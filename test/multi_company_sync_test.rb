# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class MultiCompanySyncTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    write_schema(@dir, "loyalty_native", {
      "table_name" => "OCRD",
      "IsUDT" => false,
      "columns" => [
        { "Name" => "LoyaltyPoints", "Description" => "Puntos de lealtad", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  # client_factory here returns a distinct MockSLClient per connection so
  # tests can assert on each company's calls independently.
  def clients_by_name
    @clients_by_name ||= Hash.new { |h, k| h[k] = MockSLClient.new }
  end

  def factory
    ->(conn) { clients_by_name[conn[:name]] }
  end

  def connections(*names)
    names.map { |n| { name: n } }
  end

  def test_runs_against_every_connection_and_isolates_failures
    ok_conn = { name: "OK" }
    boom_factory = lambda do |conn|
      raise "boom" if conn[:name] == "BROKEN"

      clients_by_name[conn[:name]]
    end

    runner = Clavisco::SapUdfs::MultiCompanySync.new(
      [ok_conn, { name: "BROKEN" }], schemas_path: @dir, client_factory: boom_factory
    )
    results = runner.sync_all

    ok_result = results.find { |r| r.name == "OK" }
    broken_result = results.find { |r| r.name == "BROKEN" }

    assert ok_result.ok
    refute broken_result.ok
    assert_includes broken_result.error, "boom"
    # the failing connection must not have stopped the other one from running
    assert_equal :native, ok_result.data["loyalty_native"][:table]
  end

  def test_all_ok_true_when_every_connection_succeeds_clean
    runner = Clavisco::SapUdfs::MultiCompanySync.new(
      connections("A", "B"), schemas_path: @dir, client_factory: factory
    )
    results = runner.sync_all

    assert Clavisco::SapUdfs::MultiCompanySync.all_ok?(results)
  end

  def test_all_ok_false_when_any_connection_raised
    runner = Clavisco::SapUdfs::MultiCompanySync.new(
      [{ name: "A" }, { name: "BROKEN" }], schemas_path: @dir,
      client_factory: ->(conn) { raise "nope" if conn[:name] == "BROKEN"; clients_by_name[conn[:name]] }
    )
    results = runner.sync_all

    refute Clavisco::SapUdfs::MultiCompanySync.all_ok?(results)
  end

  def test_all_ok_false_when_a_schema_reported_an_error_even_if_connection_ok
    write_schema(@dir, "broken_schema", { "table_name" => "OCRD" }) # missing IsUDT -> validation error

    runner = Clavisco::SapUdfs::MultiCompanySync.new(
      connections("A"), schemas_path: @dir, client_factory: factory
    )
    results = runner.sync_all

    a_result = results.find { |r| r.name == "A" }
    assert a_result.ok, "connection itself didn't raise"
    assert a_result.data["broken_schema"][:error]
    refute Clavisco::SapUdfs::MultiCompanySync.all_ok?(results)
  end

  def test_diff_all_never_writes
    runner = Clavisco::SapUdfs::MultiCompanySync.new(
      connections("A"), schemas_path: @dir, client_factory: factory
    )
    runner.diff_all

    refute clients_by_name["A"].calls(:post).any?
    refute clients_by_name["A"].calls(:patch).any?
  end

  def test_sync_one_only_runs_the_given_schema
    runner = Clavisco::SapUdfs::MultiCompanySync.new(
      connections("A"), schemas_path: @dir, client_factory: factory
    )
    results = runner.sync_one("loyalty_native")

    a_result = results.find { |r| r.name == "A" }
    assert_equal %w[loyalty_native], a_result.data.keys
  end
end
