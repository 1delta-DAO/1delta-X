// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MatchPlan, ItemOp} from "@core/settlement/Settlement.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {MatchRaceGuard} from "@solvers/base/MatchRaceGuard.sol";

/// @notice Where {MatchFlashSolver} borrows the plan's working capital.
/// @dev    UNI_V3_FLASH — `pool.flash()` on a Uniswap-v3-style pool DERIVED from the
///                        venue allowlist; repaid `amount + fee` by transfer.
///         UNI_V3_SWAP  — a v3 FLASH SWAP: `pool.swap()` exact-output of `token`,
///                        paid in `pairToken` inside the swap callback. One pool is
///                        both the flash and the repayment swap, so it is the shape
///                        for a pair with ONE liquid pool (a pool is `lock`ed during
///                        its own flash, so `UNI_V3_FLASH` plus a swap on the SAME
///                        pool reverts `LOK`).
///         BALANCER_V2  — the immutable vault's `flashLoan`; repaid by transfer.
///         AAVE_V3      — the immutable pool's `flashLoanSimple`; repaid by an EXACT
///                        approval the pool pulls (`amount + premium`).
///         MORPHO       — the immutable singleton's `flashLoan`; exact approval, pulled.
///         EULER        — an EVK vault named per call (`FlashSource.vault`); repaid
///                        by transfer. Never flash from the vault the plan deposits
///                        into: EVK holds the vault's lock through the callback.
enum FlashKind {
    UNI_V3_FLASH,
    UNI_V3_SWAP,
    BALANCER_V2,
    AAVE_V3,
    MORPHO,
    EULER
}

/// @notice One Uniswap-v3-style deployment: pools are never taken from calldata, they
///         are recomputed as `CREATE2(factory, keccak256(abi.encode(token0, token1,
///         fee)), initCodeHash)`. Same tuple as {AggregatorFillSolver}'s `PoolVenue`.
struct V3Venue {
    address factory;
    bytes32 initCodeHash;
}

/// @notice The fixed-address flash providers of this instance; `address(0)` = that
///         provider is disabled. Euler's vault is per call and needs no entry.
struct FlashProviders {
    address balancerVault;
    address aavePool;
    address morpho;
}

/// @notice The flash itself.
/// @param kind      the provider — see {FlashKind}.
/// @param token     the asset borrowed (for UNI_V3_SWAP: the swap's OUTPUT).
/// @param amount    how much of it. Sized off-chain from a PREVIEW; when the core prices
///                  the plan lower at inclusion (a decaying output), the unused principal
///                  round-trips through the pool and is swept back, but the provider's
///                  fee was charged on the whole `amount` (0.3 % × the decay on a v3
///                  flash). Price the fee on the full `amount` (review 2026-10-18 D-6):
///                  drift is then always in the filler's favour.
/// @param pairToken UNI_V3_*: the pool's other token (for UNI_V3_SWAP: the token the
///                  flash swap is REPAID in). Ignored otherwise.
/// @param fee       UNI_V3_*: the pool's fee tier.
/// @param venue     UNI_V3_*: index into the venue allowlist.
/// @param vault     EULER only: the EVK vault to flash from.
/// @param maxRepay  ceiling on what the provider takes back (`amount + fee`, or the
///                  flash swap's owed `pairToken`); `0` = no ceiling.
struct FlashSource {
    FlashKind kind;
    address token;
    uint256 amount;
    address pairToken;
    uint24 fee;
    uint8 venue;
    address vault;
    uint256 maxRepay;
}

/// @notice An exact-input swap on derived pools, paid from this contract's balance.
/// @param path     `tokenIn ‖ fee(3) ‖ venue(1) ‖ tokenOut [‖ fee ‖ venue ‖ tokenOut]…`
///                 — {AggregatorFillSolver}'s pool-route hop layout, 1+ hops.
/// @param amountIn `0` = this contract's whole balance of `tokenIn` at that moment.
/// @param minOut   floor on the last hop's output.
struct PoolSwap {
    bytes path;
    uint256 amountIn;
    uint256 minOut;
}

