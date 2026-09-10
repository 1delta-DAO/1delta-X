// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {GearboxPoolWithdrawModule} from "../../src/GearboxV3Modules.sol";

/// @dev POSITION-SIZED READS ON GEARBOX POOLV3 — the fourth venue the 2026-09-10
/// audit found had no `positionOf` coverage. Two findings lived here:
///
///   • FINDING 1  — the reader returned `maxWithdraw`, a reachability figure.
///   • FINDING 12 — the `Full` branch measured its floor, its `received` delta and
///     BOTH payouts against an `asset` decoded from `data`, while `pool.withdraw`
///     pays out `pool.asset()`. Gearbox was the ONE of eleven sweep sites where the
///     measured token and the paid token had independent sources; the siblings all
///     re-derive from the venue.
///
/// ⚠ A UNIT TEST ON PURPOSE, unlike its three siblings. The package has fork
/// infrastructure for CREDIT ACCOUNTS only — there is no PoolV3 fork harness, and
/// inventing a pool address would pin the suite to a guess. A mock is also the
/// stronger instrument for these two findings specifically: it lets the divergences
/// be FORCED (`maxWithdraw` strictly below the raw position; `data.asset` different
/// from `pool.asset()`), which is exactly what a live pool would not reliably
/// produce. A PoolV3 fork harness is still missing and is tracked as such.
contract MockPoolV3 {
    address public asset;
    mapping(address => uint256) public balanceOf;

    uint256 public rateNum = 1;
    uint256 public rateDen = 1;
    /// @dev Reachability clamp, independent of the share ledger — the thing
    ///      `maxWithdraw` folds in and `positionOf` must ignore.
    uint256 public liquidityCap = type(uint256).max;

    constructor(address _asset) {
        asset = _asset;
    }

    function setShares(address who, uint256 shares) external {
        balanceOf[who] = shares;
    }

    function setRate(uint256 num, uint256 den) external {
        (rateNum, rateDen) = (num, den);
    }

    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return shares * rateNum / rateDen;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        uint256 raw = previewRedeem(balanceOf[owner]);
        return raw < liquidityCap ? raw : liquidityCap;
    }
}

contract GearboxPoolPositionSizedTest is Test {
    GearboxPoolWithdrawModule internal module;
    MockPoolV3 internal pool;

    address internal constant POOL_ASSET = address(0xA55E7);
    address internal constant OTHER_ASSET = address(0x0DDBA11);
    address internal maker;

    function setUp() public {
        maker = makeAddr("gearbox-maker");
        module = new GearboxPoolWithdrawModule(address(0xFE3417));
        pool = new MockPoolV3(POOL_ASSET);
    }

    function _data(address assetWord) internal view returns (bytes memory) {
        return abi.encode(address(pool), assetWord);
    }

    /// @dev FINDING 1 REGRESSION. The share ledger says 100; the pool will only let
    /// 40 out right now. `positionOf` must report 100 — `IPositionSource` requires
    /// the raw position so an unreachable withdraw REVERTS loudly rather than
    /// silently resolving small and consuming the maker's one-shot exit order.
    function test_positionOf_isRawPosition_notMaxWithdraw() public {
        pool.setShares(maker, 100e18);
        pool.setRate(11, 10); //          shares have appreciated 10%
        pool.setLiquidityCap(40e18); //   but only 40 is reachable right now

        uint256 raw = pool.previewRedeem(pool.balanceOf(maker));
        assertEq(raw, 110e18, "raw position includes the appreciation");
        assertEq(pool.maxWithdraw(maker), 40e18, "maxWithdraw IS clipped: the finding premise");

        (address asset, uint256 reported) = module.positionOf(maker, _data(POOL_ASSET));
        assertEq(reported, raw, "positionOf reports the RAW position");
        assertGt(reported, pool.maxWithdraw(maker), "and therefore NOT maxWithdraw");
        assertEq(asset, POOL_ASSET, "asset read from the pool");
    }

    /// @dev FINDING 12 REGRESSION. The asset must come from the POOL, never from the
    /// maker-signed `data` word — the `Full` branch measures and pays in whatever
    /// this returns, so a `data` word that disagreed used to make `received` measure
    /// an untouched token, deliver 0, and strand the whole withdrawn position on a
    /// shared singleton.
    function test_positionOf_asset_comesFromThePool_notFromData() public {
        pool.setShares(maker, 50e18);

        (address fromPoolWord,) = module.positionOf(maker, _data(POOL_ASSET));
        (address fromOtherWord,) = module.positionOf(maker, _data(OTHER_ASSET));

        assertEq(fromPoolWord, POOL_ASSET, "honest data word: pool asset");
        assertEq(fromOtherWord, POOL_ASSET, "DISAGREEING data word: still the pool asset");
        assertTrue(fromOtherWord != OTHER_ASSET, "the data word is never echoed back");
    }

    /// @dev An empty position resolves to zero, which the core rejects `ZeroFill` —
    /// an exit order with nothing to exit fails closed rather than filling for 0.
    function test_positionOf_emptyPosition_isZero() public view {
        (, uint256 reported) = module.positionOf(maker, _data(POOL_ASSET));
        assertEq(reported, 0, "no shares, no position");
    }
}
