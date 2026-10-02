#!/usr/bin/env python3
"""Self-test for tools/check-module-shapes.py: each rule added by the 2026-09-30 audit
remediation must FIRE on a minimal offender and stay quiet on the compliant form.

Runs the checker against a throwaway tree (ROOT is repointed at a temp dir), so it
never touches the real sources. Wired into `make modules-check`.
"""

import importlib.util
import io
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("shapes", HERE / "check-module-shapes.py")
shapes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shapes)


def run(files: dict) -> tuple[int, str]:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        for rel, src in files.items():
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(src)
        shapes.ROOT = root
        err = io.StringIO()
        with redirect_stdout(io.StringIO()), redirect_stderr(err):
            code = shapes.main()
        return code, err.getvalue()


CASES = []


def case(name, files, expect_fail, needle=""):
    CASES.append((name, files, expect_fail, needle))


# (10) X-SPEC-1 — a SETTLE module pulling from the filler.
case(
    "X-SPEC-1 filler pull fires",
    {"packages/m/src/Bad.sol": """
contract BadSettle {
    function settle(address maker, address filler, uint256 amount, bytes calldata data) external {
        IERC721(c).transferFrom(filler, maker, amount);
    }
}"""},
    True,
    "pull FROM the filler",
)
case(
    "X-SPEC-1 maker->filler is fine",
    {"packages/m/src/Ok.sol": """
contract OkSettle {
    function settle(address maker, address filler, uint256 amount, bytes calldata data) external {
        IERC20(t).transferFrom(maker, filler, amount);
    }
}"""},
    False,
)

# (11) X-ARITH-3 — an unscaled data amount without FullFillGuard.
case(
    "X-ARITH-3 unscaled settle fires",
    {"packages/m/src/Bad.sol": """
contract BadUnscaled {
    function settle(address maker, address filler, uint256, bytes calldata data) external {
        (address t, uint256 qty) = abi.decode(data, (address, uint256));
        IERC20(t).transferFrom(maker, filler, qty);
    }
}"""},
    True,
    "unscaled data amount",
)
case(
    "X-ARITH-3 guarded settle is fine",
    {"packages/m/src/Ok.sol": """
contract OkUnscaled {
    function settle(address maker, address filler, uint256 amount, bytes calldata data) external {
        (address t, uint256 qty) = abi.decode(data, (address, uint256));
        FullFillGuard.requireFullFill(amount, qty);
        IERC20(t).transferFrom(maker, filler, qty);
    }
}"""},
    False,
)

# (12) X-STATIC-1.v1 — an approval clear behind an early return.
case(
    "X-STATIC-1.v1 clear behind early return fires",
    {"packages/m/src/Bad.sol": """
contract BadClear {
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external {
        if (msg.sender != settlement) revert NotSettlement();
        (address venue, address t) = abi.decode(data, (address, address));
        SafeTransferLib.forceApprove(t, venue, amount);
        IVenue(venue).supply(amount);
        if (bal <= floor) return;
        SafeTransferLib.forceApprove(t, venue, 0);
    }
}"""},
    True,
    "behind an early return",
)

# (13) L-LRG-4c — a stale pre-fund header.
case(
    "L-LRG-4c stale pre-fund header fires",
    {"packages/m/src/XPreFundModules.sol": """
// the maker signs a `TAKE_FOR` item whose leg-reference descriptor points here,
// and the taker allowance below.
contract XPreFundModule {
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external {
        _gatePreFundMake(data);
    }
}"""},
    True,
    "retired TAKE_FOR shape",
)

# (9) extended, L-CV2-1.v2 — requireFullFill + min-forward without requireDelivered.
case(
    "L-CV2-1.v2 requireFullFill + cap without bound fires",
    {"packages/m/src/Bad.sol": """
contract BadBorrow {
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        (address t, uint256 total) = abi.decode(data, (address, uint256));
        FullFillGuard.requireFullFill(amount, total);
        SafeTransferLib.safeTransfer(t, receiver, received < amount ? received : amount);
    }
}"""},
    True,
    "requireFullFill + min-forward",
)

# (9) extended, L-CV2-1 — a clamping venue's Exact branch without the bound.
case(
    "L-CV2-1 clamping venue without bound fires",
    {"packages/m/src/Bad.sol": """
contract AaveV4WithdrawModule {
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        IPM(pm).withdrawOnBehalfOf(spoke, id, amount, onBehalfOf);
    }
}"""},
    True,
    "clamping venue",
)


def main() -> int:
    bad = 0
    for name, files, expect_fail, needle in CASES:
        code, err = run(files)
        ok = (code != 0) == expect_fail and (not needle or needle in err)
        print(("ok   " if ok else "FAIL ") + name)
        if not ok:
            bad += 1
            print(err, file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
