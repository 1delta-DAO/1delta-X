// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {
    LiquityV2AddCollModule,
    LiquityV2RepayModule,
    LiquityV2TakerModule,
    LiquityV2TroveAuth
} from "../../src/LiquityV2Modules.sol";
import {LatestTroveData} from "../../src/interfaces/ILiquityV2.sol";

// ── Mocks: a faithful-enough Liquity V2 branch ───────────────────────────────
//
// Models the three properties the modules depend on:
//   1. the BorrowerOperations → TroveManager → TroveNFT address chain,
//   2. per-trove manager delegation that authorises the MANAGER and never a
//      beneficiary (exactly why the ownership binding has to exist),
//   3. value-out ops carrying NO receiver — proceeds land on the trove's
//      configured receiver, which the maker sets to the module.

contract LqtyToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @dev BOLD is privileged: BorrowerOperations burns it from the holder with no
    ///      ERC-20 allowance. Modelled so the repay path exercises the real shape
    ///      (module pulls BOLD to itself, BorrowerOps burns it) rather than an
    ///      approval flow the module deliberately does not perform.
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LqtyTroveNFT {
    mapping(uint256 => address) internal _owner;

    error NonexistentTrove();

    function mint(uint256 troveId, address to) external {
        _owner[troveId] = to;
    }

    /// @dev ERC-721 semantics: a non-existent token REVERTS rather than returning
    ///      `address(0)`, so a fabricated id fails closed.
    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _owner[tokenId];
        if (o == address(0)) revert NonexistentTrove();
        return o;
    }
}

contract LqtyTroveManager {
    address public troveNFT;
    /// @dev Real mainnet TroveManager exposes this; BorrowerOperations does NOT
    ///      expose `troveManager()`, which is why the chain is rooted here.
    address public borrowerOperations;
    mapping(uint256 => uint256) public debt;
    mapping(uint256 => uint256) public coll;

    constructor(address _nft) {
        troveNFT = _nft;
    }

    function setBorrowerOperations(address bo) external {
        borrowerOperations = bo;
    }

    function setDebt(uint256 troveId, uint256 d) external {
        debt[troveId] = d;
    }

    function setColl(uint256 troveId, uint256 c) external {
        coll[troveId] = c;
    }

    function getLatestTroveData(uint256 troveId) external view returns (LatestTroveData memory d) {
        d.entireDebt = debt[troveId];
        d.entireColl = coll[troveId];
    }

    function getTroveStatus(uint256) external pure returns (uint256) {
        return 1;
    }
}

contract LqtyBorrowerOperations {
    address public troveManagerAddr; // NOT a public `troveManager()` — mainnet has none
    LqtyToken public bold;
    LqtyToken public collateral;

    /// @dev troveId => manager => allowed (the `setRemoveManagerWithReceiver` grant)
    mapping(uint256 => mapping(address => bool)) public removeManager;
    mapping(uint256 => mapping(address => bool)) public addManager;
    /// @dev troveId => where value-out proceeds are forced to land
    mapping(uint256 => address) public receiverOf;

    error NotManager();

    constructor(address _tm, address _bold, address _coll) {
        troveManagerAddr = _tm;
        bold = LqtyToken(_bold);
        collateral = LqtyToken(_coll);
    }

    function setRemoveManagerWithReceiver(uint256 troveId, address manager, address receiver) external {
        removeManager[troveId][manager] = true;
        receiverOf[troveId] = receiver;
    }

    function setAddManager(uint256 troveId, address manager) external {
        addManager[troveId][manager] = true;
    }

    // ── value in ──
    function addColl(uint256 troveId, uint256 amount) external {
        if (!addManager[troveId][msg.sender]) revert NotManager();
        collateral.transferFrom(msg.sender, address(this), amount);
        LqtyTroveManager(troveManagerAddr).setColl(troveId, LqtyTroveManager(troveManagerAddr).coll(troveId) + amount);
    }

    function repayBold(uint256 troveId, uint256 amount) external {
        if (!addManager[troveId][msg.sender]) revert NotManager();
        bold.burn(msg.sender, amount); // privileged burn — no allowance, as in real Liquity
        LqtyTroveManager(troveManagerAddr).setDebt(troveId, LqtyTroveManager(troveManagerAddr).debt(troveId) - amount);
    }

    // ── value out ──
    //
    // Note what is NOT here: any notion of who the caller is acting for. Liquity
    // checks the manager grant and sends proceeds to the trove's configured
    // receiver. That is the entire authorisation.
    function withdrawBold(uint256 troveId, uint256 amount, uint256) external {
        if (!removeManager[troveId][msg.sender]) revert NotManager();
        LqtyTroveManager(troveManagerAddr).setDebt(troveId, LqtyTroveManager(troveManagerAddr).debt(troveId) + amount);
        bold.mint(receiverOf[troveId], amount);
    }

    function withdrawColl(uint256 troveId, uint256 amount) external {
        if (!removeManager[troveId][msg.sender]) revert NotManager();
        LqtyTroveManager(troveManagerAddr).setColl(troveId, LqtyTroveManager(troveManagerAddr).coll(troveId) - amount);
        collateral.transfer(receiverOf[troveId], amount);
    }

    function closeTrove(uint256) external {}
}

