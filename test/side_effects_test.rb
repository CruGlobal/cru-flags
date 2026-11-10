# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "open3"
require "rbconfig"
require "timeout"

# Subprocess proofs for guarantees that only show up in a fresh interpreter:
# requiring this library must be inert, an active poller must never keep the
# process alive past its own work, and a forked child must get its own
# poller rather than inheriting a parent thread it doesn't own (design doc
# §3, §7). Each test boots a throwaway Ruby process (the Open3 pattern from
# railtie_logic_test.rb) so these can't contaminate this test process, or
# each other, with threads or a booted client.
class SideEffectsTest < Minitest::Test
  RUBY = RbConfig.ruby
  LIB = File.expand_path("../lib", __dir__)

  # Open3.capture3's env argument MERGES with this process's own env, it
  # doesn't replace it. This process runs under `bundle exec`, which sets
  # RUBYOPT to auto-require bundler/setup and BUNDLE_GEMFILE to this repo's
  # Gemfile — inherited silently, that would make every subprocess below
  # bundler-activated even though nothing in the script asked for it, which
  # would quietly undercut the "just `require "cru_flags"`, nothing else"
  # premise these tests exist to prove. Nil-ing both here (nil deletes a key
  # for Open3) makes each child process a genuinely bare `ruby -Ilib`.
  def run_script(env, script)
    bare_env = {"RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil}.merge(env)
    Open3.capture3(bare_env, RUBY, "-I", LIB, "-e", script)
  end

  def test_require_starts_no_threads_even_with_url_set
    script = 'require "cru_flags"; ' \
      "puts Thread.list.size; " \
      "exit(Thread.list.size == 1 ? 0 : 1)"
    stdout, stderr, status = run_script({"CRU_FLAGS_URL" => "http://127.0.0.1:9/flags/x/production"}, script)
    assert status.success?,
      "require must not start threads or read the env:\nstdout: #{stdout}\nstderr: #{stderr}"
  end

  def test_active_poller_never_delays_interpreter_exit
    service = FlagService.new.start
    service.respond_with(status: 200, body: '{"Flags":{}}')
    script = 'require "cru_flags"; CruFlags.ready(timeout: 5)'
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, stderr, status = run_script({"CRU_FLAGS_URL" => service.url}, script)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert status.success?, "subprocess failed:\nstdout: #{stdout}\nstderr: #{stderr}"
    assert_operator elapsed, :<, 5.0,
      "process must exit immediately, not wait for a 30s poll tick"
  ensure
    service&.stop
  end

  # A weaker version of this test — fork, then just call CruFlags.enabled?
  # in the child and expect the parent's already-fetched value — would pass
  # even if Task 6's re-arm were completely dead: the child inherits the
  # parent's frozen @document by copy-on-write, so a plain read proves
  # nothing beyond "COW memory exists". To actually exercise the re-armed
  # fetch pipeline (fresh mutexes, a live socket, a real write to
  # @document), the FlagService here flips its answer on the SECOND request
  # — the child is forced to fetch, and can only observe the flip if its
  # post-fork read/write path is genuinely live, not just replaying stale
  # inherited state.
  def test_child_process_after_fork_can_fetch_fresh_data_not_just_replay_cow_memory
    skip "fork unavailable" unless Process.respond_to?(:fork)
    service = FlagService.new.start
    request_count = 0
    service.respond do |_req|
      request_count += 1
      body = (request_count == 1) ? '{"Flags":{"pilot":{"Enabled":true}}}' : '{"Flags":{"pilot":{"Enabled":false}}}'
      [200, {}, body]
    end
    script = <<~RUBY
      require "cru_flags"
      CruFlags.ready(timeout: 5) or exit 2
      CruFlags.enabled?("pilot") or exit 5 # precondition: parent's first fetch landed before forking
      pid = fork do
        CruFlags.refresh(force: true) # forces a genuine second HTTP round trip in the child
        exit(CruFlags.enabled?("pilot") ? 4 : 0) # must see the flip, not the parent's stale true
      end
      _, status = Process.waitpid2(pid)
      exit(status.exitstatus)
    RUBY
    stdout, stderr, status = Timeout.timeout(30) { run_script({"CRU_FLAGS_URL" => service.url}, script) }
    assert status.success?,
      "a forked child must re-arm and genuinely fetch fresh data, not replay COW memory " \
      "(exit #{status.exitstatus}):\nstdout: #{stdout}\nstderr: #{stderr}"
  rescue Timeout::Error
    flunk "fork + refresh(force: true) hung for 30s — likely a post-fork mutex deadlock"
  ensure
    service&.stop
  end
end
