# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "socket"

# Every other test file injects on_error: explicitly (client_core_test.rb,
# client_background_test.rb, client_on_demand_test.rb), so
# Client#default_on_error itself — what a real app gets when it constructs
# CruFlags::Client (or uses the CruFlags module singleton) without ever
# touching on_error: — has zero coverage. Both subprocess: default_on_error
# reads `defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger` at
# call time, so which branch fires depends on process-global state
# ("Rails" being defined at all) that must not leak into, or out of, this
# suite's own process (client_background_test.rb's on_error: ->(_e) {}
# comment is explicit about not wanting to exercise the default logger
# inline). Fresh subprocesses, the Open3 pattern from side_effects_test.rb
# and railtie_logic_test.rb, keep both branches isolated from each other
# and from every other test.
#
# The failing fetch itself is real (design doc §9 / CLAUDE.md: no
# Net::HTTP mocks) — a TCPServer is bound to grab a free port, then closed
# before the client ever connects, so the client's HTTP GET hits a real,
# nothing-listening port and gets a genuine ECONNREFUSED.
class ClientDefaultOnErrorTest < Minitest::Test
  RUBY = RbConfig.ruby
  LIB = File.expand_path("../lib", __dir__)

  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def run_script(script)
    bare_env = {"RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil}
    Open3.capture3(bare_env, RUBY, "-I", LIB, "-e", script)
  end

  def test_default_on_error_falls_back_to_stderr_when_rails_is_undefined
    port = closed_port
    script = <<~RUBY
      require "cru_flags"
      raise "test setup bug: Rails must not be defined here" if defined?(Rails)
      client = CruFlags::Client.new(url: "http://127.0.0.1:#{port}/flags/x/production")
      client.refresh(force: true)
      client.close
    RUBY
    stdout, stderr, status = run_script(script)
    assert status.success?, "subprocess failed:\nstdout: #{stdout}\nstderr: #{stderr}"
    assert_match(/flag fetches failing/, stderr,
      "default_on_error must warn on the fallback logger when Rails is undefined")
    assert_match(/CruFlags::FetchError/, stderr, "operators need the error class")
    assert_match(/#{port}/, stderr, "operators need to know which target failed")
  end

  def test_default_on_error_routes_through_rails_logger_when_rails_is_defined
    port = closed_port
    script = <<~RUBY
      require "cru_flags"

      module Rails
        class FakeLogger
          attr_reader :warnings
          def initialize = @warnings = []
          def warn(message) = @warnings << message
        end

        LOGGER = FakeLogger.new
        def self.logger = LOGGER
      end

      client = CruFlags::Client.new(url: "http://127.0.0.1:#{port}/flags/x/production")
      client.refresh(force: true)
      client.close
      puts Rails::LOGGER.warnings.join("\\x1E")
    RUBY
    stdout, stderr, status = run_script(script)
    assert status.success?, "subprocess failed:\nstdout: #{stdout}\nstderr: #{stderr}"
    warnings = stdout.strip.split("\x1E")
    refute_empty warnings, "default_on_error must call Rails.logger.warn when Rails.logger is set"
    assert_match(/flag fetches failing/, warnings.first)
    assert_match(/CruFlags::FetchError/, warnings.first, "operators need the error class")
    assert_match(/#{port}/, warnings.first, "operators need to know which target failed")
    refute_match(/flag fetches failing/, stderr,
      "Rails.logger being set must suppress the $stderr fallback entirely")
  end
end
