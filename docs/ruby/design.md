# cru-flags-ruby — Design Document

> ADL-35. Drafted 2026-08-21 against cru-flags-python's docs/design.md (the
> most complete sibling spec) and the recon in adl-35-cru-flags-ruby-recon.md.
> When the CruGlobal/cru-flags-ruby repo is created this file moves in as
> `docs/design.md` and inherits the siblings' rule: drift between the design
> doc and the code is a bug, and the doc wins.

## 1. Purpose & Scope

`cru-flags` is the official Ruby client for Cru's pipeline feature-flag
service, and the third sibling of `@cruglobal/flags` (Node) and `cru-flags`
(Python). It answers exactly one question, as cheaply and as safely as
possible:

```ruby
Flipper.enabled?(:checkout_v2)   # the fleet's existing call sites, unchanged
CruFlags.enabled?("checkout_v2") # the sibling-parity API, same answer
```

The flag service publishes one JSON document per (project, environment) at a
public HTTP endpoint. This library polls that document in the background and
answers reads from an in-memory snapshot. It is a **read-only client**: flags
are authored elsewhere (cru-cli / the deploys.cru.org dashboard), never by
this library.

The Ruby client differs from its siblings in one deliberate way: it ships a
**Flipper adapter** that answers Flipper's read API from the same in-memory
snapshot. The ~20 Rails apps already call `Flipper.enabled?` (ADL-9's
ratified standard; ararat's hand-rolled `flipper.rb` is the current
reference), so the gem keeps that API working while replacing everything
underneath it. What it replaces, and why, is §4.

### In scope for v0.x

- Read `CRU_FLAGS_URL` from the environment; poll that URL in a background
  thread; answer `enabled?(name)` from the last document received.
- Conditional requests (`If-None-Match` / `ETag`) so steady-state polling
  costs one 304 per interval.
- An opt-in `refresh_mode: "on-demand"` that drops the thread and refreshes
  synchronously on the reading thread, for runtimes that freeze between
  requests (§7.1) — included for contract parity with the siblings.
- **Fail-static** semantics: a flag lookup never raises, never blocks (in
  background mode), and never changes answer because the network broke.
- A read-only `Flipper::Adapters::CruFlags` over the snapshot, plus a Railtie
  that wires it into Flipper with zero app code.
- Stdlib-only client core (`net/http`, `json`, `thread`); Ruby >= 3.2.

### Out of scope

- **Writing** flags, or any authentication. The flag documents are public,
  read-only URLs.
- Per-actor / group / percentage targeting, variants, or non-boolean flag
  values. The service models a flag as a boolean with metadata; so does this
  client. The Flipper adapter exposes **only the boolean gate**.
- Local flag overrides, file-based sources, streaming, or a daemon/sidecar.
- The service's `/flipper/{project}/{env}/features` protocol endpoints. Stock
  Flipper's HTTP adapter needed them; ours reads the snapshot, so the
  collection/single-feature asymmetries documented in the recon simply never
  come into play.

### Non-goals

- We do **not** try to be a general feature-flag SDK. There is one document
  shape, defined by our own service, and this client is allowed to know it.
- We do **not** raise on misconfiguration. An application missing
  `CRU_FLAGS_URL` must still boot and serve traffic, with every flag off —
  exactly ararat's current Memory-adapter fallback posture.
- We do **not** cache in `Rails.cache`. The snapshot is process-local memory;
  there is no TTL, no Marshal round-trip, and therefore no TTL cliff and no
  default_proc trap (§4).

---

## 2. Wire contract

Identical to the siblings'. The live document (a real response from
`https://deploys.cru.org/flags/ararat/release-candidate`):

```json
{
  "Project": "ararat",
  "Environment": "release-candidate",
  "Version": 3,
  "NotifySlack": true,
  "Flags": {
    "pilot_banner": {
      "Enabled": true,
      "Description": "Pilot: flag-gated banner proving the flag service end-to-end (ararat#198)",
      "CreatedAt": "2026-07-31T14:09:01.119Z",
      "UpdatedAt": "2026-07-31T14:09:08.777Z",
      "UpdatedBy": "Omicron7"
    }
  }
}
```

Load-bearing properties:

