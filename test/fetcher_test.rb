# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"
require "json"

class FetcherTest < Minitest::Test
  def setup
    @service = FlagService.new.start
  end

  def teardown
    @service.stop
  end

  def fetch(etag: nil, timeout: 2.0)
    CruFlags::Fetcher.call(url: @service.url, etag:, timeout:)
  end

  def test_200_returns_document_and_etag_and_sends_headers
    @service.respond_with(status: 200, body: '{"Version":1,"Flags":{}}', headers: {"ETag" => '"1"'})
    outcome = fetch(etag: '"0"')
    assert_equal :document, outcome.kind
    assert_equal '"1"', outcome.etag
    assert_equal 1, outcome.document["Version"]
    headers = @service.requests.last.headers
    assert_equal '"0"', headers["if-none-match"]
    assert_equal "application/json", headers["accept"]
    assert_equal "cru-flags-ruby/#{CruFlags::VERSION}", headers["user-agent"]
  end

  def test_no_if_none_match_header_without_stored_etag
    @service.respond_with(status: 200, body: '{"Flags":{}}')
    fetch
    refute_includes @service.requests.last.headers.keys, "if-none-match"
  end

  def test_304_is_not_modified
    @service.respond_with(status: 304)
    assert_equal :not_modified, fetch(etag: '"1"').kind
  end

  def test_404_is_missing_not_failed
    @service.respond_with(status: 404, body: '{"message":"no flags yet"}')
    assert_equal :missing, fetch.kind
  end

  def test_http_error_carries_status_and_body_excerpt
    @service.respond_with(status: 400, body: '{"message":"\"staging\" has no feature flags"}')
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :http, outcome.error.code
    assert_equal 400, outcome.error.status
    assert_includes outcome.error.message, "staging"
  end

  def test_timeout_is_failed_with_timeout_code
    @service.respond_with(status: 200, body: '{"Flags":{}}')
    @service.delay = 0.5
    outcome = fetch(timeout: 0.1)
    assert_equal :failed, outcome.kind
    assert_equal :timeout, outcome.error.code
  end

  def test_connection_refused_is_network
    @service.stop
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :network, outcome.error.code
  end

  def test_malformed_body_is_parse_failure
    @service.respond_with(status: 200, body: "not json")
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :parse, outcome.error.code
  end

  def test_follows_redirects_to_limit_three
    hops = 0
    @service.respond do |req|
      if req.path == "/flags/test/production" || hops < 2
        hops += 1
        [302, {"Location" => "/hop#{hops}"}, nil]
      else
        [200, {}, '{"Version":9,"Flags":{}}']
      end
    end
    assert_equal :document, fetch.kind
  end

  def test_fourth_redirect_fails
    @service.respond { |_req| [302, {"Location" => "/loop"}, nil] }
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :http, outcome.error.code
  end

  def test_malformed_redirect_location_is_failed_not_raised
    @service.respond { |_req| [302, {"Location" => "/bad path with spaces"}, nil] }
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :network, outcome.error.code
  end

  def test_redirect_to_non_http_scheme_is_failed
    @service.respond { |_req| [302, {"Location" => "ftp://example.com/flags"}, nil] }
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :network, outcome.error.code
  end

  def test_redirect_to_hostless_url_is_failed
    @service.respond { |_req| [302, {"Location" => "http:///flags"}, nil] }
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :network, outcome.error.code
  end

  # URI#host keeps the brackets an IPv6 literal must carry inside a URL
  # ("[::1]"), and getaddrinfo cannot resolve that — a CRU_FLAGS_URL pointing
  # at an IPv6 address would fail every tick as a :network error. URI#hostname
  # is the unbracketed form Net::HTTP wants.
  def test_ipv6_literal_url_is_fetched_not_a_network_error
    service = begin
      FlagService.new(host: "::1").start
    rescue SocketError, SystemCallError => e
      skip "IPv6 loopback is not bindable in this environment (#{e.class}: #{e.message})"
    end
    service.respond_with(status: 200, body: '{"Version":6,"Flags":{}}')
    outcome = CruFlags::Fetcher.call(url: service.url, timeout: 2.0)
    assert_equal :document, outcome.kind, "IPv6 fetch failed: #{outcome.error&.message}"
    assert_equal 6, outcome.document["Version"]
  ensure
    service&.stop
  end

  def test_a_failed_tick_issues_exactly_one_request
    # Design doc §8: "No retries within a tick — the next tick is the retry."
    # Net::HTTP's own max_retries defaults to 1 and silently re-issues a
    # failed idempotent GET, which both doubles the blocking bound and
    # doubles the load a struggling flag service sees.
    @service.respond { |_req| raise IOError, "simulated mid-request failure" }
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal 1, @service.requests.size,
      "a failed fetch must not be retried inside the same tick"
  end

  def test_oversized_body_is_failed
    # A valid-JSON body that merely exceeds MAX_BODY_BYTES: proves the size
    # cap itself trips the failure, not a coincidental parse error.
    huge = '{"Flags":{}}' + (" " * (CruFlags::Fetcher::MAX_BODY_BYTES + 1))
    @service.respond_with(status: 200, body: huge)
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :parse, outcome.error.code
  end

  # The 1 MiB cap has to be enforced WHILE reading, not after: a check that
  # runs on an already-buffered body lets a hostile or broken service push
  # unbounded bytes into the process before anyone objects. Observable here
  # because the harness streams the payload and reports how many bytes it
  # managed to write before the client hung up.
  def test_oversized_body_aborts_the_read_instead_of_buffering_it
    chunk = "x" * 64_000
    declared = CruFlags::Fetcher::MAX_BODY_BYTES * 16
    written = 0
    finished = Queue.new
    writer = lambda do |socket|
      while written < declared
        socket.write(chunk)
        written += chunk.bytesize
      end
    rescue SystemCallError, IOError
      nil # the client hung up mid-stream, which is the whole point
    ensure
      finished.push(written)
    end
    @service.respond { |_req| [200, {"Content-Length" => declared.to_s}, writer] }

    outcome = fetch(timeout: 10.0)
    assert_equal :failed, outcome.kind
    assert_equal :parse, outcome.error.code
    assert_includes outcome.error.message, "exceeds #{CruFlags::Fetcher::MAX_BODY_BYTES} bytes"

    sent = finished.pop(timeout: 10)
    refute_nil sent, "the streaming responder never finished"
    assert_operator sent, :<, declared,
      "the client read the whole oversized payload instead of aborting at the cap"
  end

  # The cap bounds the read for every status, but only a 200 body is the
  # document, so only a 200 turns the overrun into a size failure. A huge
  # error body must still report the HTTP status it actually had, and a huge
  # 404 must still be :missing — otherwise the cap would relabel outcomes
  # the client makes real decisions on.
  def test_oversized_non_200_bodies_keep_their_own_outcome
    {404 => :missing, 500 => :failed}.each do |status, kind|
      declared = CruFlags::Fetcher::MAX_BODY_BYTES * 4
      chunk = "x" * 64_000
      written = 0
      finished = Queue.new
      writer = lambda do |socket|
        while written < declared
          socket.write(chunk)
          written += chunk.bytesize
        end
      rescue SystemCallError, IOError
        nil
      ensure
        finished.push(written)
      end
      @service.respond { |_req| [status, {"Content-Length" => declared.to_s}, writer] }

      outcome = fetch(timeout: 10.0)
      assert_equal kind, outcome.kind, "HTTP #{status}"
      assert_equal 500, outcome.error.status if status == 500

      sent = finished.pop(timeout: 10)
      refute_nil sent, "the streaming responder never finished (HTTP #{status})"
      assert_operator sent, :<, declared,
        "the cap must bound the read on HTTP #{status} too, not just on 200"
    end
  end
end
