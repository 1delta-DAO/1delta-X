// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

import {ITakerPositionManager, ISpokeV4} from "../../src/interfaces/IAaveV4.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {AaveV4ModulesBase} from "../shared/AaveV4ModulesBase.t.sol";

interface ITakerPMSigView {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function WITHDRAW_PERMIT_TYPEHASH() external view returns (bytes32);
    function BORROW_PERMIT_TYPEHASH() external view returns (bytes32);
    function nonces(address owner, uint192 key) external view returns (uint256);
}

/// @dev 2026-09-30 audit L-CV2-6: the TakerPositionManager's per-reserve grant is
///      signable (`approveWithdrawWithSig` / `approveBorrowWithSig`), but the v4
///      taker modules had no in-call replay, so every v4 withdraw/borrow order cost
///      the maker an on-chain `approveWithdraw` / `approveBorrow` transaction. The
///      modules now replay an optional signed tail ({AaveV4TakerPermit}). Each test
///      grants NOTHING on the TakerPM on chain; on the original code the tail was
///      ignored and the fill reverted `InsufficientWithdrawAllowance` /
///      `InsufficientBorrowAllowance`.
contract AaveV4TakerPermitReplayTest is AaveV4ModulesBase {
    function _signTakerPermit(bool borrow, uint256 reserveId, address spender, uint256 amount, uint256 deadline)
        internal
        view
        returns (bytes memory tail)
    {
        ITakerPMSigView pm = ITakerPMSigView(TAKER_PM);
        uint256 nonce = pm.nonces(maker, 0);
        bytes32 typehash = borrow ? pm.BORROW_PERMIT_TYPEHASH() : pm.WITHDRAW_PERMIT_TYPEHASH();
        bytes32 structHash =
            keccak256(abi.encode(typehash, MAIN_SPOKE, reserveId, maker, spender, amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", pm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        tail = abi.encode(amount, nonce, deadline, abi.encodePacked(r, s, v));
    }

    /// @dev Spoke-wide PM approval + Permit3 taker gate + solver side; NO TakerPM grant.
    function _withdrawSetup(uint256 wethIn, uint256 usdcOut, bytes32 ref) internal {
        deal(USDC, solver, usdcOut);
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(TAKER_PM, true);
        permit3.approveTaker(address(settlement), address(withdrawModule), ref, uint160(wethIn), 0);
        vm.stopPrank();
        _approveSolverSide(usdcOut, USDC);
    }

    function _fillWithdraw(uint256 wethIn, uint256 usdcOut, bytes memory takerData) internal {
        Order memory order = _buildV4WithdrawOrder(wethIn, usdcOut, takerData);
        bytes memory sig = _sign(order);
        vm.prank(solver);
        settlement.fill(order, sig, wethIn);
    }

    function test_audit_L_CV2_6_withdrawExact_signedGrantReplayedInCall() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;
        _seedV4WethPosition(wethIn + 1e15);

        bytes memory tail =
            _signTakerPermit(false, wethReserveId, address(withdrawModule), wethIn, block.timestamp + 1 hours);
        bytes memory takerData = bytes.concat(abi.encode(MAIN_SPOKE, TAKER_PM, wethReserveId, WETH, uint256(0)), tail);
        _withdrawSetup(wethIn, usdcOut, keccak256(takerData));

        assertEq(
            ITakerPositionManager(TAKER_PM)
                .withdrawAllowance(MAIN_SPOKE, wethReserveId, maker, address(withdrawModule)),
            0,
            "no on-chain grant"
        );
        _fillWithdraw(wethIn, usdcOut, takerData);

        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker paid");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver got WETH");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "module empty");
    }

    function test_audit_L_CV2_6_withdrawFull_signedMaxGrantReplayedInCall() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;
        _seedV4WethPosition(wethIn + 1e15);

        bytes memory tail = _signTakerPermit(
            false, wethReserveId, address(withdrawModule), type(uint256).max, block.timestamp + 1 hours
        );
        bytes memory takerData = bytes.concat(
            abi.encode(
                MAIN_SPOKE, TAKER_PM, wethReserveId, WETH, DustHandler.encodeMode(DustHandler.BalanceMode.Full), wethIn
            ),
            tail
        );
        _withdrawSetup(wethIn, usdcOut, keccak256(takerData));
        _fillWithdraw(wethIn, usdcOut, takerData);

        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker paid");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver got WETH");
        assertApproxEqAbs(IERC20(WETH).balanceOf(maker), 1e15, 2, "accrued excess swept to maker");
        assertEq(ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker), 0, "position closed");
    }

    /// @dev Front-run tolerance: a third party lands the published signature first;
    ///      the fill must still succeed (the grant it wanted is in place).
    function test_audit_L_CV2_6_withdraw_frontRunSignatureDoesNotBrickFill() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;
        _seedV4WethPosition(wethIn + 1e15);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = ITakerPMSigView(TAKER_PM).nonces(maker, 0);
        bytes memory tail = _signTakerPermit(false, wethReserveId, address(withdrawModule), wethIn, deadline);
        bytes memory takerData = bytes.concat(abi.encode(MAIN_SPOKE, TAKER_PM, wethReserveId, WETH, uint256(0)), tail);
        _withdrawSetup(wethIn, usdcOut, keccak256(takerData));

        (,,, bytes memory rawSig) = abi.decode(tail, (uint256, uint256, uint256, bytes));
        vm.prank(address(0xBAD));
        ITakerPositionManager(TAKER_PM)
            .approveWithdrawWithSig(
                ITakerPositionManager.TakerPermit({
                    spoke: MAIN_SPOKE,
                    reserveId: wethReserveId,
                    owner: maker,
                    spender: address(withdrawModule),
                    amount: wethIn,
                    nonce: nonce,
                    deadline: deadline
                }),
                rawSig
            );

        _fillWithdraw(wethIn, usdcOut, takerData);
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "fill survived the front-run");
    }

    /// @dev SET-not-RAISE: a standing max grant already covers the fill, so the
    ///      replay is skipped and the grant is not shrunk to the signed amount.
    function test_audit_L_CV2_6_withdraw_standingGrantNotShrunk() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;
        _seedV4WethPosition(wethIn + 1e15);

        bytes memory tail =
            _signTakerPermit(false, wethReserveId, address(withdrawModule), wethIn, block.timestamp + 1 hours);
        bytes memory takerData = bytes.concat(abi.encode(MAIN_SPOKE, TAKER_PM, wethReserveId, WETH, uint256(0)), tail);
        _withdrawSetup(wethIn, usdcOut, keccak256(takerData));
        vm.prank(maker);
        ITakerPositionManager(TAKER_PM)
            .approveWithdraw(MAIN_SPOKE, wethReserveId, address(withdrawModule), type(uint256).max);

        _fillWithdraw(wethIn, usdcOut, takerData);
        assertEq(
            ITakerPositionManager(TAKER_PM)
                .withdrawAllowance(MAIN_SPOKE, wethReserveId, maker, address(withdrawModule)),
            type(uint256).max,
            "standing max grant kept"
        );
    }

    function test_audit_L_CV2_6_borrow_signedGrantReplayedInCall() public {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 1_500e6;
        deal(WETH, solver, collateralIn);

        bytes memory tail =
            _signTakerPermit(true, usdcReserveId, address(borrowModule), borrowOut, block.timestamp + 1 hours);
        bytes memory borrowData = bytes.concat(abi.encode(MAIN_SPOKE, TAKER_PM, usdcReserveId, USDC), tail);

        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(GIVER_PM, true);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(TAKER_PM, true);
        ISpokeV4(MAIN_SPOKE).setUsingAsCollateral(wethReserveId, true, maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(collateralIn), 0);
        permit3.approveTaker(address(settlement), address(borrowModule), keccak256(borrowData), uint160(borrowOut), 0);
        vm.stopPrank();
        _approveSolverSide(collateralIn, WETH);

        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: collateralIn,
            recipient: address(0),
            data: abi.encode(MAIN_SPOKE, GIVER_PM, wethReserveId, WETH)
        });
        items[1] = Item({
            op: ItemOp.TAKE, module: address(borrowModule), amount: borrowOut, recipient: address(0), data: borrowData
        });
        Order memory order = _order(maker, 2, USDC, WETH, borrowOut, collateralIn, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, borrowOut);

        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received borrowed USDC");
        assertApproxEqAbs(ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker), borrowOut, 2, "maker debt");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "module empty");
    }
}
