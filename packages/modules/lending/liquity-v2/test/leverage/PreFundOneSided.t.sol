// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {LiquityV2PreFundModule} from "../../src/LiquityV2PreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {LiquityV2TroveAuth} from "../../src/LiquityV2Modules.sol";
import {ILiquityV2TroveManager, LatestTroveData} from "../../src/interfaces/ILiquityV2.sol";

/// @dev The open/onboarding surface the push flow needs beyond the module
///      interface — the same plain `openTrove` the leverage suite uses.
interface IBorrowerOpsPreFund {
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
}

/// @dev The ONE-SIDED pre-fund composites on Liquity V2 (Ethereum mainnet WETH
/// branch): "add-collateral whatever the conversion delivered" / "repay whatever
/// the conversion delivered", with ZERO receive-side approvals. The converted
/// output leg is delivered straight to the module (`recipient = module`), the
/// core sizes `forAmount` to exactly that delivery, and the maker's only grants
/// are the input-leg approval they had anyway plus a signable taker allowance.
/// The received asset — WETH on an add, BOLD on a repay — is never approved to
/// anything, anywhere. No venue grant appears in these flows either: the trove
/// has NO add manager set, and Liquity's value-in ops are permissionless while
/// that slot is empty (a maker who HAS set one must point it at the module).
contract LiquityV2PreFundOneSidedTest is CoreSettlementBase {
    LiquityV2PreFundModule preFund;
    // ── Verified Ethereum mainnet addresses (Liquity V2, WETH branch) — same
    //    set and pin as test/leverage/Leverage.t.sol. ──
    address internal constant TROVE_MANAGER = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address internal constant COLLATERAL_REGISTRY = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;
    uint256 internal constant BRANCH = 0; // WETH branch
    address internal constant BORROWER_OPS = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65;
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    uint256 internal constant ETH_GAS_COMPENSATION = 0.0375 ether;
    uint256 internal constant OPEN_COLL = 10 ether;
    /// @dev Opened ABOVE the 2000-BOLD minimum so a partial repay has room.
    uint256 internal constant OPEN_DEBT = 4000e18;
    uint256 internal constant MIN_DEBT = 2000e18;
    uint256 internal constant INTEREST_RATE = 0.25e18;
    uint256 troveId;

    function _forkBlock() internal view virtual override returns (uint256) {
        return 25_600_000;
    }

    function setUp() public virtual override {
        super.setUp();

        preFund = new LiquityV2PreFundModule(address(permit3), address(settlement), COLLATERAL_REGISTRY);

        vm.label(address(preFund), "liquityPreFundAddCollModule");
        vm.label(address(preFund), "liquityPreFundRepayModule");
        vm.label(TROVE_MANAGER, "troveManager");
        vm.label(BORROWER_OPS, "borrowerOperations");
        vm.label(BOLD, "BOLD");

        // ── Open the maker's trove. NO add manager: Liquity's value-in ops are
        //    permissionless while the slot is empty, so the pre-fund modules need no
        //    venue grant at all in this configuration. The maker KEEPS the
        //    minted BOLD — it is the input-leg asset of the tests below. ──
        deal(WETH, maker, OPEN_COLL + ETH_GAS_COMPENSATION);
        vm.startPrank(maker);
        IERC20(WETH).approve(BORROWER_OPS, type(uint256).max);
        troveId = IBorrowerOpsPreFund(BORROWER_OPS)
            .openTrove(
                maker,
                0,
                OPEN_COLL,
                OPEN_DEBT,
                0,
                0,
                INTEREST_RATE,
                type(uint256).max,
                address(0), //  _addManager: deliberately unset — see above
                address(0),
                address(0)
            );
        vm.stopPrank();
    }

    // ──────────────────── Helpers ────────────────────

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev Same leg reference, with the op in descriptor bits [244,252).
    function _forLegOp(uint256 index, address token, LiquityV2PreFundModule.Op op) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(op) << 244);
    }

    function _preFundAddCollData() internal view returns (bytes memory) {
        return abi.encode(_forLeg(0, WETH), BRANCH, troveId, WETH);
    }

    function _preFundRepayData() internal view returns (bytes memory) {
        return abi.encode(_forLegOp(0, BOLD, LiquityV2PreFundModule.Op.Repay), BRANCH, troveId, BOLD);
    }

    /// @dev Address one output leg to `to` (the pre-fund shape).
    function _routeLegOut(Order memory o, address token, uint256 start, uint256 end, address to) internal pure {
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(token, start, end, to);
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    function _troveData() internal view returns (LatestTroveData memory) {
        return ILiquityV2TroveManager(TROVE_MANAGER).getLatestTroveData(troveId);
    }

    // ── SWAP & ADD-COLLATERAL. The maker converts BOLD (minted at open — the
    //    one asset they hold and approve as the input leg) into WETH trove
    //    collateral. WETH — the asset they RECEIVE — has its ERC20 approval to
    //    Permit3 revoked outright (the harness grants one in setUp; we strip it)
    //    and no Permit3 book entry: the receive side is strictly empty, and with
    //    no add manager set the venue needs no grant either. ──
    function test_preFundAddColl_swapAndDeposit_zeroReceiveSideApprovals() public {
        uint256 boldIn = 1000e18;
        uint256 wethOut = 0.5 ether;

        _approveMakerToSettlement(BOLD, boldIn); //  the input leg — the ONE approval
        deal(WETH, solver, wethOut);
        _approveSolverSide(wethOut, WETH);

        bytes memory data = _preFundAddCollData();
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        // Prove the receive side is empty BEFORE the fill, not just unused.
        assertEq(IERC20(WETH).allowance(maker, address(permit3)), 0, "WETH has no ERC20 approval to Permit3");
        (uint160 amt,) = permit3.tokenAllowance(maker, address(preFund), WETH);
        assertEq(amt, 0, "WETH has no Permit3 book entry either");

        Item[] memory items = new Item[](1);
        // `amount` is the PACING total (the anchor) — this module moves nothing out.
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 701, BOLD, WETH, boldIn, wethOut, items);
        _routeLegOut(o, WETH, wethOut, 0, address(preFund));
        bytes memory sig = _sign(o);

        // The preflight accepts the module-addressed leg (and cross-checks the
        // fundingSource asset against it).
        (bool ok, string memory why) = lens.validateOrder(o);
        assertTrue(ok, why);

        LatestTroveData memory before = _troveData();
        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, boldIn);

        LatestTroveData memory after_ = _troveData();
        assertEq(after_.entireColl - before.entireColl, wethOut, "the delivered leg became trove collateral, exactly");
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "the maker's wallet never saw the WETH");
        assertEq(IERC20(WETH).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(BOLD).balanceOf(solver), boldIn, "solver received the input leg");
    }

    // ── SWAP & REPAY, inside the repayable band: the burn consumes the whole
    //    delivery, nothing is swept. BOLD — the debt asset — has its ERC20
    //    approval to Permit3 revoked outright: the repay needs no approval
    //    anywhere (BorrowerOperations burns from the module directly). ──
    function test_preFundRepay_partialRepay_zeroReceiveSideApprovals() public {
        uint256 wethIn = 0.4 ether;
        uint256 boldOut = 1000e18;

        vm.prank(maker);
        IERC20(BOLD).transfer(solver, boldOut); //  the solver's inventory
        deal(WETH, maker, wethIn);
        _approveMakerToSettlement(WETH, wethIn); //  the input leg — already-held asset
        _approveSolverSide(boldOut, BOLD);

        bytes memory data = _preFundRepayData();
        vm.startPrank(maker);
        IERC20(BOLD).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();
        assertEq(IERC20(BOLD).allowance(maker, address(permit3)), 0, "the debt token is approved nowhere");

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data); //  pacing amount
        Order memory o = _order(maker, 702, WETH, BOLD, wethIn, boldOut, items);
        _routeLegOut(o, BOLD, boldOut, 0, address(preFund));
        bytes memory sig = _sign(o);

        LatestTroveData memory before = _troveData();
        uint256 makerBold = IERC20(BOLD).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, wethIn);

        LatestTroveData memory after_ = _troveData();
        assertEq(before.entireDebt - after_.entireDebt, boldOut, "the delivered leg retired exactly that much debt");
        assertEq(IERC20(BOLD).balanceOf(maker), makerBold, "no surplus: nothing swept, nothing pulled");
        assertEq(IERC20(BOLD).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received the input leg");
    }

    // ── SWAP & REPAY, overshooting the repayable band. The delivery (2500)
    //    exceeds `entireDebt − MIN_DEBT` (~2000 + open fee): BorrowerOperations
    //    CLAMPS the burn at the minimum-debt floor, silently repaying less than
    //    requested, and the module sweeps the measured un-repayable surplus to
    //    the maker — the solver already paid it. ──
    function test_preFundRepay_venueClampsAtMinDebt_andSweepsSurplusToMaker() public {
        uint256 wethIn = 1 ether;
        uint256 boldOut = 2500e18; //  delivered conversion output — overshoots the band

        vm.prank(maker);
        IERC20(BOLD).transfer(solver, boldOut);
        deal(WETH, maker, wethIn);
        _approveMakerToSettlement(WETH, wethIn);
        _approveSolverSide(boldOut, BOLD);

        bytes memory data = _preFundRepayData();
        vm.startPrank(maker);
        IERC20(BOLD).approve(address(permit3), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 703, WETH, BOLD, wethIn, boldOut, items);
        _routeLegOut(o, BOLD, boldOut, 0, address(preFund));
        bytes memory sig = _sign(o);

        LatestTroveData memory before = _troveData();
        uint256 burnable = before.entireDebt - MIN_DEBT; //  the venue's clamp
        assertLt(burnable, boldOut, "the delivery overshoots the repayable band");
        uint256 makerBold = IERC20(BOLD).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, wethIn);

        LatestTroveData memory after_ = _troveData();
        assertEq(after_.entireDebt, MIN_DEBT, "the trove sits exactly on the minimum-debt floor");
        assertEq(
            IERC20(BOLD).balanceOf(maker), makerBold + (boldOut - burnable), "the un-repayable surplus swept to the maker"
        );
        assertEq(IERC20(BOLD).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(BOLD).allowance(maker, address(permit3)), 0, "the debt-token approval stayed zero throughout");
    }

    // ── The ownership binding survives on the pre-fund seam: a principal who does
    //    not own the named trove is rejected by the registry-rooted check before
    //    anything moves. ──
    function test_preFundModules_rejectForeignTrove() public {
        vm.startPrank(address(settlement));
        vm.expectRevert(LiquityV2TroveAuth.InvalidCaller.selector);
        preFund.makeOnBehalf(solver, 1, _preFundAddCollData());
        vm.expectRevert(LiquityV2TroveAuth.InvalidCaller.selector);
        preFund.makeOnBehalf(solver, 1, _preFundRepayData());
        vm.stopPrank();
    }

    // ── The dispatch gate: only Permit3 may enter. ──
    function test_preFundModules_rejectNonPermit3() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1, _preFundAddCollData());
        vm.prank(address(0xBAD));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1, _preFundRepayData());
    }

    // ── The descriptor gate: only a `legsOut` REFERENCE — the one form whose
    //    amount the core sized to a delivery this module actually received. ──
    function test_preFundModules_rejectNonLegRefDescriptors() public {
        bytes memory literal = abi.encode(uint256(0), BRANCH, troveId, WETH);
        bytes memory balance = abi.encode((uint256(3) << 254) | uint160(WETH), BRANCH, troveId, WETH);

        vm.startPrank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, literal);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, balance);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, literal);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, balance);
        vm.stopPrank();
    }
}
