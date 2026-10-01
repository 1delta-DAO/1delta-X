// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {ExactlyDepositModule, ExactlyRepayModule} from "../../src/ExactlyModules.sol";
import {ExactlyPreFundModule} from "../../src/ExactlyPreFundModules.sol";
import {IExactlyMarket, IExactlyAuditor} from "../../src/interfaces/IExactly.sol";

interface IERC2612Like {
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title ExactlyRepayAndPreFundRegressionsTest
/// @notice 2026-09-30 audit regressions on the LIVE exaUSDC Market (Optimism fork):
///
///   • L-FSE-4  — the fixed-branch repay's EIP-2612 tail now carries an explicit
///                `value`, so a gasless POST-MATURITY repay (where `maxAssets` must
///                exceed the face to cover Exactly's late penalty) settles instead
///                of reverting at Permit3's pull.
///   • L-FSE-2 / X-ARITH-5 — the pre-fund fixed repay clamps the presented face to
///                the live fixed position and skips an empty one, so a slice that
///                over-retired (auctioned leg, or a too-small signed total) no longer
///                bricks every later slice of the order.
///   • L-FSE-6  — first live coverage of the pull `depositAtMaturity`, the pull
///                fixed repay, and `DustAction.Recycle` on Exactly.
contract ExactlyRepayAndPreFundRegressionsTest is Test {
    address internal constant AUDITOR = 0xaEb62e6F27BC103702E7BC879AE98bceA56f027E;
    address internal constant MARKET_USDC = 0x6926B434CCe9b5b7966aE1BfEef6D0A7DCF3A8bb;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    uint256 internal constant FORK_BLOCK = 154_900_000;
    uint256 internal constant FIXED_INTERVAL = 4 weeks;

    uint256 internal constant COLLATERAL = 10_000e6;
    uint256 internal constant DEBT = 1_000e6;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    Permit3 internal permit3;
    ExactlyDepositModule internal depositModule;
    ExactlyRepayModule internal repayModule;
    ExactlyPreFundModule internal preFund;

    address internal maker;
    uint256 internal makerKey;
    address internal settlement = address(0x5E77);

    function _forkOptimism() internal {
        try vm.envString("OPTIMISM_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        string[3] memory rpcs = ["https://mainnet.optimism.io", "https://optimism.drpc.org", "https://1rpc.io/op"];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryFork(rpcs[i])) return;
        }
        revert("ExactlyRepayAndPreFund: no archive-capable Optimism RPC (set OPTIMISM_RPC_URL)");
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

    function setUp() public {
        _forkOptimism();
        (maker, makerKey) = makeAddrAndKey("exactly-audit-maker");
        permit3 = new Permit3();
        depositModule = new ExactlyDepositModule(address(permit3), settlement);
        repayModule = new ExactlyRepayModule(address(permit3), settlement);
        preFund = new ExactlyPreFundModule(address(permit3), settlement);
    }

    // ──────────────── helpers ────────────────

    function _nextMaturity() internal view returns (uint256) {
        return block.timestamp - (block.timestamp % FIXED_INTERVAL) + FIXED_INTERVAL;
    }

    /// @dev Maker's own venue interactions: collateral + a debt to retire. The drawn
    ///      cash is parked away so wallet deltas below are exactly the repay's.
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
        IERC20(USDC).transfer(address(0xD0), face);
        IERC20(USDC).approve(MARKET_USDC, 0);
        vm.stopPrank();
    }

    function _fixedDebt(uint256 maturity) internal view returns (uint256) {
        (uint256 p, uint256 f) = IExactlyMarket(MARKET_USDC).fixedBorrowPositions(maturity, maker);
        return p + f;
    }

    function _permitSig(uint256 value, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, maker, address(permit3), value, IERC2612Like(USDC).nonces(maker), deadline)
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IERC2612Like(USDC).DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(makerKey, digest);
    }

    // ──────────────── L-FSE-4: gasless post-maturity fixed repay ────────────────

