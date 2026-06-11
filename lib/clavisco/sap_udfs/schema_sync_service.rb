# frozen_string_literal: true

module Sap
  # Synchronizes UDT/UDF definitions from JSON schemas to SAP via Service Layer.
  # Reads JSON files from config/sap_schemas/ and ensures the corresponding
  # tables and fields exist in SAP.
  #
  # Usage:
  #   client = Clavisco::ServiceLayer::Client.new(...)
  #   service = Sap::SchemaSyncService.new(client)
  #   service.sync_all              # sync all schemas
  #   service.sync("log_events")    # sync one schema
  #   service.diff_all              # dry-run — show what would change
  #
  class SchemaSyncService
    SCHEMAS_PATH = Rails.root.join("config", "sap_schemas")

    def initialize(client)
      @client = client
    end

    # Sync all JSON schemas to SAP. Handles partial failures per schema.
    def sync_all
      results = {}
      schema_files.each do |file|
        name = File.basename(file, ".json")
        begin
          results[name] = sync(name)
        rescue StandardError => e
          results[name] = { error: e.message, table: nil, columns: [] }
          Rails.logger.error "[SapSchemaSync] Failed to sync #{name}: #{e.message}"
        end
      end
      results
    end

    # Sync a single schema by name (e.g. "log_events")
    def sync(schema_name)
      schema = load_schema(schema_name)
      result = { table: nil, columns: [] }

      # Step 1: Create table if it doesn't exist
      unless @client.udt_exists?(schema["table_name"])
        @client.create_udt(
          schema["table_name"],
          schema["table_description"],
          schema["table_type"] || "bott_NoObject"
        )
        result[:table] = :created
        Rails.logger.info "[SapSchemaSync] Created UDT: #{schema['table_name']}"
      else
        result[:table] = :exists
      end

      # Step 2: Create columns (UDFs) that don't exist
      udt_table = "@#{schema['table_name']}"

      schema["columns"].each do |col|
        field_name = col["name"]

        if udf_exists?(udt_table, field_name)
          result[:columns] << { name: field_name, action: :exists }
        else
          @client.create_udf(
            schema["table_name"],
            field_name: field_name,
            description: col["description"] || field_name,
            type: col["type"] || "db_Alpha",
            size: col["size"],
            mandatory: col["mandatory"] || false,
            default_value: col["default_value"]
          )
          result[:columns] << { name: field_name, action: :created }
          Rails.logger.info "[SapSchemaSync] Created UDF: #{udt_table}.U_#{field_name}"
        end
      end

      result
    end

    # Dry-run: show what would be created without making changes
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

    # Dry-run for a single schema
    def diff(schema_name)
      schema = load_schema(schema_name)
      changes = { table: nil, columns: [] }

      table_exists = @client.udt_exists?(schema["table_name"])
      changes[:table] = table_exists ? :exists : :will_create

      udt_table = "@#{schema['table_name']}"

      schema["columns"].each do |col|
        exists = table_exists ? udf_exists?(udt_table, col["name"]) : false
        changes[:columns] << {
          name: col["name"],
          action: exists ? :exists : :will_create
        }
      end

      changes
    end

    private

    def schema_files
      Dir.glob(SCHEMAS_PATH.join("*.json")).sort
    end

    def load_schema(name)
      file = SCHEMAS_PATH.join("#{name}.json")
      raise "Schema not found: #{file}" unless File.exist?(file)

      JSON.parse(File.read(file))
    end

    # Check if a UDF exists on a table using OData filter with proper escaping
    def udf_exists?(udt_table, field_name)
      filter = Clavisco::ServiceLayer::OdataFilter.and(
        Clavisco::ServiceLayer::OdataFilter.eq("TableName", udt_table),
        Clavisco::ServiceLayer::OdataFilter.eq("Name", field_name)
      )
      result = @client.get("UserFieldsMD", params: { "$filter" => filter })
      result.is_a?(Array) && result.any?
    rescue Clavisco::ServiceLayer::Client::NotFoundError
      false
    rescue Clavisco::ServiceLayer::Client::ServiceLayerError
      false
    end
  end
end
