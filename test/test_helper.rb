# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "fileutils"
require "clavisco/sap_udfs"

# Minimal stand-ins for the external `service_layer` gem contract.
# Clavisco::ServiceLayer::Client is a pure driver (get/post/patch/delete +
# session/retry) — it has no UDT/UDF-aware methods. SchemaSyncService builds
# the exact UserTablesMD/UserFieldsMD resources/bodies itself.
module Clavisco
  module ServiceLayer
    module OdataFilter
      def self.eq(field, value)
        "#{field} eq '#{value}'"
      end

      def self.and(*clauses)
        clauses.join(" and ")
      end
    end

    class Client
      class ServiceLayerError < StandardError
        attr_reader :sap_message

        def initialize(message, sap_message: nil)
          super(message)
          @sap_message = sap_message
        end
      end

      class NotFoundError < ServiceLayerError; end
    end
  end
end

# Fake Service Layer client used to test SchemaSyncService without hitting SAP.
# Implements only the pure-driver contract: get/post/patch. Records every call
# so tests can assert on exactly what resource/body SchemaSyncService built —
# e.g. asserting no UserTablesMD POST happened for a native-table schema.
class MockSLClient
  Call = Struct.new(:args, :kwargs)

  def initialize
    @calls = Hash.new { |h, k| h[k] = [] }
    @existing_tables = {}
    @udfs = {}
  end

  # --- test setup helpers ---

  # table_name here is always the BARE name (no "@") — matches what
  # SchemaSyncService queries UserTablesMD('...') with.
  def stub_table_exists(table_name, exists)
    @existing_tables[table_name] = exists
  end

  # table_name must match exactly what SchemaSyncService will query with:
  # "@TABLE" for UDTs, "TABLE" (no prefix) for native-table schemas.
  def stub_udf(table_name, field_name, metadata)
    @udfs["#{table_name}::#{field_name}"] = metadata
  end

  def calls(method_name)
    @calls[method_name]
  end

  # --- pure-driver contract ---

  def get(resource, params: {})
    record(:get, [resource], params: params)

    if (table = resource[/\AUserTablesMD\('([^']*)'\)\z/, 1])
      raise Clavisco::ServiceLayer::Client::NotFoundError, "not found" unless @existing_tables[table]

      return { "TableName" => table }
    end

    if resource == "UserFieldsMD"
      filter = params["$filter"].to_s
      table = filter[/TableName eq '([^']*)'/, 1]
      name = filter[/(?<!Table)Name eq '([^']*)'/, 1]
      metadata = @udfs["#{table}::#{name}"]
      return metadata ? [metadata] : []
    end

    raise "MockSLClient#get: unexpected resource #{resource.inspect}"
  end

  def post(resource, body:)
    record(:post, [resource], body: body)
    @existing_tables[body[:TableName]] = true if resource == "UserTablesMD"
    true
  end

  def patch(resource, body:)
    record(:patch, [resource], body: body)
    true
  end

  private

  def record(method, args, kwargs = {})
    @calls[method] << Call.new(args, kwargs)
  end
end

# Writes a schema hash out as a JSON file inside dir/name.json and returns the dir,
# so tests can point SchemaSyncService.new(client, schemas_path: dir) at it.
def write_schema(dir, name, schema)
  File.write(File.join(dir, "#{name}.json"), JSON.generate(schema))
end
