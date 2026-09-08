// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
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
        // Balance held BEFORE the operation. Sweeping `balanceOf(this)` outright
        // would pay out anything already stranded at this shared module, and anyone
        // can be the maker of a one-unit order against it. "The module ends where it
        // started", not "ends empty" — F19 / F25 G-1.
        uint256 cFloor = IERC20(cEther).balanceOf(address(this));
        uint256 ethFloor = address(this).balance;
        permit3.transferFrom(onBehalfOf, address(this), address(weth), uint160(amount));
        weth.withdraw(amount);
        ICEther(cEther).mint{value: amount}(); // reverts on error
        uint256 cBalNow = IERC20(cEther).balanceOf(address(this));
        if (cBalNow > cFloor) SafeTransferLib.safeTransfer(cEther, onBehalfOf, cBalNow - cFloor);
        _sweepNativeAsWeth(onBehalfOf, ethFloor);
    }

    /// @dev Wrap the native balance THIS CALL produced and return it to `to`.
    ///
    ///  ⚠ THE `floor` IS NOT OPTIONAL, and the reasoning that once justified
    ///  omitting it was wrong. This used to wrap `address(this).balance` outright,
    ///  argued as: `receive()` is open and these modules have no owner or rescue
    ///  path, so ETH left behind would be stranded forever — "a donor's ETH is a
    ///  gift to the maker, not a loss".
    ///
    ///  That silently assumes the maker is a legitimate counterparty. **Anyone can
    ///  be the maker of a one-wei order.** It was not a gift to the maker; it was a
    ///  gift to whoever called first, which is the F19 shape this repo rules out
    ///  everywhere else. Worse, `CompoundV2NativeRepayModule` reaches the sweep with
    ///  NO pull at all when the live debt is zero, so the claim cost only gas.
    ///
    ///  The cost of the floor is honest and worth stating: ETH donated to this
    ///  address is now unrecoverable rather than claimable. That matches how every
    ///  other module in the tree treats a donated ERC-20, and "nobody gets it" beats
    ///  "the fastest attacker gets it". Giving these modules a rescue path is a
    ///  separate decision — see `docs/audit-2026-09-modules-plan.md`.
    ///
    ///  Wrapping (rather than a raw `.call{value:}`) keeps the sweep reentrancy-free.
    function _sweepNativeAsWeth(address to, uint256 floor) private {
        uint256 bal = address(this).balance;
        if (bal > floor) {
            unchecked {
                uint256 delta = bal - floor;
                weth.deposit{value: delta}();
                SafeTransferLib.safeTransfer(address(weth), to, delta);
            }
        }
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

        // ⚠ Taken BEFORE the pull, and load-bearing: with a zero live debt `toRepay`
        // is 0 and the whole block below is skipped, so this function reaches the
        // sweep having pulled NOTHING. Unfloored, that made every wei of ETH at this
        // shared module claimable for gas by anyone. F26/2a.
        uint256 ethFloor = address(this).balance;

        uint256 debt = ICEther(cEther).borrowBalanceCurrent(onBehalfOf);
        uint256 toRepay = amount < debt ? amount : debt;
        if (toRepay > 0) {
            permit3.transferFrom(onBehalfOf, address(this), address(weth), uint160(toRepay));
            weth.withdraw(toRepay);
            ICEther(cEther).repayBorrowBehalf{value: toRepay}(onBehalfOf); // reverts on error
        }

        _sweepNativeAsWeth(onBehalfOf, ethFloor);
        _locked = 1;
    }

    /// @dev Wrap the native balance THIS CALL produced and return it to `to`.
    ///
    ///  ⚠ THE `floor` IS NOT OPTIONAL, and the reasoning that once justified
    ///  omitting it was wrong. This used to wrap `address(this).balance` outright,
    ///  argued as: `receive()` is open and these modules have no owner or rescue
    ///  path, so ETH left behind would be stranded forever — "a donor's ETH is a
    ///  gift to the maker, not a loss".
    ///
    ///  That silently assumes the maker is a legitimate counterparty. **Anyone can
    ///  be the maker of a one-wei order.** It was not a gift to the maker; it was a
    ///  gift to whoever called first, which is the F19 shape this repo rules out
    ///  everywhere else. Worse, `CompoundV2NativeRepayModule` reaches the sweep with
    ///  NO pull at all when the live debt is zero, so the claim cost only gas.
    ///
    ///  The cost of the floor is honest and worth stating: ETH donated to this
    ///  address is now unrecoverable rather than claimable. That matches how every
    ///  other module in the tree treats a donated ERC-20, and "nobody gets it" beats
    ///  "the fastest attacker gets it". Giving these modules a rescue path is a
    ///  separate decision — see `docs/audit-2026-09-modules-plan.md`.
    ///
    ///  Wrapping (rather than a raw `.call{value:}`) keeps the sweep reentrancy-free.
    function _sweepNativeAsWeth(address to, uint256 floor) private {
        uint256 bal = address(this).balance;
        if (bal > floor) {
            unchecked {
                uint256 delta = bal - floor;
                weth.deposit{value: delta}();
                SafeTransferLib.safeTransfer(address(weth), to, delta);
            }
        }
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

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        address cEther = abi.decode(data, (address));

        // Floors for BOTH sides, taken before anything moves. The WETH sweep used to
        // return the module's whole balance, and the native wrap used to wrap the
        // whole balance — so stranded WETH or ETH was claimable by whoever authored
        // the next one-wei order. F19 / F26/2a.
        uint256 wethFloor = SafeTransferLib.balanceOf(address(weth), address(this));
        uint256 ethFloor = address(this).balance;

        // base = (address) = 32 bytes ⇒ optional BalanceMode at offset 32.
        if (DustHandler.readBalanceMode(data, 32) == DustHandler.BalanceMode.Full) {
            // `Full` liquidates the user's ENTIRE live balance, so it cannot be
            // pro-rated — a sliced fill would unwind the whole position and brick
            // the rest of the order. Require the slice to be the whole item.
            FullFillGuard.requireFullFillFromData(data, 64, amount);
            // Redeem the maker's ENTIRE cEther balance, wrap all, forward the signed
            // `amount`, sweep the WETH excess back to the maker.
            uint256 cBal = IERC20(cEther).balanceOf(onBehalfOf);
            permit3.transferFrom(onBehalfOf, address(this), cEther, uint160(cBal));
            uint256 beforeEth = address(this).balance;
            uint256 err = ICEther(cEther).redeem(cBal);
            if (err != 0) revert CompoundV2Error(err);
            uint256 received = address(this).balance - beforeEth;
            require(received >= amount, "insufficient withdrawn");
            // Wrap only what this call produced. Wrapping the ENTIRE balance was
            // argued as "a donor's ETH is a gift to the maker, not a loss" — but the
            // maker is whoever authored the order, so it was a gift to the fastest
            // caller. See {_sweepNativeAsWeth} for the full correction. F26/2a.
            weth.deposit{value: address(this).balance - ethFloor}();
            SafeTransferLib.safeTransfer(address(weth), receiver, amount);
            _sweepWeth(onBehalfOf, wethFloor);
        } else {
            // Pull the ceiling cEther needed for `amount` ETH, redeem exactly `amount`,
            // wrap to WETH, forward, and return any cToken remainder to the maker.
            uint256 rate = ICEther(cEther).exchangeRateCurrent();
            uint256 cAmount = (amount * 1e18 + rate - 1) / rate;
            // Pre-pull cEther floor — see the deposit module. A stranded cToken
            // balance is not this maker's remainder and must not be swept to them.
            uint256 cFloor = IERC20(cEther).balanceOf(address(this));
            permit3.transferFrom(onBehalfOf, address(this), cEther, uint160(cAmount));
            uint256 err = ICEther(cEther).redeemUnderlying(amount);
            if (err != 0) revert CompoundV2Error(err);
            // Wrap only this call's delta — see the Full branch and {_sweepNativeAsWeth}.
            weth.deposit{value: address(this).balance - ethFloor}();
            SafeTransferLib.safeTransfer(address(weth), receiver, amount);
            uint256 cBalNow = IERC20(cEther).balanceOf(address(this));
            if (cBalNow > cFloor) SafeTransferLib.safeTransfer(cEther, onBehalfOf, cBalNow - cFloor);
            _sweepWeth(onBehalfOf, wethFloor);
        }
    }

    /// @dev Return the WETH THIS CALL produced. `floor` is the balance held before
    ///      it began — WETH is an ordinary ERC-20 and gets the ordinary F19
    ///      treatment ("the module ends where it started"). The native-side
    ///      justification never covered the wrapped side; see {_sweepNativeAsWeth}.
    function _sweepWeth(address to, uint256 floor) private {
        uint256 bal = SafeTransferLib.balanceOf(address(weth), address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(address(weth), to, bal - floor);
    }

    receive() external payable {} // ETH from cEther.redeem*
}
