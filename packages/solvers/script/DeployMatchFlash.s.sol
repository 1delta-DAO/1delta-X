// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Settlement} from "@core/settlement/Settlement.sol";
import {MatchFlashSolver, V3Venue, FlashProviders} from "@solvers/match/MatchFlashSolver.sol";

interface IV3FactoryProbe {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @title DeployMatchFlash
/// @notice Deploys one {MatchFlashSolver} — the zero-capital filler for the cycle class
///         (a flash around `matchSettle`) — and asserts every immutable against the inputs.
///
///  ⚠ RUN WITH `FOUNDRY_PROFILE=solvers-deploy` (Cancun, via-IR): Rootstock does not
///  implement Prague. Plain CREATE, no salt. Every input is immutable; a new operator,
///  venue or provider means a new instance.
///
///  Env
///  ───
///    SETTLEMENT        required — the deployed Settlement. Its `matchSettle` must admit
///                      pre-funded MAKE / TAKE_FOR (task 31): the live beta Settlement does
///                      NOT, so this solver is only useful against the next Settlement.
///    OPERATORS         required comma list (1..4) — the only callers of `executeMatch`.
///    POOL_FACTORIES    comma list (0..4) — Uniswap-v3-style factories (venue = position).
///    POOL_INIT_HASHES  same length — each factory's pool init code hash. Both unset on
///                      chain 30 = Oku (venue 0) + SushiSwap v3 (venue 1), canonical v3 hash.
///    NO_POOL_VENUES    default false — deploy with no venues even on chain 30.
///    BALANCER_VAULT    default 0x0 (disabled) — Balancer v2 vault.
///    AAVE_POOL         default 0x0 (disabled) — Aave v3 Pool.
///    MORPHO            default 0x0 (disabled) — Morpho Blue singleton.
///
///  Usage (Rootstock):
///      FOUNDRY_PROFILE=solvers-deploy forge script packages/solvers/script/DeployMatchFlash.s.sol \
///        --rpc-url https://public-node.rsk.co --broadcast --legacy --account deployer --sender 0x…
contract DeployMatchFlash is Script {
    address internal constant ROOTSTOCK_OKU_FACTORY = 0xaF37EC98A00FD63689CF3060BF3B6784E00caD82;
    address internal constant ROOTSTOCK_SUSHI_V3_FACTORY = 0x46B3fDF7b5CDe91Ac049936bF0bDb12c5d22202e;
    bytes32 internal constant UNIV3_INIT_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address internal constant RSK_WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    address internal constant RSK_USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;

    function run() public returns (MatchFlashSolver fs) {
        address settlement = vm.envAddress("SETTLEMENT");
        require(settlement.code.length != 0, "SETTLEMENT has no code on this chain");
        address[] memory operators = _addrList("OPERATORS");
        require(operators.length != 0, "OPERATORS empty: every instance is gated");
        V3Venue[] memory venues = _venues();
        FlashProviders memory providers = FlashProviders({
            balancerVault: vm.envOr("BALANCER_VAULT", address(0)),
            aavePool: vm.envOr("AAVE_POOL", address(0)),
            morpho: vm.envOr("MORPHO", address(0))
        });
        _requireCodeOrZero(providers.balancerVault, "BALANCER_VAULT");
        _requireCodeOrZero(providers.aavePool, "AAVE_POOL");
        _requireCodeOrZero(providers.morpho, "MORPHO");

        console.log("--- MatchFlashSolver (chain %s) ---", block.chainid);
        console.log("settlement ", settlement);
        console.log("operators  ", operators.length);
        console.log("pool venues", venues.length);

        vm.startBroadcast();
        fs = new MatchFlashSolver(settlement, operators, venues, providers);
        vm.stopBroadcast();

        console.log("MatchFlashSolver", address(fs));
        require(address(fs.SETTLEMENT()) == settlement, "SETTLEMENT mismatch");
        require(fs.EXECUTOR() == address(Settlement(payable(settlement)).EXECUTOR()), "EXECUTOR mismatch");
        require(fs.BALANCER_VAULT() == providers.balancerVault, "BALANCER_VAULT mismatch");
        require(fs.AAVE_POOL() == providers.aavePool, "AAVE_POOL mismatch");
        require(fs.MORPHO() == providers.morpho, "MORPHO mismatch");
        for (uint256 i; i < operators.length; i++) {
            require(fs.isOperator(operators[i]), "operator not set");
        }
        require(fs.POOL_VENUES() == venues.length, "POOL_VENUES mismatch");
        for (uint256 i; i < venues.length; i++) {
            (address f, bytes32 h) = fs.poolVenue(i);
            require(f == venues[i].factory && h == venues[i].initCodeHash, "venue mismatch");
            if (block.chainid == 30) {
                address derived = fs.poolFor(i, RSK_WRBTC, RSK_USDT0, 3000);
                require(derived == IV3FactoryProbe(f).getPool(RSK_WRBTC, RSK_USDT0, 3000), "init hash does not derive");
                console.log("  venue %s probe pool", i, derived);
            }
        }
        console.log("immutables verified");
    }

    function _venues() internal view returns (V3Venue[] memory v) {
        if (vm.envOr("NO_POOL_VENUES", false)) return new V3Venue[](0);
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
        v = new V3Venue[](factories.length);
        for (uint256 i; i < factories.length; i++) {
            require(factories[i].code.length != 0, "a POOL_FACTORIES entry has no code on this chain");
            v[i] = V3Venue({factory: factories[i], initCodeHash: hashes[i]});
        }
    }

    function _requireCodeOrZero(address a, string memory name) internal view {
        require(a == address(0) || a.code.length != 0, string.concat(name, " has no code on this chain"));
    }

    function _addrList(string memory name) internal view returns (address[] memory) {
        string memory raw = vm.envOr(name, string(""));
        if (bytes(raw).length == 0) return new address[](0);
        return vm.envAddress(name, ",");
    }
}
