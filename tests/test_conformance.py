"""The shared conformance cases (conformance/cases.json), run against this client.

Every client in the repository runs the same cases against the same server,
conformance/server.py. See conformance/README.md.
"""

from __future__ import annotations

import json
import subprocess
import sys
import urllib.request
import uuid
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

from cru_flags import Client

ROOT = Path(__file__).resolve().parent.parent
CASES: list[dict[str, Any]] = json.loads(
    (ROOT / "conformance" / "cases.json").read_text()
)["cases"]


@pytest.fixture(scope="module")
def server() -> Iterator[str]:
    process = subprocess.Popen(  # noqa: S603 - our own script, by absolute path
        [sys.executable, str(ROOT / "conformance" / "server.py")],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    try:
        port = process.stdout.readline().split()[1]
        yield f"http://127.0.0.1:{port}"
    finally:
        process.stdin.close()
        process.wait(timeout=10)
        process.stdout.close()


def _requests_seen(server: str, case: str, run: str) -> list[dict[str, Any]]:
    with urllib.request.urlopen(f"{server}/log/{case}/{run}", timeout=5) as response:
        log: list[dict[str, Any]] = json.load(response)
    return log


@pytest.mark.parametrize("case", CASES, ids=[case["name"] for case in CASES])
def test_conformance(
    case: dict[str, Any], server: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("CRU_FLAGS_URL", raising=False)
    monkeypatch.delenv("CRU_FLAGS_REFRESH_MODE", raising=False)
    run = uuid.uuid4().hex
    url = f"{server}/flags/{case['name']}/{run}" if case.get("url", True) else None
    events: list[str] = []

    def on_error(error: BaseException | None) -> None:
        events.append("recovered" if error is None else "failing")

    client = Client(
        url=url,
        poll_seconds=3600,
        fetch_timeout=1.0,
        on_error=on_error,
        refresh_mode="background",
    )
    try:
        for index, step in enumerate(case["steps"]):
            where = f"{case['name']} step {index} ({step['do']})"
            if step["do"] == "ready":
                client.ready(timeout=10)
            else:
                client.refresh(force=True)

            for name, expected in step.get("enabled", {}).items():
                assert client.enabled(name) is expected, f"{where}: enabled({name!r})"
            if url is not None and ("requests" in step or "ifNoneMatch" in step):
                seen = _requests_seen(server, case["name"], run)
                if "requests" in step:
                    assert len(seen) == step["requests"], f"{where}: requests"
                if "ifNoneMatch" in step:
                    sent = seen[-1]["headers"].get("if-none-match")
                    assert sent == step["ifNoneMatch"], f"{where}: If-None-Match"
            if "events" in step:
                assert events == step["events"], f"{where}: health events"
    finally:
        client.close()
