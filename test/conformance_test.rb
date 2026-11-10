# frozen_string_literal: true

# The shared conformance cases (conformance/cases.json), run against this
# client. Every client in the repository runs the same cases against the same
# server, conformance/server.py. See conformance/README.md.

require_relative "test_helper"
require "cru_flags"
require "json"
require "net/http"
require "open3"
require "securerandom"

class ConformanceTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CASES = JSON.parse(File.read(File.join(ROOT, "conformance", "cases.json"))).fetch("cases")

  # One server for the whole run. It exits when its stdin closes.
  def self.server_url
    @server_url ||= begin
      stdin, stdout, wait = Open3.popen2("python3", File.join(ROOT, "conformance", "server.py"))
      line = stdout.gets or raise "conformance server did not start"
      Minitest.after_run do
        stdin.close
        wait.value
      end
      "http://127.0.0.1:#{line.split.last}"
    end
  end

  CASES.each do |kase|
    define_method(:"test_#{kase.fetch("name").tr("-", "_")}") { run_case(kase) }
  end

  private

  def run_case(kase)
    name = kase.fetch("name")
    run = SecureRandom.hex(8)
    url = kase.fetch("url", true) ? "#{self.class.server_url}/flags/#{name}/#{run}" : nil
    events = []
    saved_url = ENV.delete("CRU_FLAGS_URL")
    client = CruFlags::Client.new(
      url:, poll_seconds: 3600, fetch_timeout: 1.0, refresh_mode: "background",
      on_error: ->(error) { events << (error ? "failing" : "recovered") }
    )

    kase.fetch("steps").each_with_index do |step, index|
      where = "#{name} step #{index} (#{step.fetch("do")})"
      (step.fetch("do") == "ready") ? client.ready(timeout: 10) : client.refresh(force: true)

      step.fetch("enabled", {}).each do |flag, expected|
        assert_equal expected, client.enabled?(flag), "#{where}: enabled?(#{flag.inspect})"
      end
      if url && (step.key?("requests") || step.key?("ifNoneMatch"))
        seen = requests_seen(name, run)
        assert_equal step["requests"], seen.size, "#{where}: requests" if step.key?("requests")
        if step.key?("ifNoneMatch")
          sent = seen.last&.dig("headers", "if-none-match")
          expected = step["ifNoneMatch"]
          expected.nil? ? assert_nil(sent, "#{where}: If-None-Match") : assert_equal(expected, sent, "#{where}: If-None-Match")
        end
      end
      assert_equal step["events"], events, "#{where}: health events" if step.key?("events")
    end
  ensure
    client&.close
    ENV["CRU_FLAGS_URL"] = saved_url if saved_url
  end

  def requests_seen(name, run)
    JSON.parse(Net::HTTP.get(URI("#{self.class.server_url}/log/#{name}/#{run}")))
  end
end
