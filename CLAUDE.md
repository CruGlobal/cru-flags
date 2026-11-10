# CLAUDE.md

> Guidance for every AI coding agent working in this repository. `AGENTS.md`
> is a symlink to this file. Each language has its own rules in
> `.claude/rules/<language>.md`, which Claude Code loads when it touches that
> language's files; agents that do not read `.claude/rules/` should read the
> one for the language they are changing.

## What this repository is

Clients for Cru's pipeline feature-flag service, one per language, sharing one
contract, one CI and one version number.

| Client                       | Source       | Tests                    | Design doc (authoritative) | Rules                    |
| ---------------------------- | ------------ | ------------------------ | -------------------------- | ------------------------ |
| Go, `cruflags`               | `*.go` (root) | `*_test.go`             | `docs/go/design.md`        | `.claude/rules/go.md`    |
| TypeScript, `@cruglobal/flags` | `src/`       | `test/*.test.ts`         | `docs/node/design.md`      | `.claude/rules/node.md`  |
| Python, `cru-flags`          | `cru_flags/` | `tests/`                 | `docs/python/design.md`    | `.claude/rules/python.md` |
| Ruby, `cru-flags` gem        | `lib/`       | `test/*_test.rb`         | `docs/ruby/design.md`      | `.claude/rules/ruby.md`  |

The service, the CLI that writes flags and the workflow flags exist for are
described in the
[pipeline guide](https://github.com/CruGlobal/cru-deploy/blob/main/docs/pipeline-v2.md#feature-flags).

## The contract comes first

- `conformance/` is the contract every client shares, as data: `cases.json`
  lists the cases and `server.py` serves them. Every client's test suite runs
  every case. Read `conformance/README.md` before changing how any client
  fetches, parses, caches or reports.
- **A contract change lands in every client in the same PR**, with a
  conformance case that proves it. If one client genuinely cannot follow yet,
  say so in the PR and open an issue; never let the clients drift quietly.
- Each client's design doc is the authoritative specification for that
  client. Drift between a design doc and its code is a bug, and the doc wins.
  A change to designed behavior updates the design doc in the same PR.
- **No runtime dependencies.** Every app at Cru inherits what these packages
  depend on. For Go, CI fails if `go mod tidy` changes `go.mod`. The gem's `flipper` (for its Flipper adapter) is the one
  exception, and its `json >= 2.4` floor must stay (see `.claude/rules/ruby.md`).

## Commits, versions and releases

- Conventional Commits. PRs squash-merge, so the PR title becomes the commit
  subject on `main` and is what release-please reads.
- Pre-1.0: `feat:` moves the minor, `fix:`/`perf:`/`deps:`/`refactor:`/`docs:`
  the patch. `chore:`, `ci:`, `test:`, `build:` and `style:` are hidden and do
  not cut a release.
- **Every package shares one version.** Never edit a version by hand; the
  release PR moves them all. `tests/test_versions.py` fails the build if they
  disagree.
- Merging the release PR tags `vX.Y.Z`; `release.yml` then publishes to npm,
  PyPI and RubyGems through trusted publishing. The tag itself is the Go
  release: tags must stay bare `vX.Y.Z`, or `go get` cannot see them. Do not rename `release.yml`:
  each registry's trusted publisher names it.
- Dependabot commits as `chore(deps)`, so tooling bumps release nothing.
  Retitle a Dependabot PR `deps: ...` only when it changes what consumers
  install.

## Toolchain

`.tool-versions` pins every toolchain; `asdf install` sets them all up, and CI
reads the same file. You only need the toolchains for the languages you touch,
plus a `python3` on `PATH` for the conformance server.

| Client     | Set up                                                            | Check before a PR                                                                 |
| ---------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Go         | nothing beyond `asdf install`                                     | `go vet ./... && golangci-lint run ./... && go test -race ./...`                  |
| TypeScript | `npm install`                                                     | `npm run typecheck && npm run lint && npm test && npm run build`                  |
| Python     | `uv venv && uv pip install -e ".[dev]" && source .venv/bin/activate` | `ruff check . && ruff format --check . && mypy && pytest`                       |
| Ruby       | `bundle install`                                                  | `bundle exec rake` (standardrb, then the suite)                                   |

## Layout gotchas

- `test/` holds two suites: TypeScript (`*.test.ts`, helpers in
  `test/helpers/`) and Ruby (`*_test.rb`, helpers in `test/support/`). Each
  runner globs only its own extension. Python's suite is `tests/`.
- `src/` is TypeScript only. The Python package is `cru_flags/` at the root,
  and the Go package is the root itself, so its import path is the module
  path. Keep Go files at the root.
- `go.mod` ignores `node_modules/`, so `./...` never walks npm's tree.
- Python builds go to `dist-python/` (`python -m build --outdir dist-python`),
  never `dist/`, which is the TypeScript build: a wheel left in `dist/` would
  ship inside the next npm tarball.
- `docs/<language>/CHANGELOG.md` are the frozen changelogs from before the
  clients moved here. The root `CHANGELOG.md` is release-please's.

## CI

- `.github/workflows/ci.yml` runs every language's jobs on every change. The
  ruleset requires one check, the `CI` job, which needs all the others. Add a
  new job to its `needs` list or the job gates nothing.
- Nothing in CI reaches the real flag service. The live checks
  (`npm run verify:live`, `python scripts/verify_live.py`,
  `ruby -Ilib test/verify_live.rb`) are opt-in and stay that way: a red build must
  mean the code is broken, not that the service was restarting.
