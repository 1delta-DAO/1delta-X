// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {Settlement, Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {RiverPreFundModule} from "../../src/RiverPreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IRiverXApp, IRiverTroveManager} from "../../src/interfaces/IRiver.sol";

/// @dev The ONE-SIDED pre-fund composites on River (Satoshi Protocol), against the
/// deployed BNB-Smart-Chain SatoshiXApp diamond (same addresses and fork
/// discipline as test/leverage/Leverage.t.sol): "add-collateral whatever the
/// conversion delivered" / "repay whatever the conversion delivered", with ZERO
/// receive-side TOKEN approvals. The converted output leg is delivered straight
/// to the module (`recipient = module`), the core sizes `forAmount` to exactly
/// that delivery, and the maker's only TOKEN grants are the input-leg approval
/// they had anyway plus a signable taker allowance. The received asset — BTCB on
/// an add, satUSD on a repay — is never approved to anything, anywhere. The one
/// grant that stays is the diamond-wide `setDelegateApproval(module, true)`:
/// a VENUE authorization the deployed diamond enforces on every op, value-in
/// included (the pull-funded modules carry the identical grant).
contract RiverPreFundOneSidedTest is CoreSettlementBase {
    RiverPreFundModule preFund;
    address constant XAPP = 0x07BbC5A83B83a5C440D1CAedBF1081426d0AA4Ec;
    address constant SAT_USD = 0xb4818BB69478730EF4e33Cc068dD94278e2766cB;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    /// @dev The BTCB TroveManager — see the trap notes in Leverage.t.sol.
    address constant TM = 0x5EA26D0A1a9aa6731F9BFB93fCd654cd1C3079Ec;

    uint256 constant MAX_FEE = 0.05e18;

    function setUp() public override {
        _forkBsc();

        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));

        preFund = new RiverPreFundModule(address(permit3), address(settlement));

        WETH = BTCB; // reuse the base helpers' collateral slot for labels/approvals
        vm.label(XAPP, "satoshiXApp");
        vm.label(SAT_USD, "satUSD");
        vm.label(TM, "troveManagerBTCB");
        vm.label(maker, "maker");
        vm.label(solver, "solver");
        }

    function _forkBsc() internal {
        try vm.envString("BSC_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0) {
                vm.createSelectFork(v);
                return;
            }
        } catch {}
        vm.createSelectFork("https://bsc-dataseed1.bnbchain.org");
    }

    // ──────────────────── Helpers ────────────────────

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev Same leg reference, with the op in descriptor bits [244,252).
    function _forLegOp(uint256 index, address token, RiverPreFundModule.Op op) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(op) << 244);
    }

    function _preFundAddCollData() internal pure returns (bytes memory) {
        return abi.encode(_forLeg(0, BTCB), XAPP, TM, BTCB, address(0), address(0));
    }

    function _preFundRepayData() internal pure returns (bytes memory) {
        return abi.encode(_forLegOp(0, SAT_USD, RiverPreFundModule.Op.Repay), XAPP, TM, SAT_USD, address(0), address(0));
    }

    /// @dev Address one output leg to `to` (the pre-fund shape).
    function _routeLegOut(Order memory o, address token, uint256 start, uint256 end, address to) internal pure {
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(token, start, end, to);
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    /// @dev Open the maker's trove directly. `keepSatUsd = false` parks the mint
    ///      away so sweep-delta assertions start from a clean maker balance.
    function _openTroveDirect(uint256 coll, uint256 debt, bool keepSatUsd) internal {
        deal(BTCB, maker, coll);
        vm.startPrank(maker);
        IERC20(BTCB).approve(XAPP, coll);
        IRiverXApp(XAPP).openTrove(TM, maker, MAX_FEE, coll, debt, address(0), address(0));
        if (!keepSatUsd) IERC20(SAT_USD).transfer(address(0xD1ED), IERC20(SAT_USD).balanceOf(maker));
        vm.stopPrank();
    }

    function _troveState() internal view returns (uint256 debt, uint256 coll) {
        (debt, coll,,) = IRiverTroveManager(TM).getEntireDebtAndColl(maker);
    }

    // ── SWAP & ADD-COLLATERAL. The maker converts satUSD (minted at open — the
    //    asset they hold and approve as the input leg) into BTCB trove
    //    collateral. BTCB — the asset they RECEIVE — has no ERC20 approval to
    //    Permit3 and no Permit3 book entry: the receive side's TOKEN grants are
    //    strictly empty; only the diamond's delegate authorization stands. ──
    function test_preFundAddColl_swapAndDeposit_zeroReceiveSideTokenApprovals() public {
        uint256 satIn = 500e18;
        uint256 btcbOut = 0.005e18;
        _openTroveDirect(2 ether, 2000e18, true); //  maker keeps the minted satUSD

        _approveMakerToSettlement(SAT_USD, satIn); //  the input leg — the ONE token approval
        deal(BTCB, solver, btcbOut);
        _approveSolverSide(btcbOut, BTCB);

        bytes memory data = _preFundAddCollData();
        vm.startPrank(maker);
        // The VENUE authorization — enforced by the deployed diamond on value-in
        // ops too; a token approval it is not.
        IRiverXApp(XAPP).setDelegateApproval(address(preFund), true);
        vm.stopPrank();

        // Prove the receive side's token grants are empty BEFORE the fill.
        assertEq(IERC20(BTCB).allowance(maker, address(permit3)), 0, "BTCB has no ERC20 approval to Permit3");
        (uint160 amt,) = permit3.tokenAllowance(maker, address(preFund), BTCB);
        assertEq(amt, 0, "BTCB has no Permit3 book entry either");

        Item[] memory items = new Item[](1);
        // `amount` is the PACING total (the anchor) — this module moves nothing out.
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 601, SAT_USD, BTCB, satIn, btcbOut, items);
        _routeLegOut(o, BTCB, btcbOut, 0, address(preFund));
        bytes memory sig = _sign(o);

        (, uint256 collBefore) = _troveState();
        uint256 makerBtcb = IERC20(BTCB).balanceOf(maker);
        uint256 solverSat = IERC20(SAT_USD).balanceOf(solver);

        vm.prank(solver);
        settlement.fill(o, sig, satIn);

        (, uint256 collAfter) = _troveState();
        assertEq(collAfter - collBefore, btcbOut, "the delivered leg became trove collateral, exactly");
        assertEq(IERC20(BTCB).balanceOf(maker), makerBtcb, "the maker's wallet never saw the BTCB");
        assertEq(IERC20(BTCB).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(SAT_USD).balanceOf(solver) - solverSat, satIn, "solver received the input leg");
    }

    // ── SWAP & REPAY. The maker converts BTCB into retiring part of their
    //    satUSD debt. satUSD — the debt token — is the canonical never-approved
    //    asset: no ERC20 approval to Permit3, no Permit3 book entry, asserted
    //    before the fill. (The cap-at-debt + surplus-sweep branch cannot run on
    //    the live venue — a CDP repay must leave the minimum net debt standing —
    //    so it is pinned against a mock in test/unit/RiverPreFundRepayCap.t.sol.) ──
    function test_preFundRepay_partialRepay_zeroReceiveSideTokenApprovals() public {
        uint256 btcbIn = 0.005e18;
        uint256 satOut = 500e18;
        _openTroveDirect(2 ether, 3000e18, false); //  mint parked away

        deal(BTCB, maker, btcbIn);
        _approveMakerToSettlement(BTCB, btcbIn); //  the input leg — already-held asset
        deal(SAT_USD, solver, satOut);
        _approveSolverSide(satOut, SAT_USD);

        bytes memory data = _preFundRepayData();
        vm.startPrank(maker);
        IRiverXApp(XAPP).setDelegateApproval(address(preFund), true); //  the venue grant
        vm.stopPrank();
        assertEq(IERC20(SAT_USD).allowance(maker, address(permit3)), 0, "the debt token is approved nowhere");
        (uint160 amt,) = permit3.tokenAllowance(maker, address(preFund), SAT_USD);
        assertEq(amt, 0, "the debt token has no Permit3 book entry either");

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data); //  pacing amount
        Order memory o = _order(maker, 602, BTCB, SAT_USD, btcbIn, satOut, items);
        _routeLegOut(o, SAT_USD, satOut, 0, address(preFund));
        bytes memory sig = _sign(o);

        (uint256 debtBefore,) = _troveState();
        uint256 makerSat = IERC20(SAT_USD).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, btcbIn);

        (uint256 debtAfter,) = _troveState();
        assertEq(debtBefore - debtAfter, satOut, "the delivered leg retired exactly that much debt");
        assertEq(IERC20(SAT_USD).balanceOf(maker), makerSat, "no surplus: nothing swept, nothing pulled");
        assertEq(IERC20(SAT_USD).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(BTCB).balanceOf(solver), btcbIn, "solver received the input leg");
    }

    // ── Delegation is (still) the wall: the diamond gates value-in too. ──
    function test_preFundAddColl_withoutDelegate_reverts() public {
        uint256 satIn = 500e18;
        uint256 btcbOut = 0.005e18;
        _openTroveDirect(2 ether, 2000e18, true);

        _approveMakerToSettlement(SAT_USD, satIn);
        deal(BTCB, solver, btcbOut);
        _approveSolverSide(btcbOut, BTCB);

        bytes memory data = _preFundAddCollData();
        vm.prank(maker);
        // NO setDelegateApproval.

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 603, SAT_USD, BTCB, satIn, btcbOut, items);
        _routeLegOut(o, BTCB, btcbOut, 0, address(preFund));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, satIn);

        (, uint256 coll) = _troveState();
        assertEq(coll, 2 ether, "no collateral added");
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
        bytes memory literal = abi.encode(uint256(0), XAPP, TM, BTCB, address(0), address(0));
        bytes memory balance = abi.encode((uint256(3) << 254) | uint160(BTCB), XAPP, TM, BTCB, address(0), address(0));

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
