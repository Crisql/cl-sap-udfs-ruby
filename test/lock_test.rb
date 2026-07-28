# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class LockTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @lock_path = File.join(@dir, "sync.lock")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def lock
    Clavisco::SapUdfs::Lock.new(@lock_path, @dir)
  end

  def write_schema_file(name, content)
    File.write(File.join(@dir, "#{name}.json"), content)
  end

  def test_does_not_exist_before_first_write
    refute lock.exists?
    assert_equal({}, lock.recorded_schemas)
  end

  def test_write_then_check_matches
    write_schema_file("log_events", '{"table_name":"@X"}')
    write_schema_file("ocrd_loyalty_points", '{"table_name":"OCRD"}')
    lock.write!(%w[log_events ocrd_loyalty_points])

    assert lock.exists?
    drift = lock.check(%w[log_events ocrd_loyalty_points])
    assert_equal [], drift[:stale]
    assert_equal [], drift[:pending]
    assert_equal [], drift[:changed]
  end

  def test_check_reports_stale_when_schema_removed_from_disk
    write_schema_file("log_events", '{"table_name":"@X"}')
    write_schema_file("ocrd_loyalty_points", '{"table_name":"OCRD"}')
    lock.write!(%w[log_events ocrd_loyalty_points])

    drift = lock.check(%w[log_events])
    assert_equal %w[ocrd_loyalty_points], drift[:stale]
    assert_equal [], drift[:pending]
    assert_equal [], drift[:changed]
  end

  def test_check_reports_pending_when_schema_never_synced
    write_schema_file("log_events", '{"table_name":"@X"}')
    lock.write!(%w[log_events])
    write_schema_file("new_schema", '{"table_name":"OITM"}')

    drift = lock.check(%w[log_events new_schema])
    assert_equal [], drift[:stale]
    assert_equal %w[new_schema], drift[:pending]
    assert_equal [], drift[:changed]
  end

  def test_check_reports_changed_when_synced_schema_is_edited_afterwards
    write_schema_file("log_events", '{"table_name":"@X","columns":[]}')
    lock.write!(%w[log_events])

    # Edited after the sync — no file added/removed, only content changed.
    write_schema_file("log_events", '{"table_name":"@X","columns":[{"Name":"New"}]}')

    drift = lock.check(%w[log_events])
    assert_equal [], drift[:stale]
    assert_equal [], drift[:pending]
    assert_equal %w[log_events], drift[:changed]
  end

  def test_check_with_no_lock_reports_everything_pending
    write_schema_file("a", "{}")
    write_schema_file("b", "{}")

    drift = lock.check(%w[a b])
    assert_equal [], drift[:stale]
    assert_equal %w[a b], drift[:pending]
    assert_equal [], drift[:changed]
  end

  def test_tolerates_old_name_only_lock_format_by_reporting_changed
    File.write(@lock_path, JSON.generate("synced_at" => Time.now.utc.iso8601, "schemas" => ["log_events"]))
    write_schema_file("log_events", '{"table_name":"@X"}')

    drift = lock.check(%w[log_events])
    assert_equal [], drift[:stale]
    assert_equal [], drift[:pending]
    assert_equal %w[log_events], drift[:changed]
  end
end
