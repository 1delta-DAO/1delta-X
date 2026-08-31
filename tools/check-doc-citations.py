#!/usr/bin/env python3
"""Fail if a doc cites a test that does not exist.

The matrices in `docs/edge-case-matrix.md` bind every classified combination to
the test that pins it, and `docs/reference-audits.md` binds every finding to its
regression. Those bindings are hand-written prose: rename or delete a test and
the table still claims the cell is covered. That is the same failure mode as
F13 itself — a documented guarantee drifting away from what the code does — so
it gets the same treatment as `edge-case-matrix.md` Part 3: an enumeration
derived from the source rather than from memory.

Citation forms recognised inside backticks:

    Suite:test_name          a specific test
    test_name                a specific test, suite implied by context
    test_prefix_*            a family (at least one must exist)
    ..._suffix               prefix elided from the previous citation

Usage:  python3 tools/check-doc-citations.py [docs/foo.md ...]
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def existing_tests() -> set[str]:
    """Test/invariant function names declared in Solidity test sources.

    Scoped to `*.t.sol` and `*.sol` under a `test/` directory, and explicitly
    excluding `node_modules`, `cache/` and `out/`. That is not tidiness: a bare
    recursive scan of `packages/` also matches `function test...` inside bundled
    JavaScript and stale Foundry build artifacts, which makes the set a SUPERSET
    of reality — and a superset turns this check into a false negative, letting a
    doc cite a test that no longer exists. It also made the count drift between
    runs, which is how the contamination was noticed.
    """
    out = subprocess.run(
        ["grep", "-rhoE", "--include=*.sol",
         "--exclude-dir=node_modules", "--exclude-dir=cache", "--exclude-dir=out",
         r"function (test|invariant)[A-Za-z0-9_]*", "packages/"],
        cwd=ROOT, capture_output=True, text=True,
    ).stdout
    return {line.split()[1] for line in out.splitlines() if line.strip()}


def inline_spans(text: str) -> list[str]:
    """Backtick spans, fenced code blocks removed first.

    Naive pairing across the whole file is WRONG: a ``` fence is an odd run of
    backticks, so every span after the first fenced block pairs up inverted and
    the real citations land "outside". That silently passed this check on a doc
    that cited nothing at all — the first version of this script did exactly
    that. Strip the fences, then match spans that do not cross a newline.
    """
    text = re.sub(r"^\s*```.*?^\s*```", "", text, flags=re.S | re.M)
    return re.findall(r"`([^`\n]+)`", text)


def check(doc: Path, tests: set[str]) -> list[str]:
    failures = []
    for span in inline_spans(doc.read_text(encoding="utf-8")):
        # `..._suffix` — the prefix is elided; resolve by suffix match.
        for suffix in re.findall(r"\.\.\.(_[A-Za-z0-9_]+)", span):
            if not any(t.endswith(suffix) for t in tests):
                failures.append(f"{doc}: no test ends with '{suffix}'  (from `...{suffix}`)")
        # `test_prefix_*` — a family; at least one member must exist.
        for prefix in re.findall(r"\b(test_[A-Za-z0-9_]*)\*", span):
            if not any(t.startswith(prefix) for t in tests):
                failures.append(f"{doc}: no test starts with '{prefix}'  (from `{prefix}*`)")
        # A bare, fully-spelled citation.
        for name in re.findall(r"\b(test_[A-Za-z0-9_]+)\b(?!\*)", span):
            if name not in tests and not any(t.startswith(name) for t in tests):
                failures.append(f"{doc}: cited test does not exist: {name}")
    return failures


def main() -> int:
    tests = existing_tests()
    if not tests:
        print("FAIL: found no test functions at all — is the tree intact?")
        return 1

    docs = [Path(a) for a in sys.argv[1:]] or sorted((ROOT / "docs").glob("*.md"))
    failures = [f for d in docs for f in check(d, tests)]

    print(f"{len(tests)} test functions in tree; checked {len(docs)} docs")
    if failures:
        print(f"\n{len(failures)} stale citation(s):\n")
        for f in failures:
            print("  " + f)
        return 1
    print("all doc-to-test citations resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
