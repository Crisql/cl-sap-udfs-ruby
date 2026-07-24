# frozen_string_literal: true

require "json"

module Clavisco
  module SapUdfs
    # Logic behind the sap:schema:* / sap:test_data:* rake tasks (see
    # lib/tasks/sap_udfs.rake). Kept out of the .rake file so it's testable
    # like any other class.
    #
    # schemas_path / lock_path resolve the same way SchemaSyncService's own
    # default does (Rails.root-aware when Rails is loaded, else relative to
    # the process cwd), overridable via ENV for anything that needs to point
    # elsewhere. This mirrors the tool's own "agnostic" contract: everything
    # about WHERE things live is either a sane default or an explicit input,
    # never guessed from product-specific concepts (Company, License, etc).
    module RakeSupport
      module_function

      def diff(connections_file)
        connections = load_connections(connections_file)
        results = MultiCompanySync.new(connections, schemas_path: schemas_path).diff_all
        print_results("DIFF", results)
      end

      def sync(connections_file)
        connections = load_connections(connections_file)
        results = MultiCompanySync.new(connections, schemas_path: schemas_path).sync_all
        print_results("SYNC", results)

        if MultiCompanySync.all_ok?(results)
          Lock.new(lock_path).write!(schema_names)
          puts "\nLock updated (#{lock_path}) — all #{connections.size} compan#{connections.size == 1 ? 'y' : 'ies'} synced clean."
        else
          puts "\nLock NOT updated — at least one company failed or reported schema errors."
          exit 1
        end
      end

      def sync_one(schema_name, connections_file)
        raise "schema_name argument is required, e.g. rake \"sap:schema:sync_one[log_events,/path/to/connections.json]\"" if schema_name.to_s.empty?

        connections = load_connections(connections_file)
        results = MultiCompanySync.new(connections, schemas_path: schemas_path).sync_one(schema_name)
        print_results("SYNC ONE (#{schema_name})", results)
        # sync_one only covers a single schema, not the full set — it never
        # touches the lock (which represents the full config/sap_schemas set).
        exit 1 unless MultiCompanySync.all_ok?(results)
      end

      # Purely local — never hits SAP. Compares config/sap_schemas against
      # the lock file left by the last fully-successful sync_all.
      def check_lock
        current = schema_names
        drift = Lock.new(lock_path).check(current)

        if drift[:stale].empty? && drift[:pending].empty?
          puts "Lock OK — matches current schemas (#{current.size})."
        else
          puts "Stale in lock (schema file no longer exists): #{drift[:stale].join(', ')}" unless drift[:stale].empty?
          puts "Pending (schema exists, never fully synced): #{drift[:pending].join(', ')}" unless drift[:pending].empty?
          exit 1
        end
      end

      def seed(connections_file, seed_file)
        connections = load_connections(connections_file)
        raise "seed_file argument is required" if seed_file.to_s.empty?
        raise "Seed file not found: #{seed_file}" unless File.exist?(seed_file)

        seed_data = JSON.parse(File.read(seed_file))
        table_name = seed_data.fetch("table_name") { raise "seed_file must have a top-level \"table_name\"" }
        rows = seed_data.fetch("rows") { raise "seed_file must have a top-level \"rows\" array" }

        connections.each do |conn|
          puts "-- #{conn[:name]} --"
          helper = TestDataHelper.new(ClientFactory.build(conn))
          rows.each_with_index do |row, i|
            helper.insert_row(table_name, row)
            puts "  row #{i + 1}/#{rows.size} inserted"
          rescue StandardError => e
            puts "  row #{i + 1}/#{rows.size} FAILED: #{e.message}"
          end
        rescue StandardError => e
          puts "  CONNECTION FAILED: #{e.message}"
        end
      end

      def query(connections_file, table_name, filter)
        raise "table_name argument is required" if table_name.to_s.empty?

        connections = load_connections(connections_file)
        connections.each do |conn|
          puts "-- #{conn[:name]} --"
          helper = TestDataHelper.new(ClientFactory.build(conn))
          pp helper.query(table_name, filter: (filter.to_s.empty? ? nil : filter))
        rescue StandardError => e
          puts "  FAILED: #{e.message}"
        end
      end

      def load_connections(connections_file)
        if connections_file.to_s.empty?
          raise "connections_file argument is required, e.g. rake \"sap:schema:sync[/path/to/connections.json]\""
        end

        Connections.load(connections_file)
      end

      def schemas_path
        ENV["SAP_SCHEMAS_PATH"] || (defined?(Rails) ? Rails.root.join("config", "sap_schemas").to_s : "config/sap_schemas")
      end

      def schema_names
        Dir.glob(File.join(schemas_path, "*.json")).map { |f| File.basename(f, ".json") }
      end

      def lock_path
        ENV["SAP_SYNC_LOCK_PATH"] || File.join(schemas_path, "..", "sync.lock")
      end

      def print_results(title, results)
        puts "=== #{title} ==="
        results.each do |r|
          puts "-- #{r.name} --"
          if r.ok
            pp r.data
          else
            puts "  ERROR: #{r.error}"
          end
        end
      end
    end
  end
end
