// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Settlement} from "@core/settlement/Settlement.sol";
import {AggregatorFillSolver, SurplusPolicy, PoolVenue} from "@solvers/aggregator/AggregatorFillSolver.sol";
import {RouteSandbox} from "@solvers/aggregator/RouteSandbox.sol";
import {NativeBalance} from "@periphery/NativeBalance.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface INativeBalanceMin {
    function balanceOf(address a) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IV3FactoryMin {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @title DeployAggregatorFill
/// @notice Deploys one {AggregatorFillSolver} instance — the zero-inventory,
///         DEX-routed filler the Rootstock beta's "route" strategy drives — and
///         asserts every immutable against what was asked for.
///
///  ⚠ RUN WITH `FOUNDRY_PROFILE=solvers-deploy` (the `deploy-aggregator-fill` make
///  target sets it). That profile pins `evm_version = "cancun"`: Rootstock does not
///  implement Prague, and the repo default would emit opcodes it cannot run.
///
///  Plain CREATE, no salt: the instance's identity is its constructor arguments
///  (operator set, policy), neither of which other chains need to predict. Both are
///  immutable — supporting another operator means deploying another instance. There
///  is NO router set (BREAKING, 2026-10): the constructor deploys a {RouteSandbox}
///  that runs every route and may call any target, so a new venue needs nothing.
///
///  The signer comes from the CLI (`--account`/`--sender`, `--ledger`,
///  `--private-key`, …); `vm.startBroadcast()` is called with no key.
///
///  Env
///  ───
///    SETTLEMENT            required — the deployed Settlement
///    OPERATORS             REQUIRED comma list (1..4) — the filler EOA(s). Every
///                          instance is gated since 2026-10: the constructor
///                          reverts on an empty set (NoOperators), and the old
///                          ALLOW_OPEN escape hatch is refused.
///    ALLOW_CONTRACT_OPERATORS  default false — an operator address WITH CODE (a
///                          Safe, any contract, or an EIP-7702 delegated EOA,
///                          whose code is the 0xef0100 delegation designator) is
///                          refused unless this is true. Such an operator's code can
///                          be reached mid-fill by a route (a hook, a callback) and
///                          re-enter the solver as an operator; the solver's
///                          reentrancy guard holds, but the operator is then only
///                          as safe as that code. Logged loudly either way.
///    MAKER_SURPLUS_PPM     default 0 (≤ 1_000_000; must fit uint32 — checked, not
///                          truncated)
///    PROTOCOL_SURPLUS_PPM  default 0 (same)
///    PROTOCOL_RECIPIENT    default 0x0 (required when PROTOCOL_SURPLUS_PPM != 0)
///    POOL_FACTORIES        comma list (0..4) — the Uniswap-v3-style factories a
///                          DIRECT POOL ROUTE may swap on (venue index = position).
///    POOL_INIT_HASHES      comma list, same length — each factory's pool init code
///                          hash. Both unset on chain 30 = the verified Rootstock
///                          defaults: venue 0 = Uniswap v3 / Oku factory
///                          0xaF37EC98A00FD63689CF3060BF3B6784E00caD82, venue 1 =
///                          SushiSwap v3 factory
///                          0x46B3fDF7b5CDe91Ac049936bF0bDb12c5d22202e, both with the
///                          canonical v3 hash 0xe34f199b…8b54 (checked 2026-10-12 by
///                          deriving the live WRBTC/USDT0 0.3% pools 0xaeF6…9Bbd and
///                          0x6d77…Fd71 — the script re-derives them after deploying).
///                          Unset elsewhere = no venues (pool routes off).
///    NO_POOL_VENUES        default false — true deploys with no venues even on 30.
///    NATIVE_BALANCE        default 0x0 — the deployed `NativeBalance` view token
///                          (packages/periphery/src/NativeBalance.sol) DIRECT orders
///                          name to receive raw native coin (task 30, solver v3).
///                          Unset = native delivery OFF (both immutables zero).
///    DEPLOY_NATIVE_BALANCE default false — true deploys a fresh `NativeBalance` in the
///                          same run, BEFORE the solver, and wires it in (so one run —
///                          and one simulation — covers both). Refused together with
///                          NATIVE_BALANCE.
///    WNATIVE               the wrapped native such an order's route ends in. Default
///                          on chain 30 when NATIVE_BALANCE is set: WRBTC
///                          0x542fDA317318eBF1d3DEAf76E0b632741A7e677d. Elsewhere it
///                          is REQUIRED with NATIVE_BALANCE, and refused without it.
///    FLOOR_TOKENS          optional, and NO LONGER NEEDED (2026-10) — comma list of
///                          tokens to pre-seed a 1-wei balance floor of on the
///                          SOLVER (the deployer must hold 1 wei of each). The
///                          solver now seeds that floor itself, out of the
///                          filler's side of its first fill of each token (README,
///                          "The floor seeds itself"); pre-seeding only saves that
///                          one fill the refund it forgoes. The removed ROUTERS /
///                          STANDING / PRIME_TOKENS are refused.
///
///  Usage (Rootstock, Foundry keystore)
///  ───────────────────────────────────
///      make deploy-aggregator-fill RPC=https://public-node.rsk.co \
///        DEPLOY_ARGS="--account deployer --sender 0x… --legacy --gas-estimate-multiplier 110" \
///        VERIFY_ARGS="--verify --verifier blockscout --verifier-url https://rootstock.blockscout.com/api/"
contract DeployAggregatorFill is Script {
    function run() public returns (AggregatorFillSolver agg) {
        address settlement = vm.envAddress("SETTLEMENT");
        require(settlement.code.length != 0, "SETTLEMENT has no code on this chain");
        // The pre-sandbox configuration knobs. Refused rather than ignored: a deploy
        // that names them expects a router allowlist / standing approvals this
        // contract no longer has.
        require(bytes(vm.envOr("ROUTERS", string(""))).length == 0, "ROUTERS was removed: routes run in RouteSandbox");
        require(bytes(vm.envOr("STANDING", string(""))).length == 0, "STANDING was removed (no router approvals)");
        require(bytes(vm.envOr("PRIME_TOKENS", string(""))).length == 0, "PRIME_TOKENS was removed");
        require(
            !vm.envOr("ALLOW_OPEN", false),
            "ALLOW_OPEN was removed: every AggregatorFillSolver is operator-gated (2026-10)"
        );

        address[] memory operators = _addrList("OPERATORS");
        require(operators.length != 0, "OPERATORS empty: every instance is gated (constructor reverts NoOperators)");
        _checkOperatorCode(operators);

        SurplusPolicy memory policy = SurplusPolicy({
            makerPpm: _ppm("MAKER_SURPLUS_PPM"),
            protocolPpm: _ppm("PROTOCOL_SURPLUS_PPM"),
            protocolRecipient: vm.envOr("PROTOCOL_RECIPIENT", address(0))
        });
        // The constructor's `BadSurplusSplit`, as named env errors rather than a
        // bare selector out of the pre-broadcast simulation.
        require(
            uint256(policy.makerPpm) + policy.protocolPpm <= 1_000_000,
            "MAKER_SURPLUS_PPM + PROTOCOL_SURPLUS_PPM exceeds 1_000_000 ppm"
        );
        require(
            policy.protocolPpm == 0 || policy.protocolRecipient != address(0),
            "PROTOCOL_RECIPIENT is required when PROTOCOL_SURPLUS_PPM != 0"
        );
        PoolVenue[] memory venues = _venues();
        bool deployNative = vm.envOr("DEPLOY_NATIVE_BALANCE", false);
        (address nativeBalance, address wnative) = deployNative ? _nativeToDeploy() : _native();
        address[] memory floorTokens = _addrList("FLOOR_TOKENS");
        for (uint256 i; i < floorTokens.length; i++) {
            require(floorTokens[i].code.length != 0, "a FLOOR_TOKENS entry has no code on this chain");
        }

        console.log("--- AggregatorFillSolver (chain %s) ---", block.chainid);
        console.log("settlement      ", settlement);
        console.log("operators       ", operators.length);
        console.log("pool venues     ", venues.length);
        if (deployNative) console.log("native balance   (deployed in this run)");
        else console.log("native balance  ", nativeBalance);
        console.log("wnative         ", wnative);

        vm.startBroadcast();
        if (deployNative) nativeBalance = address(new NativeBalance());
        agg = new AggregatorFillSolver(settlement, operators, policy, venues, nativeBalance, wnative);
        // OPTIONAL pre-seed of the solver's balance floor: one wei per listed token,
        // so even the FIRST fill's inbound transfer rewrites a live slot. Without it
        // the solver keeps one wei of each token out of its own first fill of it.
        for (uint256 i; i < floorTokens.length; i++) {
            require(IERC20Min(floorTokens[i]).transfer(address(agg), 1), "floor seed transfer failed");
        }
        vm.stopBroadcast();

        console.log("AggregatorFillSolver", address(agg));
        console.log("RouteSandbox        ", address(agg.SANDBOX()));
        _assertDeployed(agg, settlement, operators, policy);
        _assertVenues(agg, venues);
        if (deployNative) {
            console.log("NativeBalance       ", nativeBalance);
            _probeNative(nativeBalance);
        }
        (address nbDeployed, address wDeployed) = agg.nativeDelivery();
        require(nbDeployed == nativeBalance, "NATIVE_BALANCE mismatch");
        require(wDeployed == wnative, "WNATIVE mismatch");
        console.log("immutables verified");
    }

    /// @dev Read the deployed contract back and compare it with the inputs. These
    ///      cannot fail if the constructor is right, which is exactly why they are
    ///      worth running: they check the code AT THE ADDRESS, not the init code sent.
    function _assertDeployed(
        AggregatorFillSolver agg,
        address settlement,
        address[] memory operators,
        SurplusPolicy memory policy
    ) internal view {
        require(address(agg.SETTLEMENT()) == settlement, "SETTLEMENT mismatch");
        address executor = address(Settlement(payable(settlement)).EXECUTOR());
        require(agg.EXECUTOR() == executor, "EXECUTOR mismatch");
        require(agg.GATED(), "GATED mismatch");
        RouteSandbox sb = agg.SANDBOX();
        require(address(sb).code.length != 0, "SANDBOX has no code");
        require(sb.OWNER() == address(agg), "SANDBOX owner mismatch");
        require(sb.SETTLEMENT() == settlement, "SANDBOX settlement mismatch");
        require(sb.PERMIT3() == address(Settlement(payable(settlement)).PERMIT3()), "SANDBOX permit3 mismatch");
        require(sb.EXECUTOR() == executor, "SANDBOX executor mismatch");
        require(agg.MAKER_SURPLUS_PPM() == policy.makerPpm, "MAKER_SURPLUS_PPM mismatch");
        require(agg.PROTOCOL_SURPLUS_PPM() == policy.protocolPpm, "PROTOCOL_SURPLUS_PPM mismatch");
        require(agg.PROTOCOL_RECIPIENT() == policy.protocolRecipient, "PROTOCOL_RECIPIENT mismatch");
        for (uint256 i; i < operators.length; i++) {
            require(agg.isOperator(operators[i]), "operator not set");
            console.log("  operator", operators[i]);
        }
    }

    /// @dev The venue allowlist: POOL_FACTORIES / POOL_INIT_HASHES, or the verified
    ///      Rootstock defaults on chain 30 when both are unset.
    function _venues() internal view returns (PoolVenue[] memory v) {
        if (vm.envOr("NO_POOL_VENUES", false)) return new PoolVenue[](0);
        address[] memory factories = _addrList("POOL_FACTORIES");
        string memory rawHashes = vm.envOr("POOL_INIT_HASHES", string(""));
        bytes32[] memory hashes = bytes(rawHashes).length == 0 ? new bytes32[](0) : vm.envBytes32("POOL_INIT_HASHES", ",");
        require(factories.length == hashes.length, "POOL_FACTORIES / POOL_INIT_HASHES length mismatch");
        if (factories.length == 0 && block.chainid == 30) {
            factories = new address[](2);
            hashes = new bytes32[](2);
            (factories[0], hashes[0]) = (ROOTSTOCK_OKU_FACTORY, UNIV3_INIT_HASH);
            (factories[1], hashes[1]) = (ROOTSTOCK_SUSHI_V3_FACTORY, UNIV3_INIT_HASH);
        }
        v = new PoolVenue[](factories.length);
        for (uint256 i; i < factories.length; i++) {
            require(factories[i].code.length != 0, "a POOL_FACTORIES entry has no code on this chain");
            v[i] = PoolVenue({factory: factories[i], initCodeHash: hashes[i]});
        }
    }

    /// @dev The native-delivery pair (task 30): NATIVE_BALANCE / WNATIVE, both or
    ///      neither (the constructor's {AggregatorFillSolver.BadNative}). The view token
    ///      is probed — `balanceOf(x) == x.balance` and 18 decimals — so a wrong address
    ///      fails HERE, not as a `DeltaTooLow` on the first native fill.
    function _native() internal view returns (address nb, address w) {
        nb = vm.envOr("NATIVE_BALANCE", address(0));
        w = vm.envOr("WNATIVE", address(0));
        if (nb == address(0)) {
            require(w == address(0), "WNATIVE set without NATIVE_BALANCE");
            return (nb, w);
        }
        if (w == address(0) && block.chainid == 30) w = RSK_WRBTC;
        require(w != address(0), "WNATIVE is required with NATIVE_BALANCE off chain 30");
        require(nb.code.length != 0, "NATIVE_BALANCE has no code on this chain");
        require(w.code.length != 0, "WNATIVE has no code on this chain");
        _probeNative(nb);
    }

    /// @dev DEPLOY_NATIVE_BALANCE: the view is created in the broadcast, so only the
    ///      wrapped native is resolved here (same default and checks as {_native}).
    function _nativeToDeploy() internal view returns (address nb, address w) {
        require(vm.envOr("NATIVE_BALANCE", address(0)) == address(0), "set NATIVE_BALANCE or DEPLOY_NATIVE_BALANCE, not both");
        w = vm.envOr("WNATIVE", address(0));
        if (w == address(0) && block.chainid == 30) w = RSK_WRBTC;
        require(w != address(0), "WNATIVE is required with DEPLOY_NATIVE_BALANCE off chain 30");
        require(w.code.length != 0, "WNATIVE has no code on this chain");
        nb = address(0); // assigned in the broadcast
    }

    /// @dev `balanceOf(x) == x.balance` and 18 decimals — a wrong address fails HERE,
    ///      not as a `DeltaTooLow` on the first native fill.
    function _probeNative(address nb) internal view {
        address probe = address(0xdead);
        require(INativeBalanceMin(nb).balanceOf(probe) == probe.balance, "NATIVE_BALANCE is not a NativeBalance view");
        require(INativeBalanceMin(nb).decimals() == 18, "NATIVE_BALANCE decimals != 18");
    }

    address internal constant ROOTSTOCK_OKU_FACTORY = 0xaF37EC98A00FD63689CF3060BF3B6784E00caD82;
    address internal constant ROOTSTOCK_SUSHI_V3_FACTORY = 0x46B3fDF7b5CDe91Ac049936bF0bDb12c5d22202e;
    bytes32 internal constant UNIV3_INIT_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address internal constant RSK_WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    address internal constant RSK_USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;

    /// @dev Read every venue back, and prove each derives a pool its factory knows:
    ///      on chain 30 the WRBTC/USDT0 0.3% pool (both default venues list it), and
    ///      against `factory.getPool` — so a wrong init code hash fails HERE, not on
    ///      the first fill. Off chain 30 the probe pair is POOL_PROBE
    ///      ("tokenA,tokenB,fee"), skipped if unset.
    function _assertVenues(AggregatorFillSolver agg, PoolVenue[] memory venues) internal view {
        require(agg.POOL_VENUES() == venues.length, "POOL_VENUES mismatch");
        (address a, address b, uint24 fee) = (RSK_WRBTC, RSK_USDT0, 3000);
        bool probe = block.chainid == 30;
        string memory raw = vm.envOr("POOL_PROBE", string(""));
        if (bytes(raw).length != 0) {
            string[] memory parts = vm.split(raw, ",");
            require(parts.length == 3, "POOL_PROBE must be tokenA,tokenB,fee");
            (a, b, fee) = (vm.parseAddress(parts[0]), vm.parseAddress(parts[1]), uint24(vm.parseUint(parts[2])));
            probe = true;
        }
        for (uint256 i; i < venues.length; i++) {
            (address f, bytes32 h) = agg.poolVenue(i);
            require(f == venues[i].factory && h == venues[i].initCodeHash, "venue mismatch");
            console.log("  venue factory", f);
            if (!probe) continue;
            address derived = agg.poolFor(i, a, b, fee);
            require(derived == IV3FactoryMin(f).getPool(a, b, fee), "venue init code hash does not derive the factory's pool");
            require(derived.code.length != 0, "probe pool has no code");
            console.log("    probe pool  ", derived);
        }
    }

    /// @dev A ppm env value, read as uint256 and BOUNDED rather than cast: a bare
    ///      `uint32(...)` silently truncates (2^32 + 1 would deploy as 1 ppm).
    function _ppm(string memory name) internal view returns (uint32) {
        uint256 v = vm.envOr(name, uint256(0));
        require(v <= type(uint32).max, string.concat(name, " does not fit uint32"));
        require(v <= 1_000_000, string.concat(name, " exceeds 1_000_000 ppm"));
        return uint32(v);
    }

    /// @dev Refuse (or, with ALLOW_CONTRACT_OPERATORS=true, loudly warn about) an
    ///      operator that has code — a contract, or an EIP-7702 delegated EOA.
    function _checkOperatorCode(address[] memory operators) internal view {
        bool allow = vm.envOr("ALLOW_CONTRACT_OPERATORS", false);
        for (uint256 i; i < operators.length; i++) {
            bytes memory code = operators[i].code;
            if (code.length == 0) continue;
            bool delegated = code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00;
            console.log("!!! WARNING: operator %s HAS CODE", operators[i]);
            console.log(
                delegated
                    ? "!!!   (EIP-7702 delegated EOA: its delegate's code runs whenever it is called)"
                    : "!!!   (a contract: a route can reach it mid-fill and re-enter as an operator)"
            );
            require(allow, "operator has code: set ALLOW_CONTRACT_OPERATORS=true if intended");
        }
    }

    /// @dev A comma-separated address list; unset or empty = empty list (forge's
    ///      own `envOr(name, delim, address[])` rejects an empty string).
    function _addrList(string memory name) internal view returns (address[] memory) {
        string memory raw = vm.envOr(name, string(""));
        if (bytes(raw).length == 0) return new address[](0);
        return vm.envAddress(name, ",");
    }
}