| Property | Contract |
| --- | --- |
| Top level | JSON object with `Project`, `Environment`, `Version`, `NotifySlack`, `Flags`. PascalCase keys. |
| `Flags` | Object keyed by flag name. Each value is an object with at least `Enabled: bool`; other keys are metadata. |
| Unknown keys | **Additive.** New top-level and per-flag keys may appear at any time; the client ignores what it does not understand and never validates beyond "is a JSON object". |
| `ETag` | Present on `200`, currently the stringified `Version`. Opaque to the client — store and echo it, never parse it. |
| `304 Not Modified` | Returned when `If-None-Match` matches. Body empty; the previous snapshot stays in force. |
| `404 Not Found` | A *valid* answer meaning "no document exists yet", not a failure. |
| `400 Bad Request` | The URL names an environment that does not exist (only `release-candidate` and `production` are real). This *is* a failure: the caller's configuration is wrong and someone should see it. |

`enabled?(name)` is defined precisely as:

```ruby
document.dig("Flags", name, "Enabled") == true
```

The `== true` identity check (not truthiness) is deliberate: a flag whose
`Enabled` is the *string* `"true"`, or `1`, or `null` is a malformed
document, and the safe reading of a malformed document is "off".

---

## 3. Public API

```ruby
CruFlags.enabled?("checkout_v2")  # -> bool, never raises
CruFlags.ready(timeout: 3.0)      # -> bool, never raises
CruFlags.snapshot                 # -> Hash, plain JSON-serializable deep copy
CruFlags.refresh(force: false)    # -> bool, refresh now on this thread
CruFlags.close                    # -> nil, stop refreshing (mostly for tests)
CruFlags.flipper_adapter          # -> the read-only Flipper adapter (§5)

CruFlags::Client.new(
  url: nil,            # nil -> read CRU_FLAGS_URL on first use
  poll_seconds: 30.0,  # refresh interval, ±20% jitter
  fetch_timeout: 2.0,  # per-request open AND read timeout
  on_error: nil,       # nil -> log to the "cru_flags" logger (§3.6)
  refresh_mode: nil    # nil -> read CRU_FLAGS_REFRESH_MODE, else "background"
)
```

### 3.1 `CruFlags` module methods

The module methods delegate to a lazily-constructed process-wide
`CruFlags::Client` singleton — the 99% path, mirroring the siblings'
module-level `flags`. Requiring the gem does **nothing**: no environment
read, no socket, no thread (§7). The singleton is constructed on first use,
so tests and dotenv can set `CRU_FLAGS_URL` any time before the first lookup.

### 3.2 `enabled?(name) -> bool`

Non-blocking read of the current snapshot (in on-demand mode it may refresh
first; §7.1). **Never raises** — the entire body is rescued so no bug in this
library, no malformed document, and no shutdown race can take down a caller's
request path. Anything unexpected answers `false`. Accepts a String or
Symbol; Symbols are converted with `to_s` (the document's keys are strings;
Flipper call sites pass symbols).

Unknown flag, unset flag, no document yet, no `CRU_FLAGS_URL`, service down
before the first success — all `false`.

### 3.3 `ready(timeout: nil) -> bool`

Blocks until the **first fetch attempt completes** — success *or* failure —
and returns whether it completed within `timeout`. Returns `true` after a
failed first attempt (the attempt did complete, and "all off" is the final
answer until the next poll). Returns `false` immediately, without blocking,
when the client is inert (no URL) — there is no attempt to wait for and never
will be. In on-demand mode `ready` *performs* the first attempt like any
other read, so `timeout:` is unused there — the call is bounded by the fetch
timeouts (up to ~2s by default) regardless of a smaller `timeout:` value,
exactly as the python client documents. Never raises.

### 3.4 `snapshot -> Hash`

A plain, deep-copied, JSON-serializable Hash of the last document received
(`{}` before the first success). `JSON.generate(CruFlags.snapshot)`
round-trips to exactly what the service sent. The copy exists so a caller
cannot mutate library state; the internally stored snapshot is genuinely
frozen (§6).

### 3.5 `refresh(force: false) -> bool`

Fetches on the *calling* thread and returns whether the snapshot is fresh (an
attempt has completed and the most recent one succeeded). Without `force` it
is a no-op while the last attempt is younger than `poll_seconds`. Blocks for
at most the fetch timeouts. Never raises. This is the refresh primitive in
on-demand mode, and an out-of-band poke in background mode — where, per the
Node contract, concurrent `refresh` calls and a concurrent poller tick all
**share one in-flight request** rather than stacking simultaneous fetches.

