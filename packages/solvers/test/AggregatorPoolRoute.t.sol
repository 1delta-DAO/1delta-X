// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {
    AggregatorFillSolver,
    RoutePlan,
    SurplusPolicy,
    NO_PATCH,
    POOL_ROUTE,
    Permit2612,
    PoolVenue
} from "@solvers/aggregator/AggregatorFillSolver.sol";

import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {AggregatorFillSolverTest} from "./AggregatorFillSolver.t.sol";
import {newAgg, noGuard} from "./shared/AggDeploy.sol";

interface IV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @dev A Uniswap-v3-SHAPED factory: deploys {MockV3Pool} by CREATE2 with salt
///      `keccak256(abi.encode(token0, token1, fee))` and a PARAMETER-LESS constructor
///      that reads `parameters()` back — Uniswap's `UniswapV3PoolDeployer` pattern, so a
///      pool address is `CREATE2(factory, salt, keccak256(creationCode))` exactly as the
///      solver derives it.
contract MockV3Factory {
    struct Params {
        address factory;
        address token0;
        address token1;
        uint24 fee;
    }

    Params public parameters;
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function initCodeHash() external pure returns (bytes32) {
        return keccak256(type(MockV3Pool).creationCode);
    }

    function createPool(address a, address b, uint24 fee) external returns (MockV3Pool pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        parameters = Params(address(this), t0, t1, fee);
        pool = new MockV3Pool{salt: keccak256(abi.encode(t0, t1, fee))}();
        delete parameters;
        getPool[t0][t1][fee] = address(pool);
        getPool[t1][t0][fee] = address(pool);
    }
}

/// @dev A constant-price pool with Uniswap v3's swap/callback contract: pays the
///      output FIRST, then calls `uniswapV3SwapCallback(amount0, amount1, data)` on
///      `msg.sender` with the caller's own `data`, then requires its input balance to
///      have risen by the owed amount (`IIA`). Knobs make it misbehave the ways a
///      callback must survive: owe more than due, owe on the wrong token, consume or
///      deliver less than asked, or echo DIFFERENT callback data.
contract MockV3Pool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    /// @dev token1 per token0 = num / den.
    uint256 public num = 1;
    uint256 public den = 1;
    int256 public extraOwed;
    bool public flip;
    uint256 public shortBps;
    bytes public overrideData;
    bool private unlocked = true;

    constructor() {
        (factory, token0, token1, fee) = MockV3Factory(msg.sender).parameters();
    }

    function setPrice(uint256 n, uint256 d) external {
        (num, den) = (n, d);
    }

    function setMisbehaviour(int256 extra, bool flip_, uint256 short_, bytes calldata data_) external {
        (extraOwed, flip, shortBps, overrideData) = (extra, flip_, short_, data_);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(unlocked, "LOK");
        unlocked = false;
        (address tin, address tout) = zeroForOne ? (token0, token1) : (token1, token0);
        (uint256 n, uint256 d) = zeroForOne ? (num, den) : (den, num); // out = in · n / d
        uint256 amtIn;
        uint256 amtOut;
        if (amountSpecified > 0) {
            amtIn = uint256(amountSpecified);
            amtIn -= (amtIn * shortBps) / 10_000; // stops early (liquidity exhausted)
            amtOut = (amtIn * n) / d;
        } else {
            amtOut = uint256(-amountSpecified);
            amtOut -= (amtOut * shortBps) / 10_000; // delivers short
            amtIn = (amtOut * d + n - 1) / n;
        }
        SafeTransferLib.safeTransfer(tout, recipient, amtOut);
        int256 owedIn = int256(amtIn) + extraOwed;
        (amount0, amount1) = zeroForOne ? (owedIn, -int256(amtOut)) : (-int256(amtOut), owedIn);
        if (flip) (amount0, amount1) = (amount1, amount0);
        uint256 balBefore = MockERC20(tin).balanceOf(address(this));
        bytes memory cb = data;
        if (overrideData.length != 0) cb = overrideData;
        IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, cb);
        require(MockERC20(tin).balanceOf(address(this)) >= balBefore + amtIn, "IIA");
        unlocked = true;
    }
}

/// @dev A minimal EIP-2612 token (OpenZeppelin's typehash and domain shape).
contract Erc2612Token {
    string public name = "Permit Token";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline, "expired");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == owner, "bad sig");
        allowance[owner][spender] = value;
    }
}

/// @dev A token whose `transfer` makes ONE armed call to `target` mid-transfer and
///      records the result — the "attacker gains control while the swap is in
///      flight" probe (a pool pays its output with `transfer`).
contract HookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public target;
    bytes public payload;
    bool public fired;
    bytes public ret;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(address t, bytes calldata p) external {
        (target, payload, fired) = (t, p, false);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        _hook();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function _hook() internal {
        if (target == address(0) || fired) return;
        fired = true;
        bytes memory r;
        (, r) = target.call(payload);
        ret = r;
    }
}

