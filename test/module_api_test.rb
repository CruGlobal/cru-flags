# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"

class ModuleApiTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":true}}}')
  end

  def teardown
    CruFlags.reset!
    ENV.delete("CRU_FLAGS_URL")
    @service.stop
  end

  def test_reads_env_at_first_use_not_at_require
    ENV["CRU_FLAGS_URL"] = @service.url # set AFTER require — must still work
    assert CruFlags.ready(timeout: 2.0)
    assert CruFlags.enabled?("pilot")
    assert_equal "pilot", CruFlags.snapshot.dig("Flags").keys.first
  end

  def test_unset_env_is_inert_and_all_false
    refute CruFlags.enabled?("pilot")
    refute CruFlags.ready(timeout: 0.1)
    assert_equal({}, CruFlags.snapshot)
  end

  def test_whitespace_env_counts_as_unset
    ENV["CRU_FLAGS_URL"] = "   "
    refute CruFlags.enabled?("pilot")
  end

  def test_singleton_is_memoized_and_reset_discards_it
    ENV["CRU_FLAGS_URL"] = @service.url
    first = CruFlags.client
    assert_same first, CruFlags.client
    CruFlags.reset!
    refute_same first, CruFlags.client
  end
end
