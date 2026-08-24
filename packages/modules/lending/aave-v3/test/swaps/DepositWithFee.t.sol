// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, OrderSide, Validator, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {FeeTransferModule} from "@modules/maker/src/FeeTransferModule.sol";

import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Pure gasless deposit + rising relayer fee: the mirror of the
/// withdraw-with-fee exit. The maker wants WETH deposited into Aave without
/// sending a transaction; there is NO conversion leg to price a filler's
/// compensation into, so the order carries a dedicated fee leg that dutch-RISES
/// (`startAmountIn < endAmountIn`) until filling it covers a relayer's
/// gas + margin — auction-discovered, gas-bump aware, zero filler capital
/// (the relayer fronts nothing, it only earns the fee leg):
///
///   items    = MAKE deposit D WETH        (the real action; module pulls maker WETH)
///   tokenIn  = WETH, F0 → FMAX rising     (the relayer fee, maker pays)
///   tokenOut = —                          (empty; nothing is delivered back)
///
/// Production deposits should be full-fill-only (`minFillAnchor = anchor`);
/// the partial-fill test below only pins the pro-rata math.
contract DepositWithFeeTest is AaveModulesBase {
    uint256 constant DEPOSIT = 1 ether; //  the deposited principal
    uint256 constant F0 = 1e15; //          fee floor (auction start, best for maker)
    uint256 constant FMAX = 3e15; //        fee ceiling (auction end, worst for maker)
    uint32 constant DURATION = 1000;

    function _buildDepositOrder(uint256 nonce) internal view returns (Order memory order) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: DEPOSIT,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, WETH)
        });
        order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: _legsIn1Rising(WETH, F0, FMAX),
            legsOut: PackedEncode.legsOut(new LegOut[](0)),
            timing: _packTiming(uint32(block.timestamp), uint32(DURATION), 0) | _expiryBits(block.timestamp + 1 hours),
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

    function _approveMakerDepositSide() internal {
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        // Deposit module pulls the principal from the maker during MAKE.
        permit3.approveToken(address(depositModule), WETH, uint160(DEPOSIT), 0);
        // Settlement pulls the (risen) fee leg — cap at the auction ceiling.
        permit3.approveToken(address(settlement), WETH, uint160(FMAX), 0);
        vm.stopPrank();
    }

    function test_deposit_withRisingFee_aaveV3() public {
        deal(WETH, maker, DEPOSIT + FMAX);
        _approveMakerDepositSide();

        Order memory order = _buildDepositOrder(21);
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);

        vm.warp(block.timestamp + DURATION / 2); // bump = 5000
        uint256 fee = F0 + (FMAX - F0) / 2; //      2e15

        vm.prank(solver);
        settlement.fill(order, sig, F0); //         anchor = the fee floor

        // The deposit landed in full; the relayer earned exactly the risen tick.
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, DEPOSIT, 2, "maker aWETH minted");
        assertEq(IERC20(WETH).balanceOf(solver), fee, "relayer earned the auction-tick fee");
        assertEq(IERC20(WETH).balanceOf(maker), FMAX - fee, "maker paid principal + risen fee");

        // Nothing stranded.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "module WETH drained");
    }

    /// @dev Fee widens with basefee via the shared gas bump — the knob that keeps
    /// a deposit fillable in a gas spike without a fat static fee.
    function test_deposit_withRisingFee_gasBump_aaveV3() public {
        deal(WETH, maker, DEPOSIT + FMAX);
        _approveMakerDepositSide();

        Order memory order = _buildDepositOrder(22);
        _setDecayStart(order, 0);
        _setDecayDuration(order, 0); //   no time decay — gas bump only
        order.params = (order.params & ~(uint256(0xffff) << 16)) | (uint256(5_000) << 16); //  up to half the leg span from gas alone
        order.params = (order.params & ~(uint256(type(uint64).max) << 32)) | (uint256(10 gwei) << 32);
        bytes memory sig = _sign(order);

        vm.fee(2 gwei); // gasAdd = 5000 * 2/10 = 1000 bps
        uint256 fee = F0 + ((FMAX - F0) * 1_000) / 10_000; // 1.2e15

        vm.prank(solver);
        settlement.fill(order, sig, F0);

        assertEq(IERC20(WETH).balanceOf(solver), fee, "fee widened by the gas bump");
        assertEq(IERC20(WETH).balanceOf(maker), FMAX - fee, "maker paid the gas-indexed fee");
    }

    /// @dev Two half fills: deposit slices and the fee leg scale by the same fill
    /// fraction, each fee slice priced at its own tick.
    function test_deposit_withRisingFee_partialFills_aaveV3() public {
        deal(WETH, maker, DEPOSIT + FMAX);
        _approveMakerDepositSide();

        Order memory order = _buildDepositOrder(23);
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);

        // First half at the floor tick.
        vm.prank(solver);
        settlement.fill(order, sig, F0 / 2);
        uint256 fee1 = F0 / 2; // (F0/2 · F0) / F0
        assertEq(IERC20(WETH).balanceOf(solver), fee1, "first slice at floor tick");
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, DEPOSIT / 2, 2, "half the deposit landed");

        // Second half mid-decay. Re-snapshot after the warp — aWETH rebases, so
        // the first half accrues interest over the 500s and would skew a
        // whole-order delta.
        vm.warp(block.timestamp + DURATION / 2);
        uint256 makerAWethMid = IERC20(aWETH).balanceOf(maker);
        vm.prank(solver);
        settlement.fill(order, sig, F0 - F0 / 2);
        uint256 fee2 = ((F0 - F0 / 2) * (F0 + (FMAX - F0) / 2)) / F0; // risen tick
        assertEq(IERC20(WETH).balanceOf(solver), fee1 + fee2, "second slice at the risen tick");
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethMid, DEPOSIT / 2, 2, "second half landed");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
    }

    /// @dev The FULL integrator shape: one outputless order paying BOTH fee
    /// actors — the originator an absolute, named-recipient fee (via
    /// {FeeTransferModule}, the fee ITEM) and the relayer the auction-discovered
    /// rising leg. This is the entry-side counterpart of the exit-margin flow in
    /// {WithdrawWithFeeTest}, for outputless shapes with no tokenOut to carry a fee leg.
    function test_deposit_withRisingFee_andOriginatorFeeItem_aaveV3() public {
        FeeTransferModule feeModule = new FeeTransferModule(address(permit3), address(settlement));
        address originator = address(0x0F0F);
        uint256 origFee = 5e14; // 0.0005 WETH — absolute, priced off-chain at signing

        deal(WETH, maker, DEPOSIT + origFee + FMAX);
        _approveMakerDepositSide();
        vm.prank(maker);
        permit3.approveToken(address(feeModule), WETH, uint160(origFee), 0);

        Order memory order = _buildDepositOrder(24);
        Item[] memory items = new Item[](2);
        // The deposit item (rebuilt: `order.items` is now a packed blob, not Item[]).
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: DEPOSIT,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, WETH)
        });
        items[1] = Item({
            op: ItemOp.MAKE,
            module: address(feeModule),
            amount: origFee,
            recipient: address(0),
            data: abi.encode(WETH, originator)
        });
        order.items = PackedEncode.items(items);
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 relayerFee = F0 + (FMAX - F0) / 2;

        vm.prank(solver);
        settlement.fill(order, sig, F0);

        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, DEPOSIT, 2, "deposit landed");
        assertEq(IERC20(WETH).balanceOf(originator), origFee, "originator got the absolute fee");
        assertEq(IERC20(WETH).balanceOf(solver), relayerFee, "relayer got the auction-tick fee");
        assertEq(IERC20(WETH).balanceOf(maker), FMAX - relayerFee, "maker paid deposit + both fees");
        assertEq(IERC20(WETH).balanceOf(address(feeModule)), 0, "fee module never holds funds");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
    }
}
