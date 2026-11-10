# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "timeout"
require "cru_flags"

class ClientOnDemandTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":true}}}', headers: {"ETag" => '"1"'})
  end

  def teardown
    @client&.close
    @service.stop
  end

  def new_client(**opts)
    @client = CruFlags::Client.new(url: @service.url, poll_seconds: 0.2, refresh_mode: "on-demand", **opts)
  end

  def test_no_thread_ever_and_first_read_fetches
    # net/http wraps its TCP connect in Timeout.timeout whenever TCPSocket
    # lacks open_timeout: support (true for the stdlib default net-http), and
    # the timeout library spawns its process-global "Timeout stdlib thread" on
    # first use. Warm that lazy singleton so the count below measures OUR
    # client and not whichever test happened to touch Timeout first.
    Timeout.timeout(1) { 1 }
    before = Thread.list.size
    client = new_client
    assert client.enabled?("pilot"), "first read performs the fetch"
    assert_equal before, Thread.list.size
    assert(Thread.list.none? { |t| t.name == "cru-flags-poller" })
  end

  def test_reads_within_interval_do_not_refetch
    client = new_client
    client.enabled?("pilot")
    10.times { client.enabled?("pilot") }
    assert_equal 1, @service.requests.size
  end

  def test_staleness_anchors_on_attempt_while_service_down
    @service.respond_with(status: 500, body: "x")
    # on_error: swallow — see the matching comment in client_background_test.rb.
    client = new_client(on_error: ->(_e) {})
    20.times { client.enabled?("pilot") }
    assert_operator @service.requests.size, :<=, 2,
      "a dead service costs one failed request per interval, not one per read"
  end

  def test_concurrent_first_reads_share_one_fetch
    @service.delay = 0.2
    client = new_client
    threads = 8.times.map { Thread.new { client.enabled?("pilot") } }
    results = threads.map(&:value)
    assert_equal 1, @service.requests.size
    assert results.all?, "every coalesced reader sees the fetched document"
  end

  def test_ready_performs_the_attempt
    client = new_client
    assert client.ready(timeout: 0.01), "timeout: is unused in on-demand mode"
    assert_equal 1, @service.requests.size
  end

  def test_unrecognized_env_value_warns_and_falls_back_to_background
    errors = []
    ENV["CRU_FLAGS_REFRESH_MODE"] = "sometimes"
    client = CruFlags::Client.new(url: @service.url, poll_seconds: 0.2, on_error: ->(e) { errors << e })
    client.ready(timeout: 2.0)
    assert(Thread.list.any? { |t| t.name == "cru-flags-poller" }, "fell back to background")
    assert_equal 1, errors.compact.size
    client.close
  ensure
    ENV.delete("CRU_FLAGS_REFRESH_MODE")
  end

  def test_unrecognized_constructor_value_raises
    assert_raises(ArgumentError) { CruFlags::Client.new(url: @service.url, refresh_mode: "sometimes") }
  end
end