    /// @notice Post-maturity Exactly charges a late penalty, so `maxAssets` must sit
    ///         ABOVE the face. The maker grants NO standing ERC-20 approval — only the
    ///         EIP-2612 tail, now signed for the whole `maxAssets` ceiling. Before the
    ///         fix the tail was replayed with `value = amount` (the face) and the
    ///         module's pull of the scaled `maxAssets` reverted.
    function test_audit_L_FSE_4_gaslessFixedRepay_postMaturity_settles() public {
        uint256 maturity = _nextMaturity();
        uint256 owed = _seedDebt(maturity, DEBT);
        vm.warp(maturity + 3 days); // overdue: penalty accrues, cost > face
        uint256 maxAssets = (owed * 110) / 100;

        deal(USDC, maker, maxAssets);
        // The maker's Permit3 book entry for the module (not the ERC-20 approval —
        // that is what the permit tail supplies).
        vm.prank(maker);
        permit3.approveToken(address(repayModule), USDC, type(uint160).max, 0);
        assertEq(IERC20(USDC).allowance(maker, address(permit3)), 0, "no standing ERC-20 approval");

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(maxAssets, deadline);
        bytes memory data = abi.encode(
            MARKET_USDC,
            USDC,
            maturity,
            maxAssets,
            uint256(DustHandler.DustAction.SweepToUser),
            owed, //       totalAmount — a full fill
            maxAssets, //  explicit permit value
            deadline,
            v,
            r,
            s
        );

        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, owed, data);

