# frozen_string_literal: true

module Clavisco
  module SapUdfs
    # Builds a Clavisco::ServiceLayer::Client from one entry produced by
    # Connections.load. This gem does not depend on service_layer directly —
    # SchemaSyncService only needs an object that responds to get/post/patch —
    # so the require is attempted lazily, only when a real client is actually
    # needed (rake tasks), with a clear error if it's not on the load path.
    module ClientFactory
      def self.build(connection)
        begin
          require "clavisco/service_layer"
        rescue LoadError
          raise "Clavisco::ServiceLayer::Client is not available on the load path. " \
                "Make sure the service_layer gem/submodule is required before running " \
                "sap:schema:* / sap:test_data:* tasks."
        end

        Clavisco::ServiceLayer::Client.new(
          base_url: connection[:base_url],
          company_db: connection[:company_db],
          username: connection[:username],
          password: connection[:password],
          session_owner_id: connection[:session_owner_id] || connection[:name] || "sap-udfs"
        )
      end
    end
  end
end
