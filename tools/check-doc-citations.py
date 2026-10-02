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

Second pass — MODULE READMEs NAME REAL CONTRACTS. Each `packages/modules/**/README.md`
is checked so that every `SomethingModule` token it mentions is declared in that
package's `src/`. This is the doc-side twin of the test check: three READMEs
(liquity-v2, river, morpho-blue) were found on 2026-09-11 still describing
contracts — and in two cases a SEAM — that an earlier merge had folded away,
with tables that a reader would take as the wire layout. A README that names a
contract which does not compile is a promise the package no longer keeps.

Designs that are documented but deliberately unbuilt, and historical names a
README keeps on purpose, are listed in `README_NAME_OK` with the reason; the
README itself must also say so.

Third pass — LAYOUT OFFSETS IN DOCS MATCH THE CODE (audit 2026-09-30 L-CENSUS-4 /
L-CENSUS-7 / L-LIB-6). Module READMEs and `docs/gasless-permit-relay.md` are the
encoder spec integrators actually read (the SDK ships few builders), and both had
drifted from the code by whole words: a README put a `BalanceMode` at 160 where the
code reads it at 192, and the relay doc put every signature tail one word early. In
a table row naming a module (first backticked `…Module` / `…Callback`), every `@N`
offset must be an offset that contract's code reads (`replay*(data, N` /
`readBalanceMode(data, N` / `data[N:` …) or that its header byte map — itself held
to the code by shapes rule 9b — names. In the relay doc the rule is stricter: an
`@N` must be an offset at which that contract replays a signature.

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


# Contract names a module README may mention WITHOUT them existing in any src/.
# Two legitimate reasons, each of which the README must ALSO say in prose:
#   • a documented design that is deliberately unbuilt ("NOT yet implemented");
#   • a HISTORICAL name — a contract the README explains was replaced, kept so the
#     audit reasoning behind its successor stays legible.
# Keep the reason on every row. A name that is neither is drift, and the fix is
# the README, not this table.
README_NAME_OK = {
    "fluid": {
        "FluidSmartDepositModule",
        "FluidSmartOperateModule",
        "FluidSmartTakeForModule",
        "FluidSmartTakerModule",
    },  # "Smart vaults T2 / T3 / T4 — design (NOT yet implemented)" section
    "bridge": {"GenericCallModule"},  # historical: "the old GenericCallModule … reduced to PermissionlessCallModule"
    "maker": {"GenericCallModule"},  # historical: "its predecessor GenericCallModule" (2026-08 audit)
}

MODULE_NAME = re.compile(r"\b[A-Z][A-Za-z0-9]+Module\b")
# Any declared type a README might name: contracts, interfaces, libraries.
CONTRACT_DECL = re.compile(r"^\s*(?:abstract\s+contract|contract|interface|library)\s+(\w+)", re.M)


_ALL_DECLARED: set[str] | None = None


def _all_declared() -> set[str]:
    global _ALL_DECLARED
    if _ALL_DECLARED is None:
        _ALL_DECLARED = set()
        # src/ for real contracts, test/ for the mocks a README may legitimately
        # point at ("core's dispatch tests run against `ProgressBumpModule`").
        for pat in ("src/**/*.sol", "test/**/*.sol"):
            for o in (ROOT / "packages").rglob(pat):
                if "node_modules" in str(o) or "/out/" in str(o):
                    continue
                _ALL_DECLARED |= set(CONTRACT_DECL.findall(o.read_text(encoding="utf-8")))
    return _ALL_DECLARED


def check_module_readmes() -> tuple[int, list[str]]:
    """Every `*Module` a package README names must be declared in that package's src/."""
    failures = []
    readmes = sorted((ROOT / "packages" / "modules").rglob("README.md"))
    for readme in readmes:
        pkg = readme.parent
        src = pkg / "src"
        if not src.is_dir():
            continue
        declared = set()
        for sol in src.rglob("*.sol"):
            declared |= set(CONTRACT_DECL.findall(sol.read_text(encoding="utf-8")))
        ok_unbuilt = README_NAME_OK.get(pkg.name, set())
        for name in sorted(set(MODULE_NAME.findall(readme.read_text(encoding="utf-8")))):
            if name in declared or name in ok_unbuilt:
                continue
            # A name from ANOTHER package's src (core interfaces, a sibling venue) is a
            # cross-reference, not drift.
            if name in _all_declared():
                continue
            failures.append(f"{readme.relative_to(ROOT)}: names `{name}`, not declared in {src.relative_to(ROOT)}/")
    return len(readmes), failures


