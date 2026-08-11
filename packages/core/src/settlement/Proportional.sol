// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

/// @title Proportional
/// @notice The BALANCE-RELATIVE amount encoding: a way for a maker to sign
///         "sell 100% of whatever I hold when this fills" instead of an absolute
///         number they would have to know at signing time.
///
///  The problem
///  ───────────
///  `LegIn.start` is an absolute token amount, fixed the moment the order is
///  signed. That makes the whole class of "exit my entire position" orders
///  unsignable: a gasless full sweep, a wallet-drain-to-stable, a
///  close-everything order whose size depends on interest that accrues between
///  signing and filling. The maker would have to guess the amount, sign slightly
///  low (leaving dust), and re-sign whenever the balance moved.
///
///  The encoding
///  ────────────
///  Rather than add a field — which would change the EIP-712 typehash and
///  invalidate every order already signed against the current golden hash — the
///  bps live in the TOP of the existing `start` word, in a range no real token
///  amount can reach:
///
///      start = type(uint256).max - (BPS - bps)      for bps in 1..BPS
///
///  so `bps == BPS` (100%) is `type(uint256).max` and `bps == 1` (0.01%) is
///  `type(uint256).max - 9999`. Anything strictly above {SENTINEL_FLOOR} is a
///  proportional marker; everything at or below it — which is every amount
///  expressible in any real token, the floor being ~1.15e77 — is an ordinary
///  absolute amount and decodes exactly as before. `bps == 0` deliberately maps
///  ONTO the floor and is therefore NOT proportional: a zero-size leg is
///  expressible as a plain `0` and does not need a second spelling.
///
///  Borrowed from 0x-Settler's `Permit2PaymentTakerSubmitted._permitToSellAmount`,
///  which overloads the Permit2 permitted-amount word the same way and for the
///  same reason.
///
///  ⚠ WHERE THIS MAY APPEAR
///  ───────────────────────
///  On ANY `legsIn[i]` of a SELL order, so a single signature can sweep several
///  tokens at once ("take all my USDC and all my USDT for this much ETH"). NOT on
///  output legs — the solver delivers those, and an obligation measured against
///  the PAYER's balance is meaningless on the counterparty's side.
///
///  Leg 0 is special only in WHERE it is resolved. It is the anchor, so it is read
///  in {OrderGates.anchorTotal} before any funds move and pinned in
///  `FillCtx.anchor`; legs 1..n are read in {Pricing.inputOwed} at the moment they
///  are charged. Nothing else consumes a non-anchor leg's amount — output pricing
///  and the fill counter both key off the anchor alone — so a later read is
///  self-consistent. The one visible consequence is that a maker who also signs an
///  item crediting themselves that token pays against the post-item balance on the
///  single-order path and the pre-item balance on the netted {Batch} path. Both
///  sit under the same mandatory cap, which is what bounds the difference.
///
///  A proportional order is still FULL-FILL ONLY, and that is what makes the whole
///  thing sound:
///
///  The anchor is the fill DENOMINATOR, and `filled[orderHash]` counts in anchor
///  units. A denominator derived from a live balance MOVES between fills, so a
///  partially-filled proportional order would measure its own progress against a
///  ruler that shrinks as it fills — sell 40% of 1000, and the second fill sees a
///  balance of 600 and believes the order is 400/600 done. Partial fills and a
///  balance-relative anchor cannot both be correct.
///
///  Because the order is full-fill only, the ANCHOR is read exactly once per fill
///  and `FillCtx.anchor` pins it; {Pricing.inputOwed} returns that pin for leg 0
///  rather than re-reading. That is what makes the output pricing and the maker's
///  leg-0 payment provably consistent: one balance read, so no window exists in
///  which an item crediting the maker mid-fill could make the two disagree.
///
///  The full-fill rule also gives the maker the semantics they actually asked
///  for. "Sell everything I have" is an all-or-nothing instruction; a solver
///  taking 30% of it and leaving the rest is not a smaller version of the same
///  order, it is a different one.
///
///  ⚠ FILL THESE THROUGH `fillUpTo`
///  ───────────────────────────────
///  The rule is enforced at the point of use, by {Pricing.inputOwed}: anything
///  that is not a whole fill reverts {ProportionalNeedsFullFill}. Nothing in
///  {OrderState._openFill} knows the order is proportional, and that is a measured
///  choice — threading a flag back to force `delta = total` there cost +253 gas on
///  EVERY plain fill, which this codebase does not spend on a feature most orders
///  never use.
///
///  The consequence for callers: plain `fill` must be handed EXACTLY the resolved
///  anchor, which a solver cannot know if the balance moves between simulation and
///  inclusion — the very drift this encoding exists to absorb. Use `fillUpTo`
///  instead. It clamps the request to the order's remaining size, which for an
///  unfilled proportional order IS the freshly resolved anchor, so passing any
///  sufficiently large `fillAmount` fills the sweep exactly.
///
///  That same clamp is also the SOLVER's size bound, for free: `fillAmount` is a
///  ceiling, never raised. If the maker's balance grew past what the solver quoted,
///  the clamp leaves the request below the anchor and the fill is rejected as the
///  partial it is — the solver is never silently made to buy more than it priced.
///
///  ⚠ `end` IS THE MAKER'S CAP, AND YOU ALMOST ALWAYS WANT ONE
///  ──────────────────────────────────────────────────────────
///  A proportional order always fills fully, so the fill fraction is exactly 1
///  and every OUTPUT leg pays its full signed amount — `ceil(anchor · start /
///  anchor) == start`, independent of what the anchor resolved to. The maker
///  therefore receives the SAME output whether their balance came in at half
///  the expected size or at triple it. Half is harmless (they sell less and are
///  paid in full); triple is not (they sell three times as much for the same
///  money).
///
///  So on a proportional leg `end` is repurposed: not a decay endpoint — a
///  balance-relative amount has nothing to ramp toward — but an ABSOLUTE CAP on
///  the resolved amount. With it the order reads "sell 100% of my balance, but
///  never more than `end`", which is never worse for the maker than the plain
///  absolute order they would otherwise have signed:
///
///      balance ≤ cap → sell the balance, receive the full output  (maker gains)
///      balance > cap → sell exactly the cap, receive the full output (identical
///                      to the absolute order they would otherwise have signed)
///
///  The cap is MANDATORY (`end == 0` reverts {ProportionalNeedsCap}). Uncapped is
///  not merely a footgun: the maker's balance is not under their sole control —
///  ANYONE can raise it by transferring tokens to them — so an uncapped sweep is a
///  standing offer to buy the maker's entire holding at a price fixed for a much
///  smaller one. Nor is it a hypothetical accident: `0` is what an unset field
///  holds, so the dangerous mode would be the default.
///
///  A genuinely unbounded sweep remains expressible as `end = SENTINEL_FLOOR` —
///  the largest value that is not itself a marker — so requiring a cap costs no
///  expressiveness, only deliberateness. The SDK defaults it to the quoted amount,
///  which makes the order exactly as good as the absolute one it replaces and
///  never worse. `minFillAnchor` is the matching FLOOR ("do not bother unless I
///  hold at least X") and needs no new machinery, since the anti-dust check already
///  runs against the resolved delta.
///
///  This is also the direction the drift actually runs in practice: the marker
///  exists to absorb the gap between quote and inclusion — accrued interest, a
///  rebase, a pending transfer landing, fee-on-transfer shrinkage — not to make
///  the order price-agnostic. The cap keeps it doing exactly that.
library Proportional {
    /// @dev A proportional marker appeared somewhere the encoding does not permit
    ///      one: on a BUY order's output anchor, on an input leg that also carries
    ///      a decay endpoint (`end != 0`), on `legsIn[1..n]`, or on an order whose
    ///      denominator is a signed `fillTotal` / a `fillModule` rather than the
    ///      leg anchor. See the contract note for why the permitted position is
    ///      exactly `legsIn[0]` of a SELL.
    error InvalidProportionalLeg();
    /// @dev A proportional order was offered a partial fill. Its denominator is a
    ///      live balance, so progress cannot be measured across fills — see the
    ///      contract note.
    error ProportionalNeedsFullFill();
    /// @dev A proportional leg carries no cap (`end == 0`). MANDATORY — see the cap
    ///      section of the contract note. An uncapped sweep hands the maker's ENTIRE
    ///      balance over for the order's fixed output, and since anyone may raise
    ///      that balance by simply transferring tokens to the maker, an uncapped
    ///      order is an open invitation rather than a mere footgun. `end == 0` is
    ///      also the value an unset field has, so the dangerous mode would otherwise
    ///      be the one you get by not thinking about it.
    ///
    ///      A genuinely unbounded sweep is still expressible — set `end` to
    ///      {SENTINEL_FLOOR}, the largest value that is not itself a marker — so
    ///      this costs no expressiveness, only deliberateness.
    error ProportionalNeedsCap();

    /// @dev A `start` STRICTLY ABOVE this is a proportional marker. Equal to
    ///      `type(uint256).max - BPS`, i.e. ~1.15e77 — unreachable by any real
    ///      token amount, so the check can never misread ordinary order data.
    uint256 internal constant BPS = 10_000;

    uint256 internal constant SENTINEL_FLOOR = type(uint256).max - BPS;

    /// @notice Is this leg amount a proportional marker rather than an absolute
    ///         amount?
    /// @dev One compare against a constant on a word the caller has already
    ///      loaded — this is the per-leg cost paid by every fill, proportional or
    ///      not.
    function isProportional(uint256 start) internal pure returns (bool) {
        return start > SENTINEL_FLOOR;
    }

    /// @notice The bps (1..{BPS}) carried by a proportional marker.
    /// @dev Caller must have established {isProportional}; the subtraction below
    ///      is meaningless otherwise.
    function bps(uint256 start) internal pure returns (uint256) {
        unchecked {
            // `start > SENTINEL_FLOOR` ⇒ `type(uint256).max - start < BPS`, so
            // this lands in 1..BPS and cannot underflow.
            return BPS - (type(uint256).max - start);
        }
    }

    /// @notice Resolve a proportional marker against `owner`'s live balance of
    ///         `token`, capped at `cap` (0 = uncapped).
    /// @dev The multiplication is deliberately CHECKED. A balance large enough to
    ///      overflow `balance * bps` is not reachable with any real token, but
    ///      this is a value path that decides how much of a maker's money moves,
    ///      and a silent wrap here would under-price the maker's own leg. Revert
    ///      instead.
    function resolve(address token, address owner, uint256 start, uint256 cap) internal view returns (uint256 amount) {
        // Every resolution goes through here, so this is the one place the cap has
        // to be enforced for it to be enforced everywhere.
        if (cap == 0) revert ProportionalNeedsCap();
        amount = SafeTransferLib.balanceOf(token, owner) * bps(start) / BPS;
        if (amount > cap) amount = cap;
    }

    /// @notice Build the marker for `bpsValue` (1..{BPS}).
    /// @dev Not used by the settler — it exists so tests and any on-chain order
    ///      builder encode through the same arithmetic the reader decodes with,
    ///      rather than open-coding `type(uint256).max - ...` and drifting. The
    ///      SDK mirrors this exactly.
    function encode(uint256 bpsValue) internal pure returns (uint256) {
        require(bpsValue != 0 && bpsValue <= BPS, "Proportional: bps");
        unchecked {
            return type(uint256).max - (BPS - bpsValue);
        }
    }
}
