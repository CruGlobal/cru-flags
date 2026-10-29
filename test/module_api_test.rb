# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"

class ModuleApiTest < Minitest::Test
  def setup
    CruFlags.reset!
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

  # close going through the memoizing reader would BUILD the singleton just
  # to close it, leaving a permanently-closed client memoized: every later
  # read answers false and ready never becomes true, in a correctly
  # configured app, because something called close at shutdown.
  def test_close_on_an_unbuilt_singleton_does_not_build_one
    ENV["CRU_FLAGS_URL"] = @service.url
    CruFlags.close
    assert_nil CruFlags.instance_variable_get(:@client),
      "close must not construct the singleton it was asked to close"
    assert CruFlags.ready(timeout: 2.0), "the singleton must still be usable after a no-op close"
    assert CruFlags.enabled?("pilot")
  end

  def test_the_singleton_saves_to_the_configured_fallback_store
    store = Class.new {
      attr_reader :data
      def initialize = @data = {}
      def read(key) = @data[key]
      def write(key, value, **) = @data[key] = value
    }.new
    CruFlags.default_fallback_store = -> { store }
    ENV["CRU_FLAGS_URL"] = @service.url
    assert CruFlags.ready(timeout: 2.0)
    assert_includes store.data.fetch("cru_flags/v1/#{@service.url}"), "pilot"
  ensure
    CruFlags.default_fallback_store = nil
  end

  def test_an_assignment_beats_the_default_in_either_order
    default = Object.new
    CruFlags.fallback_store = nil
    CruFlags.default_fallback_store = -> { default }
    assert_nil CruFlags.fallback_store
    CruFlags.reset!
    assert_same default, CruFlags.fallback_store
    other = Object.new
    CruFlags.fallback_store = other
    assert_same other, CruFlags.fallback_store
  ensure
    CruFlags.default_fallback_store = nil
  end

  def test_the_module_setter_takes_a_proc_like_client_new_does
    store = Class.new {
      attr_reader :data
      def initialize = @data = {}
      def read(key) = @data[key]
      def write(key, value, **) = @data[key] = value
    }.new
    CruFlags.fallback_store = -> { store }
    assert_same store, CruFlags.fallback_store
    ENV["CRU_FLAGS_URL"] = @service.url
    assert CruFlags.ready(timeout: 2.0)
    assert_includes store.data.fetch("cru_flags/v1/#{@service.url}"), "pilot"
  end

  def test_a_singleton_built_before_the_assignment_still_follows_it
    store = Class.new {
      attr_reader :writes
      def initialize = @writes = 0
      def read(_) = nil
      def write(*, **) = @writes += 1
    }.new
    CruFlags.default_fallback_store = -> { store }
    ENV["CRU_FLAGS_URL"] = @service.url
    CruFlags.client # built while the default applies
    CruFlags.fallback_store = nil
    assert CruFlags.ready(timeout: 2.0)
    CruFlags.refresh(force: true)
    assert_equal 0, store.writes
  ensure
    CruFlags.default_fallback_store = nil
  end

  def test_singleton_is_memoized_and_reset_discards_it
    ENV["CRU_FLAGS_URL"] = @service.url
    first = CruFlags.client
    assert_same first, CruFlags.client
    CruFlags.reset!
    refute_same first, CruFlags.client
  end
end