/// @title AggregatorPoolRouteTest
/// @notice DIRECT POOL ROUTES (2026-10-12): the solver swaps on Uniswap-v3-style pools
///         itself and pays in `uniswapV3SwapCallback`, instead of pushing the input
///         through {RouteSandbox} to a router. Pinned here: pool derivation from the
///         immutable venue allowlist, exact-input / exact-output on one and two hops,
///         every existing floor (`minOut`, `maxPay`, the core's delta check, the routed
///         budget), the three callback gates (armed, genuine pool of the CURRENT hop,
///         exactly the owed input within budget), reentrancy, and the ERC-2612
///         `permits` argument of both entries.
contract AggregatorPoolRouteTest is AggregatorFillSolverTest {
    MockV3Factory internal fac0; // venue 0 ("Oku")
    MockV3Factory internal fac1; // venue 1 ("Sushi") — same pool code, other factory
    MockV3Pool internal poolAB; // tA/tB 0.05% on venue 0
    MockV3Pool internal poolAB1; // tA/tB 0.3% on venue 1
    MockV3Pool internal poolAC; // tA/tC 0.3% on venue 0
    MockV3Pool internal poolCB; // tC/tB 0.05% on venue 0

    uint24 internal constant F500 = 500;
    uint24 internal constant F3000 = 3000;
    address internal constant TREASURY = address(0x7EA5);

    function setUp() public virtual override {
        super.setUp();
        fac0 = new MockV3Factory();
        fac1 = new MockV3Factory();
        poolAB = fac0.createPool(address(tA), address(tB), F500);
        poolAB1 = fac1.createPool(address(tA), address(tB), F3000);
        poolAC = fac0.createPool(address(tA), address(tC), F3000);
        poolCB = fac0.createPool(address(tC), address(tB), F500);
        // Liquidity: every pool holds both sides.
        MockV3Pool[4] memory ps = [poolAB, poolAB1, poolAC, poolCB];
        for (uint256 i; i < 4; i++) {
            MockERC20(ps[i].token0()).mint(address(ps[i]), 1_000e18);
            MockERC20(ps[i].token1()).mint(address(ps[i]), 1_000e18);
        }
        aggSolver = _venueSolver(_ops());
        vm.label(address(aggSolver), "poolSolver");
    }

    function _venues() internal view returns (PoolVenue[] memory v) {
        v = new PoolVenue[](2);
        v[0] = PoolVenue({factory: address(fac0), initCodeHash: fac0.initCodeHash()});
        v[1] = PoolVenue({factory: address(fac1), initCodeHash: fac1.initCodeHash()});
    }

    function _venueSolver(address[] memory ops) internal returns (AggregatorFillSolver s) {
        s = newAgg(address(settlement), ops, _noSplit(), _venues());
    }

    function _np() internal pure returns (Permit2612[] memory) {
        return new Permit2612[](0);
    }

    // ───────────────────────── plan builders ─────────────────────────

    function _hop1(address a, uint24 fee, uint8 venue, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, venue, b);
    }

    function _hop2(address a, uint24 f1, uint8 v1, address b, uint24 f2, uint8 v2, address c)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(a, f1, v1, b, f2, v2, c);
    }

    function _poolPlan(bytes memory path, uint256 amountIn, uint256 amountOut, uint256 inOff, uint256 outOff, uint256 minOut)
        internal
        pure
        returns (RoutePlan memory)
    {
        return RoutePlan({
            router: POOL_ROUTE,
            minOut: minOut,
            maxPay: 0,
            inventory: 0,
            amountInOffset: inOff,
            amountOutOffset: outOff,
            minBumpBps: 0,
            profitRecipient: TREASURY,
            originator: address(0),
            originatorPpm: 0,
            data: abi.encodePacked(amountIn, amountOut, path)
        });
    }

    /// @dev `out = in · rateBps / 10_000` for a swap `tokenIn → tokenOut` on `p`.
    function _rate(MockV3Pool p, address tokenIn, uint256 rateBps) internal {
        if (tokenIn == p.token0()) p.setPrice(rateBps, 10_000);
        else p.setPrice(10_000, rateBps);
    }

    function _assertNoSandboxUse(AggregatorFillSolver s) internal view {
        address sb = address(s.SANDBOX());
        assertEq(tA.balanceOf(sb), 0, "sandbox untouched (tA)");
        assertEq(tB.balanceOf(sb), 0, "sandbox untouched (tB)");
        assertEq(tA.allowance(sb, address(poolAB)), 0, "no sandbox approval");
        assertEq(tA.allowance(address(s), address(poolAB)), 0, "the solver approves no pool");
    }

    // ════════════════════════ pool derivation ════════════════════════

    function test_poolFor_derivesEachFactorysPool() public view {
        assertEq(aggSolver.poolFor(0, address(tA), address(tB), F500), address(poolAB), "venue 0 tA/tB");
        assertEq(aggSolver.poolFor(0, address(tB), address(tA), F500), address(poolAB), "order-independent");
        assertEq(aggSolver.poolFor(1, address(tA), address(tB), F3000), address(poolAB1), "venue 1 tA/tB");
        assertEq(aggSolver.poolFor(0, address(tA), address(tC), F3000), fac0.getPool(address(tA), address(tC), F3000));
        // Same tokens and fee on the OTHER venue is a different (here non-existent) pool.
        assertTrue(aggSolver.poolFor(1, address(tA), address(tB), F500) != address(poolAB), "venue binds the factory");
        assertEq(aggSolver.POOL_VENUES(), 2);
        (address f, bytes32 h) = aggSolver.poolVenue(1);
        assertEq(f, address(fac1));
        assertEq(h, fac1.initCodeHash());
    }

    function test_poolVenue_unknownIndexReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.UnknownVenue.selector, uint256(2)));
        aggSolver.poolVenue(2);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.UnknownVenue.selector, uint256(255)));
        aggSolver.poolFor(255, address(tA), address(tB), F500);
    }

    function test_constructor_refusesBadVenues() public {
        PoolVenue[] memory v = new PoolVenue[](1);
        v[0] = PoolVenue({factory: address(0), initCodeHash: bytes32(uint256(1))});
        vm.expectRevert(AggregatorFillSolver.BadVenue.selector);
        new AggregatorFillSolver(address(settlement), _ops(), _noSplit(), v, address(0), address(0));
        v[0] = PoolVenue({factory: address(fac0), initCodeHash: bytes32(0)});
        vm.expectRevert(AggregatorFillSolver.BadVenue.selector);
        new AggregatorFillSolver(address(settlement), _ops(), _noSplit(), v, address(0), address(0));
        PoolVenue[] memory five = new PoolVenue[](5);
        for (uint256 i; i < 5; i++) five[i] = PoolVenue({factory: address(fac0), initCodeHash: bytes32(uint256(1))});
        vm.expectRevert(AggregatorFillSolver.BadSetSize.selector);
        new AggregatorFillSolver(address(settlement), _ops(), _noSplit(), five, address(0), address(0));
    }

    function test_noVenues_poolRouteRefused() public {
        AggregatorFillSolver s = newAgg(address(settlement), _ops(), _noSplit(), new PoolVenue[](0));
        assertEq(s.POOL_VENUES(), 0);
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), 0, 0, 0, NO_PATCH, AMOUNT_OUT);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.UnknownVenue.selector, uint256(0))));
        s.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    // ════════════════════════ the four shapes ════════════════════════

    /// @dev PULL, exact-input, one hop, patched amount: the pool pays the SOLVER,
    ///      Settlement pulls the maker's 90, the 10 spread goes to the treasury (less
    ///      the self-seeded wei). No sandbox, no approval of anything but Settlement,
    ///      and that one is cleared.
    function test_pull_exactIn_singleHop() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), 0, 0, 0, NO_PATCH, AMOUNT_OUT);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid");
        // `_seedIn` routed 100e18 − 1 wei of tA (kept as the tA floor): 1:1 → 1 wei less tB.
        assertEq(tB.balanceOf(TREASURY), AMOUNT_IN - 1 - AMOUNT_OUT - 1, "spread to the treasury, less the tB floor");
        assertEq(tA.balanceOf(address(aggSolver)), 1, "tA floor");
        assertEq(tB.balanceOf(address(aggSolver)), 1, "tB floor");
        assertEq(tB.allowance(address(aggSolver), address(settlement)), 0, "Settlement allowance cleared");
        _assertNoSandboxUse(aggSolver);
    }

    /// @dev PULL, exact-input, TWO hops (tA → tC → tB, both venue 0): the
    ///      intermediate lands here and is re-swapped in full.
    function test_pull_exactIn_twoHops() public {
        _rate(poolAC, address(tA), 20_000); // 1 tA → 2 tC
        _rate(poolCB, address(tC), 5_000); //  1 tC → 0.5 tB
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        bytes memory path = _hop2(address(tA), F3000, 0, address(tC), F500, 0, address(tB));
        RoutePlan memory p = _poolPlan(path, AMOUNT_IN, 0, NO_PATCH, NO_PATCH, AMOUNT_OUT);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid");
        assertEq(tB.balanceOf(TREASURY), AMOUNT_IN - AMOUNT_OUT - 1, "spread (100 - 90, less the tB floor)");
        assertEq(tC.balanceOf(address(aggSolver)), 0, "the intermediate is consumed in full");
        _assertNoSandboxUse(aggSolver);
    }

    /// @dev DIRECT, exact-output, one hop — the beta's live shape: the pool pays the
    ///      MAKER exactly the owed 90, the core verifies the delta, the unspent 10 tA
    ///      stays as input residue and is split. The solver never holds tB.
    function test_direct_exactOut_singleHop() public {
        tA.mint(address(aggSolver), 1);
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        uint256[] memory outs = aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(outs[0], AMOUNT_OUT, "core reports the verified delivery");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid exactly the owed amount");
        assertEq(tA.balanceOf(TREASURY), AMOUNT_IN - AMOUNT_OUT, "the unspent input is the spread");
        assertEq(tA.balanceOf(address(aggSolver)), 1, "floor untouched");
        assertEq(tB.balanceOf(address(aggSolver)), 0, "the solver never touches tokenOut");
        assertEq(tB.allowance(address(aggSolver), address(settlement)), 0, "nothing approved");
        _assertNoSandboxUse(aggSolver);
    }

    /// @dev The same on VENUE 1 (the second factory) — one instance, two venues.
    function test_direct_exactOut_singleHop_venue1() public {
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F3000, 1, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid via venue 1");
        assertEq(tA.balanceOf(address(poolAB1)), 1_000e18 + AMOUNT_OUT, "venue 1's pool was paid");
    }

    /// @dev DIRECT, exact-output, TWO hops — the recursive callback: the tC/tB pool
    ///      pays the maker, its callback buys the owed tC from the tA/tC pool PAID TO
    ///      the tC/tB pool, and only that innermost callback pays tA from here.
    function test_direct_exactOut_twoHops() public {
        _rate(poolAC, address(tA), 20_000); // 1 tA → 2 tC
        _rate(poolCB, address(tC), 5_000); //  1 tC → 0.5 tB
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        bytes memory path = _hop2(address(tA), F3000, 0, address(tC), F500, 0, address(tB));
        RoutePlan memory p = _poolPlan(path, AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid exactly");
        assertEq(tC.balanceOf(address(aggSolver)), 0, "the intermediate never lands here");
        assertEq(tA.balanceOf(TREASURY), AMOUNT_IN - AMOUNT_OUT - 1, "residue split (first fill keeps the tA floor)");
    }

    /// @dev DIRECT, exact-INPUT: the maker receives the whole output (core verifies
    ///      ≥ owed), no residue.
    function test_direct_exactIn_singleHop() public {
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), 0, 0, 0, NO_PATCH, 0);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_IN, "maker got the whole 1:1 output");
        assertEq(tA.balanceOf(address(aggSolver)), 0, "direct exact-input routes the whole delta (no seeding)");
    }

    /// @dev A direct order whose `legsOut[0]` names a RECIPIENT: the pool pays that
    ///      recipient (from the order, never from the plan).
    function test_direct_payeeIsLeg0Recipient() public {
        address beneficiary = address(0xBEEF01);
        Order memory o = _directOrder(1);
        o.legsOut = PackedEncode.oneLegOut(address(tB), AMOUNT_OUT, 0, beneficiary);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(beneficiary), AMOUNT_OUT, "leg 0's recipient paid");
        assertEq(tB.balanceOf(maker), 0, "not the maker");
    }

    /// @dev `amountOutOffset = 32`: the amountOut word is the core's LIVE
    ///      `pricedOut[0]` (typed callback) — a stale word in the plan is overwritten.
    function test_direct_exactOut_liveAmountOutPatch() public {
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, 1, NO_PATCH, 32, 0);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "paid the live priced amount, not the stale word");
    }

    /// @dev The netted entry: `executeItemFill` runs the same pool route as its CALL
    ///      step (state 5 → SWAPPING → 5) and pushes the proceeds to the pool.
    function test_itemFill_poolRoute() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), 0, 0, 0, NO_PATCH, AMOUNT_OUT);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid");
        assertGt(tB.balanceOf(TREASURY), 0, "spread split");
    }

    // ════════════════════════ floors still hold ════════════════════════

    function test_floor_pull_minOutStillEnforced() public {
        _rate(poolAB, address(tA), 9_500); // 100 → 95
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, 0, NO_PATCH, NO_PATCH, 96e18);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, 95e18, 96e18)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    function test_floor_pull_maxPayStillCaps() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, 0, NO_PATCH, NO_PATCH, AMOUNT_OUT);
        p.maxPay = AMOUNT_OUT - 1;
        vm.expectRevert(); // Settlement's pull exceeds the capped approval
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// @dev The maker's floor on the DIRECT path is the core's delta check: a route
    ///      that pays less than owed reverts there.
    function test_floor_direct_coreDeltaCheck() public {
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p =
            _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT - 1, NO_PATCH, NO_PATCH, 0);
        vm.expectRevert(Base.DeltaTooLow.selector);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// @dev THE BUDGET IS THE FILL'S DELTA, NOT THE SOLVER'S BALANCE. The solver holds
    ///      500 tA of retained value; an exact-output route whose pool now wants more
    ///      than this fill delivered — with a ceiling word far above it — reverts
    ///      {PoolOverBudget} at the routed delta, and the retained value is intact.
    function test_budget_exactOut_neverReachesHeldValue() public {
        tA.mint(address(aggSolver), 500e18);
        _rate(poolAB, address(tA), 5_000); // 90 tB now costs 180 tA
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p =
            _poolPlan(_hop1(address(tA), F500, 0, address(tB)), type(uint128).max, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.PoolOverBudget.selector, 180e18, AMOUNT_IN))
        );
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tA.balanceOf(address(aggSolver)), 500e18, "held value untouched");
    }

    /// @dev The plan's own ceiling binds when it is BELOW the delta (the beta keeps its
    ///      margin with it).
    function test_budget_exactOut_planCeilingBinds() public {
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), 89e18, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.PoolOverBudget.selector, 90e18, 89e18)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// @dev Exact-input with an UNPATCHED amount above the fill's delta (a stale quote
    ///      for a bigger fill): refused before any swap, even with held value around.
    function test_budget_exactIn_quotedAboveDeltaReverts() public {
        tA.mint(address(aggSolver), 500e18);
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p =
            _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN + 1, 0, NO_PATCH, NO_PATCH, AMOUNT_OUT);
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.PoolOverBudget.selector, AMOUNT_IN + 1, AMOUNT_IN))
        );
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    // ════════════════════════ route validation ════════════════════════

    function _expectBadRoute(Order memory o, RoutePlan memory p) internal {
        bytes memory sig = _sign(o);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.BadPoolRoute.selector)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    function test_route_firstTokenMustBeTheAnchorInput() public {
        tC.mint(address(aggSolver), 500e18); // held value in another token
        _expectBadRoute(_order(1), _poolPlan(_hop1(address(tC), F500, 0, address(tB)), 0, 0, 0, NO_PATCH, AMOUNT_OUT));
    }

    function test_route_lastTokenMustBeTheAnchorOutput() public {
        _expectBadRoute(_order(1), _poolPlan(_hop1(address(tA), F3000, 0, address(tC)), 0, 0, 0, NO_PATCH, AMOUNT_OUT));
    }

    function test_route_malformedLengthAndHops() public {
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), 0, 0, 0, NO_PATCH, AMOUNT_OUT);
        p.data = bytes.concat(p.data, hex"00"); // one stray byte
        _expectBadRoute(_order(1), p);
        p.data = abi.encodePacked(uint256(0), uint256(0), address(tA)); // no hop at all
        _expectBadRoute(_order(2), p);
        // Five hops (> MAX_POOL_HOPS = 4).
        bytes memory path = abi.encodePacked(address(tA));
        for (uint256 i; i < 5; i++) path = abi.encodePacked(path, F500, uint8(0), i == 4 ? address(tB) : address(tC));
        p.data = abi.encodePacked(uint256(0), uint256(0), path);
        _expectBadRoute(_order(3), p);
    }

    function test_route_offsetsMustBeTheWordPositions() public {
        _expectBadRoute(_order(1), _poolPlan(_hop1(address(tA), F500, 0, address(tB)), 0, 0, 4, NO_PATCH, AMOUNT_OUT));
        _expectBadRoute(
            _directOrder(2), _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, 0, 0)
        );
    }

    function test_route_amountOutAboveInt256Refused() public {
        _expectBadRoute(
            _directOrder(1),
            _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, uint256(type(int256).max) + 1, NO_PATCH, NO_PATCH, 0)
        );
    }

    /// @dev A hop on a pool that does not exist (no code at the derived address).
    function test_route_nonexistentPoolReverts() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), 100, 0, address(tB)), 0, 0, 0, NO_PATCH, AMOUNT_OUT);
        // The assembly `pool.swap` requires a 64-byte return: an address without code
        // returns nothing → {BadPoolSwap} (pins the selector hard-coded in `_poolSwap`).
        assertEq(AggregatorFillSolver.BadPoolSwap.selector, bytes4(0x17d3a782), "selector in _poolSwap");
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.BadPoolSwap.selector)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    // ════════════════════ assembly equivalence (2026-10-12 gas pass) ════════════════════

    /// @dev `_derive` (scratch-memory CREATE2) against the plain-Solidity formula it
    ///      replaced, over arbitrary tokens / fees, both argument orders and both venues.
    function testFuzz_poolFor_matchesReferenceFormula(address a, address b, uint24 fee, bool venue1) public view {
        uint256 v = venue1 ? 1 : 0;
        (address factory, bytes32 initCodeHash) = aggSolver.poolVenue(v);
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        address ref = address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encode(t0, t1, fee)), initCodeHash))))
        );
        assertEq(aggSolver.poolFor(v, a, b, fee), ref, "a,b");
        assertEq(aggSolver.poolFor(v, b, a, fee), ref, "b,a");
    }

    /// @dev The free-memory pointer survives `_derive` (it borrows word 0x40 for the salt
    ///      preimage): a view call that allocates after it returns well-formed data.
    function test_poolFor_preservesFreeMemoryPointer() public view {
        // `poolVenue` + `_derive` + ABI-encoding the return: a corrupted pointer would
        // garble the returned word or revert.
        assertEq(aggSolver.poolFor(0, address(tA), address(tB), F500), address(poolAB));
        (address f,) = aggSolver.poolVenue(0);
        assertEq(f, address(fac0));
    }

    /// @dev {NO_PATCH} is "bit 255 set": `2^255` (the cheap calldata word, the SDK's
    ///      value) and the pre-2026-10-12 `type(uint256).max` both leave the words alone,
    ///      on a pool route and on an opaque one.
    function test_noPatch_anyBit255Value() public {
        assertEq(NO_PATCH, uint256(1) << 255, "canonical sentinel");
        // Pool route, direct exact-out, both offsets = the OLD sentinel.
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        uint256 max = type(uint256).max;
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, max, max, 0);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "old sentinel = no patch (pool)");
        // Any other bit-255 value too.
        Order memory o2 = _directOrder(2);
        bytes memory sig2 = _sign(o2);
        RoutePlan memory p2 = _poolPlan(
            _hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, (uint256(1) << 255) | 7, NO_PATCH, 0
        );
        aggSolver.executeFill(o2, sig2, AMOUNT_IN, p2, "", _np());
        assertEq(tB.balanceOf(maker), 2 * AMOUNT_OUT, "2^255|7 = no patch (pool)");
        // A value just below bit 255 is an OFFSET, and on a pool route only 0 / 32 are.
        _expectBadRoute(
            _directOrder(3),
            _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, (uint256(1) << 255) - 1, NO_PATCH, 0)
        );
    }

    /// @dev Exact-output RECURSION with a forged prefix: callback data whose current hop
    ///      starts less than one hop past the budget word cannot address a previous hop
    ///      — `h − 24` underflows and the callback reverts before paying anyone, even
    ///      from the genuine pool of that hop while armed.
    function test_callback_shortPrefixRecursionReverts() public {
        vm.store(address(aggSolver), bytes32(0), bytes32(uint256(6))); // _active = SWAPPING
        bytes memory d = abi.encodePacked(bytes10(0), _hop1(address(tA), F500, 0, address(tB))); // h = 10
        bool aIs0 = address(tA) < address(tB);
        tA.mint(address(aggSolver), 500e18);
        vm.prank(address(poolAB));
        vm.expectRevert(); // arithmetic underflow (panic 0x11)
        aggSolver.uniswapV3SwapCallback(aIs0 ? int256(1e18) : int256(0), aIs0 ? int256(0) : int256(1e18), d);
        // Data shorter than one hop: `length − 44` underflows.
        vm.prank(address(poolAB));
        vm.expectRevert();
        aggSolver.uniswapV3SwapCallback(1, 0, hex"00112233");
        assertEq(tA.balanceOf(address(aggSolver)), 500e18, "nothing paid");
    }

    // ════════════════════════ the callback's gates ════════════════════════

    function _cbData(uint256 budget, bytes memory hops) internal pure returns (bytes memory) {
        return abi.encodePacked(budget, hops);
    }

    /// @dev UNARMED: even the genuine pool, with well-formed data, gets nothing
    ///      outside a fill — before any fill, and after one completed.
    function test_callback_unarmed_revertsEvenForTheGenuinePool() public {
        bytes memory d = _cbData(500e18, _hop1(address(tA), F500, 0, address(tB)));
        bool aIs0 = address(tA) < address(tB);
        vm.prank(address(poolAB));
        vm.expectRevert(AggregatorFillSolver.NotArmed.selector);
        aggSolver.uniswapV3SwapCallback(aIs0 ? int256(1e18) : int256(0), aIs0 ? int256(0) : int256(1e18), d);

        test_direct_exactOut_singleHop(); // leaves the solver holding its 1-wei floor
        vm.prank(address(poolAB));
        vm.expectRevert(AggregatorFillSolver.NotArmed.selector);
        aggSolver.uniswapV3SwapCallback(aIs0 ? int256(1e18) : int256(0), aIs0 ? int256(0) : int256(1e18), d);
    }

    /// @dev WRONG CALLER WHILE ARMED: a token hook gains control mid-swap (the pool
    ///      pays the hook token out) and calls the callback naming the REAL pool with
    ///      a fat budget. `msg.sender` is the hook, not the derived pool: {NotPool}.
    function test_callback_armed_wrongCallerRefused() public {
        HookToken h = new HookToken();
        MockV3Pool pH = fac0.createPool(address(tA), address(h), F500);
        h.mint(address(pH), 1_000e18);
        tA.mint(address(aggSolver), 500e18); // something to steal
        Order memory o = _plainOrder(1, address(tA), address(h), AMOUNT_IN, AMOUNT_OUT);
        o.timing |= uint256(1) << 104;
        o.exclusiveFiller = address(aggSolver);
        bytes memory sig = _sign(o);
        bool aIs0 = address(tA) < address(h);
        h.arm(
            address(aggSolver),
            abi.encodeCall(
                AggregatorFillSolver.uniswapV3SwapCallback,
                (
                    aIs0 ? int256(500e18) : int256(0),
                    aIs0 ? int256(0) : int256(500e18),
                    _cbData(type(uint256).max, _hop1(address(tA), F500, 0, address(h)))
                )
            )
        );
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(h)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertTrue(h.fired(), "the hook ran mid-swap");
        assertEq(bytes4(h.ret()), AggregatorFillSolver.NotPool.selector, "refused: not the derived pool");
        assertEq(tA.balanceOf(address(h)), 0, "the hook got nothing");
        assertEq(tA.balanceOf(address(aggSolver)), 500e18, "held value intact (the residue went to the treasury)");
        assertEq(tA.balanceOf(TREASURY), AMOUNT_IN - AMOUNT_OUT, "residue split as usual");
    }

    /// @dev REENTRY: the hook is an OPERATOR of its instance and re-enters
    ///      `executeFill` and `sweep` mid-swap — both {Reentrancy}.
    function test_callback_reentryFromSwapRefused() public {
        HookToken h = new HookToken();
        address[] memory ops = new address[](2);
        (ops[0], ops[1]) = (address(this), address(h));
        AggregatorFillSolver s = _venueSolver(ops);
        MockV3Pool pH = fac0.createPool(address(tA), address(h), F500);
        h.mint(address(pH), 1_000e18);
        Order memory o = _plainOrder(1, address(tA), address(h), AMOUNT_IN, AMOUNT_OUT);
        o.timing |= uint256(1) << 104;
        o.exclusiveFiller = address(s);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(h)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);

        h.arm(address(s), abi.encodeCall(AggregatorFillSolver.sweep, (address(tA), address(h), 1)));
        s.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(bytes4(h.ret()), AggregatorFillSolver.Reentrancy.selector, "sweep refused mid-swap");

        Order memory o2 = _plainOrder(2, address(tA), address(h), AMOUNT_IN, AMOUNT_OUT);
        o2.timing |= uint256(1) << 104;
        o2.exclusiveFiller = address(s);
        bytes memory sig2 = _sign(o2);
        Order memory o3 = _plainOrder(3, address(tA), address(h), AMOUNT_IN, AMOUNT_OUT);
        o3.timing |= uint256(1) << 104;
        o3.exclusiveFiller = address(s);
        bytes memory sig3 = _sign(o3);
        h.arm(address(s), abi.encodeCall(AggregatorFillSolver.executeFill, (o2, sig2, AMOUNT_IN, p, "", _np())));
        s.executeFill(o3, sig3, AMOUNT_IN, p, "", _np());
        assertEq(bytes4(h.ret()), AggregatorFillSolver.Reentrancy.selector, "executeFill refused mid-swap");
    }

    /// @dev A GENUINE pool that echoes data for ANOTHER pool: the callback binds the
    ///      caller to the hop IN THE DATA, so a real pool cannot spend another hop's
    ///      budget (or claim to be another pool).
    function test_callback_genuinePoolWithAnotherHopsData_refused() public {
        poolAB.setMisbehaviour(0, false, 0, _cbData(AMOUNT_IN, _hop1(address(tA), F3000, 1, address(tB))));
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.NotPool.selector)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// @dev WRONG TOKEN: a pool that reports the owed amount on the OUTPUT side —
    ///      the hop's input delta is then ≤ 0 and nothing is paid.
    function test_callback_owedOnTheWrongToken_refused() public {
        poolAB.setMisbehaviour(0, true, 0, "");
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.BadPoolSwap.selector)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// @dev WRONG AMOUNT: a pool asking for more than the hop's budget gets nothing.
    function test_callback_owedAboveBudget_refused() public {
        poolAB.setMisbehaviour(int256(AMOUNT_IN), false, 0, ""); // owes 90 + 100
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.PoolOverBudget.selector, AMOUNT_OUT + AMOUNT_IN, AMOUNT_IN))
        );
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// @dev Exact-input that stops early, exact-output that delivers short: both
    ///      refused (no stranded intermediate, no short delivery reported as filled).
    function test_callback_partialSwapsRefused() public {
        poolAB.setMisbehaviour(0, false, 100, ""); // 1% short
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, 0, NO_PATCH, NO_PATCH, 0);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.BadPoolSwap.selector)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());

        Order memory d = _directOrder(2);
        bytes memory sigD = _sign(d);
        RoutePlan memory q = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.BadPoolSwap.selector)));
        aggSolver.executeFill(d, sigD, AMOUNT_IN, q, "", _np());
    }

    /// @dev The swap state is restored after the swap (6 → 3) and the fill's after the
    ///      fill (3 → 1): a second fill on the same instance runs normally.
    function test_callback_stateRestoredAfterSwap() public {
        test_direct_exactOut_singleHop();
        // A second fill on the same instance works: the state went 6 → 3 → 1.
        Order memory o = _directOrder(2);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), 2 * AMOUNT_OUT);
    }

    // ════════════════════════ ERC-2612 permits ════════════════════════

    Erc2612Token internal pt;
    MockV3Pool internal poolPB;

    /// @dev A permit-token market: the maker holds `pt`, has approved NOTHING (no
    ///      Permit3 grant, no Settlement allowance).
    function _permitMarket() internal returns (Order memory o, bytes memory sig, RoutePlan memory p) {
        pt = new Erc2612Token();
        poolPB = fac0.createPool(address(pt), address(tB), F500);
        tB.mint(address(poolPB), 1_000e18);
        pt.mint(maker, AMOUNT_IN);
        o = _plainOrder(1, address(pt), address(tB), AMOUNT_IN, AMOUNT_OUT);
        o.timing |= uint256(1) << 104;
        o.exclusiveFiller = address(aggSolver);
        sig = _sign(o);
        p = _poolPlan(_hop1(address(pt), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
    }

    function _signPermit(uint256 pk, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (Permit2612 memory p)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                pt.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(pt.PERMIT_TYPEHASH(), owner, address(settlement), value, pt.nonces(owner), deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        p = Permit2612({token: address(pt), owner: owner, value: value, deadline: deadline, v: v, r: r, s: s});
    }

    function _one(Permit2612 memory p) internal pure returns (Permit2612[] memory ps) {
        ps = new Permit2612[](1);
        ps[0] = p;
    }

    function test_permit_unfundedWithoutIt() public {
        (Order memory o, bytes memory sig, RoutePlan memory p) = _permitMarket();
        vm.expectRevert(); // the maker's pull finds neither Permit3 nor a direct allowance
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// @dev HAPPY PATH: one transaction — the solver lands the maker's permit to
    ///      SETTLEMENT, the core's direct-approval fallback pulls with it, the pool
    ///      route pays the maker. The allowance is used up exactly.
    function test_permit_happyPath() public {
        (Order memory o, bytes memory sig, RoutePlan memory p) = _permitMarket();
        Permit2612 memory pm = _signPermit(makerPk, maker, AMOUNT_IN, block.timestamp + 1 hours);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _one(pm));
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid");
        assertEq(pt.balanceOf(maker), 0, "input pulled through the permit's allowance");
        assertEq(pt.allowance(maker, address(settlement)), 0, "allowance consumed exactly");
        assertEq(pt.nonces(maker), 1, "the permit landed");
    }

    /// @dev RELAYED FIRST (front-run, or the maker sent it): our permit call reverts
    ///      on the spent nonce, and the allowance already covers it — accepted.
    function test_permit_relayedFirst_accepted() public {
        (Order memory o, bytes memory sig, RoutePlan memory p) = _permitMarket();
        Permit2612 memory pm = _signPermit(makerPk, maker, AMOUNT_IN, block.timestamp + 1 hours);
        vm.prank(address(0xF00D));
        pt.permit(maker, address(settlement), pm.value, pm.deadline, pm.v, pm.r, pm.s);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _one(pm));
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "filled on the relayed allowance");
    }

    /// @dev Only the ORDER'S MAKER may be a permit's owner — the operator-gated entry
    ///      is no relay for anyone else's permits.
    function test_permit_wrongOwnerRefused() public {
        (Order memory o, bytes memory sig, RoutePlan memory p) = _permitMarket();
        uint256 evePk = 0xE7E;
        address eve = vm.addr(evePk);
        pt.mint(eve, 1);
        Permit2612 memory pm = _signPermit(evePk, eve, 1, block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.PermitOwnerNotMaker.selector, eve));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _one(pm));
    }

    /// @dev A permit that fails (bad signature) with no allowance behind it reverts
    ///      {PermitFailed} before anything moves; so does an expired one, and one whose
    ///      relayed allowance is SMALLER than its value.
    function test_permit_failedWithoutAllowanceReverts() public {
        (Order memory o, bytes memory sig, RoutePlan memory p) = _permitMarket();
        Permit2612 memory bad = _signPermit(0xBAD, maker, AMOUNT_IN, block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.PermitFailed.selector, address(pt)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _one(bad));

        Permit2612 memory expired = _signPermit(makerPk, maker, AMOUNT_IN, block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.PermitFailed.selector, address(pt)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _one(expired));

        // An allowance exists, but one wei short of the permit's value: still refused.
        vm.prank(maker);
        pt.approve(address(settlement), AMOUNT_IN - 1);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.PermitFailed.selector, address(pt)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _one(bad));
    }

    /// @dev A maker in Permit3 STRICT MODE has switched the direct-approval fallback
    ///      off: the permit lands (Settlement's allowance is set) but the core's pull
    ///      refuses `Permit3Denied`, and the whole fill — permit included — reverts.
    ///      Strict makers must fund through Permit3; a permit to Settlement cannot.
    function test_permit_strictMakerHasNoFallback() public {
        (Order memory o, bytes memory sig, RoutePlan memory p) = _permitMarket();
        vm.prank(maker);
        permit3.setStrictMode(true);
        Permit2612 memory pm = _signPermit(makerPk, maker, AMOUNT_IN, block.timestamp + 1 hours);
        vm.expectRevert(IPermit3.Permit3Denied.selector);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _one(pm));
        assertEq(pt.nonces(maker), 0, "reverted with the fill");
    }

    /// @dev The netted entry carries permits too (its PULL step uses the same fallback).
    function test_permit_executeItemFill() public {
        (Order memory o,, RoutePlan memory p) = _permitMarket();
        o.timing &= ~(uint256(1) << 104); // the netted path refuses delta-verify orders
        o.exclusiveFiller = address(0);
        bytes memory sig = _sign(o);
        p = _poolPlan(_hop1(address(pt), F500, 0, address(tB)), 0, 0, 0, NO_PATCH, AMOUNT_OUT);
        Permit2612 memory pm = _signPermit(makerPk, maker, AMOUNT_IN, block.timestamp + 1 hours);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _one(pm), noGuard());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid");
        assertEq(pt.balanceOf(maker), 0, "pulled with the permit");
    }

    /// @dev The permit call is `permit(...)` FROM THE SOLVER to an operator-named
    ///      address: pin that no protocol contract answers that selector, so naming
    ///      one can only fail (and then the allowance check refuses).
    function test_permit_selectorUnknownToTheProtocol() public {
        address[3] memory targets = [address(settlement), address(permit3), aggSolver.EXECUTOR()];
        for (uint256 i; i < 3; i++) {
            (bool ok,) = targets[i].call(
                abi.encodeWithSelector(0xd505accf, maker, address(settlement), 1, block.timestamp, uint8(27), bytes32(0), bytes32(0))
            );
            assertFalse(ok, "no protocol contract implements permit(address,address,uint256,uint256,uint8,bytes32,bytes32)");
        }
    }

    /// @dev Non-operators still cannot reach anything, permits or not.
    function test_permit_operatorGateFirst() public {
        (Order memory o, bytes memory sig, RoutePlan memory p) = _permitMarket();
        Permit2612 memory pm = _signPermit(makerPk, maker, AMOUNT_IN, block.timestamp + 1 hours);
        vm.prank(address(0xE7E));
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.NotOperator.selector, address(0xE7E)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _one(pm));
        assertEq(pt.nonces(maker), 0, "nothing ran");
    }

    // ════════════════════════ unit gas (mocks; read the DIFFERENCE) ════════════════════════
    //
    // Same harness, same floors (1 wei of tA and tB on the solver, minted in the test
    // body — dirty slots, see the README's EIP-2200 note), mocked tokens / router /
    // pool. The fork figures (`PoolRouteFork.t.sol`) are the ones to quote.

    function _gasFloors() internal {
        tA.mint(address(aggSolver), 1);
        tB.mint(address(aggSolver), 1);
        tB.mint(maker, 1);
        tA.mint(TREASURY, 1);
        tB.mint(TREASURY, 1);
        // The sandbox's standing router approval, as after its first fill.
        vm.prank(address(aggSolver.SANDBOX()));
        tA.approve(address(router), type(uint256).max);
    }

    function test_gas_unit_direct_sandbox() public {
        _gasFloors();
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _exactOutPlan(AMOUNT_OUT, AMOUNT_IN, maker);
        p.profitRecipient = TREASURY;
        uint256 g0 = gasleft();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        emit log_named_uint("unit: SANDBOX direct exact-out", g0 - gasleft());
    }

    function test_gas_unit_direct_pool() public {
        _gasFloors();
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, AMOUNT_OUT, NO_PATCH, NO_PATCH, 0);
        uint256 g0 = gasleft();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        emit log_named_uint("unit: POOL direct exact-out   ", g0 - gasleft());
    }

    function test_gas_unit_pull_sandbox() public {
        _gasFloors();
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(aggSolver), AMOUNT_OUT, NO_PATCH);
        p.profitRecipient = TREASURY;
        uint256 g0 = gasleft();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        emit log_named_uint("unit: SANDBOX pull exact-in   ", g0 - gasleft());
    }

    function test_gas_unit_pull_pool() public {
        _gasFloors();
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _poolPlan(_hop1(address(tA), F500, 0, address(tB)), AMOUNT_IN, 0, NO_PATCH, NO_PATCH, AMOUNT_OUT);
        uint256 g0 = gasleft();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        emit log_named_uint("unit: POOL pull exact-in      ", g0 - gasleft());
    }
}
