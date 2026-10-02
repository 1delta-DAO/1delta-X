#!/usr/bin/env python3
"""Fail if a foundry profile is reachable from no make target (audit 2026-09-30 MISC-MOD-6).

`[profile.modules-erc4626]` existed in foundry.toml while the package sat in no make
target, so its regressions never ran in `test-all` or CI. Every profile must be in
the Makefile's ALL_PACKAGES (which the CI matrix is built from), except the
deploy-only profiles listed here with their reason.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NOT_A_TEST_PACKAGE = {
    "default": "whole-monorepo default, never run directly",
    "core-deploy": "via-IR deploy build of Settlement; gated by `make size-check` / `make test-deployed`",
    "periphery-deploy": "via-IR deploy build of the lens/7683 settlers; gated by `make size-check`",
}


def main() -> int:
    profiles = set(re.findall(r"^\[profile\.([A-Za-z0-9_-]+)\]", (ROOT / "foundry.toml").read_text(), re.M))
    out = subprocess.run(["make", "-s", "print-packages"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    packages = set(json.loads(out))
    missing = sorted(profiles - packages - set(NOT_A_TEST_PACKAGE))
    unknown = sorted(packages - profiles)
    if missing:
        print("foundry profile(s) reachable from no make target (add to PACKAGES / FORK_PACKAGES):")
        for m in missing:
            print("  " + m)
    if unknown:
        print("ALL_PACKAGES names profile(s) foundry.toml does not define:")
        for u in unknown:
            print("  " + u)
    if missing or unknown:
        return 1
    print(f"{len(packages)} test packages; every foundry profile is gated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
