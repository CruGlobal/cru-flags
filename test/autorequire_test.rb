# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

# Bundler's autorequire derives candidate require paths from the gem NAME,
# not from the gemspec's actual entry point: for `gem "cru-flags"` it tries
# "cru-flags", then "cru-flags".tr("-", "/") == "cru/flags" (Bundler::Runtime
# #require, `required_file.tr("-", "/")`) — and swallows the LoadError when
# neither exists, so an app that adds this gem without an explicit
# `require: "cru_flags"` gets NO error, just a Railtie that never loads and
# flags that silently read false forever. This proves the hyphenated name
# Bundler actually tries is loadable, in a bare subprocess so it can't be
# fooled by this test process already having required "cru_flags" some
# other way.
class AutorequireTest < Minitest::Test
  RUBY = RbConfig.ruby
  LIB = File.expand_path("../lib", __dir__)

  def test_requiring_by_the_hyphenated_gem_name_loads_the_library
    script = 'require "cru-flags"; ' \
      "exit((defined?(CruFlags::Railtie) || defined?(CruFlags)) ? 0 : 1)"
    stdout, stderr, status = Open3.capture3({"RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil},
      RUBY, "-I", LIB, "-e", script)
    assert status.success?,
      "`require \"cru-flags\"` (what Bundler autorequire actually tries for " \
      "gem \"cru-flags\") must load the library:\nstdout: #{stdout}\nstderr: #{stderr}"
  end
end
