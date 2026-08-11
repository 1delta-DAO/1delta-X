// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {Order} from "../settlement/Settlement.sol";

/// @title ConditionTreeValidator
/// @notice Boolean composition over other validators — `OR`, `AND`, `NOT` — in a
///         single maker-signed expression.
///
///  Why
///  ───
///  `order.validators` is a flat AND-composed list, so "fill when the oracle says
///  X **or** the timeout has passed" cannot be said inside one order. This
///  validator is one ordinary entry in that list whose `data` happens to be a
///  whole expression; it evaluates each leaf by `staticcall`ing it exactly as
///  {Base._runValidators} would. So it composes rather than replaces:
///  `validators = [a, tree]` is `a AND tree`, and the same blob works unchanged as
///  an `invariants` entry.
///
///  Everything stays maker-signed. The expression lives inside this validator's
///  `data`, which lives inside the order's `validators` blob, which is inside the
///  EIP-712 typehash — a solver can no more rewrite a leaf here than it can swap a
///  top-level validator. **No core change: this is a deployed validator and
///  Settlement's bytecode is untouched.**
///
///  ⚠ WHEN NOT TO REACH FOR THIS
///  ────────────────────────────
///  OR across WHOLE ORDERS is already free, and is usually what you want: sign two
///  orders sharing a `nonce`, and whichever fills first cancels the other. That
///  covers "limit **or** stop-loss" — the most common disjunction — for no extra
///  gas, and lets each branch carry its own prices, items and amounts, which one
///  order cannot. Reach for this only when the disjunction is over conditions on
///  ONE fill: `(oracle OR timeout) AND whitelisted`.
///
///  ENCODING — disjunctive normal form (an OR of ANDs)
///  ──────────────────────────────────────────────────
///      groupCount(1) ‖ group*
///      group := leafCount(1) ‖ leaf*
///      leaf  := flags(1) ‖ target(20) ‖ dataLen(2) ‖ data
///
///      flags bit 0  NEGATE — invert this leaf
///      flags bit 1  TRY    — treat a reverting leaf as `false` instead of aborting
///
///  The expression is `(l₁ AND l₂ …) OR (l₃ AND l₄ …) OR …`, and every boolean
///  formula has such a form — with negated literals available, DNF is complete, so
///  nothing is lost against an arbitrary tree.
///
///  `(price ≥ X OR elapsed > T) AND whitelisted` distributes to
///  `(price ≥ X AND whitelisted) OR (elapsed > T AND whitelisted)`: two groups,
///  two leaves each. The whitelist leaf appears twice — but only ONE group is ever
///  evaluated to completion, so the duplication costs calldata, not gas.
///
///  Why this shape and not a node graph with child indices — the form Kyber's
///  `ConditionTree` uses, whose own doc concedes *"invalid tree structures could
///  lead to revert, or invalid results"*:
///
///    • **no cycles and no out-of-range child**, because there are no indices;
///    • **no recursion at all**, so no depth limit to pick and no call-stack
///      exhaustion to reason about — evaluation is two flat loops;
///    • **short-circuits both ways**: a false leaf abandons the rest of its group,
///      and a satisfied group returns without touching any later group. An oracle
///      read that cannot change the answer is never paid for;
///    • **well-formedness is exact** — parsing must consume precisely
///      `data.length`, and an empty expression or an empty group is rejected
///      rather than being vacuously true.
///
///  ⚠ A REVERTING LEAF IS AN ERROR, NOT `false`
///  ───────────────────────────────────────────
///  {OrderGates.gatePasses} folds a reverting validator into `false`. Under a flat
///  AND that is harmless — false aborts the fill either way. Once `OR` and `NOT`
///  exist it stops being harmless:
///
///    `NOT(staleOracleLeaf)` — the leaf reverts, reads as `false`, and NEGATE turns
///    it TRUE. "Fill unless the price is above X" would fill precisely when the
///    feed is broken.
///
///  So a leaf that reverts, or returns fewer than 32 bytes, aborts the fill with
///  {ConditionErrored} — the same outcome a maker already gets from a reverting
///  top-level validator — which leaves NEGATE able to invert only a clean boolean.
///
///  `TRY` is the explicit opt-out, per leaf: it converts a reverting leaf to
///  `false`. A maker who genuinely wants "price ≥ X, or if the feed is down fall
///  back to the timeout" sets TRY on the price leaf, and that choice is visible in
///  the signed order instead of being the silent default.
///
///  ⚠ TRY + NEGATE on the same leaf means "reverted or false" ⇒ true. That is
///  coherent but rarely what anyone means; prefer a dedicated leaf that returns a
///  clean boolean.
contract ConditionTreeValidator is IOrderValidator {
    /// @dev Invert this leaf's result.
    uint256 internal constant FLAG_NEGATE = 1;
    /// @dev Treat a reverting leaf as `false` rather than aborting the fill.
    uint256 internal constant FLAG_TRY = 2;

    /// @dev Fixed part of a leaf record: flags | target | dataLen.
    uint256 internal constant LEAF_HEAD = 1 + 20 + 2;

    /// @dev The blob ended mid-record, a leaf's `data` runs past the end, an
    ///      unknown flag bit was set, or the expression / a group is EMPTY. An
    ///      empty conjunction is vacuously true and an empty disjunction is
    ///      vacuously false; both are far likelier to be a builder bug than an
    ///      intent, and silently honouring either would turn a malformed condition
    ///      into an unconditional answer.
    error MalformedTree();
    /// @dev The expression parsed cleanly but did not consume the whole blob.
    ///      Rejected so two different blobs cannot mean the same thing.
    error TrailingBytes();
    /// @dev A leaf reverted or returned a short result and carried no `TRY` flag —
    ///      see the contract note on why that is an error rather than `false`.
    ///      Arg-less deliberately: threading the failing address out would cost a
    ///      stack slot in a function that must stay inside the legacy-codegen
    ///      limit, and the leaf is recoverable by simulating them individually.
    error ConditionErrored();

    /// @inheritdoc IOrderValidator
    /// @param data the DNF blob described in the contract note.
    function validate(Order calldata order, address filler, bytes calldata data, bytes calldata takerData)
        external
        view
        override
        returns (bool)
    {
        if (data.length == 0) revert MalformedTree();
        uint256 groups = uint8(data[0]);
        if (groups == 0) revert MalformedTree(); // an empty disjunction is not "false", it is a bug
        uint256 cursor = 1;
        bool satisfied;

        for (uint256 g; g < groups;) {
            // Once an earlier group has satisfied the expression, later groups are
            // still PARSED — the cursor must reach the end for the exact-consumption
            // check — but no leaf in them is CALLED. That is the outer short-circuit.
            (bool groupOk, uint256 next) = _group(order, filler, data, takerData, cursor, !satisfied);
            if (groupOk) satisfied = true;
            cursor = next;
            unchecked {
                ++g;
            }
        }

        if (cursor != data.length) revert TrailingBytes();
        return satisfied;
    }

    /// @dev One AND-group: every leaf must hold. Its own frame so {validate}'s does
    ///      not have to carry the leaf locals too — this package builds without
    ///      via-IR and the legacy stack limit is the binding constraint.
    ///
    ///      `evaluate == false` parses without calling anything, which is how an
    ///      already-satisfied expression skips the groups after it.
    /// @return groupOk true iff `evaluate` and every leaf held
    /// @return next    the cursor just past this group
    function _group(
        Order calldata order,
        address filler,
        bytes calldata blob,
        bytes calldata takerData,
        uint256 cursor,
        bool evaluate
    ) private view returns (bool groupOk, uint256 next) {
        if (cursor >= blob.length) revert MalformedTree();
        uint256 leaves = uint8(blob[cursor]);
        if (leaves == 0) revert MalformedTree(); // an empty conjunction is not "true", it is a bug
        unchecked {
            ++cursor;
        }

        // Starts true and is cleared by the first failing leaf; the rest of the
        // group is then parsed but not called — the inner short-circuit.
        groupOk = evaluate;
        for (uint256 i; i < leaves;) {
            uint256 h = _leafHeader(blob, cursor);
            if (groupOk) groupOk = _leafValue(order, filler, blob, takerData, h);
            cursor = (h >> 192) & 0xffffffff; // dataEnd
            unchecked {
                ++i;
            }
        }
        return (groupOk, cursor);
    }

    // ──────────────────── Leaf decode / evaluation ────────────────────
    //
    // A decoded leaf travels as ONE word rather than four return values. Passed
    // separately, the four had to stay live in {_group} across the evaluation
    // call, which overflows the legacy-codegen stack limit this package builds
    // under — via-IR is not in play here, so 16 slots is the hard budget.
    //
    //   bits [  0:160)  target
    //   bits [160:192)  dataStart
    //   bits [192:224)  dataEnd
    //   bits [224:226)  flags

    /// @dev Decode and bounds-check the leaf record at `cursor`.
    function _leafHeader(bytes calldata blob, uint256 cursor) private pure returns (uint256) {
        unchecked {
            if (cursor + LEAF_HEAD > blob.length) revert MalformedTree();
        }
        uint256 flags;
        uint256 target;
        uint256 len;
        assembly {
            let p := add(blob.offset, cursor)
            flags := byte(0, calldataload(p))
            target := shr(96, calldataload(add(p, 1)))
            len := shr(240, calldataload(add(p, 21)))
        }
        // Unknown bits are rejected rather than ignored: a builder that sets one
        // believes it asked for something, and silently dropping it would change
        // the condition's meaning without changing the order's hash.
        if (flags & ~(FLAG_NEGATE | FLAG_TRY) != 0) revert MalformedTree();
        uint256 dataStart;
        uint256 dataEnd;
        unchecked {
            dataStart = cursor + LEAF_HEAD;
            dataEnd = dataStart + len;
        }
        if (dataEnd > blob.length) revert MalformedTree();
        return target | (dataStart << 160) | (dataEnd << 192) | (flags << 224);
    }

    /// @dev Evaluate one decoded leaf.
    ///
    ///      The staticcall is written out here rather than delegated to a helper:
    ///      pushing its seven argument slots on top of everything already live was
    ///      the last thing over the stack limit. `TRY` is applied before `NEGATE`,
    ///      so NEGATE only ever inverts a CLEAN boolean — the property the whole
    ///      contract note is built around.
    function _leafValue(
        Order calldata order,
        address filler,
        bytes calldata blob,
        bytes calldata takerData,
        uint256 h
    ) private view returns (bool) {
        bool ok;
        bool passed;
        {
            bytes memory cd = abi.encodeCall(
                IOrderValidator.validate,
                (order, filler, blob[(h >> 160) & 0xffffffff:(h >> 192) & 0xffffffff], takerData)
            );
            address target = address(uint160(h));
            /// @solidity memory-safe-assembly
            assembly {
                // Exactly one word of returndata is copied, into scratch space, so
                // a hostile leaf cannot bomb this contract's memory.
                let success := staticcall(gas(), target, add(cd, 0x20), mload(cd), 0x00, 0x20)
                // `ok` and `passed` are kept APART on purpose. {OrderGates.gatePasses}
                // folds a revert into `false`; here NEGATE and TRY need to tell them
                // apart — see the contract note.
                ok := and(success, gt(returndatasize(), 31))
                passed := and(ok, eq(mload(0x00), 1))
            }
        }
        uint256 flags = h >> 224;
        if (!ok) {
            if (flags & FLAG_TRY == 0) revert ConditionErrored();
            passed = false;
        }
        return flags & FLAG_NEGATE == 0 ? passed : !passed;
    }
}
