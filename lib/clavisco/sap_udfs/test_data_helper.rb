# frozen_string_literal: true

require "securerandom"

module Clavisco
  module SapUdfs
    # Raw UDT row-data access (query/insert) against a pure-driver Client.
    # Independent of schema sync — this is plumbing only: it knows SAP's
    # naming convention for UDT data resources (U_ prefix) and system fields
    # (Code/Name/DocEntry), but has zero opinion about WHAT data a product
    # wants to seed or query. That data is supplied by the caller (rake
    # tasks read it from a JSON file the product owns).
    class TestDataHelper
      def initialize(client)
        @client = client
      end

      # Input can be "CL_EMA_LOG_EVENTS", "@CL_EMA_LOG_EVENTS", or already
      # "U_CL_EMA_LOG_EVENTS" — the "@" (UserFieldsMD reference prefix) is
      # never used for data access, only "U_" is.
      def udt_data_resource(table_name)
        clean = table_name.to_s.delete_prefix("@")
        clean.start_with?("U_") ? clean : "U_#{clean}"
      end

      def query(table_name, filter: nil, top: nil, skip: nil, order_by: nil, select: nil)
        params = {}
        params["$filter"] = filter if filter
        params["$top"] = top if top
        params["$skip"] = skip if skip
        params["$orderby"] = order_by if order_by
        params["$select"] = select if select
        @client.get(udt_data_resource(table_name), params: params)
      end

      # Code and Name are SAP system fields (no U_ prefix); every other key
      # gets the U_ prefix added automatically unless already present.
      def insert_row(table_name, data)
        system_keys = %w[Code Name DocEntry]
        body = {}
        data.each do |key, value|
          key_str = key.to_s
          field_name = if system_keys.include?(key_str)
                         key_str
                       else
                         key_str.start_with?("U_") ? key_str : "U_#{key_str}"
                       end
          body[field_name] = value
        end
        body["Code"] ||= SecureRandom.uuid[0..19]
        body["Name"] ||= body["Code"]
        @client.post(udt_data_resource(table_name), body: body)
      end
    end
  end
end
