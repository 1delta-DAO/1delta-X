// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {ISpokeV4} from "../../src/interfaces/IAaveV4.sol";
import {AaveV4PreFundModule} from "../../src/AaveV4PreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {AaveV4ModulesBase} from "../shared/AaveV4ModulesBase.t.sol";

/// @dev The ONE-SIDED pre-fund composites against the live mainnet Aave v4
/// Hub/Spoke: "deposit whatever the conversion delivered" / "repay whatever the
/// conversion delivered", with ZERO receive-side approvals. The converted output
/// leg is delivered straight to the module (`recipient = module`), the core
/// sizes `forAmount` to exactly that delivery, and this module funds the giver
/// PM from its own balance. The maker's only grants are the input-leg approval
/// they had anyway, a signable taker allowance, and the ONE piece of v4-native
/// position state every giver-PM op needs regardless of funding —
/// `spoke.setUserPositionManager(giverPM, true)`. The received asset itself is
/// never approved to anything, anywhere. Mirrors the aave-v3 `PreFundOneSidedTest`
/// shapes on the v4 venue.
contract PreFundOneSidedV4Test is AaveV4ModulesBase {
    AaveV4PreFundModule preFund;

    uint256 constant USDC_IN = 1_500e6;
    uint256 constant WETH_OUT = 1 ether;

    function setUp() public override {
        super.setUp();
        preFund = new AaveV4PreFundModule(address(permit3), address(settlement));
        }

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev Same leg reference, with the op in descriptor bits [244,252).
    function _forLegOp(uint256 index, address token, AaveV4PreFundModule.Op op) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(op) << 244);
    }

    /// @dev Address one output leg to `to` (the pre-fund shape).
    function _routeLegOut(Order memory o, address token, uint256 start, uint256 end, address to) internal pure {
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(token, start, end, to);
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    // ── SWAP & DEPOSIT. The maker converts USDC (the one asset they hold and had
    //    approved anyway) into a WETH v4 supply. WETH — the asset they RECEIVE —
    //    has its ERC20 approval to Permit3 revoked outright and no Permit3 token
    //    allowance to anything: the receive-side TOKEN surface is strictly empty.
    //    The giver-PM approval on the spoke is position state, not a token grant,
    //    and the pull-funded MAKE deposit needs it just the same. ──
    function test_preFundDeposit_swapAndDeposit_zeroReceiveSideApprovals_aaveV4() public {
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN); //  the input leg — the ONE token approval
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);

        bytes memory data = abi.encode(_forLeg(0, WETH), MAIN_SPOKE, GIVER_PM, wethReserveId, WETH);
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(GIVER_PM, true); //  position state, not a token grant
        IERC20(WETH).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        // Prove the receive side is empty BEFORE the fill, not just unused.
        assertEq(IERC20(WETH).allowance(maker, address(permit3)), 0, "receive asset has no ERC20 approval");

        Item[] memory items = new Item[](1);
        // `amount` is the PACING total (the anchor) — this module moves nothing out.
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 501, USDC, WETH, USDC_IN, WETH_OUT, items);
        _routeLegOut(o, WETH, WETH_OUT, 0, address(preFund));
        bytes memory sig = _sign(o);

        // The preflight accepts the module-addressed leg.
        (bool ok, string memory why) = lens.validateOrder(o);
        assertTrue(ok, why);

        uint256 suppliedBefore = ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker);
        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertApproxEqAbs(
            ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker) - suppliedBefore,
            WETH_OUT,
            2,
            "the delivered leg became supplied balance"
        );
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "the maker's wallet never saw the WETH");
        assertEq(IERC20(WETH).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "solver received the input leg");
    }

    // ── SWAP & REPAY. The maker converts WETH into retiring their USDC debt. The
    //    debt asset is the canonical never-approved token: the maker's USDC ERC20
    //    approval to Permit3 is revoked to prove the point. Over-delivery (1500
    //    delivered vs 1000 owed) is swept to the maker — the surplus is theirs. ──
    function test_preFundRepay_capsAtDebt_andSweepsSurplusToMaker_aaveV4() public {
        uint256 debt = 1_000e6;
        // Seeds 10 WETH collateral + `debt` USDC of v4 debt, keeps 1 WETH in the
        // wallet for the input leg, and approves the giver PM on the spoke.
        _openV4UsdcDebt(debt);

        _approveMakerToSettlement(WETH, 1 ether); //  the input leg — already-held asset
        deal(USDC, solver, USDC_IN);
        _approveSolverSide(USDC_IN, USDC);

        bytes memory data = abi.encode(_forLegOp(0, USDC, AaveV4PreFundModule.Op.Repay), MAIN_SPOKE, GIVER_PM, usdcReserveId, USDC);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        assertEq(IERC20(USDC).allowance(maker, address(permit3)), 0, "debt asset has no ERC20 approval");

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 502, WETH, USDC, 1 ether, USDC_IN, items);
        _routeLegOut(o, USDC, USDC_IN, 0, address(preFund));
        bytes memory sig = _sign(o);

        uint256 debtBefore = ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker);
        assertGt(debtBefore, 0, "pre: maker should have debt");
        uint256 makerUsdc = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, 1 ether);

        assertEq(ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker), 0, "the debt is retired in full");
        assertApproxEqAbs(
            IERC20(USDC).balanceOf(maker) - makerUsdc, USDC_IN - debtBefore, 2, "the surplus was swept to the maker"
        );
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(WETH).balanceOf(solver), 1 ether, "solver received the input leg");
    }
}