/// @notice Everything around the plan.
/// @param flash      the flash — see {FlashSource}.
/// @param swaps      run after `matchSettle` returns and before the repayment (the
///                   proceeds → flash-asset conversion). May be empty.
/// @param recipient  where every residue is swept at the end; `0` = `msg.sender`.
/// @param extraSweep tokens to sweep besides the derived set (the flash tokens, every
///                   order leg token, every `swaps` path token) — e.g. the output of a
///                   mid-plan {MatchFlashSolver.onMatchStep} swap that is not a leg.
/// @param minProfit  floors on the final sweep, per token ({MatchRaceGuard.SweptFloor}).
///                   A floor on the SWEPT BALANCE, not on this call's P&L: whatever sat
///                   here before the call (a donation, an earlier call's residue) is
///                   swept and counted too, so a parked wei can satisfy `expected + 1`
///                   (review 2026-10-18 D-5). The recipient still receives at least the
///                   floor; price a plan's profit from the simulation, not from this.
struct FlashMatch {
    FlashSource flash;
    PoolSwap[] swaps;
    address recipient;
    address[] extraSweep;
    MatchRaceGuard.SweptFloor[] minProfit;
}

/// @notice The cheap-loss race guard ({MatchRaceGuard}), checked before anything else.
struct RaceCheck {
    bytes32[] orderHashes;
    uint256[] expectedFilled;
    address[] nonceMakers;
    uint256[] nonces;
}

