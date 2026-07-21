# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SchemaSyncServiceTest < Minitest::Test
  def setup
    @client = MockSLClient.new
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def service
    Clavisco::SapUdfs::SchemaSyncService.new(@client, schemas_path: @dir)
  end

  # --- UDT behavior (retrocompatibilidad) ---

  def test_udt_schema_creates_table_and_field_when_missing
    write_schema(@dir, "loyalty_udt", {
      "table_name" => "CL_TEST",
      "table_description" => "Test UDT",
      "table_type" => "bott_NoObject",
      "columns" => [
        { "Name" => "Points", "Description" => "Loyalty points", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    result = service.sync("loyalty_udt")

    assert_equal :created, result[:table]
    assert_equal 1, @client.calls(:create_udt).size
    assert_equal "CL_TEST", @client.calls(:create_udt).first.args[0]

    assert_equal 1, @client.calls(:create_udf).size
    create_udf_call = @client.calls(:create_udf).first
    assert_equal "CL_TEST", create_udf_call.args[0], "create_udf should receive the bare table name, same as before this change"

    get_call = @client.calls(:get).first
    assert_includes get_call.kwargs[:params]["$filter"], "@CL_TEST",
                     "UDF lookup for a UDT must still query with the '@' prefix"
  end

  def test_udt_schema_skips_create_udt_when_table_already_exists
    @client.stub_udt_exists("CL_TEST", true)
    write_schema(@dir, "loyalty_udt", {
      "table_name" => "CL_TEST",
      "table_description" => "Test UDT",
      "columns" => [
        { "Name" => "Points", "Description" => "Loyalty points", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    result = service.sync("loyalty_udt")

    assert_equal :exists, result[:table]
    assert_empty @client.calls(:create_udt)
  end

  # --- native_table behavior (nuevo) ---

  def test_native_table_never_creates_udt_and_uses_bare_name
    write_schema(@dir, "loyalty_native", {
      "table_name" => "OCRD",
      "IsUDT" => false,
      "columns" => [
        { "Name" => "LoyaltyPoints", "Description" => "Puntos de lealtad", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    result = service.sync("loyalty_native")

    assert_equal :native, result[:table]
    assert_empty @client.calls(:udt_exists?), "native_table schemas must never call udt_exists?"
    assert_empty @client.calls(:create_udt), "native_table schemas must never call create_udt"

    create_udf_call = @client.calls(:create_udf).first
    assert_equal "OCRD", create_udf_call.args[0], "create_udf must receive the real table name, without '@'"

    get_call = @client.calls(:get).first
    refute_includes get_call.kwargs[:params]["$filter"], "@OCRD"
    assert_includes get_call.kwargs[:params]["$filter"], "TableName eq 'OCRD'"

    assert_equal [{ name: "LoyaltyPoints", action: :created }], result[:columns]
  end

  def test_native_table_updates_existing_udf_without_creating_table
    @client.stub_udf("OCRD", "LoyaltyPoints", {
      "TableName" => "OCRD", "FieldID" => 5, "Description" => "Old description",
      "Type" => "db_Numeric", "Mandatory" => "tNO"
    })
    write_schema(@dir, "loyalty_native", {
      "table_name" => "OCRD",
      "IsUDT" => false,
      "columns" => [
        { "Name" => "LoyaltyPoints", "Description" => "Puntos de lealtad", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    result = service.sync("loyalty_native")

    assert_equal :native, result[:table]
    assert_empty @client.calls(:create_udt)
    assert_empty @client.calls(:create_udf), "field already exists — should update, not create"
    assert_equal 1, @client.calls(:patch).size

    col_result = result[:columns].first
    assert_equal :updated, col_result[:action]
    assert_equal "OCRD(TableName='OCRD',FieldID=5)".sub("OCRD(", "UserFieldsMD("), @client.calls(:patch).first.args[0]
  end

  def test_diff_reports_native_instead_of_will_create
    write_schema(@dir, "loyalty_native", {
      "table_name" => "OCRD",
      "IsUDT" => false,
      "columns" => [
        { "Name" => "LoyaltyPoints", "Description" => "Puntos de lealtad", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    changes = service.diff("loyalty_native")

    assert_equal :native, changes[:table]
    assert_empty @client.calls(:udt_exists?)
    assert_equal [{ name: "LoyaltyPoints", action: :will_create }], changes[:columns]
  end

  # --- validation ---

  def test_validation_does_not_require_table_description_for_native_table
    write_schema(@dir, "loyalty_native", {
      "table_name" => "OCRD",
      "IsUDT" => false,
      "columns" => [
        { "Name" => "LoyaltyPoints", "Description" => "Puntos de lealtad", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    # Should not raise even though table_description/table_type are absent.
    result = service.sync("loyalty_native")
    assert_equal :native, result[:table]
  end

  def test_validation_still_requires_table_description_for_udt
    write_schema(@dir, "no_description", {
      "table_name" => "CL_TEST",
      "columns" => [
        { "Name" => "Points", "Description" => "Loyalty points", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    error = assert_raises(RuntimeError) { service.sync("no_description") }
    assert_includes error.message, "table_description is required"
  end
end
