// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {GearboxPoolWithdrawModule} from "../../src/GearboxV3Modules.sol";
import {IGearboxPoolV3} from "../../src/interfaces/IGearboxV3.sol";

/// @dev The PoolV3 behind the pinned credit manager. Declared here rather than in
///      the module's interface because the modules never need it — the test does,
///      to DERIVE the pool address instead of hardcoding a guess.
interface ICreditManagerPool {
    function pool() external view returns (address);
}

/// @dev POSITION-SIZED READS ON A REAL GEARBOX PoolV3 — closing the last coverage
/// gap from the 2026-09-10 audit.
///
/// The package's fork infrastructure covers CREDIT ACCOUNTS only, so the first pass
/// at this was a mock unit test. This is the fork half: the PoolV3 address is READ
/// FROM the credit manager the package already pins (`CreditManagerV3.pool()`),
/// which makes it authoritative for the pinned block rather than a guessed constant.
///
/// Two findings live here:
///   • FINDING 1  — the reader returned `maxWithdraw`, a reachability figure.
///   • FINDING 12 — the `Full` branch measured and paid a `data`-supplied `asset`
///     while `pool.withdraw` pays `pool.asset()`; Gearbox was the one sweep site of
///     eleven where those two had independent sources.
///
/// The mock suite (`test/unit/GearboxPoolPositionSized.t.sol`) stays: it can FORCE
/// a clipped `maxWithdraw` and a disagreeing asset word, which a live, liquid pool
/// will not reliably produce. This one proves the reader against the real contract.
contract GearboxPoolPositionSizedTest is Test {
    address internal constant CREDIT_MANAGER = 0x9fB5493dEb601A0329ad8bFF43cD182a61321ca7;
    uint256 internal constant FORK_BLOCK = 25_600_000;

    Permit3 internal permit3;
    GearboxPoolWithdrawModule internal module;

    address internal POOL;
    address internal ASSET;

    address internal maker;
    address internal settlement = address(0x5E77);
    address internal receiver = address(0xBEEF);

    uint256 internal constant DEPOSIT = 10 ether;

    function _forkMainnet() internal {
        try vm.envString("ETH_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        // Same ladder the credit-flow fork suite uses — these serve historical state.
        string[3] memory rpcs = [
            "https://gateway.tenderly.co/public/mainnet", "https://eth.drpc.org", "https://ethereum-rpc.publicnode.com"
        ];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryFork(rpcs[i])) return;
        }
        revert("GearboxPoolPositionSized: no archive-capable mainnet RPC (set ETH_RPC_URL)");
    }

    function _tryFork(string memory rpc) internal returns (bool) {
        try this.__fork(rpc) {
            return true;
        } catch {
            return false;
        }
    }

    function __fork(string calldata rpc) external {
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    function setUp() public {
        _forkMainnet();

        // Derived, not guessed: the pool the pinned credit manager actually uses.
        POOL = ICreditManagerPool(CREDIT_MANAGER).pool();
        ASSET = IGearboxPoolV3(POOL).asset();

        maker = makeAddr("gearbox-pool-maker");
        permit3 = new Permit3();
        module = new GearboxPoolWithdrawModule(address(permit3));

        vm.label(POOL, "PoolV3");
        vm.label(ASSET, "poolAsset");

        // Supply into the pool as the maker, then grant the module the ERC-4626
        // share allowance its withdraw needs.
        deal(ASSET, maker, DEPOSIT);
        vm.startPrank(maker);
        IERC20(ASSET).approve(POOL, DEPOSIT);
        IGearboxPoolV3(POOL).deposit(DEPOSIT, maker);
        IERC20(POOL).approve(address(module), type(uint256).max);
        vm.stopPrank();
    }

    function _data(address assetWord) internal view returns (bytes memory) {
        return abi.encode(POOL, assetWord);
    }

    function _rawPosition(address who) internal view returns (uint256) {
        return IGearboxPoolV3(POOL).previewRedeem(IGearboxPoolV3(POOL).balanceOf(who));
    }

    // ──────────────────── Finding 1 ────────────────────

    /// @dev The reader must be the raw share conversion. Asserted unconditionally
    /// because that is the interface contract; the divergence from `maxWithdraw` is
    /// forced and asserted in the mock suite, which a liquid live pool cannot do.
    function test_positionOf_isTheRawShareConversion() public view {
        (address asset, uint256 reported) = module.positionOf(maker, _data(ASSET));

        assertEq(asset, ASSET, "asset read from the pool");
        assertEq(reported, _rawPosition(maker), "positionOf is previewRedeem(balanceOf), the RAW position");
        assertApproxEqAbs(reported, DEPOSIT, 2, "and it is the deposit");
    }

    /// @dev Where the live pool's own reachability figure differs, the reader must
    /// follow the raw one. Logs rather than asserts when the pool is liquid enough
    /// that the two coincide — the point is which number is reported, not that the
    /// fork state happens to diverge.
    function test_positionOf_followsRawEvenWhenMaxWithdrawIsLower() public {
        uint256 raw = _rawPosition(maker);
        uint256 reachable = IGearboxPoolV3(POOL).maxWithdraw(maker);
        (, uint256 reported) = module.positionOf(maker, _data(ASSET));

        assertEq(reported, raw, "reader is raw");
        if (reachable < raw) {
            assertGt(reported, reachable, "and strictly above the reachability figure");
        } else {
            emit log_string("note: pool is liquid at this block, maxWithdraw == raw; contract still pinned");
        }
    }

    // ──────────────────── Finding 12 ────────────────────

    /// @dev The asset must come from the POOL, never from the maker-signed `data`
    /// word — the `Full` branch measures and pays in whatever this returns.
    function test_positionOf_asset_comesFromThePool_notFromData() public view {
        (address honest,) = module.positionOf(maker, _data(ASSET));
        (address disagreeing,) = module.positionOf(maker, _data(address(0xD15A6)));

        assertEq(honest, ASSET, "honest word: pool asset");
        assertEq(disagreeing, ASSET, "DISAGREEING word: still the pool asset");
    }

    // ──────────────────── End to end ────────────────────

    /// @dev A `Full` withdraw against the real pool: the whole position leaves, the
    /// module keeps nothing, and the receiver is paid in the POOL's asset.
    function test_fullMode_withdrawsWholePosition() public {
        uint256 raw = _rawPosition(maker);
        bytes memory data =
            abi.encode(POOL, ASSET, DustHandler.encodeMode(DustHandler.BalanceMode.Full), raw);

        vm.prank(maker);
        permit3.approveTaker(settlement, address(module), keccak256(data), type(uint160).max, 0);

        uint256 receiverBefore = IERC20(ASSET).balanceOf(receiver);
        vm.prank(settlement);
        permit3.take(address(module), maker, uint160(raw), receiver, data);

        assertApproxEqAbs(IERC20(ASSET).balanceOf(receiver) - receiverBefore, raw, 2, "receiver paid the position");
        assertLe(_rawPosition(maker), 2, "position fully exited");
        assertEq(IERC20(ASSET).balanceOf(address(module)), 0, "module holds no asset");
        assertEq(IERC20(POOL).balanceOf(address(module)), 0, "module holds no shares");
    }

    /// @dev FINDING 2 REGRESSION: a `Full` leg short of the signed amount must
    /// REVERT rather than deliver less and let the core bill the maker's wallet.
    function test_fullMode_shortPosition_reverts() public {
        uint256 signed = DEPOSIT * 3; // far above the position
        bytes memory data =
            abi.encode(POOL, ASSET, DustHandler.encodeMode(DustHandler.BalanceMode.Full), signed);

        vm.prank(maker);
        permit3.approveTaker(settlement, address(module), keccak256(data), type(uint160).max, 0);

        vm.prank(settlement);
        vm.expectRevert(); // ShortWithdraw, or the pool on insufficient shares
        permit3.take(address(module), maker, uint160(signed), receiver, data);
    }
}
