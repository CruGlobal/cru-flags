# frozen_string_literal: true

require "net/http"
require "uri"

module CruFlags
  # One conditional GET of the flag document. Stateless; the Client owns the
  # etag and the snapshot. Never raises — every failure is an Outcome.
  module Fetcher
    Outcome = Struct.new(:kind, :document, :etag, :error)

    # The parts of a Net::HTTPResponse this module uses, captured while the
    # connection is still open. The body is read (and size-capped) inside the
    # request block rather than buffered by Net::HTTP, so nothing here holds
    # a live socket.
    Response = Struct.new(:code, :body, :etag, :location)

    REDIRECT_LIMIT = 3
    REDIRECT_CODES = %w[301 302 303 307 308].freeze
    VALID_SCHEMES = %w[http https].freeze
    BODY_EXCERPT = 200
    MAX_BODY_BYTES = 1_048_576

    module_function

    def call(url:, etag: nil, timeout: 2.0)
      response = get_following_redirects(URI(url), etag:, timeout:)
      case response.code
      when "200"
        # The MAX_BODY_BYTES cap already tripped during the read if it was
        # going to (see read_capped_body); reaching here means the body fits.
        document = Document.parse(response.body.to_s)
        Outcome.new(kind: :document, document:, etag: response.etag)
      when "304" then Outcome.new(kind: :not_modified)
      when "404" then Outcome.new(kind: :missing)
      else
        excerpt = response.body.to_s.strip.gsub(/\s+/, " ")[0, BODY_EXCERPT]
        failed(FetchError.new("flag fetch failed with HTTP #{response.code}: #{excerpt}",
          code: :http, status: Integer(response.code)))
      end
    rescue FetchError => e
      failed(e)
    rescue ParseError => e
      failed(FetchError.new(e.message, code: :parse))
    rescue Timeout::Error => e
      failed(FetchError.new("flag fetch timed out: #{e.message}", code: :timeout))
    rescue SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
      URI::Error, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError => e
      failed(FetchError.new("flag fetch failed: #{e.message}", code: :network))
    rescue => e
      # Floor, not enumeration: "call never raises" must hold by construction.
      # Mirrors the sibling clients' contract (node's toFlagsError) — any
      # exception type we didn't anticipate still normalizes to :network
      # rather than escaping as a raise.
      failed(FetchError.new("flag fetch failed: #{e.message}", code: :network))
    end

    def get_following_redirects(uri, etag:, timeout:)
      REDIRECT_LIMIT.downto(0) do |hops_left|
        response = get(uri, etag:, timeout:)
        return response unless REDIRECT_CODES.include?(response.code)
        if hops_left.zero?
          raise FetchError.new("flag fetch exceeded #{REDIRECT_LIMIT} redirects",
            code: :http, status: Integer(response.code))
        end
        uri = uri.merge(response.location.to_s)
        validate_redirect_uri!(uri)
      end
    end

    # Guards each redirect hop (design doc §8): a Location header pointing at
    # a non-http(s) scheme or a hostless URI must not be handed to Net::HTTP,
    # which would otherwise raise something less legible than a plain :failed
    # :network outcome.
    def validate_redirect_uri!(uri)
      return if VALID_SCHEMES.include?(uri.scheme) && !uri.hostname.to_s.empty?
      raise FetchError.new("flag fetch redirected to an invalid URI (scheme #{uri.scheme.inspect}, host #{uri.hostname.inspect})",
        code: :network)
    end

    def get(uri, etag:, timeout:)
      headers = {"Accept" => "application/json",
                 "User-Agent" => "cru-flags-ruby/#{VERSION}"}
      headers["If-None-Match"] = etag if etag
      # hostname, not host: URI#host keeps the brackets an IPv6 literal must
      # carry inside a URL ("[::1]"), which getaddrinfo cannot resolve.
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: timeout, read_timeout: timeout, write_timeout: timeout) do |http|
        # Design doc §8: no retries within a tick — the next tick is the
        # retry. Net::HTTP's default max_retries of 1 silently re-issues a
        # failed idempotent GET, doubling both the blocking bound the client
        # promises and the load a struggling flag service sees.
        http.max_retries = 0
        http.request(Net::HTTP::Get.new(uri.request_uri, headers)) do |response|
          return Response.new(code: response.code, etag: response["etag"],
            location: response["location"], body: read_capped_body(response))
        end
      end
    end

    # Design doc §8's 1 MiB cap, enforced WHILE the body streams in rather
    # than after Net::HTTP has already buffered it: reading stops the moment
    # the cap is passed, so an oversized (or endless) body never reaches the
    # heap whole. A 304 — and any other bodyless response — yields nothing
    # and comes back as "".
    #
    # Only a 200 turns the overrun into the tick's failure: that body IS the
    # document, and a truncated document must never be parsed. Every other
    # status uses the body as at most a BODY_EXCERPT-sized error excerpt, or
    # ignores it entirely, so overrunning there just ends the read rather
    # than relabeling a legible HTTP outcome as a size error.
    def read_capped_body(response)
      body = +""
      response.read_body do |chunk|
        body << chunk
        next if body.bytesize <= MAX_BODY_BYTES
        if response.code == "200"
          raise FetchError.new("flag fetch body exceeds #{MAX_BODY_BYTES} bytes", code: :parse)
        end
        break
      end
      body
    end

    def failed(error) = Outcome.new(kind: :failed, error:)
    private_class_method :get_following_redirects, :validate_redirect_uri!, :get,
      :read_capped_body, :failed
  end
end
