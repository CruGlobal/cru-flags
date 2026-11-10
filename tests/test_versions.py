"""Every package in the repository declares the same version.

release-please bumps all of these in one commit (release-please-config.json's
`extra-files`). If one is missed, or someone edits one by hand, the packages
would publish under different numbers; this fails the build first.
"""

from __future__ import annotations

import json
import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _declared_versions() -> dict[str, str]:
    package = json.loads((ROOT / "package.json").read_text())
    lock = json.loads((ROOT / "package-lock.json").read_text())
    pyproject = tomllib.loads((ROOT / "pyproject.toml").read_text())
    manifest = json.loads((ROOT / ".release-please-manifest.json").read_text())
    ruby = re.search(
        r'VERSION = "([^"]+)"', (ROOT / "lib/cru_flags/version.rb").read_text()
    )
    assert ruby is not None, "lib/cru_flags/version.rb has no VERSION"
    return {
        ".release-please-manifest.json": manifest["."],
        "package.json": package["version"],
        "package-lock.json": lock["version"],
        'package-lock.json packages[""]': lock["packages"][""]["version"],
        "pyproject.toml": pyproject["project"]["version"],
        "lib/cru_flags/version.rb": ruby.group(1),
    }


def test_every_package_declares_the_same_version() -> None:
    versions = _declared_versions()
    assert len(set(versions.values())) == 1, versions
