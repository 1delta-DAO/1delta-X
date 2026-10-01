// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";

import {GearboxPoolDepositModule, GearboxPoolWithdrawModule} from "../../src/GearboxV3Modules.sol";
import {GearboxPoolPreFundDepositModule} from "../../src/GearboxV3PreFundModules.sol";
import {IGearboxPoolV3} from "../../src/interfaces/IGearboxV3.sol";

interface ICreditManagerPoolAudit {
    function pool() external view returns (address);
}

/// @title 2026-09-30 audit, L-LRG-5 (2)-(4) — Gearbox PoolV3 legs against the LIVE pool.
/// @notice `GearboxPoolDepositModule` was never instantiated by any test, the `Exact`
///         branch of `GearboxPoolWithdrawModule` had no positive test, and
///         `GearboxPoolPreFundDepositModule` ran only against a mock. Same pinned
///         block and pool derivation as `PoolPositionSized.t.sol`.
contract GearboxAuditPoolLegsForkTest is Test {
    address internal constant CREDIT_MANAGER = 0x9fB5493dEb601A0329ad8bFF43cD182a61321ca7;
    uint256 internal constant FORK_BLOCK = 25_600_000;

    Permit3 internal permit3;
    GearboxPoolDepositModule internal depositModule;
    GearboxPoolWithdrawModule internal withdrawModule;
    GearboxPoolPreFundDepositModule internal preFund;

    address internal POOL;
    address internal ASSET;
    address internal maker = makeAddr("gearbox-audit-maker");
    address internal settlement = address(0x5E77);
    address internal receiver = address(0xBEEF);

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
        bool ok;
        try vm.envString("ETH_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0) ok = _tryFork(v);
        } catch {}
        string[3] memory rpcs = [
            "https://gateway.tenderly.co/public/mainnet", "https://eth.drpc.org", "https://ethereum-rpc.publicnode.com"
        ];
        for (uint256 i = 0; i < rpcs.length && !ok; i++) {
            ok = _tryFork(rpcs[i]);
        }
        require(ok, "no archive-capable mainnet RPC (set ETH_RPC_URL)");

        POOL = ICreditManagerPoolAudit(CREDIT_MANAGER).pool();
        ASSET = IGearboxPoolV3(POOL).asset();
        permit3 = new Permit3();
        depositModule = new GearboxPoolDepositModule(address(permit3), settlement);
        withdrawModule = new GearboxPoolWithdrawModule(address(permit3));
        preFund = new GearboxPoolPreFundDepositModule(address(permit3), settlement);
    }

    function _position(address who) internal view returns (uint256) {
        return IGearboxPoolV3(POOL).previewRedeem(IGearboxPoolV3(POOL).balanceOf(who));
    }

    function test_audit_L_LRG_5_poolDeposit_pull_creditsMaker() public {
        uint256 amount = 5 ether;
        deal(ASSET, maker, amount);
        vm.startPrank(maker);
        IERC20(ASSET).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), ASSET, uint160(amount), 0);
        vm.stopPrank();

        vm.prank(settlement);
        depositModule.makeOnBehalf(maker, amount, abi.encode(POOL, ASSET));

        assertApproxEqAbs(_position(maker), amount, 2, "maker holds the supplied position");
        assertEq(IERC20(ASSET).balanceOf(address(depositModule)), 0, "module holds nothing");
        assertEq(IERC20(ASSET).allowance(address(depositModule), POOL), 0, "scoped approval cleared");
    }

    function test_audit_L_LRG_5_poolWithdraw_exact_partialSlice() public {
        uint256 supplied = 10 ether;
        uint256 slice = 3 ether;
        deal(ASSET, maker, supplied);
        vm.startPrank(maker);
        IERC20(ASSET).approve(POOL, supplied);
        IGearboxPoolV3(POOL).deposit(supplied, maker);
        IERC20(POOL).approve(address(withdrawModule), type(uint256).max);
        bytes memory data = abi.encode(POOL, ASSET); // no mode word = Exact
        permit3.approveTaker(settlement, address(withdrawModule), keccak256(data), uint160(slice), 0);
        vm.stopPrank();

        uint256 before = _position(maker);
        vm.prank(settlement);
        permit3.take(address(withdrawModule), maker, uint160(slice), receiver, data);

        assertEq(IERC20(ASSET).balanceOf(receiver), slice, "receiver paid exactly the slice");
        assertApproxEqAbs(before - _position(maker), slice, 2, "position reduced by the slice");
        assertEq(IERC20(POOL).balanceOf(address(withdrawModule)), 0, "module holds no shares");
    }

    function test_audit_L_LRG_5_poolPreFundDeposit_live() public {
        uint256 forAmount = 4 ether;
        deal(ASSET, address(preFund), forAmount); // the core-delivered leg
        uint256 desc = (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(ASSET)) << 16);

        vm.prank(settlement);
        preFund.makeOnBehalf(maker, forAmount, abi.encode(desc, POOL, ASSET));

        assertApproxEqAbs(_position(maker), forAmount, 2, "the delivery became the maker's position");
        assertEq(IERC20(ASSET).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(ASSET).allowance(address(preFund), POOL), 0, "scoped approval cleared");
    }
}
