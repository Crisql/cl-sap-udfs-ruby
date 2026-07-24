# frozen_string_literal: true

require_relative "test_helper"

# Guards config/connections.sample.json — the documented contract shape —
# against silently drifting out of sync with what Connections.load actually
# requires.
class ConnectionsSampleTest < Minitest::Test
  SAMPLE_PATH = File.expand_path("../config/connections.sample.json", __dir__)

  def test_sample_file_parses_as_valid_connections
    result = Clavisco::SapUdfs::Connections.load(SAMPLE_PATH)

    assert_equal 2, result.size
    assert_equal %w[ACME_PROD ACME_PROD_2], result.map { |c| c[:name] }
  end
end
