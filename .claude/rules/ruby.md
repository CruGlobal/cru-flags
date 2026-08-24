# CLAUDE.md

`docs/design.md` is the authoritative specification for this library. Drift
between the design doc and the code is a bug, and the doc wins. Any PR that
changes designed behavior MUST update `docs/design.md` in the same PR.

This gem is the third sibling of cru-flags-node and cru-flags-python. The
three share one behavioral contract; before changing contract-level behavior
here, check whether the siblings need the same change and say so in the PR.

Rules:
- The client core stays stdlib-only. `flipper` is the only real runtime
  dependency, and it exists only for the adapter + Railtie. The gemspec's
  other entry, `json >= 2.4`, is a version floor on a default gem, not a
  library we depend on — and it must stay: `JSON.parse(..., freeze: true)`
  is what deep-freezes the published document, and json below 2.4 silently
  ignores `freeze:`, which would quietly unfreeze the snapshot that design
  doc §6's lock-free read path depends on.
- `enabled?` never raises and (in background mode) never does I/O.
- Tests run against a real local HTTP server, not mocks of Net::HTTP.
- `bundle exec rake` runs standardrb + the full suite; both must be green.
