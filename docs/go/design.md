# Go client (`github.com/CruGlobal/cru-flags`) — Design Document

This is the authoritative specification for the Go client. Drift between this
document and the code is a bug, and the document wins. A change to designed
behavior updates it in the same PR.

The Go client is the fourth client for the pipeline feature-flag service. The
behavior all four share is pinned by the conformance suite
(`conformance/cases.json`), and the reasoning behind most of it is in the
TypeScript client's design doc ([`docs/node/design.md`](../node/design.md)),
which this client follows closely. This document covers the API and the
places where Go needs its own answer.

## 1. Scope

In scope: reading one flag document over HTTP, keeping it current by polling
or on demand, answering `Enabled(name)` from memory, and reporting health
transitions. Out of scope, as for every client: writing flags (the `cru app
flags` CLI is the only writer), per-user targeting, streaming, local
overrides, and usage reporting.

Standard library only, permanently. Every Go app at Cru that imports this
inherits its dependencies; CI fails if `go mod tidy` changes `go.mod`.

## 2. The wire contract

As in [`docs/node/design.md`](../node/design.md) §2, unchanged:

| Response                    | Client behavior                                                       |
| --------------------------- | --------------------------------------------------------------------- |
| `200` + body + `ETag`       | Parse; store the document and its `ETag`. Healthy.                     |
| `304`                       | Keep the document (the same pointer). Healthy.                         |
| `404`                       | No document: every flag off, and the `ETag` is forgotten. Healthy.     |
| other status, network error | Failure. The document and `ETag` stay as they were.                    |

`Enabled(name)` is true exactly when the document's `Flags[name].Enabled` is
the JSON literal `true`. Parsing rejects only a body that is not a JSON
object, or whose `Flags` is present and not an object (§6.1 of the Node
document): unknown keys are ignored, a non-object flag entry is dropped, and a
mistyped metadata field is left at its zero value.

A rejected `200` body never stores its `ETag`: storing it would make every
later poll a `304` for a body the client never accepted.

## 3. API

```go
// Package-level functions use a default client built from the environment.
func Enabled(name string) bool
func Ready(ctx context.Context) bool
func Refresh(ctx context.Context) bool
func Snapshot() *Document
func Default() *Client

func New(opts Options) *Client
func (c *Client) Enabled(name string) bool
func (c *Client) Ready(ctx context.Context) bool
func (c *Client) Refresh(ctx context.Context) bool
func (c *Client) ForceRefresh(ctx context.Context) bool
func (c *Client) Snapshot() *Document
func (c *Client) Close()

type Options struct {
	URL          string            // default $CRU_FLAGS_URL, read at first use
	PollInterval time.Duration     // default 30s
	FetchTimeout time.Duration     // default 2s
	RefreshMode  RefreshMode       // Background or OnDemand; default $CRU_FLAGS_REFRESH_MODE, else Background
	OnError      func(HealthEvent) // default: slog.Default() at Warn
}
```

- **`Enabled` never blocks, never panics and returns no error.** It recovers
  from any panic and answers false. On a nil `*Client` it answers false.
- **The zero `Client` works** and behaves like `New(Options{})`: everything
  `New` would allocate is set up on first use, so a `Client` declared as a
  variable or embedded by value in a struct cannot crash a fetch goroutine.
- **`Ready` returns a bool, not an error.** It reports whether the first
  fetch settled before `ctx` ended, not whether it succeeded: it is a warmup
  hook, not a health check. An inert client returns true at once (there is
  nothing to wait for, and "settled" is the honest answer), unlike the Python
  and Ruby clients, which return false there. Returning true keeps
  `if !cruflags.Ready(ctx) { log... }` from logging on every developer
  laptop.
- **`Refresh` and `ForceRefresh`** match Node's `refresh()` and
  `refresh({ force: true })`. Both share a fetch already in progress, wait for
  it or for `ctx`, and report whether the document is fresh: an attempt has
  settled and the most recent one succeeded. An inert or closed client is
  never fresh. `ctx` bounds only the caller's wait; the shared fetch keeps
  its own `FetchTimeout`, so one caller giving up cannot abort it for others.
- **`Snapshot` returns a copy**, typed with the fields the service sends
  today. Unknown fields are not carried: Go has no frozen-object equivalent,
  and a typed copy is what a Go caller wants on a debug or health endpoint.
- **`FetchError`** carries `Code` (`http`, `network`, `timeout`, `parse`) and
  `Status`, as Node's `FlagsError` does. Only `HealthEvent.Err` carries one.

## 4. Behavior

### 4.1 Lazy start

