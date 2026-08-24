# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"

class ClientBackgroundTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":true}}}', headers: {"ETag" => '"1"'})
  end

  def teardown
    @client&.close
    @service.stop
  end

  def new_client(**opts)
    @client = CruFlags::Client.new(url: @service.url, poll_seconds: 0.2, **opts)
  end

  def test_constructing_starts_no_thread_first_read_does
    before = Thread.list.size
    client = new_client
    assert_equal before, Thread.list.size
    client.enabled?("pilot")
    assert client.ready(timeout: 2.0)
    assert client.enabled?("pilot")
    assert(Thread.list.any? { |t| t.name == "cru-flags-poller" })
  end

  def test_ready_true_after_failed_first_attempt
    @service.respond_with(status: 500, body: "x")
    # on_error: swallow — this test deliberately triggers a failure, and the
    # default on_error would otherwise log it (test_helper's warning-free
    # gate is about Ruby Warning.warn, not stderr logging, but there is no
    # reason for this test to exercise the default logger at all).
    client = new_client(on_error: ->(_e) {})
    assert client.ready(timeout: 2.0), "a completed failed attempt is still completed"
    refute client.enabled?("pilot")
  end

  def test_ready_false_immediately_when_inert
    client = CruFlags::Client.new(url: nil)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refute client.ready(timeout: 5.0)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 1.0
  end

  def test_poller_revalidates_with_etag_on_steady_state
    client = new_client
    client.ready(timeout: 2.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
    sleep 0.05 until @service.requests.size >= 3 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_operator @service.requests.size, :>=, 3, "poller should tick repeatedly"
    assert_equal '"1"', @service.requests.last.headers["if-none-match"]
  end

  def test_picks_up_flag_changes_within_interval
    client = new_client
    client.ready(timeout: 2.0)
    assert client.enabled?("pilot")
    @service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":false}}}', headers: {"ETag" => '"2"'})
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
    sleep 0.05 while client.enabled?("pilot") && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    refute client.enabled?("pilot")
  end

  def test_close_returns_promptly_and_stops_polling
    client = new_client
    client.ready(timeout: 2.0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.close
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.15,
      "close must interrupt the poll sleep, not wait it out"
    count = @service.requests.size
    sleep 0.5
    assert_equal count, @service.requests.size, "no fetches after close"
  end

  def test_dead_poller_self_heals_on_next_read
    client = new_client
    client.ready(timeout: 2.0)
    dead_thread = client.instance_variable_get(:@thread)
    dead_thread.kill
    dead_thread.join(2)
    refute dead_thread.alive?, "precondition: the poller must actually be dead"
    assert client.enabled?("pilot"), "cached snapshot must still read fine through a dead poller"
    new_thread = client.instance_variable_get(:@thread)
    refute_same dead_thread, new_thread, "a read after a dead poller must respawn a new one"
    assert new_thread.alive?
  end

  def test_ready_returns_immediately_when_already_closed
    client = new_client
    client.close
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refute client.ready(timeout: 5.0)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 0.2,
      "an already-closed client must not sit out a wait poll"
  end

  def test_ready_stays_true_after_close_once_completed
    client = new_client
    assert client.ready(timeout: 2.0)
    client.close
    assert client.ready(timeout: 2.0), "closing after completion must not retroactively flip ready"
  end

  def test_concurrent_refresh_calls_share_one_request
    client = new_client
    client.ready(timeout: 2.0)
    baseline = @service.requests.size
    @service.delay = 0.2
    threads = 5.times.map { Thread.new { client.refresh(force: true) } }
    threads.each(&:join)
    assert_operator @service.requests.size - baseline, :<=, 2,
      "a burst of refreshes must coalesce, not stack N requests"
  end
end
