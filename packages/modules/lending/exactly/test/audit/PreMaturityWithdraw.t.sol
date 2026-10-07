// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {ExactlyTakerModule} from "../../src/ExactlyModules.sol";
import {IExactlyMarket, IExactlyAuditor} from "../../src/interfaces/IExactly.sol";

/// @title ExactlyPreMaturityWithdrawTest
/// @notice Review 2026-10-06 task 12, against the LIVE exaUSDC Market on Optimism
///         through the REAL Settlement, Permit3 and lens.
///
///         Before maturity `withdrawAtMaturity` pays `assetsDiscounted < amount`
///         straight to the receiver, and the module deliberately does not bound it
///         (the discount is legitimate). {Core._payInputsToSolver} therefore bills
///         `owed − assetsDiscounted` to the maker's WALLET. The fixed rate behind the
///         discount is a live utilisation figure a filler can raise in the same block
///         by borrowing at that maturity first, so `minAssetsRequired` — the only cap
///         — must be signed non-zero. Every earlier test signed it 0 and warped past
///         maturity; this suite pins the pre-maturity path:
///
///           • a zero floor REVERTS `ZeroMinAssets` (B15, 2026-10-06 — it used to
///             bill exactly `owed − assetsDiscounted` to the wallet), and stays
///             legal at/after maturity;
///           • a non-zero floor caps it, and a same-block rate raise that would push
///             the discount past the floor makes the fill revert instead;
///           • the lens flags the zero-floor order and passes the floored one.
contract ExactlyPreMaturityWithdrawTest is CoreSettlementBase {
    address internal constant AUDITOR = 0xaEb62e6F27BC103702E7BC879AE98bceA56f027E;
    address internal constant MARKET_USDC = 0x6926B434CCe9b5b7966aE1BfEef6D0A7DCF3A8bb; // exaUSDC (native)
    address internal constant OP_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant OP_WETH = 0x4200000000000000000000000000000000000006;

    uint256 internal constant FORK_BLOCK = 154_900_000; // the package's fork pin
    uint256 internal constant FIXED_INTERVAL = 4 weeks;

    uint256 internal constant SIGNED = 10_000e6; //  face withdrawn == the input leg
    uint256 internal constant WALLET = 5_000e6; //   unrelated wallet USDC (the draw's source)
    uint256 internal constant WETH_OUT = 4e18;
    string internal constant FLOOR_WHY = "item proceeds floor does not bound the wallet draw on its input leg";

    ExactlyTakerModule internal takerModule;
    uint256 internal maturity;

    function _forkOptimism() internal {
        try vm.envString("OPTIMISM_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryForkOp(v)) return;
        } catch {}
        string[3] memory rpcs = ["https://mainnet.optimism.io", "https://optimism.drpc.org", "https://1rpc.io/op"];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryForkOp(rpcs[i])) return;
        }
        revert("ExactlyPreMaturityWithdraw: no archive-capable Optimism RPC (set OPTIMISM_RPC_URL)");
    }

    function _tryForkOp(string memory rpc) internal returns (bool) {
        try this.__forkOp(rpc) {
            return true;
        } catch {
            return false;
        }
    }

    function __forkOp(string calldata rpc) external {
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    function setUp() public override {
        // NOT super.setUp(): that forks Ethereum mainnet. Same deployments, on Optimism.
        _forkOptimism();
        USDC = OP_USDC;
        WETH = OP_WETH;

        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));
        lens = new SettlementLens(address(settlement));
        takerModule = new ExactlyTakerModule(address(permit3));

        // A maturity two intervals out, so it is still well in the future.
        maturity = block.timestamp - (block.timestamp % FIXED_INTERVAL) + 2 * FIXED_INTERVAL;

        // Maker: a 10,000 USDC fixed deposit at `maturity`, plus unrelated wallet USDC.
        deal(USDC, maker, SIGNED + WALLET);
        vm.startPrank(maker);
        IERC20(USDC).approve(MARKET_USDC, SIGNED);
        IExactlyMarket(MARKET_USDC).depositAtMaturity(maturity, SIGNED, 0, maker);
        vm.stopPrank();

        deal(WETH, solver, 100e18);
        vm.startPrank(solver);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _data(uint256 minAssets) internal view returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Withdraw), MARKET_USDC, USDC, maturity, minAssets, SIGNED);
    }

    /// @dev The share grant + taker grant for the TAKE, and the standing Settlement
    ///      allowance on USDC the maker uses for other USDC-selling orders — the
    ///      allowance the shortfall is billed against.
    function _grants(bytes memory data) internal {
        vm.startPrank(maker);
        IERC20(MARKET_USDC).approve(address(takerModule), type(uint256).max);
        permit3.approveTaker(
            address(settlement), address(takerModule), keccak256(data), uint160(SIGNED), type(uint48).max
        );
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _order(uint256 nonce, bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(takerModule), amount: SIGNED, recipient: address(0), data: data});
        return _sellOrder(nonce, maker, USDC, WETH, SIGNED, WETH_OUT, items);
    }

    /// @dev What the venue would pay for the whole face RIGHT NOW — measured by
    ///      running the withdraw and rolling it back.
    function _discounted() internal returns (uint256 got) {
        uint256 snap = vm.snapshotState();
        vm.prank(maker);
        got = IExactlyMarket(MARKET_USDC).withdrawAtMaturity(maturity, SIGNED, 0, maker, maker);
        vm.revertToState(snap);
    }

    /// @dev A third party borrows at the maker's maturity in the same block — the
    ///      filler-side lever on the fixed rate the discount is priced at.
    function _raiseRate(uint256 borrow) internal {
        address whale = makeAddr("rate-raiser");
        deal(USDC, whale, borrow * 3);
        vm.startPrank(whale);
        IERC20(USDC).approve(MARKET_USDC, borrow * 3);
        IExactlyMarket(MARKET_USDC).deposit(borrow * 3, whale);
        IExactlyAuditor(AUDITOR).enterMarket(MARKET_USDC);
        IExactlyMarket(MARKET_USDC).borrowAtMaturity(maturity, borrow, type(uint256).max, whale, whale);
        vm.stopPrank();
    }

    /// @notice Zero floor before maturity: the lens flags it up front, and since B15
    ///         (2026-10-06) the module REVERTS `ZeroMinAssets` at fill time — the
    ///         unbounded wallet draw (`owed − assetsDiscounted`, which a filler can
    ///         widen in the same block) is no longer reachable. Wallet untouched.
    function test_preMaturity_zeroFloor_reverts() public {
        assertLt(block.timestamp, maturity, "pre-maturity");
        bytes memory data = _data(0);
        _grants(data);
        Order memory order = _order(1, data);

        (bool ok, string memory why) = lens.validateOrder(order);
        assertFalse(ok, "zero floor flagged");
        assertEq(why, FLOOR_WHY);

        assertLt(_discounted(), SIGNED, "precondition: a pre-maturity discount exists");

        uint256 walletBefore = IERC20(USDC).balanceOf(maker);
        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectRevert(ExactlyTakerModule.ZeroMinAssets.selector);
        settlement.fill(order, sig, SIGNED);
        assertEq(IERC20(USDC).balanceOf(maker), walletBefore, "wallet untouched");
    }

    /// @notice The same zero-floor order is legal once maturity has passed: the face is
    ///         paid in full, nothing is billed to the wallet, and the lens passes it.
    function test_atMaturity_zeroFloor_fillsAtFace() public {
        // Warp FIRST: the order builder stamps a 1h deadline from `block.timestamp`.
        // A fixed withdraw reads no price feed, so the warp trips no oracle staleness.
        vm.warp(maturity);
        bytes memory data = _data(0);
        _grants(data);
        Order memory order = _order(4, data);
        bytes memory sig = _sign(order);

        (bool ok, string memory why) = lens.validateOrder(order);
        assertTrue(ok, why);

        uint256 walletBefore = IERC20(USDC).balanceOf(maker);
        vm.prank(solver);
        settlement.fill(order, sig, SIGNED);
        assertEq(IERC20(USDC).balanceOf(maker), walletBefore, "no wallet draw at maturity");
        assertEq(IERC20(USDC).balanceOf(solver), SIGNED);
    }

    /// @notice A floor at the live discounted amount caps the draw at `owed − floor`
    ///         and passes the lens.
    function test_preMaturity_floor_capsTheWalletDraw() public {
        uint256 floor = _discounted();
        bytes memory data = _data(floor);
        _grants(data);
        Order memory order = _order(2, data);

        (bool ok, string memory why) = lens.validateOrder(order);
        assertTrue(ok, why);

        uint256 walletBefore = IERC20(USDC).balanceOf(maker);
        bytes memory sig = _sign(order);
        vm.prank(solver);
        settlement.fill(order, sig, SIGNED);

        assertLe(walletBefore - IERC20(USDC).balanceOf(maker), SIGNED - floor, "draw <= owed - minAssetsRequired");
        assertEq(IERC20(USDC).balanceOf(solver), SIGNED);
    }

    /// @notice The attack the floor exists for: a same-block borrow at the maker's
    ///         maturity deepens the discount. With the floor signed at the pre-raise
    ///         figure the fill REVERTS and the wallet is untouched; signed 0 it would
    ///         have billed the deeper discount.
    function test_preMaturity_rateRaise_deeperDiscount_refusedByTheFloor() public {
        uint256 floor = _discounted();
        bytes memory data = _data(floor);
        _grants(data);
        Order memory order = _order(3, data);
        bytes memory sig = _sign(order);

        _raiseRate(500_000e6);
        uint256 raised = _discounted();
        assertLt(raised, floor, "precondition: the borrow deepened the discount");

        uint256 walletBefore = IERC20(USDC).balanceOf(maker);
        vm.prank(solver);
        // Exactly: `assetsDiscounted < minAssetsRequired`.
        vm.expectRevert(abi.encodeWithSignature("Disagreement()"));
        settlement.fill(order, sig, SIGNED);
        assertEq(IERC20(USDC).balanceOf(maker), walletBefore, "wallet untouched");
    }
}
