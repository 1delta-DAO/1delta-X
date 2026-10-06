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

# L-CENSUS-7 — comments are stripped before matching: a pin that exists only in a
# comment no longer satisfies rule 2.
case(
    "L-CENSUS-7 commented-out pin fires",
    {"packages/modules/m/src/Bad.sol": """
contract BadMaker {
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external {
        // if (msg.sender != settlement) revert NotSettlement();
        (address venue) = abi.decode(data, (address));
    }
}"""},
    True,
    "do NOT pin their dispatcher",
)
case(
    "L-CENSUS-7 real pin passes",
    {"packages/modules/m/src/Ok.sol": """
contract OkMaker {
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external {
        if (msg.sender != settlement) revert NotSettlement();
        (address venue) = abi.decode(data, (address));
    }
}"""},
    False,
)

# (14) L-CENSUS-7a — a non-zero approval never cleared on the entrypoint's path.
case(
    "L-CENSUS-7a uncleared approval fires",
    {"packages/modules/m/src/Bad.sol": """
contract BadApprove {
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external {
        if (msg.sender != settlement) revert NotSettlement();
        (address venue, address t) = abi.decode(data, (address, address));
        SafeTransferLib.forceApprove(t, venue, amount);
        IVenue(venue).supply(t, amount, onBehalfOf);
    }
}"""},
    True,
    "never cleared",
)
case(
    "L-CENSUS-7a clear in a reached helper passes",
    {"packages/modules/m/src/Ok.sol": """
contract OkApprove {
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external {
        if (msg.sender != settlement) revert NotSettlement();
        (address venue, address t) = abi.decode(data, (address, address));
        SafeTransferLib.forceApprove(t, venue, amount);
        IVenue(venue).supply(t, amount, onBehalfOf);
        _clear(t, venue);
    }
    function _clear(address token, address v) private {
        SafeTransferLib.forceApprove(token, v, 0);
    }
}"""},
    False,
)

# (15) L-CENSUS-7a — a standing ensureApproval toward an order-decoded spender.
case(
    "L-CENSUS-7a ensureApproval to a decoded spender fires",
    {"packages/modules/m/src/Bad.sol": """
contract BadEnsure {
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external {
        if (msg.sender != settlement) revert NotSettlement();
        (address venue, address t) = abi.decode(data, (address, address));
        SafeTransferLib.ensureApproval(t, venue, amount);
        IVenue(venue).supply(t, amount, onBehalfOf);
    }
}"""},
    True,
    "outside the allow-list",
)

# (16) L-CENSUS-7b — a TAKE-measured token taken from data and never bound.
case(
    "L-CENSUS-7b unbound measured token fires",
    {"packages/modules/m/src/Bad.sol": """
contract BadMeasure {
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        (address vault, address token) = abi.decode(data, (address, address));
        uint256 floor = IERC20(token).balanceOf(address(this));
        IVault(vault).redeemFor(amount, onBehalfOf);
        uint256 received = IERC20(token).balanceOf(address(this)) - floor;
        FullFillGuard.requireDelivered(received, amount);
        SafeTransferLib.safeTransfer(token, receiver, received);
    }
}"""},
    True,
    "not bound to the venue",
)
case(
    "L-CENSUS-7b venue-derived token passes",
    {"packages/modules/m/src/Ok.sol": """
contract OkMeasure {
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        (address vault) = abi.decode(data, (address));
        address token = IVault(vault).asset();
        uint256 floor = IERC20(token).balanceOf(address(this));
        IVault(vault).redeemFor(amount, onBehalfOf);
        uint256 received = IERC20(token).balanceOf(address(this)) - floor;
        FullFillGuard.requireDelivered(received, amount);
        SafeTransferLib.safeTransfer(token, receiver, received);
    }
}"""},
    False,
)

# (13) L-CENSUS-6 — keyed on the pre-fund shape, not the file name.
case(
    "L-CENSUS-6 stale pre-fund header outside a *PreFundModules.sol file fires",
    {"packages/m/src/XBrokerModule.sol": """
// the maker signs a `TAKE_FOR` item whose leg-reference descriptor points here.
contract XBrokerModule {
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external {
        _gatePreFundMake(data);
    }
}"""},
    True,
    "retired TAKE_FOR shape",
)

