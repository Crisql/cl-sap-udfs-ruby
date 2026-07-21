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
    # The only rule the tool applies internally on updates is sending EditSize
    # alongside Size on PATCH, because SAP silently ignores Size-only updates.
    #
    # `client` is expected to be a pure Service Layer driver: get/post/patch/
    # delete only (see Clavisco::ServiceLayer::Client). This service builds the
    # exact UserTablesMD/UserFieldsMD resources and bodies itself — it does not
    # rely on any UDT/UDF-aware helper on the client.
    #
    # A schema can target either:
    # - a User-Defined Table (default, `"IsUDT" => true` or the key absent):
    #   the tool creates the UDT if missing and queries/creates UDFs under it.
    #   `table_name` must already include the "@" SAP prefix (e.g. "@CL_TEST")
    #   — the developer writes it, this service only validates it's there.
    # - a native SAP table (`"IsUDT" => false`, e.g. OCRD, OITM, ORDR):
    #   the tool never creates the table. `table_name` must NOT have the "@"
    #   prefix (e.g. "OCRD"). `table_description` / `table_type` are irrelevant
    #   in this case and are not required by validation.
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

        if udt?(schema)
          bare_name = bare_table_name(schema)
          if table_exists?(bare_name)
            result[:table] = :exists
          else
            create_table(bare_name, schema["table_description"], schema["table_type"] || "bott_NoObject")
            result[:table] = :created
            log(:info, "Created UDT: #{bare_name}")
          end
        else
          result[:table] = :native
        end

        table_name = schema["table_name"]

        schema["columns"].each do |col|
          current_udf = get_udf_metadata(table_name, col["Name"])

          if current_udf
            # Field exists — check if update is needed
            col_result = check_and_update_udf(current_udf, col, table_name)
            result[:columns] << col_result
          else
            # Field does not exist — create it
            create_udf(table_name, col)
            result[:columns] << { name: col["Name"], action: :created }
            log(:info, "Created UDF: #{table_name}.U_#{col['Name']}")
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

        if udt?(schema)
          table_present = table_exists?(bare_table_name(schema))
          changes[:table] = table_present ? :exists : :will_create
        else
          changes[:table] = :native
          table_present = true
        end

        table_name = schema["table_name"]
        schema["columns"].each do |col|
          if table_present
            current_udf = get_udf_metadata(table_name, col["Name"])
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

      # True when the schema targets a User-Defined Table (the default).
      # False means a native SAP table (OCRD, OITM, ORDR, ...).
      def udt?(schema)
        schema.key?("IsUDT") ? schema["IsUDT"] == true : true
      end

      # table_name without the "@" prefix — only meaningful for UDT schemas,
      # needed because UserTablesMD (create/exists) always uses the bare name;
      # only references to it in UserFieldsMD keep the "@".
      def bare_table_name(schema)
        schema["table_name"].to_s.delete_prefix("@")
      end

      # ── Raw Service Layer calls (UserTablesMD) ──
      # The client is a pure driver — this service builds the exact resource/body.

      def table_exists?(bare_name)
        @client.get("UserTablesMD('#{bare_name}')")
        true
      rescue Clavisco::ServiceLayer::Client::NotFoundError
        false
      end

      def create_table(bare_name, description, table_type)
        @client.post("UserTablesMD", body: {
          TableName: bare_name,
          TableDescription: description,
          TableType: table_type
        })
      end

      # ── Raw Service Layer calls (UserFieldsMD) ──

      # Fetch current UDF metadata from SAP (returns hash or nil).
      # table_name is used exactly as given in the schema (already "@"-prefixed
      # for UDTs, bare for native tables) — no naming decision made here.
      def get_udf_metadata(table_name, field_name)
        filter = Clavisco::ServiceLayer::OdataFilter.and(
          Clavisco::ServiceLayer::OdataFilter.eq("TableName", table_name),
          Clavisco::ServiceLayer::OdataFilter.eq("Name", field_name)
        )
        result = @client.get("UserFieldsMD", params: { "$filter" => filter })
        return nil unless result.is_a?(Array) && result.any?

        result.first
      rescue StandardError
        nil
      end

      def create_udf(table_name, col)
        body = {
          TableName: table_name,
          Name: col["Name"],
          Description: col["Description"],
          Type: col["Type"],
          SubType: col["SubType"],
          Mandatory: col["Mandatory"]
        }
        body[:Size] = col["Size"] if col["Size"]
        body[:DefaultValue] = col["DefaultValue"] if col["DefaultValue"]
        @client.post("UserFieldsMD", body: body)
      end

      # Compare current SAP state with desired schema and attempt updates.
      # Returns { name:, action:, updates: [{ property:, old:, new:, status:, error: }] }
      def check_and_update_udf(current_udf, col, table_name)
        diffs = compute_diffs(current_udf, col)

        if diffs.empty?
          return { name: col["Name"], action: :exists }
        end

        # SAP UserFieldsMD uses composite key: TableName + FieldID
        udf_table_name = current_udf["TableName"]
        field_id = current_udf["FieldID"]
        updates = []

        diffs.each do |diff_item|
          body = build_update_body(diff_item)
          begin
            resource = "UserFieldsMD(TableName='#{udf_table_name}',FieldID=#{field_id})"
            @client.patch(resource, body: body)
            updates << {
              property: diff_item[:property],
              old_value: diff_item[:old_value],
              new_value: diff_item[:new_value],
              status: :success
            }
            log(:info, "Updated UDF #{table_name}.U_#{col['Name']}.#{diff_item[:property]}: '#{diff_item[:old_value]}' → '#{diff_item[:new_value]}'")
          rescue Clavisco::ServiceLayer::Client::ServiceLayerError => e
            updates << {
              property: diff_item[:property],
              old_value: diff_item[:old_value],
              new_value: diff_item[:new_value],
              status: :failed,
              error: e.sap_message || e.message
            }
            log(:warn, "Failed to update UDF #{table_name}.U_#{col['Name']}.#{diff_item[:property]}: #{e.message}")
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

        if udt?(schema)
          errors << "table_description is required" unless schema["table_description"].to_s.strip != ""
          unless schema["table_name"].to_s.start_with?("@")
            errors << "table_name must start with '@' when IsUDT is true (or absent) — e.g. \"@#{schema['table_name']}\""
          end
        elsif schema["table_name"].to_s.start_with?("@")
          errors << "table_name must NOT start with '@' when IsUDT is false (native table)"
        end

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
