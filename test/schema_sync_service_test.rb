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

  # --- UDT behavior ---
  # table_name must already carry the "@" prefix — the developer writes it,
  # SchemaSyncService only validates and passes it through.

  def test_udt_schema_creates_table_and_field_when_missing
    write_schema(@dir, "loyalty_udt", {
      "table_name" => "@CL_TEST",
      "IsUDT" => true,
      "table_description" => "Test UDT",
      "table_type" => "bott_NoObject",
      "columns" => [
        { "Name" => "Points", "Description" => "Loyalty points", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    result = service.sync("loyalty_udt")

    assert_equal :created, result[:table]

    # UserTablesMD existence check + create both use the bare name (no "@")
    table_get = @client.calls(:get).find { |c| c.args[0].start_with?("UserTablesMD") }
    assert_equal "UserTablesMD('CL_TEST')", table_get.args[0]

    table_post = @client.calls(:post).find { |c| c.args[0] == "UserTablesMD" }
    refute_nil table_post, "expected a POST UserTablesMD to create the table"
    assert_equal "CL_TEST", table_post.kwargs[:body][:TableName]
    assert_equal "Test UDT", table_post.kwargs[:body][:TableDescription]

    # UserFieldsMD create uses the "@"-prefixed name exactly as written in the schema
    udf_post = @client.calls(:post).find { |c| c.args[0] == "UserFieldsMD" }
    refute_nil udf_post
    assert_equal "@CL_TEST", udf_post.kwargs[:body][:TableName]

    udf_get = @client.calls(:get).find { |c| c.args[0] == "UserFieldsMD" }
    assert_includes udf_get.kwargs[:params]["$filter"], "@CL_TEST"
  end

  def test_udt_schema_skips_create_when_table_already_exists
    @client.stub_table_exists("CL_TEST", true)
    write_schema(@dir, "loyalty_udt", {
      "table_name" => "@CL_TEST",
      "IsUDT" => true,
      "table_description" => "Test UDT",
      "columns" => [
        { "Name" => "Points", "Description" => "Loyalty points", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    result = service.sync("loyalty_udt")

    assert_equal :exists, result[:table]
    refute @client.calls(:post).any? { |c| c.args[0] == "UserTablesMD" }, "must not try to create an existing UDT"
  end

  # --- native table behavior ---
  # table_name must NOT carry "@" — SchemaSyncService never creates the table
  # and never touches udt_exists?/create_udt equivalents.

  def test_native_table_never_checks_or_creates_table_and_uses_bare_name
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
    refute @client.calls(:get).any? { |c| c.args[0].start_with?("UserTablesMD") },
           "native schemas must never check table existence"
    refute @client.calls(:post).any? { |c| c.args[0] == "UserTablesMD" },
           "native schemas must never create a table"

    udf_post = @client.calls(:post).find { |c| c.args[0] == "UserFieldsMD" }
    refute_nil udf_post
    assert_equal "OCRD", udf_post.kwargs[:body][:TableName], "must use the real table name, without '@'"

    udf_get = @client.calls(:get).find { |c| c.args[0] == "UserFieldsMD" }
    refute_includes udf_get.kwargs[:params]["$filter"], "@OCRD"
    assert_includes udf_get.kwargs[:params]["$filter"], "TableName eq 'OCRD'"

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
    refute @client.calls(:post).any? { |c| c.args[0] == "UserTablesMD" }
    refute @client.calls(:post).any? { |c| c.args[0] == "UserFieldsMD" }, "field already exists — should update, not create"
    assert_equal 1, @client.calls(:patch).size

    col_result = result[:columns].first
    assert_equal :updated, col_result[:action]
    assert_equal "UserFieldsMD(TableName='OCRD',FieldID=5)", @client.calls(:patch).first.args[0]
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
    refute @client.calls(:get).any? { |c| c.args[0].start_with?("UserTablesMD") }
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
      "table_name" => "@CL_TEST",
      "IsUDT" => true,
      "columns" => [
        { "Name" => "Points", "Description" => "Loyalty points", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    error = assert_raises(RuntimeError) { service.sync("no_description") }
    assert_includes error.message, "table_description is required"
  end

  def test_validation_rejects_udt_schema_without_at_prefix
    write_schema(@dir, "missing_at", {
      "table_name" => "CL_TEST",
      "IsUDT" => true,
      "table_description" => "Test UDT",
      "columns" => [
        { "Name" => "Points", "Description" => "Loyalty points", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    error = assert_raises(RuntimeError) { service.sync("missing_at") }
    assert_includes error.message, "table_name must start with '@'"
  end

  def test_validation_rejects_native_schema_with_at_prefix
    write_schema(@dir, "extra_at", {
      "table_name" => "@OCRD",
      "IsUDT" => false,
      "columns" => [
        { "Name" => "LoyaltyPoints", "Description" => "Puntos de lealtad", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    error = assert_raises(RuntimeError) { service.sync("extra_at") }
    assert_includes error.message, "must NOT start with '@'"
  end
  def test_validation_requires_isudt_key
    write_schema(@dir, "no_isudt", {
      "table_name" => "@CL_TEST",
      "table_description" => "Test UDT",
      "columns" => [
        { "Name" => "Points", "Description" => "Loyalty points", "Type" => "db_Numeric",
          "SubType" => "st_None", "Mandatory" => "tNO" }
      ]
    })

    error = assert_raises(RuntimeError) { service.sync("no_isudt") }
    assert_includes error.message, "IsUDT is required"
  end
end
