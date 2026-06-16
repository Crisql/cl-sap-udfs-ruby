# frozen_string_literal: true

require "json"

module Clavisco
  module SapUdfs
    # Synchronizes UDT/UDF definitions from JSON schemas to SAP via Service Layer.
    # Product-agnostic: schemas_path is injectable.
    #
    # JSON column fields use SAP naming directly (PascalCase):
    # Name, Description, Type, SubType, Size, Mandatory, DefaultValue.
    # The dev writes values exactly as SAP expects them — no translations.
    #
    # The only rule the tool applies internally is sending EditSize alongside
    # Size on PATCH, because SAP silently ignores Size-only updates.
    #
    # Supports these actions per UDF:
    # - :created  — field did not exist, was created
    # - :exists   — field exists and matches schema (no changes)
    # - :updated  — field exists, some properties were updated
    # - :partially_updated — some properties updated, some rejected
    # - :update_failed — field exists, update was attempted but SAP rejected it
    #
    class SchemaSyncService
      def initialize(client, schemas_path: nil, logger: nil)
        @client = client
        @schemas_path = schemas_path || default_schemas_path
        @logger = logger
      end

      # Sync all schemas: create UDTs/UDFs that don't exist, update existing ones if schema changed.
      # Returns { "schema_name" => { table:, columns: [{ name:, action:, updates: [...] }] } }
      def sync_all
        results = {}
        schema_files.each do |file|
          name = File.basename(file, ".json")
          begin
            results[name] = sync(name)
          rescue StandardError => e
            results[name] = { error: e.message, table: nil, columns: [] }
            log(:error, "Failed to sync #{name}: #{e.message}")
          end
        end
        results
      end

      def sync(schema_name)
        schema = load_schema(schema_name)
        result = { table: nil, columns: [] }

        unless @client.udt_exists?(schema["table_name"])
          @client.create_udt(schema["table_name"], schema["table_description"], schema["table_type"] || "bott_NoObject")
          result[:table] = :created
          log(:info, "Created UDT: #{schema['table_name']}")
        else
          result[:table] = :exists
        end

        udt_table = "@#{schema['table_name']}"

        schema["columns"].each do |col|
          current_udf = get_udf_metadata(udt_table, col["Name"])

          if current_udf
            # Field exists — check if update is needed
            col_result = check_and_update_udf(current_udf, col, udt_table)
            result[:columns] << col_result
          else
            # Field does not exist — create it
            @client.create_udf(
              schema["table_name"],
              field_name: col["Name"],
              description: col["Description"],
              type: col["Type"],
              sub_type: col["SubType"],
              size: col["Size"],
              mandatory: col["Mandatory"],
              default_value: col["DefaultValue"]
            )
            result[:columns] << { name: col["Name"], action: :created }
            log(:info, "Created UDF: #{udt_table}.U_#{col['Name']}")
          end
        end

        result
      end

      def diff_all
        results = {}
        schema_files.each do |file|
          name = File.basename(file, ".json")
          begin
            results[name] = diff(name)
          rescue StandardError => e
            results[name] = { error: e.message, table: nil, columns: [] }
          end
        end
        results
      end

      def diff(schema_name)
        schema = load_schema(schema_name)
        changes = { table: nil, columns: [] }

        table_exists = @client.udt_exists?(schema["table_name"])
        changes[:table] = table_exists ? :exists : :will_create

        udt_table = "@#{schema['table_name']}"
        schema["columns"].each do |col|
          if table_exists
            current_udf = get_udf_metadata(udt_table, col["Name"])
            if current_udf
              # Field exists — check what would change
              diffs = compute_diffs(current_udf, col)
              if diffs.any?
                changes[:columns] << { name: col["Name"], action: :will_update, diffs: diffs }
              else
                changes[:columns] << { name: col["Name"], action: :exists }
              end
            else
              changes[:columns] << { name: col["Name"], action: :will_create }
            end
          else
            changes[:columns] << { name: col["Name"], action: :will_create }
          end
        end

        changes
      end

      private

      # Fetch current UDF metadata from SAP (returns hash or nil)
      def get_udf_metadata(udt_table, field_name)
        filter = Clavisco::ServiceLayer::OdataFilter.and(
          Clavisco::ServiceLayer::OdataFilter.eq("TableName", udt_table),
          Clavisco::ServiceLayer::OdataFilter.eq("Name", field_name)
        )
        result = @client.get("UserFieldsMD", params: { "$filter" => filter })
        return nil unless result.is_a?(Array) && result.any?

        result.first
      rescue StandardError
        nil
      end

      # Compare current SAP state with desired schema and attempt updates.
      # Returns { name:, action:, updates: [{ property:, old:, new:, status:, error: }] }
      def check_and_update_udf(current_udf, col, udt_table)
        diffs = compute_diffs(current_udf, col)

        if diffs.empty?
          return { name: col["Name"], action: :exists }
        end

        # SAP UserFieldsMD uses composite key: TableName + FieldID
        table_name = current_udf["TableName"]
        field_id = current_udf["FieldID"]
        updates = []

        diffs.each do |diff_item|
          body = build_update_body(diff_item)
          begin
            resource = "UserFieldsMD(TableName='#{table_name}',FieldID=#{field_id})"
            @client.patch(resource, body: body)
            updates << {
              property: diff_item[:property],
              old_value: diff_item[:old_value],
              new_value: diff_item[:new_value],
              status: :success
            }
            log(:info, "Updated UDF #{udt_table}.U_#{col['Name']}.#{diff_item[:property]}: '#{diff_item[:old_value]}' → '#{diff_item[:new_value]}'")
          rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
            updates << {
              property: diff_item[:property],
              old_value: diff_item[:old_value],
              new_value: diff_item[:new_value],
              status: :failed,
              error: e.sap_message || e.message
            }
            log(:warn, "Failed to update UDF #{udt_table}.U_#{col['Name']}.#{diff_item[:property]}: #{e.message}")
          end
        end

        has_success = updates.any? { |u| u[:status] == :success }
        has_failure = updates.any? { |u| u[:status] == :failed }

        action = if has_success && has_failure
                   :partially_updated
                 elsif has_success
                   :updated
                 else
                   :update_failed
                 end

        { name: col["Name"], action: action, updates: updates }
      end

      # Compute differences between SAP current state and desired schema.
      # All field names match SAP naming directly — no translation needed.
      def compute_diffs(current_udf, col)
        diffs = []

        # Description
        desired_desc = col["Description"]
        current_desc = current_udf["Description"] || ""
        if desired_desc != current_desc
          diffs << { property: "Description", old_value: current_desc, new_value: desired_desc }
        end

        # DefaultValue
        desired_default = col["DefaultValue"] || ""
        current_default = current_udf["DefaultValue"] || ""
        if desired_default.to_s != current_default.to_s
          diffs << { property: "DefaultValue", old_value: current_default, new_value: desired_default }
        end

        # Size
        if col["Size"] && current_udf["Size"]
          desired_size = col["Size"].to_i
          current_size = current_udf["Size"].to_i
          if desired_size != current_size
            diffs << { property: "Size", old_value: current_size, new_value: desired_size }
          end
        end

        # Type (SAP rejects changes — attempted for reporting)
        desired_type = col["Type"]
        current_type = current_udf["Type"] || ""
        if desired_type != current_type
          diffs << { property: "Type", old_value: current_type, new_value: desired_type }
        end

        # Mandatory
        desired_mandatory = col["Mandatory"]
        current_mandatory = current_udf["Mandatory"] || "tNO"
        if desired_mandatory != current_mandatory
          diffs << { property: "Mandatory", old_value: current_mandatory, new_value: desired_mandatory }
        end

        diffs
      end

      # Build the PATCH body for a single property change.
      #
      # Only rule: Size requires EditSize alongside it. SAP silently ignores
      # Size-only PATCH (accepts without error, does not persist the change).
      def build_update_body(diff_item)
        case diff_item[:property]
        when "Description"
          { Description: diff_item[:new_value] }
        when "DefaultValue"
          { DefaultValue: diff_item[:new_value] }
        when "Size"
          { Size: diff_item[:new_value], EditSize: diff_item[:new_value] }
        when "Type"
          { Type: diff_item[:new_value] }
        when "Mandatory"
          { Mandatory: diff_item[:new_value] }
        else
          {}
        end
      end

      def schema_files
        Dir.glob(File.join(@schemas_path, "*.json")).sort
      end

      def load_schema(name)
        file = File.join(@schemas_path, "#{name}.json")
        raise "Schema not found: #{file}" unless File.exist?(file)

        schema = JSON.parse(File.read(file))
        validate_schema!(schema, file)
        schema
      end

      # Validates required fields in the JSON schema.
      # Fails fast so devs get clear feedback on what's missing.
      def validate_schema!(schema, file)
        errors = []
        errors << "table_name is required" unless schema["table_name"].to_s.strip != ""
        errors << "table_description is required" unless schema["table_description"].to_s.strip != ""

        (schema["columns"] || []).each_with_index do |col, i|
          label = col["Name"] || "columns[#{i}]"
          errors << "#{label}: Name is required" unless col["Name"].to_s.strip != ""
          errors << "#{label}: Description is required" unless col["Description"].to_s.strip != ""
          errors << "#{label}: Type is required" unless col["Type"].to_s.strip != ""
          errors << "#{label}: SubType is required" unless col["SubType"].to_s.strip != ""
          errors << "#{label}: Mandatory is required (tYES or tNO)" unless %w[tYES tNO].include?(col["Mandatory"])
        end

        return if errors.empty?

        raise "Invalid schema #{file}:\n  - #{errors.join("\n  - ")}"
      end

      def default_schemas_path
        defined?(Rails) ? Rails.root.join("config", "sap_schemas").to_s : "config/sap_schemas"
      end

      def log(level, message)
        logger = @logger || (defined?(Rails) && Rails.logger) || nil
        logger&.send(level, "[SapSchemaSync] #{message}")
      end
    end
  end
end
