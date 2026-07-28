# frozen_string_literal: true

require_relative "test_helper"

class CsvReportTest < Minitest::Test
  Result = Clavisco::SapUdfs::MultiCompanySync::Result

  def test_header_row
    csv = Clavisco::SapUdfs::CsvReport.generate([])
    assert_equal "company,schema,table_action,column_name,column_action,detail\n", csv
  end

  def test_connection_level_failure
    results = [Result.new(name: "BROKEN", ok: false, data: {}, error: "cannot connect")]

    csv = Clavisco::SapUdfs::CsvReport.generate(results)

    assert_includes csv, "BROKEN,,CONNECTION_ERROR,,,cannot connect"
  end

  def test_schema_level_error
    results = [Result.new(name: "A", ok: true, data: {
      "broken_schema" => { error: "Invalid schema", table: nil, columns: [] }
    })]

    csv = Clavisco::SapUdfs::CsvReport.generate(results)

    assert_includes csv, "A,broken_schema,ERROR,,,Invalid schema"
  end

  def test_created_column
    results = [Result.new(name: "A", ok: true, data: {
      "loyalty_native" => { table: :native, columns: [{ name: "LoyaltyPoints", action: :created }] }
    })]

    csv = Clavisco::SapUdfs::CsvReport.generate(results)

    assert_includes csv, "A,loyalty_native,native,LoyaltyPoints,created,"
  end

  def test_updated_column_includes_update_detail
    results = [Result.new(name: "A", ok: true, data: {
      "log_events" => { table: :exists, columns: [
        { name: "Event", action: :updated, updates: [
          { property: "Description", old_value: "old", new_value: "new", status: :success }
        ] }
      ] }
    })]

    csv = Clavisco::SapUdfs::CsvReport.generate(results)

    assert_includes csv, "Description: old->new (success)"
  end

  def test_diff_will_update_includes_diffs_detail
    results = [Result.new(name: "A", ok: true, data: {
      "log_events" => { table: :exists, columns: [
        { name: "Event", action: :will_update, diffs: [
          { property: "Description", old_value: "old", new_value: "new" }
        ] }
      ] }
    })]

    csv = Clavisco::SapUdfs::CsvReport.generate(results)

    assert_includes csv, "Description: old->new"
  end

  def test_schema_with_no_columns_still_gets_a_row
    results = [Result.new(name: "A", ok: true, data: {
      "empty_schema" => { table: :exists, columns: [] }
    })]

    csv = Clavisco::SapUdfs::CsvReport.generate(results)

    assert_includes csv, "A,empty_schema,exists,,,"
  end

  def test_write_creates_file
    require "tmpdir"
    Dir.mktmpdir do |dir|
      path = File.join(dir, "report.csv")
      results = [Result.new(name: "A", ok: true, data: {
        "loyalty_native" => { table: :native, columns: [{ name: "LoyaltyPoints", action: :created }] }
      })]

      Clavisco::SapUdfs::CsvReport.write(results, path)

      assert File.exist?(path)
      assert_includes File.read(path), "LoyaltyPoints"
    end
  end
end