### 3.6 `on_error`

A callable invoked **only on health transitions**:

- ok → failing: called with the exception that broke the poll.
- failing → ok: called with `nil` (recovery).

Never called per-poll while a failure persists, and never for `304` or `404`.
The default logs both transitions at WARN — to `Rails.logger` when Rails is
loaded, else to a `Logger` on `$stderr` tagged `cru_flags`. This is the
structural replacement for ararat's `LoggedFlagFetches` delegator: the two
2026-07-31 outages that motivated it were invisible precisely because
failures were swallowed silently; transition logging makes an outage exactly
two log lines (one down, one up) instead of zero or thousands. Exceptions
raised *by* `on_error` are swallowed: a broken error handler must not kill
the poller.

### 3.7 `close`

Stops refreshing, in either mode. Terminal: a closed client never refreshes
again, and closing before the first lookup leaves the client permanently
inert. The last snapshot stays readable. Mostly useful in tests.

---

## 4. Why fail-static (and what this replaces)

The design constraint is inverted relative to a normal HTTP client: **the
flag client is allowed to be wrong, but never allowed to be loud, slow, or
fatal.**

1. **`enabled?` performs no I/O** in the default background mode: one ivar
   read and two Hash lookups. No lock on the read path, so a slow network can
   never become a slow request.
2. **All flags are `false` until the first successful fetch.** A flag guards
   *new* behaviour; the safe answer while ignorant is the old behaviour.
3. **Last-known-good persists indefinitely. There is no TTL.** This is the
   failure-mode semantic §6 of the fleet's original flags design doc (the
   Google-Doc-era spec, snapshotted as cru-flags-design-doc.md) promised and
   the current fleet recipe does not deliver: ararat composes `Flipper::Adapters::Failsafe` outside a
   30-second `ActiveSupportCacheStore`, so 30 seconds into any flag-service
   outage every flag snaps to `false` — a synchronised, fleet-wide behaviour
   change caused by exactly the outage a flag client should ride through.
   Holding the last deliberately-published configuration is the whole reason
   this gem exists. Freshness is a monitoring question (the transition log,
   `ready`, `snapshot["Version"]`), never a silent behaviour flip.
4. **404 is data, not an error.** "This project has no flags yet" is the
   normal state of every project on day one.
5. **Nothing raises.** `enabled?` and `ready` rescue `StandardError` —
   `Interrupt`, `SystemExit`, and other non-StandardError exceptions still
   propagate.

The stock-Flipper traps this architecture retires by construction (all
verified live in the recon):

- Flipper's Rails engine installs a **Memoizer middleware that preloads
  `get_all` on every request** — with a network adapter underneath, Failsafe
  is load-bearing and any gap 500s the whole app. Our adapter's `get_all` is
  a frozen-Hash read; the preload becomes free and Failsafe has nothing to
  guard.
- `Flipper::Adapters::Http` must be given `max_retries: 0` **explicitly**
  (its internal default never applies) and leaves open/read timeouts at
  Net::HTTP's ~60s unless set. Our HTTP layer sets 2s/2s explicitly and never
  sits on a request path.
- The `default_proc` that Marshal — and therefore any Marshal-backed
  `Rails.cache` — cannot serialize (ararat's `MarshalableFlipperReads`
  incident) is added by `Flipper::Adapters::Memoizable#get_all`
  (memoizable.rb:103 in 1.4.2), **which wraps ANY adapter the DSL is given,
  including ours** — not by the Http adapter as ararat's comments suggest.
  With no `Rails.cache` layer nothing ever Marshals the result, so the trap
  is gone — but Memoizable's mutation constrains our adapter's return values;
  see the hard rule in §5.

---

## 5. The Flipper adapter

`Flipper::Adapters::CruFlags` — a read-only adapter over the client's frozen
snapshot, so every existing `Flipper.enabled?(:name)` call site works
unchanged.

- `features` → the Set of flag names in the current document.
- `get(feature)` / `get_multi` / `get_all` → gate-value hashes shaped by
  `Flipper::Adapter.default_config` (which in 1.4 includes the `expression`
  gate key alongside boolean/actors/groups/percentages), with **only the
  boolean gate** populated: `true` when the flag's `Enabled == true`, off
  otherwise. The service is boolean-only.
