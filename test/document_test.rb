# frozen_string_literal: true

require_relative "test_helper"
require "cru_flags"
require "json"

class DocumentTest < Minitest::Test
  REAL_DOC = {
    "Project" => "ararat", "Environment" => "release-candidate",
    "Version" => 3, "NotifySlack" => true,
    "Flags" => {"pilot_banner" => {"Enabled" => true, "UpdatedBy" => "Omicron7"}},
    "FutureKey" => {"nested" => [1, 2]}
  }.freeze

  def test_parses_and_deep_freezes_preserving_unknown_keys
    doc = CruFlags::Document.parse(JSON.generate(REAL_DOC))
    assert_equal true, doc.dig("Flags", "pilot_banner", "Enabled")
    assert_equal({"nested" => [1, 2]}, doc["FutureKey"])
    each_node(doc) { |node| assert_predicate node, :frozen? }
  end

  def test_missing_or_nil_flags_becomes_empty_hash
    assert_equal({}, CruFlags::Document.parse("{}")["Flags"])
    assert_equal({}, CruFlags::Document.parse('{"Flags": null}')["Flags"])
  end

  def test_empty_constant_is_deep_frozen
    assert_predicate CruFlags::Document::EMPTY, :frozen?
    assert_predicate CruFlags::Document::EMPTY["Flags"], :frozen?
  end

  def test_wrong_type_flags_fails_the_document
    ["[]", '"x"', "3"].each do |bad|
      assert_raises(CruFlags::ParseError) { CruFlags::Document.parse(%({"Flags": #{bad}})) }
    end
  end

  def test_non_hash_flag_entries_are_dropped_without_failing
    doc = CruFlags::Document.parse('{"Flags": {"good": {"Enabled": true}, "bad": 7}}')
    assert_equal %w[good], doc["Flags"].keys
  end

  def test_non_object_bodies_raise_parse_error
    ["not json", "[]", '"str"', "null"].each do |bad|
      assert_raises(CruFlags::ParseError) { CruFlags::Document.parse(bad) }
    end
  end

  def test_round_trips_through_json
    doc = CruFlags::Document.parse(JSON.generate(REAL_DOC))
    assert_equal doc, JSON.parse(JSON.generate(doc))
  end

  private

  def each_node(node, &block)
    yield node
    case node
    when Hash
      node.each do |k, v|
        each_node(k, &block)
        each_node(v, &block)
      end
    when Array then node.each { |v| each_node(v, &block) }
    end
  end
end