`New` does nothing: no environment read, no goroutine, no request. The first
`Enabled`, `Ready`, `Refresh`, `ForceRefresh` or `Snapshot` call reads
`CRU_FLAGS_URL` and `CRU_FLAGS_REFRESH_MODE`, starts the first fetch and, in
background mode, the poller. The package's default client is therefore free
to build in a package-level `var`, and a test or `main` that sets the
environment after import still works.

### 4.2 Inert without a URL

No URL from `Options` or the environment: every flag off, no goroutine, no
request, no log line. Local development, CI, preview and lab have no flag
document, so this is a normal state.

### 4.3 Background polling

One goroutine fetches, waits for the fetch to settle, then sleeps
`PollInterval` times a random factor in [0.8, 1.2]. Scheduling after the
fetch settles means polls never overlap or queue behind a slow service; the
jitter keeps a fleet deployed together from polling in lockstep. Every poll
after a success sends `If-None-Match`. There are no retries within a poll.

Where Node `unref()`s its timer so it never holds the process open, Go needs
nothing: a Go program exits when `main` returns, whatever goroutines remain.
`Close` exists so tests and short-lived tools can stop the goroutine and wait
for it.

### 4.4 Fail-static

Before the first success every flag is off. After it, the last good document
is served through any number of failures, with no expiry. A 404 is the one
response that drops the document, because it is a successful answer meaning
"no flags".

### 4.5 On-demand refresh

With `RefreshMode: OnDemand` (or `CRU_FLAGS_REFRESH_MODE=on-demand`) there is
no poller. The first use still fetches once, so `Ready` behaves the same.
After that a read (`Enabled`, `Snapshot`) that finds the last attempt
`PollInterval` old starts a refresh and does not wait for it; `Refresh` starts
one and waits. Staleness is measured from the last attempt, not the last
success, so a dead service costs one request per interval rather than one per
read, and concurrent refreshes share one request.

This is how Lambda is handled, as in the Node client: a frozen process stops
the poller's clock, so on Lambda the app sets the variable, calls `Ready`
during init and `Refresh` at the top of the handler. The client does not
detect Lambda by itself, because the Node client does not, and the two should
not differ on when they poll.

An unrecognized mode, from `Options` or the environment, logs one warning and
falls back to background polling: a typo in a deployment's environment must
not stop the app from booting.

### 4.6 Bounds

- `FetchTimeout` (default 2s) bounds the whole fetch, body included.
- Bodies are capped at `MaxBodyBytes` (1 MiB). A larger `200` is a parse
  failure; the cap is enforced while reading, so an oversized body is never
  held in memory whole.
- At most three redirects are followed, matching the Python and Ruby clients.
- Requests send `User-Agent: cru-flags-go/<Version>`.

### 4.7 Health reporting

`OnError` is called on transitions only: `Failing` (with a `*FetchError`)
when a fetch fails after the client was healthy, and `Recovered` when one
succeeds after it was failing. It runs on the fetching goroutine, outside the
client's lock, and a panic in it is recovered.

It runs before the callers waiting on that fetch are released, so that by the
time `Ready` or `Refresh` returns, the event has been delivered (the
conformance cases check exactly that). The cost is that a handler must return
quickly, and must not call `Close`, `Ready`, `Refresh` or `ForceRefresh` on
the same client: those wait on the fetch that is running the handler, and
would deadlock. `Enabled` and `Snapshot` are safe in a handler. The same goes
for an `slog` handler when the default `OnError` is in use. The refresh-mode
warning, by contrast, is logged after start-up finishes, so an `slog` handler
that reads a flag cannot deadlock against it. The default logs both through
`slog.Default()` at Warn level, so an app that configures slog for its log
pipeline gets these lines in the same format with no wiring. A fetch that
`Close` abandoned is not reported.

## 5. Concurrency

Reads load an `atomic.Pointer[Document]` and look up a map that is never
written after it is published. They take no lock, except that an on-demand
read of a stale document, with no fetch already in flight, takes the client's
mutex briefly to start one. Atomic mirrors of "fetching" and "closed" let
every other on-demand read skip the lock, including all reads on an inert or
closed client.

`Close` may be called from several goroutines at once; every call returns
only after the poller and any abandoned fetch have exited. Fetches are serialized: a second refresh while one is in flight
waits on the first one's channel instead of starting another.

## 6. Testing

- `client_test.go` runs the client against real `httptest` servers, never a
  stubbed `http.RoundTripper`: `ETag` revalidation, timeouts and redirects
  are where a double would encode assumptions instead of testing them.
- `conformance_test.go` runs the shared cases against `conformance/server.py`.
- CI runs `go test -race`, `go vet` and golangci-lint on the `.tool-versions`
  Go, and the tests again on `go.mod`'s floor.
- No test reaches the real flag service.
