// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";

import {LiquityV2RepayModule, LiquityV2TakerModule} from "../../src/LiquityV2Modules.sol";
import {FelixRepayModule, FelixTakerModule} from "../../src/FelixModules.sol";
import {ICollateralRegistry, ILiquityV2TroveManager, LatestTroveData} from "../../src/interfaces/ILiquityV2.sol";

interface IFelixBOManagers {
    function setAddManager(uint256 _troveId, address _manager) external;
    function setRemoveManagerWithReceiver(uint256 _troveId, address _manager, address _receiver) external;
}

/// @title 2026-09-30 audit, G-VENUE_B-2 — Felix (HyperEVM) smoke test against the LIVE venue.
/// @notice Felix renamed the BOLD surface (`feUSDToken()`, `repayfeUSD`,
///         `withdrawfeUSD`), so every canonical repay/borrow leg reverted there. The
///         Felix modules override only those seams; this drives them against the
///         deployed WHYPE branch with a real, pre-existing trove whose owner (an EOA)
///         re-points its managers at our modules. Forks HyperEVM (chain 999) at a
///         pinned block; override the endpoint with `HYPEREVM_RPC_URL`.
contract FelixForkTest is Test {
    address constant REGISTRY = 0x9De1e57049c475736289Cb006212F3E1DCe4711B;
    address constant TROVE_MANAGER = 0x3100F4e7BDA2ED2452d9A57EB30260ab071BBe62;
    address constant BORROWER_OPS = 0x5B271DC20bA7Beb8EEE276EB4F1644B6A217f0A3;
    address constant FEUSD = 0x02c6a2fA58cC01A18B8D9E00eA48d65E4dF26c70;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    /// @dev A live WHYPE-branch trove (~117.6k feUSD debt) owned by an EOA at the pin.
    uint256 constant TROVE_ID = 115780174399283960948327121362969236590892368408200139583297895432249963078332;
    address constant OWNER = 0xff7240b53F929048D8B5796f9aEF6B233F440084;
    uint256 constant BRANCH = 0;
    uint256 constant FORK_BLOCK = 47_403_643;

    Permit3 permit3;
    address settlement = makeAddr("settlement");
    address receiver = makeAddr("receiver");
    FelixRepayModule fRepay;
    FelixTakerModule fTaker;

    function setUp() public {
        string memory rpc = "https://rpc.hyperliquid.xyz/evm";
        try vm.envString("HYPEREVM_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0) rpc = v;
        } catch {}
        vm.createSelectFork(rpc, FORK_BLOCK);

        permit3 = new Permit3();
        fRepay = new FelixRepayModule(address(permit3), settlement, REGISTRY);
        fTaker = new FelixTakerModule(address(permit3), REGISTRY);
    }

    function _debt() internal view returns (uint256) {
        LatestTroveData memory d = ILiquityV2TroveManager(TROVE_MANAGER).getLatestTroveData(TROVE_ID);
        return d.entireDebt;
    }

    /// The venue facts the Felix modules rest on.
    function test_audit_G_VENUE_B_2_felixPremise_renamedSurface() public {
        (bool ok,) = REGISTRY.staticcall(abi.encodeWithSignature("boldToken()"));
        assertFalse(ok, "Felix registry has no boldToken()");
        assertEq(ICollateralRegistry(REGISTRY).getToken(BRANCH), WHYPE, "branch 0 collateral");
        assertEq(ICollateralRegistry(REGISTRY).getTroveManager(BRANCH), TROVE_MANAGER, "branch 0 TM");

        // The canonical repay module can never serve Felix.
        LiquityV2RepayModule canonical = new LiquityV2RepayModule(address(permit3), settlement, REGISTRY);
        vm.prank(settlement);
        vm.expectRevert();
        canonical.makeOnBehalf(OWNER, 1e18, abi.encode(BRANCH, TROVE_ID, FEUSD));
    }

    function test_audit_G_VENUE_B_2_felixRepay_burnsFeUSD() public {
        uint256 amount = 100e18;
        deal(FEUSD, OWNER, amount);
        vm.startPrank(OWNER);
        IFelixBOManagers(BORROWER_OPS).setAddManager(TROVE_ID, address(fRepay));
        IERC20(FEUSD).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(fRepay), FEUSD, uint160(amount), 0);
        vm.stopPrank();

        uint256 debtBefore = _debt();
        vm.prank(settlement);
        fRepay.makeOnBehalf(OWNER, amount, abi.encode(BRANCH, TROVE_ID, FEUSD));

        assertEq(debtBefore - _debt(), amount, "repayfeUSD retired exactly the slice");
        assertEq(IERC20(FEUSD).balanceOf(OWNER), 0, "pulled from the owner");
        assertEq(IERC20(FEUSD).balanceOf(address(fRepay)), 0, "module holds nothing");
    }

    function test_audit_G_VENUE_B_2_felixBorrow_mintsFeUSD_andWithdrawColl() public {
        vm.prank(OWNER);
        IFelixBOManagers(BORROWER_OPS).setRemoveManagerWithReceiver(TROVE_ID, address(fTaker), address(fTaker));

        // op 0: withdrawfeUSD
        uint256 borrow = 50e18;
        bytes memory bData = abi.encode(uint8(0), BRANCH, TROVE_ID, FEUSD, type(uint256).max, borrow);
        vm.prank(OWNER);
        permit3.approveTaker(settlement, address(fTaker), keccak256(bData), uint160(borrow), 0);
        uint256 debtBefore = _debt();
        vm.prank(settlement);
        permit3.take(address(fTaker), OWNER, uint160(borrow), receiver, bData);
        assertEq(IERC20(FEUSD).balanceOf(receiver), borrow, "withdrawfeUSD proceeds forwarded");
        assertGe(_debt() - debtBefore, borrow, "debt drawn (plus the upfront fee)");

        // op 1: withdrawColl, pinned to the registry's WHYPE
        uint256 coll = 1e18;
        bytes memory wData = abi.encode(uint8(1), BRANCH, TROVE_ID, WHYPE);
        vm.prank(OWNER);
        permit3.approveTaker(settlement, address(fTaker), keccak256(wData), uint160(coll), 0);
        vm.prank(settlement);
        permit3.take(address(fTaker), OWNER, uint160(coll), receiver, wData);
        assertEq(IERC20(WHYPE).balanceOf(receiver), coll, "collateral forwarded");
        assertEq(IERC20(FEUSD).balanceOf(address(fTaker)), 0, "module holds nothing");
    }
}
