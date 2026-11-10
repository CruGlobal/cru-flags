# Contributing to cru-flags

This repository holds every official client for Cru's pipeline feature-flag
service. They share one contract (`conformance/`), one CI and one version, so
most of what follows applies whichever language you are changing.

## Set up

Every toolchain is pinned in `.tool-versions`. Install
[asdf](https://asdf-vm.com/), add the plugins for the languages you will
touch, and run `asdf install` from the repository root. CI reads the same
file, so a green local build means a green CI build. Do not install the
toolchains another way for work here: divergent versions cause failures that
are hard to reproduce.

The conformance suite runs in every language and needs a `python3` on `PATH`
for its test server (any Python 3.11 or newer).

### Go (`github.com/CruGlobal/cru-flags`)

```sh
asdf plugin add golang
asdf plugin add golangci-lint
asdf install

go vet ./... && golangci-lint run ./... && go test -race ./...
```

The package takes no dependencies: CI fails if `go mod tidy` changes
`go.mod`. It supports the Go release in `go.mod` and newer.

### TypeScript (`@cruglobal/flags`)

```sh
asdf plugin add nodejs
asdf install
npm install

npm run typecheck && npm run lint && npm test && npm run build
```

The published package supports Node.js 20 and newer; the `.tool-versions`
pin only governs development.

### Python (`cru-flags`)

```sh
asdf plugin add python
asdf install
uv venv --python "$(awk '/^python /{print $2}' .tool-versions)"
uv pip install -e ".[dev]"
source .venv/bin/activate

ruff check . && ruff format --check . && mypy && pytest
python -m build --outdir dist-python
```

There is no committed lockfile: the package has no runtime dependencies and
its dev dependencies float within `[project.optional-dependencies].dev`.

### Ruby (`cru-flags` gem)

```sh
asdf plugin add ruby
asdf install
bundle install

bundle exec rake   # standardrb, then the full suite
```

## Workflow

1. Keep each PR to one concern.
2. Read the design doc for the client you are changing
   (`docs/<language>/design.md`). It is the specification; drift between it
   and the code is a bug, and a change to designed behavior updates it in
   the same PR.
3. **Contract changes land in every client at once.** If a change touches
   what goes over the wire or how a client reacts to it (status handling,
   `ETag`s, parsing, last-known-good, health reporting, `CRU_FLAGS_URL` or
   `CRU_FLAGS_REFRESH_MODE`), add or update a case in
   `conformance/cases.json` and make every client pass it in the same PR.
4. Run the checks above for every language you touched.
5. Write the PR title as a [Conventional Commit](https://www.conventionalcommits.org/).
   PRs squash-merge, so the title becomes the commit on `main`, and
   release-please derives the next version and the changelog from it.

## Failing test first

Bug fixes and features lead with a failing test. Structure the PR so its
first commit adds a test that reproduces the bug or asserts the new behavior,
and the following commits make it pass. A bug report is most useful with the
same: a minimal failing test, or the flag document plus the call and the value
you expected.

Exempt: documentation-only changes, CI and workflow changes, dependency
updates, and refactors that change no observable behavior. When unsure,
include the test.

## Live checks

The test suites never reach the real flag service. Each client also has an
opt-in check against `https://deploys.cru.org/flags/ararat/release-candidate`
(public and read-only), which CI never runs. Go has none yet; its
conformance cases cover the same wire behavior against a local server.

```sh
npm run verify:live
python scripts/verify_live.py
CRU_FLAGS_URL=https://deploys.cru.org/flags/ararat/release-candidate ruby -Ilib test/verify_live.rb
```

## Releases

Nobody bumps versions by hand. release-please keeps a release PR open on
`main`; merging it bumps every package to the same version, tags `vX.Y.Z` and
publishes a GitHub Release, and `.github/workflows/release.yml` publishes to
npm, PyPI and RubyGems. The tag is the Go release. If one registry's publish fails, fix the cause and
re-run that workflow by hand with just that registry selected.

## License

By contributing, you agree that your contributions are licensed under the
[BSD-3-Clause License](LICENSE).
