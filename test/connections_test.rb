# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ConnectionsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def write_connections(data)
    path = File.join(@dir, "connections.json")
    File.write(path, JSON.generate(data))
    path
  end

  def test_loads_single_connection
    path = write_connections([
      { "name" => "ACME", "base_url" => "https://sl/", "company_db" => "DB1",
        "username" => "u", "password" => "p" }
    ])

    result = Clavisco::SapUdfs::Connections.load(path)

    assert_equal 1, result.size
    assert_equal({ name: "ACME", base_url: "https://sl/", company_db: "DB1",
                   username: "u", password: "p", session_owner_id: nil }, result.first)
  end

  def test_loads_multiple_connections
    path = write_connections([
      { "base_url" => "https://sl/", "company_db" => "DB1", "username" => "u", "password" => "p" },
      { "base_url" => "https://sl/", "company_db" => "DB2", "username" => "u", "password" => "p" }
    ])

    result = Clavisco::SapUdfs::Connections.load(path)

    assert_equal 2, result.size
    assert_equal %w[DB1 DB2], result.map { |c| c[:name] }
  end

  def test_defaults_name_to_company_db_when_absent
    path = write_connections([
      { "base_url" => "https://sl/", "company_db" => "DB1", "username" => "u", "password" => "p" }
    ])

    result = Clavisco::SapUdfs::Connections.load(path)

    assert_equal "DB1", result.first[:name]
  end

  def test_raises_on_missing_file
    error = assert_raises(RuntimeError) { Clavisco::SapUdfs::Connections.load(File.join(@dir, "nope.json")) }
    assert_includes error.message, "not found"
  end

  def test_raises_when_not_an_array
    path = write_connections({ "base_url" => "https://sl/" })
    error = assert_raises(RuntimeError) { Clavisco::SapUdfs::Connections.load(path) }
    assert_includes error.message, "JSON array"
  end

  def test_raises_when_empty_array
    path = write_connections([])
    error = assert_raises(RuntimeError) { Clavisco::SapUdfs::Connections.load(path) }
    assert_includes error.message, "at least one connection"
  end

  def test_raises_on_missing_required_field
    path = write_connections([{ "base_url" => "https://sl/", "company_db" => "DB1" }])
    error = assert_raises(RuntimeError) { Clavisco::SapUdfs::Connections.load(path) }
    assert_includes error.message, "username"
    assert_includes error.message, "password"
  end
end
