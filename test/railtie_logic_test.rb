# frozen_string_literal: true

require_relative "test_helper"
# NOTE: "rails/railtie" alone triggers a require-order bug in railties >=
# 8.1.2.1 (rails/initializable.rb uses delegate_missing_to before
# active_support/core_ext/module/delegation is loaded — rails/railtie.rb
# requires "rails/initializable" before any active_support core_ext). A real
# Rails app never hits this because the full "rails" gem loads active_support
# first; requiring the full framework here reproduces that real ordering
# instead of the bare (and, on this railties version, broken) submodule.
require "rails"
require "cru_flags"
require "cru_flags/railtie"
require "open3"
require "rbconfig"

class RailtieLogicTest < Minitest::Test
  def quiet?(current:, env_var: nil, rails_env: "development")
    CruFlags::Railtie.quiet_strict?(current:, env_var:, rails_env:)
  end

  # Also the documented indistinguishable case (design doc §5.1): an app that
  # explicitly sets config.flipper.strict = :warn in development is setting
  # the value flipper already defaulted to, which reads identically to
  # setting nothing, so it gets quieted too.
  def test_quiets_flippers_own_dev_default
    assert quiet?(current: :warn)
  end

  def test_quiets_flippers_own_prod_default
    assert quiet?(current: false, rails_env: "production")
  end

  def test_honors_explicit_env_var
    refute quiet?(current: :warn, env_var: "warn")
    refute quiet?(current: false, env_var: "false", rails_env: "production")
  end

  def test_honors_app_chosen_values_that_differ_from_the_default
    refute quiet?(current: true) # dev default is :warn; true means the app chose
    refute quiet?(current: :warn, rails_env: "production") # prod default is false
  end

  def test_railtie_is_defined_when_rails_is
    assert CruFlags::Railtie.ancestors.include?(Rails::Railtie)
  end

  # Regression coverage for a real bug the unit tests above are structurally
  # blind to: Rails::Application computes its initializer collection ONCE, by
  # walking Rails::Railtie's currently-defined subclasses, before running any
  # of them. requiring "flipper" from *inside* our own initializer's body
  # (rather than at file scope) meant Flipper::Engine did not exist yet when
  # that walk happened, so Flipper::Engine's own initializers — including the
  # one that wraps the adapter in Flipper::Adapters::Strict — never joined
  # the collection at all. No pure-Ruby unit test of quiet_strict? in
  # isolation can see that, because it only exercises the decision function,
  # never a real Rails::Application#initialize! walk. This boots a real,
  # minimal Rails::Application in a subprocess (so it can't contaminate this
  # process, or any other test file's process, with a booted Rails app) and
  # inspects the actual adapter chain Flipper ends up with.
  #
  # "require bundler/setup" first makes this deterministic regardless of
  # whether the outer test process itself was invoked via `bundle exec` —
  # it pins the subprocess to this repo's Gemfile.lock (flipper, railties)
  # instead of falling through to whatever gems happen to be installed.
  BOOT_SCRIPT = <<~RUBY
    require "bundler/setup"
    require "logger"
    require "rails"
    require "cru_flags"

    class BootTestApp < Rails::Application
      config.eager_load = false
      config.logger = Logger.new(File::NULL)
      config.secret_key_base = "x" * 30
    end

    Rails.application.initialize!

    chain = []
    adapter = Flipper.instance.adapter
    while adapter
      chain << adapter.class.name
      adapter = adapter.instance_variable_get(:@adapter)
    end
    puts chain.join(",")
  RUBY

  def boot_adapter_chain(extra_env)
    lib_dir = File.expand_path("../lib", __dir__)
    gemfile = File.expand_path("../Gemfile", __dir__)
    env = {"BUNDLE_GEMFILE" => gemfile, "FLIPPER_STRICT" => nil}.merge(extra_env)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I#{lib_dir}", "-e", BOOT_SCRIPT)
    assert status.success?, "subprocess boot failed:\n#{stderr}"
    stdout.strip.split(",")
  end

  def test_zero_config_boot_registers_our_adapter_without_strict
    chain = boot_adapter_chain({})
    assert_includes chain, "CruFlags::FlipperAdapter"
    refute_includes chain, "Flipper::Adapters::Strict"
  end

  def test_explicit_flipper_strict_env_var_is_honored_through_a_real_boot
    chain = boot_adapter_chain({"FLIPPER_STRICT" => "raise"})
    assert_includes chain, "Flipper::Adapters::Strict"
  end
end
