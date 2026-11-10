# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Design doc §9's "filterwarnings-equivalent strictness": force Ruby's
# deprecation-warning category on (off by default outside `-w`) and collect
# every Warning.warn call so the suite can fail on any of them, instead of
# them silently scrolling past in stderr.
Warning[:deprecated] = true

CRU_FLAGS_COLLECTED_WARNINGS = []

# Exact-message allow-list for a THIRD-PARTY deprecation we don't control
# (flipper/rails/ruby itself) that we can't fix here. Empty today; if one
# ever fires, add its exact text with a comment explaining why it's not
# fixable in this repo, per finding F2 of the 2026-08-21 final review.
CRU_FLAGS_ALLOWED_WARNINGS = [].freeze

module Warning
  class << self
    alias_method :cru_flags_original_warn, :warn
  end

  def self.warn(message, category: nil)
    cru_flags_original_warn(message, category:)
    return if CRU_FLAGS_ALLOWED_WARNINGS.any? { |allowed| message.include?(allowed) }
    CRU_FLAGS_COLLECTED_WARNINGS << message
  end
end

require "minitest/autorun"

Minitest.after_run do
  # A snapshot, and $stderr.write rather than Kernel#warn (or $stderr.puts,
  # standard's suggested replacement): this summary must not itself route
  # back through Warning.warn, or each line printed here would be collected
  # into the very array being iterated, growing it without end.
  warnings = CRU_FLAGS_COLLECTED_WARNINGS.dup
  unless warnings.empty?
    $stderr.write "\n#{warnings.size} warning(s) were emitted during the test run " \
      "(design doc §9 requires a warning-free suite):\n"
    warnings.each { |w| $stderr.write "  #{w}\n" }
    exit(1)
  end
end
