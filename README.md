# cru-flags

Clients for **Cru's pipeline feature-flag service**, one per language, in one
repository. Each one reads `CRU_FLAGS_URL`, polls that one JSON document with
`ETag` revalidation, keeps the last good copy through any outage, and answers
"is this flag on?" from memory without ever raising:

| Language   | Package                                                            | Install                                 | Read a flag                                |
| ---------- | ------------------------------------------------------------------ | --------------------------------------- | ------------------------------------------ |
| Go         | [`github.com/CruGlobal/cru-flags`][go-pkg]                         | `go get github.com/CruGlobal/cru-flags` | `cruflags.Enabled("checkout_v2")`          |
| TypeScript | [`@cruglobal/flags`](https://www.npmjs.com/package/@cruglobal/flags) | `npm install @cruglobal/flags`          | `flags.enabled("checkout_v2")`             |
| Python     | [`cru-flags`](https://pypi.org/project/cru-flags/)                 | `pip install cru-flags`                 | `flags.enabled("checkout_v2")`             |
| Ruby       | [`cru-flags`](https://rubygems.org/gems/cru-flags)                 | `gem "cru-flags"`                       | `Flipper.enabled?(:checkout_v2)` (Rails)   |

All four have zero runtime dependencies (the gem's one exception is `flipper`,
for its read-only Flipper adapter), share one version number, and release
together.

How flags are created and flipped (`cru app flags`), and how they fit the
merge-dark / demo-on-stage / launch-in-production workflow, is in the
[pipeline guide](https://github.com/CruGlobal/cru-deploy/blob/main/docs/pipeline-v2.md#feature-flags).

> **Status: AI-generated, maintained on a best-effort basis.** These libraries
> were authored primarily by an AI assistant against the design documents
> linked below. Dependabot keeps tooling current; feature work and fixes
> happen as needed. Issues and pull requests are welcome.

[go-pkg]: https://pkg.go.dev/github.com/CruGlobal/cru-flags

## The contract every client keeps

- **`CRU_FLAGS_URL` unset means every flag is off**, silently. Local
  development, CI, preview and lab environments have no flag document, and
  that is a normal state, not a configuration error.
- **Unknown flags read off.** Only a literal `"Enabled": true` turns a flag on.
- **A flag read never fetches, never blocks and never raises.** It is a memory
  lookup.
- **Poll every 30 seconds, plus or minus 20% jitter,** sending `If-None-Match`
  so an unchanged document costs a `304`.
- **Keep last-known-good.** A failed poll (timeout, `5xx`, a malformed body)
  changes nothing, forever. Flags never fall back to off on error. A `404`
  means "this app has no flags yet" and is not an error.
- **Fetch once at startup** (`Ready`) so the first requests after a deploy see
  real flags.
- **Log health transitions only**: once when polling starts failing, once when
  it recovers.

The [conformance suite](conformance/) encodes these rules as cases, and every
client's test suite runs them against the same test server.

## Quick start

### Go

```go
import cruflags "github.com/CruGlobal/cru-flags"

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	cruflags.Ready(ctx) // optional: wait for the first fetch before serving
	cancel()

	if cruflags.Enabled("checkout_v2") {
		// ...
	}
}
```

Details: [docs/go/README.md](https://github.com/CruGlobal/cru-flags/blob/main/docs/go/README.md).

### TypeScript / Node.js

```ts
import { flags } from "@cruglobal/flags";

await flags.ready(); // optional warmup
if (flags.enabled("checkout_v2")) {
  // ...
}
```

Details: [docs/node/README.md](https://github.com/CruGlobal/cru-flags/blob/main/docs/node/README.md).

### Python

```python
from cru_flags import flags

flags.ready(timeout=3.0)  # optional warmup
if flags.enabled("checkout_v2"):
    ...
```

Details: [docs/python/README.md](https://github.com/CruGlobal/cru-flags/blob/main/docs/python/README.md).

### Ruby

```ruby
# Gemfile
gem "cru-flags"

# In Rails the Railtie wires Flipper for you:
Flipper.enabled?(:checkout_v2)

# Anywhere else:
CruFlags.enabled?("checkout_v2")
```

Details: [docs/ruby/README.md](https://github.com/CruGlobal/cru-flags/blob/main/docs/ruby/README.md).

### Lambda and Cloud Run

On runtimes that freeze the process between requests, a background poll timer
does not tick. Set `CRU_FLAGS_REFRESH_MODE=on-demand` and every client drops
the timer and refreshes from the read path instead, at most once per poll
interval. Call `Ready` during init so the first invocation sees real flags.

## Repository layout

| Path                                                 | What                                                        |
| ---------------------------------------------------- | ----------------------------------------------------------- |
| `*.go`, `go.mod`                                     | Go package `cruflags`                                       |
| `src/`, `test/*.ts`, `package.json`                  | TypeScript package `@cruglobal/flags`                       |
| `cru_flags/`, `tests/`, `pyproject.toml`             | Python package `cru-flags`                                  |
| `lib/`, `test/*.rb`, `cru-flags.gemspec`             | Ruby gem `cru-flags`                                        |
| `conformance/`                                       | Shared cases and the test server every client runs against |
| `docs/<language>/`                                   | Each client's README, design document and old changelog     |

Each language's design document (`docs/<language>/design.md`) is the
authoritative specification for that client. See
[CONTRIBUTING.md](https://github.com/CruGlobal/cru-flags/blob/main/CONTRIBUTING.md)
to work on them.

## Releasing

[release-please](https://github.com/googleapis/release-please) keeps a release
pull request open on `main`, built from Conventional Commit subjects. Merging
it bumps every version file, writes `CHANGELOG.md`, tags `vX.Y.Z` and
publishes a GitHub Release. The release workflow then publishes to npm, PyPI
and RubyGems through trusted publishing (no registry tokens live in this
repository). The Go module needs no publish step: the tag is the release.

## License

[BSD-3-Clause](LICENSE).
