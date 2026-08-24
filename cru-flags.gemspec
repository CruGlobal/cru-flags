# frozen_string_literal: true

require_relative "lib/cru_flags/version"

Gem::Specification.new do |spec|
  spec.name = "cru-flags"
  spec.version = CruFlags::VERSION
  spec.authors = ["Cru"]
  spec.email = ["apps@cru.org"]
  spec.summary = "Official Ruby client for Cru's pipeline feature-flag service"
  spec.description = "Polls the flag service's per-(project, environment) JSON document, " \
    "answers reads from a frozen in-memory snapshot with fail-static semantics, and ships " \
    "a read-only Flipper adapter for the Rails fleet. CRuby only. See docs/design.md."
  spec.homepage = "https://github.com/CruGlobal/cru-flags-ruby"
  spec.license = "BSD-3-Clause"
  spec.required_ruby_version = ">= 3.2"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md", "docs/design.md"]
  spec.require_paths = ["lib"]

  # The ONE runtime dependency, and only for the adapter + Railtie (design doc §10).
  spec.add_dependency "flipper", "~> 1.4"

  # json >= 2.4 is the first release whose JSON.parse honors freeze: true;
  # older json versions silently ignore it, which would quietly unfreeze the
  # snapshot the whole read path depends on being immutable (design doc §6).
  spec.add_dependency "json", ">= 2.4"
end
