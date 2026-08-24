# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "net/http"
require "json"

class FlagServiceTest < Minitest::Test
  def setup
    @service = FlagService.new.start
  end

  def teardown
    @service.stop
  end

  def test_serves_canned_json_and_records_request_headers
    @service.respond_with(status: 200, body: {"Flags" => {}}.to_json,
      headers: {"ETag" => '"1"', "Content-Type" => "application/json"})
    uri = URI(@service.url)
    res = Net::HTTP.start(uri.host, uri.port) do |http|
      http.get(uri.path, {"If-None-Match" => '"0"', "Accept" => "application/json"})
    end
    assert_equal "200", res.code
    assert_equal '"1"', res["etag"]
    assert_equal '"0"', @service.requests.last.headers["if-none-match"]
  end

  def test_programmable_block_and_status_304
    @service.respond { |req| [304, {}, nil] }
    uri = URI(@service.url)
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.get(uri.path) }
    assert_equal "304", res.code
  end

  def test_ioerror_from_one_connection_does_not_kill_the_accept_loop
    attempts = 0
    @service.respond do |_req|
      attempts += 1
      raise IOError, "simulated per-connection failure" if attempts == 1
      [200, {}, "ok"]
    end
    uri = URI(@service.url)

    # Disable Net::HTTP's own idempotent-request retry (default: 1) so the
    # first connection's failure surfaces here instead of being silently
    # retried by the client. Bound both attempts so a regression (the accept
    # loop dying) fails fast instead of hanging on a dead listener.
    assert_raises(StandardError) do
      Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) do |h|
        h.max_retries = 0
        h.get(uri.path)
      end
    end

    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) { |h| h.get(uri.path) }
    assert_equal "200", res.code
  end
end
