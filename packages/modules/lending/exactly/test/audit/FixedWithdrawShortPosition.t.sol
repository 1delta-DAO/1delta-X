// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {ExactlyTakerModule} from "../../src/ExactlyModules.sol";
import {IExactlyMarket} from "../../src/interfaces/IExactly.sol";

/// @title ExactlyFixedWithdrawShortPositionTest
/// @notice 2026-09-30 audit L-CV2-1.v1 regression, against the LIVE exaUSDC Market on
///         Optimism through the REAL Settlement and Permit3.
///
///         Exactly's `withdrawAtMaturity` CLAMPS a request larger than the fixed
///         deposit to the deposit instead of reverting. Before the fix the module
///         passed the slice straight through, the venue under-delivered without
///         reverting, and `Core._payInputsToSolver` pulled the shortfall out of the
///         maker's WALLET. The module now reads `fixedDepositPositions` and reverts
///         `ShortFixedPosition` — the asserted end state is "the fill reverts and the
///         wallet is untouched". Also the first live coverage of the fixed-withdraw
///         branch at all (L-FSE-6).
contract ExactlyFixedWithdrawShortPositionTest is CoreSettlementBase {
    address internal constant MARKET_USDC = 0x6926B434CCe9b5b7966aE1BfEef6D0A7DCF3A8bb; // exaUSDC (native)
    address internal constant OP_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant OP_WETH = 0x4200000000000000000000000000000000000006;

    uint256 internal constant FORK_BLOCK = 154_900_000; // the package's fork pin
    uint256 internal constant FIXED_INTERVAL = 4 weeks;

    uint256 internal constant SIGNED = 10_000e6;
    uint256 internal constant DRAWN = 6_000e6;
    uint256 internal constant WALLET = 20_000e6;
    uint256 internal constant WETH_OUT = 4e18;

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
        revert("ExactlyFixedWithdraw: no archive-capable Optimism RPC (set OPTIMISM_RPC_URL)");
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

        maturity = block.timestamp - (block.timestamp % FIXED_INTERVAL) + FIXED_INTERVAL;

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

    function _fixedWithdrawData(uint256 minAssets) internal view returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Withdraw), MARKET_USDC, USDC, maturity, minAssets, SIGNED);
    }

    function _position(address who) internal view returns (uint256) {
        (uint256 p, uint256 f) = IExactlyMarket(MARKET_USDC).fixedDepositPositions(maturity, who);
        return p + f;
    }

    /// @dev The README grants for the TAKE leg + a standing Settlement allowance on
    ///      USDC the maker uses for its OTHER USDC-selling orders — the allowance the
    ///      pre-fix shortfall was billed against.
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

    function _orderO(uint256 nonce, bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(takerModule), amount: SIGNED, recipient: address(0), data: data});
        return _sellOrder(nonce, maker, USDC, WETH, SIGNED, WETH_OUT, items);
    }

    /// @notice The PoC scenario, asserting the SAFE end state: a short fixed position
    ///         makes the fill REVERT and the maker's wallet is never billed.
    function test_audit_L_CV2_1_v1_shortFixedPosition_settlementFillReverts_walletUntouched() public {
        vm.warp(maturity + 1 days); // matured: minAssets = 0 is the natural floor
        vm.prank(maker);
        IExactlyMarket(MARKET_USDC).withdrawAtMaturity(maturity, DRAWN, 0, maker, maker);
        uint256 positionBefore = _position(maker);
        assertLt(positionBefore, SIGNED, "precondition: position short of the slice");
        assertGt(positionBefore, 0, "precondition: position partially remains");

        bytes memory data = _fixedWithdrawData(0);
        _grants(data);
        Order memory order = _orderO(1, data);
        bytes memory sig = _sign(order);

        uint256 makerWalletBefore = IERC20(USDC).balanceOf(maker);
        uint256 solverUsdcBefore = IERC20(USDC).balanceOf(solver);

        vm.prank(solver);
        // `ExactlyTakerModule.ShortFixedPosition(amount, position)`, by signature so
        // this file also compiles against the pre-fix module (fails-before check).
        vm.expectRevert(abi.encodeWithSignature("ShortFixedPosition(uint256,uint256)", SIGNED, positionBefore));
        settlement.fill(order, sig, SIGNED);

        assertEq(IERC20(USDC).balanceOf(maker), makerWalletBefore, "maker wallet NOT billed");
        assertEq(IERC20(USDC).balanceOf(solver), solverUsdcBefore, "filler got nothing");
        assertEq(_position(maker), positionBefore, "fixed position untouched");
    }

    /// @notice The venue-isolating shape: a direct Permit3.take on a short position
    ///         reverts instead of under-delivering, and spends none of the taker grant.
    function test_audit_L_CV2_1_v1_shortFixedPosition_directTake_reverts() public {
        vm.warp(maturity + 1 days);
        vm.prank(maker);
        IExactlyMarket(MARKET_USDC).withdrawAtMaturity(maturity, DRAWN, 0, maker, maker);

        bytes memory data = _fixedWithdrawData(0);
        vm.startPrank(maker);
        IERC20(MARKET_USDC).approve(address(takerModule), type(uint256).max);
        permit3.approveTaker(address(this), address(takerModule), keccak256(data), uint160(SIGNED), type(uint48).max);
        vm.stopPrank();

        address rcv = address(0xCAFE);
        vm.expectRevert();
        permit3.take(address(takerModule), maker, uint160(SIGNED), rcv, data);

        assertEq(IERC20(USDC).balanceOf(rcv), 0, "no short delivery");
        (uint160 left,) = permit3.takerAllowance(maker, address(this), address(takerModule), keccak256(data));
        assertEq(left, SIGNED, "taker allowance untouched");
    }

    /// @notice CONTROL + coverage of the live fixed-withdraw branch (L-FSE-6): a
    ///         position that covers the slice fills from the position and the
    ///         maker's wallet is never billed.
    function test_audit_L_CV2_1_v1_fullFixedPosition_fillsFromPosition() public {
        vm.warp(maturity + 1 days);
        assertGe(_position(maker), SIGNED, "full position");

        bytes memory data = _fixedWithdrawData(0);
        _grants(data);
        Order memory order = _orderO(2, data);
        bytes memory sig = _sign(order);

        uint256 makerWalletBefore = IERC20(USDC).balanceOf(maker);
        vm.prank(solver);
        settlement.fill(order, sig, SIGNED);

        assertGe(IERC20(USDC).balanceOf(maker), makerWalletBefore, "maker wallet NOT billed");
        assertEq(IERC20(USDC).balanceOf(solver), SIGNED, "filler got 10,000 from the position");
        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "maker got the signed WETH");
    }

    /// @notice A PARTIAL slice of a fixed withdraw is still admitted while the
    ///         position covers it — the guard is the venue's clamp condition, not a
    ///         full-fill rule.
    function test_audit_L_CV2_1_v1_partialSlice_withinPosition_succeeds() public {
        vm.warp(maturity + 1 days);
        bytes memory data = _fixedWithdrawData(0);
        vm.startPrank(maker);
        IERC20(MARKET_USDC).approve(address(takerModule), type(uint256).max);
        permit3.approveTaker(address(this), address(takerModule), keccak256(data), uint160(SIGNED), type(uint48).max);
        vm.stopPrank();

        uint256 before = _position(maker);
        address rcv = address(0xCAFE);
        permit3.take(address(takerModule), maker, uint160(SIGNED / 4), rcv, data);
        assertEq(IERC20(USDC).balanceOf(rcv), SIGNED / 4, "matured: no discount, exact face delivered");
        assertEq(_position(maker), before - SIGNED / 4, "position reduced by the slice");
    }
}