# (9) per `op` branch, review 2026-10-06 M2 — the Venus shape: the Withdraw branch
# carries the bound, the Borrow branch measures and caps but does not. The
# whole-function search let the sibling vouch for it.
_LADDER = """
contract XTakerModule {
    enum Op { Borrow, Withdraw }
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        (uint8 op, address v, address t) = abi.decode(data, (uint8, address, address));
        if (op == uint8(Op.Borrow)) {
            uint256 balBefore = IERC20(t).balanceOf(address(this));
            IV(v).borrowBehalf(onBehalfOf, amount);
            uint256 received = IERC20(t).balanceOf(address(this)) - balBefore;
            %BORROW_BOUND%
            t.safeTransfer(receiver, received < amount ? received : amount);
        } else if (op == uint8(Op.Withdraw)) {
            _withdraw(onBehalfOf, amount, receiver, v, t);
        } else {
            revert BadOp(op);
        }
    }
    function _withdraw(address onBehalfOf, uint256 amount, address receiver, address v, address t) private {
        uint256 balBefore = IERC20(t).balanceOf(address(this));
        IV(v).redeemUnderlyingBehalf(onBehalfOf, amount);
        uint256 received = IERC20(t).balanceOf(address(this)) - balBefore;
        FullFillGuard.requireDelivered(received, amount);
        t.safeTransfer(receiver, received < amount ? received : amount);
    }
}"""
case(
    "M2 per-branch: bounded sibling does not cover the unbounded branch",
    {"packages/m/src/Bad.sol": _LADDER.replace("%BORROW_BOUND%", "")},
    True,
    "op branch `Borrow`",
)
case(
    "M2 per-branch: every measured branch bounded passes",
    {"packages/m/src/Ok.sol": _LADDER.replace("%BORROW_BOUND%", "FullFillGuard.requireDelivered(received, amount);")},
    False,
)
case(
    "M2 per-branch: a hand-rolled `< amount` revert is the bound",
    {"packages/m/src/Ok.sol": _LADDER.replace("%BORROW_BOUND%", "if (received < amount) revert Short(received, amount);")},
    False,
)
# A single-op module on a venue verified exact-or-revert passes by its allow-list
# row; the identical body under a name with no row fires.
_SINGLE = """
contract %NAME% {
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        (address spoke, address pm, uint256 id, address asset) = abi.decode(data, (address, address, uint256, address));
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        IPM(pm).borrowOnBehalfOf(spoke, id, amount, onBehalfOf);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
        SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
    }
}"""
case(
    "M2 venue-exact allow-list row passes (AaveV4BorrowModule)",
    {"packages/m/src/Ok.sol": _SINGLE.replace("%NAME%", "AaveV4BorrowModule")},
    False,
)
case(
    "M2 same single-op body without an allow-list row fires",
    {"packages/m/src/Bad.sol": _SINGLE.replace("%NAME%", "SomeBorrowModule")},
    True,
    "op branch `takeOnBehalf`",
)

# (17) review 2026-10-06 M3 — a taker whose `amount` is in another unit than the
# proceeds must implement IProceedsAsset and name both units in its header.
_SMART = """
// Burns `amount` LP units and pays ONE pool coin to `receiver`.
contract ListaSmartTakerModule is ITakerModule%IFACE% {
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        (address provider, uint256 i, uint256 minOutRate) = abi.decode(data, (address, uint256, uint256));
        IProvider(provider).withdrawCollateralOneCoin(amount, i, amount * minOutRate / 1e18, onBehalfOf, receiver);
    }
%FN%
}"""
_PROCEEDS_FN = "    function proceedsAsset(bytes calldata data) external view returns (address) { return coin; }"
case(
    "M3 unit-converting taker without IProceedsAsset fires",
    {"packages/m/src/Bad.sol": _SMART.replace("%IFACE%", "").replace("%FN%", "")},
    True,
    "does not implement IProceedsAsset",
)
case(
    "M3 unit-converting taker with IProceedsAsset + both units in header passes",
    {"packages/m/src/Ok.sol": _SMART.replace("%IFACE%", ", IProceedsAsset").replace("%FN%", _PROCEEDS_FN)},
    False,
)
case(
    "M3 header that does not name the proceeds unit fires",
    {"packages/m/src/Bad.sol": _SMART.replace("%IFACE%", ", IProceedsAsset").replace("%FN%", _PROCEEDS_FN)
        .replace("pays ONE pool coin", "pays the output")},
    True,
    "missing unit(s) coin",
)
case(
    "M3 rate-scaled `amount` floor in an unregistered taker fires",
    {"packages/m/src/Bad.sol": _SMART.replace("ListaSmartTakerModule", "OtherLpTakerModule")
        .replace("%IFACE%", ", IProceedsAsset").replace("%FN%", _PROCEEDS_FN)},
    True,
    "UNIT_CONVERTING_TAKERS",
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
