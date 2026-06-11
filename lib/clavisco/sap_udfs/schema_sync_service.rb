# frozen_string_literal: true

require "json"

module Clavisco
  module SapUdfs
    # Synchronizes UDT/UDF definitions from JSON schemas to SAP via Service Layer.
    # Product-agnostic: schemas_path is injectable.
    #
    class SchemaSyncService
      def initialize(client, schemas_path: nil, logger: nil)
        @client = client
        @schemas_path = schemas_path || default_schemas_path
        @logger = logger
      end

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
          if udf_exists?(udt_table, col["name"])
            result[:columns] << { name: col["name"], action: :exists }
          else
            @client.create_udf(
              schema["table_name"],
              field_name: col["name"],
              description: col["description"] || col["name"],
              type: col["type"] || "db_Alpha",
              size: col["size"],
              mandatory: col["mandatory"] || false,
              default_value: col["default_value"]
            )
            result[:columns] << { name: col["name"], action: :created }
            log(:info, "Created UDF: #{udt_table}.U_#{col['name']}")
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
          exists = table_exists ? udf_exists?(udt_table, col["name"]) : false
          changes[:columns] << { name: col["name"], action: exists ? :exists : :will_create }
        end

        changes
      end

      private

      def schema_files
        Dir.glob(File.join(@schemas_path, "*.json")).sort
      end

      def load_schema(name)
        file = File.join(@schemas_path, "#{name}.json")
        raise "Schema not found: #{file}" unless File.exist?(file)

        JSON.parse(File.read(file))
      end

      def udf_exists?(udt_table, field_name)
        filter = Clavisco::ServiceLayer::OdataFilter.and(
          Clavisco::ServiceLayer::OdataFilter.eq("TableName", udt_table),
          Clavisco::ServiceLayer::OdataFilter.eq("Name", field_name)
        )
        result = @client.get("UserFieldsMD", params: { "$filter" => filter })
        result.is_a?(Array) && result.any?
      rescue StandardError
        false
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
