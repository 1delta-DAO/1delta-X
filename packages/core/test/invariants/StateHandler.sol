// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {Settlement, Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";

/// @dev The "lender" behind the walk's one item-bearing order: a TAKE module that
///      hands `produce` of `token` (both fixed in the signed `data`) to `receiver`,
///      whatever slice the settler asked for. Decoupling what it PRODUCES from what
///      the order OWES is the point — it is what drives both branches of the
///      netted path's credit ledger (over-credit → refund to the maker; under-credit
///      → `PULL` tops up exactly the gap) from one order.
contract FundingTakerMock is ITakerModule {
    address public immutable permit3;

    constructor(address _permit3) {
        permit3 = _permit3;
    }

    function takeOnBehalf(address, uint256, address receiver, bytes calldata data) external override {
        require(msg.sender == permit3, "only permit3");
        (address token, uint256 produce) = abi.decode(data, (address, uint256));
        MockERC20(token).transfer(receiver, produce);
    }
}

/// @title StateHandler
/// @notice The action driver behind {CoreStateInvariants} — a closed, fully-funded
///         world (3 makers, 2 fillers, 1 attacker, 9 orders, 4 candidate delegates,
///         one lender) in which the invariant fuzzer may call ANY lifecycle entry
///         point as ANY actor, in any order, at any time — the single-order hot
///         path and the netted {Settlement.matchSettle} path alike.
///
///  ── WHAT THIS ACTUALLY PROVES ────────────────────────────────────────────────
///  Every action here does the same three things:
///
///    1. SNAPSHOT the whole tracked state surface — the four state families the
///       settler owns — into a flat `uint256[N_CELLS]`;
///    2. run the action (always `try`/`catch`: a revert is a legitimate outcome and
///       must leave state untouched);
///    3. DIFF the snapshot and check every changed cell against an ALLOWLIST that
///       this action, performed by THIS caller, was entitled to move.
///
///  Step 3 is the whole point, and it is what a per-scenario unit test cannot give
///  you: it is a *negative* property over the entire state surface. "A fill moved
///  `filled[thisOrder]` and nothing else." "An attacker's `revokeOrderApproval` on a
///  stranger's order hash moved nothing at all." Griefing, front-running and theft in
///  this contract all reduce to a write landing in a cell whose key belongs to
///  somebody else, and every such write shows up here as an unallowed diff.
///
///  On top of the allowlist the diff enforces the MONOTONIC laws that make the
///  lifecycle irreversible — `filled` never decreases, the cancellation sentinel is
///  never cleared, a set nonce bit never clears, `minValidNonce` never retreats —
///  and each settled fill OR MATCH is checked for exact value conservation: every
///  maker, the lender, and the solver end the call with exactly the delta the
///  signed orders imply, whatever schedule the solver ran ({doMatchSettle}).
///
///  ⚠ VIOLATIONS ARE RECORDED, NOT REVERTED. The suite runs with
///  `fail_on_revert = false` (a fuzzer that may call anything as anyone will revert
///  constantly, by design), so an assertion that REVERTED inside a handler would be
///  swallowed whole and the suite would go green on a broken contract. Every finding
///  is therefore written to one of the four family strings and asserted by the
///  matching `invariant_*` function in the test contract.
contract StateHandler is MockSettlementBase {
    // ──────────────────── The universe ────────────────────

    /// @dev 6 SELL-tA orders (the original book), 2 mirror SELL-tB orders (the
    ///      counter-side a netted match needs) and 1 item-funded order — see {_def}.
    uint256 public constant N_ORDERS = 9;
    uint256 internal constant N_MAKERS = 3;
    uint256 internal constant N_SIGNERS = 4; // [0] is address(0) — see {signers}
    uint256 internal constant N_COORDS = 10;
    uint256 internal constant N_ACTORS = 6; // 3 makers + 2 fillers + 1 attacker

    /// @dev Mirrors {NonceManager.SIGNER_NONCE_NS}. Spelled out rather than imported
    ///      so the suite pins the CONSTANT, not the contract's opinion of it.
    uint256 internal constant NS = 1 << 255;
    uint256 internal constant CANCELLED = type(uint256).max;
    uint256 internal constant FILL_ONCE_BIT = 1 << 100;

    /// @dev Orders are rebuilt on demand and must hash IDENTICALLY every time, so the
    ///      deadline cannot come from `block.timestamp` — `doWarp` moves it.
    uint256 internal constant ORDER_EXPIRY = 4_102_444_800; // 2100-01-01

    uint256[N_MAKERS] internal makerPks;
    uint256[2] internal fillerPks;
    uint256[N_SIGNERS] internal signerPks; // [0] unused — signers[0] is address(0)

    address[N_MAKERS] public makers;
    address[2] public fillers;
    /// @dev Candidate delegates. `signers[0]` is deliberately `address(0)`: it is a
    ///      tracked cell that {OrderState.setOrderSigner} must never let leave zero,
    ///      which is the whole "a malformed signature recovers to 0" guard.
    address[N_SIGNERS] public signers;
    address public attacker;

    bytes32[N_ORDERS] public orderHashes;

    // ──────────────────── Cell layout ────────────────────
    //
    // One flat array so the diff is a single loop. The offsets are the only place the
    // layout is written down; every accessor below derives from them.

    uint256 internal constant OFF_APPROVED = N_ORDERS; //                 6
    uint256 internal constant OFF_SIGNER = OFF_APPROVED + N_MAKERS * N_ORDERS; // 24
    uint256 internal constant OFF_MINVALID = OFF_SIGNER + N_MAKERS * N_SIGNERS; // 36
    uint256 internal constant OFF_BIT = OFF_MINVALID + N_MAKERS; //      39
    uint256 internal constant N_CELLS = OFF_BIT + N_MAKERS * N_COORDS; // 69

    // ──────────────────── Findings, one string per state family ────────────────────

    uint256 internal constant F_FILL = 0;
    uint256 internal constant F_CANCEL = 1;
    uint256 internal constant F_APPROVAL = 2;
    uint256 internal constant F_DELEGATION = 3;

    string public fillViolation;
    string public cancelViolation;
    string public approvalViolation;
    string public delegationViolation;

    // Liveness counters — a suite where every action reverted proves nothing, so
    // {CoreStateInvariants} asserts these moved.
    uint256 public fillsSettled;
    uint256 public matchesSettled;
    uint256 public ordersCancelled;
    uint256 public approvalsRecorded;
    uint256 public delegationsWritten;
    uint256 public noncesCancelled;

    /// @dev The per-action allowlist, rebuilt by every action and cleared by `_close`.
    uint256[] internal allowed;

    /// @dev The lender behind order 8's TAKE item. Holds tA stock and nothing else.
    FundingTakerMock public taker;

    /// @dev Tokens DONATED straight to the settler by {doDonate}. Every balance-delta
    ///      window in the core is measured from a snapshot, so a donated balance is
    ///      documented as unreachable — never swept to a solver, never counted as an
    ///      item's proceeds. {CoreStateInvariants} asserts the settler holds EXACTLY
    ///      this much, and every conservation check below asserts nobody received it.
    mapping(address => uint256) public donated;

    // ──────────────────── Wiring ────────────────────

    /// @dev The handler deploys nothing; it attaches to the instances the test
    ///      contract already stood up, so both halves observe the same settler.
    function setUp() public override {}

    function init(Permit3 p3, Settlement s, MockERC20 a, MockERC20 b) external {
        permit3 = p3;
        settlement = s;
        tA = a;
        tB = b;

        makerPks = [uint256(0x111111), 0x222222, 0x333333];
        fillerPks = [uint256(0xF11111), 0xF22222];
        signerPks = [uint256(0), 0x511111, 0x522222, 0x533333];

        for (uint256 m; m < N_MAKERS; ++m) {
            makers[m] = vm.addr(makerPks[m]);
            // Both tokens: a maker must be able to act as the FILLER of somebody
            // else's order too, which is an ordinary cross-maker fill and a state
            // transition worth walking into.
            _arm(makers[m], tA);
            _arm(makers[m], tB);
        }
        for (uint256 f; f < 2; ++f) {
            fillers[f] = vm.addr(fillerPks[f]);
            // Both tokens: the mirror orders (6, 7) are paid in tA.
            _arm(fillers[f], tA);
            _arm(fillers[f], tB);
        }
        attacker = vm.addr(0xBADBAD);
        _arm(attacker, tA);
        _arm(attacker, tB);

        signers[0] = address(0);
        for (uint256 k = 1; k < N_SIGNERS; ++k) {
            signers[k] = vm.addr(signerPks[k]);
        }

        // The lender: stocked with tA, and maker 0 grants the settler a standing
        // taker allowance keyed to order 8's exact item `data` — the same
        // `(spender, module, ref)` triple the production flow authorises.
        taker = new FundingTakerMock(address(permit3));
        tA.mint(address(taker), 1e30);
        vm.prank(makers[0]);
        permit3.approveTaker(address(settlement), address(taker), keccak256(_itemData(8)), type(uint160).max, 0);

        for (uint256 i; i < N_ORDERS; ++i) {
            orderHashes[i] = _hashOrder(_mkOrder(i));
        }
    }

    /// @dev Fund + approve one actor for one token: ERC20 → Permit3 → Settlement,
    ///      the same two-hop the production flow uses.
    function _arm(address who, MockERC20 t) internal {
        t.mint(who, 1e30);
        vm.startPrank(who);
        t.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(t), type(uint160).max, 0);
        vm.stopPrank();
    }

    // ──────────────────── The order book ────────────────────

    /// @dev Fixed definitions. Note `i2`/`i3` SHARE nonce 2 on the same maker (the OCO
    ///      shape) so per-hash cancellation and per-nonce cancellation can be told
    ///      apart, and `i4` is the fill-once opt-in, whose progress is the nonce rather
    ///      than a `filled` counter.
    ///
    ///      Orders 0–5 all SELL tA for tB. A netted match needs the other side, so
    ///      `i6`/`i7` SELL tB for tA (`sellB`): 6 at exactly order 0's rate (a
    ///      balanced CoW nets to zero solver residue), 7 at a better one (the
    ///      residue is real and the sweep has something to pay). Both are sized to
    ///      outlast the whole tA side (~9.9M tB of demand against 45M of supply),
    ///      so a run's later matches are not all overfills of an exhausted mirror. `i8` is the one
    ///      ITEM-BEARING order: its tA input is funded by a TAKE against the lender
    ///      that always produces `produce` — below a full fill's owed amount, so a
    ///      `PULL` must top up the gap, and above a small partial fill's, so the
    ///      excess must come back to the maker. Same maker and same tokens as order
    ///      0, so it is also fillable on the hot path, where {_expectFill} applies
    ///      the identical arithmetic.
    struct Def {
        uint256 makerIdx;
        uint256 nonce;
        uint256 amtIn;
        uint256 amtOut;
        bool fillOnce;
        bool sellB;
        uint256 produce;
    }

    function _def(uint256 i) internal pure returns (Def memory) {
        if (i == 0) return Def(0, 0, 1_000_000, 2_000_000, false, false, 0);
        if (i == 1) return Def(0, 1, 900_001, 1_333_337, false, false, 0); // ceil-rounding pair
        if (i == 2) return Def(1, 2, 500_000, 1_000_001, false, false, 0);
        if (i == 3) return Def(1, 2, 600_000, 1_200_000, false, false, 0); // sibling on nonce 2
        if (i == 4) return Def(2, 3, 700_000, 1_400_000, true, false, 0); //  fill-once
        if (i == 5) return Def(2, 7, 800_000, 999_999, false, false, 0);
        if (i == 6) return Def(1, 3, 20_000_000, 10_000_000, false, true, 0); // mirror, rate 2
        if (i == 7) return Def(2, 1, 25_000_000, 10_000_000, false, true, 0); // mirror, rate 2.5
        return Def(0, 7, 1_000_000, 2_000_000, false, false, 600_000); //  item-funded
    }

    /// @dev Order 8's item `data` — the bytes the lender decodes AND the bytes the
    ///      taker allowance is keyed to, so they are spelled once.
    function _itemData(uint256 i) internal view returns (bytes memory) {
        return abi.encode(address(tA), _def(i).produce);
    }

    function _mkOrder(uint256 i) internal view returns (Order memory o) {
        Def memory d = _def(i);
        o = _blank(d.nonce);
        o.maker = makers[d.makerIdx];
        (address tIn, address tOut) = d.sellB ? (address(tB), address(tA)) : (address(tA), address(tB));
        o.legsIn = _legsIn1(tIn, d.amtIn);
        o.legsOut = _legsOut1(tOut, d.amtOut);
        _setExpiry(o, ORDER_EXPIRY);
        if (d.fillOnce) o.timing |= FILL_ONCE_BIT;
        if (d.produce != 0) {
            Item[] memory its = new Item[](1);
            its[0] = Item({
                op: ItemOp.TAKE,
                module: address(taker),
                amount: d.amtIn,
                recipient: address(0), // proceeds to the pool
                data: _itemData(i)
            });
            o.items = PackedEncode.items(its);
        }
    }

    function orderTotal(uint256 i) public pure returns (uint256) {
        return _def(i).amtIn;
    }

    function orderOut(uint256 i) public pure returns (uint256) {
        return _def(i).amtOut;
    }

    function orderMaker(uint256 i) public view returns (address) {
        return makers[_def(i).makerIdx];
    }

    function orderNonce(uint256 i) public pure returns (uint256) {
        return _def(i).nonce;
    }

    function isFillOnce(uint256 i) public pure returns (bool) {
        return _def(i).fillOnce;
    }

    /// @dev Token index (0 = tA, 1 = tB) of the order's input leg; the output leg is
    ///      the other one.
    function _tokIn(uint256 i) internal pure returns (uint256) {
        return _def(i).sellB ? 1 : 0;
    }

    function _tok(uint256 t) internal view returns (MockERC20) {
        return t == 0 ? tA : tB;
    }

    function orderProduce(uint256 i) public pure returns (uint256) {
        return _def(i).produce;
    }

    // ──────────────────── Nonce coordinates under observation ────────────────────

    /// @dev The coordinates the snapshot watches. The first six are ORDER space (every
    ///      nonce the book uses, plus a word-boundary probe); the last four are the
    ///      RESERVED half {Signatures.setOrderSignerWithSig} consumes. Watching both
    ///      halves is what turns "a relayed nomination must never burn an order nonce"
    ///      into a checkable diff rather than a comment.
    /// @dev The watched bitmap coordinates: six in ORDER space, then the signer half.
    ///
    ///      The signer half is no longer `NS | 0..3`. A permit's nonce is FORCED to
    ///      `(signer << 8) | seq` ({Signatures.SignerPermitNonceMalformed}), so those
    ///      coordinates are unreachable and watching them proved nothing. Each
    ///      candidate delegate gets its own watched coordinate at `seq = 0` instead,
    ///      which is also what makes the revocation burn observable: revoking a
    ///      delegate blanks that delegate's whole word, and its watched bit sits in
    ///      it. The order coordinates live in word 0 and every other delegate in its
    ///      own, so one revocation can flip exactly one watched bit.
    ///
    ///      `c == 9` is a NEGATIVE CONTROL — a free-form signer-space coordinate no
    ///      legal permit can consume, and no revocation can reach. It must never flip.
    function _coord(uint256 c) internal view returns (uint256) {
        if (c == 0) return 0;
        if (c == 1) return 1;
        if (c == 2) return 2;
        if (c == 3) return 3;
        if (c == 4) return 7;
        if (c == 5) return 255;
        if (c < 9) return NS | (uint256(uint160(signers[c - 5])) << 8);
        return NS | 3;
    }

    function _coordIdx(uint256 nonce) internal view returns (uint256) {
        for (uint256 c; c < N_COORDS; ++c) {
            if (_coord(c) == nonce) return c;
        }
        return type(uint256).max;
    }

    // ──────────────────── Snapshot / diff ────────────────────

    function _iFilled(uint256 i) internal pure returns (uint256) {
        return i;
    }

    function _iApproved(uint256 m, uint256 i) internal pure returns (uint256) {
        return OFF_APPROVED + m * N_ORDERS + i;
    }

    function _iSigner(uint256 m, uint256 k) internal pure returns (uint256) {
        return OFF_SIGNER + m * N_SIGNERS + k;
    }

    function _iMinValid(uint256 m) internal pure returns (uint256) {
        return OFF_MINVALID + m;
    }

    function _iBit(uint256 m, uint256 c) internal pure returns (uint256) {
        return OFF_BIT + m * N_COORDS + c;
    }

    function _snap() internal view returns (uint256[] memory s) {
        s = new uint256[](N_CELLS);
        for (uint256 i; i < N_ORDERS; ++i) {
            s[_iFilled(i)] = settlement.filled(orderHashes[i]);
        }
        for (uint256 m; m < N_MAKERS; ++m) {
            address mk = makers[m];
            for (uint256 i; i < N_ORDERS; ++i) {
                s[_iApproved(m, i)] = settlement.orderApproved(mk, orderHashes[i]) ? 1 : 0;
            }
            for (uint256 k; k < N_SIGNERS; ++k) {
                s[_iSigner(m, k)] = settlement.orderSignerExpiry(mk, signers[k]);
            }
            s[_iMinValid(m)] = settlement.minValidNonce(mk);
            for (uint256 c; c < N_COORDS; ++c) {
                uint256 n = _coord(c);
                s[_iBit(m, c)] = (settlement.nonceBitmap(mk, n >> 8) >> (n & 0xff)) & 1;
            }
        }
    }

    /// @dev Which family a cell belongs to, so a finding is filed under the state the
    ///      user asked about rather than in one undifferentiated bucket.
    function _familyOf(uint256 k) internal pure returns (uint256) {
        if (k < OFF_APPROVED) return F_FILL;
        if (k < OFF_SIGNER) return F_APPROVAL;
        if (k < OFF_MINVALID) return F_DELEGATION;
        return F_CANCEL; // minValidNonce + nonce bitmap
    }

    function _allow(uint256 k) internal {
        allowed.push(k);
    }

    function _isAllowed(uint256 k) internal view returns (bool) {
        uint256 n = allowed.length;
        for (uint256 j; j < n; ++j) {
            if (allowed[j] == k) return true;
        }
        return false;
    }

    /// @dev Close an action: diff the snapshot, file anything unallowed or
    ///      non-monotonic, then clear the allowlist for the next call.
    function _close(uint256[] memory before) internal {
        uint256[] memory nowS = _snap();
        for (uint256 k; k < N_CELLS; ++k) {
            uint256 a = before[k];
            uint256 b = nowS[k];
            if (a == b) continue;
            if (!_isAllowed(k)) _rec(_familyOf(k), "state mutated outside the caller's authority, cell", k);
            _monotonic(k, a, b);
        }
        delete allowed;
    }

    /// @dev The laws that hold for a cell's value regardless of WHO moved it.
    function _monotonic(uint256 k, uint256 a, uint256 b) internal {
        if (k < OFF_APPROVED) {
            // `filled` — the cancellation sentinel is terminal, progress never rewinds,
            // and progress never exceeds the order's own denominator.
            if (a == CANCELLED) _rec(F_FILL, "cancellation sentinel cleared, order", k);
            else if (b != CANCELLED && b < a) _rec(F_FILL, "filled decreased, order", k);
            if (b != CANCELLED && b > orderTotal(k)) _rec(F_FILL, "filled exceeded the order total, order", k);
        } else if (k >= OFF_BIT) {
            if (a == 1 && b == 0) _rec(F_CANCEL, "a cancelled nonce was un-cancelled, cell", k);
        } else if (k >= OFF_MINVALID) {
            if (b < a) _rec(F_CANCEL, "the rollback floor retreated, cell", k);
        }
        // Approval and delegation cells are freely writable BY THEIR OWNER in both
        // directions, so they carry no monotonic law — only the allowlist above.
    }

    function _rec(uint256 fam, string memory why, uint256 cell) internal {
        string memory msg_ = string.concat(why, " ", vm.toString(cell));
        if (fam == F_FILL) {
            if (bytes(fillViolation).length == 0) fillViolation = msg_;
        } else if (fam == F_CANCEL) {
            if (bytes(cancelViolation).length == 0) cancelViolation = msg_;
        } else if (fam == F_APPROVAL) {
            if (bytes(approvalViolation).length == 0) approvalViolation = msg_;
        } else {
            if (bytes(delegationViolation).length == 0) delegationViolation = msg_;
        }
    }

    // ──────────────────── Actor selection ────────────────────

    /// @dev Every entry point is callable by every actor. Half of them own no order at
    ///      all, which is exactly the population the authority checks exist for.
    function _actor(uint256 seed) internal view returns (address) {
        uint256 a = seed % N_ACTORS;
        if (a < N_MAKERS) return makers[a];
        if (a < N_MAKERS + 2) return fillers[a - N_MAKERS];
        return attacker;
    }

    function _makerIdxOf(address who) internal view returns (uint256) {
        for (uint256 m; m < N_MAKERS; ++m) {
            if (makers[m] == who) return m;
        }
        return type(uint256).max;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    // ═══════════════════════ FILL STATE ═══════════════════════

    // ──────────────────── Value conservation ────────────────────
    //
    // One ledger of EXPECTED balance deltas, shared by the hot path ({doFill}) and
    // the netted path ({doMatchSettle}). {_expectFill} adds what ONE settled fill of
    // order `i` at size `f` must do to every party; {_ledgerOpen} / {_ledgerCheck}
    // snapshot and compare. The party set is fixed — 3 makers, the lender, the
    // solver — and indexed by token (0 = tA, 1 = tB), so a fill of the item order
    // and a three-order match are the same arithmetic summed.

    struct Ledger {
        address solver;
        uint256 solverMaker; //   `_makerIdxOf(solver)`, or max — a maker may solve
        int256[2][N_MAKERS] expMaker; // [maker][token]
        int256[2] expSolver;
        int256 expLender; //      tA only — the lender stocks nothing else
        uint256[2][N_MAKERS] preMaker;
        uint256[2] preSolver;
        uint256 preLender;
    }

    function _ledgerOpen(Ledger memory L, address solver) internal view {
        L.solver = solver;
        L.solverMaker = _makerIdxOf(solver);
        for (uint256 m; m < N_MAKERS; ++m) {
            L.preMaker[m][0] = tA.balanceOf(makers[m]);
            L.preMaker[m][1] = tB.balanceOf(makers[m]);
        }
        L.preSolver[0] = tA.balanceOf(solver);
        L.preSolver[1] = tB.balanceOf(solver);
        L.preLender = tA.balanceOf(address(taker));
    }

    /// @dev What a settled fill of `f` anchor units of order `i` does to every
    ///      balance. The maker pays `f` of its input token — less whatever the
    ///      order's item PRODUCED, which on both paths is netted against the debt
    ///      (a shortfall is pulled from the wallet, an excess is returned to it) —
    ///      and receives the ceil-rounded output slice. The solver is paid the input
    ///      and pays the output; the lender is down exactly what its module handed
    ///      over. `produce` cancels between lender and maker, so the solver's side
    ///      never sees it — which is the "excess goes to the maker, never the
    ///      solver" rule in arithmetic form.
    function _expectFill(Ledger memory L, uint256 i, uint256 f) internal pure {
        Def memory d = _def(i);
        uint256 tIn = d.sellB ? 1 : 0;
        uint256 tOut = 1 - tIn;
        int256 out = int256(_ceilDiv(f * d.amtOut, d.amtIn));
        L.expMaker[d.makerIdx][tIn] += int256(d.produce) - int256(f);
        L.expMaker[d.makerIdx][tOut] += out;
        L.expSolver[tIn] += int256(f);
        L.expSolver[tOut] -= out;
        L.expLender -= int256(d.produce);
    }

    /// @dev Compare. A maker who is also the solver gets both expectations folded
    ///      onto its one balance — nothing is skipped.
    function _ledgerCheck(Ledger memory L, string memory who, uint256 cell) internal {
        for (uint256 t; t < 2; ++t) {
            MockERC20 tok = _tok(t);
            for (uint256 m; m < N_MAKERS; ++m) {
                int256 exp = L.expMaker[m][t];
                if (m == L.solverMaker) exp += L.expSolver[t];
                if (int256(tok.balanceOf(makers[m])) - int256(L.preMaker[m][t]) != exp) {
                    _rec(F_FILL, string.concat(who, ": a maker's balance moved off the signed amount, cell"), cell);
                }
            }
            if (L.solverMaker == type(uint256).max) {
                if (int256(tok.balanceOf(L.solver)) - int256(L.preSolver[t]) != L.expSolver[t]) {
                    _rec(F_FILL, string.concat(who, ": the solver was paid off the signed amount, cell"), cell);
                }
            }
        }
        if (int256(tA.balanceOf(address(taker))) - int256(L.preLender) != L.expLender) {
            _rec(F_FILL, string.concat(who, ": the lender moved off what its module produced, cell"), cell);
        }
    }

    /// @dev The ordinary fill: maker-signed, filler-submitted, any size.
    ///      Allowed to move `filled[thisOrder]` — or, for a fill-once order, the
    ///      maker's bit for THIS order's nonce — and nothing else in the world.
    ///
    ///      Locals are boxed in {FillProbe}: the pre-call readings, the post-call
    ///      checks and the diff together overflow the legacy-codegen stack frame.
    struct FillProbe {
        uint256 i;
        uint256 total;
        uint256 amount;
        bool dead;
        bool nonceDead;
        Ledger ledger;
    }

    function doFill(uint256 orderSeed, uint256 actorSeed, uint256 amountSeed) external {
        FillProbe memory p;
        p.i = orderSeed % N_ORDERS;
        p.total = orderTotal(p.i);
        Order memory o = _mkOrder(p.i);

        uint256[] memory before = _snap();
        {
            uint256 prevFilled = before[_iFilled(p.i)];
            p.dead = prevFilled == CANCELLED;
            // Half the time ask for everything that is left, so full fills (and
            // fill-once, which accepts nothing else) are reached often rather than by
            // luck; the other half is an arbitrary slice.
            uint256 remaining = (p.dead || prevFilled >= p.total) ? p.total : p.total - prevFilled;
            p.amount = amountSeed % 2 == 0 ? remaining : (amountSeed % p.total) + 1;
        }
        p.nonceDead = settlement.isNonceCancelled(o.maker, o.nonce);
        _ledgerOpen(p.ledger, _actor(actorSeed));
        _expectFill(p.ledger, p.i, p.amount);
        _allowFillCells(p.i);

        bytes memory sig = _signWith(o, makerPks[_makerIdxOf(o.maker)]);
        vm.prank(_actor(actorSeed));
        try settlement.fill(o, sig, p.amount) returns (uint256[] memory outs) {
            _checkSettledFill(p, outs);
        } catch {}
        _close(before);
    }

    /// @dev What a SETTLED fill has to be true of, whoever submitted it.
    function _checkSettledFill(FillProbe memory p, uint256[] memory outs) internal {
        ++fillsSettled;
        // A fill that lands on a killed order is the whole theft class this suite
        // exists to exclude — neither kill switch may be survivable.
        if (p.dead) _rec(F_FILL, "a cancelled order settled a fill, order", p.i);
        if (p.nonceDead) _rec(F_CANCEL, "an order on a cancelled nonce settled a fill, order", p.i);
        // Value conservation: the maker paid exactly the fill size (net of what its
        // item produced) and was paid the ceil-rounded slice — never a wei less, and
        // never more than the ceiling; the solver and the lender likewise. A SELF-fill
        // (nothing forbids a maker filling its own order) folds both sides onto one
        // balance rather than being skipped.
        _ledgerCheck(p.ledger, "fill", p.i);
        uint256 owed = _ceilDiv(p.amount * orderOut(p.i), p.total);
        if (outs.length == 0 || outs[0] != owed) _rec(F_FILL, "reported output != ceil slice, order", p.i);
    }

    /// @dev The empty-`sig` (on-chain approval) path. Success is only ever legitimate
    ///      when the maker's {OrderState.approveOrder} record was set AT THIS MOMENT —
    ///      unlike a signature, that record is revocable and is re-read on every fill.
    function doFillSigless(uint256 orderSeed, uint256 actorSeed) external {
        uint256 i = orderSeed % N_ORDERS;
        address filler = _actor(actorSeed);
        Order memory o = _mkOrder(i);
        uint256 total = orderTotal(i);

        uint256[] memory before = _snap();
        bool wasApproved = settlement.orderApproved(o.maker, orderHashes[i]);
        uint256 prevFilled = before[_iFilled(i)];
        uint256 amount = prevFilled >= total || prevFilled == CANCELLED ? total : total - prevFilled;

        _allowFillCells(i);
        vm.prank(filler);
        try settlement.fill(o, "", amount) returns (uint256[] memory) {
            ++fillsSettled;
            if (!wasApproved) _rec(F_APPROVAL, "an unapproved order settled a sigless fill, order", i);
        } catch {}
        _close(before);
    }

    /// @dev A delegate-signed fill. Success is legitimate only if the recovered signer
    ///      was a LIVE nomination of THIS order's maker — or if the order was already
    ///      touched, which is the documented first-fill skip
    ///      ({Signatures._verifySignature}): once `filled != 0` the signature is not
    ///      re-read at all. Encoding the caveat is the point; if the skip ever widened
    ///      to an untouched order this fires.
    function doFillAsDelegate(uint256 orderSeed, uint256 actorSeed, uint256 signerSeed) external {
        uint256 i = orderSeed % N_ORDERS;
        uint256 k = (signerSeed % (N_SIGNERS - 1)) + 1; // never the zero address
        address filler = _actor(actorSeed);
        Order memory o = _mkOrder(i);

        uint256[] memory before = _snap();
        uint256 prevFilled = before[_iFilled(i)];
        uint256 expiry = settlement.orderSignerExpiry(o.maker, signers[k]);
        bool nominated = expiry != 0 && block.timestamp <= expiry;

        _allowFillCells(i);
        bytes memory sig = _signWith(o, signerPks[k]);
        vm.prank(filler);
        try settlement.fill(o, sig, orderTotal(i) / 4 + 1) returns (uint256[] memory) {
            ++fillsSettled;
            if (!nominated && prevFilled == 0) {
                _rec(F_DELEGATION, "a non-delegate opened an untouched order, order", i);
            }
        } catch {}
        _close(before);
    }

    /// @dev A structurally valid but WRONG signature (the attacker's key over the
    ///      order digest). It may never open an untouched order. On a touched one the
    ///      first-fill skip lets it through — deliberate, documented, and pinned here
    ///      so the boundary cannot move silently.
    function doFillBadSig(uint256 orderSeed, uint256 actorSeed) external {
        uint256 i = orderSeed % N_ORDERS;
        address filler = _actor(actorSeed);
        Order memory o = _mkOrder(i);

        uint256[] memory before = _snap();
        uint256 prevFilled = before[_iFilled(i)];

        _allowFillCells(i);
        bytes memory sig = _signWith(o, 0xBADBAD);
        vm.prank(filler);
        try settlement.fill(o, sig, orderTotal(i) / 3 + 1) returns (uint256[] memory) {
            ++fillsSettled;
            if (prevFilled == 0) _rec(F_FILL, "a forged signature opened an untouched order, order", i);
        } catch {}
        _close(before);
    }

    /// @dev The cells a fill of order `i` may legitimately move: its own counter, plus
    ///      — for the fill-once opt-in only — the maker's bit for its own nonce, which
    ///      is where that order's progress is recorded instead.
    function _allowFillCells(uint256 i) internal {
        _allow(_iFilled(i));
        Def memory d = _def(i);
        if (d.fillOnce) {
            uint256 c = _coordIdx(d.nonce);
            if (c != type(uint256).max) _allow(_iBit(d.makerIdx, c));
        }
    }

    // ═══════════════════════ THE NETTED PATH ═══════════════════════

    /// @dev Everything one {doMatchSettle} has to carry across the call.
    struct MatchProbe {
        uint256 n; //           orders in the plan, 2 or 3
        uint256[3] idx; //      book index per slot
        uint256[3] req; //      the fill REQUESTED — may be the whole-remaining sentinel
        uint256[3] fill; //     the fill it RESOLVES to — what the arithmetic is on
        uint256[3] prev; //     `filled` at call time
        bool deadSentinel; //   some slot sits on a parked cancellation sentinel
        bool deadNonce; //      some slot sits on a cancelled nonce
        bool complete; //       the schedule CAN legitimately settle — see {_matchSchedule}
        bool doubled; //        an exactly-once step (ITEM / DELIVER) appears twice
        bool poolShort; //      Σ owed − Σ out < 0 in some token: nobody covers it here
        Ledger ledger;
    }

    /// @dev The netted path — {Settlement.matchSettle} — with the SCHEDULE fuzzed.
    ///
    ///      Two or three orders, at least one tA seller and one tB seller, sized so
    ///      that a balanced coincidence of wants is reached often (the tB seller is
    ///      usually sized to exactly what the tA sellers demand) but not always. The
    ///      canonical `[PULL…, ITEM…, DELIVER…]` schedule is then MUTATED: shuffled
    ///      into an arbitrary interleaving, a `PULL` duplicated, a step dropped, a
    ///      `PRESEND` inserted anywhere, or an ITEM/DELIVER duplicated.
    ///
    ///      The claim under test is the one `Batch.matchSettle` makes for itself:
    ///      ANY schedule yields a correct settlement or a revert — never a
    ///      wrong-but-successful one. So nothing here asserts that a schedule
    ///      settles; it asserts what must be true IF it did:
    ///        • every maker, the solver and the lender moved by EXACTLY the signed
    ///          arithmetic, whatever the interleaving — a duplicate `PULL` cost the
    ///          maker nothing (the second draws `owed − credit = 0`), an item's
    ///          over-production came back to the maker and never reached the sweep,
    ///          a `PRESEND` only advanced money the solver was owed anyway;
    ///        • the schedule was complete — every DELIVER and ITEM present, every
    ///          input leg either pulled or covered by its item's proceeds;
    ///        • no exactly-once step ran twice;
    ///        • the pool was never short — if Σ owed < Σ out in a token the match
    ///          MUST revert, because no CALL step here fronts the difference;
    ///        • no dead order (sentinel or nonce) settled, and `filled` advanced by
    ///          exactly the resolved sizes;
    ///        • and, via {_close}, only the plan's own `filled` cells moved.
    function doMatchSettle(
        uint256 aSeed,
        uint256 bSeed,
        uint256 cSeed,
        uint256 fillSeed,
        uint256 actorSeed,
        uint256 schedSeed
    ) external {
        MatchProbe memory p;
        p.n = cSeed % 3 == 0 ? 3 : 2;
        p.idx[0] = _sideA(aSeed);
        p.idx[1] = 6 + (bSeed % 2);
        if (p.n == 3) p.idx[2] = (cSeed / 3) % N_ORDERS; // anything — a repeat, a second mirror

        uint256[] memory before = _snap();
        _ledgerOpen(p.ledger, _actor(actorSeed));
        // The tA sellers are sized first (slots 0 and 2), the tB seller (slot 1)
        // against what they demand.
        _sizeSlot(p, before, 0, fillSeed);
        if (p.n == 3) _sizeSlot(p, before, 2, fillSeed >> 128);
        _sizeSlot(p, before, 1, fillSeed >> 64);
        for (uint256 x; x < p.n; ++x) {
            _allowFillCells(p.idx[x]);
            _expectFill(p.ledger, p.idx[x], p.fill[x]);
        }
        p.poolShort = p.ledger.expSolver[0] < 0 || p.ledger.expSolver[1] < 0;

        MatchPlan memory plan = _matchPlan(p, schedSeed);
        vm.prank(p.ledger.solver);
        try settlement.matchSettle(plan) returns (uint256[][] memory, address[] memory, uint256[] memory) {
            _checkSettledMatch(p);
        } catch {}
        _close(before);
    }

    /// @dev A tA seller: the six original orders and the item-funded one.
    function _sideA(uint256 seed) internal pure returns (uint256) {
        uint256 c = seed % 7;
        return c == 6 ? 8 : c;
    }

    /// @dev Resolve slot `x`'s fill. Sellers of tA: half the time the whole
    ///      remainder (a quarter of that via the `type(uint256).max` sentinel, which
    ///      the settler resolves to the same number), otherwise an arbitrary slice.
    ///      The tB seller: usually EXACTLY the tB the tA sellers are owed — a balanced
    ///      CoW against order 6, a real solver residue against order 7 — sometimes
    ///      that plus slack, sometimes arbitrary.
    function _sizeSlot(MatchProbe memory p, uint256[] memory before, uint256 x, uint256 seed) internal view {
        uint256 i = p.idx[x];
        uint256 total = orderTotal(i);
        p.prev[x] = before[_iFilled(i)];
        if (p.prev[x] == CANCELLED) p.deadSentinel = true;
        if (settlement.isNonceCancelled(orderMaker(i), orderNonce(i))) p.deadNonce = true;
        uint256 remaining = (p.prev[x] == CANCELLED || p.prev[x] >= total) ? total : total - p.prev[x];
        uint256 mode = seed % 4;
        uint256 f;
        if (x == 1) {
            // What the tA sellers are owed in tB (the floor for a whole pool) and
            // what they pay in tA (which bounds how much tA this seller may be owed
            // in return — the ceiling). Between the two the solver ends whole in
            // both tokens; above the ceiling the pool is short of tA and the match
            // must revert.
            uint256 demand;
            uint256 supplyA;
            for (uint256 y; y < p.n; ++y) {
                if (y == 1 || _def(p.idx[y]).sellB) continue;
                demand += _ceilDiv(p.fill[y] * orderOut(p.idx[y]), orderTotal(p.idx[y]));
                supplyA += p.fill[y];
            }
            uint256 ceiling = supplyA * total / orderOut(i);
            if (mode < 2) f = demand;
            else if (mode == 2) f = ceiling > demand ? demand + (seed / 4) % (ceiling - demand + 1) : demand;
            else f = (seed / 4) % remaining + 1;
            if (f == 0) f = 1;
        } else {
            // Slices are drawn from the REMAINDER, not the total: the overfill probe
            // is {doFill}'s job, and a match that overfills teaches nothing new.
            f = mode < 2 ? remaining : (seed / 4) % remaining + 1;
        }
        p.fill[x] = f;
        p.req[x] = (f == remaining && mode == 1) ? type(uint256).max : f;
    }

    function _matchPlan(MatchProbe memory p, uint256 schedSeed) internal view returns (MatchPlan memory plan) {
        plan.orders = new Order[](p.n);
        plan.sigs = new bytes[](p.n);
        plan.fillAmounts = new uint256[](p.n);
        for (uint256 x; x < p.n; ++x) {
            Order memory o = _mkOrder(p.idx[x]);
            plan.orders[x] = o;
            plan.sigs[x] = _signWith(o, makerPks[_def(p.idx[x]).makerIdx]);
            plan.fillAmounts[x] = p.req[x];
        }
        plan.takerDatas = new bytes[](0);
        plan.callTargets = new address[](0);
        plan.callDatas = new bytes[](0);
        plan.schedule = _matchSchedule(p, schedSeed);
    }

    /// @dev Mirror of {MatchStep.pack}.
    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return kind | (a << 8) | (b << 24);
    }

    /// @dev The canonical schedule, then one mutation (`seed % 6`), then — half the
    ///      time — a shuffle on top. Sets `p.complete` / `p.doubled` from the FINAL
    ///      step list, so the expectation tracks what was actually submitted.
    function _matchSchedule(MatchProbe memory p, uint256 seed) internal pure returns (uint256[] memory s) {
        uint256 nItems;
        for (uint256 x; x < p.n; ++x) {
            if (orderProduce(p.idx[x]) != 0) ++nItems;
        }
        s = new uint256[](2 * p.n + nItems);
        uint256 w;
        for (uint256 x; x < p.n; ++x) {
            s[w++] = _step(MatchStep.PULL, x, 0);
        }
        for (uint256 x; x < p.n; ++x) {
            if (orderProduce(p.idx[x]) != 0) s[w++] = _step(MatchStep.ITEM, x, 0);
        }
        for (uint256 x; x < p.n; ++x) {
            s[w++] = _step(MatchStep.DELIVER, x, 0);
        }
        uint256 mode = seed % 6;
        if (mode == 2) {
            s = _append(s, _step(MatchStep.PULL, (seed >> 8) % p.n, 0)); // tolerated, must cost nothing
        } else if (mode == 3) {
            s = _drop(s, (seed >> 8) % s.length); //                       usually fatal
        } else if (mode == 4) {
            s = _insert(s, (seed >> 16) % (s.length + 1), _step(MatchStep.PRESEND, (seed >> 8) % 2, 0));
        } else if (mode == 5) {
            // Re-run an exactly-once step: an item (borrow twice) if the plan has
            // one, else a delivery (drain the pool). Neither may ever settle.
            uint256 k = (seed >> 8) % (s.length - p.n) + p.n; // any step after the PULLs
            s = _append(s, s[k]);
            p.doubled = true;
        }
        if (mode == 1 || (seed >> 24) % 2 == 1) _shuffle(s, seed >> 32);
        p.complete = _isComplete(p, s);
    }

    /// @dev A schedule can legitimately settle only if every slot's DELIVER is
    ///      present, its ITEM (if any) is present, and its input is covered — by a
    ///      `PULL`, or by the item alone when that produces at least what is owed.
    function _isComplete(MatchProbe memory p, uint256[] memory s) internal pure returns (bool) {
        for (uint256 x; x < p.n; ++x) {
            bool pulled;
            bool delivered;
            bool ran;
            for (uint256 k; k < s.length; ++k) {
                uint256 kind = s[k] & 0xff;
                uint256 a = (s[k] >> 8) & 0xffff;
                if (a != x) continue;
                if (kind == MatchStep.PULL) pulled = true;
                else if (kind == MatchStep.DELIVER) delivered = true;
                else if (kind == MatchStep.ITEM) ran = true;
            }
            uint256 produce = orderProduce(p.idx[x]);
            if (!delivered) return false;
            if (produce != 0 && !ran) return false;
            if (!pulled && produce < p.fill[x]) return false;
        }
        return true;
    }

    function _checkSettledMatch(MatchProbe memory p) internal {
        ++matchesSettled;
        uint256 cell = p.idx[0];
        if (p.deadSentinel) _rec(F_FILL, "a match settled a cancelled order, order", cell);
        if (p.deadNonce) _rec(F_CANCEL, "a match settled an order on a cancelled nonce, order", cell);
        if (!p.complete) _rec(F_FILL, "an incomplete schedule settled, order", cell);
        if (p.doubled) _rec(F_FILL, "an exactly-once step ran twice and the match settled, order", cell);
        if (p.poolShort) _rec(F_FILL, "a match settled with the pool short, order", cell);
        _ledgerCheck(p.ledger, "match", cell);
        // Progress: each order's counter advanced by exactly the sum of its resolved
        // fills in this plan (an order may appear in two slots). Fill-once orders
        // keep no counter — {CoreStateInvariants} pins that separately.
        for (uint256 x; x < p.n; ++x) {
            uint256 i = p.idx[x];
            if (isFillOnce(i)) continue;
            uint256 sum;
            for (uint256 y; y < p.n; ++y) {
                if (p.idx[y] == i) sum += p.fill[y];
            }
            if (settlement.filled(orderHashes[i]) != p.prev[x] + sum) {
                _rec(F_FILL, "a match advanced filled by other than its resolved sizes, order", i);
            }
        }
    }

    // ──────────────────── Memory-array helpers for the schedule ────────────────────

    function _append(uint256[] memory a, uint256 v) internal pure returns (uint256[] memory b) {
        b = new uint256[](a.length + 1);
        for (uint256 k; k < a.length; ++k) {
            b[k] = a[k];
        }
        b[a.length] = v;
    }

    function _drop(uint256[] memory a, uint256 at) internal pure returns (uint256[] memory b) {
        b = new uint256[](a.length - 1);
        uint256 w;
        for (uint256 k; k < a.length; ++k) {
            if (k != at) b[w++] = a[k];
        }
    }

    function _insert(uint256[] memory a, uint256 at, uint256 v) internal pure returns (uint256[] memory b) {
        b = new uint256[](a.length + 1);
        uint256 w;
        for (uint256 k; k <= a.length; ++k) {
            if (k == at) b[w++] = v;
            if (k < a.length) b[w++] = a[k];
        }
    }

    /// @dev Fisher–Yates over the seed's nibbles-worth of entropy; in place.
    function _shuffle(uint256[] memory a, uint256 seed) internal pure {
        for (uint256 k = a.length; k > 1; --k) {
            uint256 j = seed % k;
            seed /= k;
            (a[k - 1], a[j]) = (a[j], a[k - 1]);
        }
    }

    // ═══════════════════════ DONATIONS ═══════════════════════

    /// @dev A stray transfer straight into the settler. The core measures every
    ///      proceeds window and every sweep from a snapshot taken at the top of the
    ///      call, so money that was already there is documented as UNREACHABLE: no
    ///      solver is ever paid it, no item is ever credited it, and no one can get
    ///      it out. The tally makes that a checked property: the settler's balance
    ///      must equal `donated` exactly ({CoreStateInvariants}), and every
    ///      conservation check above is blind to it by construction — so a sweep
    ///      that dipped into the donation would surface as an over-paid solver.
    function doDonate(uint256 actorSeed, uint256 tokSeed, uint256 amtSeed) external {
        address who = _actor(actorSeed);
        MockERC20 t = _tok(tokSeed % 2);
        uint256 amt = amtSeed % 1_000_000 + 1;

        uint256[] memory before = _snap();
        vm.prank(who);
        try t.transfer(address(settlement), amt) {
            donated[address(t)] += amt;
        } catch {}
        _close(before);
    }

    // ═══════════════════════ CANCELLATION STATE ═══════════════════════

    /// @dev Per-hash cancellation. Only the order's own maker may park the sentinel;
    ///      for anyone else the allowlist is EMPTY, so a successful call by a stranger
    ///      is reported rather than tolerated.
    function doCancelOrder(uint256 orderSeed, uint256 actorSeed) external {
        uint256 i = orderSeed % N_ORDERS;
        address caller = _actor(actorSeed);
        Order memory o = _mkOrder(i);

        uint256[] memory before = _snap();
        if (caller == o.maker) _allow(_iFilled(i));

        vm.prank(caller);
        try settlement.cancelOrder(o) returns (bytes32 h) {
            ++ordersCancelled;
            if (h != orderHashes[i]) _rec(F_FILL, "cancelOrder returned the wrong hash, order", i);
            if (caller != o.maker) _rec(F_FILL, "a stranger cancelled an order, order", i);
            if (settlement.filled(orderHashes[i]) != CANCELLED) {
                _rec(F_FILL, "cancelOrder did not park the sentinel, order", i);
            }
        } catch {}
        _close(before);
    }

    /// @dev Bulk nonce cancellation over the watched coordinate set, ORDER space and
    ///      the reserved nomination half alike.
    function doCancelNonces(uint256 actorSeed, uint256 c0Seed, uint256 c1Seed) external {
        address caller = _actor(actorSeed);
        uint256 c0 = c0Seed % N_COORDS;
        uint256 c1 = c1Seed % N_COORDS;

        uint256[] memory before = _snap();
        uint256 m = _makerIdxOf(caller);
        if (m != type(uint256).max) {
            _allow(_iBit(m, c0));
            _allow(_iBit(m, c1));
        }

        uint256[] memory ns = new uint256[](2);
        ns[0] = _coord(c0);
        ns[1] = _coord(c1);
        vm.prank(caller);
        try settlement.cancelOrders(ns) {
            ++noncesCancelled;
            if (!settlement.isNonceCancelled(caller, ns[0]) || !settlement.isNonceCancelled(caller, ns[1])) {
                _rec(F_CANCEL, "cancelOrders left a nonce live, coord", c0);
            }
        } catch {}
        _close(before);
    }

    /// @dev The rollback floor. Bounded to 0..3 so it retires part of the book without
    ///      permanently sterilising every maker (nonces 3 and 7 stay reachable) — the
    ///      floor is monotonic, so one unbounded call would end the run's fill coverage.
    function doRollback(uint256 actorSeed, uint256 floorSeed) external {
        address caller = _actor(actorSeed);
        uint256 floor_ = floorSeed % 4;

        uint256[] memory before = _snap();
        uint256 m = _makerIdxOf(caller);
        uint256 prev = m == type(uint256).max ? 0 : before[_iMinValid(m)];
        if (m != type(uint256).max) _allow(_iMinValid(m));

        vm.prank(caller);
        try settlement.rollbackNonces(floor_) {
            if (floor_ < prev) _rec(F_CANCEL, "rollbackNonces accepted a retreat, floor", floor_);
            // The floor is a cancellation in its own right: everything below it must
            // read as cancelled immediately, bitmap or no bitmap.
            if (floor_ > 0 && !settlement.isNonceCancelled(caller, floor_ - 1)) {
                _rec(F_CANCEL, "a nonce below the floor still reads live, floor", floor_);
            }
        } catch {}
        _close(before);
    }

    /// @dev Word-level invalidation. Either the order word (0) or the word the reserved
    ///      nomination half lives in.
    function doInvalidateWord(uint256 actorSeed, uint256 wordSeed) external {
        address caller = _actor(actorSeed);
        uint256 word = wordSeed % 2 == 0 ? 0 : (NS >> 8);

        uint256[] memory before = _snap();
        uint256 m = _makerIdxOf(caller);
        if (m != type(uint256).max) {
            for (uint256 c; c < N_COORDS; ++c) {
                if (_coord(c) >> 8 == word) _allow(_iBit(m, c));
            }
        }

        vm.prank(caller);
        try settlement.invalidateNonceWord(word) {
            ++noncesCancelled;
        } catch {}
        _close(before);
    }

    // ═══════════════════════ APPROVAL STATE ═══════════════════════

    /// @dev On-chain order authorization. The record is keyed by `msg.sender` and the
    ///      call demands `order.maker == msg.sender`, so the only reachable cell is the
    ///      caller's own row for this order.
    function doApproveOrder(uint256 orderSeed, uint256 actorSeed) external {
        uint256 i = orderSeed % N_ORDERS;
        address caller = _actor(actorSeed);
        Order memory o = _mkOrder(i);

        uint256[] memory before = _snap();
        uint256 m = _makerIdxOf(caller);
        if (m != type(uint256).max) _allow(_iApproved(m, i));

        vm.prank(caller);
        try settlement.approveOrder(o) returns (bytes32) {
            ++approvalsRecorded;
            if (caller != o.maker) _rec(F_APPROVAL, "a stranger approved an order, order", i);
        } catch {}
        _close(before);
    }

    /// @dev The batch form. Its extra property is ATOMICITY: a ladder containing one
    ///      order the caller does not own must approve NOTHING — a multisig may not
    ///      half-approve. The allowlist covers both cells, so a partial write shows up
    ///      as the wrong cell count only if it lands elsewhere; the explicit check
    ///      below is what catches a half-applied batch.
    function doApproveOrders(uint256 aSeed, uint256 bSeed, uint256 actorSeed) external {
        uint256 i = aSeed % N_ORDERS;
        uint256 j = bSeed % N_ORDERS;
        address caller = _actor(actorSeed);

        uint256[] memory before = _snap();
        uint256 m = _makerIdxOf(caller);
        if (m != type(uint256).max) {
            _allow(_iApproved(m, i));
            _allow(_iApproved(m, j));
        }

        Order[] memory batch = new Order[](2);
        batch[0] = _mkOrder(i);
        batch[1] = _mkOrder(j);
        bool bothOwned = batch[0].maker == caller && batch[1].maker == caller;

        vm.prank(caller);
        try settlement.approveOrders(batch) returns (bytes32[] memory) {
            ++approvalsRecorded;
            if (!bothOwned) _rec(F_APPROVAL, "approveOrders accepted a foreign order, order", i);
        } catch {
            // Reverted — the diff below proves nothing was written, which IS the
            // atomicity property. Nothing more to assert here.
        }
        _close(before);
    }

    /// @dev Revocation takes a BARE HASH, which makes it the sharpest griefing surface
    ///      in the contract: it escalates a touched order to a full cancel. The guard
    ///      is that the escalation only fires if the CALLER's own approval flag was
    ///      set. The allowlist therefore admits `filled[i]` only when the caller really
    ///      held that flag a moment ago — so a stranger reaching the sentinel is a
    ///      reported violation, not an accepted write.
    function doRevokeApproval(uint256 orderSeed, uint256 actorSeed) external {
        uint256 i = orderSeed % N_ORDERS;
        address caller = _actor(actorSeed);

        uint256[] memory before = _snap();
        bool heldFlag = settlement.orderApproved(caller, orderHashes[i]);
        uint256 m = _makerIdxOf(caller);
        if (m != type(uint256).max) _allow(_iApproved(m, i));
        if (heldFlag) _allow(_iFilled(i));

        vm.prank(caller);
        try settlement.revokeOrderApproval(orderHashes[i]) {
            if (settlement.orderApproved(caller, orderHashes[i])) {
                _rec(F_APPROVAL, "revokeOrderApproval left the flag set, order", i);
            }
            // The documented escalation: a revoked approval on a TOUCHED order must
            // become a full cancel, or the first-fill signature skip would let any
            // 65 arbitrary bytes settle the remainder of a withdrawn order.
            if (heldFlag && before[_iFilled(i)] != 0 && settlement.filled(orderHashes[i]) != CANCELLED) {
                _rec(F_APPROVAL, "a revoked, part-filled order was left fillable, order", i);
            }
        } catch {}
        _close(before);
    }

    // ═══════════════════════ DELEGATION STATE ═══════════════════════

    /// @dev Direct nomination. The registry is keyed by `msg.sender`, so the only
    ///      reachable row is the caller's own — nobody can nominate a signer for
    ///      somebody else, which is the entire difference between this and an operator.
    function doSetOrderSigner(uint256 actorSeed, uint256 signerSeed, uint256 expirySeed) external {
        address caller = _actor(actorSeed);
        uint256 k = signerSeed % N_SIGNERS; // may be index 0 == address(0)
        uint256 expiry = expirySeed % 3 == 0 ? 0 : block.timestamp + (expirySeed % 30 days);

        uint256[] memory before = _snap();
        uint256 m = _makerIdxOf(caller);
        if (m != type(uint256).max && k != 0) {
            _allow(_iSigner(m, k));
            // A REVOCATION also blanks the delegate's whole permit word — the single
            // `SSTORE` that makes revocation final ({OrderState._setOrderSigner}).
            // That delegate's watched coordinate lives in it; nothing else does. A
            // direct SHORTENING burns it too (audit 2026-09-30 X-DIFF-CORE-3), so an
            // unrelayed longer permit cannot undo the wind-down — and ONLY a
            // revocation or a shortening may: an extension that burned it would be a
            // regression this diff still catches.
            if (expiry == 0 || expiry < settlement.orderSignerExpiry(caller, signers[k])) {
                _allow(_iBit(m, 5 + k));
            }
        }

        vm.prank(caller);
        try settlement.setOrderSigner(signers[k], expiry) {
            ++delegationsWritten;
            if (k == 0) _rec(F_DELEGATION, "address(0) was authorized as a signer, cell", 0);
        } catch {}
        _close(before);
    }

    /// @dev The RELAYED nomination — anyone may submit it, the permit carries its own
    ///      authorization. Two properties ride on this one action:
    ///        • the write lands on the SIGNING maker's row, never the relayer's;
    ///        • replay protection consumes `nonce | SIGNER_NONCE_NS` and NEVER the bare
    ///          coordinate. That namespace is a kill switch: sharing it made an
    ///          unrelayed permit a third-party-triggerable cancel on every order the
    ///          maker later signed with the same nonce. The bare coordinate is watched
    ///          and NOT allowlisted, so any regression lands as a diff.
    function doSetOrderSignerWithSig(uint256 makerSeed, uint256 signerSeed, uint256 nonceSeed, uint256 relayerSeed)
        external
    {
        uint256 m = makerSeed % N_MAKERS;
        uint256 k = (signerSeed % (N_SIGNERS - 1)) + 1;
        // FORCED derivation: the settler requires `nonce >> 8 == uint160(signer)`, so
        // the handler cannot pick a free coordinate even if it wanted to. `seq = 0`
        // is the one this delegate's watched coordinate tracks.
        uint256 n = uint256(uint160(signers[k])) << 8;
        uint256 expiry = nonceSeed % 3 == 0 ? 0 : block.timestamp + 7 days;
        uint256 deadline = block.timestamp + 1 days;
        // Every other permit is signed by the WRONG key: an outsider forging a
        // nomination for a maker must never write that maker's row.
        bool forged = relayerSeed % 2 == 1;
        uint256 pk = forged ? 0xBADBAD : makerPks[m];

        uint256[] memory before = _snap();
        _allow(_iSigner(m, k));
        // The RESERVED coordinate for THIS delegate — and only it. A revocation
        // (`expiry == 0`) blanks the delegate's whole word, but this is the only
        // watched bit inside it, so the allowance stays exact either way.
        _allow(_iBit(m, 5 + k));

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                settlement.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256(
                            "OrderSignerPermit(address maker,address signer,uint256 expiry,uint256 nonce,uint256 deadline)"
                        ),
                        makers[m],
                        signers[k],
                        expiry,
                        n,
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.prank(_actor(relayerSeed));
        try settlement.setOrderSignerWithSig(makers[m], signers[k], expiry, n, deadline, abi.encodePacked(r, s, v)) {
            ++delegationsWritten;
            if (forged) _rec(F_DELEGATION, "a forged permit wrote a maker's registry row, maker", m);
            if (settlement.orderSignerExpiry(makers[m], signers[k]) != expiry) {
                _rec(F_DELEGATION, "the relayed nomination did not take effect, maker", m);
            }
            if (!settlement.isNonceCancelled(makers[m], NS | n)) {
                _rec(F_DELEGATION, "the reserved permit coordinate was not consumed, nonce", n);
            }
        } catch {}
        _close(before);
    }

    // ═══════════════════════ TIME ═══════════════════════

    /// @dev Time alone must move nothing. A lapsing delegation is a change in what the
    ///      registry MEANS, never a change in what it STORES — the empty allowlist here
    ///      is the assertion.
    function doWarp(uint256 seed) external {
        uint256[] memory before = _snap();
        vm.warp(block.timestamp + (seed % 10 days) + 1);
        _close(before);
    }
}
