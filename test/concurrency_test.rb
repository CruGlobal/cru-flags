# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"
require "json"

# Concurrency guarantees that only surface under real contention: readers
# racing a fast-swapping poller must never observe a half-applied document
# (design doc §6 — documents are deep-frozen and swapped by single reference
# assignment, never mutated in place). Design doc §9 asks specifically for a
# hammer on `enabled?` across snapshot swaps, so the reader pool drives both
# it and `snapshot`. Plus two jitter checks (design doc
# §7's ±20% de-phasing band): an honestly-labeled Ruby-RNG sanity bound, and
# a source-derived pin on the poller's actual jitter formula (the sanity
# bound alone never calls into the client, so it can't fail if the formula
# is edited or removed).
class ConcurrencyTest < Minitest::Test
  def test_readers_never_see_a_half_applied_swap
    service = FlagService.new.start
    docs = [
      '{"Version":1,"Flags":{"a":{"Enabled":true},"b":{"Enabled":true}}}',
      '{"Version":2,"Flags":{"a":{"Enabled":false},"b":{"Enabled":false}}}'
    ]
    turn = 0
    service.respond { |_req| [200, {}, docs[(turn += 1) % 2]] }
    client = CruFlags::Client.new(url: service.url, poll_seconds: 0.01)
    client.ready(timeout: 2.0)
    stop = false
    violations = []
    # Bounded: these loops run millions of iterations in a second, so an
    # unbounded record turns one real regression into a multi-megabyte
    # failure message. The first few examples are all a diagnosis needs.
    record = ->(v) { violations << v if violations.size < 10 }
    # Half the readers go through snapshot (one deep copy, so the two flags
    # it compares come from the same document) and half through enabled?,
    # the lock-free dig straight into the live frozen document — the read
    # path §9 actually promises to hammer, and the only one that touches the
    # swapped reference with no copy in between. Two enabled? calls straddle
    # a swap legitimately, so what it can assert is what the contract
    # promises: it never raises, and it answers strictly true or false —
    # never nil, never a fragment of a half-applied document.
    readers = 8.times.map do |i|
      Thread.new do
        until stop
          begin
            if i.even?
              snap = client.snapshot
              next if snap.empty?
              a = snap.dig("Flags", "a", "Enabled")
              b = snap.dig("Flags", "b", "Enabled")
              record.call(snap) if a != b # the two docs always agree internally
            else
              %w[a b missing].each do |name|
                value = client.enabled?(name)
                record.call([name, value]) unless value == true || value == false
              end
            end
          rescue => e
            record.call(e) # enabled?/snapshot never raise, contention included
          end
        end
      end
    end
    sleep 1.0
    stop = true
    readers.each(&:join)
    assert_empty violations, "a reader observed a torn document (or raised)"
  ensure
    client&.close
    service&.stop
  end

  # Honestly labeled: this is a sanity check on Kernel#rand(Range)'s own
  # documented float-range semantics, NOT a test of the poller. It never
  # touches CruFlags::Client, so editing or deleting spawn_poller's jitter
  # formula cannot make this fail — see
  # test_poller_jitter_formula_is_pinned_at_its_call_site below for the test
  # that actually pins the poller's behavior.
  def test_ruby_rand_float_range_stays_in_band_sanity_check
    samples = 10_000.times.map { rand(0.8..1.2) }
    assert_operator samples.min, :>=, 0.8
    assert_operator samples.max, :<=, 1.2
    assert_in_delta 1.0, samples.sum / samples.size, 0.01
  end

  # A source-derived pin (the style the sibling clients use against
  # vocabulary drift): reads the client's own source and asserts its jitter
  # expression is still exactly `@poll_seconds * rand(0.8..1.2)` at its one
  # call site (design doc §7's ±20% de-phasing band against a thundering
  # herd). Brittle by design — a formula edit here MUST break this test,
  # which the sanity check above cannot do since it never calls into the
  # client at all.
  def test_poller_jitter_formula_is_pinned_at_its_call_site
    source = File.read(File.expand_path("../lib/cru_flags/client.rb", __dir__))
    assert_match(/@poll_seconds\s*\*\s*rand\(0\.8\.\.1\.2\)/, source,
      "the poller's jitter formula (poll_seconds * rand(0.8..1.2)) must not drift silently")
  end
end
