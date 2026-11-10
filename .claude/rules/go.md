---
paths:
  - "*.go"
  - "go.mod"
  - ".golangci.yml"
  - "docs/go/**"
---

# Go client: `github.com/CruGlobal/cru-flags`

Read the root `CLAUDE.md` first; this file adds what is specific to the Go
client.

[`docs/go/design.md`](../../docs/go/design.md) is the authoritative
specification. Read it before changing a `.go` file, and update it in the same
PR when designed behavior changes. Most of the reasoning it builds on is in
[`docs/node/design.md`](../../docs/node/design.md).

## Load-bearing decisions (do not "simplify" these)

- **Standard library only, forever.** CI fails if `go mod tidy` changes
  `go.mod`. Every Go app at Cru inherits what this package imports.
- **The package is the repository root** (`package cruflags`), so the import
  path is the module path. Do not move it into a subdirectory.
- **`Enabled` never blocks, never panics, returns no error.** It recovers
  panics and is a lock-free atomic load plus a map lookup. In on-demand mode it
  may start a refresh, never wait for one.
- **`New` does nothing.** No environment read, no goroutine, no request until
  first use. The package-level default client depends on this.
- **Fail-static with no expiry.** A failure never clears the document or its
  `ETag`. Only a 404 drops them.
- **The `ETag` is stored only with a document that parsed.**
- **`OnError` fires on transitions only**, outside the lock, with panics
  recovered, and before waiting callers are released. Never per poll. Never
  log from inside `startOnce.Do`: an slog handler that reads a flag would
  re-enter it and deadlock.
- **The zero `Client` must keep working.** Anything `New` would allocate goes
  in `setup()`, which every method calls first.
- **Staleness is measured from the last attempt**, not the last success.
- **No Lambda auto-detection.** On-demand mode is chosen by
  `CRU_FLAGS_REFRESH_MODE` or `Options.RefreshMode`, as in the Node client.
  Changing that is a cross-client decision.
- **`Version` in `version.go` is moved by release-please.** Never edit it by
  hand; the Go module's real version is the git tag.

## Commands

```sh
go vet ./...
golangci-lint run ./...     # config in .golangci.yml; version pinned in .tool-versions
go test -race ./...         # needs python3 on PATH for the conformance cases
```

## Testing conventions

- Use real `httptest` servers (`newService` in `client_test.go`), not a fake
  `RoundTripper`.
- Keep tests deterministic: hold a response open with a channel rather than
  racing a sleep, and use `eventually` for asynchronous outcomes.
- Every test must pass under `-race`.
