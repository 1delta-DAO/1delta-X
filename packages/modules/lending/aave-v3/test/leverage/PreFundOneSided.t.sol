// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Chains, Tokens} from "@coretest/data/LenderRegistry.sol";

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3.sol";
import {AaveV3CreditModule} from "../../src/AaveV3CreditModule.sol";
import {AaveV3PreFundModule} from "../../src/AaveV3PreFundModules.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev The slice of the Aave debt token's EIP-712 surface the delegation-with-sig
///      signer needs.
interface IDebtTokenSig {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(address) external view returns (uint256);
}

/// @dev The ONE-SIDED pre-fund composites: "deposit whatever the conversion
/// delivered" / "repay whatever the conversion delivered", with ZERO receive-side
/// approvals. The converted output leg is delivered straight to the module
/// (`recipient = module`), the core sizes `forAmount` to exactly that delivery,
/// and the maker's only grants are the input-leg approval they had anyway plus a
/// signable taker allowance. The received asset — the aToken underlying on a
/// deposit, the DEBT token's underlying on a repay — is never approved to
/// anything, anywhere.
contract PreFundOneSidedTest is AaveModulesBase {
    AaveV3PreFundModule preFund;

    uint256 constant USDC_IN = 1_500e6;
    uint256 constant WETH_OUT = 1 ether;

    function setUp() public override {
        super.setUp();
        preFund = new AaveV3PreFundModule(address(permit3), address(settlement));
        vm.label(address(preFund), "aaveV3PreFundModule");
    }

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    ///      Bits [16:176) carry the funding TOKEN: the core requires
    ///      `legsOut[index].token` to equal it and `PreFundGuard.floorOf` requires the
    ///      module's own decoded asset to equal it, so there is ONE copy of it.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1). Op 0 = Supply.
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev The repay op, in descriptor bits [244,252) — see {PreFundModuleBase._preFundOp}.
    function _forLegRepay(uint256 index, address token) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(AaveV3PreFundModule.Op.Repay) << 244);
    }

    /// @dev Address one output leg to `to` (the pre-fund shape), optionally decaying.
    function _routeLegOut(Order memory o, address token, uint256 start, uint256 end, address to) internal pure {
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(token, start, end, to);
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    // ── SWAP & DEPOSIT. The maker converts USDC (the one asset they hold and had
    //    approved anyway) into a WETH Aave deposit. WETH — the asset they RECEIVE —
    //    has its ERC20 approval to Permit3 revoked outright and no Permit3 token
    //    allowance to anything: the receive side is strictly empty. ──
    function test_preFundDeposit_swapAndDeposit_zeroReceiveSideApprovals() public {
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN); //  the input leg — the ONE approval
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);

        bytes memory data = abi.encode(_forLeg(0, WETH), AAVE_POOL, WETH);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        // `amount` is the PACING total (the anchor) — this module moves nothing out.
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data); // amount unread: the core sizes it
        Order memory o = _order(maker, 301, USDC, WETH, USDC_IN, WETH_OUT, items);
        _routeLegOut(o, WETH, WETH_OUT, 0, address(preFund));
        bytes memory sig = _sign(o);

        // The preflight accepts the module-addressed leg.
        (bool ok, string memory why) = lens.validateOrder(o);
        assertTrue(ok, why);

        uint256 aBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - aBefore, WETH_OUT, 2, "the delivered leg became collateral");
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "the maker's wallet never saw the WETH");
        assertEq(IERC20(WETH).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "solver received the input leg");
    }

    // ── The auctioned version, in partial fills: a decaying WETH leg filled
    //    mid-decay deposits exactly the clearing amount — the combination no
    //    ratio-in-data or wallet-routed MAKE can express without either an
    //    approval surface or a mis-sized leg. ──
    function test_preFundDeposit_decayedLeg_partialFills_depositExactlyTheClearing() public {
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN);
        deal(WETH, solver, WETH_OUT * 2);
        _approveSolverSide(WETH_OUT * 2, WETH);
        uint256 solverBefore = IERC20(WETH).balanceOf(solver);

        bytes memory data = abi.encode(_forLeg(0, WETH), AAVE_POOL, WETH);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data); // amount unread: the core sizes it
        Order memory o = _order(maker, 302, USDC, WETH, USDC_IN, WETH_OUT, items);
        _routeLegOut(o, WETH, WETH_OUT, 0.9 ether, address(preFund)); //  1.0 → 0.9
        o.timing = _packTiming(uint32(block.timestamp), 1000, 0) | _expiryBits(block.timestamp + 1 hours);
        bytes memory sig = _sign(o);

        uint256 aBefore = IERC20(aWETH).balanceOf(maker);

        vm.warp(block.timestamp + 500); //  bump = 5000 ⇒ the leg clears at 0.95
        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN / 3);
        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN - USDC_IN / 3);

        uint256 delivered = solverBefore - IERC20(WETH).balanceOf(solver);
        assertApproxEqAbs(delivered, 0.95 ether, 2, "the auction cleared mid-decay");
        assertApproxEqAbs(
            IERC20(aWETH).balanceOf(maker) - aBefore, delivered, 2, "every delivered wei was deposited"
        );
        assertEq(IERC20(WETH).balanceOf(address(preFund)), 0, "module drained across slices");
    }

    // ── SWAP & REPAY. The maker converts WETH into retiring their USDC debt. The
    //    debt asset is the canonical never-approved token: the maker's USDC ERC20
    //    approval to Permit3 is revoked to prove the point. Over-delivery (1500
    //    delivered vs 1000 owed) is swept to the maker — the surplus is theirs. ──
    function test_preFundRepay_capsAtDebt_andSweepsSurplusToMaker() public {
        // Seed the position: 10 WETH collateral, 1000 USDC debt.
        uint256 debt = 1_000e6;
        deal(WETH, maker, 10 ether + 1 ether);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, 10 ether);
        IAaveV3Pool(AAVE_POOL).supply(WETH, 10 ether, maker, 0);
        IAaveV3Pool(AAVE_POOL).borrow(USDC, debt, 2, 0, maker);
        vm.stopPrank();

        _approveMakerToSettlement(WETH, 1 ether); //  the input leg — already-held asset
        deal(USDC, solver, USDC_IN);
        _approveSolverSide(USDC_IN, USDC);

        bytes memory data = abi.encode(_forLegRepay(0, USDC), AAVE_POOL, USDC, uint256(2), usdcDebtToken);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 303, WETH, USDC, 1 ether, USDC_IN, items);
        _routeLegOut(o, USDC, USDC_IN, 0, address(preFund));
        bytes memory sig = _sign(o);

        uint256 makerUsdc = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, 1 ether);

        assertEq(IERC20(usdcDebtToken).balanceOf(maker), 0, "the debt is retired in full");
        assertEq(IERC20(USDC).balanceOf(maker), makerUsdc + (USDC_IN - debt), "the surplus was swept to the maker");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(WETH).balanceOf(solver), 1 ether, "solver received the input leg");
    }

    // ── THE FULL MINIMAL-APPROVAL CLAIM, END TO END. Cross-asset open in THREE
    //    currencies — equity in X (DAI), borrow A (USDC), collateral B (WETH) —
    //    with ONE maker signature and exactly ONE standing approval: X to Permit3.
    //    Everything else rides that signature: the Permit3 token allowance on X,
    //    the taker allowance for the borrow (both in the witness-bound PermitBatch)
    //    and Aave's credit delegation (an EIP-712 sig replayed in-call from the
    //    item's own data). A and B have their ERC20 approvals to Permit3 REVOKED
    //    and hold no Permit3 book entries — asserted before the fill. ──
    function test_oneSignature_crossAssetOpen_XtoAB_onlyXApproved() public {
        address DAI = tokens[Chains.ETHEREUM_MAINNET][Tokens.DAI];
        uint256 daiIn = 2_000e18; //  X — the maker's equity, sold to the solver
        uint256 borrow = 1_000e6; //  A — drawn against the new collateral
        AaveV3CreditModule lever = new AaveV3CreditModule(address(permit3), address(settlement));

        // The item data: fused base layout + the delegation-with-sig block, signed
        // against the REAL debt token's EIP-712 domain — no on-chain
        // `approveDelegation` anywhere in this test.
        bytes memory data;
        {
            uint256 deadline = block.timestamp + 1 hours;
            bytes32 structHash = keccak256(
                abi.encode(
                    keccak256("DelegationWithSig(address delegatee,uint256 value,uint256 nonce,uint256 deadline)"),
                    address(lever),
                    borrow,
                    IDebtTokenSig(usdcDebtToken).nonces(maker),
                    deadline
                )
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(
                makerPk,
                keccak256(abi.encodePacked("\x19\x01", IDebtTokenSig(usdcDebtToken).DOMAIN_SEPARATOR(), structHash))
            );
            data = abi.encode(
                _forLeg(0, WETH) | DESC_OP_LEVERAGE,
                uint256(0),
                AAVE_POOL,
                USDC,
                uint256(2),
                WETH,
                usdcDebtToken,
                deadline,
                v,
                r,
                s
            );
        }

        // The maker's world: they hold X, and X is their ONE approval.
        deal(DAI, maker, daiIn);
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        IERC20(WETH).approve(address(permit3), 0); //  B: stripped
        IERC20(USDC).approve(address(permit3), 0); //  A: stripped
        vm.stopPrank();

        // Order: sell X, receive the borrowed A alongside (both input legs to the
        // solver), collateral B delivered straight to the module.
        Order memory o;
        {
            Item[] memory items = new Item[](1);
            items[0] = Item(ItemOp.TAKE_FOR, address(lever), borrow, address(0), data);
            LegIn[] memory legsIn = new LegIn[](2);
            legsIn[0] = LegIn(DAI, daiIn, 0); //   X, pulled from the maker's wallet
            legsIn[1] = LegIn(USDC, borrow, 0); // A, funded by the borrow proceeds
            o = _order(maker, 304, DAI, WETH, daiIn, WETH_OUT, items);
            o.legsIn = PackedEncode.legsIn(legsIn);
            _routeLegOut(o, WETH, WETH_OUT, 0, address(lever));
        }

        // ONE signature: the witness-bound PermitBatch carries the X token
        // allowance AND the borrow's taker allowance, bound to this order's hash.
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(address(settlement), DAI, uint160(daiIn), uint48(_expiry(o)));
        IPermit3.PermitBatch memory batch =
            _buildBatch(tp, _takerPermits1(address(settlement), address(lever), keccak256(data), borrow), 0, _expiry(o));
        bytes memory sig = _signPermitWitness(batch, _hashOrder(o));

        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);

        // Prove the receive side is empty BEFORE the fill, not just unused.
        assertEq(IERC20(WETH).allowance(maker, address(permit3)), 0, "B has no ERC20 approval");
        assertEq(IERC20(USDC).allowance(maker, address(permit3)), 0, "A has no ERC20 approval");
        (uint160 amt,) = permit3.tokenAllowance(maker, address(lever), WETH);
        assertEq(amt, 0, "B has no Permit3 book entry either");

        uint256 aBefore = IERC20(aWETH).balanceOf(maker);
        uint256 dBefore = IERC20(usdcDebtToken).balanceOf(maker);

        vm.prank(solver);
        settlement.fillWithPermit(o, batch, sig, daiIn);

        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - aBefore, WETH_OUT, 2, "B became collateral in full");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - dBefore, borrow, 2, "A was drawn");
        assertEq(IERC20(DAI).balanceOf(maker), 0, "X was sold");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "B never transited the wallet");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "A went to the solver, not the wallet");
        assertEq(IERC20(DAI).balanceOf(solver), daiIn, "solver received X");
        assertEq(IERC20(USDC).balanceOf(solver), borrow, "solver received A");
        assertEq(IERC20(WETH).balanceOf(address(lever)), 0, "module drained");
    }

    // ── DELEVERAGE, composed from proven parts: TAKE(withdraw) funds the input
    //    leg, the solver converts, and the pre-fund-repay retires the debt from the
    //    delivered leg. The maker's approvals touch ONLY what they already own —
    //    the aToken (their position). The underlying WETH and the debt-side USDC
    //    have their ERC20 approvals to Permit3 revoked outright: the withdrawn
    //    funds flow protocol → Settlement → solver, the repay funds flow
    //    solver → module → protocol, and neither ever needs the maker's wallet. ──
    function test_preFundDeleverage_onlyThePositionAssetIsApproved() public {
        uint256 debt = 1_000e6;
        uint256 usdcOut = 1_100e6; //  delivered conversion output — overshoots the debt
        deal(WETH, maker, 10 ether);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, 10 ether);
        IAaveV3Pool(AAVE_POOL).supply(WETH, 10 ether, maker, 0);
        IAaveV3Pool(AAVE_POOL).borrow(USDC, debt, 2, 0, maker);
        vm.stopPrank();

        bytes memory dataW = abi.encode(AAVE_POOL, WETH, aWETH);
        bytes memory dataR = abi.encode(_forLegRepay(0, USDC), AAVE_POOL, USDC, uint256(2), usdcDebtToken);

        vm.startPrank(maker);
        // The position asset — the ONE thing the maker approves, and they own it.
        IERC20(aWETH).approve(address(withdrawModule), type(uint256).max);
        permit3.approveTaker(
            address(settlement), address(withdrawModule), keccak256(dataW), uint160(1 ether), uint48(block.timestamp + 1 hours)
        );
        // Both flow-through assets: stripped bare.
        IERC20(WETH).approve(address(permit3), 0);
        IERC20(USDC).approve(address(permit3), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.TAKE, address(withdrawModule), 1 ether, address(0), dataW);
        items[1] = Item(ItemOp.MAKE, address(preFund), 0, address(0), dataR); //  core-sized, no pacing amount
        Order memory o = _order(maker, 305, WETH, USDC, 1 ether, usdcOut, items);
        _routeLegOut(o, USDC, usdcOut, 0, address(preFund));
        bytes memory sig = _sign(o);

        deal(USDC, solver, usdcOut);
        _approveSolverSide(usdcOut, USDC);

        uint256 aBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerUsdc = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, 1 ether);

        assertEq(IERC20(usdcDebtToken).balanceOf(maker), 0, "debt retired");
        assertApproxEqAbs(aBefore - IERC20(aWETH).balanceOf(maker), 1 ether, 2, "one WETH of collateral withdrawn");
        assertEq(IERC20(USDC).balanceOf(maker), makerUsdc + (usdcOut - debt), "repay surplus swept to the maker");
        assertEq(IERC20(WETH).balanceOf(solver), 1 ether, "solver received the withdrawn WETH");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "the withdrawn WETH never transited the wallet");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement drained");
    }
}
