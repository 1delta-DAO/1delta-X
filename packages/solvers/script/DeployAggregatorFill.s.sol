// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Settlement} from "@core/settlement/Settlement.sol";
import {AggregatorFillSolver, SurplusPolicy} from "@solvers/aggregator/AggregatorFillSolver.sol";
import {RouteSandbox} from "@solvers/aggregator/RouteSandbox.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
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
        address[] memory floorTokens = _addrList("FLOOR_TOKENS");
        for (uint256 i; i < floorTokens.length; i++) {
            require(floorTokens[i].code.length != 0, "a FLOOR_TOKENS entry has no code on this chain");
        }

        console.log("--- AggregatorFillSolver (chain %s) ---", block.chainid);
        console.log("settlement      ", settlement);
        console.log("operators       ", operators.length);

        vm.startBroadcast();
        agg = new AggregatorFillSolver(settlement, operators, policy);
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
