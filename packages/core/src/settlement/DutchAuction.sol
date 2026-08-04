// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, CurvePoint} from "./Structs.sol";

/// @title DutchAuction
/// @notice Dutch decay pricing. Every leg shares ONE clock and ONE normalized
///         decay `bumpBps ∈ [0, 10000]` (0 = the `start` price / best for maker,
///         10000 = the `end` price / worst). Each leg maps that shared bump
///         through its own `start`/`end` bounds. The shape of the bump over time
///         is either a single linear segment (`decayStartTime`/`decayDuration`)
///         or, if `curve` is non-empty, a piecewise-linear interpolation over the
///         signed `CurvePoint[]`. An optional gas bump adds decay proportional to
///         `block.basefee`, so the maker clears for less when gas is high.
///
///         Fixed legs (`end == 0`) ignore the bump; any leg with `end != 0` is
///         auctioned — outputs FALL (`end ≤ start`), inputs RISE (`start ≤ end`).
///         On SELL the falling outputs are the classic conversion auction and a
///         rising input is the relayer-fee leg; on BUY the rising inputs are the
///         conversion auction.
///
///         Also home to the {Order.timing} accessors — the three uint32 clocks
///         (`decayStartTime` | `decayDuration` | `exclusivityEndTime`) are packed
///         into one word; these unpack them (and the SDK mirrors the layout).
library DutchAuction {
    error AuctionNotStarted();
    error InvalidAuctionParams();

    uint256 internal constant BPS = 10_000;

    // ──────────────────── Packed `timing` accessors ────────────────────

    /// @notice Auction start (unix) — bits [0:32) of `order.timing`.
    function decayStartTime(Order calldata order) internal pure returns (uint256) {
        return uint32(order.timing);
    }

    /// @notice Decay window (seconds; 0 = no time decay) — bits [32:64).
    function decayDuration(Order calldata order) internal pure returns (uint256) {
        return uint32(order.timing >> 32);
    }

    /// @notice Exclusivity end (unix; ignored if `exclusiveFiller == 0`) — bits [64:96).
    function exclusivityEndTime(Order calldata order) internal pure returns (uint256) {
        return uint32(order.timing >> 64);
    }

    /// @notice The maker's ITEM EXECUTION POLICY — bits [96:100). See {ItemPolicy}.
    /// @dev    `timing`'s three clocks occupy bits [0:96) and every accessor above
    ///         masks to `uint32`, so bits [96:256) were dead space in a word the
    ///         maker ALREADY SIGNS. Putting the policy there buys maker-enforced item
    ///         ordering with no new `Order` field, no EIP-712 typehash change, and no
    ///         golden-hash break — and every order signed before this existed reads
    ///         back {ItemPolicy.ANY}, which is exactly the behaviour it was signed
    ///         under. Bits [100:256) remain free for whatever comes next.
    function itemPolicy(Order calldata order) internal pure returns (uint256) {
        return (order.timing >> 96) & 0xf;
    }

    // ──────────────────── Decay clock ────────────────────

    /// @notice The shared normalized decay for this order at the current time,
    ///         in [0, 10000]. Piecewise if `curve` is set, else a single linear
    ///         segment; then the optional gas bump is added and the sum clamped.
    function bumpBps(Order calldata order) internal view returns (uint256 bps) {
        uint256 startT = decayStartTime(order);
        CurvePoint[] calldata curve = order.curve;
        uint256 n = curve.length;

        if (n == 0) {
            // Classic single linear segment.
            uint256 dur = decayDuration(order);
            if (dur != 0) {
                if (block.timestamp < startT) revert AuctionNotStarted();
                uint256 elapsed = block.timestamp - startT;
                bps = elapsed >= dur ? BPS : (BPS * elapsed) / dur;
            }
            // decayDuration == 0 ⇒ bps stays 0 (start price, no time decay).
        } else {
            // Piecewise-linear curve, timeDeltas relative to decayStartTime.
            if (block.timestamp < startT) revert AuctionNotStarted();
            uint256 elapsed = block.timestamp - startT;
            if (elapsed <= curve[0].timeDelta) {
                bps = curve[0].bumpBps;
            } else if (elapsed >= curve[n - 1].timeDelta) {
                bps = curve[n - 1].bumpBps;
            } else {
                for (uint256 k; k < n - 1; k++) {
                    uint256 t1 = curve[k + 1].timeDelta;
                    if (elapsed < t1) {
                        uint256 t0 = curve[k].timeDelta;
                        uint256 b0 = curve[k].bumpBps;
                        uint256 b1 = curve[k + 1].bumpBps;
                        uint256 span = t1 - t0; // > 0 for a well-formed (increasing) curve
                        // Interpolate; the curve may rise or fall between points.
                        bps = b1 >= b0
                            ? b0 + ((b1 - b0) * (elapsed - t0)) / span
                            : b0 - ((b0 - b1) * (elapsed - t0)) / span;
                        break;
                    }
                }
            }
        }

        // Gas bump: extra decay proportional to basefee, capped at gasBumpBps.
        uint256 gb = order.gasBumpBps;
        if (gb != 0 && order.gasPriceRef != 0) {
            uint256 gasAdd = (gb * block.basefee) / order.gasPriceRef;
            if (gasAdd > gb) gasAdd = gb;
            bps += gasAdd;
        }
        if (bps > BPS) bps = BPS;
    }

    // ──────────────────── Per-leg ticks ────────────────────

    /// @notice Output tick for leg `j` given a PRECOMPUTED shared `bump` (bps).
    ///         `pure` — the caller computes `bumpBps(order)` once per fill and
    ///         reuses it across every leg. A FIXED leg (`end == 0`) returns `start`
    ///         and ignores `bump`.
    function amountOutAt(Order calldata order, uint256 j, uint256 bump) internal pure returns (uint256) {
        uint256 startOut = order.legsOut[j].start;
        uint256 endOut = order.legsOut[j].end;
        if (endOut == 0) return startOut; // fixed leg — no bump
        if (startOut < endOut) revert InvalidAuctionParams(); // outputs must FALL
        return startOut - ((startOut - endOut) * bump) / BPS;
    }

    /// @notice Current auction tick for every output leg. Computes the shared
    ///         `bump` at most ONCE (lazily, only if some leg actually decays — so
    ///         an all-fixed order never calls `bumpBps`, preserving its behavior).
    function currentAmountOut(Order calldata order) internal view returns (uint256[] memory outs) {
        uint256 n = order.legsOut.length;
        outs = new uint256[](n);
        uint256 bump;
        bool bumpSet;
        for (uint256 j; j < n;) {
            if (order.legsOut[j].end != 0 && !bumpSet) {
                bump = bumpBps(order);
                bumpSet = true;
            }
            outs[j] = amountOutAt(order, j, bump);
            unchecked {
                ++j;
            }
        }
    }

    /// @notice Input tick for leg `i` given a PRECOMPUTED shared `bump` (bps).
    ///         `pure` counterpart of `amountOutAt`. FIXED leg (`end == 0`) returns
    ///         `start`.
    function amountInAt(Order calldata order, uint256 i, uint256 bump) internal pure returns (uint256) {
        uint256 startIn = order.legsIn[i].start;
        uint256 endIn = order.legsIn[i].end;
        if (endIn == 0) return startIn; // fixed leg — no bump
        if (startIn > endIn) revert InvalidAuctionParams(); // inputs must RISE
        return startIn + ((endIn - startIn) * bump) / BPS;
    }

    /// @notice Current auction tick for every input leg. Shared `bump` computed at
    ///         most once (lazily), as in `currentAmountOut`.
    function currentAmountIn(Order calldata order) internal view returns (uint256[] memory ins) {
        uint256 n = order.legsIn.length;
        ins = new uint256[](n);
        uint256 bump;
        bool bumpSet;
        for (uint256 i; i < n;) {
            if (order.legsIn[i].end != 0 && !bumpSet) {
                bump = bumpBps(order);
                bumpSet = true;
            }
            ins[i] = amountInAt(order, i, bump);
            unchecked {
                ++i;
            }
        }
    }
}
