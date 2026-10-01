// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {LiquityV2TakerModule, LiquityV2RepayModule, LiquityV2TroveAuth} from "../../src/LiquityV2Modules.sol";
import {ICollateralRegistry, ILiquityV2TroveManager, LatestTroveData} from "../../src/interfaces/ILiquityV2.sol";

/// @dev The REAL mainnet Liquity V2 surface beyond the module interface.
interface IBOVenue {
    function openTrove(
        address _owner,
        uint256 _ownerIndex,
        uint256 _collAmount,
        uint256 _boldAmount,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _annualInterestRate,
        uint256 _maxUpfrontFee,
        address _addManager,
        address _removeManager,
        address _receiver
    ) external returns (uint256);
    function setRemoveManagerWithReceiver(uint256 _troveId, address _manager, address _receiver) external;
    function removeManagerReceiverOf(uint256 _troveId) external view returns (address manager, address receiver);
}

interface ITroveNFTVenue {
    function ownerOf(uint256) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title 2026-09-30 audit — Liquity v2 against the LIVE mainnet WETH branch.
/// @notice G-VENUE_B-1: a trove bought with a stale remove-manager RECEIVER (the
///         pair survives a TroveNFT transfer) used to let the venue pay the former
///         owner while Settlement billed the leg to the buyer's wallet. The fill now
///         reverts and nothing moves. L-LRG-1: a mis-named collateral is rejected
///         against the registry's `getToken`. L-CENSUS-3: the pull repay module
///         serves an over-sized repay (the venue clamps at MIN_DEBT, the module
///         sweeps). Real Settlement + Permit3 + the real BorrowerOperations at block
///         25.6M; only actors and balances are test-controlled.
contract AuditLiquityV2VenueForkTest is CoreSettlementBase {
    address internal constant TROVE_MANAGER = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address internal constant COLLATERAL_REGISTRY = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;
    uint256 internal constant BRANCH = 0; // WETH branch
    address internal constant BORROWER_OPS = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65;
    address internal constant TROVE_NFT = 0x1A0FC0b843aFD9140267D25d4E575Cb37a838013;
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address internal constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;

    uint256 internal constant ETH_GAS_COMPENSATION = 0.0375 ether;
    uint256 internal constant OPEN_COLL = 20 ether;
    uint256 internal constant OPEN_DEBT = 4000e18;
    uint256 internal constant MIN_DEBT = 2000e18;
    uint256 internal constant INTEREST_RATE = 0.25e18;

    uint256 internal constant WITHDRAW = 5 ether;
    uint256 internal constant USDC_OUT = 15_000e6;

    LiquityV2TakerModule internal takerModule;
    LiquityV2RepayModule internal repayModule;
    address internal seller = makeAddr("troveSeller");
    uint256 internal troveId;

    function _forkBlock() internal view virtual override returns (uint256) {
        return 25_600_000;
    }

    function setUp() public virtual override {
        super.setUp();
        takerModule = new LiquityV2TakerModule(address(permit3), COLLATERAL_REGISTRY);
        repayModule = new LiquityV2RepayModule(address(permit3), address(settlement), COLLATERAL_REGISTRY);

        // Seller opens a trove, grants manager = the 1delta module with receiver =
        // SELLER, then transfers the TroveNFT to the buyer (the maker).
        deal(WETH, seller, OPEN_COLL + ETH_GAS_COMPENSATION);
        vm.startPrank(seller);
        IERC20(WETH).approve(BORROWER_OPS, type(uint256).max);
        troveId = IBOVenue(BORROWER_OPS)
            .openTrove(
                seller, 0, OPEN_COLL, OPEN_DEBT, 0, 0, INTEREST_RATE, type(uint256).max, address(0), address(0), address(0)
            );
        IBOVenue(BORROWER_OPS).setRemoveManagerWithReceiver(troveId, address(takerModule), seller);
        IERC20(BOLD).transfer(address(0xdead), IERC20(BOLD).balanceOf(seller));
        ITroveNFTVenue(TROVE_NFT).transferFrom(seller, maker, troveId);
        vm.stopPrank();
        deal(WETH, seller, 0);
    }

    function _withdrawCollData(address token) internal view returns (bytes memory) {
        return abi.encode(uint8(1), BRANCH, troveId, token);
    }

    function _borrowData(uint256 total) internal view returns (bytes memory) {
        return abi.encode(uint8(0), BRANCH, troveId, BOLD, type(uint256).max, total);
    }

    function _takeOrder(address tokenIn, uint256 amountIn, bytes memory data, uint256 nonce)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE, module: address(takerModule), amount: amountIn, recipient: address(0), data: data});
        return _order(maker, nonce, tokenIn, USDC, amountIn, USDC_OUT, items);
    }

    function _trove() internal view returns (LatestTroveData memory) {
        return ILiquityV2TroveManager(TROVE_MANAGER).getLatestTroveData(troveId);
    }

    /// The buyer's ordinary setup: taker grant + a standing Settlement allowance on
    /// the leg token + wallet balance — exactly what the wallet-billing path needed.
    function _armWithdraw(bytes memory data) internal {
        deal(WETH, maker, 10 ether);
        vm.startPrank(maker);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(data), uint160(WITHDRAW), 0);
        permit3.approveToken(address(settlement), WETH, type(uint160).max, 0);
        vm.stopPrank();
        deal(USDC, solver, USDC_OUT);
    }

    // ─────────────── G-VENUE_B-1 ───────────────

    function test_audit_G_VENUE_B_1_staleReceiver_withdrawColl_failsClosed() public {
        (address mgr, address rcv) = IBOVenue(BORROWER_OPS).removeManagerReceiverOf(troveId);
        assertEq(mgr, address(takerModule), "pre: manager looks onboarded");
        assertEq(rcv, seller, "pre: the receiver survived the NFT transfer");

        bytes memory data = _withdrawCollData(WETH);
        _armWithdraw(data);
        Order memory order = _takeOrder(WETH, WITHDRAW, data, 1);
        bytes memory sig = _sign(order);

        uint256 collBefore = _trove().entireColl;
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.ShortWithdraw.selector, 0, WITHDRAW));
        settlement.fill(order, sig, WITHDRAW);

        assertEq(_trove().entireColl, collBefore, "trove untouched");
        assertEq(IERC20(WETH).balanceOf(maker), makerWethBefore, "maker wallet untouched");
        assertEq(IERC20(WETH).balanceOf(seller), 0, "stale receiver got nothing");
    }

    function test_audit_G_VENUE_B_1_staleReceiver_borrow_failsClosed() public {
        uint256 borrow = 1000e18;
        bytes memory data = _borrowData(borrow);
        deal(BOLD, maker, 2000e18);
        vm.startPrank(maker);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(data), uint160(borrow), 0);
        IERC20(BOLD).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), BOLD, type(uint160).max, 0);
        vm.stopPrank();
        deal(USDC, solver, USDC_OUT);

        Order memory order = _takeOrder(BOLD, borrow, data, 2);
        bytes memory sig = _sign(order);
        uint256 debtBefore = _trove().entireDebt;

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.ShortWithdraw.selector, 0, borrow));
        settlement.fill(order, sig, borrow);

        assertEq(_trove().entireDebt, debtBefore, "no debt drawn");
        assertEq(IERC20(BOLD).balanceOf(maker), 2000e18, "maker wallet untouched");
        assertEq(IERC20(BOLD).balanceOf(seller), 0, "stale receiver got nothing");
    }

    /// Control: after the buyer re-grants receiver = module the same order fills,
    /// funded from the trove, wallet untouched.
    function test_audit_G_VENUE_B_1_receiverIsModule_fills() public {
        vm.prank(maker);
        IBOVenue(BORROWER_OPS).setRemoveManagerWithReceiver(troveId, address(takerModule), address(takerModule));

        bytes memory data = _withdrawCollData(WETH);
        _armWithdraw(data);
        Order memory order = _takeOrder(WETH, WITHDRAW, data, 3);
        bytes memory sig = _sign(order);
        uint256 collBefore = _trove().entireColl;
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(order, sig, WITHDRAW);

        assertEq(collBefore - _trove().entireColl, WITHDRAW, "trove funded the leg");
        assertEq(IERC20(WETH).balanceOf(maker), makerWethBefore, "maker wallet untouched");
    }

    // ─────────────── L-LRG-1 ───────────────

    /// The registry's `getToken` is real on mainnet, and a real-but-wrong collateral
    /// (rETH named on the WETH branch) is rejected before the venue call.
    function test_audit_L_LRG_1_withdrawColl_wrongBranchCollateral_rejected() public {
        assertEq(ICollateralRegistry(COLLATERAL_REGISTRY).getToken(BRANCH), WETH, "registry getter: branch 0 = WETH");
        vm.prank(maker);
        IBOVenue(BORROWER_OPS).setRemoveManagerWithReceiver(troveId, address(takerModule), address(takerModule));

        bytes memory data = _withdrawCollData(RETH);
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(data), uint160(WITHDRAW), 0);

        uint256 collBefore = _trove().entireColl;
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(LiquityV2TroveAuth.CollTokenMismatch.selector, RETH, WETH));
        permit3.take(address(takerModule), maker, uint160(WITHDRAW), address(settlement), data);
        assertEq(_trove().entireColl, collBefore, "trove untouched");
        assertEq(IERC20(WETH).balanceOf(address(takerModule)), 0, "nothing stranded");
    }

    // ─────────────── L-CENSUS-3 ───────────────

    /// The pull repay module on the LIVE venue with `amount > entireDebt`: it used to
    /// revert `FullCloseNotSupported`; the venue clamps at MIN_DEBT and the module
    /// sweeps the un-burned BOLD back.
    function test_audit_L_CENSUS_3_pullRepay_overSized_clampsAtMinDebt() public {
        uint256 entire = _trove().entireDebt;
        uint256 signed = entire + 100e18;
        deal(BOLD, maker, signed);
        vm.startPrank(maker);
        IERC20(BOLD).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), BOLD, uint160(signed), 0);
        vm.stopPrank();

        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, signed, abi.encode(BRANCH, troveId, BOLD));

        assertEq(_trove().entireDebt, MIN_DEBT, "venue clamped the burn at MIN_DEBT");
        assertEq(IERC20(BOLD).balanceOf(maker), signed - (entire - MIN_DEBT), "un-burned BOLD swept back");
        assertEq(IERC20(BOLD).balanceOf(address(repayModule)), 0, "module holds nothing");
    }
}
