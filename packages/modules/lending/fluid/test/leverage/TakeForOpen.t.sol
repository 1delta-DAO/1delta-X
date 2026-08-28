// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {Chains, Tokens} from "@coretest/data/LenderRegistry.sol";

import {IFluidVault} from "../../src/interfaces/IFluid.sol";
import {FluidTakeForModule, FluidOperateModule} from "../../src/FluidModules.sol";
import {FluidModulesBase, IFluidVaultFactory721} from "../shared/FluidModulesBase.t.sol";

/// @dev `TAKE_FOR` on Fluid — the protocol that exercises the funding descriptor
/// hardest, because Fluid is where the old constant-`sideAmount` shape hurt most.
///
/// Three things are pinned here, on the mainnet wstETH-USDC T1 vault (id 14):
///
///   1. **Partial fills now work on an EXISTING position.** {FluidOperateModule}
///      rejects every sliced fill ({FullFillGuard}) because its collateral amount
///      lives in `data` and cannot pro-rate — even though Fluid is perfectly happy
///      to be added to repeatedly. With the core sizing `forAmount`, the same open
///      slices cleanly. The contrast is asserted directly: the same partial fill
///      that reverts on the old module succeeds on this one.
///   2. **A fresh open (`nftId == 0`) stays full-fill only** — and that is correct,
///      not a leftover. A fresh `operate` MINTS a position, so N slices make N
///      positions. No amount encoding fixes position identity, which is exactly
///      what {FullFillGuard} exists for.
///   3. **The no-conversion shape**: wallet-funded collateral (balance descriptor)
///      + borrow straight to the maker, paid for by a rising relayer-fee leg. One
///      signature, zero solver capital.
contract FluidTakeForOpenTest is FluidModulesBase {
    /// @dev Same vault the leverage suite uses — vault 4's USDC borrow limit is
    ///      exhausted at the pinned block; 14 has headroom.
    address constant WSTETH_USDC_VAULT = 0x1982CC7b1570C2503282d0A0B41F69b3B28fdcc3;

    FluidTakeForModule takeForModule;
    address WSTETH;

    // Constants rather than locals: the no-conversion test below builds a whole
    // `Order` literal in one frame and goes stack-too-deep otherwise (these
    // packages compile without the optimizer).
    uint256 constant NC_COL0 = 1 ether; //   seed collateral already in the position
    uint256 constant NC_HELD = 1 ether; //   the maker's whole wstETH wallet
    uint256 constant NC_CAP = 2 ether; //    the mandatory signed ceiling
    uint256 constant NC_DEBT = 1_000e6; //   drawn to the maker's wallet
    uint256 constant NC_FEE_FLOOR = 10e6; // relayer-fee auction start
    uint256 constant NC_FEE_CEIL = 30e6; //  auction end
    uint32 constant NC_DURATION = 1000;

    function setUp() public override {
        super.setUp();

        WSTETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH];
        takeForModule = new FluidTakeForModule(address(permit3));

        vm.label(WSTETH_USDC_VAULT, "FluidWstethUsdcVault");
        vm.label(WSTETH, "wstETH");
        vm.label(address(takeForModule), "fluidTakeForModule");

        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        // Strict-ownerOf ⇒ the module needs operator rights to take JIT custody.
        IFluidVaultFactory721(VAULT_FACTORY).setApprovalForAll(address(takeForModule), true);
        vm.stopPrank();
    }

    // ──────────────────── descriptors ────────────────────

    function _forLeg(uint256 j) internal pure returns (uint256) {
        return (uint256(1) << 255) | j;
    }

    function _forBalance(address token) internal pure returns (uint256) {
        return (uint256(3) << 254) | uint160(token);
    }

    // ──────────────────── helpers ────────────────────

    function _openData(uint256 forDesc, uint256 forCap, uint256 nftId, uint256 totalAmount)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            FluidTakeForModule.OpenData({
                forDesc: forDesc,
                forCap: forCap,
                vault: WSTETH_USDC_VAULT,
                factory: VAULT_FACTORY,
                collateralToken: WSTETH,
                nftId: nftId,
                totalAmount: totalAmount
            })
        );
    }

    function _seedWstethPosition(uint256 col0) internal returns (uint256 nftId) {
        deal(WSTETH, maker, col0);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(WSTETH_USDC_VAULT, col0);
        (nftId,,) = IFluidVault(WSTETH_USDC_VAULT).operate(0, int256(col0), 0, address(0));
        vm.stopPrank();
        require(nftId != 0, "seed position failed");
    }

    function _authTakeFor(bytes memory data, uint256 colCap, uint256 debtCap) internal {
        vm.startPrank(maker);
        permit3.approveToken(address(takeForModule), WSTETH, uint160(colCap), 0);
        permit3.approveTaker(address(settlement), address(takeForModule), keccak256(data), uint160(debtCap), 0);
        permit3.approveToken(address(settlement), USDC, uint160(debtCap), 0);
        vm.stopPrank();
    }

    /// @dev Levered order: solver delivers wstETH (`legsOut[0]`), the item supplies
    ///      exactly that leg and borrows USDC to fund `legsIn[0]`.
    function _leveredOrder(uint256 nonce, bytes memory data, uint256 colAdd, uint256 debtAdd)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(takeForModule), debtAdd, address(0), data);
        return _order(maker, nonce, USDC, WSTETH, debtAdd, colAdd, items);
    }

    function _closeAndMeasure(uint256 nftId, uint256 usdcBudget) internal returns (uint256 col, uint256 debt) {
        deal(USDC, maker, usdcBudget);
        vm.startPrank(maker);
        IERC20(USDC).approve(WSTETH_USDC_VAULT, usdcBudget);
        (, int256 colOut, int256 debtOut) =
            IFluidVault(WSTETH_USDC_VAULT).operate(nftId, type(int256).min, type(int256).min, maker);
        vm.stopPrank();
        col = uint256(-colOut);
        debt = uint256(-debtOut);
    }

    // ──────────────── 1. the win: an existing position now slices ────────────────

    function test_existingPosition_partialFills_oneOperatePerSlice() public {
        uint256 col0 = 1 ether;
        uint256 colAdd = 1 ether; //   delivered by the solver, supplied by the item
        uint256 debtAdd = 1_000e6;

        uint256 nftId = _seedWstethPosition(col0);
        deal(WSTETH, solver, colAdd * 2); // ceil headroom on a per-fill-ceil SELL leg
        _approveSolverSide(colAdd * 2, WSTETH);

        bytes memory data = _openData(_forLeg(0), 0, nftId, debtAdd);
        _authTakeFor(data, colAdd + 2, debtAdd);

        Order memory o = _leveredOrder(1, data, colAdd, debtAdd);
        bytes memory sig = _sign(o);

        uint256 makerWsteth = IERC20(WSTETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, debtAdd / 2);
        assertEq(IERC20(WSTETH).balanceOf(maker), makerWsteth, "net zero in the funding token after slice 1");
        assertEq(_ownerOf(nftId), maker, "NFT handed straight back after slice 1");

        vm.prank(solver);
        settlement.fill(o, sig, debtAdd - debtAdd / 2);
        assertEq(IERC20(WSTETH).balanceOf(maker), makerWsteth, "net zero after slice 2");
        assertEq(_ownerOf(nftId), maker, "NFT handed back after slice 2");

        assertEq(IERC20(USDC).balanceOf(solver), debtAdd, "solver received the whole borrow");
        assertEq(IERC20(WSTETH).balanceOf(address(takeForModule)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");

        // ONE position, grown by both slices — not two.
        (uint256 col, uint256 debt) = _closeAndMeasure(nftId, (debtAdd * 101) / 100);
        assertApproxEqRel(col, col0 + colAdd, 1e15, "collateral = seed + both slices");
        assertApproxEqRel(debt, debtAdd, 1e15, "debt = the whole borrow");
    }

    /// The contrast, on the SAME position and the SAME slice: the constant-side-amount
    /// module refuses it. That refusal is what `TAKE_FOR` removes.
    function test_oldOperateModule_refusesTheSameSlice() public {
        uint256 nftId = _seedWstethPosition(1 ether);
        uint256 colAdd = 1 ether;
        uint256 debtAdd = 1_000e6;

        deal(WSTETH, solver, colAdd);
        _approveSolverSide(colAdd, WSTETH);

        bytes memory data = abi.encode(
            FluidOperateModule.OperateData({
                mode: 0,
                vault: WSTETH_USDC_VAULT,
                factory: VAULT_FACTORY,
                fundingToken: WSTETH,
                nftId: nftId,
                sideAmount: colAdd,
                repayCeiling: 0,
                totalAmount: debtAdd
            })
        );
        vm.startPrank(maker);
        permit3.approveToken(address(operateModule), WSTETH, uint160(colAdd), 0);
        permit3.approveTaker(address(settlement), address(operateModule), keccak256(data), uint160(debtAdd), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(operateModule), debtAdd, address(0), data);
        Order memory o = _order(maker, 2, USDC, WSTETH, debtAdd, colAdd, items);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, debtAdd / 2, debtAdd)
        );
        settlement.fill(o, sig, debtAdd / 2);
    }

    // ──────────────── 2. a fresh open still cannot be sliced ────────────────

    /// `nftId == 0` mints a position per `operate`, so N slices would make N
    /// positions. Position identity, not arithmetic — {FullFillGuard} still applies.
    function test_freshOpen_partialFill_reverts() public {
        uint256 colAdd = 1 ether;
        uint256 debtAdd = 1_000e6;

        deal(WSTETH, solver, colAdd);
        _approveSolverSide(colAdd, WSTETH);

        bytes memory data = _openData(_forLeg(0), 0, 0, debtAdd);
        _authTakeFor(data, colAdd + 2, debtAdd);

        Order memory o = _leveredOrder(3, data, colAdd, debtAdd);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, debtAdd / 2, debtAdd)
        );
        settlement.fill(o, sig, debtAdd / 2);
    }

    /// …and a whole fill opens exactly ONE position, owned by the maker.
    function test_freshOpen_fullFill_mintsOnePositionToTheMaker() public {
        uint256 colAdd = 1 ether;
        uint256 debtAdd = 1_000e6;

        deal(WSTETH, solver, colAdd);
        _approveSolverSide(colAdd, WSTETH);

        bytes memory data = _openData(_forLeg(0), 0, 0, debtAdd);
        _authTakeFor(data, colAdd + 2, debtAdd);

        uint256 before_ = IFluidVaultFactory721(VAULT_FACTORY).balanceOf(maker);

        Order memory o = _leveredOrder(4, data, colAdd, debtAdd);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, debtAdd);

        assertEq(IFluidVaultFactory721(VAULT_FACTORY).balanceOf(maker) - before_, 1, "exactly one new position");
        assertEq(IERC20(USDC).balanceOf(solver), debtAdd, "solver received the borrow");
        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "delivered collateral went into the position");
        assertEq(IERC20(WSTETH).balanceOf(address(takeForModule)), 0, "module drained");
    }

    // ──────────────── 3. the no-conversion shape ────────────────

    /// Nothing converts: the maker funds the collateral from their OWN wallet
    /// (balance descriptor), the borrow goes straight to their wallet, and the
    /// relayer is paid by a rising USDC input leg that self-funds out of the borrow.
    /// The solver fronts nothing at all.
    function test_noConversion_depositBalance_andBorrow_withRisingFee() public {
        uint256 nftId = _seedWstethPosition(NC_COL0);
        deal(WSTETH, maker, NC_HELD);
        deal(USDC, maker, 0); // the fee can only come from the borrow

        bytes memory data = _openData(_forBalance(WSTETH), NC_CAP, nftId, NC_DEBT);
        _authTakeFor(data, NC_CAP, NC_DEBT);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(NC_FEE_CEIL), 0);

        Order memory o = _noConversionOrder(data);
        bytes memory sig = _sign(o);

        uint256 solverUsdcBefore = IERC20(USDC).balanceOf(solver);
        vm.warp(block.timestamp + NC_DURATION / 2);
        uint256 fee = NC_FEE_FLOOR + (NC_FEE_CEIL - NC_FEE_FLOOR) / 2;

        vm.prank(solver); // no inventory, no approvals used — the solver only pays gas
        settlement.fill(o, sig, NC_FEE_FLOOR);

        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "wallet swept into the position");
        assertEq(IERC20(USDC).balanceOf(maker), NC_DEBT - fee, "maker keeps the borrow minus the fee");
        assertEq(IERC20(USDC).balanceOf(solver) - solverUsdcBefore, fee, "relayer earned the auction-tick fee");
        assertEq(_ownerOf(nftId), maker, "NFT returned");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");

        (uint256 col,) = _closeAndMeasure(nftId, (NC_DEBT * 101) / 100);
        assertApproxEqRel(col, NC_COL0 + NC_HELD, 1e15, "the whole wallet became collateral");
    }

    /// @dev Own frame: the outputless SELL of docs/relayer-fees.md. `legsOut` is
    ///      EMPTY (nothing converts) and `legsIn[0]` is the rising relayer fee, in
    ///      the borrowed asset — self-funding, because items run before
    ///      `_payInputsToSolver`.
    function _noConversionOrder(bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE_FOR,
            module: address(takeForModule),
            amount: NC_DEBT,
            recipient: maker, // straight to the wallet — never touches Settlement
            data: data
        });
        return Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 5,
            legsIn: PackedEncode.oneLegIn(USDC, NC_FEE_FLOOR, NC_FEE_CEIL),
            legsOut: PackedEncode.legsOut(new LegOut[](0)),
            timing: _packTiming(uint32(block.timestamp), NC_DURATION, 0) | _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: _noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }
}
