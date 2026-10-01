// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";

import {LiquityV2RepayModule} from "../../src/LiquityV2Modules.sol";
import {LiquityV2PreFundModule} from "../../src/LiquityV2PreFundModules.sol";
import {FelixRepayModule, FelixTakerModule, FelixPreFundModule} from "../../src/FelixModules.sol";
import {LqtyToken, LqtyTroveNFT, LqtyTroveManager} from "./LiquityV2TroveAuth.t.sol";

/// @dev Felix-shaped venue: the registry's debt getter is `feUSDToken()` (no
///      `boldToken()`), BorrowerOperations exposes `repayfeUSD` / `withdrawfeUSD`
///      and NOT the BOLD-named selectors.
contract FelixRegistryMock {
    mapping(uint256 => address) internal _tm;
    mapping(uint256 => address) internal _coll;
    address public feUSDToken;

    function set(uint256 i, address t, address c) external {
        _tm[i] = t;
        _coll[i] = c;
    }

    function setFeUSD(address f) external {
        feUSDToken = f;
    }

    function getTroveManager(uint256 i) external view returns (address) {
        return _tm[i];
    }

    function getToken(uint256 i) external view returns (address) {
        return _coll[i];
    }
}

contract FelixBOMock {
    address public tmAddr;
    LqtyToken public feUSD;
    mapping(uint256 => address) public receiverOf;

    constructor(address t, address f) {
        tmAddr = t;
        feUSD = LqtyToken(f);
    }

    function setRemoveManagerWithReceiver(uint256 id, address, address r) external {
        receiverOf[id] = r;
    }

    function repayfeUSD(uint256 id, uint256 a) external {
        feUSD.burn(msg.sender, a);
        LqtyTroveManager(tmAddr).setDebt(id, LqtyTroveManager(tmAddr).debt(id) - a);
    }

    function withdrawfeUSD(uint256 id, uint256 a, uint256) external {
        LqtyTroveManager(tmAddr).setDebt(id, LqtyTroveManager(tmAddr).debt(id) + a);
        feUSD.mint(receiverOf[id], a);
    }
}

/// @title 2026-09-30 audit, G-VENUE_B-2 — the Felix modules drive the renamed entrypoints.
/// @notice Unit half; the live-venue half is `test/fork/FelixFork.t.sol`.
contract AuditFelixModulesTest is Test {
    Permit3 permit3;
    LqtyToken collateral;
    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    address receiver = address(0xFEE);
    uint256 constant BRANCH = 0;
    uint256 constant TROVE = 1111;

    function setUp() public {
        permit3 = new Permit3();
        collateral = new LqtyToken();
    }

    function _desc(address token, LiquityV2PreFundModule.Op op) internal pure returns (uint256) {
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | (uint256(op) << 244);
    }

    // ──────────────── G-VENUE_B-2: Felix seam ────────────────

    function test_audit_G_VENUE_B_2_felix_repayBorrowPreFund_driveRenamedEntrypoints() public {
        LqtyToken feUSD = new LqtyToken();
        LqtyTroveNFT fNft = new LqtyTroveNFT();
        LqtyTroveManager fTm = new LqtyTroveManager(address(fNft));
        FelixBOMock fBo = new FelixBOMock(address(fTm), address(feUSD));
        fTm.setBorrowerOperations(address(fBo));
        FelixRegistryMock fReg = new FelixRegistryMock();
        fReg.set(BRANCH, address(fTm), address(collateral));
        fReg.setFeUSD(address(feUSD));
        fNft.mint(TROVE, maker);
        fTm.setDebt(TROVE, 4_000e18);

        FelixRepayModule fRepay = new FelixRepayModule(address(permit3), settlement, address(fReg));
        FelixTakerModule fTaker = new FelixTakerModule(address(permit3), address(fReg));
        FelixPreFundModule fPre = new FelixPreFundModule(address(permit3), settlement, address(fReg));

        // repay (pull)
        feUSD.mint(maker, 500e18);
        vm.startPrank(maker);
        feUSD.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(fRepay), address(feUSD), uint160(500e18), 0);
        vm.stopPrank();
        vm.prank(settlement);
        fRepay.makeOnBehalf(maker, 500e18, abi.encode(BRANCH, TROVE, address(feUSD)));
        assertEq(fTm.debt(TROVE), 3_500e18, "repayfeUSD burned the slice");

        // borrow (take)
        fBo.setRemoveManagerWithReceiver(TROVE, address(fTaker), address(fTaker));
        bytes memory bData = abi.encode(uint8(0), BRANCH, TROVE, address(feUSD), uint256(0), uint256(300e18));
        vm.prank(maker);
        permit3.approveTaker(settlement, address(fTaker), keccak256(bData), uint160(300e18), 0);
        vm.prank(settlement);
        permit3.take(address(fTaker), maker, uint160(300e18), receiver, bData);
        assertEq(feUSD.balanceOf(receiver), 300e18, "withdrawfeUSD minted to the module and forwarded");
        assertEq(fTm.debt(TROVE), 3_800e18, "debt drawn");

        // repay (pre-fund)
        feUSD.mint(address(fPre), 200e18);
        vm.prank(settlement);
        fPre.makeOnBehalf(
            maker,
            200e18,
            abi.encode(_desc(address(feUSD), LiquityV2PreFundModule.Op.Repay), BRANCH, TROVE, address(feUSD))
        );
        assertEq(fTm.debt(TROVE), 3_600e18, "pre-fund repayfeUSD");

        // The canonical modules cannot serve Felix: the registry has no boldToken().
        LiquityV2RepayModule canonical = new LiquityV2RepayModule(address(permit3), settlement, address(fReg));
        vm.prank(settlement);
        vm.expectRevert();
        canonical.makeOnBehalf(maker, 1, abi.encode(BRANCH, TROVE, address(feUSD)));
    }
}
