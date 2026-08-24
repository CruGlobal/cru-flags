# frozen_string_literal: true

require_relative "test_helper"
require "cru_flags"

class VersionTest < Minitest::Test
  def test_version_is_a_frozen_semver_string
    assert_match(/\A\d+\.\d+\.\d+\z/, CruFlags::VERSION)
    assert_predicate CruFlags::VERSION, :frozen?
  end
end
