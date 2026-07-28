# frozen_string_literal: true

require "csv"

module Clavisco
  module SapUdfs
    # Flattens MultiCompanySync results (from sync_all/diff_all/sync_one)
    # into CSV rows for review — one row per (company, schema, column).
    # Pure formatting: no SAP calls, no opinion beyond what
    # SchemaSyncService/MultiCompanySync already reported.
    module CsvReport
      HEADERS = %w[company schema table_action column_name column_action detail].freeze

      def self.write(results, path)
        File.write(path, generate(results))
      end

      def self.generate(results)
        CSV.generate do |csv|
          csv << HEADERS
          rows(results).each { |row| csv << row }
        end
      end

      def self.rows(results)
        results.flat_map { |r| rows_for_connection(r) }
      end

      def self.rows_for_connection(r)
        return [[r.name, nil, "CONNECTION_ERROR", nil, nil, r.error]] unless r.ok

        (r.data || {}).flat_map { |schema_name, schema_result| rows_for_schema(r.name, schema_name, schema_result) }
      end

      def self.rows_for_schema(company, schema_name, schema_result)
        return [[company, schema_name, "ERROR", nil, nil, schema_result[:error]]] if schema_result[:error]

        columns = schema_result[:columns] || []
        return [[company, schema_name, schema_result[:table], nil, nil, nil]] if columns.empty?

        columns.map do |col|
          [company, schema_name, schema_result[:table], col[:name], col[:action], detail_for(col)]
        end
      end

      def self.detail_for(col)
        if col[:updates]
          col[:updates].map do |u|
            "#{u[:property]}: #{u[:old_value]}->#{u[:new_value]} (#{u[:status]}#{u[:error] ? " - #{u[:error]}" : ""})"
          end.join("; ")
        elsif col[:diffs]
          col[:diffs].map { |d| "#{d[:property]}: #{d[:old_value]}->#{d[:new_value]}" }.join("; ")
        end
      end
    end
  end
end
