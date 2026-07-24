# frozen_string_literal: true

module Clavisco
  module SapUdfs
    # Runs SchemaSyncService against every connection in a connections file.
    # One MultiCompanySync = one schemas_path, N SAP companies. Each
    # company's failure is isolated — one failing doesn't stop the rest —
    # and reported separately so the caller can decide what "fully ok" means
    # (see .all_ok?).
    class MultiCompanySync
      Result = Struct.new(:name, :ok, :data, :error, keyword_init: true)

      def initialize(connections, schemas_path: nil, client_factory: ClientFactory.method(:build))
        @connections = connections
        @schemas_path = schemas_path
        @client_factory = client_factory
      end

      def diff_all
        run_each { |service| service.diff_all }
      end

      def sync_all
        run_each { |service| service.sync_all }
      end

      def sync_one(schema_name)
        run_each { |service| { schema_name => service.sync(schema_name) } }
      end

      # True only if every connection ran without a connection-level
      # exception AND without any per-schema :error entry (SchemaSyncService
      # rescues those itself inside sync_all/diff_all and reports them as
      # { error: "..." } under that schema's name).
      def self.all_ok?(results)
        results.all? do |r|
          r.ok && (r.data || {}).values.none? { |s| s.is_a?(Hash) && s[:error] }
        end
      end

      private

      def run_each
        @connections.map do |conn|
          client = @client_factory.call(conn)
          service = SchemaSyncService.new(client, schemas_path: @schemas_path)
          Result.new(name: conn[:name], ok: true, data: yield(service), error: nil)
        rescue StandardError => e
          Result.new(name: conn[:name], ok: false, data: {}, error: e.message)
        end
      end
    end
  end
end
