# cru-flags-ruby Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `cru-flags` gem — the third sibling of cru-flags-node/cru-flags-python plus a read-only Flipper adapter — exactly as specified in the design doc.

**Architecture:** A stdlib-only polling client (`CruFlags::Client`) publishes a deep-frozen document snapshot swapped atomically; a module-level singleton exposes `CruFlags.enabled?`; a Flipper adapter answers Flipper's read API from the same snapshot; a Railtie wires it into Rails. Fail-static: reads never raise, never block (background mode), and hold last-known-good through outages with no TTL.

**Tech Stack:** Ruby >= 3.2 (CRuby only), Net::HTTP, JSON (`freeze: true`), minitest, standardrb, flipper ~> 1.4 (sole runtime dep), release-please + RubyGems Trusted Publishing.

**Spec:** `docs/design.md` (in this repo). The spec wins over this plan on any conflict — and note the conflict in the PR.

## Global Constraints

- `required_ruby_version = ">= 3.2"`; CRuby only (GVL-dependent lock-free reads, spec §6).
- Client core (`document.rb`, `fetcher.rb`, `client.rb`, `errors.rb`) uses stdlib ONLY. `flipper` is the single runtime dependency and only `flipper_adapter.rb`/`railtie.rb` may touch it.
- `enabled?` NEVER raises (rescue `StandardError`, not `Exception`) and does no I/O in background mode.
- Requiring the gem starts nothing: no thread, no env read, no socket (spec §7).
- All numbers verbatim from spec: poll 30.0s, jitter `rand(0.8..1.2)`, fetch timeout 2.0s (open+read+write), redirect limit 3, User-Agent `cru-flags-ruby/<version>`.
- Document-before-ETag ordering on 200 (spec §8). 404 publishes empty doc AND clears ETag. `Flags` present-but-wrong-type fails the document; missing/null `Flags` → `{}`.
- Flipper adapter `get`/`get_multi`/`get_all` return freshly-built UNFROZEN top-level Hashes on every call (spec §5 HARD RULE — Memoizable mutates them).
- Every commit: standardrb clean + full suite green. Commit trailers: `Co-authored-by: Claude <noreply@anthropic.com>`.
- Work on branch `build-v0`; do NOT push to `main`.

## File Structure

```
cru-flags.gemspec           # gem metadata; flipper runtime dep; CRuby-only note
Gemfile / Rakefile          # dev deps (minitest, standard, rake, railties); default task = standard + test
.standard.yml, .tool-versions
lib/cru_flags.rb            # requires + module-singleton API + Railtie hook
lib/cru_flags/version.rb
lib/cru_flags/errors.rb     # Error < StandardError; ParseError; FetchError(code:, status:); ReadOnlyError
lib/cru_flags/document.rb   # Document.parse(body) -> frozen Hash | raise ParseError
lib/cru_flags/fetcher.rb    # Fetcher.call(url:, etag:, timeout:) -> Outcome
lib/cru_flags/client.rb     # Client — state, health, background + on-demand modes
lib/cru_flags/flipper_adapter.rb
lib/cru_flags/railtie.rb
test/test_helper.rb
test/support/flag_service.rb  # programmable localhost HTTP server (TCPServer)
test/*_test.rb                # one file per task, named below
test/verify_live.rb           # opt-in networked check; NOT in rake
.github/workflows/ci.yml, release.yml
.github/dependabot.yml
release-please-config.json, .release-please-manifest.json
CHANGELOG.md
```

---

### Task 1: Gem scaffold, rake, standardrb, CI

