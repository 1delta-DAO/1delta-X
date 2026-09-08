// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {ExactlyPreFundModule} from "../../src/ExactlyPreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {IExactlyMarket, IExactlyAuditor} from "../../src/interfaces/IExactly.sol";

/// @title ExactlyPreFundOneSidedTest
/// @notice Optimism-mainnet fork validation of the PRE-FUNDED one-sided
///         modules against the live MarketUSDC — "deposit / repay whatever the
///         conversion delivered", funded from the MODULE's own balance, never a
///         `permit3.transferFrom`.
///
///  Driven exactly like the package's Leverage suite drives its taker legs:
///  through Permit3's taker book (`approveTaker` + `takeFor`) with a pranked
///  settlement spender — the delivered output leg is simulated by dealing the
///  asset to the module first, which is precisely the state Settlement's
///  module-addressed `legsOut[j]` delivery produces. The core's sizing of
///  `forAmount` to that delivery is core territory (proven in the aave-v3
///  PreFundOneSided suite); what THIS file pins is the venue fund-flow, the caps,
///  the sweeps, and the zero-receive-side-approval claim on real Exactly.
contract ExactlyPreFundOneSidedTest is Test {
    ExactlyPreFundModule preFund;
    // ── deployed Exactly suite on Optimism (same pins as Leverage.t.sol) ──
    address internal constant AUDITOR = 0xaEb62e6F27BC103702E7BC879AE98bceA56f027E;
    address internal constant MARKET_USDC = 0x6926B434CCe9b5b7966aE1BfEef6D0A7DCF3A8bb; // exaUSDC (native)
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // native USDC

    uint256 internal constant FORK_BLOCK = 154_900_000;
    uint256 internal constant FIXED_INTERVAL = 4 weeks; // Exactly's maturity grid

    uint256 internal constant COLLATERAL = 10_000e6;
    uint256 internal constant DEBT = 1_000e6;
    uint256 internal constant DELIVERED = 1_200e6;

    Permit3 internal permit3;

    address internal maker;
    address internal settlement = address(0x5E77);

    // ──────────────── fork plumbing (Leverage.t.sol pattern) ────────────────

    function _forkOptimism() internal {
        try vm.envString("OPTIMISM_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        string[3] memory rpcs = ["https://mainnet.optimism.io", "https://optimism.drpc.org", "https://1rpc.io/op"];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryFork(rpcs[i])) return;
        }
        revert("ExactlyPreFundOneSided: no archive-capable Optimism RPC (set OPTIMISM_RPC_URL)");
    }

    function _tryFork(string memory rpc) internal returns (bool) {
        try this.__fork(rpc) {
            return true;
        } catch {
            return false;
        }
    }

    function __fork(string calldata rpc) external {
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    // ──────────────── setup ────────────────

    function setUp() public {
        _forkOptimism();

        maker = makeAddr("exactly-pre-fund-maker");

        permit3 = new Permit3();
        preFund = new ExactlyPreFundModule(address(permit3), address(settlement));

        vm.label(MARKET_USDC, "MarketUSDC");
        vm.label(USDC, "USDC");
        vm.label(AUDITOR, "Auditor");
        }

    // ──────────────── helpers ────────────────

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev Same leg reference, with the op in descriptor bits [244,252).
    function _forLegOp(uint256 index, address token, ExactlyPreFundModule.Op op) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(op) << 244);
    }

    function _depositData(uint256 maturity, uint256 minAssetsRequired) internal pure returns (bytes memory) {
        return abi.encode(_forLeg(0, USDC), MARKET_USDC, USDC, maturity, minAssetsRequired);
    }

    /// @dev The trailing word is the funding leg's FULL amount — the denominator
    ///      this fill's `forAmount` is a slice of. The fixed branch scales the
    ///      signed face with it (F27/H-3).
    function _repayData(uint256 maturity, uint256 positionAssets, uint256 totalForAmount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_forLegOp(0, USDC, ExactlyPreFundModule.Op.Repay), MARKET_USDC, USDC, maturity, positionAssets, totalForAmount);
    }

    /// @dev Drive a pre-funded MAKE the way Settlement would: the delivered leg already
    ///      sits on the module and Settlement calls it DIRECTLY with the
    ///      delivery-sized amount the core computed. No taker grant and no Permit3
    ///      hop — nothing leaves the position, so neither exists on this seam.
    function _takeFor(address module, bytes memory data, uint256 forAmount) internal {
        vm.prank(settlement);
        IMakerModule(module).makeOnBehalf(maker, forAmount, data);
    }

    /// @dev Maker's own venue interactions: seed collateral + debt so a repay
    ///      has something to retire. Direct calls, no module involved.
    function _seedDebt(uint256 maturity, uint256 face) internal returns (uint256 owed) {
        deal(USDC, maker, COLLATERAL);
        vm.startPrank(maker);
        IERC20(USDC).approve(MARKET_USDC, COLLATERAL);
        IExactlyMarket(MARKET_USDC).deposit(COLLATERAL, maker);
        IExactlyAuditor(AUDITOR).enterMarket(MARKET_USDC);
        if (maturity == 0) {
            IExactlyMarket(MARKET_USDC).borrow(face, maker, maker);
            owed = face;
        } else {
            owed = IExactlyMarket(MARKET_USDC).borrowAtMaturity(maturity, face, type(uint256).max, maker, maker);
        }
        // The drawn cash is irrelevant to the repay-side assertions; park it so
        // the maker's wallet delta below is exactly the swept surplus.
        IERC20(USDC).transfer(address(0xD0), face);
        vm.stopPrank();
    }

    /// Next 4-week boundary after the fork timestamp — the closest live fixed pool.
    function _nextMaturity() internal view returns (uint256) {
        return block.timestamp - (block.timestamp % FIXED_INTERVAL) + FIXED_INTERVAL;
    }

    /// @dev The receive-side claim, asserted not just unused: the maker granted
    ///      NOTHING on the delivered asset — no ERC20 approval to Permit3, no
    ///      Permit3 token-book entry to the module.
    function _assertReceiveSideEmpty(address module) internal view {
        assertEq(IERC20(USDC).allowance(maker, address(permit3)), 0, "no ERC20 approval to Permit3");
        (uint160 amt,) = permit3.tokenAllowance(maker, module, USDC);
        assertEq(amt, 0, "no Permit3 token-book entry to the module");
    }

    // ──────────────── deposit ────────────────

    /// Floating: the delivered leg becomes the maker's floating deposit, from
    /// the module's own balance — the maker approved nothing on USDC.
    function test_preFundDeposit_floating_fundsFromModuleBalance() public {
        bytes memory data = _depositData(0, 0);
        deal(USDC, address(preFund), DELIVERED); //  the delivered output leg
        _assertReceiveSideEmpty(address(preFund));

        _takeFor(address(preFund), data, DELIVERED);

        assertGt(IERC20(MARKET_USDC).balanceOf(maker), 0, "maker holds the exaUSDC shares");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).maxWithdraw(maker), DELIVERED, 2, "position ~= delivery");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(USDC).allowance(address(preFund), MARKET_USDC), 0, "venue approval cleared");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "nothing transited the maker's wallet");
    }

    /// Fixed: `depositAtMaturity` at the next live pool, floor-guarded by the
    /// maker-signed `minAssetsRequired` (position = assets + fee ≥ assets).
    function test_preFundDeposit_fixed_depositAtMaturity() public {
        uint256 maturity = _nextMaturity();
        bytes memory data = _depositData(maturity, DELIVERED); //  floor = the delivery itself
        deal(USDC, address(preFund), DELIVERED);

        uint256 marketBefore = IERC20(USDC).balanceOf(MARKET_USDC);

        _takeFor(address(preFund), data, DELIVERED);

        assertEq(IERC20(USDC).balanceOf(MARKET_USDC) - marketBefore, DELIVERED, "assets entered the market");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(USDC).allowance(address(preFund), MARKET_USDC), 0, "venue approval cleared");
    }

    // ──────────────── repay ────────────────

    /// Floating: cap at the LIVE debt (`previewDebt`) and sweep the delivered
    /// surplus to the maker — it is theirs, not the singleton's.
    function test_preFundRepay_floating_capsAtDebt_andSweepsSurplus() public {
        _seedDebt(0, DEBT);
        bytes memory data = _repayData(0, 0, 0);
        deal(USDC, address(preFund), DELIVERED); //  overshoots the 1,000 debt
        _assertReceiveSideEmpty(address(preFund));

        _takeFor(address(preFund), data, DELIVERED);

        assertEq(IExactlyMarket(MARKET_USDC).previewDebt(maker), 0, "the debt is retired in full");
        // ±1 wei: `previewDebt` rounds the live debt UP (borrow-share math), so
        // retiring it in full can cost one wei above the borrowed face.
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), DELIVERED - DEBT, 1, "the surplus was swept to the maker");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(USDC).allowance(address(preFund), MARKET_USDC), 0, "venue approval cleared");
    }

    /// Fixed: the signed face (`positionAssets`) against the delivered budget
    /// (`maxAssets = forAmount`). Pre-maturity the market takes the DISCOUNTED
    /// assets, so the sweep is the early-repay discount plus the over-delivery.
    function test_preFundRepay_fixed_faceAgainstBudget_sweepsUnspent() public {
        uint256 maturity = _nextMaturity();
        uint256 owed = _seedDebt(maturity, DEBT); //  face + fixed-pool fee
        uint256 budget = owed + 50e6;
        // Full fill: `forAmount == totalForAmount`, so the face is unscaled.
        bytes memory data = _repayData(maturity, owed, budget);
        deal(USDC, address(preFund), budget);

        _takeFor(address(preFund), data, budget);

        assertEq(IExactlyMarket(MARKET_USDC).previewDebt(maker), 0, "the fixed position is closed");
        assertGe(IERC20(USDC).balanceOf(maker), 50e6, "over-delivery (+ any discount) swept to the maker");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(USDC).allowance(address(preFund), MARKET_USDC), 0, "venue approval cleared");
    }

    /// Fixed, fail-closed: a FULL fill whose budget cannot cover the signed face
    /// reverts inside Exactly (`Disagreement` against the budget) rather than
    /// half-retiring the position. `totalForAmount == forAmount` here, so the face
    /// is unscaled and this is genuinely an under-funded order rather than a slice
    /// of a larger one — the distinction F27/H-3 introduced.
    function test_preFundRepay_fixed_underDelivery_failsClosed() public {
        uint256 maturity = _nextMaturity();
        uint256 owed = _seedDebt(maturity, DEBT);
        uint256 short = owed / 2;
        bytes memory data = _repayData(maturity, owed, short);
        deal(USDC, address(preFund), short);

        vm.prank(settlement);
        vm.expectRevert(); // Exactly: Disagreement (actualRepay > maxAssets budget)
        preFund.makeOnBehalf(maker, short, data);
    }

    /// @notice F27/H-3 regression. `positionAssets` is an ABSOLUTE maker-signed
    ///         face; `forAmount` is this fill's slice of the funding leg. The pull
    ///         sibling scales for free (its face IS the pro-rated item amount), the
    ///         pre-fund shape has no such number, so the face rode UNSCALED and every
    ///         slice presented the whole position.
    ///
    ///         The damage needs the early-repay discount: pre-maturity the market
    ///         charges less than face, so the full face's `actualRepayAssets` can
    ///         fall under a PARTIAL slice's budget — the first slice then retires
    ///         100% of the position and every later slice re-presents the same face
    ///         against an empty one.
    ///
    ///         Two half-slices of one order. Against the pre-fix code the first
    ///         call closes the whole position; with the face scaled, each slice
    ///         retires its own share and the position survives to the second.
    function test_preFundRepay_fixed_partialSlices_scaleTheFace() public {
        uint256 maturity = _nextMaturity();
        uint256 owed = _seedDebt(maturity, DEBT);
        uint256 total = owed + 50e6;
        uint256 slice = total / 2;
        bytes memory data = _repayData(maturity, owed, total);

        deal(USDC, address(preFund), slice);
        _takeFor(address(preFund), data, slice);

        // The defect: one half-slice must NOT have retired the whole position.
        assertGt(IExactlyMarket(MARKET_USDC).previewDebt(maker), 0, "first slice closed the whole position");

        deal(USDC, address(preFund), total - slice);
        _takeFor(address(preFund), data, total - slice);

        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
    }
}