- **HARD RULE: `get`, `get_multi`, and `get_all` must return freshly-built,
  UNFROZEN top-level Hashes on every call** (their nested gate values may
  reference frozen snapshot data; the top-level containers may not be
  frozen and may not be memoized/shared). Flipper's DSL wraps every adapter
  in `Adapters::Memoizable` by default, and its `get_all` **mutates the
  returned Hash in place** (`response.default_proc = ...`,
  memoizable.rb:103) on every Memoizer-preloaded request — a frozen or
  shared return value raises `FrozenError` on every request in production,
  a stricter recurrence of the very failure mode §4 retires. The suite
  pins this with a test that calls the adapter through
  `Flipper::Adapters::Memoizable` under memoization.
- `add` / `remove` / `clear` / `enable` / `disable` →
  raise `CruFlags::ReadOnlyError`. The CLI and dashboard are the only
  writers; this preserves the behavior of ararat's
  `Flipper::Adapters::ReadOnly` wrapper (whose own error class is
  `ReadOnly::WriteAttempted`) without another wrapper layer.
- The adapter holds no state of its own and takes no locks — it reads
  whatever frozen document the client currently publishes, so a Memoizer
  preload, a console `Flipper.enabled?`, and a background job all see the
  same atomically-swapped snapshot.

### 5.1 Railtie

`require "cru_flags"` in a Rails app (via the Gemfile) installs a Railtie
that, in an initializer:

- registers the adapter via `Flipper.configure { |c| c.adapter { CruFlags.flipper_adapter } }`
  in an ordinary initializer — safe against ordering because Flipper's engine
  resolves `config.adapter` LAZILY on first `Flipper.instance` access (its
  `flipper.default` block calls it at invocation time, not at boot), and the
  last `AdapterBuilder#store` wins, so an app's own `Flipper.configure` in
  `config/initializers` still overrides ours;
- quiets strict mode for the no-flag-document case, **but not with a naive
  "unless the app set it" check** — Flipper's engine populates
  `config.flipper.strict` in `config.before_configuration` (`:warn` in
  development, `false` in production), which runs before ANY gem initializer,
  so the value is always already set when we look. Instead the Railtie sets
  `config.flipper.strict = false` only when `ENV["FLIPPER_STRICT"].nil?` AND
  the current value equals Flipper's own computed default for this Rails env —
  i.e. only when we can prove nobody chose it. `FLIPPER_STRICT=warn` (or any
  app-set value) is always honored. Rationale: local dev and brand-new
  projects legitimately have no flag document, and `Flipper.add` is never
  called by app code (flags are born in the service), so dev-mode `:warn`
  would fire on every check.

With `CRU_FLAGS_URL` unset the client is inert, the snapshot is empty, and
every flag reads `false` — byte-for-byte ararat's current Memory-adapter
fallback, with zero configuration branching. An app that wants different
wiring (a test adapter, Flipper UI in development) configures Flipper itself;
the Railtie only supplies the default.

Non-Rails Ruby (plain scripts, sidekiq-less workers) skips the Railtie and
uses `CruFlags.enabled?` directly.

---

## 6. Snapshot storage & atomicity

The parsed document is **deep-frozen** before it is published — via
`JSON.parse(body, freeze: true)` (json >= 2.4, which also interns repeated
strings) rather than a hand-rolled recursive walk. The frozen tree is then
assigned to a single instance variable — one atomic reference swap — while
holding a mutex that only *writers* contend for. Readers never take the lock.

The lock-free read depends on CRuby's GVL making a single reference store
observable atomically; **the gem supports CRuby only** (the entire fleet is
CRuby; JRuby/TruffleRuby have no GVL and would need a read barrier we have no
consumer for). The gemspec/README say so.

Why frozen rather than "a hash we promise not to mutate": the snapshot is
shared across every thread in the process, and one accidental
`snapshot["Flags"]["x"]["Enabled"] = true` in caller code would be an
un-debuggable, cross-thread, non-reproducible bug. Freezing makes it a
`FrozenError` at the point of the mistake. `CruFlags.snapshot` hands back a
thawed deep copy so the public API stays ordinary Ruby.

Consistency guarantee: a reader sees either the whole old document or the
whole new one, never a half-applied update.

---

## 7. Threading model

