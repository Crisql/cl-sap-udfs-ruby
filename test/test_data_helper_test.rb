# frozen_string_literal: true

require_relative "test_helper"

class TestDataHelperTest < Minitest::Test
  def setup
    @client = MockSLClient.new
    @helper = Clavisco::SapUdfs::TestDataHelper.new(@client)
  end

  def test_udt_data_resource_adds_u_prefix_and_strips_at
    assert_equal "U_CL_TEST", @helper.udt_data_resource("CL_TEST")
    assert_equal "U_CL_TEST", @helper.udt_data_resource("@CL_TEST")
    assert_equal "U_CL_TEST", @helper.udt_data_resource("U_CL_TEST")
  end

  def test_insert_row_prefixes_user_fields_and_leaves_system_fields
    @helper.insert_row("CL_TEST", "Points" => 10, "Code" => "ROW1")

    post = @client.calls(:post).first
    assert_equal "U_CL_TEST", post.args[0]
    assert_equal 10, post.kwargs[:body]["U_Points"]
    assert_equal "ROW1", post.kwargs[:body]["Code"]
  end

  def test_insert_row_generates_code_and_name_when_absent
    @helper.insert_row("CL_TEST", "Points" => 10)

    body = @client.calls(:post).first.kwargs[:body]
    refute_nil body["Code"]
    assert_equal body["Code"], body["Name"]
  end

  def test_query_builds_odata_params
    @helper.query("CL_TEST", filter: "U_Points eq 5", top: 10)

    get = @client.calls(:get).first
    assert_equal "U_CL_TEST", get.args[0]
    assert_equal "U_Points eq 5", get.kwargs[:params]["$filter"]
    assert_equal 10, get.kwargs[:params]["$top"]
  end
end
