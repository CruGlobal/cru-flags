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

  def test_oversized_body_is_failed
    # A valid-JSON body that merely exceeds MAX_BODY_BYTES: proves the size
    # cap itself trips the failure, not a coincidental parse error.
    huge = '{"Flags":{}}' + (" " * (CruFlags::Fetcher::MAX_BODY_BYTES + 1))
    @service.respond_with(status: 200, body: huge)
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :parse, outcome.error.code
  end
end
