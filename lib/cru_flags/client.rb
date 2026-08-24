# frozen_string_literal: true

require "json"
require "logger"
require "uri"

module CruFlags
  # The polling flag client (design doc §3–§8). One instance per process in
  # normal use, via the CruFlags module singleton.
  class Client
    VALID_SCHEMES = %w[http https].freeze
    MODES = %w[background on-demand].freeze

    # The one place CRU_FLAGS_URL is read and normalized (design doc §3:
    # `url: nil` means "read CRU_FLAGS_URL on first use"). It lives on the
    # Client, not on the module singleton, so a directly-constructed Client
    # honors the documented contract instead of being silently inert; the
    # module singleton gets the same normalization by construction.
    def self.url_from_env
      value = ENV[ENV_VAR].to_s.strip
      value.empty? ? nil : value
    end

    def initialize(url: nil, poll_seconds: 30.0, fetch_timeout: 2.0,
      on_error: nil, refresh_mode: nil)
      @poll_seconds = positive(poll_seconds, 30.0)
      @fetch_timeout = positive(fetch_timeout, 2.0)
      @on_error = on_error || default_on_error
      @refresh_mode = resolve_mode(refresh_mode)
      @url = url || self.class.url_from_env
      @document = nil
      @etag = nil
      @healthy = true
      @attempted = false
      @last_attempt_at = nil
      @last_attempt_ok = false
      @closed = false
      @write_mutex = Mutex.new
      @fetch_mutex = Mutex.new
      @ready_mutex = Mutex.new
      @ready_cv = ConditionVariable.new
      @wake = Queue.new
      @thread = nil
      @pid = nil
      validate_url!
    end

    def inert? = @url.nil?

    def enabled?(name)
      read_path_touch
      doc = @document
      doc&.dig("Flags", name.to_s, "Enabled") == true
    rescue
      false
    end

    def snapshot
      read_path_touch
      doc = @document
      doc ? JSON.parse(JSON.generate(doc)) : {}
    rescue
      {}
    end

    # The Flipper adapter's read primitive: the frozen Flags hash (or {}),
    # through the same read path as enabled? (lazy start / on-demand
    # refresh).
    def flags_for_adapter
      read_path_touch
      @document&.fetch("Flags", nil) || {}
    rescue
      {}
    end

    # Blocks until the first fetch attempt completes (success or failure) and
    # returns whether it did within timeout. Immediately false for inert
    # clients (design doc §3.3, §7).
    def ready(timeout: nil)
      return false if inert? || (@closed && !@attempted)
      ensure_started
      return on_demand_ready if on_demand?
      @ready_mutex.synchronize do
        deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until @attempted
          ensure_started # self-heals a poller that died mid-wait, rather than waiting on it forever
          remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if remaining && remaining <= 0
          @ready_cv.wait(@ready_mutex, remaining || 1.0)
          return false if @closed && !@attempted
        end
        true
      end
    rescue
      false
    end

    def refresh(force: false)
      return false if inert? || @closed
      waited_from = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        @fetch_mutex.synchronize do
          if force
            attempt_fetch unless @last_attempt_at && @last_attempt_at >= waited_from
          elsif stale?
            attempt_fetch
          end
        end
      ensure
        signal_ready
      end
      @attempted && @last_attempt_ok
    rescue
      false
    end

    def close
      @closed = true
      @wake.push(:stop)
      @ready_mutex.synchronize { @ready_cv.broadcast }
      begin
        @thread&.join(0.1)
      rescue
        nil # close called from the poller thread itself must not raise ThreadError
      end
      nil
    end

    private

    # The pre-read hook shared by enabled?/snapshot/flags_for_adapter: lazily
    # arms the background poller (a no-op once running) and, in on-demand
    # mode, performs the coalesced fetch before the read.
    def read_path_touch
      ensure_started
      refresh_on_demand
    end

    # refresh_mode resolution (design doc §7.1, §7.2): constructor argument
    # wins over ENV["CRU_FLAGS_REFRESH_MODE"], which wins over the
    # "background" default. An unrecognized constructor value is a caller
    # typo -> ArgumentError. An unrecognized ENV value is misconfiguration
    # that must never stop boot -> one on_error warning, then background.
    # @on_error is already assigned by the time this runs, so the warning
    # can be reported inline.
    def resolve_mode(arg)
      if arg
        raise ArgumentError, "refresh_mode must be one of #{MODES.join(", ")}" unless MODES.include?(arg)
        return arg
      end
      env = ENV["CRU_FLAGS_REFRESH_MODE"].to_s.strip
      return "background" if env.empty?
      return env if MODES.include?(env)
      report(FetchError.new("CRU_FLAGS_REFRESH_MODE=#{env.inspect} is not recognized; using background",
        code: :network))
      "background"
    end

    # On-demand mode has no poller thread at all (design doc §7.1).
    def on_demand?
      @refresh_mode == "on-demand"
    end

    # The on-demand read-path hook: every enabled?/snapshot/ready call
    # attempts a coalesced, attempt-anchored fetch before reading. A no-op
    # in background mode, for inert clients, and once closed.
    def refresh_on_demand
      return unless on_demand?
      return if inert? || @closed
      begin
        attempt_fetch_coalesced(force: false)
      ensure
        signal_ready # deliberate: kept for symmetry with the background poller's signal, even though on-demand's own ready() never waits on this CV
      end
    end

    # ready in on-demand mode performs the read-path refresh itself rather
    # than waiting on the ready CV (there is no poller to signal it); the
    # timeout: argument is unused there, bounded instead by the fetch
    # timeouts (design doc §3.3, §7.1).
    def on_demand_ready
      refresh_on_demand
      @attempted
    end

    # Lazily arms the background poller on the first enabled?/ready/snapshot
    # call. A no-op for inert, closed, or on-demand clients. Self-healing: a
    # dead poller (killed by an unanticipated bug) is detected via
    # Thread#alive? and respawned rather than leaving flags frozen forever.
    # Fork-safe: a PID change discards the dead parent thread's state
    # (including the ready CV, whose wait queue may reference parent
    # threads) so the child re-arms its own poller on its own next read
    # (design doc §7).
    def ensure_started
      return if inert? || @closed || on_demand?
      return if @thread&.alive? && Process.pid == @pid
      @write_mutex.synchronize do
        return if @closed
        if @thread && Process.pid != @pid
          @thread = nil
          @wake = Queue.new
          @ready_mutex = Mutex.new
          @ready_cv = ConditionVariable.new
        end
        spawn_poller unless @thread&.alive?
      end
    end

    def spawn_poller
      @pid = Process.pid
      @thread = Thread.new do
        Thread.current.name = "cru-flags-poller"
        Thread.current.report_on_exception = false
        until @closed
          begin
            attempt_fetch_coalesced(force: true)
          rescue
            nil # a bug here must not silently kill the poller (design doc §7)
          ensure
            signal_ready
          end
          begin
            @wake.pop(timeout: @poll_seconds * rand(0.8..1.2))
          rescue
            # Non-spinning: a broken wake queue must not turn into a busy
            # loop hammering the flag service.
            sleep(@poll_seconds)
          end
        end
      end
    end

    def attempt_fetch_coalesced(force:)
      @fetch_mutex.synchronize do
        attempt_fetch if force || stale?
      end
    end

    def signal_ready
      return unless @attempted
      @ready_mutex.synchronize { @ready_cv.broadcast }
    end

    def stale?
      @last_attempt_at.nil? ||
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_attempt_at) >= @poll_seconds
    end

    def attempt_fetch
      outcome = Fetcher.call(url: @url, etag: @etag, timeout: @fetch_timeout)
      apply(outcome)
    ensure
      @attempted = true
      @last_attempt_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def apply(outcome)
      case outcome.kind
      when :document
        @document = outcome.document # document BEFORE etag (design doc §8)
        @etag = outcome.etag
        became(healthy: true)
      when :not_modified
        became(healthy: true)
      when :missing
        @document = Document::EMPTY
        @etag = nil
        became(healthy: true)
      when :failed
        became(healthy: false, error: outcome.error)
      end
      @last_attempt_ok = outcome.kind != :failed
    end

    def became(healthy:, error: nil)
      return if healthy == @healthy
      @healthy = healthy
      report(healthy ? nil : error)
    end

    def report(error)
      @on_error.call(error)
    rescue
      nil # a broken error handler must not kill the poller
    end

    def default_on_error
      lambda do |error|
        logger = defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger ||
          (@fallback_logger ||= Logger.new($stderr, progname: "cru_flags"))
        if error
          logger.warn("flag fetches failing: #{error.class}: #{error.message}")
        else
          logger.warn("flag fetches recovered")
        end
      end
    end

    def positive(value, fallback)
      (value.is_a?(Numeric) && value.finite? && value.positive?) ? value.to_f : fallback
    end

    def validate_url!
      return if @url.nil?
      uri = URI(@url.to_s)
      invalid_scheme = !VALID_SCHEMES.include?(uri.scheme)
      # hostname, matching the fetcher: the unbracketed form is what actually
      # gets resolved, so it is what "has a host" must be judged on.
      no_host = uri.hostname.to_s.empty?
      if invalid_scheme || no_host
        reason = invalid_scheme ? "scheme #{uri.scheme.inspect} is not http(s)" : "has no host"
        @url = nil
        report(FetchError.new("CRU_FLAGS_URL #{reason}; client is inert", code: :network))
      end
    rescue URI::InvalidURIError
      @url = nil
      report(FetchError.new("CRU_FLAGS_URL is not a valid URL; client is inert", code: :network))
    end
  end
end
