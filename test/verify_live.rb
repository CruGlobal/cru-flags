# frozen_string_literal: true

# Opt-in, NETWORKED verification against the real public endpoint.
# Deliberately not part of CI (design doc §9). Run:
#   CRU_FLAGS_URL=https://deploys.cru.org/flags/ararat/release-candidate ruby -Ilib test/verify_live.rb
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cru_flags"

abort "set CRU_FLAGS_URL" unless ENV["CRU_FLAGS_URL"]
abort "not ready within 15s" unless CruFlags.ready(timeout: 15)
snap = CruFlags.snapshot
%w[Project Environment Version Flags].each do |key|
  abort "snapshot missing #{key}: #{snap.keys}" unless snap.key?(key)
end
abort "second conditional fetch should be fresh (304 path)" unless CruFlags.refresh(force: true)
puts "OK: #{snap["Project"]}/#{snap["Environment"]} v#{snap["Version"]}, #{snap["Flags"].size} flag(s)"
