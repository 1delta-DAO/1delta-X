// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAllowanceHolder} from "../interfaces/IAllowanceHolder.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

/// @title AllowanceHolder
/// @notice Signature-free, allowance-free-afterwards token pulls. The owner
///         approves this contract once on the ERC20 and thereafter calls
///         `exec(operator, token, amount, target, data)`: the holder records an
///         allowance for `operator`, calls `target`, and zeroes the allowance
///         before returning. Nothing survives the call — there is no standing
///         approval to revoke and no signature to leak.
///
///         Ported from 0x's `AllowanceHolder`, with two deliberate deviations
///         documented below (no transient storage; explicit in-flight check).
///
///  PROVENANCE — 0x `AllowanceHolder` (MIT). NO PERMIT2 LINEAGE: Uniswap's
///  ─────────────────────────────────────────────────────────────────────────
///  Permit2 has nothing like this, and nothing here is derived from it. It is
///  the one file in this directory that is not part of the Permit2 family, which
///  is also why it is not part of the `Permit3` contract.
///
///  FROM 0x: `exec` + callback `transferFrom`, the ephemeral (operator, owner,
///  token) grant, the ERC-2771-style appended sender, and the `_rejectIfERC20`
///  confused-deputy probe.
///  CHANGED:
///    • Plain `SSTORE`, not `TSTORE` — some target chains have no transient
///      storage. See the gas note below.
///    • An explicit `AllowanceInFlight` check on nesting, which the transient
///      version does not need.
///
///  Why this is a SEPARATE, UNPRIVILEGED contract
///  ─────────────────────────────────────────────
///  `exec` performs an arbitrary call to an arbitrary target from THIS contract's
///  address. Fold that capability into Permit3 and it becomes a universal
///  authority bypass: taker modules gate on `msg.sender == permit3`, so a Permit3
///  that could be told to call anything would let anyone reach `takeOnBehalf`
///  directly, allowance gate and all. The holder's address must therefore never be
///  granted authority anywhere — not as a Permit3 spender, not as a module's
///  authorised caller, not as a settlement operator. Whatever it is trusted with,
///  everyone is trusted with.
///
///  For the same reason it must never hold a balance between calls: any `exec` can
///  make it call `token.transfer(...)`. Tokens or ETH left here are unowned.
///
///  Gas
///  ───
///  The grant is a real SSTORE, not TSTORE — some target chains have no transient
///  storage. Set-then-clear within one transaction refunds the full write
///  (EIP-3529), so on any transaction large enough to clear the gasUsed/5 refund
///  cap — a settlement fill is an order of magnitude past it — the net cost is
///  roughly the cold-slot premium (~2.3k gas), not the ~22k headline.
contract AllowanceHolder is IAllowanceHolder {
    /// @dev keccak256(operator, owner, token) → live allowance. Flat rather than
    ///      three nested mappings so the slot key is computed ONCE per `exec` and
    ///      reused for the clear; Solidity cannot hold a storage pointer to a
    ///      `uint256` mapping value, so a nested mapping would re-hash on every
    ///      touch.
    mapping(bytes32 => uint256) private _ephemeral;

    function exec(address operator, address token, uint256 amount, address payable target, bytes calldata data)
        external
        payable
        override
        returns (bytes memory result)
    {
        // A target of `address(this)` would re-enter with the holder as the
        // operator, letting a crafted `data` spend an allowance granted to it.
        if (target == address(this)) revert InvalidTarget();
        _rejectIfERC20(target, data);

        address owner = msg.sender;
        bytes32 key = _key(operator, owner, token);
        // DEVIATION FROM 0x: an explicit in-flight check. With transient storage a
        // nested `exec` on the same triple would silently clobber the outer grant
        // and, worse, zero it early on the inner return. Rejecting the collision is
        // free — the slot is being read anyway — and nesting on a DIFFERENT triple
        // stays legal, which is what a multi-token flow actually needs.
        if (_ephemeral[key] != 0) revert AllowanceInFlight();

        _ephemeral[key] = amount;
        result = _callWithSender(target, data, owner);
        // Unconditional: a revert in `target` bubbles out of `_callWithSender`, so
        // the whole frame — this write included — is undone. There is no path that
        // returns with the slot still hot.
        _ephemeral[key] = 0;
    }

    function transferFrom(address token, address owner, address recipient, uint256 amount)
        external
        override
        returns (bool)
    {
        // Keyed on `msg.sender` as the operator and on `owner` as the payer, so a
        // live allowance can only ever move the tokens of the account that granted
        // it, and only for the operator it named. Outside an `exec` every key reads
        // zero, so this reverts for any non-zero pull.
        bytes32 key = _key(msg.sender, owner, token);
        uint256 allowed = _ephemeral[key];
        if (allowed < amount) revert InsufficientEphemeralAllowance(allowed);
        unchecked {
            _ephemeral[key] = allowed - amount;
        }
        SafeTransferLib.safeTransferFrom(token, owner, recipient, amount);
        return true;
    }

    function ephemeralAllowance(address operator, address owner, address token)
        external
        view
        override
        returns (uint256)
    {
        return _ephemeral[_key(operator, owner, token)];
    }

    // ──────────────────── Internal ────────────────────

    function _key(address operator, address owner, address token) private pure returns (bytes32) {
        return keccak256(abi.encode(operator, owner, token));
    }

    /// @dev THE LOAD-BEARING GUARD. Users approve this contract on their ERC20s, so
    ///      the holder is the only party that can spend those approvals — and `exec`
    ///      lets an arbitrary caller pick both the callee and its calldata. Without
    ///      this check, anyone could call
    ///
    ///          exec(_, _, 0, USDC, abi.encodeCall(IERC20.transferFrom, (victim, attacker, all)))
    ///
    ///      and drain EVERY approval the holder holds, their own `amount` grant
    ///      being irrelevant. Only DIRECT calls are dangerous: routed through any
    ///      intermediate contract, `msg.sender` at the token is no longer the
    ///      holder and the approvals are out of reach.
    ///
    ///      So targets that answer `balanceOf(address)` are refused outright, as in
    ///      0x's original. It is a heuristic and it is deliberately over-broad: it
    ///      also rejects vaults, LP tokens and anything else with an ERC20 face.
    ///      Loosen it only with a positive allowlist, never by weakening the probe.
    function _rejectIfERC20(address target, bytes calldata data) private view {
        // Probe with the callee's own first argument where there is one, rather
        // than a constant: a token with a blacklist may revert on `balanceOf` for
        // an arbitrary address, and a reverting probe reads as "not a token".
        address probe;
        if (data.length >= 36) {
            /// @solidity memory-safe-assembly
            assembly {
                probe := and(calldataload(add(data.offset, 0x04)), 0xffffffffffffffffffffffffffffffffffffffff)
            }
        }
        // Precompile range (and zero) — no token, and cheap addresses an attacker
        // could pick on purpose to steer the probe.
        if (uint160(probe) <= 0xffff) probe = address(this);

        // Probe TWICE — once with the callee's own argument, once with a constant
        // (`this`). The argument-derived probe is chosen BY THE CALLER: for the
        // drain this guard exists to stop
        // (`exec(_, _, 0, USDC, transferFrom(victim, …))`) the attacker sets
        // `arg0 = victim`, so a token that reverts / returns short for that one
        // address would read as "not a token" and open the guard. Rejecting if
        // EITHER probe answers removes the attacker's control over the outcome, at
        // the cost of one extra staticcall on a path that already makes one. Only a
        // target that answers `balanceOf` for NEITHER address slips through, and
        // such a thing cannot be the ERC20 whose approvals the drain would spend.
        if (_answersBalanceOf(target, probe) || _answersBalanceOf(target, address(this))) revert ConfusedDeputy();
    }

    /// @dev True if `target.balanceOf(who)` succeeds and returns at least a word.
    ///      `balanceOf(address)` == 0x70a08231.
    function _answersBalanceOf(address target, address who) private view returns (bool) {
        (bool success, bytes memory ret) = target.staticcall(abi.encodeWithSelector(0x70a08231, who));
        return success && ret.length >= 32;
    }

    /// @dev Calls `target` with `data ++ sender` (20 trailing bytes, ERC-2771
    ///      style), forwarding `msg.value`, and returns the raw return data —
    ///      bubbling a revert verbatim so the caller sees the target's own error.
    ///
    ///      Solidity's ABI decoder ignores trailing calldata on external calls, so
    ///      the appended word is invisible to targets that do not look for it.
    ///
    ///      The argument buffer is built ABOVE the free-memory pointer without
    ///      bumping it (permitted for memory-safe assembly — it is consumed by the
    ///      CALL and never outlives it); the returned `bytes` is then allocated
    ///      properly over that same region, which by then is dead.
    function _callWithSender(address target, bytes calldata data, address sender)
        private
        returns (bytes memory result)
    {
        uint256 value = msg.value;
        /// @solidity memory-safe-assembly
        assembly {
            let p := mload(0x40)
            calldatacopy(p, data.offset, data.length)
            // Left-aligned 20 bytes. Writing a full word first would need the tail
            // cleared; shifting the address up puts it flush at `data.length`.
            mstore(add(p, data.length), shl(96, sender))
            let ok := call(gas(), target, value, p, add(data.length, 20), 0x00, 0x00)

            let rds := returndatasize()
            result := mload(0x40)
            mstore(result, rds)
            returndatacopy(add(result, 0x20), 0x00, rds)
            mstore(0x40, add(add(result, 0x20), and(add(rds, 0x1f), not(0x1f))))
            if iszero(ok) { revert(add(result, 0x20), rds) }
        }
    }
}