interface IFlashV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IFlashBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IFlashAavePool {
    function flashLoanSimple(
        address receiver,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IFlashMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IFlashEulerVault {
    function flashLoan(uint256 amount, bytes calldata data) external;
}

/// @title MatchFlashSolver
/// @notice Zero-capital filler for the CYCLE class (design review 2026-10-18, S-4):
///         one flash loan around `Settlement.matchSettle`, repaid from the plan's own
///         proceeds.
///
///  Why a flash
///  ───────────
///  A cycle is a plan whose delivery needs the proceeds of the order's own item: a
///  leverage open at the edge (the borrow needs the deposit, the deposit needs the
///  delivery, the delivery needs the borrow), a leverage close (withdraw needs the
///  repay), every fused composite (one item consumes the DELIVER and funds the
///  inputs — review M-3), and an ORDERED `TAKE_FOR`. `matchSettle` nets everything
///  acyclic; a cycle needs the first delivery fronted. Because the plan nets, ONE
///  flash in the cycle's token covers it (fill-ordering plan §4.5) — never one per leg.
///
///  The flow
///  ────────
///    executeMatch(guard, job, plan)                 operator only
///      1. race guard (`filled` / nonces), plan checks, sweep set — before anything moves
///      2. provider call — `job` + the encoded `matchSettle` call are the flash payload
///         └─ provider callback (authenticated, see below)
///             a. `matchSettle(plan)`; a CALL step targets {onMatchStep}, which pushes
///                the flash principal into the pool (Settlement) — the only way in:
///                a balance there BEFORE the call is under the snapshot floor and
///                unreachable. The plan's residual is swept back to this contract
///                (`plan.profitRecipient = 0` / this) — that is the repayment source.
///             b. `job.swaps` — proceeds → flash asset, on derived pools only
///             c. repay (transfer, or an exact approval the provider pulls)
///      3. zero any approval left to the provider, sweep every touched token to
///         `job.recipient`, check `job.minProfit`.
///
///  A typical leverage open (flash C, the order sells D, receives C):
///      schedule = [CALL onMatchStep(fund C), DELIVER 0, ITEM 0 0 (TAKE_FOR: deposit C
///      + borrow D)]; the borrowed D is swept here; `swaps` = D→C; repay C.
///
///  Callback authentication — the three gates, all load-bearing
///  ───────────────────────────────────────────────────────────
///  (The lesson of the AggregatorFillSolver drain: a flag armed by a permissionless
///  entrypoint authorises nothing.)
///    1. WHO ASKED: the flash is armed only by {executeMatch}, which only an immutable
///       operator may call (no setter). There is no open instance.
///    2. WHICH PROVIDER: the address this call ITSELF called — a CREATE2-derived pool
///       (the venue's init code hash pins genuine pool code), an immutable provider, or
///       the operator's Euler vault — is recorded before the call; a callback from any
///       other address reverts {UnexpectedCaller}. Aave additionally checks `initiator`.
///    3. WHICH FLASH: `keccak256(payload)` is committed before the call and consumed by
///       the first callback that matches. A provider that calls back ANY recipient with
///       ANY data (Balancer v2) cannot inject a foreign flash, and no second callback
///       can reuse the first ({UnexpectedPayload} / {NotArmed}).
///  The state machine closes every other window: the provider callback is accepted
///  only while the provider call is in flight (FLASHING), {onMatchStep} only while OUR
///  `matchSettle` is in flight (SETTLING — Settlement is non-reentrant and the EXECUTOR
///  answers only Settlement, so its CALL step is one of THIS plan's), the swap callback
///  only while a swap this contract started is in flight (SWAPPING, and from the derived
///  pool of the hop it pays). From the provider's return on nothing is accepted, so the
///  sweep — which runs token code — can host no callback.
///
///  Trust model: no funds at rest (everything is swept to `job.recipient` at the end of
///  every call — a donation goes to the next operator's recipient), no approvals at
///  rest (the only approvals ever granted are the exact Aave/Morpho repayments, zeroed
///  after the provider returns), never a Permit3 spender, never a Settlement or Permit3
///  approver. {onMatchStep} pushes only to Settlement and swaps only on derived pools,
///  so there is no "call anything as this contract" primitive.
///
///  ⚠ SUPPORTED PLANS. No SETTLE item ({SettleUnsupported}): a SETTLE module pays this
///  contract in any token it likes (an NFT included), which the sweep set cannot be
///  proven to cover. `PRESEND` is fine (it pays this contract, which spends or sweeps
///  it). `plan.profitRecipient` may not be Settlement or the EXECUTOR ({ProfitStranded});
///  it should be `0` (this contract) whenever the repayment needs the residual.
///
///  ⚠ FILLER IDENTITY. `matchSettle` keys exclusivity, FILLER_SET, filler-aware
///  validators and invariants on its `msg.sender` — this contract. Because every
///  instance is operator-gated, an order MAY name it: only its operators can fill.
contract MatchFlashSolver is MatchRaceGuard {
    // ───────────────────────── state machine ─────────────────────────

    uint256 private constant IDLE = 1;
    /// @dev The provider call is in flight; only its callback is accepted.
    uint256 private constant FLASHING = 2;
    /// @dev Our `matchSettle` is in flight; only {onMatchStep} from the EXECUTOR.
    uint256 private constant SETTLING = 3;
    /// @dev A swap this contract started is in flight; only its pool's swap callback.
    uint256 private constant SWAPPING = 4;
    /// @dev Inside the provider callback, between steps; nothing is accepted.
    uint256 private constant BUSY = 5;
    /// @dev The callback finished; nothing is accepted until {executeMatch} ends.
    uint256 private constant DONE = 6;

    /// @dev Packed in one slot: `_state` and the provider the flash was armed against.
    uint96 private _state = uint96(IDLE);
    address private _armed;
    /// @dev keccak256 of the flash payload, single-use — see the contract note.
    bytes32 private _commit;

    uint160 private constant MIN_SQRT_RATIO_PLUS_1 = 4295128740;
    uint160 private constant MAX_SQRT_RATIO_MINUS_1 = 1461446703485210103287273052203988822378723970341;
    uint256 private constant MAX_SWEEP = 64;

    // ───────────────────────── immutables ─────────────────────────

    /// @notice Settlement's callback trampoline: the only caller of {onMatchStep}.
    address public immutable EXECUTOR;
    address public immutable BALANCER_VAULT;
    address public immutable AAVE_POOL;
    address public immutable MORPHO;

    /// @notice How many {V3Venue}s this instance derives pools from (0..{MAX_SET}).
    uint256 public immutable POOL_VENUES;
    uint256 public constant MAX_SET = 4;
    address private immutable FACTORY0;
    address private immutable FACTORY1;
    address private immutable FACTORY2;
    address private immutable FACTORY3;
    bytes32 private immutable INIT_HASH0;
    bytes32 private immutable INIT_HASH1;
    bytes32 private immutable INIT_HASH2;
    bytes32 private immutable INIT_HASH3;

    address private immutable OPERATOR0;
    address private immutable OPERATOR1;
    address private immutable OPERATOR2;
    address private immutable OPERATOR3;

    // ───────────────────────── errors ─────────────────────────

    error NotOperator(address caller);
    /// @dev Empty operator set, a zero operator, or more than {MAX_SET}.
    error BadOperatorSet();
    /// @dev A venue with a zero factory or init code hash, or more than {MAX_SET}.
    error BadVenue();
    error UnknownVenue(uint256 venue);
    /// @dev The requested fixed-address provider is not configured on this instance.
    error ProviderDisabled(FlashKind kind);
    /// @dev Zero amount, `pairToken == token` on a v3 kind, zero Euler vault.
    error BadFlashRequest();
    /// @dev {executeMatch} re-entered.
    error Busy();
    /// @dev A callback outside the window that accepts it.
    error NotArmed();
    /// @dev A provider callback from an address other than the provider called.
    error UnexpectedCaller(address caller);
    /// @dev A provider callback whose payload is not the one {executeMatch} sent.
    error UnexpectedPayload();
    /// @dev A provider callback of the wrong kind for the armed flash.
    error WrongCallback();
    /// @dev The provider returned without calling back.
    error FlashCallbackMissing();
    /// @dev The provider reported a loan that is not the one requested.
    error BadFlashLoan();
    /// @dev The flash swap did not deliver exactly `amount`, or owes nothing.
    error BadFlashSwap();
    error FlashNotRepaid(address token, uint256 owed, uint256 held);
    error RepayAboveMax(uint256 owed, uint256 maxRepay);
    error BadPath();
    error BadPoolSwap();
    error SwapBelowMin(uint256 out, uint256 minOut);
    /// @dev A hop's pool consumed less than its exact input (its price limit was hit):
    ///      the unconsumed token would be left here, possibly outside the sweep set.
    error PartialSwap(uint256 consumed, uint256 amountIn);
    error NotPool();
    error PoolOverBudget(uint256 owed, uint256 budget);
    error OnlyExecutor();
    error LengthMismatch();
    /// @dev `plan.profitRecipient` is Settlement or the EXECUTOR, where nobody can claim it.
    error ProfitStranded();
    /// @dev `job.recipient` is this contract, Settlement or the EXECUTOR.
    error BadRecipient();
    error SettleUnsupported(uint256 order, uint256 item);
    error TooManyTokens();

    /// @param operators 1..4 callers of {executeMatch}. Immutable, no setter.
    /// @param venues    0..4 v3 deployments; venue index = position.
    /// @param providers the fixed-address providers; zero = disabled.
    constructor(
        address settlement,
        address[] memory operators,
        V3Venue[] memory venues,
        FlashProviders memory providers
    ) MatchRaceGuard(settlement) {
        EXECUTOR = address(SETTLEMENT.EXECUTOR());
        uint256 n = operators.length;
        if (n == 0 || n > MAX_SET) revert BadOperatorSet();
        for (uint256 i; i < n; ++i) {
            if (operators[i] == address(0)) revert BadOperatorSet();
        }
        OPERATOR0 = operators[0];
        OPERATOR1 = n > 1 ? operators[1] : operators[0];
        OPERATOR2 = n > 2 ? operators[2] : operators[0];
        OPERATOR3 = n > 3 ? operators[3] : operators[0];

        uint256 v = venues.length;
        if (v > MAX_SET) revert BadVenue();
        for (uint256 i; i < v; ++i) {
            if (venues[i].factory == address(0) || venues[i].initCodeHash == bytes32(0)) revert BadVenue();
        }
        POOL_VENUES = v;
        V3Venue memory none;
        V3Venue memory v0 = v > 0 ? venues[0] : none;
        V3Venue memory v1 = v > 1 ? venues[1] : none;
        V3Venue memory v2 = v > 2 ? venues[2] : none;
        V3Venue memory v3 = v > 3 ? venues[3] : none;
        (FACTORY0, INIT_HASH0) = (v0.factory, v0.initCodeHash);
        (FACTORY1, INIT_HASH1) = (v1.factory, v1.initCodeHash);
        (FACTORY2, INIT_HASH2) = (v2.factory, v2.initCodeHash);
        (FACTORY3, INIT_HASH3) = (v3.factory, v3.initCodeHash);

        BALANCER_VAULT = providers.balancerVault;
        AAVE_POOL = providers.aavePool;
        MORPHO = providers.morpho;
    }

    // ───────────────────────── views ─────────────────────────

    function isOperator(address who) public view returns (bool) {
        return who == OPERATOR0 || who == OPERATOR1 || who == OPERATOR2 || who == OPERATOR3;
    }

    /// @notice Venue `i` — reverts {UnknownVenue} past {POOL_VENUES}.
    function poolVenue(uint256 i) public view returns (address factory, bytes32 initCodeHash) {
        if (i >= POOL_VENUES) revert UnknownVenue(i);
        if (i == 0) return (FACTORY0, INIT_HASH0);
        if (i == 1) return (FACTORY1, INIT_HASH1);
        if (i == 2) return (FACTORY2, INIT_HASH2);
        return (FACTORY3, INIT_HASH3);
    }

    /// @notice The pool `(tokenA, tokenB, fee)` on `venue` — the only address this
    ///         contract flashes from, swaps on, or pays in a v3 callback.
    function poolFor(uint256 venue, address tokenA, address tokenB, uint24 fee) public view returns (address) {
        (address factory, bytes32 initCodeHash) = poolVenue(venue);
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encode(t0, t1, fee)), initCodeHash)))
            )
        );
    }

    // ───────────────────────── entry ─────────────────────────

    /// @notice Flash `job.flash`, run `plan` through `matchSettle` inside it, convert
    ///         the proceeds with `job.swaps`, repay, and sweep every residue to
    ///         `job.recipient`.
    /// @param  g    the race guard — reverts {OrderTaken}/{NonceTaken} cheaply, before
    ///         the plan is touched.
    /// @param  job  the flash and its surroundings — see {FlashMatch}.
    /// @param  plan the settlement. Its CALL step(s) that inject the flash target
    ///         {onMatchStep}; `profitRecipient` = 0 so the residual comes back here.
    /// @return tokens the swept token set.
    /// @return profit `profit[k]` = what was swept to the recipient in `tokens[k]`.
    function executeMatch(RaceCheck calldata g, FlashMatch calldata job, MatchPlan calldata plan)
        external
        returns (address[] memory tokens, uint256[] memory profit)
    {
        if (!isOperator(msg.sender)) revert NotOperator(msg.sender);
        if (_state != IDLE) revert Busy();
        _requireUntouched(g.orderHashes, g.expectedFilled);
        _requireNoncesLive(g.nonceMakers, g.nonces);

        address to = job.recipient == address(0) ? msg.sender : job.recipient;
        if (to == address(this) || to == address(SETTLEMENT) || to == EXECUTOR) revert BadRecipient();
        _checkPlan(plan);
        tokens = _sweepSet(job, plan);

        bytes memory payload = abi.encode(job, abi.encodeCall(SETTLEMENT.matchSettle, (plan)));
        address provider = _provider(job.flash);
        _state = uint96(FLASHING);
        _armed = provider;
        _commit = keccak256(payload);

        _callProvider(job.flash, provider, payload);

        if (_state != DONE) revert FlashCallbackMissing();
        FlashKind kind = job.flash.kind;
        // Aave / Morpho pulled exactly the approved repayment; clear it regardless, so
        // a provider that pulled less leaves no standing allowance behind.
        if (kind == FlashKind.AAVE_V3 || kind == FlashKind.MORPHO) {
            SafeTransferLib.forceApprove(job.flash.token, provider, 0);
        }
        profit = _sweepAll(tokens, to);
        _requireSwept(tokens, profit, job.minProfit);
        _state = uint96(IDLE);
        _armed = address(0);
    }

    // ───────────────────────── plan CALL step ─────────────────────────

    /// @notice The CALL-step target that injects working capital into the pool:
    ///         run `swaps`, then push `amounts[i]` of `tokens[i]` (`type(uint256).max`
    ///         = this contract's whole balance) to Settlement.
    /// @dev    Only from the EXECUTOR while OUR `matchSettle` is in flight: Settlement
    ///         is non-reentrant and the EXECUTOR obeys only Settlement, so the caller is
    ///         a CALL step of the plan an operator committed to. The destination is
    ///         fixed to Settlement and swaps run on derived pools only.
    function onMatchStep(PoolSwap[] calldata swaps, address[] calldata tokens, uint256[] calldata amounts) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_state != SETTLING) revert NotArmed();
        if (tokens.length != amounts.length) revert LengthMismatch();
        _runSwaps(swaps, SETTLING);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amt = amounts[i];
            if (amt == type(uint256).max) amt = SafeTransferLib.balanceOf(tokens[i], address(this));
            if (amt != 0) SafeTransferLib.safeTransfer(tokens[i], address(SETTLEMENT), amt);
        }
    }

    // ───────────────────────── provider callbacks ─────────────────────────

    /// @notice Uniswap v3 `flash` callback (UNI_V3_FLASH).
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        FlashSource calldata f = _auth(data, FlashKind.UNI_V3_FLASH);
        _run(data);
        _repay(f.token, f.amount + (f.token < f.pairToken ? fee0 : fee1), f.maxRepay, true);
        _state = uint96(DONE);
    }

    /// @notice Uniswap v3 swap callback: a swap of {_hop} (SWAPPING), or the flash swap
    ///         itself (UNI_V3_SWAP, FLASHING).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (_state == SWAPPING) {
            _paySwap(amount0Delta, amount1Delta, data);
            return;
        }
        FlashSource calldata f = _auth(data, FlashKind.UNI_V3_SWAP);
        (int256 paid, int256 got) = f.pairToken < f.token ? (amount0Delta, amount1Delta) : (amount1Delta, amount0Delta);
        if (paid <= 0 || got != -int256(f.amount)) revert BadFlashSwap();
        _run(data);
        _repay(f.pairToken, uint256(paid), f.maxRepay, true);
        _state = uint96(DONE);
    }

    /// @notice Balancer v2 `flashLoan` callback.
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external {
        FlashSource calldata f = _auth(userData, FlashKind.BALANCER_V2);
        if (tokens.length != 1 || amounts.length != 1 || feeAmounts.length != 1) revert BadFlashLoan();
        if (tokens[0] != f.token || amounts[0] != f.amount) revert BadFlashLoan();
        _run(userData);
        _repay(f.token, f.amount + feeAmounts[0], f.maxRepay, true);
        _state = uint96(DONE);
    }

    /// @notice Aave v3 `flashLoanSimple` callback.
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        FlashSource calldata f = _auth(params, FlashKind.AAVE_V3);
        if (initiator != address(this) || asset != f.token || amount != f.amount) revert BadFlashLoan();
        _run(params);
        _repay(asset, amount + premium, f.maxRepay, false);
        _state = uint96(DONE);
        return true;
    }

    /// @notice Morpho Blue `flashLoan` callback.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        FlashSource calldata f = _auth(data, FlashKind.MORPHO);
        if (assets != f.amount) revert BadFlashLoan();
        _run(data);
        _repay(f.token, assets, f.maxRepay, false);
        _state = uint96(DONE);
    }

    /// @notice Euler EVK vault `flashLoan` callback.
    function onFlashLoan(bytes calldata data) external {
        FlashSource calldata f = _auth(data, FlashKind.EULER);
        _run(data);
        _repay(f.token, f.amount, f.maxRepay, true);
        _state = uint96(DONE);
    }

    // ───────────────────────── internals ─────────────────────────

    /// @dev Gates 2 and 3 of the contract note (gate 1 is {executeMatch}'s operator
    ///      check, which is the only writer of FLASHING): in flight, from the armed
    ///      provider, with the committed payload — consumed — and of the armed kind.
    function _auth(bytes calldata data, FlashKind kind) private returns (FlashSource calldata f) {
        if (_state != FLASHING) revert NotArmed();
        if (msg.sender != _armed) revert UnexpectedCaller(msg.sender);
        if (keccak256(data) != _commit) revert UnexpectedPayload();
        _commit = bytes32(0);
        _state = uint96(BUSY);
        f = _jobOf(data).flash;
        if (f.kind != kind) revert WrongCallback();
    }

    /// @dev The payload is `abi.encode(FlashMatch job, bytes matchCall)`, produced by
    ///      {executeMatch} and proven by the commitment, so it is read in place.
    function _jobOf(bytes calldata data) private pure returns (FlashMatch calldata job) {
        assembly {
            job := add(data.offset, calldataload(data.offset))
        }
    }

    /// @dev `matchSettle`, then the proceeds swaps.
    function _run(bytes calldata data) private {
        bytes calldata cd;
        assembly {
            let p := add(data.offset, calldataload(add(data.offset, 0x20)))
            cd.length := calldataload(p)
            cd.offset := add(p, 0x20)
        }
        bytes memory call_ = cd;
        _state = uint96(SETTLING);
        (bool ok, bytes memory ret) = address(SETTLEMENT).call(call_);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        _state = uint96(BUSY);
        _runSwaps(_jobOf(data).swaps, BUSY);
    }

    /// @dev Pay `owed` of `token` to the provider (`msg.sender`): by transfer, or by
    ///      an exact approval it pulls after the callback returns.
    function _repay(address token, uint256 owed, uint256 maxRepay, bool push) private {
        if (maxRepay != 0 && owed > maxRepay) revert RepayAboveMax(owed, maxRepay);
        uint256 held = SafeTransferLib.balanceOf(token, address(this));
        if (held < owed) revert FlashNotRepaid(token, owed, held);
        if (push) SafeTransferLib.safeTransfer(token, msg.sender, owed);
        else SafeTransferLib.forceApprove(token, msg.sender, owed);
    }

    function _provider(FlashSource calldata f) private view returns (address p) {
        if (f.amount == 0) revert BadFlashRequest();
        FlashKind kind = f.kind;
        if (kind == FlashKind.UNI_V3_FLASH || kind == FlashKind.UNI_V3_SWAP) {
            if (f.token == f.pairToken) revert BadFlashRequest();
            return poolFor(f.venue, f.token, f.pairToken, f.fee);
        }
        if (kind == FlashKind.EULER) {
            if (f.vault == address(0)) revert BadFlashRequest();
            return f.vault;
        }
        p = kind == FlashKind.BALANCER_V2 ? BALANCER_VAULT : kind == FlashKind.AAVE_V3 ? AAVE_POOL : MORPHO;
        if (p == address(0)) revert ProviderDisabled(kind);
    }

    function _callProvider(FlashSource calldata f, address p, bytes memory payload) private {
        FlashKind kind = f.kind;
        if (kind == FlashKind.UNI_V3_FLASH) {
            (uint256 a0, uint256 a1) = f.token < f.pairToken ? (f.amount, uint256(0)) : (uint256(0), f.amount);
            IFlashV3Pool(p).flash(address(this), a0, a1, payload);
        } else if (kind == FlashKind.UNI_V3_SWAP) {
            if (f.amount > uint256(type(int256).max)) revert BadFlashRequest();
            bool zeroForOne = f.pairToken < f.token;
            IFlashV3Pool(p)
                .swap(
                    address(this),
                    zeroForOne,
                    -int256(f.amount),
                    zeroForOne ? MIN_SQRT_RATIO_PLUS_1 : MAX_SQRT_RATIO_MINUS_1,
                    payload
                );
        } else if (kind == FlashKind.BALANCER_V2) {
            address[] memory t = new address[](1);
            uint256[] memory a = new uint256[](1);
            (t[0], a[0]) = (f.token, f.amount);
            IFlashBalancerVault(p).flashLoan(address(this), t, a, payload);
        } else if (kind == FlashKind.AAVE_V3) {
            IFlashAavePool(p).flashLoanSimple(address(this), f.token, f.amount, payload, 0);
        } else if (kind == FlashKind.MORPHO) {
            IFlashMorpho(p).flashLoan(f.token, f.amount, payload);
        } else {
            IFlashEulerVault(p).flashLoan(f.amount, payload);
        }
    }

    /// @dev Run `swaps` in the SWAPPING window, then return to `resume`.
    function _runSwaps(PoolSwap[] calldata swaps, uint256 resume) private {
        uint256 n = swaps.length;
        if (n == 0) return;
        _state = uint96(SWAPPING);
        for (uint256 i; i < n; ++i) {
            _swap(swaps[i]);
        }
        _state = uint96(resume);
    }

    /// @dev One exact-input path, hop by hop, every hop's output landing here.
    function _swap(PoolSwap calldata s) private {
        bytes calldata path = s.path;
        uint256 len = path.length;
        if (len < 44 || (len - 20) % 24 != 0) revert BadPath();
        uint256 amount = s.amountIn;
        if (amount == 0) amount = SafeTransferLib.balanceOf(address(bytes20(path[0:20])), address(this));
        uint256 hops = (len - 20) / 24;
        for (uint256 k; k < hops; ++k) {
            uint256 o = 24 * k;
            amount = _hop(
                address(bytes20(path[o:o + 20])),
                address(bytes20(path[o + 24:o + 44])),
                uint24(bytes3(path[o + 20:o + 23])),
                uint8(path[o + 23]),
                amount
            );
        }
        if (amount < s.minOut) revert SwapBelowMin(amount, s.minOut);
    }

    function _hop(address tokenIn, address tokenOut, uint24 fee, uint8 venue, uint256 amountIn)
        private
        returns (uint256 out)
    {
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert BadPoolSwap();
        address pool = poolFor(venue, tokenIn, tokenOut, fee);
        bool zeroForOne = tokenIn < tokenOut;
        (int256 a0, int256 a1) = IFlashV3Pool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? MIN_SQRT_RATIO_PLUS_1 : MAX_SQRT_RATIO_MINUS_1,
                abi.encode(tokenIn, tokenOut, fee, venue, amountIn)
            );
        (int256 paid, int256 got) = zeroForOne ? (a0, a1) : (a1, a0);
        if (got >= 0) revert BadPoolSwap();
        // EXACT input or nothing (review 2026-10-18 F-3): a pool that stops at its price
        // limit consumes less, and the rest of `tokenIn` would stay here — for a mid-plan
        // {onMatchStep} hop an intermediate token that is no leg, no `job.swaps` path
        // token and no `extraSweep` entry, so the final sweep would never move it.
        // (`paid` cannot exceed `amountIn`: {_paySwap} caps it at the hop's budget.)
        if (uint256(paid) != amountIn) revert PartialSwap(uint256(paid), amountIn);
        out = uint256(-got);
    }

    /// @dev Pay a {_hop} swap: only the derived pool of the hop named in `data`, only
    ///      its input token, never more than the hop's `amountIn`. A genuine pool calls
    ///      back only the `msg.sender` of its own `swap` (this contract, in SWAPPING)
    ///      with this contract's own data; a forged `data` names a pool the caller is not.
    function _paySwap(int256 amount0Delta, int256 amount1Delta, bytes calldata data) private {
        (address tokenIn, address tokenOut, uint24 fee, uint8 venue, uint256 budget) =
            abi.decode(data, (address, address, uint24, uint8, uint256));
        if (msg.sender != poolFor(venue, tokenIn, tokenOut, fee)) revert NotPool();
        int256 owed = tokenIn < tokenOut ? amount0Delta : amount1Delta;
        if (owed <= 0) revert BadPoolSwap();
        if (uint256(owed) > budget) revert PoolOverBudget(uint256(owed), budget);
        SafeTransferLib.safeTransfer(tokenIn, msg.sender, uint256(owed));
    }

    /// @dev {ProfitStranded} and {SettleUnsupported}, before anything moves.
    function _checkPlan(MatchPlan calldata plan) private view {
        address pr = plan.profitRecipient;
        if (pr == address(SETTLEMENT) || pr == EXECUTOR) revert ProfitStranded();
        uint256 nOrders = plan.orders.length;
        for (uint256 i; i < nOrders; ++i) {
            bytes calldata items = plan.orders[i].items;
            uint256 n = PackedArrays.validateRecords(items, PackedArrays.ITEM_HEAD);
            uint256 cursor = PackedArrays.recordsStart();
            for (uint256 k; k < n; ++k) {
                uint256 op;
                (op,,,,, cursor) = PackedArrays.itemAt(items, cursor);
                if (op == uint256(ItemOp.SETTLE)) revert SettleUnsupported(i, k);
            }
        }
    }

    /// @dev Every token this call can leave here: the flash token(s), every order leg
    ///      token, every `swaps` path token, and `extraSweep` — deduplicated.
    function _sweepSet(FlashMatch calldata job, MatchPlan calldata plan) private pure returns (address[] memory s) {
        s = new address[](MAX_SWEEP);
        uint256 n;
        FlashSource calldata f = job.flash;
        n = _add(s, n, f.token);
        if (f.kind == FlashKind.UNI_V3_FLASH || f.kind == FlashKind.UNI_V3_SWAP) n = _add(s, n, f.pairToken);
        uint256 nOrders = plan.orders.length;
        for (uint256 i; i < nOrders; ++i) {
            bytes calldata legsIn = plan.orders[i].legsIn;
            uint256 m = PackedArrays.validateFixed(legsIn, PackedArrays.LEG_IN_STRIDE);
            for (uint256 j; j < m; ++j) {
                n = _add(s, n, PackedArrays.legInToken(legsIn, j));
            }
            bytes calldata legsOut = plan.orders[i].legsOut;
            m = PackedArrays.validateFixed(legsOut, PackedArrays.LEG_OUT_STRIDE);
            for (uint256 j; j < m; ++j) {
                n = _add(s, n, PackedArrays.legOutToken(legsOut, j));
            }
        }
        for (uint256 i; i < job.swaps.length; ++i) {
            bytes calldata path = job.swaps[i].path;
            if (path.length < 44 || (path.length - 20) % 24 != 0) revert BadPath();
            for (uint256 o; o < path.length; o += 24) {
                n = _add(s, n, address(bytes20(path[o:o + 20])));
            }
        }
        for (uint256 i; i < job.extraSweep.length; ++i) {
            n = _add(s, n, job.extraSweep[i]);
        }
        assembly {
            mstore(s, n)
        }
    }

    function _add(address[] memory s, uint256 n, address t) private pure returns (uint256) {
        for (uint256 k; k < n; ++k) {
            if (s[k] == t) return n;
        }
        if (n == MAX_SWEEP) revert TooManyTokens();
        s[n] = t;
        return n + 1;
    }

    function _sweepAll(address[] memory tokens, address to) private returns (uint256[] memory swept) {
        uint256 n = tokens.length;
        swept = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            uint256 bal = SafeTransferLib.balanceOf(tokens[k], address(this));
            if (bal != 0) {
                swept[k] = bal;
                SafeTransferLib.safeTransfer(tokens[k], to, bal);
            }
        }
    }
}
