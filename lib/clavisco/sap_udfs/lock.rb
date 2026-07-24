# frozen_string_literal: true

require "json"
require "time"

module Clavisco
  module SapUdfs
    # Tracks which schemas have been confirmed synced, across EVERY company
    # in the connections file used, so `check_lock` can flag drift between
    # config/sap_schemas and what was actually confirmed against SAP:
    #
    # - stale:   listed in the lock, but no longer has a schema file on disk
    #            (removed from config — may have left an orphaned UDT/UDF in
    #            SAP that needs manual review).
    # - pending: has a schema file on disk, but was never part of a fully
    #            successful sync_all run (new schema, or a previous run that
    #            failed for at least one company).
    #
    # The lock is only written/updated when a full sync_all succeeds for
    # EVERY connection in the file — a partial success (e.g. 3 of 4 companies
    # ok) must never produce a false "all good" signal.
    class Lock
      def initialize(path)
        @path = path
      end

      def write!(schema_names)
        File.write(@path, JSON.pretty_generate(
          "synced_at" => Time.now.utc.iso8601,
          "schemas" => schema_names.sort
        ))
      end

      def exists?
        File.exist?(@path)
      end

      def recorded_schemas
        return [] unless exists?

        JSON.parse(File.read(@path))["schemas"] || []
      end

      def check(current_schema_names)
        recorded = recorded_schemas
        {
          stale: recorded - current_schema_names,
          pending: current_schema_names - recorded
        }
      end
    end
  end
end
