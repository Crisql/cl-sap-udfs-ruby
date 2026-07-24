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

  def test_does_not_exist_before_first_write
    lock = Clavisco::SapUdfs::Lock.new(@lock_path)
    refute lock.exists?
    assert_equal [], lock.recorded_schemas
  end

  def test_write_then_check_matches
    lock = Clavisco::SapUdfs::Lock.new(@lock_path)
    lock.write!(%w[log_events ocrd_loyalty_points])

    assert lock.exists?
    drift = lock.check(%w[log_events ocrd_loyalty_points])
    assert_equal [], drift[:stale]
    assert_equal [], drift[:pending]
  end

  def test_check_reports_stale_when_schema_removed_from_disk
    lock = Clavisco::SapUdfs::Lock.new(@lock_path)
    lock.write!(%w[log_events ocrd_loyalty_points])

    drift = lock.check(%w[log_events])
    assert_equal %w[ocrd_loyalty_points], drift[:stale]
    assert_equal [], drift[:pending]
  end

  def test_check_reports_pending_when_schema_never_synced
    lock = Clavisco::SapUdfs::Lock.new(@lock_path)
    lock.write!(%w[log_events])

    drift = lock.check(%w[log_events new_schema])
    assert_equal [], drift[:stale]
    assert_equal %w[new_schema], drift[:pending]
  end

  def test_check_with_no_lock_reports_everything_pending
    lock = Clavisco::SapUdfs::Lock.new(@lock_path)

    drift = lock.check(%w[a b])
    assert_equal [], drift[:stale]
    assert_equal %w[a b], drift[:pending]
  end
end
