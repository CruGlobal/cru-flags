# frozen_string_literal: true

# Bundler's autorequire derives the require path from the GEM NAME
# ("cru-flags" -> "cru-flags", then "cru/flags"), never from the real entry
# point ("cru_flags") — so `gem "cru-flags"` (no explicit `require:`) loads
# THIS file. Do not delete: without it, autorequire silently no-ops (the
# LoadError is swallowed) and the Railtie never loads.
require "cru_flags"