        assertEq(_fixedDebt(maturity), 0, "overdue fixed position closed");
        uint256 spent = maxAssets - IERC20(USDC).balanceOf(maker);
        assertGt(spent, owed, "post-maturity cost exceeded the face (penalty)");
        assertLe(spent, maxAssets, "never above the signed ceiling");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
        assertEq(IERC20(USDC).allowance(address(repayModule), MARKET_USDC), 0, "market grant cleared");
    }

    // ──────────────── L-FSE-6: live coverage of the untested pull branches ────────────────

    /// @notice Pull `depositAtMaturity` (only the pre-fund twin had live coverage).
    function test_audit_L_FSE_6_pullDepositAtMaturity_live() public {
        uint256 maturity = _nextMaturity();
        uint256 amount = 2_000e6;
        deal(USDC, maker, amount);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), USDC, type(uint160).max, 0);
        vm.stopPrank();

        vm.prank(settlement);
        depositModule.makeOnBehalf(maker, amount, abi.encode(MARKET_USDC, USDC, maturity, amount));

        (uint256 principal, uint256 fee) = IExactlyMarket(MARKET_USDC).fixedDepositPositions(maturity, maker);
        assertEq(principal, amount, "fixed deposit credited to the maker");
        assertGe(principal + fee, amount, "position >= the signed floor");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "pulled from the maker");
        assertEq(IERC20(USDC).balanceOf(address(depositModule)), 0, "module drained");
        assertEq(IERC20(USDC).allowance(address(depositModule), MARKET_USDC), 0, "grant cleared");
    }

    /// @notice Pull fixed repay BEFORE maturity with a standing approval — the early
    ///         repay discount makes the cost <= face, and the unspent ceiling is swept.
    function test_audit_L_FSE_6_pullFixedRepay_preMaturity_live() public {
        uint256 maturity = _nextMaturity();
        uint256 owed = _seedDebt(maturity, DEBT);
        uint256 maxAssets = owed;
        deal(USDC, maker, maxAssets);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, type(uint160).max, 0);
        vm.stopPrank();

        bytes memory data =
            abi.encode(MARKET_USDC, USDC, maturity, maxAssets, uint256(DustHandler.DustAction.SweepToUser), owed);
        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, owed, data);

        assertEq(_fixedDebt(maturity), 0, "fixed position closed");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
        assertEq(IERC20(USDC).allowance(address(repayModule), MARKET_USDC), 0, "grant cleared");
    }

    /// @notice `DustAction.Recycle` on a floating repay: the full signed ceiling is
    ///         pulled, the debt retired, and the surplus RE-SUPPLIED as the maker's
    ///         floating deposit rather than swept.
    function test_audit_L_FSE_6_floatingRepay_recycle_live() public {
        _seedDebt(0, DEBT);
        uint256 ceiling = DEBT + 100e6;
        deal(USDC, maker, ceiling);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, type(uint160).max, 0);
        vm.stopPrank();

        uint256 sharesBefore = IExactlyMarket(MARKET_USDC).balanceOf(maker);
        bytes memory data =
            abi.encode(MARKET_USDC, USDC, uint256(0), uint256(0), uint256(DustHandler.DustAction.Recycle));
        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, ceiling, data);

        (,, uint256 floatingShares) = IExactlyMarket(MARKET_USDC).accounts(maker);
        assertEq(floatingShares, 0, "floating debt retired");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "whole ceiling pulled (Recycle)");
        uint256 recycled =
            IExactlyMarket(MARKET_USDC).previewRedeem(IExactlyMarket(MARKET_USDC).balanceOf(maker) - sharesBefore);
        assertApproxEqAbs(recycled, 100e6, 2, "surplus re-supplied as the maker's floating deposit");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
        assertEq(IERC20(USDC).allowance(address(repayModule), MARKET_USDC), 0, "grant cleared");
    }

    // ──────────────── L-FSE-2 / X-ARITH-5: pre-fund fixed repay ────────────────

    function _repayDesc() internal pure returns (uint256) {
        // leg reference (bit 255) + PRE-FUND (bit 253) + token + leg 0, op Repay in [244,252)
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(USDC)) << 16)
            | (uint256(ExactlyPreFundModule.Op.Repay) << 244);
    }

    function _preFundRepay(bytes memory data, uint256 forAmount) internal {
        deal(USDC, address(preFund), IERC20(USDC).balanceOf(address(preFund)) + forAmount);
        vm.prank(settlement);
        IMakerModule(address(preFund)).makeOnBehalf(maker, forAmount, data);
    }

    /// @notice AUCTIONED funding leg, `total` signed as its FLOOR (`end`) delivery per
    ///         the corrected byte map: an early 96% slice delivers above `total`, so
    ///         it presents — and, pre-maturity at a discount, retires — the WHOLE face.
    ///         The remaining 4% slice then meets an empty fixed position. Before the
    ///         fix it was presented to Exactly anyway and reverted (division by zero
    ///         in `FixedLib.scaleProportionally`), leaving the order's tail
    ///         unfillable; now it is skipped and its delivery swept to the maker.
    function test_audit_L_FSE_2_auctionedLeg_overRetiringSlice_doesNotBrickTheRest() public {
        uint256 maturity = _nextMaturity();
        uint256 owed = _seedDebt(maturity, DEBT);
        uint256 end = owed; //                 the leg's floor delivery = `total`
        uint256 start = (owed * 110) / 100; // auction start
        bytes memory data = abi.encode(_repayDesc(), MARKET_USDC, USDC, maturity, owed, end);

        // Slice 1: 96% at the START tick.
        uint256 slice1 = (start * 96) / 100;
        _preFundRepay(data, slice1);
        assertEq(_fixedDebt(maturity), 0, "the early slice retired the whole face");

        // Slice 2: the remaining 4% — must not revert.
        uint256 makerBefore = IERC20(USDC).balanceOf(maker);
        uint256 slice2 = (start * 4) / 100;
        _preFundRepay(data, slice2);

        assertEq(IERC20(USDC).balanceOf(maker) - makerBefore, slice2, "nothing left to retire: delivery swept back");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(USDC).allowance(address(preFund), MARKET_USDC), 0, "grant cleared");
    }

    /// @notice A FULL fill of an auctioned leg at a DECAYED tick, `total = end`:
    ///         `forAmount >= total`, so the whole face is retired — the case where
    ///         signing `total = start` left fixed debt open with the order consumed.
    function test_audit_L_FSE_2_auctionedLeg_decayedFullFill_retiresWholeFace() public {
        uint256 maturity = _nextMaturity();
        uint256 owed = _seedDebt(maturity, DEBT);
        uint256 end = owed;
        uint256 tick = owed + (owed * 2) / 100; // decayed most of the way to `end`
        bytes memory data = abi.encode(_repayDesc(), MARKET_USDC, USDC, maturity, owed, end);

        _preFundRepay(data, tick);

        assertEq(_fixedDebt(maturity), 0, "whole fixed position closed");
        assertGe(IERC20(USDC).balanceOf(maker), tick - owed, "unspent budget swept to the maker");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
    }

    /// @notice X-ARITH-5: a mis-encoded, too-SMALL `total` makes every slice present
    ///         the whole face. That is not a ceiling against the maker (the delivered
    ///         budget is), so it is not refused — but it must not brick the order: the
    ///         first slice retires the position within its own budget and the next
    ///         slice finds nothing to retire and is swept back, instead of reverting.
    function test_audit_X_ARITH_5_tooSmallTotal_laterSlicesSweep_notRevert() public {
        uint256 maturity = _nextMaturity();
        uint256 owed = _seedDebt(maturity, DEBT);
        bytes memory data = abi.encode(_repayDesc(), MARKET_USDC, USDC, maturity, owed, uint256(1));

        _preFundRepay(data, owed + 10e6);
        assertEq(_fixedDebt(maturity), 0, "first slice retired the whole face within its budget");

        uint256 makerBefore = IERC20(USDC).balanceOf(maker);
        _preFundRepay(data, 300e6);
        assertEq(IERC20(USDC).balanceOf(maker) - makerBefore, 300e6, "second slice swept back, no revert");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
    }

    /// @notice The clamp never interferes with the honest fixed-price partial path
    ///         (F27/H-3): two halves each retire their own share.
    function test_audit_L_FSE_2_fixedLeg_partialSlices_unchanged() public {
        uint256 maturity = _nextMaturity();
        uint256 owed = _seedDebt(maturity, DEBT);
        uint256 total = owed + 50e6;
        bytes memory data = abi.encode(_repayDesc(), MARKET_USDC, USDC, maturity, owed, total);

        _preFundRepay(data, total / 2);
        uint256 left = _fixedDebt(maturity);
        assertGt(left, 0, "half a slice does not close the position");
        assertApproxEqAbs(left, owed - owed / 2, 2, "half the face retired");

        _preFundRepay(data, total - total / 2);
        assertLe(_fixedDebt(maturity), 1, "both halves retire the face (floor rounding may leave a wei)");
    }
}