_SHAPES = None


def _shapes():
    global _SHAPES
    if _SHAPES is None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("shapes", ROOT / "tools" / "check-module-shapes.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _SHAPES = mod
    return _SHAPES


REPLAY_OFFSET = re.compile(r"\breplay\w*\(\s*data\s*,\s*([^,]+),")
NUM = re.compile(r"(?<![0-9A-Za-z_])(\d{2,3})(?![0-9])")


def contract_offsets() -> dict:
    """{contract: (all offsets the code reads or the header names, replay offsets)}."""
    shapes = _shapes()
    out = {}
    for sol in (ROOT / "packages").rglob("src/**/*.sol"):
        if "node_modules" in str(sol):
            continue
        src = sol.read_text(encoding="utf-8")
        code = shapes.strip_comments(src)
        for name, _inh, body, header in shapes.contract_spans(code, src):
            used = set()
            for a, b in shapes.DATA_OFFSET_READ.findall(body):
                used.update(int(x) for x in NUM.findall(a or b))
            replay = set()
            for m in REPLAY_OFFSET.finditer(body):
                replay.update(int(x) for x in NUM.findall(m.group(1)))
            named = set(int(x) for x in NUM.findall(header))
            prev = out.get(name, (set(), set()))
            out[name] = (prev[0] | used | replay | named, prev[1] | replay)
    return out


SUBJECT = re.compile(r"`([A-Z][A-Za-z0-9]+(?:Module|Callback))`")
AT_OFFSET = re.compile(r"@\s*(\d{2,3})(?![0-9])")


def check_layout_offsets() -> list[str]:
    offsets = contract_offsets()
    failures = []
    targets = [(r, False) for r in sorted((ROOT / "packages" / "modules").rglob("README.md"))]
    targets.append((ROOT / "docs" / "gasless-permit-relay.md", True))
    for doc, replay_only in targets:
        if not doc.exists():
            continue
        for ln, line in enumerate(doc.read_text(encoding="utf-8").splitlines(), 1):
            if not line.lstrip().startswith("|"):
                continue
            m = SUBJECT.search(line)
            if not m or m.group(1) not in offsets:
                continue
            allowed, replay = offsets[m.group(1)]
            pool = replay if replay_only else allowed
            for n in (int(x) for x in AT_OFFSET.findall(line)):
                if n not in pool:
                    kind = "replays no signature at" if replay_only else "neither reads nor documents"
                    failures.append(f"{doc.relative_to(ROOT)}:{ln}: `{m.group(1)}` {kind} offset {n}")
    return failures


def main() -> int:
    tests = existing_tests()
    if not tests:
        print("FAIL: found no test functions at all — is the tree intact?")
        return 1

    docs = [Path(a) for a in sys.argv[1:]] or (
        sorted((ROOT / "docs").glob("*.md"))
        + sorted((ROOT / "docs" / "reference-audits").glob("*.md"))
    )
    failures = [f for d in docs for f in check(d, tests)]

    n_readmes, readme_failures = check_module_readmes()
    layout_failures = check_layout_offsets()

    print(f"{len(tests)} test functions in tree; checked {len(docs)} docs, {n_readmes} module READMEs")
    if failures:
        print(f"\n{len(failures)} stale citation(s):\n")
        for f in failures:
            print("  " + f)
    if readme_failures:
        print(f"\n{len(readme_failures)} module README(s) name a contract that does not exist:\n")
        for f in readme_failures:
            print("  " + f)
        print("\nEither the README is stale (a merge or rename folded the contract away — fix the\n"
              "table, and check whether the SEAM it documents moved too), or it documents an\n"
              "unbuilt design or a deliberately-kept historical name: say so in the README\n"
              "and add the name to README_NAME_OK with the reason.")
    if layout_failures:
        print(f"\n{len(layout_failures)} documented layout offset(s) do not match the code:\n")
        for f in layout_failures:
            print("  " + f)
        print("\nThe README / relay-doc row is an encoder spec. Re-derive the offset from the\n"
              "contract (its header byte map is held to the code by shapes rule 9b).")
    if failures or readme_failures or layout_failures:
        return 1
    print("all doc-to-test citations resolve; all module README contract names exist; documented layout offsets match the code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
