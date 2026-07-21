# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "fileutils"
require "clavisco/sap_udfs"

# Minimal stand-ins for the external `service_layer` gem contract.
# SchemaSyncService only depends on these two constants — see HANDOFF_SAP_UDFS.md
# section 2 ("Contrato de interfaz del cliente").
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
    end
  end
end

# Fake Service Layer client used to test SchemaSyncService without hitting SAP.
# Implements exactly the contract described in HANDOFF_SAP_UDFS.md section 2:
#   udt_exists?, create_udt, create_udf, get, patch
#
# Records every call so tests can assert on what was (or wasn't) invoked —
# e.g. asserting `create_udt` was never called for a native-table schema.
class MockSLClient
  Call = Struct.new(:args, :kwargs)

  def initialize
    @calls = Hash.new { |h, k| h[k] = [] }
    @udt_exists = {}
    @udfs = {}
  end

  # --- test setup helpers ---

  def stub_udt_exists(table_name, exists)
    @udt_exists[table_name] = exists
  end

  # table_name must match exactly what SchemaSyncService will query with:
  # "@TABLE" for UDTs, "TABLE" (no prefix) for native_table schemas.
  def stub_udf(table_name, field_name, metadata)
    @udfs["#{table_name}::#{field_name}"] = metadata
  end

  def calls(method_name)
    @calls[method_name]
  end

  # --- contract methods ---

  def udt_exists?(table_name)
    record(:udt_exists?, [table_name])
    !!@udt_exists[table_name]
  end

  def create_udt(table_name, description, table_type = "bott_NoObject")
    record(:create_udt, [table_name, description, table_type])
    @udt_exists[table_name] = true
    true
  end

  def create_udf(table_name, field_name:, description:, type:, sub_type:, size:, mandatory:, default_value:)
    record(:create_udf, [table_name], field_name: field_name, description: description, type: type,
                                       sub_type: sub_type, size: size, mandatory: mandatory,
                                       default_value: default_value)
    true
  end

  def get(resource, params:)
    record(:get, [resource], params: params)
    filter = params["$filter"].to_s
    table = filter[/TableName eq '([^']*)'/, 1]
    name = filter[/(?<!Table)Name eq '([^']*)'/, 1]
    metadata = @udfs["#{table}::#{name}"]
    metadata ? [metadata] : []
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
