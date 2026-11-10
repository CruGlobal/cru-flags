#!/usr/bin/env python3
"""The test server every client's conformance tests run against.

It serves the cases in ``cases.json`` beside it. Standard library only, so
any ``python3`` (3.11 or newer) can run it, whatever language is under test.

Protocol, for the test harnesses:

* Start it as ``python3 conformance/server.py``. It binds an ephemeral port
  on 127.0.0.1 and prints one line, ``PORT <number>``, once it is serving.
* ``GET /flags/<case>/<run>`` serves the case's responses in order: the
  first request gets ``responses[0]``, the second ``responses[1]``, and once
  the list runs out the last one repeats. ``<run>`` is any token the harness
  picks, so each client instance gets its own counter and request log.
* ``GET /log/<case>/<run>`` returns what that run has been sent so far, as a
  JSON list of ``{"headers": {...}}`` with lower-cased header names.
* It exits when its stdin reaches end-of-file, so a harness that dies cannot
  leave it running. Pass ``--port`` to run it by hand on a fixed port.
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

CASES_FILE = Path(__file__).resolve().parent / "cases.json"


class Script:
    """The cases and documents from cases.json, plus what each run was sent."""

    def __init__(self, raw: dict[str, Any]) -> None:
        """Index the cases by name."""
        self.documents: dict[str, Any] = raw["documents"]
        self.cases: dict[str, dict[str, Any]] = {c["name"]: c for c in raw["cases"]}
        self._lock = threading.Lock()
        self._log: dict[str, list[dict[str, Any]]] = {}

    def next_response(
        self, case: str, run: str, headers: dict[str, str]
    ) -> dict[str, Any]:
        """Record one request for a run and return the response it gets."""
        responses = self.cases[case]["responses"]
        with self._lock:
            seen = self._log.setdefault(f"{case}/{run}", [])
            seen.append({"headers": headers})
            index = min(len(seen), len(responses)) - 1
        return responses[index]  # type: ignore[no-any-return]

    def log(self, case: str, run: str) -> list[dict[str, Any]]:
        """Return a copy of the requests recorded for a run."""
        with self._lock:
            return list(self._log.get(f"{case}/{run}", []))

    def body(self, response: dict[str, Any]) -> tuple[bytes, str]:
        """Build a response's body and its content type."""
        if "body" in response:
            return response["body"].encode(), "text/plain; charset=utf-8"
        if "document" in response:
            value: Any = dict(self.documents[response["document"]])
        elif "json" in response:
            value = response["json"]
        else:
            return b"", ""
        if "padToBytes" in response:
            value["Padding"] = ""
            short = response["padToBytes"] - len(json.dumps(value).encode())
            value["Padding"] = "x" * max(short, 0)
        return json.dumps(value).encode(), "application/json"


class Handler(BaseHTTPRequestHandler):
    """Serves /flags/<case>/<run> and /log/<case>/<run>."""

    script: Script

    def do_GET(self) -> None:
        """Route one GET."""
        parts = self.path.split("?", 1)[0].strip("/").split("/")
        if len(parts) == 3 and parts[1] in self.script.cases:  # noqa: PLR2004
            kind, case, run = parts
            if kind == "flags":
                self._serve_case(case, run)
                return
            if kind == "log":
                self._send(
                    HTTPStatus.OK,
                    json.dumps(self.script.log(case, run)).encode(),
                    "application/json",
                )
                return
        usage = f"expected /flags/<case>/<run> or /log/<case>/<run>, got {self.path}\n"
        self._send(HTTPStatus.BAD_REQUEST, usage.encode(), "text/plain; charset=utf-8")

    def _serve_case(self, case: str, run: str) -> None:
        headers = {name.lower(): value for name, value in self.headers.items()}
        response = self.script.next_response(case, run, headers)
        if "delayMs" in response:
            time.sleep(response["delayMs"] / 1000)
        body, content_type = self.script.body(response)
        extra = {"ETag": response["etag"]} if "etag" in response else {}
        self._send(response["status"], body, content_type, extra)

    def _send(
        self,
        status: int,
        body: bytes,
        content_type: str,
        extra: dict[str, str] | None = None,
    ) -> None:
        try:
            self.send_response(status)
            self.send_header("Cache-Control", "no-cache")
            for name, value in (extra or {}).items():
                self.send_header(name, value)
            if status != HTTPStatus.NOT_MODIFIED:
                if content_type:
                    self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if status != HTTPStatus.NOT_MODIFIED:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # The client gave up first, which is what a timeout case expects.
            pass

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Stay quiet: test output is the harness's to report."""


def main() -> None:
    """Serve until stdin closes."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()

    Handler.script = Script(json.loads(CASES_FILE.read_text()))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True

    def stop_at_eof() -> None:
        sys.stdin.buffer.read()
        server.shutdown()

    threading.Thread(target=stop_at_eof, daemon=True).start()
    sys.stdout.write(f"PORT {server.server_address[1]}\n")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
