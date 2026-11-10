# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"
require "cru_flags/flipper_adapter" # not autoloaded by "cru_flags" alone (kept flipper-free)
require "flipper"

class FlipperAdapterTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @service.respond_with(status: 200,
      body: '{"Flags":{"pilot":{"Enabled":true},"dark":{"Enabled":false}}}')
    @client = CruFlags::Client.new(url: @service.url)
    @client.refresh(force: true)
    @adapter = CruFlags::FlipperAdapter.new(@client)
    @flipper = Flipper.new(@adapter)
  end

  def teardown
    @client.close
    @service.stop
  end

  def test_flipper_enabled_end_to_end
    assert @flipper.enabled?(:pilot)
    refute @flipper.enabled?(:dark)
    refute @flipper.enabled?(:absent)
  end

  def test_features_is_the_documents_flag_names
    assert_equal Set.new(%w[pilot dark]), @adapter.features
  end

  def test_gate_hashes_are_default_config_shaped
    gates = @adapter.get(@flipper.feature(:pilot))
    # Flipper::Adapter.default_config is not callable on the bare module in
    # 1.4.x (default_config lives on Adapter::ClassMethods, extended into
    # classes that `include Flipper::Adapter` — not into the module itself).
    # Flipper::Adapters::Memory is Flipper's own such class, so it's an
    # independent oracle for the canonical gate-value shape.
    assert_equal Flipper::Adapters::Memory.default_config.keys.sort, gates.keys.sort
    assert_equal true, gates[:boolean]
  end

  def test_get_multi_returns_correct_gate_hashes_including_an_absent_feature
    features = [@flipper.feature(:pilot), @flipper.feature(:dark), @flipper.feature(:absent)]
    result = @adapter.get_multi(features)
    assert_equal true, result["pilot"][:boolean]
    assert_nil result["dark"][:boolean]
    assert_nil result["absent"][:boolean]
  end

  def test_writes_raise_read_only_error
    feature = @flipper.feature(:pilot)
    assert_raises(CruFlags::ReadOnlyError) { @flipper.enable(:new_flag) }
    assert_raises(CruFlags::ReadOnlyError) { @flipper.disable(:pilot) }
    assert_raises(CruFlags::ReadOnlyError) { @adapter.add(feature) }
    assert_raises(CruFlags::ReadOnlyError) { @adapter.remove(feature) }
    assert_raises(CruFlags::ReadOnlyError) { @adapter.clear(feature) }
  end

  def test_get_all_survives_memoizable_mutation
    memoized = Flipper::Adapters::Memoizable.new(@adapter)
    memoized.memoize = true
    result = memoized.get_all # Memoizable sets default_proc on the returned Hash
    assert result.key?("pilot")
    assert_equal true, result["pilot"][:boolean]
  end

  def test_get_all_returns_a_fresh_unfrozen_hash_every_call
    a = @adapter.get_all
    b = @adapter.get_all
    refute_same a, b
    refute_predicate a, :frozen?
    a.default_proc = ->(h, k) { h[k] = nil } # the exact Memoizable mutation
  end

  def test_get_all_is_marshalable
    Marshal.dump(@adapter.get_all) # ararat's MarshalableFlipperReads regression
  end

  def test_inert_client_reads_all_off
    inert = CruFlags::Client.new(url: nil)
    flipper = Flipper.new(CruFlags::FlipperAdapter.new(inert))
    refute flipper.enabled?(:pilot)
    inert.close
  end
end