**Files:**
- Create: `cru-flags.gemspec`, `Gemfile`, `Rakefile`, `.standard.yml`, `.tool-versions`, `lib/cru_flags/version.rb`, `lib/cru_flags.rb` (stub), `test/test_helper.rb`, `test/version_test.rb`, `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `CruFlags::VERSION` (String); `rake` default task running `standard` + `test`; test files glob `test/*_test.rb`.

- [ ] **Step 1: Create branch**

```bash
cd ~/Work/rails/cru-flags-ruby && git checkout -b build-v0
```

- [ ] **Step 2: Write the gemspec, Gemfile, Rakefile, configs**

`cru-flags.gemspec`:
```ruby
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
end
```

`Gemfile`:
```ruby
# frozen_string_literal: true

source "https://rubygems.org"
gemspec

gem "minitest", "~> 5.27"
gem "rake", "~> 13.0"
gem "railties", "~> 8.0" # Railtie + strict-logic tests only
gem "standard", "~> 1.50"
```

`Rakefile`:
```ruby
# frozen_string_literal: true

require "minitest/test_task"
require "standard/rake"

Minitest::TestTask.create(:test) do |t|
  t.test_globs = ["test/*_test.rb"]
end

task default: %i[standard test]
```

`.standard.yml`:
```yaml
ruby_version: 3.2
```

`.tool-versions`:
```
ruby 3.3.10
```

`lib/cru_flags/version.rb`:
```ruby
# frozen_string_literal: true

module CruFlags
  VERSION = "0.1.0"
end
```

`lib/cru_flags.rb`:
```ruby
# frozen_string_literal: true

require_relative "cru_flags/version"
```

`test/test_helper.rb`:
```ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
```

- [ ] **Step 3: Write the failing version test**

`test/version_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "cru_flags"

class VersionTest < Minitest::Test
  def test_version_is_a_frozen_semver_string
    assert_match(/\A\d+\.\d+\.\d+\z/, CruFlags::VERSION)
    assert_predicate CruFlags::VERSION, :frozen?
  end
end
```

- [ ] **Step 4: bundle install; run rake; expect green**

Run: `bundle install && bundle exec rake`
Expected: standardrb clean, 1 test passes.

- [ ] **Step 5: Write `.github/workflows/ci.yml`**

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  test:
    name: lint + test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - run: bundle exec rake
  test-matrix:
    strategy:
      matrix:
        ruby: ["3.2", "3.3", "3.4"]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true
      - run: bundle exec rake test
```

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "chore: gem scaffold — gemspec, rake (standard + minitest), CI"
```

---

### Task 2: Local flag-service test harness

**Files:**
- Create: `test/support/flag_service.rb`, `test/flag_service_test.rb`

**Interfaces:**
- Produces: `FlagService` — a real HTTP server on `127.0.0.1:<random>`:
  - `FlagService.new` / `#start` -> self, `#url` (String, `http://127.0.0.1:PORT/flags/test/production`), `#stop`
  - `#respond_with(status:, body: nil, headers: {})` — sets the canned next response (persists until changed)
  - `#respond { |request| [status, headers, body] }` — programmable per-request block; `request` responds to `#headers` (Hash, downcased keys), `#path`, `#method`
  - `#requests` -> Array of those request records, in order
  - `#delay=(seconds)` — sleep before responding (timeout tests)
- No keep-alive: server closes the connection after each response (mirrors the client's one-shot requests).

- [ ] **Step 1: Write the failing harness smoke test**

`test/flag_service_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "net/http"
require "json"

class FlagServiceTest < Minitest::Test
  def setup
    @service = FlagService.new.start
  end

  def teardown
    @service.stop
  end

  def test_serves_canned_json_and_records_request_headers
    @service.respond_with(status: 200, body: {"Flags" => {}}.to_json,
      headers: {"ETag" => '"1"', "Content-Type" => "application/json"})
    uri = URI(@service.url)
    res = Net::HTTP.start(uri.host, uri.port) do |http|
      http.get(uri.path, {"If-None-Match" => '"0"', "Accept" => "application/json"})
    end
    assert_equal "200", res.code
    assert_equal '"1"', res["etag"]
    assert_equal '"0"', @service.requests.last.headers["if-none-match"]
  end

  def test_programmable_block_and_status_304
    @service.respond { |req| [304, {}, nil] }
    uri = URI(@service.url)
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.get(uri.path) }
    assert_equal "304", res.code
  end
end
```

- [ ] **Step 2: Run; expect FAIL (no FlagService)**

Run: `bundle exec rake test`

- [ ] **Step 3: Implement the harness**

`test/support/flag_service.rb` — a `TCPServer` accept loop on a background thread; parse the request line + headers (read until blank line, honor `Content-Length` if ever present), record it, apply `@delay`, write an `HTTP/1.1 <status>` response with `Connection: close` and `Content-Length`, close the socket. `stop` closes the listener and joins the thread. Keep it ~80 lines, no dependencies. Malformed sockets (client timeout closing early) must not kill the accept loop — rescue per-connection, keep serving.

```ruby
# frozen_string_literal: true

require "socket"

# A real, programmable HTTP/1.1 server for contract tests. Mock-free on
# purpose: 304-handling, header echo, and timeout behavior must exercise the
# real Net::HTTP (design doc §9).
class FlagService
  Request = Struct.new(:method, :path, :headers, keyword_init: true)

  attr_reader :requests
  attr_accessor :delay

  def initialize
    @requests = []
    @delay = nil
    @responder = ->(_req) { [404, {}, nil] }
    @mutex = Mutex.new
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { accept_loop }
    @thread.report_on_exception = false
    self
  end

  def url = "http://127.0.0.1:#{@port}/flags/test/production"

  def respond_with(status:, body: nil, headers: {})
    @mutex.synchronize { @responder = ->(_req) { [status, headers, body] } }
  end

  def respond(&block)
    @mutex.synchronize { @responder = block }
  end

  def stop
    @server&.close
    @thread&.join(2)
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      handle(socket)
    rescue IOError, Errno::EBADF
      break # listener closed by #stop
    rescue
      next # one bad connection must not stop the server
    end
  end

  def handle(socket)
    request_line = socket.gets or return
    method, path, = request_line.split(" ", 3)
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.strip if value
    end
    request = Request.new(method:, path:, headers:)
    responder = @mutex.synchronize { @responder }
    @requests << request
    sleep(@delay) if @delay
    status, response_headers, body = responder.call(request)
    write_response(socket, status, response_headers, body)
  ensure
    socket&.close
  end

  def write_response(socket, status, headers, body)
    socket.write "HTTP/1.1 #{status} X\r\n"
    headers.each { |k, v| socket.write "#{k}: #{v}\r\n" }
    socket.write "Connection: close\r\n"
    socket.write "Content-Length: #{body ? body.bytesize : 0}\r\n\r\n"
    socket.write(body) if body
  end
end
```

- [ ] **Step 4: Run; expect PASS; commit**

```bash
bundle exec rake && git add -A && git commit -m "test: programmable local flag-service harness"
```

---

### Task 3: Errors + Document.parse

**Files:**
- Create: `lib/cru_flags/errors.rb`, `lib/cru_flags/document.rb`, `test/document_test.rb`
- Modify: `lib/cru_flags.rb` (add requires)

**Interfaces:**
- Produces:
  - `CruFlags::Error < StandardError`; `CruFlags::ParseError < Error`; `CruFlags::FetchError < Error` with `attr_reader :code` (`:http`/`:network`/`:timeout`/`:parse`) and `:status` (Integer or nil), constructor `FetchError.new(message, code:, status: nil)`; `CruFlags::ReadOnlyError < Error`.
  - `CruFlags::Document.parse(body) -> Hash` — deep-frozen; raises `ParseError`.

**Parsing rules (spec §2/§8, byte-for-byte the sibling contract):**
- Body not valid JSON, or valid JSON that is not an object → `ParseError`.
- `Flags` missing or `nil` → replaced with frozen `{}`.
- `Flags` present but not a Hash (string/number/array) → `ParseError` (leniency is for absence, not malformation).
- Non-Hash flag *entries* are dropped; all unknown keys preserved verbatim.
- Result and every nested value frozen — parse with `JSON.parse(body, freeze: true)`; the `Flags`-replacement/entry-drop rebuild must re-freeze what it builds.

- [ ] **Step 1: Write the failing tests**

`test/document_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "cru_flags"
require "json"

class DocumentTest < Minitest::Test
  REAL_DOC = {
    "Project" => "ararat", "Environment" => "release-candidate",
    "Version" => 3, "NotifySlack" => true,
    "Flags" => {"pilot_banner" => {"Enabled" => true, "UpdatedBy" => "Omicron7"}},
    "FutureKey" => {"nested" => [1, 2]}
  }.freeze

  def test_parses_and_deep_freezes_preserving_unknown_keys
    doc = CruFlags::Document.parse(JSON.generate(REAL_DOC))
    assert_equal true, doc.dig("Flags", "pilot_banner", "Enabled")
    assert_equal({"nested" => [1, 2]}, doc["FutureKey"])
    each_node(doc) { |node| assert_predicate node, :frozen? }
  end

  def test_missing_or_nil_flags_becomes_empty_hash
    assert_equal({}, CruFlags::Document.parse("{}")["Flags"])
    assert_equal({}, CruFlags::Document.parse('{"Flags": null}')["Flags"])
  end

  def test_wrong_type_flags_fails_the_document
    ["[]", '"x"', "3"].each do |bad|
      assert_raises(CruFlags::ParseError) { CruFlags::Document.parse(%({"Flags": #{bad}})) }
    end
  end

  def test_non_hash_flag_entries_are_dropped_without_failing
    doc = CruFlags::Document.parse('{"Flags": {"good": {"Enabled": true}, "bad": 7}}')
    assert_equal %w[good], doc["Flags"].keys
  end

  def test_non_object_bodies_raise_parse_error
    ["not json", "[]", '"str"', "null"].each do |bad|
      assert_raises(CruFlags::ParseError) { CruFlags::Document.parse(bad) }
    end
  end

  def test_round_trips_through_json
    doc = CruFlags::Document.parse(JSON.generate(REAL_DOC))
    assert_equal doc, JSON.parse(JSON.generate(doc))
  end

  private

  def each_node(node, &block)
    yield node
    case node
    when Hash then node.each { |k, v| each_node(k, &block); each_node(v, &block) }
    when Array then node.each { |v| each_node(v, &block) }
    end
  end
end
```

- [ ] **Step 2: Run; expect FAIL. Step 3: Implement**

`lib/cru_flags/errors.rb`:
```ruby
# frozen_string_literal: true

module CruFlags
  class Error < StandardError; end

  class ParseError < Error; end

  # Normalized fetch failure. code is :http, :network, :timeout, or :parse;
  # status is set only for :http.
  class FetchError < Error
    attr_reader :code, :status

    def initialize(message, code:, status: nil)
      super(message)
      @code = code
      @status = status
    end
  end

  class ReadOnlyError < Error; end
end
```

`lib/cru_flags/document.rb`:
```ruby
# frozen_string_literal: true

require "json"

module CruFlags
  module Document
    EMPTY = {"Flags" => {}}.freeze

    module_function

    # Parse and deep-freeze one flag document. Leniency is for ABSENCE, not
    # malformation: a missing Flags key is an empty document, a wrong-typed
    # one is a broken document (design doc §8).
    def parse(body)
      parsed = JSON.parse(body, freeze: true)
      raise ParseError, "document is not a JSON object" unless parsed.is_a?(Hash)

      normalize_flags(parsed)
    rescue JSON::ParserError => e
      raise ParseError, "document is not JSON: #{e.message}"
    end

    def normalize_flags(parsed)
      flags = parsed["Flags"]
      case flags
      when nil
        rebuild(parsed, {}.freeze)
      when Hash
        clean = flags.select { |_name, entry| entry.is_a?(Hash) }
        (clean.size == flags.size) ? parsed : rebuild(parsed, clean.freeze)
      else
        raise ParseError, "Flags is #{flags.class}, expected an object"
      end
    end

    def rebuild(parsed, flags)
      parsed.reject { |k, _| k == "Flags" }.merge("Flags" => flags).freeze
    end
    private_class_method :normalize_flags, :rebuild
  end
end
```

Add to `lib/cru_flags.rb`: `require_relative "cru_flags/errors"` and `require_relative "cru_flags/document"`.

- [ ] **Step 4: Run; expect PASS; commit**

```bash
bundle exec rake && git add -A && git commit -m "feat: document parsing — sibling leniency rules, deep-frozen output"
```

---

### Task 4: Fetcher — one HTTP tick

**Files:**
- Create: `lib/cru_flags/fetcher.rb`, `test/fetcher_test.rb`
- Modify: `lib/cru_flags.rb` (require)

**Interfaces:**
- Consumes: `CruFlags::Document.parse`, `CruFlags::FetchError`.
- Produces: `CruFlags::Fetcher.call(url:, etag: nil, timeout: 2.0) -> Outcome` where
  `Outcome = Struct.new(:kind, :document, :etag, :error, keyword_init: true)` (defined as `CruFlags::Fetcher::Outcome`) and `kind` is:
  - `:document` — 200: `document` = frozen parsed Hash, `etag` = response ETag (or nil)
  - `:not_modified` — 304
  - `:missing` — 404
  - `:failed` — anything else: `error` = `FetchError`
  `call` never raises; every failure becomes `kind: :failed`.

**Behavior (spec §8):** GET with `Accept: application/json`, `User-Agent: cru-flags-ruby/<VERSION>`, `If-None-Match` when etag given. One-shot `Net::HTTP.start(host, port, use_ssl: uri.scheme == "https", open_timeout:, read_timeout:, write_timeout:)`. Follow 301/302/303/307/308 up to 3 hops (re-issue GET at `Location`, resolved relative to the current URI); a 4th redirect is `:failed` (`code: :http`). Non-2xx/304/404 statuses → `FetchError.new("flag fetch failed with HTTP <status>: <first 200 chars of body>", code: :http, status:)`. `Net::OpenTimeout`/`Net::ReadTimeout`/`Timeout::Error` → `code: :timeout`; other `SystemCallError`/`SocketError`/`IOError`/`OpenSSL::SSL::SSLError`/`EOFError` → `code: :network`; `ParseError` → `code: :parse`.

- [ ] **Step 1: Write the failing tests**

`test/fetcher_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"
require "json"

class FetcherTest < Minitest::Test
  def setup
    @service = FlagService.new.start
  end

  def teardown
    @service.stop
  end

  def fetch(etag: nil, timeout: 2.0)
    CruFlags::Fetcher.call(url: @service.url, etag:, timeout:)
  end

  def test_200_returns_document_and_etag_and_sends_headers
    @service.respond_with(status: 200, body: '{"Version":1,"Flags":{}}', headers: {"ETag" => '"1"'})
    outcome = fetch(etag: '"0"')
    assert_equal :document, outcome.kind
    assert_equal '"1"', outcome.etag
    assert_equal 1, outcome.document["Version"]
    headers = @service.requests.last.headers
    assert_equal '"0"', headers["if-none-match"]
    assert_equal "application/json", headers["accept"]
    assert_equal "cru-flags-ruby/#{CruFlags::VERSION}", headers["user-agent"]
  end

  def test_no_if_none_match_header_without_stored_etag
    @service.respond_with(status: 200, body: '{"Flags":{}}')
    fetch
    refute_includes @service.requests.last.headers.keys, "if-none-match"
  end

  def test_304_is_not_modified
    @service.respond_with(status: 304)
    assert_equal :not_modified, fetch(etag: '"1"').kind
  end

  def test_404_is_missing_not_failed
    @service.respond_with(status: 404, body: '{"message":"no flags yet"}')
    assert_equal :missing, fetch.kind
  end

  def test_http_error_carries_status_and_body_excerpt
    @service.respond_with(status: 400, body: '{"message":"\"staging\" has no feature flags"}')
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :http, outcome.error.code
    assert_equal 400, outcome.error.status
    assert_includes outcome.error.message, "staging"
  end

  def test_timeout_is_failed_with_timeout_code
    @service.respond_with(status: 200, body: '{"Flags":{}}')
    @service.delay = 0.5
    outcome = fetch(timeout: 0.1)
    assert_equal :failed, outcome.kind
    assert_equal :timeout, outcome.error.code
  end

  def test_connection_refused_is_network
    @service.stop
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :network, outcome.error.code
  end

  def test_malformed_body_is_parse_failure
    @service.respond_with(status: 200, body: "not json")
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :parse, outcome.error.code
  end

  def test_follows_redirects_to_limit_three
    hops = 0
    @service.respond do |req|
      if req.path == "/flags/test/production" || hops < 2
        hops += 1
        [302, {"Location" => "/hop#{hops}"}, nil]
      else
        [200, {}, '{"Version":9,"Flags":{}}']
      end
    end
    assert_equal :document, fetch.kind
  end

  def test_fourth_redirect_fails
    @service.respond { |_req| [302, {"Location" => "/loop"}, nil] }
    outcome = fetch
    assert_equal :failed, outcome.kind
    assert_equal :http, outcome.error.code
  end
end
```

- [ ] **Step 2: Run; FAIL. Step 3: Implement `lib/cru_flags/fetcher.rb`**

```ruby
# frozen_string_literal: true

require "net/http"
require "uri"

module CruFlags
  # One conditional GET of the flag document. Stateless; the Client owns the
  # etag and the snapshot. Never raises — every failure is an Outcome.
  module Fetcher
    Outcome = Struct.new(:kind, :document, :etag, :error, keyword_init: true)

    REDIRECT_LIMIT = 3
    REDIRECT_CODES = %w[301 302 303 307 308].freeze
    BODY_EXCERPT = 200

    module_function

    def call(url:, etag: nil, timeout: 2.0)
      response = get_following_redirects(URI(url), etag:, timeout:)
      case response.code
      when "200"
        document = Document.parse(response.body.to_s)
        Outcome.new(kind: :document, document:, etag: response["etag"])
      when "304" then Outcome.new(kind: :not_modified)
      when "404" then Outcome.new(kind: :missing)
      else
        excerpt = response.body.to_s.strip[0, BODY_EXCERPT]
        failed(FetchError.new("flag fetch failed with HTTP #{response.code}: #{excerpt}",
          code: :http, status: Integer(response.code)))
      end
    rescue ParseError => e
      failed(FetchError.new(e.message, code: :parse))
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
      failed(FetchError.new("flag fetch timed out: #{e.message}", code: :timeout))
    rescue SystemCallError, SocketError, IOError, EOFError, OpenSSL::SSL::SSLError => e
      failed(FetchError.new("flag fetch failed: #{e.message}", code: :network))
    end

    def get_following_redirects(uri, etag:, timeout:)
      REDIRECT_LIMIT.downto(0) do |hops_left|
        response = get(uri, etag:, timeout:)
        return response unless REDIRECT_CODES.include?(response.code)
        if hops_left.zero?
          raise FetchError.new("flag fetch exceeded #{REDIRECT_LIMIT} redirects",
            code: :http, status: Integer(response.code))
        end
        uri = uri.merge(response["location"].to_s)
      end
    end

    def get(uri, etag:, timeout:)
      headers = {"Accept" => "application/json",
                 "User-Agent" => "cru-flags-ruby/#{VERSION}"}
      headers["If-None-Match"] = etag if etag
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: timeout, read_timeout: timeout, write_timeout: timeout) do |http|
        http.get(uri.request_uri, headers)
      end
    end

    def failed(error) = Outcome.new(kind: :failed, error:)
    private_class_method :get_following_redirects, :get, :failed
  end
end
```

Note: the raised `FetchError` inside `get_following_redirects` is caught by
`call`'s generic handling only if listed — add `rescue FetchError => e` /
`failed(e)` ABOVE the ParseError rescue in `call`.

- [ ] **Step 4: Run; PASS; commit**

```bash
bundle exec rake && git add -A && git commit -m "feat: fetcher — one conditional GET, sibling outcome taxonomy"
```

---

### Task 5: Client core — snapshot, health, manual refresh

**Files:**
- Create: `lib/cru_flags/client.rb`, `test/client_core_test.rb`
- Modify: `lib/cru_flags.rb` (require)

**Interfaces:**
- Consumes: `Fetcher.call`, `Document::EMPTY`, errors.
- Produces: `CruFlags::Client.new(url: nil, poll_seconds: 30.0, fetch_timeout: 2.0, on_error: nil, refresh_mode: nil)` with `#enabled?(name)`, `#snapshot`, `#refresh(force: false)`, `#close`, `#inert?`. (`#ready` and mode threading land in Tasks 6–7; in this task `refresh` fetches inline with no coalescing yet and `ready` is NOT implemented.)

**Behavior locked in this task (spec §3, §4, §8):**
- Explicit `url:` wins over ENV; ENV resolution itself is Task 8's module concern — `Client` receives a url or is inert. Also inert: non-http(s) url (one `on_error` warning).
- State: `@document` (frozen Hash or nil), `@etag`, `@healthy` (nil until first non-ok... precisely: report transitions only), `@last_attempt_at` (monotonic), `@closed`, `@write_mutex`.
- Outcome application: `:document` → publish frozen doc, THEN store etag; `:not_modified` → nothing; `:missing` → publish `Document::EMPTY`, CLEAR etag; `:failed` → keep everything. `:document`/`:not_modified`/`:missing` are healthy; `:failed` unhealthy. `on_error.(error)` on ok→failing, `on_error.(nil)` on failing→ok; never on repeat failures; `on_error` exceptions swallowed.
- `enabled?(name)`: `snapshot_ref&.dig("Flags", name.to_s, "Enabled") == true`, whole body rescued (`StandardError` → false). Symbols accepted.
- `snapshot`: thawed deep copy via `JSON.parse(JSON.generate(doc))`; `{}` when no doc.
- Default `on_error`: logs WARN to `Rails.logger` if defined, else a `Logger.new($stderr, progname: "cru_flags")`; messages `"cru_flags: flag fetches failing: <error>"` / `"cru_flags: flag fetches recovered"`.
- `refresh(force: false)`: no-op (returns freshness) while last attempt younger than `poll_seconds` unless force; fetch inline; update `@last_attempt_at` on EVERY attempt (success or not); returns `attempted_once? && last_attempt_succeeded?`. Never raises.
- `close`: sets `@closed`; a closed client never fetches again; last snapshot stays readable.

- [ ] **Step 1: Write the failing tests**

`test/client_core_test.rb` (key cases; write all of these):
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"

class ClientCoreTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @errors = []
    @client = CruFlags::Client.new(url: @service.url, on_error: ->(e) { @errors << e })
  end

  def teardown
    @client.close
    @service.stop
  end

  def serve(body, etag: nil)
    headers = etag ? {"ETag" => etag} : {}
    @service.respond_with(status: 200, body:, headers:)
  end

  def test_enabled_is_false_before_any_fetch_and_never_raises
    refute @client.enabled?("anything")
    refute @client.enabled?(nil) # hostile input answers false, not raise
  end

  def test_refresh_publishes_document_and_enabled_reads_it
    serve('{"Flags":{"pilot":{"Enabled":true},"off":{"Enabled":false}}}', etag: '"1"')
    assert @client.refresh(force: true)
    assert @client.enabled?("pilot")
    assert @client.enabled?(:pilot) # symbols accepted
    refute @client.enabled?("off")
    refute @client.enabled?("stringly") # absent
  end

  def test_malformed_enabled_values_read_false
    serve('{"Flags":{"a":{"Enabled":"true"},"b":{"Enabled":1},"c":{"Enabled":null}}}')
    @client.refresh(force: true)
    %w[a b c].each { |name| refute @client.enabled?(name) }
  end

  def test_failure_keeps_last_known_good_indefinitely
    serve('{"Flags":{"pilot":{"Enabled":true}}}', etag: '"1"')
    @client.refresh(force: true)
    @service.respond_with(status: 500, body: "boom")
    5.times { @client.refresh(force: true) }
    assert @client.enabled?("pilot"), "outage must not turn flags off (no TTL)"
  end

  def test_health_transitions_fire_once_each_way_and_never_for_404_or_304
    serve('{"Flags":{}}', etag: '"1"')
    @client.refresh(force: true)
    @service.respond_with(status: 304)
    @client.refresh(force: true)
    @service.respond_with(status: 404)
    @client.refresh(force: true)
    assert_empty @errors
    @service.respond_with(status: 500, body: "x")
    3.times { @client.refresh(force: true) }
    assert_equal 1, @errors.size
    assert_kind_of CruFlags::FetchError, @errors.first
    serve('{"Flags":{}}')
    @client.refresh(force: true)
    assert_equal [@errors.first, nil], @errors
  end

  def test_404_publishes_empty_and_clears_etag
    serve('{"Flags":{"pilot":{"Enabled":true}}}', etag: '"7"')
    @client.refresh(force: true)
    @service.respond_with(status: 404)
    @client.refresh(force: true)
    refute @client.enabled?("pilot")
    serve('{"Flags":{}}')
    @client.refresh(force: true)
    refute_includes @service.requests.last.headers.keys, "if-none-match",
      "404 must clear the stored ETag so a reappearing document is fetched fresh"
  end

  def test_snapshot_is_a_thawed_json_roundtrippable_copy
    serve('{"Version":3,"Flags":{"pilot":{"Enabled":true}}}')
    @client.refresh(force: true)
    snap = @client.snapshot
    refute_predicate snap, :frozen?
    snap["Flags"]["pilot"]["Enabled"] = false # mutating the copy...
    assert @client.enabled?("pilot") # ...cannot touch library state
  end

  def test_refresh_without_force_is_a_noop_while_fresh
    serve('{"Flags":{}}')
    @client.refresh(force: true)
    @client.refresh
    assert_equal 1, @service.requests.size
  end

  def test_close_is_terminal
    serve('{"Flags":{"pilot":{"Enabled":true}}}')
    @client.refresh(force: true)
    @client.close
    @service.respond_with(status: 200, body: '{"Flags":{}}')
    @client.refresh(force: true)
    assert_equal 1, @service.requests.size, "closed client must not fetch"
    assert @client.enabled?("pilot"), "last snapshot stays readable"
  end

  def test_non_http_url_is_inert_with_one_warning
    client = CruFlags::Client.new(url: "file:///etc/passwd", on_error: ->(e) { @errors << e })
    assert client.inert?
    refute client.enabled?("x")
    client.close
  end

  def test_broken_on_error_handler_is_swallowed
    client = CruFlags::Client.new(url: @service.url, on_error: ->(_e) { raise "handler bug" })
    @service.respond_with(status: 500, body: "x")
    client.refresh(force: true) # must not raise
    client.close
  end
end
```

- [ ] **Step 2: Run; FAIL. Step 3: Implement `lib/cru_flags/client.rb`**

Implement exactly the state machine above. Structure (the mode/threading
methods referenced by later tasks are added in Tasks 6–7 — here `refresh`
calls `attempt_fetch` directly):

```ruby
# frozen_string_literal: true

require "logger"

module CruFlags
  # The polling flag client (design doc §3–§8). One instance per process in
  # normal use, via the CruFlags module singleton.
  class Client
    VALID_SCHEMES = %w[http https].freeze

    def initialize(url: nil, poll_seconds: 30.0, fetch_timeout: 2.0,
      on_error: nil, refresh_mode: nil)
      @poll_seconds = positive(poll_seconds, 30.0)
      @fetch_timeout = positive(fetch_timeout, 2.0)
      @on_error = on_error || default_on_error
      @refresh_mode = refresh_mode # resolved in Task 7
      @url = url
      @document = nil
      @etag = nil
      @healthy = true
      @attempted = false
      @last_attempt_at = nil
      @last_attempt_ok = false
      @closed = false
      @write_mutex = Mutex.new
      validate_url!
    end

    def inert? = @url.nil?

    def enabled?(name)
      doc = @document
      doc&.dig("Flags", name.to_s, "Enabled") == true
    rescue StandardError
      false
    end

    def snapshot
      doc = @document
      doc ? JSON.parse(JSON.generate(doc)) : {}
    rescue StandardError
      {}
    end

    def refresh(force: false)
      return false if inert? || @closed
      @write_mutex.synchronize do
        attempt_fetch if force || stale?
        @attempted && @last_attempt_ok
      end
    rescue StandardError
      false
    end

    def close
      @closed = true
      nil
    end

    private

    def stale?
      @last_attempt_at.nil? ||
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_attempt_at) >= @poll_seconds
    end

    def attempt_fetch
      outcome = Fetcher.call(url: @url, etag: @etag, timeout: @fetch_timeout)
      apply(outcome)
    ensure
      @attempted = true
      @last_attempt_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def apply(outcome)
      case outcome.kind
      when :document
        @document = outcome.document # document BEFORE etag (design doc §8)
        @etag = outcome.etag
        became(healthy: true)
      when :not_modified
        became(healthy: true)
      when :missing
        @document = Document::EMPTY
        @etag = nil
        became(healthy: true)
      when :failed
        became(healthy: false, error: outcome.error)
      end
      @last_attempt_ok = outcome.kind != :failed
    end

    def became(healthy:, error: nil)
      return if healthy == @healthy
      @healthy = healthy
      report(healthy ? nil : error)
    end

    def report(error)
      @on_error.call(error)
    rescue StandardError
      nil # a broken error handler must not kill the poller
    end

    def default_on_error
      lambda do |error|
        logger = defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger ||
          (@fallback_logger ||= Logger.new($stderr, progname: "cru_flags"))
        if error
          logger.warn("cru_flags: flag fetches failing: #{error.class}: #{error.message}")
        else
          logger.warn("cru_flags: flag fetches recovered")
        end
      end
    end

    def positive(value, fallback)
      (value.is_a?(Numeric) && value.finite? && value.positive?) ? value.to_f : fallback
    end

    def validate_url!
      return if @url.nil?
      scheme = URI(@url.to_s).scheme
      unless VALID_SCHEMES.include?(scheme)
        @url = nil
        report(FetchError.new("CRU_FLAGS_URL scheme #{scheme.inspect} is not http(s); client is inert",
          code: :network))
      end
    rescue URI::InvalidURIError
      @url = nil
      report(FetchError.new("CRU_FLAGS_URL is not a valid URL; client is inert", code: :network))
    end
  end
end
```

- [ ] **Step 4: Run; PASS; commit**

```bash
bundle exec rake && git add -A && git commit -m "feat: client core — fail-static snapshot, health transitions, manual refresh"
```

---

### Task 6: Background mode — poller thread, ready, fork re-arm

**Files:**
- Modify: `lib/cru_flags/client.rb`
- Create: `test/client_background_test.rb`

**Interfaces:**
- Produces on `Client`: `#ready(timeout: nil) -> bool`; lazy poller start from `enabled?`/`ready`/`snapshot`; `#close` now also wakes/stops the thread promptly.

**Behavior (spec §7):**
- First `enabled?`/`ready`/`snapshot` call on a non-inert background-mode client starts ONE thread (`Thread#name = "cru-flags-poller"`, `report_on_exception = false`) which loops: attempt fetch, then wait `poll_seconds * rand(0.8..1.2)` on a `Queue#pop(timeout:)` (Ruby 3.2+) so `close` can push to wake it immediately. Constructing the client starts nothing; requiring starts nothing.
- `ready(timeout: nil)`: waits (on a `Mutex`+`ConditionVariable` signaled after the first attempt) until the first attempt completes; returns whether it did within `timeout`. Immediately `false` for inert clients, no blocking. `true` after a *failed* first attempt.
- Fork re-arm: store `@pid = Process.pid` when the thread starts; every read checks `Process.pid != @pid` and, if changed, discards the dead thread state (under the write mutex, double-checked) so the child lazily starts its own poller. (The connection_pool / dd-trace-rb pattern.)
- `refresh` racing the poller's tick: both go through one `@fetch_mutex` so concurrent callers share/wait on the one in-flight request rather than stacking simultaneous fetches (spec §3.5). (Implementation: `attempt_fetch` takes `@fetch_mutex`; a caller that was blocked waiting takes it, finds the last attempt fresh via `stale?`, and returns without fetching.)
- `enabled?`/`snapshot` never take the fetch mutex in background mode — reads stay I/O-free and lock-free.

- [ ] **Step 1: Write the failing tests**

`test/client_background_test.rb` (write all of these):
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"

class ClientBackgroundTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":true}}}', headers: {"ETag" => '"1"'})
  end

  def teardown
    @client&.close
    @service.stop
  end

  def new_client(**opts)
    @client = CruFlags::Client.new(url: @service.url, poll_seconds: 0.2, **opts)
  end

  def test_constructing_starts_no_thread_first_read_does
    before = Thread.list.size
    client = new_client
    assert_equal before, Thread.list.size
    client.enabled?("pilot")
    assert client.ready(timeout: 2.0)
    assert client.enabled?("pilot")
    assert(Thread.list.any? { |t| t.name == "cru-flags-poller" })
  end

  def test_ready_true_after_failed_first_attempt
    @service.respond_with(status: 500, body: "x")
    client = new_client
    assert client.ready(timeout: 2.0), "a completed failed attempt is still completed"
    refute client.enabled?("pilot")
  end

  def test_ready_false_immediately_when_inert
    client = CruFlags::Client.new(url: nil)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refute client.ready(timeout: 5.0)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 1.0
  end

  def test_poller_revalidates_with_etag_on_steady_state
    client = new_client
    client.ready(timeout: 2.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
    sleep 0.05 until @service.requests.size >= 3 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_operator @service.requests.size, :>=, 3, "poller should tick repeatedly"
    assert_equal '"1"', @service.requests.last.headers["if-none-match"]
  end

  def test_picks_up_flag_changes_within_interval
    client = new_client
    client.ready(timeout: 2.0)
    assert client.enabled?("pilot")
    @service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":false}}}', headers: {"ETag" => '"2"'})
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
    sleep 0.05 while client.enabled?("pilot") && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    refute client.enabled?("pilot")
  end

  def test_close_returns_promptly_and_stops_polling
    client = new_client
    client.ready(timeout: 2.0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.close
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.15,
      "close must interrupt the poll sleep, not wait it out"
    count = @service.requests.size
    sleep 0.5
    assert_equal count, @service.requests.size, "no fetches after close"
  end

  def test_concurrent_refresh_calls_share_one_request
    client = new_client
    client.ready(timeout: 2.0)
    baseline = @service.requests.size
    @service.delay = 0.2
    threads = 5.times.map { Thread.new { client.refresh(force: true) } }
    threads.each(&:join)
    assert_operator @service.requests.size - baseline, :<=, 2,
      "a burst of refreshes must coalesce, not stack N requests"
  end
end
```

- [ ] **Step 2: Run; FAIL. Step 3: Implement**

Modify `Client`: add `@ready_mutex`, `@ready_cv`, `@fetch_mutex`, `@wake = Queue.new`, `@thread`, `@pid`. `enabled?`/`snapshot`/`ready` call `ensure_started` first (no-op for inert/closed/on-demand). `ensure_started` double-checks under `@write_mutex`, handles PID change (`@thread = nil; @wake = Queue.new` on fork detection), spawns:

```ruby
def spawn_poller
  @pid = Process.pid
  @thread = Thread.new do
    Thread.current.name = "cru-flags-poller"
    Thread.current.report_on_exception = false
    until @closed
      attempt_fetch_coalesced(force: true)
      signal_ready
      begin
        @wake.pop(timeout: @poll_seconds * rand(0.8..1.2))
      rescue StandardError
        nil
      end
    end
  end
end

def attempt_fetch_coalesced(force:)
  @fetch_mutex.synchronize do
    attempt_fetch if force || stale?
  end
end
```

`refresh` switches from `@write_mutex` to `attempt_fetch_coalesced(force:)` — but with a freshness re-check for the non-force path INSIDE the mutex, so a caller that waited out someone else's in-flight fetch returns without fetching again; for `force: true` callers that waited, re-check `stale?` against a small floor (a fetch that completed while we waited counts — anchor on "an attempt completed after I started waiting": record `waited_from = Process.clock_gettime(...)` and skip if `@last_attempt_at && @last_attempt_at >= waited_from`). `signal_ready` broadcasts the CV once `@attempted` is true. `close` pushes to `@wake` and `@thread&.join(0.1)`.

`ready(timeout:)`:
```ruby
def ready(timeout: nil)
  return false if inert?
  ensure_started
  return on_demand_ready if on_demand? # Task 7
  @ready_mutex.synchronize do
    deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until @attempted
      remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return false if remaining && remaining <= 0
      @ready_cv.wait(@ready_mutex, remaining || 1.0)
      return false if @closed && !@attempted
    end
    true
  end
rescue StandardError
  false
end
```

(`on_demand?` returns false until Task 7 introduces mode resolution.)

- [ ] **Step 4: Run; PASS (run the file 5x — threading tests must not flake: `for i in 1 2 3 4 5; do bundle exec rake test N=$i || break; done`); commit**

```bash
git add -A && git commit -m "feat: background mode — lazy jittered poller, ready(), coalesced fetches, fork re-arm"
```

---

### Task 7: On-demand mode + mode resolution

**Files:**
- Modify: `lib/cru_flags/client.rb`
- Create: `test/client_on_demand_test.rb`

**Interfaces:**
- Produces: `refresh_mode:` resolution — constructor arg wins; else `ENV["CRU_FLAGS_REFRESH_MODE"]`; else `"background"`. Unrecognized ENV value → one `on_error` warning + background. Unrecognized CONSTRUCTOR value → `ArgumentError` at construction. `Client#on_demand?` (private ok).

**Behavior (spec §7.1):** in on-demand mode `ensure_started` never spawns; every read (`enabled?`, `snapshot`, `ready`) first calls `attempt_fetch_coalesced(force: false)` (staleness anchored on last ATTEMPT); `ready`'s `timeout:` is unused (call is bounded by fetch timeouts); concurrent readers coalesce (the `@fetch_mutex` already does this: first fetches, the rest find `stale?` false and return). `refresh(force: true)` still forces. `close` still terminal.

- [ ] **Step 1: Write the failing tests**

`test/client_on_demand_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"

class ClientOnDemandTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":true}}}', headers: {"ETag" => '"1"'})
  end

  def teardown
    @client&.close
    @service.stop
  end

  def new_client(**opts)
    @client = CruFlags::Client.new(url: @service.url, poll_seconds: 0.2, refresh_mode: "on-demand", **opts)
  end

  def test_no_thread_ever_and_first_read_fetches
    before = Thread.list.size
    client = new_client
    assert client.enabled?("pilot"), "first read performs the fetch"
    assert_equal before, Thread.list.size
  end

  def test_reads_within_interval_do_not_refetch
    client = new_client
    client.enabled?("pilot")
    10.times { client.enabled?("pilot") }
    assert_equal 1, @service.requests.size
  end

  def test_staleness_anchors_on_attempt_while_service_down
    @service.respond_with(status: 500, body: "x")
    client = new_client
    20.times { client.enabled?("pilot") }
    assert_operator @service.requests.size, :<=, 2,
      "a dead service costs one failed request per interval, not one per read"
  end

  def test_concurrent_first_reads_share_one_fetch
    @service.delay = 0.2
    client = new_client
    threads = 8.times.map { Thread.new { client.enabled?("pilot") } }
    results = threads.map(&:value)
    assert_equal 1, @service.requests.size
    assert results.all?, "every coalesced reader sees the fetched document"
  end

  def test_ready_performs_the_attempt
    client = new_client
    assert client.ready(timeout: 0.01), "timeout: is unused in on-demand mode"
    assert_equal 1, @service.requests.size
  end

  def test_unrecognized_env_value_warns_and_falls_back_to_background
    errors = []
    ENV["CRU_FLAGS_REFRESH_MODE"] = "sometimes"
    client = CruFlags::Client.new(url: @service.url, poll_seconds: 0.2, on_error: ->(e) { errors << e })
    client.ready(timeout: 2.0)
    assert(Thread.list.any? { |t| t.name == "cru-flags-poller" }, "fell back to background")
    assert_equal 1, errors.compact.size
    client.close
  ensure
    ENV.delete("CRU_FLAGS_REFRESH_MODE")
  end

  def test_unrecognized_constructor_value_raises
    assert_raises(ArgumentError) { CruFlags::Client.new(url: @service.url, refresh_mode: "sometimes") }
  end
end
```

- [ ] **Step 2: Run; FAIL. Step 3: Implement**

In `initialize`: `@refresh_mode = resolve_mode(refresh_mode)` where:

```ruby
MODES = %w[background on-demand].freeze

def resolve_mode(arg)
  if arg
    raise ArgumentError, "refresh_mode must be one of #{MODES.join(", ")}" unless MODES.include?(arg)
    return arg
  end
  env = ENV["CRU_FLAGS_REFRESH_MODE"].to_s.strip
  return "background" if env.empty?
  return env if MODES.include?(env)
  @mode_warning = "CRU_FLAGS_REFRESH_MODE=#{env.inspect} is not recognized; using background"
  "background"
end
```

(The warning is delivered through `report(FetchError.new(@mode_warning, code: :network))` on first start, because `@on_error` isn't assigned yet during `resolve_mode` if ordering puts it earlier — assign `@on_error` FIRST in `initialize`, then this can warn inline instead.) `on_demand? = @refresh_mode == "on-demand"`. Reads call `attempt_fetch_coalesced(force: false)` when `on_demand? && !inert? && !@closed`. `ensure_started` returns early when `on_demand?`. `on_demand_ready` = perform a read-path refresh, then `@attempted`.

- [ ] **Step 4: Run 5x; PASS; commit**

```bash
bundle exec rake && git add -A && git commit -m "feat: on-demand refresh mode — attempt-anchored, coalesced, threadless"
```

---

### Task 8: Module singleton + environment resolution

**Files:**
- Modify: `lib/cru_flags.rb`
- Create: `test/module_api_test.rb`

**Interfaces:**
- Produces: `CruFlags.enabled?(name)`, `.ready(timeout: nil)`, `.snapshot`, `.refresh(force: false)`, `.close`, `.client` (the singleton), `.reset!` (test hook: closes + discards the singleton — documented as not-public-API in a comment), `.flipper_adapter` (stub raising `NotImplementedError` until Task 9 — no, define it in Task 9; do not reference it here).

**Behavior (spec §3.1, §7.2):** the singleton is built on first module-method call with no arguments — so it reads `ENV["CRU_FLAGS_URL"]` at that moment (whitespace-only = unset → inert). Env caching then lives for the singleton's life; `reset!` is how tests get a fresh read. Thread-safe construction (a `Mutex` around the memoization).

- [ ] **Step 1: Write the failing tests**

`test/module_api_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"

class ModuleApiTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":true}}}')
  end

  def teardown
    CruFlags.reset!
    ENV.delete("CRU_FLAGS_URL")
    @service.stop
  end

  def test_reads_env_at_first_use_not_at_require
    ENV["CRU_FLAGS_URL"] = @service.url # set AFTER require — must still work
    assert CruFlags.ready(timeout: 2.0)
    assert CruFlags.enabled?("pilot")
    assert_equal "pilot", CruFlags.snapshot.dig("Flags").keys.first
  end

  def test_unset_env_is_inert_and_all_false
    refute CruFlags.enabled?("pilot")
    refute CruFlags.ready(timeout: 0.1)
    assert_equal({}, CruFlags.snapshot)
  end

  def test_whitespace_env_counts_as_unset
    ENV["CRU_FLAGS_URL"] = "   "
    refute CruFlags.enabled?("pilot")
  end

  def test_singleton_is_memoized_and_reset_discards_it
    ENV["CRU_FLAGS_URL"] = @service.url
    first = CruFlags.client
    assert_same first, CruFlags.client
    CruFlags.reset!
    refute_same first, CruFlags.client
  end
end
```

- [ ] **Step 2: Run; FAIL. Step 3: Implement in `lib/cru_flags.rb`**

```ruby
# frozen_string_literal: true

require_relative "cru_flags/version"
require_relative "cru_flags/errors"
require_relative "cru_flags/document"
require_relative "cru_flags/fetcher"
require_relative "cru_flags/client"

# Module-level singleton — the 99% path (design doc §3.1). Requiring this
# file does nothing: no env read, no socket, no thread.
module CruFlags
  ENV_VAR = "CRU_FLAGS_URL"

  @client_mutex = Mutex.new
  @client = nil

  class << self
    def client
      @client || @client_mutex.synchronize { @client ||= Client.new(url: url_from_env) }
    end

    def enabled?(name) = client.enabled?(name)

    def ready(timeout: nil) = client.ready(timeout:)

    def snapshot = client.snapshot

    def refresh(force: false) = client.refresh(force:)

    def close = client.close

    # Test hook, not public API: closes and discards the singleton so the
    # next call re-reads the environment.
    def reset!
      @client_mutex.synchronize do
        @client&.close
        @client = nil
      end
    end

    private

    def url_from_env
      value = ENV[ENV_VAR].to_s.strip
      value.empty? ? nil : value
    end
  end
end

require_relative "cru_flags/railtie" if defined?(Rails::Railtie)
```

(The railtie require line lands with Task 10; include it now pointing at a file created there ONLY if Task 10 is in the same PR — it is. Guard: create an empty `lib/cru_flags/railtie.rb` containing just `# frozen_string_literal: true` now so the require never breaks, and fill it in Task 10.)

- [ ] **Step 4: Run; PASS; commit**

```bash
bundle exec rake && git add -A && git commit -m "feat: module singleton — env at first use, reset! test hook"
```

---

### Task 9: Flipper adapter

**Files:**
- Create: `lib/cru_flags/flipper_adapter.rb`, `test/flipper_adapter_test.rb`
- Modify: `lib/cru_flags.rb` (add `CruFlags.flipper_adapter`; require the adapter file lazily inside that method — the client core must not load flipper)

**Interfaces:**
- Consumes: `Client#snapshot`-adjacent internals — add `Client#flags_for_adapter -> Hash` (frozen `doc["Flags"]` or `{}`; also triggers the same read-path behavior as `enabled?`: `ensure_started`/on-demand refresh).
- Produces: `CruFlags::FlipperAdapter.new(client)` implementing Flipper's adapter API; `CruFlags.flipper_adapter` returning a memoized instance bound to the singleton client.

**Flipper adapter API (verified against flipper v1.4.2 source):** `features` (Set of names), `add(feature)`, `remove(feature)`, `clear(feature)`, `get(feature)`, `get_multi(features)`, `get_all`, `enable(feature, gate, thing)`, `disable(feature, gate, thing)`, plus `name` (Symbol) and `read_only?`. Gate-value hashes must be shaped like `Flipper::Adapter.default_config` (`{boolean: nil, groups: Set, actors: Set, percentage_of_actors: nil, percentage_of_time: nil, expression: nil}`); boolean truthy via `Typecast.to_boolean` accepts `true`.

**HARD RULE (spec §5):** `get`/`get_multi`/`get_all` return freshly-built, unfrozen top-level Hashes every call — `Flipper::Adapters::Memoizable#get_all` MUTATES the returned Hash (`response.default_proc = ...`). The test suite pins this by calling through Memoizable with memoization on.

- [ ] **Step 1: Write the failing tests**

`test/flipper_adapter_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"
require "flipper"

class FlipperAdapterTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @service.respond_with(status: 200,
      body: '{"Flags":{"pilot":{"Enabled":true},"dark":{"Enabled":false}}}')
    @client = CruFlags::Client.new(url: @service.url)
    @client.refresh(force: true)
    @adapter = CruFlags::FlipperAdapter.new(@client)
    @flipper = Flipper.new(@adapter)
  end

  def teardown
    @client.close
    @service.stop
  end

  def test_flipper_enabled_end_to_end
    assert @flipper.enabled?(:pilot)
    refute @flipper.enabled?(:dark)
    refute @flipper.enabled?(:absent)
  end

  def test_features_is_the_documents_flag_names
    assert_equal Set.new(%w[pilot dark]), @adapter.features
  end

  def test_gate_hashes_are_default_config_shaped
    gates = @adapter.get(@flipper.feature(:pilot))
    assert_equal Flipper::Adapter.default_config.keys.sort, gates.keys.sort
    assert_equal true, gates[:boolean]
  end

  def test_writes_raise_read_only_error
    feature = @flipper.feature(:pilot)
    assert_raises(CruFlags::ReadOnlyError) { @flipper.enable(:new_flag) }
    assert_raises(CruFlags::ReadOnlyError) { @flipper.disable(:pilot) }
    assert_raises(CruFlags::ReadOnlyError) { @adapter.add(feature) }
    assert_raises(CruFlags::ReadOnlyError) { @adapter.remove(feature) }
    assert_raises(CruFlags::ReadOnlyError) { @adapter.clear(feature) }
  end

  def test_get_all_survives_memoizable_mutation
    memoized = Flipper::Adapters::Memoizable.new(@adapter)
    memoized.memoize = true
    result = memoized.get_all # Memoizable sets default_proc on the returned Hash
    assert result.key?("pilot")
    assert_equal true, result["pilot"][:boolean]
  end

  def test_get_all_returns_a_fresh_unfrozen_hash_every_call
    a = @adapter.get_all
    b = @adapter.get_all
    refute_same a, b
    refute_predicate a, :frozen?
    a.default_proc = ->(h, k) { h[k] = nil } # the exact Memoizable mutation
  end

  def test_get_all_is_marshalable
    Marshal.dump(@adapter.get_all) # ararat's MarshalableFlipperReads regression
  end

  def test_inert_client_reads_all_off
    inert = CruFlags::Client.new(url: nil)
    flipper = Flipper.new(CruFlags::FlipperAdapter.new(inert))
    refute flipper.enabled?(:pilot)
    inert.close
  end
end
```

- [ ] **Step 2: Run; FAIL. Step 3: Implement**

`lib/cru_flags/flipper_adapter.rb`:
```ruby
# frozen_string_literal: true

require "flipper"
require "set"

module CruFlags
  # Read-only Flipper adapter over the client's frozen snapshot (design doc
  # §5). HARD RULE: get/get_multi/get_all build fresh, UNFROZEN top-level
  # hashes on every call — Flipper::Adapters::Memoizable mutates the Hash we
  # return (response.default_proc =, memoizable.rb:103), so a frozen or
  # shared return value would raise FrozenError on every memoized request.
  class FlipperAdapter
    include Flipper::Adapter

    def initialize(client)
      @client = client
    end

    def name = :cru_flags

    def read_only? = true

    def features
      @client.flags_for_adapter.keys.to_set
    end

    def get(feature)
      gates_for(feature.key)
    end

    def get_multi(features)
      flags = @client.flags_for_adapter
      features.to_h { |feature| [feature.key, gates_for(feature.key, flags)] }
    end

    def get_all
      flags = @client.flags_for_adapter
      flags.keys.to_h { |name| [name, gates_for(name, flags)] }
    end

    def add(_feature) = write_refused
    def remove(_feature) = write_refused
    def clear(_feature) = write_refused
    def enable(_feature, _gate, _thing) = write_refused
    def disable(_feature, _gate, _thing) = write_refused

    private

    def gates_for(name, flags = @client.flags_for_adapter)
      gates = self.class.default_config.dup
      gates[:boolean] = true if flags.dig(name, "Enabled") == true
      gates
    end

    def write_refused
      raise ReadOnlyError, "flags are written by cru-cli and the deploys.cru.org dashboard, never by the app"
    end
  end
end
```

Add to `Client`:
```ruby
# The Flipper adapter's read primitive: the frozen Flags hash (or {}),
# through the same read path as enabled? (lazy start / on-demand refresh).
def flags_for_adapter
  read_path_touch
  @document&.fetch("Flags", nil) || {}
rescue StandardError
  {}
end
```
where `read_path_touch` is the existing private pre-read hook `enabled?` uses (`ensure_started` / on-demand refresh) — extract it in this task if Tasks 6–7 inlined it.

Add to `lib/cru_flags.rb` `class << self` block:
```ruby
def flipper_adapter
  @flipper_adapter_mutex ||= Mutex.new
  @flipper_adapter || @flipper_adapter_mutex.synchronize do
    @flipper_adapter ||= begin
      require_relative "cru_flags/flipper_adapter"
      FlipperAdapter.new(client)
    end
  end
end
```
(and clear `@flipper_adapter` in `reset!`; initialize `@flipper_adapter_mutex = Mutex.new` next to `@client_mutex` at module level rather than lazily — lazy mutex init is racy).

**Check `Flipper::Adapter.default_config` at implementation time**: it is `include Flipper::Adapter`'s `self.class.default_config` (instance side: `default_config`) — use whichever form the included module provides in 1.4.x (`Flipper::Adapter::ClassMethods#default_config`); the test asserts key parity so a mismatch fails loudly.

- [ ] **Step 4: Run; PASS; commit**

```bash
bundle exec rake && git add -A && git commit -m "feat: read-only Flipper adapter — default_config-shaped, Memoizable-safe"
```

---

### Task 10: Railtie

**Files:**
- Modify: `lib/cru_flags/railtie.rb` (was an empty placeholder from Task 8)
- Create: `test/railtie_logic_test.rb`

**Interfaces:**
- Produces: `CruFlags::Railtie` (only defined when `Rails::Railtie` is); pure decision function `CruFlags::Railtie.quiet_strict?(current:, env_var:, rails_env:) -> bool`.

**Behavior (spec §5.1):**
- Initializer `"cru_flags.flipper"` (ordinary ordering): `Flipper.configure { |config| config.adapter { CruFlags.flipper_adapter } }`. Safe because Flipper's engine resolves `config.adapter` lazily at first `Flipper.instance` access and last-registered block wins, so an app's own `Flipper.configure` still overrides.
- Strict quieting: set `app.config.flipper.strict = false` ONLY when `quiet_strict?` is true — `env_var` (`ENV["FLIPPER_STRICT"]`) is nil AND `current` equals Flipper's own computed default for `rails_env` (`:warn` when `rails_env == "development"`, `false` otherwise). Any app-chosen value survives.

- [ ] **Step 1: Write the failing logic tests**

`test/railtie_logic_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "rails/railtie"
require "cru_flags"
require "cru_flags/railtie"

class RailtieLogicTest < Minitest::Test
  def quiet?(current:, env_var: nil, rails_env: "development")
    CruFlags::Railtie.quiet_strict?(current:, env_var:, rails_env:)
  end

  def test_quiets_flippers_own_dev_default
    assert quiet?(current: :warn)
  end

  def test_quiets_flippers_own_prod_default
    assert quiet?(current: false, rails_env: "production")
  end

  def test_honors_explicit_env_var
    refute quiet?(current: :warn, env_var: "warn")
    refute quiet?(current: false, env_var: "false", rails_env: "production")
  end

  def test_honors_app_chosen_values_that_differ_from_the_default
    refute quiet?(current: true) # dev default is :warn; true means the app chose
    refute quiet?(current: :warn, rails_env: "production") # prod default is false
  end

  def test_railtie_is_defined_when_rails_is
    assert CruFlags::Railtie.ancestors.include?(Rails::Railtie)
  end
end
```

- [ ] **Step 2: Run; FAIL. Step 3: Implement `lib/cru_flags/railtie.rb`**

```ruby
# frozen_string_literal: true

module CruFlags
  # Zero-config Rails wiring (design doc §5.1). Registration is ordering-safe
  # because Flipper's engine resolves config.adapter LAZILY on first
  # Flipper.instance access, and the last-registered adapter block wins — an
  # app's own Flipper.configure in config/initializers still overrides ours.
  class Railtie < Rails::Railtie
    # Flipper's engine assigns config.flipper.strict in before_configuration
    # (:warn in development, false elsewhere) — BEFORE any gem initializer —
    # so "did the app set it" cannot be read off the config value alone. We
    # quiet strict only when the env var is unset AND the value still equals
    # Flipper's own computed default, i.e. only when nobody chose it.
    def self.quiet_strict?(current:, env_var:, rails_env:)
      return false unless env_var.nil?
      flipper_default = (rails_env == "development") ? :warn : false
      current == flipper_default
    end

    initializer "cru_flags.flipper" do |app|
      require "flipper"
      Flipper.configure { |config| config.adapter { CruFlags.flipper_adapter } }

      if app.config.respond_to?(:flipper) &&
          Railtie.quiet_strict?(current: app.config.flipper.strict,
            env_var: ENV["FLIPPER_STRICT"], rails_env: Rails.env.to_s)
        app.config.flipper.strict = false
      end
    end
  end
end
```

- [ ] **Step 4: Run; PASS; commit**

```bash
bundle exec rake && git add -A && git commit -m "feat: railtie — lazy adapter registration, provably-default-only strict quieting"
```

---

### Task 11: Side-effect, concurrency, and distribution-shape tests

**Files:**
- Create: `test/side_effects_test.rb`, `test/concurrency_test.rb`

**Interfaces:** none new — this task pins global guarantees.

- [ ] **Step 1: Write the tests (they should PASS against the finished client — any failure here is a real bug found)**

`test/side_effects_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "rbconfig"

class SideEffectsTest < Minitest::Test
  RUBY = RbConfig.ruby
  LIB = File.expand_path("../lib", __dir__)

  def test_require_starts_no_threads_even_with_url_set
    script = 'require "cru_flags"; ' \
      'puts Thread.list.size; ' \
      'exit(Thread.list.size == 1 ? 0 : 1)'
    assert system({"CRU_FLAGS_URL" => "http://127.0.0.1:9/flags/x/production"},
      RUBY, "-I", LIB, "-e", script), "require must not start threads or read the env"
  end

  def test_active_poller_never_delays_interpreter_exit
    service = FlagService.new.start
    service.respond_with(status: 200, body: '{"Flags":{}}')
    script = 'require "cru_flags"; CruFlags.ready(timeout: 5)'
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert system({"CRU_FLAGS_URL" => service.url}, RUBY, "-I", LIB, "-e", script)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 5.0,
      "process must exit immediately, not wait for a 30s poll tick"
  ensure
    service&.stop
  end

  def test_child_process_after_fork_gets_its_own_poller
    skip "fork unavailable" unless Process.respond_to?(:fork)
    service = FlagService.new.start
    service.respond_with(status: 200, body: '{"Flags":{"pilot":{"Enabled":true}}}')
    script = <<~RUBY
      require "cru_flags"
      CruFlags.ready(timeout: 5) or exit 2
      pid = fork do
        exit(CruFlags.enabled?("pilot") ? 0 : 3)
      end
      _, status = Process.waitpid2(pid)
      exit(status.exitstatus)
    RUBY
    assert system({"CRU_FLAGS_URL" => service.url}, RUBY, "-I", LIB, "-e", script),
      "a forked child must re-arm and answer reads"
  ensure
    service&.stop
  end
end
```

`test/concurrency_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"
require "json"

class ConcurrencyTest < Minitest::Test
  def test_readers_never_see_a_half_applied_swap
    service = FlagService.new.start
    docs = [
      '{"Version":1,"Flags":{"a":{"Enabled":true},"b":{"Enabled":true}}}',
      '{"Version":2,"Flags":{"a":{"Enabled":false},"b":{"Enabled":false}}}'
    ]
    turn = 0
    service.respond { |_req| [200, {}, docs[(turn += 1) % 2]] }
    client = CruFlags::Client.new(url: service.url, poll_seconds: 0.01)
    client.ready(timeout: 2.0)
    stop = false
    violations = []
    readers = 8.times.map do
      Thread.new do
        until stop
          snap = client.snapshot
          next if snap.empty?
          a = snap.dig("Flags", "a", "Enabled")
          b = snap.dig("Flags", "b", "Enabled")
          violations << snap if a != b # the two docs always agree internally
        end
      end
    end
    sleep 1.0
    stop = true
    readers.each(&:join)
    assert_empty violations, "a reader observed a torn document"
  ensure
    client&.close
    service&.stop
  end

  def test_jitter_distribution_stays_in_band
    samples = 10_000.times.map { rand(0.8..1.2) }
    assert_operator samples.min, :>=, 0.8
    assert_operator samples.max, :<=, 1.2
    assert_in_delta 1.0, samples.sum / samples.size, 0.01
  end
end
```

- [ ] **Step 2: Run the whole suite 5x; all green, no flakes; commit**

```bash
for i in 1 2 3 4 5; do bundle exec rake || break; done
git add -A && git commit -m "test: subprocess side-effect guarantees, fork re-arm, torn-read hammer"
```

---

### Task 12: Release plumbing + verify_live + PR

**Files:**
- Create: `.github/workflows/release.yml`, `.github/dependabot.yml`, `release-please-config.json`, `.release-please-manifest.json`, `CHANGELOG.md`, `test/verify_live.rb`

- [ ] **Step 1: Write the release-please config (the version-file path is load-bearing — the default derivation for a hyphenated name resolves to `lib/cru/flags/version.rb`, which does not exist)**

`release-please-config.json`:
```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "ruby",
  "packages": {
    ".": {
      "package-name": "cru-flags",
      "version-file": "lib/cru_flags/version.rb",
      "bump-minor-pre-major": true,
      "bump-patch-for-minor-pre-major": true
    }
  }
}
```

`.release-please-manifest.json`:
```json
{".": "0.1.0"}
```

`CHANGELOG.md`:
```markdown
# Changelog
```

- [ ] **Step 2: Write `.github/workflows/release.yml` (RubyGems Trusted Publishing — OIDC, no API key; first publish rides the pending-publisher flow)**

```yaml
name: Release
on:
  push:
    branches: [main]
jobs:
  release-please:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    outputs:
      release_created: ${{ steps.release.outputs.release_created }}
    steps:
      - id: release
        uses: googleapis/release-please-action@v4
  publish:
    needs: release-please
    if: needs.release-please.outputs.release_created == 'true'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      id-token: write
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - run: bundle exec rake
      - uses: rubygems/release-gem@v1
```

- [ ] **Step 3: Write `.github/dependabot.yml` (the fleet's security-only posture, ADL-32 template shape)**

```yaml
version: 2
updates:
  - package-ecosystem: bundler
    directory: "/"
    schedule:
      interval: daily
    open-pull-requests-limit: 0
    groups:
      security-updates:
        applies-to: security-updates
        patterns: ["*"]
  - package-ecosystem: github-actions
    directory: "/"
    schedule:
      interval: weekly
    open-pull-requests-limit: 3
```

- [ ] **Step 4: Write `test/verify_live.rb` (opt-in, NOT matched by the rake glob since it does not end in `_test.rb`... it does — name it `verify_live.rb` exactly so `test/*_test.rb` skips it)**

```ruby
# frozen_string_literal: true

# Opt-in, NETWORKED verification against the real public endpoint.
# Deliberately not part of CI (design doc §9). Run:
#   CRU_FLAGS_URL=https://deploys.cru.org/flags/ararat/release-candidate ruby -Ilib test/verify_live.rb
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cru_flags"

abort "set CRU_FLAGS_URL" unless ENV["CRU_FLAGS_URL"]
abort "not ready within 15s" unless CruFlags.ready(timeout: 15)
snap = CruFlags.snapshot
%w[Project Environment Version Flags].each do |key|
  abort "snapshot missing #{key}: #{snap.keys}" unless snap.key?(key)
end
abort "second conditional fetch should be fresh (304 path)" unless CruFlags.refresh(force: true)
puts "OK: #{snap["Project"]}/#{snap["Environment"]} v#{snap["Version"]}, #{snap["Flags"].size} flag(s)"
```

- [ ] **Step 5: Full suite 5x + standardrb; fix anything; commit**

```bash
for i in 1 2 3 4 5; do bundle exec rake || break; done
git add -A && git commit -m "chore: release-please + trusted publishing + security-only dependabot + live check"
```

- [ ] **Step 6: Push branch and open the PR**

```bash
git push -u origin build-v0
gh pr create -R CruGlobal/cru-flags-ruby --title "feat: the cru-flags client — sibling contract + Flipper adapter" \
  --body "Implements docs/design.md end to end. See the plan at docs/superpowers/plans/2026-08-21-cru-flags-ruby.md for the task-by-task record."
```

---

## Self-Review Notes (kept for executors)

- Spec §3.5 in-flight coalescing is implemented in Task 6 and tested by `test_concurrent_refresh_calls_share_one_request`; §7.1's read coalescing by `test_concurrent_first_reads_share_one_fetch`.
- Spec §5 HARD RULE is Task 9's `test_get_all_survives_memoizable_mutation` + `test_get_all_returns_a_fresh_unfrozen_hash_every_call`.
- Spec §7 fork re-arm: Task 6 implementation, Task 11 subprocess proof.
- Spec §9's "suite emits no warnings" ambition is NOT enforced in v0 (minitest has no filterwarnings equivalent with teeth); revisit post-v0. Everything else in §9 has a task.
- Trusted-publisher setup on rubygems.org (pending publisher for `cru-flags` → this repo/workflow) is a HUMAN step for Justin — the release workflow is inert until then.