/// @title LiquityV2TroveAuthTest
/// @notice End-to-end scenarios for the Liquity V2 modules: a working add-coll, a
///         working borrow, and the self-signed-order drain the ownership binding
///         must prevent.
///
///         The attack runs through the REAL Permit3. Its taker book is keyed by
///         the APPROVER (`_takerAllowance[user][spender][ref]`,
///         `ref = keccak256(data)`), so an attacker can self-approve a ref computed
///         over a VICTIM's trove. Liquity cannot stop what follows — it authorises
///         the manager (the module), which every onboarded user has granted. Only
///         `LiquityV2TroveAuth.authorizeTrove` does.
contract LiquityV2TroveAuthTest is Test {
    Permit3 permit3;

    LqtyToken bold;
    LqtyToken collateral;
    LqtyTroveNFT nft;
    LqtyTroveManager tm;
    LqtyBorrowerOperations bo;

    LiquityV2AddCollModule addCollModule;
    LiquityV2RepayModule repayModule;
    LiquityV2TakerModule takerModule;

    address settlement = address(0x5E77);
    address maker = address(0xA11CE); // the victim
    address attacker = address(0xBAD);
    address receiver = address(0xFEE);

    uint256 constant MAKER_TROVE = 1111;
    uint256 constant ATTACKER_TROVE = 2222;

    uint256 constant ADD_COLL = 5e18;
    uint256 constant BORROW = 3_000e18;

    function setUp() public {
        permit3 = new Permit3();
        bold = new LqtyToken();
        collateral = new LqtyToken();
        nft = new LqtyTroveNFT();
        tm = new LqtyTroveManager(address(nft));
        bo = new LqtyBorrowerOperations(address(tm), address(bold), address(collateral));
        tm.setBorrowerOperations(address(bo));

        addCollModule = new LiquityV2AddCollModule(address(permit3), settlement);
        repayModule = new LiquityV2RepayModule(address(permit3), settlement);
        takerModule = new LiquityV2TakerModule(address(permit3));

        nft.mint(MAKER_TROVE, maker);
        nft.mint(ATTACKER_TROVE, attacker);
        tm.setColl(MAKER_TROVE, 20e18);
        tm.setColl(ATTACKER_TROVE, 20e18);
        collateral.mint(address(bo), 100e18);

        // Both users onboard exactly as the docs instruct. This is the precondition
        // for the attack, not a misconfiguration.
        bo.setAddManager(MAKER_TROVE, address(addCollModule));
        bo.setAddManager(MAKER_TROVE, address(repayModule));
        bo.setRemoveManagerWithReceiver(MAKER_TROVE, address(takerModule), address(takerModule));
        bo.setRemoveManagerWithReceiver(ATTACKER_TROVE, address(takerModule), address(takerModule));

        collateral.mint(maker, ADD_COLL);
        vm.startPrank(maker);
        collateral.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(addCollModule), address(collateral), uint160(ADD_COLL), 0);
        vm.stopPrank();
    }

    function _borrowData(uint256 troveId) internal view returns (bytes memory) {
        return abi.encode(uint8(0), address(tm), troveId, address(bold), uint256(0));
    }

    function _withdrawCollData(uint256 troveId) internal view returns (bytes memory) {
        return abi.encode(uint8(1), address(tm), troveId, address(collateral));
    }

    // ──────────────── Scenario 1: add collateral ────────────────

    function test_addColl_creditsOwnTrove() public {
        vm.prank(settlement);
        addCollModule.makeOnBehalf(maker, ADD_COLL, abi.encode(address(tm), MAKER_TROVE, address(collateral)));

        assertEq(tm.coll(MAKER_TROVE), 25e18, "collateral added to the maker's trove");
        assertEq(collateral.balanceOf(maker), 0, "pulled from the maker");
        assertEq(collateral.balanceOf(address(addCollModule)), 0, "module holds no residue");
        assertEq(collateral.allowance(address(addCollModule), address(bo)), 0, "no standing allowance");
    }

    // ──────────────── Scenario 2: borrow ────────────────

    function test_borrow_drawsDebtAndForwardsProceeds() public {
        bytes memory data = _borrowData(MAKER_TROVE);

        vm.prank(maker);
        permit3.approveTaker(settlement, keccak256(data), uint160(BORROW), 0);

        vm.prank(settlement);
        permit3.take(address(takerModule), maker, uint160(BORROW), receiver, data);

        assertEq(tm.debt(MAKER_TROVE), BORROW, "debt recorded against the maker's trove");
        assertEq(bold.balanceOf(receiver), BORROW, "proceeds forwarded to the order receiver");
        assertEq(bold.balanceOf(address(takerModule)), 0, "module holds no residue");
    }

    // ──────────────── Scenario 3: the attack, prevented ────────────────

    /// The full drain, end to end through the real Permit3. The attacker forges
    /// nothing — they approve a ref of their OWN over the maker's trove and fill
    /// their own order.
    function test_attacker_cannot_borrow_against_victim_trove() public {
        bytes memory victimData = _borrowData(MAKER_TROVE); // <- the maker's trove

        // Succeeds: the taker book is keyed by the approver, so nothing here
        // belongs to the maker.
        vm.prank(attacker);
        permit3.approveTaker(settlement, keccak256(victimData), type(uint160).max, 0);

        vm.prank(settlement);
        vm.expectRevert(LiquityV2TroveAuth.InvalidCaller.selector);
        permit3.take(address(takerModule), attacker, uint160(BORROW), attacker, victimData);

        assertEq(tm.debt(MAKER_TROVE), 0, "no debt drawn against the maker");
        assertEq(bold.balanceOf(attacker), 0, "attacker received nothing");
    }

    /// The collateral leg of the same attack — strip the victim's trove instead.
    function test_attacker_cannot_withdraw_victim_collateral() public {
        bytes memory victimData = _withdrawCollData(MAKER_TROVE);

        vm.prank(attacker);
        permit3.approveTaker(settlement, keccak256(victimData), type(uint160).max, 0);

        vm.prank(settlement);
        vm.expectRevert(LiquityV2TroveAuth.InvalidCaller.selector);
        permit3.take(address(takerModule), attacker, uint160(1e18), attacker, victimData);

        assertEq(tm.coll(MAKER_TROVE), 20e18, "maker's collateral untouched");
        assertEq(collateral.balanceOf(attacker), 0, "attacker received nothing");
    }

    /// Proof the gate the attacker cleared really was open: the identical call
    /// against their OWN trove succeeds. So the reverts above are the ownership
    /// binding doing the work, not an incidental failure earlier in the flow.
    function test_attacker_can_still_borrow_against_their_own_trove() public {
        bytes memory ownData = _borrowData(ATTACKER_TROVE);

        vm.prank(attacker);
        permit3.approveTaker(settlement, keccak256(ownData), type(uint160).max, 0);

        vm.prank(settlement);
        permit3.take(address(takerModule), attacker, uint160(BORROW), attacker, ownData);

        assertEq(tm.debt(ATTACKER_TROVE), BORROW, "attacker's own trove works normally");
        assertEq(bold.balanceOf(attacker), BORROW, "and they keep their own debt");
    }

    /// The maker legs need the binding too — an attacker must not be able to push
    /// a victim's pre-approved collateral into a trove of their choosing.
    function test_attacker_cannot_addColl_to_victim_trove() public {
        collateral.mint(attacker, ADD_COLL);
        vm.startPrank(attacker);
        collateral.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(addCollModule), address(collateral), uint160(ADD_COLL), 0);
        vm.stopPrank();

        vm.prank(settlement);
        vm.expectRevert(LiquityV2TroveAuth.InvalidCaller.selector);
        addCollModule.makeOnBehalf(attacker, ADD_COLL, abi.encode(address(tm), MAKER_TROVE, address(collateral)));

        assertEq(tm.coll(MAKER_TROVE), 20e18, "victim's trove untouched");
    }

    /// A trove id that does not exist fails closed on the ERC-721 read rather than
    /// resolving to `address(0)` and matching a zero principal.
    function test_nonexistent_trove_reverts() public {
        bytes memory data = _borrowData(9999);

        vm.prank(attacker);
        permit3.approveTaker(settlement, keccak256(data), type(uint160).max, 0);

        vm.prank(settlement);
        vm.expectRevert(LqtyTroveNFT.NonexistentTrove.selector);
        permit3.take(address(takerModule), attacker, uint160(BORROW), attacker, data);
    }

    // ──────────────── Repay (derived troveManager) ────────────────

    function test_repay_reducesOwnDebt_withDerivedTroveManager() public {
        tm.setDebt(MAKER_TROVE, BORROW);
        bold.mint(maker, BORROW);

        vm.startPrank(maker);
        bold.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), address(bold), uint160(BORROW), 0);
        vm.stopPrank();

        // data no longer carries `troveManager` — it is derived from `borrowerOps`.
        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, BORROW, abi.encode(address(tm), MAKER_TROVE, address(bold)));

        assertEq(tm.debt(MAKER_TROVE), 0, "debt repaid");
        assertEq(bold.balanceOf(address(repayModule)), 0, "no residue left on the module");
    }

    function test_attacker_cannot_repay_into_victim_trove() public {
        tm.setDebt(MAKER_TROVE, BORROW);
        bold.mint(attacker, BORROW);

        vm.startPrank(attacker);
        bold.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), address(bold), uint160(BORROW), 0);
        vm.stopPrank();

        vm.prank(settlement);
        vm.expectRevert(LiquityV2TroveAuth.InvalidCaller.selector);
        repayModule.makeOnBehalf(attacker, BORROW, abi.encode(address(tm), MAKER_TROVE, address(bold)));

        assertEq(tm.debt(MAKER_TROVE), BORROW, "victim's debt unchanged");
    }
}
