# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"
require "json"
require "active_support"
require "active_support/cache"
require "active_support/testing/time_helpers"

# Design doc §6.1: the cross-process fallback copy.
class ClientFallbackTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  # The read/write surface the client uses, recording calls, with switches to
  # make either side blow up.
  class FakeStore
    attr_reader :data, :writes, :reads
    attr_accessor :fail_reads, :fail_writes

    def initialize
      @data = {}
      @writes = []
      @reads = 0
    end

    def read(key)
      @reads += 1
      raise "store read down" if fail_reads
      @data[key]
    end

    def write(key, value, **options)
      raise "store write down" if fail_writes
      @writes << [key, value, options]
      @data[key] = value
      true
    end
  end

  def setup
    @service = FlagService.new.start
    @store = FakeStore.new
    @clients = []
  end

  def teardown
    @clients.each(&:close)
    @service.stop
  end

  def client(store: @store)
    CruFlags::Client.new(url: @service.url, on_error: ->(_) {}, fallback_store: store).tap { @clients << _1 }
  end

  def serve(body, etag: nil)
    @service.respond_with(status: 200, body:, headers: etag ? {"ETag" => etag} : {})
  end

  def key = "cru_flags/v1/#{@service.url}"

  def test_a_successful_fetch_saves_the_document_with_no_expiry
    serve('{"Version":3,"Flags":{"pilot":{"Enabled":true}}}')
    assert client.refresh(force: true)
    stored_key, value, options = @store.writes.last
    assert_equal key, stored_key
    assert_equal({"Version" => 3, "Flags" => {"pilot" => {"Enabled" => true}}}, JSON.parse(value))
    assert_equal({expires_in: nil}, options)
  end

  def test_every_successful_tick_rewrites_the_copy_so_an_evicted_key_comes_back
    serve('{"Flags":{"pilot":{"Enabled":true}}}', etag: '"1"')
    c = client
    c.refresh(force: true)
    @store.data.clear
    @service.respond_with(status: 304)
    c.refresh(force: true)
    assert_equal 2, @store.writes.size
    assert_includes @store.data.fetch(key), "pilot"
  end

  def test_a_process_that_boots_during_an_outage_serves_the_shared_copy
    serve('{"Flags":{"pilot":{"Enabled":true}}}')
    client.refresh(force: true)
    @service.respond_with(status: 503, body: "down")
    cold = client
    refute cold.refresh(force: true), "the fetch itself still failed"
    assert cold.enabled?("pilot")
  end

  def test_a_process_holding_a_document_never_reads_the_shared_copy
    serve('{"Flags":{"pilot":{"Enabled":true}}}')
    warm = client
    warm.refresh(force: true)
    @store.data[key] = '{"Flags":{"pilot":{"Enabled":false}}}'
    @service.respond_with(status: 500, body: "x")
    3.times { warm.refresh(force: true) }
    assert warm.enabled?("pilot")
    assert_equal 0, @store.reads
  end

  def test_the_shared_copy_is_read_only_until_one_is_found
    @service.respond_with(status: 500, body: "x")
    c = client
    c.refresh(force: true)
    assert_equal 1, @store.reads
    @store.data[key] = '{"Flags":{"pilot":{"Enabled":true}}}'
    c.refresh(force: true)
    assert c.enabled?("pilot")
    c.refresh(force: true)
    assert_equal 2, @store.reads
  end

  def test_a_404_saves_the_empty_document
    @service.respond_with(status: 404)
    client.refresh(force: true)
    assert_equal({"Flags" => {}}, JSON.parse(@store.data.fetch(key)))
  end

  def test_a_restored_copy_sends_no_etag_so_recovery_fetches_a_full_document
    @store.data[key] = '{"Flags":{"pilot":{"Enabled":true}}}'
    @service.respond_with(status: 500, body: "x")
    c = client
    c.refresh(force: true)
    serve('{"Flags":{}}')
    c.refresh(force: true)
    refute_includes @service.requests.last.headers.keys, "if-none-match"
    refute c.enabled?("pilot"), "the live document replaces the restored copy"
  end

  def test_the_restored_copy_is_frozen_like_a_fetched_one
    @store.data[key] = '{"Flags":{"pilot":{"Enabled":true}}}'
    @service.respond_with(status: 500, body: "x")
    c = client
    c.refresh(force: true)
    assert_raises(FrozenError) { c.flags_for_adapter["pilot"] = {} }
  end

  def test_garbage_in_the_store_is_ignored
    @service.respond_with(status: 500, body: "x")
    ["not json", "[1,2]", '{"Flags":"nope"}', 42, {"Flags" => {"pilot" => {"Enabled" => true}}}].each do |junk|
      @store.data[key] = junk
      c = client
      c.refresh(force: true)
      refute c.enabled?("pilot"), "#{junk.inspect} must not be served"
      assert_equal({}, c.snapshot)
    end
  end

  def test_a_failing_store_never_escapes
    @store.fail_reads = true
    @store.fail_writes = true
    serve('{"Flags":{"pilot":{"Enabled":true}}}')
    c = client
    assert c.refresh(force: true)
    assert c.enabled?("pilot")
    @service.respond_with(status: 500, body: "x")
    cold = client
    refute cold.refresh(force: true)
    refute cold.enabled?("pilot")
  end

  def test_a_raising_store_read_still_reports_the_outage
    @store.fail_reads = true
    @service.respond_with(status: 500, body: "x")
    errors = []
    c = CruFlags::Client.new(url: @service.url, on_error: ->(e) { errors << e }, fallback_store: @store)
    @clients << c
    c.refresh(force: true)
    assert_equal 1, errors.size
    assert_kind_of CruFlags::FetchError, errors.first
  end

  def test_a_proc_store_is_resolved_on_every_use
    current = nil
    c = client(store: -> { current })
    serve('{"Flags":{"pilot":{"Enabled":true}}}')
    c.refresh(force: true)
    assert_empty @store.writes
    current = @store
    c.refresh(force: true)
    assert_equal 1, @store.writes.size
  end

  def test_on_demand_mode_restores_on_the_reading_thread
    @store.data[key] = '{"Flags":{"pilot":{"Enabled":true}}}'
    @service.respond_with(status: 500, body: "x")
    c = CruFlags::Client.new(url: @service.url, on_error: ->(_) {}, fallback_store: @store,
      refresh_mode: "on-demand")
    @clients << c
    assert c.enabled?("pilot")
  end

  def test_copies_are_keyed_by_url_so_environments_never_mix
    serve('{"Flags":{"pilot":{"Enabled":true}}}')
    client.refresh(force: true)
    @service.respond_with(status: 500, body: "x")
    other = CruFlags::Client.new(url: @service.url.sub("/production", "/staging"),
      on_error: ->(_) {}, fallback_store: @store).tap { @clients << _1 }
    other.refresh(force: true)
    refute other.enabled?("pilot")
  end

  def test_without_a_store_a_cold_outage_still_reads_all_off
    @service.respond_with(status: 500, body: "x")
    c = client(store: nil)
    c.refresh(force: true)
    refute c.enabled?("pilot")
  end

  def test_background_mode_restores_without_any_explicit_refresh
    @store.data[key] = '{"Flags":{"pilot":{"Enabled":true}}}'
    @service.respond_with(status: 500, body: "x")
    c = client
    assert c.ready(timeout: 2.0)
    assert c.enabled?("pilot")
  end

  # The real store most apps pass (via the Railtie): a store-wide default
  # TTL must not apply to the copy.
  def test_an_active_support_store_keeps_the_copy_past_its_default_ttl
    store = ActiveSupport::Cache::MemoryStore.new(expires_in: 60)
    serve('{"Flags":{"pilot":{"Enabled":true}}}')
    client(store:).refresh(force: true)
    travel(86_400) do
      @service.respond_with(status: 500, body: "x")
      cold = client(store:)
      cold.refresh(force: true)
      assert cold.enabled?("pilot")
    end
  end
end
