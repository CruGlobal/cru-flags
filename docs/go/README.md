# cruflags (Go)

[![Go Reference](https://pkg.go.dev/badge/github.com/CruGlobal/cru-flags.svg)](https://pkg.go.dev/github.com/CruGlobal/cru-flags)

The Go client for Cru's pipeline feature-flag service. It reads one URL from
the environment, keeps that flag document current in the background, and
answers flag reads from memory:

```go
import cruflags "github.com/CruGlobal/cru-flags"

if cruflags.Enabled("checkout_v2") {
	// ...
}
```

`Enabled` never blocks, never fails and never panics. Unknown flags, a missing
`CRU_FLAGS_URL` and an unreachable flag service all read off. Standard library
only, Go 1.25 or newer.

## Install

```sh
go get github.com/CruGlobal/cru-flags
```

The pipeline sets `CRU_FLAGS_URL` for you in release-candidate and production:

```sh
CRU_FLAGS_URL=https://deploys.cru.org/flags/<project>/<environment>
```

Without it (local development, CI, tests, preview, lab) the client is
**inert**: every flag is off, and it makes no requests and logs nothing.

## Usage

### A server

Wait briefly for the first fetch before serving, so the first requests after a
deploy see real flags instead of every flag off:

```go
func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	cruflags.Ready(ctx) // true once the first fetch settled, success or not
	cancel()

	http.HandleFunc("/checkout", func(w http.ResponseWriter, r *http.Request) {
		if cruflags.Enabled("checkout_v2") {
			newCheckout(w, r)
			return
		}
		oldCheckout(w, r)
	})
	log.Fatal(http.ListenAndServe(":8080", nil))
}
```

A goroutine polls every 30 seconds, plus or minus 20%, with `If-None-Match`,
so an unchanged document costs a `304`. A failed poll changes nothing: the
last good document is served for as long as the outage lasts.

### AWS Lambda and Cloud Run (on-demand refresh)

A process frozen between requests stops the poller too. Set

```sh
CRU_FLAGS_REFRESH_MODE=on-demand
```

and the client runs no goroutine. Call `Ready` during init and `Refresh` at the
top of each invocation or request; it makes at most one conditional GET per
30 seconds, and none while the document is fresh:

```go
func init() {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cruflags.Ready(ctx)
}

func handler(ctx context.Context, event events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	cruflags.Refresh(ctx)
	if cruflags.Enabled("checkout_v2") {
		// ...
	}
	// ...
}
```

Between `Refresh` calls, a read that finds the document stale starts a
refresh without waiting for it and answers from what it has.

### Your own client

Construct one to inject configuration, for tests, or to read more than one
document:

```go
flags := cruflags.New(cruflags.Options{
	URL:          "https://deploys.cru.org/flags/ararat/production", // default: $CRU_FLAGS_URL
	PollInterval: 30 * time.Second,
	FetchTimeout: 2 * time.Second,
	RefreshMode:  cruflags.Background, // or cruflags.OnDemand
	OnError: func(e cruflags.HealthEvent) { // health transitions only
		logger.Warn("feature flags "+string(e.Kind), "error", e.Err)
	},
})
defer flags.Close()
```

`New` does nothing until the client is first used. Every method is safe for
concurrent use, and a nil `*Client` behaves as an inert one. In tests, point
`Options.URL` at an `httptest.Server`, or leave `CRU_FLAGS_URL` unset and every
flag reads off.

### Health

`OnError` is called once when polling starts failing (with a
`*cruflags.FetchError` carrying `Code` and `Status`) and once when it recovers,
never once per poll. The default logs both lines at Warn through
`slog.Default()`.

### Snapshot

`cruflags.Snapshot()` returns a copy of the current document (nil before the
first one and after a 404), handy on a health or debug endpoint. Changing the
copy changes nothing in the client.

## Development

```sh
asdf install   # Go and golangci-lint, from .tool-versions
go vet ./...
golangci-lint run ./...
go test -race ./...
```

The conformance tests start `conformance/server.py`, so they need a `python3`
(3.11 or newer) on `PATH`. See [design.md](design.md) for the specification and
the reasoning behind it, and [CONTRIBUTING.md](../../CONTRIBUTING.md) for the
workflow.

## License

[BSD-3-Clause](../../LICENSE).
