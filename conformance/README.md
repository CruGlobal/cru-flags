# Conformance suite

The behavior every cru-flags client shares, written down once as data and
checked against every client in CI. If a case here and a client disagree, the
client is wrong, or the case changes for every client in the same PR.

- [`cases.json`](cases.json): the cases, and the flag documents they serve.
- [`server.py`](server.py): a standard-library Python HTTP server that serves
  each case's responses in order and records what the client sent.

Each client runs every case from its own test suite:

| Client     | Harness                                                   |
| ---------- | --------------------------------------------------------- |
| Go         | [`conformance_test.go`](../conformance_test.go)           |
| TypeScript | [`test/conformance.test.ts`](../test/conformance.test.ts) |
| Python     | [`tests/test_conformance.py`](../tests/test_conformance.py) |
| Ruby       | [`test/conformance_test.rb`](../test/conformance_test.rb) |

The harnesses start `server.py` with whatever `python3` is on `PATH` (3.11 or
newer). Every CI runner has one.

## What the cases pin down

| Rule                                                                                  | Cases                                                                           |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| A flag reads its document's `Enabled` value; only a JSON `true` is on                 | `document`, `enabled-must-be-literal-true`                                      |
| A flag the document does not name is off; names are case-sensitive                   | `unknown-flag`                                                                  |
| Revalidate with `If-None-Match`; a `304` keeps the document                           | `not-modified`, `changed-document`                                              |
| A failed fetch keeps the last good document, forever                                  | `server-error-keeps-last-known-good`, `timeout-keeps-last-known-good`           |
| A body that is not a JSON object, or is over 1 MiB, is a failed fetch                 | `malformed-body-keeps-last-known-good`, `body-not-an-object`, `oversized-body`  |
| A rejected body's `ETag` is never stored                                              | `malformed-body-keeps-last-known-good`                                          |
| Before any document, every flag is off                                                | `server-error-before-any-document`                                              |
| `404` means "no flags yet": every flag off, not an error, and the `ETag` is forgotten  | `not-found-is-not-an-error`, `not-found-drops-the-document`                      |
| Health is reported on transitions only: once failing, once recovered                  | `server-error-keeps-last-known-good`, `recovers-after-failure`                  |
| No `CRU_FLAGS_URL`: every flag off, no requests, nothing reported                     | `no-url`                                                                        |

What the suite does not cover, because it is runtime-specific and each client
tests it itself: polling cadence and jitter, the on-demand refresh mode,
concurrency, and how each client logs.

## Case format

```jsonc
{
  "name": "not-modified",            // test name in every harness
  "description": "...",
  "url": false,                       // optional: build the client with no URL
  "responses": [                      // request N gets responses[N]; the last repeats
    { "status": 200, "etag": "\"3\"", "document": "v3" },
    { "status": 304 }
  ],
  "steps": [
    { "do": "ready", "enabled": { "pilot_banner": true } },
    {
      "do": "refresh",                // a forced refresh, awaited
      "enabled": { "pilot_banner": true },
      "requests": 2,                  // requests the server has seen so far
      "ifNoneMatch": "\"3\"",         // If-None-Match on the latest request (null: absent)
      "events": []                    // health events so far: "failing" / "recovered"
    }
  ]
}
```

A response body is one of `document` (a name from `documents`), `json` (any
JSON value) or `body` (raw text). `padToBytes` pads a document to that many
bytes, and `delayMs` holds the response back.

Each harness builds its client with a one-hour poll interval (so no background
poll fires mid-case), a one-second fetch timeout, background refresh mode,
and an error hook that records `failing` and `recovered`. `ready` waits for the
first fetch; `refresh` forces one more and waits for it. Every check in a step
is optional.

## Changing the contract

1. Add or change the case in `cases.json`.
2. Run every client's suite. Each one that fails gets fixed in the same PR.
3. If a change also alters a client's designed behavior, update that
   client's `docs/<language>/design.md` too.

To poke at the server by hand:

```sh
python3 conformance/server.py --port 8099
curl -i http://127.0.0.1:8099/flags/not-modified/try1
curl -i -H 'If-None-Match: "3"' http://127.0.0.1:8099/flags/not-modified/try1
curl http://127.0.0.1:8099/log/not-modified/try1
```
