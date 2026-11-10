# frozen_string_literal: true

require "flipper"

module CruFlags
  # Read-only Flipper adapter over the client's frozen snapshot (design doc
  # §5). HARD RULE: get/get_multi/get_all build fresh, UNFROZEN top-level
  # hashes on every call — Flipper::Adapters::Memoizable mutates the Hash we
  # return (response.default_proc =, memoizable.rb:103), so a frozen or
  # shared return value would raise FrozenError on every memoized request.
  class FlipperAdapter
    include Flipper::Adapter

    def initialize(client)
      @client = client
    end

    def name = :cru_flags

    def read_only? = true

    def features
      @client.flags_for_adapter.keys.to_set
    end

    def get(feature)
      gates_for(feature.key)
    end

    def get_multi(features)
      flags = @client.flags_for_adapter
      features.to_h { |feature| [feature.key, gates_for(feature.key, flags)] }
    end

    def get_all
      flags = @client.flags_for_adapter
      flags.keys.to_h { |name| [name, gates_for(name, flags)] }
    end

    def add(_feature) = write_refused

    def remove(_feature) = write_refused

    def clear(_feature) = write_refused

    def enable(_feature, _gate, _thing) = write_refused

    def disable(_feature, _gate, _thing) = write_refused

    private

    def gates_for(name, flags = @client.flags_for_adapter)
      gates = self.class.default_config.dup
      gates[:boolean] = true if flags.dig(name, "Enabled") == true
      gates
    end

    def write_refused
      raise ReadOnlyError, "flags are written by cru-cli and the deploys.cru.org dashboard, never by the app"
    end
  end
end