// ═══════════════════ X-STATIC-1.v1: no standing grant after a FoT repay ═══════════════════

/// @dev Fee-on-transfer token: 1% of every transfer is burned in flight.
contract FoTToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _move(from, to, a);
        return true;
    }

    function _move(address from, address to, uint256 a) internal {
        balanceOf[from] -= a;
        balanceOf[to] += a - a / 100;
    }
}

/// @dev An order-chosen "market" that pulls exactly what the caller HOLDS — the
///      delivered delta of a fee-on-transfer pull — and reports a live floating debt.
contract HoldingsPullMarket {
    address internal immutable token;

    constructor(address t) {
        token = t;
    }

    function accounts(address) external pure returns (uint256, uint256, uint256) {
        return (0, 0, 1_000e6);
    }

    function previewRefund(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function repay(uint256, address) external returns (uint256, uint256) {
        uint256 bal = FoTToken(token).balanceOf(msg.sender);
        FoTToken(token).transferFrom(msg.sender, address(this), bal);
        return (bal, bal);
    }

    function repayAtMaturity(uint256, uint256, uint256, address) external returns (uint256) {
        uint256 bal = FoTToken(token).balanceOf(msg.sender);
        FoTToken(token).transferFrom(msg.sender, address(this), bal);
        return bal;
    }
}

/// @title ExactlyRepayFoTGrantClearTest
/// @notice X-STATIC-1.v1: {ExactlyRepayModule} cleared its scoped market grant only
///         BELOW `_disposeResidual`'s `bal <= floor` early return. A fee-on-transfer
///         asset delivers less than the nominal approval, an order-chosen market
///         pulls the delta, the balance returns to the floor — and the difference
///         stayed granted to that market. The end state asserted: no grant survives.
contract ExactlyRepayFoTGrantClearTest is Test {
    Permit3 internal permit3;
    ExactlyRepayModule internal repayModule;
    FoTToken internal token;
    HoldingsPullMarket internal market;
    address internal maker = address(0xA11CE);
    address internal settlement = address(0x5E77);

    function setUp() public {
        permit3 = new Permit3();
        repayModule = new ExactlyRepayModule(address(permit3), settlement);
        token = new FoTToken();
        market = new HoldingsPullMarket(address(token));
        token.mint(maker, 10_000e6);
        vm.startPrank(maker);
        token.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), address(token), type(uint160).max, 0);
        vm.stopPrank();
    }

    function test_audit_X_STATIC_1_v1_floatingRepay_fotAsset_noStandingGrant() public {
        bytes memory data = abi.encode(address(market), address(token), uint256(0), uint256(0));
        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, 500e6, data);

        assertEq(token.balanceOf(address(repayModule)), 0, "precondition: balance back at the floor");
        assertEq(token.allowance(address(repayModule), address(market)), 0, "no grant outlives the call");
    }

    function test_audit_X_STATIC_1_v1_fixedRepay_fotAsset_noStandingGrant() public {
        bytes memory data = abi.encode(
            address(market), address(token), uint256(1), uint256(500e6), uint256(0), uint256(500e6)
        );
        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, 500e6, data);

        assertEq(token.balanceOf(address(repayModule)), 0, "precondition: balance back at the floor");
        assertEq(token.allowance(address(repayModule), address(market)), 0, "no grant outlives the call");
    }
}
