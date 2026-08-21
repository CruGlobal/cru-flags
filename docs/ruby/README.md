# cru-flags

> **Status: AI-generated, not actively maintained by a human team.** This
> library was authored primarily by an AI assistant against the specification
> in [docs/design.md](docs/design.md), reviewed and operated by the Cru Rails
> team. Read the design doc before changing behavior — drift between the
> design doc and the code is a bug, and the doc wins.

The official Ruby client for Cru's pipeline feature-flag service, and the
third sibling of [cru-flags-node](https://github.com/CruGlobal/cru-flags-node)
and [cru-flags-python](https://github.com/CruGlobal/cru-flags-python) — plus a
read-only Flipper adapter so the Rails fleet's existing `Flipper.enabled?`
call sites work unchanged.

```ruby
# In a Rails app: add the gem, done. The Railtie wires Flipper for you.
Flipper.enabled?(:checkout_v2)

# Anywhere else:
require "cru_flags"
CruFlags.enabled?("checkout_v2")
```

Configuration is one environment variable: `CRU_FLAGS_URL`, the full document
URL (`https://deploys.cru.org/flags/<project>/<environment>`). Unset means
every flag is off and nothing starts — no thread, no socket, no warning.

Semantics in one paragraph: the client polls the document in a background
thread (30s ± 20% jitter, 2s timeouts, conditional GETs via ETag) and answers
reads from a frozen in-memory snapshot. **Fail-static**: all flags are off
until the first successful fetch; after that, an outage means flags stop
changing — never that they turn off. Reads never raise and never do I/O.
Health transitions (and only transitions) are logged.

CRuby >= 3.2 only. See [docs/design.md](docs/design.md) for everything else.
