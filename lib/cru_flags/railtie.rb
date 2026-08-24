# frozen_string_literal: true

# Loaded at file scope, not inside the initializer: Rails::Application
# computes its initializer collection ONCE, by walking Rails::Railtie's
# currently-defined subclasses, before running any of them. If "flipper"
# were required for the first time from inside our own initializer's body,
# Flipper::Engine would not exist yet when that walk happens, so its own
# initializers (Strict wrapping, ActorLimit, the Memoizer middleware) would
# never join the collection at all — not run late, just silently absent.
# This file only loads under Rails (see the guarded require in
# lib/cru_flags.rb), so requiring "flipper" here does not touch the
# no-bundler / non-Rails path.
require "flipper"

module CruFlags
  # Zero-config Rails wiring (design doc §5.1). Registration is ordering-safe
  # because Flipper's engine resolves config.adapter LAZILY on first
  # Flipper.instance access, and the last-registered adapter block wins — an
  # app's own Flipper.configure in config/initializers still overrides ours.
  class Railtie < Rails::Railtie
    # Flipper's engine assigns config.flipper.strict in before_configuration
    # (:warn in development, false elsewhere) — BEFORE any gem initializer —
    # so "did the app set it" cannot be read off the config value alone. We
    # quiet strict only when the env var is unset AND the value still equals
    # Flipper's own computed default, i.e. only when nobody chose it.
    def self.quiet_strict?(current:, env_var:, rails_env:)
      return false unless env_var.nil?
      flipper_default = (rails_env == "development") ? :warn : false
      current == flipper_default
    end

    initializer "cru_flags.flipper" do |app|
      Flipper.configure { |config| config.adapter { CruFlags.flipper_adapter } }

      if app.config.respond_to?(:flipper) &&
          Railtie.quiet_strict?(current: app.config.flipper.strict,
            env_var: ENV["FLIPPER_STRICT"], rails_env: Rails.env.to_s)
        app.config.flipper.strict = false
      end
    end
  end
end
