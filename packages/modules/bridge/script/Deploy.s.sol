// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {PositionFunnelFactory} from "../src/funnel/PositionFunnelFactory.sol";
import {FunnelGrantModule} from "../src/funnel/FunnelGrantModule.sol";
import {AcrossBridgeOutModule} from "../src/out/AcrossBridgeOutModule.sol";
import {LzOftBridgeOutModule} from "../src/out/LzOftBridgeOutModule.sol";
import {BridgedOrderInbox} from "../src/BridgedOrderInbox.sol";

/// @title DeployScript
/// @notice Deploys the cross-chain package. Every contract goes out through
///         CREATE2 with a fixed salt, so an identical run on another chain lands
///         on identical addresses.
///
///  Why the factory address is load-bearing
///  ───────────────────────────────────────
///  Funds are bridged to funnel addresses that may not be deployed yet. A funnel
///  address is derived from the factory address and the factory's init code, so if
///  the factory ever lands somewhere else on a chain, every funnel address the
///  source chain predicted for it is wrong — and tokens already sent there are
///  unreachable. That makes this script's determinism a fund-safety property, not
///  a convenience:
///
///    • the factory's constructor args (`permit3`, `settlement`, `lens`) are part
///      of its init code, so those THREE must already be at identical addresses on
///      every chain or the factory address diverges silently;
///    • the salt below must never change;
///    • the factory is not upgradeable and has no owner, so there is nothing to
///      migrate later even if we wanted to.
///
///  After each run, record the printed factory address, implementation address and
///  sample init-code hash into the deployment registry, and refuse to enable a
///  chain as a bridging destination until its factory matches the others.
///
///  Usage:
///    forge script packages/modules/bridge/script/Deploy.s.sol \
///      --rpc-url $RPC --broadcast --verify
///
///  Required env: PERMIT3, SETTLEMENT, LENS.
///  Optional env: ACROSS_SPOKE_POOL, LZ_ENDPOINT (zero disables that path),
///                INBOX_OWNER (omit to skip the shared inbox entirely).
contract DeployScript is Script {
    /// @dev Never change this. It is an input to every funnel address ever
    ///      predicted for this deployment.
    bytes32 constant SALT = keccak256("1delta.bridge.v1");

    function run() public {
        address permit3 = vm.envAddress("PERMIT3");
        address settlement = vm.envAddress("SETTLEMENT");
        address lens = vm.envAddress("LENS");
        address spokePool = vm.envOr("ACROSS_SPOKE_POOL", address(0));
        address lzEndpoint = vm.envOr("LZ_ENDPOINT", address(0));
        address inboxOwner = vm.envOr("INBOX_OWNER", address(0));

        vm.startBroadcast();

        // The funnel path. Deployed first because it is the one whose address
        // other chains depend on.
        // Pinned as an immutable inside every funnel, so it must be deployed
        // before the factory and must never change: a different grant module means
        // a different implementation, a different init code, and therefore a
        // different funnel address on this chain than on every other.
        FunnelGrantModule grantModule = new FunnelGrantModule{salt: SALT}(settlement);
        console.log("FunnelGrantModule    ", address(grantModule));

        PositionFunnelFactory factory =
            new PositionFunnelFactory{salt: SALT}(permit3, settlement, lens, address(grantModule));
        console.log("PositionFunnelFactory", address(factory));
        console.log("  implementation     ", factory.IMPLEMENTATION());
        console.logBytes32(factory.initCodeHashFor(address(0xdead))); // sample; owner-dependent by design

        if (spokePool != address(0)) {
            AcrossBridgeOutModule acrossOut = new AcrossBridgeOutModule{salt: SALT}(permit3, settlement, spokePool);
            console.log("AcrossBridgeOutModule", address(acrossOut));
        }

        // One module serves Stargate and every plain OFT; the pool or token is
        // named per-order in the signed spec, not baked in here.
        LzOftBridgeOutModule lzOut = new LzOftBridgeOutModule{salt: SALT}(permit3, settlement);
        console.log("LzOftBridgeOutModule ", address(lzOut));

        // The shared, commitment-authorised inbox is OPTIONAL: it only buys
        // bridging to a third party who signs nothing, and it is swap-only. A
        // deployment that always uses funnels does not need it.
        if (inboxOwner != address(0)) {
            BridgedOrderInbox inbox =
                new BridgedOrderInbox{salt: SALT}(permit3, settlement, spokePool, lzEndpoint, inboxOwner);
            console.log("BridgedOrderInbox    ", address(inbox));
        }

        vm.stopBroadcast();
    }
}
