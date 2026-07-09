// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {ICEther} from "./interfaces/ICompoundV2.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

// ════════════════════════════════════════════════════════════════════════════
//  Compound v2 NATIVE (cEther) modules — deposit / repay / withdraw
//
//  Compound v2 (and its forks) expose their ETH market as `cEther`, whose value-in
//  entry points are payable/native (`mint()`, `repayBorrowBehalf(borrower)`) and
//  whose `redeem*` sends native ETH. The core is ERC20-only, so these modules
//  bridge WETH↔ETH at the cEther boundary ONLY: the maker's funds flow as WETH
//  through Permit3/Settlement, and each module unwraps to ETH for the payable call
//  (deposit/repay) or wraps the redeemed ETH back to WETH (withdraw). The maker
//  never handles raw ETH — WETH is the settlement-side representation.
//
//    deposit  → weth.withdraw → cEther.mint{value}    (cTokens minted here, forwarded)
//    repay    → weth.withdraw → cEther.repayBorrowBehalf{value}   (the on-behalf call)
//    withdraw → cEther.redeem* → weth.deposit         (ETH wrapped, forwarded as WETH)
//
//  There is NO native borrow module: vanilla Compound v2 has no `borrowBehalf`/
//  delegation, so a router cannot borrow on a user's behalf (native or ERC20) — the
//  same reason the cErc20 package ships no borrow module.
//
//  `data` for every native module is `abi.encode(cEther)` — the underlying is native,
//  so only the cToken address is needed (the module's `weth` is immutable).
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── native deposit maker module ────────────────────
contract CompoundV2NativeDepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;
    IWETH public immutable weth;

    error NotSettlement();

    constructor(address _permit3, address _settlement, address _weth) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
        weth = IWETH(_weth);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        address cEther = abi.decode(data, (address));

        // Pull WETH from the maker, unwrap, mint cEther to THIS module (cEther has no
        // `mintBehalf`), then forward the receipt cTokens to the maker.
        permit3.transferFrom(onBehalfOf, address(this), address(weth), uint160(amount));
        weth.withdraw(amount);
        ICEther(cEther).mint{value: amount}(); // reverts on error
        SafeTransferLib.safeTransfer(cEther, onBehalfOf, IERC20(cEther).balanceOf(address(this)));
    }

    receive() external payable {} // ETH from weth.withdraw
}

// ──────────────────── native repay maker module ────────────────────
//
// Pull-exact: reads the live ETH debt and repays exactly `min(amount, debt)` — the
// over-repay buffer is never pulled, so nothing sits here for a caller to redirect
// and there is no residual to dispose. cEther reverts on an over-send (it caps at
// the debt via SafeMath), so exact repayment is mandatory anyway.
// `nonReentrant` guards weird-token / ETH receive hooks.
contract CompoundV2NativeRepayModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;
    IWETH public immutable weth;

    uint256 private _locked = 1;

    error Reentrancy();
    error NotSettlement();

    constructor(address _permit3, address _settlement, address _weth) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
        weth = IWETH(_weth);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        address cEther = abi.decode(data, (address));

        uint256 debt = ICEther(cEther).borrowBalanceCurrent(onBehalfOf);
        uint256 toRepay = amount < debt ? amount : debt;
        if (toRepay > 0) {
            permit3.transferFrom(onBehalfOf, address(this), address(weth), uint160(toRepay));
            weth.withdraw(toRepay);
            ICEther(cEther).repayBorrowBehalf{value: toRepay}(onBehalfOf); // reverts on error
        }

        _locked = 1;
    }

    receive() external payable {} // ETH from weth.withdraw
}

// ──────────────────── native withdraw taker module ────────────────────
//
// Redeems the maker's cEther collateral. Compound v2 has no redeem-on-behalf, so the
// module pulls the maker's cEther via the Permit3 token allowance (maker infinite-
// approves cEther to this module), redeems to native ETH, WRAPS it to WETH, and
// forwards WETH to `receiver` — so the value re-enters the ERC20 settlement flow
// (solver payout or the maker's wallet). `data = abi.encode(cEther[, BalanceMode])`.
contract CompoundV2NativeWithdrawModule is ITakerModule {
    IPermit3 public immutable permit3;
    IWETH public immutable weth;

    error OnlyPermit3();
    error CompoundV2Error(uint256 code);

    constructor(address _permit3, address _weth) {
        permit3 = IPermit3(_permit3);
        weth = IWETH(_weth);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        address cEther = abi.decode(data, (address));

        // base = (address) = 32 bytes ⇒ optional BalanceMode at offset 32.
        if (DustHandler.readBalanceMode(data, 32) == DustHandler.BalanceMode.Full) {
            // Redeem the maker's ENTIRE cEther balance, wrap all, forward the signed
            // `amount`, sweep the WETH excess back to the maker.
            uint256 cBal = IERC20(cEther).balanceOf(onBehalfOf);
            permit3.transferFrom(onBehalfOf, address(this), cEther, uint160(cBal));
            uint256 beforeEth = address(this).balance;
            uint256 err = ICEther(cEther).redeem(cBal);
            if (err != 0) revert CompoundV2Error(err);
            uint256 received = address(this).balance - beforeEth;
            require(received >= amount, "insufficient withdrawn");
            weth.deposit{value: received}();
            SafeTransferLib.safeTransfer(address(weth), receiver, amount);
            if (received > amount) SafeTransferLib.safeTransfer(address(weth), onBehalfOf, received - amount);
        } else {
            // Pull the ceiling cEther needed for `amount` ETH, redeem exactly `amount`,
            // wrap to WETH, forward, and return any cToken remainder to the maker.
            uint256 rate = ICEther(cEther).exchangeRateCurrent();
            uint256 cAmount = (amount * 1e18 + rate - 1) / rate;
            permit3.transferFrom(onBehalfOf, address(this), cEther, uint160(cAmount));
            uint256 err = ICEther(cEther).redeemUnderlying(amount);
            if (err != 0) revert CompoundV2Error(err);
            weth.deposit{value: amount}();
            SafeTransferLib.safeTransfer(address(weth), receiver, amount);
            uint256 leftC = IERC20(cEther).balanceOf(address(this));
            if (leftC != 0) SafeTransferLib.safeTransfer(cEther, onBehalfOf, leftC);
        }
    }

    receive() external payable {} // ETH from cEther.redeem*
}