- **One background Thread per active client**, `Thread#name` set to
  `"cru-flags-poller"`, `abort_on_exception` left false, `report_on_exception`
  set false (the loop rescues everything; a teardown race must not spam
  stderr).
- **Started lazily** on the first `enabled?` / `ready` call, never at
  require. Requiring a gem must not start threads: it breaks preloading
  forking servers (Puma workers, Spring) that require before forking, and
  makes `require "cru_flags"` in a test suite a side-effecting act. **After
  `fork`, the child re-starts its own poller lazily on first read** — the
  client detects a PID change and discards the parent's dead thread state
  (Puma's `fork_worker` and Spring both make this a first-class case in
  Rails, where the siblings could treat forking as exotic).
- **Never delays exit.** Ruby threads other than the main thread die with
  the process — no daemon flag needed — but the loop also sleeps
  interruptibly (a `Queue#pop` with timeout / `ConditionVariable#wait`), so
  `close` returns promptly instead of waiting out a poll interval.
- **Jitter**: each sleep is `poll_seconds * rand(0.8..1.2)`. Fleet pods boot
  together; without jitter they synchronise into a thundering herd against
  the flag service. ±20% de-phases them within a couple of intervals.
- **Inert clients start nothing.** No `CRU_FLAGS_URL` and no explicit `url:`
  means no thread, no socket, no warning — just `false`.

### 7.1 On-demand refresh (`refresh_mode: "on-demand"`)

Contract-identical to the siblings' mode (python design §5.1): no poller
thread at all; every read fetches first when the last **attempt** is
`poll_seconds` or older, else answers from cache. Concurrent readers coalesce
on one mutex — a burst of N readers is one request. Staleness anchors on the
last attempt, not the last success, so a dead service costs one failed
request per interval, not one per read. No jitter (real traffic de-phases
itself). The cost is the read-path guarantee: `enabled?` can block up to the
fetch timeouts, once per interval.

Selecting it: `Client.new(refresh_mode: "on-demand")` or
`CRU_FLAGS_REFRESH_MODE=on-demand`. The constructor argument wins. An
unrecognised *environment* value warns through `on_error` and falls back to
background (misconfiguration must never stop boot); an unrecognised
*constructor* argument raises `ArgumentError` (that is a typo in code).

Why it ships at all: the Rails fleet is long-running ECS and will use
background mode everywhere — but the three clients advertise one contract,
the mode is ~100 lines plus ported tests, and the first Cloud-Run-shaped
Ruby consumer gets it for free instead of forking the gem.

### 7.2 Environment resolution

`CRU_FLAGS_URL` and `CRU_FLAGS_REFRESH_MODE` are read once, at first use, and
cached. Empty or whitespace-only counts as unset. Only `http`/`https` URLs
are accepted; anything else makes the client inert with one warning through
`on_error`.

---

## 8. Fetch algorithm

One tick:

1. Build a `Net::HTTP::Get` with `Accept: application/json`, a `User-Agent`
   of `cru-flags-ruby/<version>`, and `If-None-Match: <etag>` when an ETag is
   stored.
2. One-shot `Net::HTTP.start(host, port, use_ssl:, open_timeout: t,
   read_timeout: t, write_timeout: t)` — no keep-alive, no connection
   pooling; the right trade for one request per 30 seconds. **No retries
   within a tick** — the next tick is the retry. Redirects are followed to a
   fixed limit of **3** (Net::HTTP does not follow them itself; the siblings
   inherit auto-follow from `fetch`/`urllib`).
3. Outcomes:

   | Outcome | Action | Health |
   | --- | --- | --- |
   | `200` + JSON object | Freeze and publish; **then** store `ETag` | ok |
   | `304` | Keep snapshot and ETag | ok |
   | `404` | Publish empty snapshot; clear ETag | ok |
   | Other status (`400`, `5xx`, …) | Keep snapshot | failing |
   | Timeout / DNS / connection error | Keep snapshot | failing |
   | Body not JSON, or not a JSON object | Keep snapshot | failing |

   Document-before-ETag ordering is load-bearing (inherited from the Node
   client): a body that fails to parse must never get its ETag stored, or
   the client would pin itself to the bad response via endless 304s.

4. Report the health transition (§3.6), if any.

