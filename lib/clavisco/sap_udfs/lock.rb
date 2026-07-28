# frozen_string_literal: true

require "json"
require "time"
require "digest"

module Clavisco
  module SapUdfs
    # Tracks which schemas have been confirmed synced — by content, not just
    # by name — across EVERY company in the connections file used, so
    # `check_lock` can flag drift between config/sap_schemas and what was
    # actually confirmed against SAP:
    #
    # - stale:   listed in the lock, but no longer has a schema file on disk
    #            (removed from config — may have left an orphaned UDT/UDF in
    #            SAP that needs manual review).
    # - pending: has a schema file on disk, but was never part of a fully
    #            successful sync_all run (new schema, or a previous run that
    #            failed for at least one company).
    # - changed: has a schema file on disk AND was previously synced clean,
    #            but its content no longer matches what was synced (edited
    #            since the last successful sync_all — needs re-sync).
    #
    # Each schema is recorded with a SHA256 of its file content, not just its
    # name, precisely so an edited schema is caught even if no file was
    # added or removed.
    #
    # The lock is only written/updated when a full sync_all succeeds for
    # EVERY connection in the file — a partial success (e.g. 3 of 4 companies
    # ok) must never produce a false "all good" signal.
    class Lock
      def initialize(path, schemas_path)
        @path = path
        @schemas_path = schemas_path
      end

      def write!(schema_names)
        entries = schema_names.each_with_object({}) { |name, h| h[name] = content_hash(name) }
        File.write(@path, JSON.pretty_generate(
          "synced_at" => Time.now.utc.iso8601,
          "schemas" => entries
        ))
      end

      def exists?
        File.exist?(@path)
      end

      # Hash of { "schema_name" => "sha256..." }. Tolerates the old
      # name-only lock format (array) by treating every entry as having no
      # recorded hash, so it's reported as :changed until the next sync.
      def recorded_schemas
        return {} unless exists?

        raw = JSON.parse(File.read(@path))["schemas"]
        return {} if raw.nil?
        return raw if raw.is_a?(Hash)

        raw.each_with_object({}) { |name, h| h[name] = nil }
      end

      def check(current_schema_names)
        recorded = recorded_schemas
        recorded_names = recorded.keys

        {
          stale: recorded_names - current_schema_names,
          pending: current_schema_names - recorded_names,
          changed: (current_schema_names & recorded_names).select do |name|
            content_hash(name) != recorded[name]
          end
        }
      end

      private

      def content_hash(name)
        file = File.join(@schemas_path, "#{name}.json")
        Digest::SHA256.hexdigest(File.read(file))
      end
    end
  end
end
