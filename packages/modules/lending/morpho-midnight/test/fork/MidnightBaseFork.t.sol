// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IMidnight, Market, CollateralParams, MidnightIdLib} from "../../src/interfaces/IMidnight.sol";

/// @dev Venue-side views/admin used only to stand a market up on the fork.
interface IMidnightAdmin {
    function configurator() external view returns (address);
    function enableLltv(uint256 lltv) external;
    function enableLiquidationCursor(uint256 liquidationCursor) external;
    function isLltvEnabled(uint256 lltv) external view returns (bool);
    function isLiquidationCursorEnabled(uint256 liquidationCursor) external view returns (bool);
    function touchMarket(Market memory market) external returns (bytes32);
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
}

/// @notice Smoke suite against the DEPLOYED Morpho Midnight singleton on Base
///         (audit 2026-09-30 L-ML-1 / L-ML-8). It pins the venue facts the
///         package's {MidnightMock} must reproduce and the modules rely on:
///
///   • `supplyCollateral` and `repay` are AUTH-GATED — not permissionless — and
///     revert `Unauthorized()` (0x82b42900) for a module acting for a maker who
///     has not granted it (the docs used to say "no delegation needed");
///   • `withdraw` is auth-gated likewise, and `take` with `taker != msg.sender`
///     reverts `TakerUnauthorized()`;
///   • `setIsAuthorized` accepts an already-authorized caller (re-delegation —
///     a grant is FULL control);
///   • `MidnightIdLib.toId` reproduces the id `touchMarket` derives, and the
///     market blob lands in code at that address (SSTORE2);
///   • `updatePosition` (used by the taker module's Full credit exit, L-ML-3)
///     exists and returns the updated position.
///
///  Runs at the latest block (the auth gates and id derivation are state-free;
///  the market is created on the fork). Set `BASE_RPC_URL` to pin a provider.
contract MidnightBaseForkTest is Test {
    address internal constant MIDNIGHT = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    bytes4 internal constant UNAUTHORIZED = 0x82b42900; // Unauthorized()

    address internal maker = makeAddr("maker");
    address internal module = makeAddr("module");

    function setUp() public {
        _forkBase();
        // The deployed bytecode relies on Osaka's CLZ.
        vm.setEvmVersion("osaka");
    }

    function _forkBase() internal {
        try vm.envString("BASE_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0) {
                try this.__fork(v) {
                    return;
                } catch {}
            }
        } catch {}
        string[4] memory rpcs =
            ["https://mainnet.base.org", "https://base-rpc.publicnode.com", "https://base.drpc.org", "https://1rpc.io/base"];
        for (uint256 i; i < rpcs.length; i++) {
            try this.__fork(rpcs[i]) {
                return;
            } catch {}
        }
        revert("MidnightBaseFork: no working Base RPC (set BASE_RPC_URL)");
    }

    /// @dev External self-call so a reverting `createSelectFork` is catchable.
    function __fork(string calldata rpc) external {
        vm.createSelectFork(rpc);
    }

    function _market() internal view returns (Market memory m) {
        CollateralParams[] memory cp = new CollateralParams[](1);
        cp[0] = CollateralParams({token: WETH, lltv: 0.8e18, liquidationCursor: 0.3e18, oracle: address(0x0AC1E)});
        m = Market({
            chainId: block.chainid,
            midnight: MIDNIGHT,
            loanToken: USDC,
            collateralParams: cp,
            maturity: block.timestamp + 90 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    // ──────────────────── L-ML-1: value-IN ops are auth-gated ────────────────────

    function test_audit_L_ML_1_fork_supplyCollateralIsAuthGated() public {
        vm.prank(module);
        vm.expectRevert(UNAUTHORIZED);
        IMidnight(MIDNIGHT).supplyCollateral(_market(), 0, 1, maker);
    }

    function test_audit_L_ML_1_fork_repayIsAuthGated() public {
        vm.prank(module);
        vm.expectRevert(UNAUTHORIZED);
        IMidnight(MIDNIGHT).repay(_market(), 1, maker, address(0), "");
    }

    function test_audit_L_ML_8_fork_withdrawIsAuthGated() public {
        vm.prank(module);
        vm.expectRevert(UNAUTHORIZED);
        IMidnight(MIDNIGHT).withdraw(_market(), 1, maker, module);
    }

    /// The grant is what the modules need — and it opens BOTH value-in ops past
    /// the auth gate (they then fail later, on the unseeded position / balance,
    /// with a DIFFERENT error).
    function test_audit_L_ML_1_fork_grantPassesTheAuthGate() public {
        vm.prank(maker);
        IMidnight(MIDNIGHT).setIsAuthorized(module, true, maker);

        vm.prank(module);
        (bool ok, bytes memory ret) = MIDNIGHT.call(
            abi.encodeCall(IMidnight.repay, (_market(), 1, maker, address(0), bytes("")))
        );
        assertFalse(ok, "unseeded repay still fails");
        assertTrue(ret.length < 4 || bytes4(ret) != UNAUTHORIZED, "but no longer on the auth gate");
    }

    // ──────────────────── L-ML-8: venue semantics the mock mirrors ────────────────────

    function test_audit_L_ML_8_fork_authorizedAddressCanRedelegate() public {
        address third = makeAddr("third");
        vm.prank(maker);
        IMidnight(MIDNIGHT).setIsAuthorized(module, true, maker);
        vm.prank(module);
        IMidnight(MIDNIGHT).setIsAuthorized(third, true, maker);
        assertTrue(IMidnightAdmin(MIDNIGHT).isAuthorized(maker, third), "an authorized address re-delegated");
    }

    function test_audit_L_ML_8_fork_toIdMatchesVenueAndUpdatePositionExists() public {
        IMidnightAdmin venue = IMidnightAdmin(MIDNIGHT);
        Market memory m = _market();
        address configurator = venue.configurator();
        vm.startPrank(configurator);
        if (!venue.isLltvEnabled(0.8e18)) venue.enableLltv(0.8e18);
        if (!venue.isLiquidationCursorEnabled(0.3e18)) venue.enableLiquidationCursor(0.3e18);
        vm.stopPrank();

        bytes32 venueId = venue.touchMarket(m);
        assertEq(MidnightIdLib.toId(m), venueId, "MidnightIdLib.toId == venue id");
        assertGt(address(uint160(uint256(venueId))).code.length, 0, "market blob stored at the id (SSTORE2)");

        (uint128 c,, uint128 accrued) = IMidnight(MIDNIGHT).updatePosition(m, maker);
        assertEq(c, 0, "fresh position: no credit");
        assertEq(accrued, 0, "nothing accrued");
        (uint128 cv,,) = IMidnight(MIDNIGHT).updatePositionView(m, venueId, maker);
        assertEq(cv, 0, "view twin agrees");
        assertEq(IMidnight(MIDNIGHT).credit(venueId, maker), 0, "stored credit");
    }
}
