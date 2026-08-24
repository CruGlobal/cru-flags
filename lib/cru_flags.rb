# frozen_string_literal: true

require_relative "cru_flags/version"
require_relative "cru_flags/errors"
require_relative "cru_flags/document"
require_relative "cru_flags/fetcher"
require_relative "cru_flags/client"

# Module-level singleton — the 99% path (design doc §3.1). Requiring this
# file does nothing: no env read, no socket, no thread.
module CruFlags
  ENV_VAR = "CRU_FLAGS_URL"

  @client_mutex = Mutex.new
  @client = nil
  @flipper_adapter_mutex = Mutex.new
  @flipper_adapter = nil

  class << self
    def client
      @client || @client_mutex.synchronize { @client ||= Client.new(url: url_from_env) }
    end

    def enabled?(name) = client.enabled?(name)

    def ready(timeout: nil) = client.ready(timeout:)

    def snapshot = client.snapshot

    def refresh(force: false) = client.refresh(force:)

    def close = client.close

    # The read-only Flipper adapter (design doc §5), memoized and bound to
    # the singleton client. `flipper` is required lazily here (not at the
    # top of this file) so requiring "cru_flags" alone stays flipper-free.
    def flipper_adapter
      @flipper_adapter || @flipper_adapter_mutex.synchronize do
        @flipper_adapter ||= begin
          require_relative "cru_flags/flipper_adapter"
          FlipperAdapter.new(client)
        end
      end
    end

    # Test hook, not public API: closes and discards the singleton so the
    # next call re-reads the environment.
    def reset!
      @client_mutex.synchronize do
        @client&.close
        @client = nil
      end
      @flipper_adapter_mutex.synchronize { @flipper_adapter = nil }
    end

    private

    def url_from_env
      value = ENV[ENV_VAR].to_s.strip
      value.empty? ? nil : value
    end
  end
end

require_relative "cru_flags/railtie" if defined?(Rails::Railtie)
