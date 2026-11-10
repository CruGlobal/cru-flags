# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"

class ClientCoreTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @errors = []
    @client = CruFlags::Client.new(url: @service.url, on_error: ->(e) { @errors << e })
  end

  def teardown
    @client.close
    @service.stop
  end

  def serve(body, etag: nil)
    headers = etag ? {"ETag" => etag} : {}
    @service.respond_with(status: 200, body:, headers:)
  end

  def test_enabled_is_false_before_any_fetch_and_never_raises
    refute @client.enabled?("anything")
    refute @client.enabled?(nil) # hostile input answers false, not raise
  end

  def test_refresh_publishes_document_and_enabled_reads_it
    serve('{"Flags":{"pilot":{"Enabled":true},"off":{"Enabled":false}}}', etag: '"1"')
    assert @client.refresh(force: true)
    assert @client.enabled?("pilot")
    assert @client.enabled?(:pilot) # symbols accepted
    refute @client.enabled?("off")
    refute @client.enabled?("stringly") # absent
  end

  def test_malformed_enabled_values_read_false
    serve('{"Flags":{"a":{"Enabled":"true"},"b":{"Enabled":1},"c":{"Enabled":null}}}')
    @client.refresh(force: true)
    %w[a b c].each { |name| refute @client.enabled?(name) }
  end

  def test_failure_keeps_last_known_good_indefinitely
    serve('{"Flags":{"pilot":{"Enabled":true}}}', etag: '"1"')
    @client.refresh(force: true)
    @service.respond_with(status: 500, body: "boom")
    5.times { @client.refresh(force: true) }
    assert @client.enabled?("pilot"), "outage must not turn flags off (no TTL)"
  end

  def test_health_transitions_fire_once_each_way_and_never_for_404_or_304
    serve('{"Flags":{}}', etag: '"1"')
    @client.refresh(force: true)
    @service.respond_with(status: 304)
    @client.refresh(force: true)
    @service.respond_with(status: 404)
    @client.refresh(force: true)
    assert_empty @errors
    @service.respond_with(status: 500, body: "x")
    3.times { @client.refresh(force: true) }
    assert_equal 1, @errors.size
    assert_kind_of CruFlags::FetchError, @errors.first
    serve('{"Flags":{}}')
    @client.refresh(force: true)
    assert_equal [@errors.first, nil], @errors
  end

  def test_404_publishes_empty_and_clears_etag
    serve('{"Flags":{"pilot":{"Enabled":true}}}', etag: '"7"')
    @client.refresh(force: true)
    @service.respond_with(status: 404)
    @client.refresh(force: true)
    refute @client.enabled?("pilot")
    serve('{"Flags":{}}')
    @client.refresh(force: true)
    refute_includes @service.requests.last.headers.keys, "if-none-match",
      "404 must clear the stored ETag so a reappearing document is fetched fresh"
  end

  def test_flags_for_adapter_after_404_is_frozen
    serve('{"Flags":{"pilot":{"Enabled":true}}}', etag: '"1"')
    @client.refresh(force: true)
    @service.respond_with(status: 404)
    @client.refresh(force: true)
    flags = @client.flags_for_adapter
    assert_empty flags
    assert_raises(FrozenError) { flags["pilot"] = {"Enabled" => true} }
  end

  def test_snapshot_is_a_thawed_json_roundtrippable_copy
    serve('{"Version":3,"Flags":{"pilot":{"Enabled":true}}}')
    @client.refresh(force: true)
    snap = @client.snapshot
    refute_predicate snap, :frozen?
    snap["Flags"]["pilot"]["Enabled"] = false # mutating the copy...
    assert @client.enabled?("pilot") # ...cannot touch library state
  end

  def test_refresh_without_force_is_a_noop_while_fresh
    serve('{"Flags":{}}')
    @client.refresh(force: true)
    @client.refresh
    assert_equal 1, @service.requests.size
  end

  def test_close_is_terminal
    serve('{"Flags":{"pilot":{"Enabled":true}}}')
    @client.refresh(force: true)
    @client.close
    @service.respond_with(status: 200, body: '{"Flags":{}}')
    @client.refresh(force: true)
    assert_equal 1, @service.requests.size, "closed client must not fetch"
    assert @client.enabled?("pilot"), "last snapshot stays readable"
  end

  def test_non_http_url_is_inert_with_one_warning
    client = CruFlags::Client.new(url: "file:///etc/passwd", on_error: ->(e) { @errors << e })
    assert client.inert?
    refute client.enabled?("x")
    client.close
    assert_equal 1, @errors.size
  end

  def test_no_host_url_is_inert_with_one_warning
    client = CruFlags::Client.new(url: "http:///flags", on_error: ->(e) { @errors << e })
    assert client.inert?
    refute client.enabled?("x")
    client.close
    assert_equal 1, @errors.size
  end

  def test_junk_poll_seconds_and_fetch_timeout_fall_back_to_defaults
    # positive() is a private constructor-time validator (design doc §1: an
    # application must still boot on misconfiguration, so junk numeric
    # options fall back silently rather than raising). It has no externally
    # observable effect beyond which value gets stored, so reading the ivars
    # directly is the simplest faithful way to pin it.
    [0, -1, "x", Float::INFINITY].each do |junk|
      client = CruFlags::Client.new(url: @service.url, poll_seconds: junk, fetch_timeout: junk)
      assert_equal 30.0, client.instance_variable_get(:@poll_seconds), "poll_seconds=#{junk.inspect}"
      assert_equal 2.0, client.instance_variable_get(:@fetch_timeout), "fetch_timeout=#{junk.inspect}"
      client.close
    end
  end

  def test_valid_poll_seconds_and_fetch_timeout_are_used
    client = CruFlags::Client.new(url: @service.url, poll_seconds: 5.0, fetch_timeout: 1.5)
    assert_equal 5.0, client.instance_variable_get(:@poll_seconds)
    assert_equal 1.5, client.instance_variable_get(:@fetch_timeout)
    client.close
  end

  # Design doc §3 documents the constructor as `url: nil -> read
  # CRU_FLAGS_URL on first use`. A directly-constructed Client that ignored
  # the env var would be permanently inert with no signal at all: every flag
  # silently false in an app that is configured correctly.
  def test_nil_url_falls_back_to_the_env_var
    ENV["CRU_FLAGS_URL"] = @service.url
    @service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":true}}}')
    client = CruFlags::Client.new(url: nil, on_error: ->(e) { @errors << e })
    refute_predicate client, :inert?
    assert client.ready(timeout: 2.0)
    assert client.enabled?("pilot")
    client.close
  ensure
    ENV.delete("CRU_FLAGS_URL")
  end

  def test_nil_url_with_unset_env_stays_inert
    ENV.delete("CRU_FLAGS_URL")
    client = CruFlags::Client.new(url: nil, on_error: ->(e) { @errors << e })
    assert_predicate client, :inert?
    refute client.enabled?("pilot")
    assert_empty @errors, "an unset env var is normal, not an error"
    client.close
  end

  def test_nil_url_with_whitespace_only_env_stays_inert
    ENV["CRU_FLAGS_URL"] = "   "
    client = CruFlags::Client.new(url: nil, on_error: ->(e) { @errors << e })
    assert_predicate client, :inert?
    client.close
  ensure
    ENV.delete("CRU_FLAGS_URL")
  end

  # An explicit url: wins over the environment, so a caller that constructs
  # its own Client can still point it somewhere else.
  def test_explicit_url_wins_over_the_env_var
    ENV["CRU_FLAGS_URL"] = "http://127.0.0.1:1/never"
    client = CruFlags::Client.new(url: @service.url, on_error: ->(e) { @errors << e })
    serve('{"Flags":{"pilot":{"Enabled":true}}}')
    assert client.refresh(force: true)
    assert client.enabled?("pilot")
    client.close
  ensure
    ENV.delete("CRU_FLAGS_URL")
  end

  def test_broken_on_error_handler_is_swallowed
    client = CruFlags::Client.new(url: @service.url, on_error: ->(_e) { raise "handler bug" })
    @service.respond_with(status: 500, body: "x")
    refute client.refresh(force: true) # must not raise, and must report the failed fetch
    client.close
  end
end