Parsing is lenient exactly like the siblings, with the Node client's §6.1
rules as the reference: missing/`null` `Flags` becomes `{}`, but `Flags`
**present with the wrong type** (a string, number, or array) fails the whole
document (health → failing) — leniency is for absence, not for malformation.
Individual non-Hash flag *entries* are dropped without failing the document;
all unknown keys are preserved verbatim. (§2's "never validates beyond is-a-
JSON-object" is scoped by these rules, same as the siblings' docs.)

---

## 9. Testing strategy

Every line of the behavioural contract is a test, in the python client's
organisation: contract tests grouped by design-doc section, against **a real
local HTTP server** (a minimal programmable responder on a stdlib
`TCPServer` at `127.0.0.1:0` — WEBrick is no longer a default gem and the
responder needs ~60 lines), recording inbound headers so the ETag echo, 304,
404, 500, slow-response, and malformed-body paths exercise real `Net::HTTP`
behaviour rather than a mock's idea of it.

Plus, ported from the siblings and ararat:

- Subprocess tests: `require "cru_flags"` starts no threads even with
  `CRU_FLAGS_URL` set; a running poller never delays interpreter exit.
- A fork test: parent warms the client, child forks, child's reads work and
  spawn the child's own poller (§7's PID-change case).
- Jitter distribution; a concurrency hammer on `enabled?` across snapshot
  swaps; `JSON.generate`/`parse` round-trip of `snapshot`.
- Flipper conformance: `Flipper.new(CruFlags.flipper_adapter)` answering
  `enabled?` end-to-end against the local server, the Memoizer preload path,
  writes raising `ReadOnlyError`, and — the regression ararat paid for —
  `Marshal.dump(Rails.cache-shaped round trip)` of everything `get_all`
  returns.
- On-demand mode: its own section (coalescing, one-fetch-per-interval while
  down, no thread).
- `test/verify_live.rb`, opt-in and networked, against the real public
  endpoint (document parses; second conditional fetch is 304). Not in CI.

Framework: minitest (the fleet standard), `filterwarnings`-equivalent
strictness via `Warning[:deprecated] = true` and a test that the suite emits
no warnings. CI: one required check running lint (standardrb, the fleet
direction per AP-7) + the suite on the `.tool-versions` Ruby, plus a matrix
re-running the suite on 3.2 / 3.3 / 3.4.

---

## 10. Packaging & distribution

- Gem `cru-flags`, require path `cru_flags`, module `CruFlags`, repo
  `CruGlobal/cru-flags-ruby`. Version lives in `lib/cru_flags/version.rb`,
  bumped by release-please (`release-type: ruby` **with an explicit
  `"version-file": "lib/cru_flags/version.rb"`** — release-please's default
  path derivation turns the hyphenated name into `lib/cru/flags/version.rb`
  and would silently bump a file that doesn't exist).
- `required_ruby_version = ">= 3.2"` — the fleet floor.
- Runtime dependency: **`flipper` (`~> 1.4`) only.** The client core uses
  stdlib exclusively; the Flipper adapter and Railtie are the gem's reason to
  have its one dependency, and every consumer already carries it. (If a
  flipper-less consumer ever appears, splitting a zero-dep core gem out is a
  follow-up, not a v0 concern.)
- Publishing via **RubyGems Trusted Publishing** (OIDC) from
  `.github/workflows/release.yml` — the PyPI pattern; no API key in the
  repo. First publish uses RubyGems' pending-publisher flow since the gem
  name is unclaimed.
- Repo onboarding matches the fleet standard from day one: security-only
  `dependabot.yml` (bundler + github-actions lanes per the ADL-32 template),
  a `dependabot-auto-merge` gate is NOT installed (review-tier repo), README
  status banner and CLAUDE.md same-PR-doc rule copied from the siblings.

---

## 11. Rollout (out of scope for the gem, recorded for sequencing)

1. Gem ships and publishes v0.1.0.
2. ararat cuts over: Gemfile swap, delete `config/initializers/flipper.rb`
   and its two regression tests (their scenarios live in the gem's suite
   now). ararat is the proving ground exactly as it was for the hand-rolled
   version.
3. devops-claude-skills onboarding skill Stage 4 changes from "copy ararat's
   flipper.rb" to "add the cru-flags gem".
4. The remaining fleet picks it up as apps onboard to v2 (no mass retrofit —
   only ararat and clm are on v2 today).

Each step is its own PR with its own review; none blocks the gem.
