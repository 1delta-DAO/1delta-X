// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {LiquityV2TakerModule, LiquityV2TroveAuth} from "../../src/LiquityV2Modules.sol";
import {LatestTroveData} from "../../src/interfaces/ILiquityV2.sol";

// Reuse the honest mocks from the existing suite by re-declaring minimal copies.
contract Tok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

contract NFT {
    mapping(uint256 => address) internal _o;
    error Nonexistent();
    function mint(uint256 id, address to) external { _o[id] = to; }
    function ownerOf(uint256 id) external view returns (address) { address o = _o[id]; if (o == address(0)) revert Nonexistent(); return o; }
}

contract TM {
    address public troveNFT;
    address public borrowerOperations;
    mapping(uint256 => uint256) public debt;
    mapping(uint256 => uint256) public coll;
    constructor(address n) { troveNFT = n; }
    function setBO(address b) external { borrowerOperations = b; }
    function setDebt(uint256 id, uint256 d) external { debt[id] = d; }
    function setColl(uint256 id, uint256 c) external { coll[id] = c; }
    function getLatestTroveData(uint256 id) external view returns (LatestTroveData memory d) { d.entireDebt = debt[id]; d.entireColl = coll[id]; }
}

/// The REAL branch entry point. Authorises the MANAGER only — exactly like mainnet.
contract BO {
    address public tmAddr;
    Tok public bold;
    Tok public coll;
    mapping(uint256 => mapping(address => bool)) public removeManager;
    mapping(uint256 => address) public receiverOf;
    error NotManager();
    constructor(address t, address b, address c) { tmAddr = t; bold = Tok(b); coll = Tok(c); }
    function setRemoveManagerWithReceiver(uint256 id, address m, address r) external { removeManager[id][m] = true; receiverOf[id] = r; }
    function withdrawBold(uint256 id, uint256 a, uint256) external {
        if (!removeManager[id][msg.sender]) revert NotManager();
        TM(tmAddr).setDebt(id, TM(tmAddr).debt(id) + a);
        bold.mint(receiverOf[id], a);
    }
    function withdrawColl(uint256 id, uint256 a) external {
        if (!removeManager[id][msg.sender]) revert NotManager();
        TM(tmAddr).setColl(id, TM(tmAddr).coll(id) - a);
        coll.transfer(receiverOf[id], a);
    }
}

/// @dev The immutable branch registry the modules are now rooted at.
contract Registry {
    mapping(uint256 => address) internal _tm;
    function set(uint256 i, address t) external { _tm[i] = t; }
    function getTroveManager(uint256 i) external view returns (address) { return _tm[i]; }
    function totalCollaterals() external pure returns (uint256) { return 1; }
}

// ── The attacker's forged root ────────────────────────────────────────────────
// One contract returning a LYING TroveNFT for the ownership check and the REAL
// BorrowerOperations for dispatch. This USED to be injectable as `troveManager`
// via `data`, and it drained victim troves. It is now unreachable: `data` carries
// a branch INDEX and the TroveManager is resolved through an immutable registry,
// so there is no longer a field an attacker can point at this contract.
contract ForgedNFT {
    address public immutable attacker;
    constructor(address a) { attacker = a; }
    function ownerOf(uint256) external view returns (address) { return attacker; }
}

contract ForgedTM {
    address public troveNFT;
    address public borrowerOperations; // <- the REAL one
    constructor(address fakeNft, address realBO) { troveNFT = fakeNft; borrowerOperations = realBO; }
}

contract ForgedRootAuthTest is Test {
    Permit3 permit3;
    Tok bold; Tok collateral;
    NFT nft; TM tm; BO bo; Registry registry;
    LiquityV2TakerModule takerModule;

    address victim = address(0xA11CE);
    address attacker = address(0xBAD);

    uint256 constant BRANCH = 0;
    uint256 constant UNKNOWN_BRANCH = 7;
    uint256 constant VICTIM_TROVE = 1111;
    uint256 constant STEAL_BOLD = 3_000e18;
    uint256 constant STEAL_COLL = 5e18;

    function setUp() public {
        permit3 = new Permit3();
        bold = new Tok(); collateral = new Tok();
        nft = new NFT();
        tm = new TM(address(nft));
        bo = new BO(address(tm), address(bold), address(collateral));
        tm.setBO(address(bo));
        registry = new Registry();
        registry.set(BRANCH, address(tm));
        takerModule = new LiquityV2TakerModule(address(permit3), address(registry));

        nft.mint(VICTIM_TROVE, victim);
        tm.setColl(VICTIM_TROVE, 20e18);
        collateral.mint(address(bo), 100e18);

        // The victim onboards EXACTLY as this package's docs instruct.
        bo.setRemoveManagerWithReceiver(VICTIM_TROVE, address(takerModule), address(takerModule));
    }

    /// @dev F26/C-1 REGRESSION. The forged root is still deployable — it just has
    ///      nowhere to go. `data` carries a branch INDEX, and the TroveManager comes
    ///      from an immutable registry, so the attacker cannot substitute the oracle.
    ///      Before the fix this exact flow (with the forged TM in `data`) minted
    ///      3,000 BOLD against the victim's trove.
    function test_forgedRoot_isNotInjectable_borrow() public {
        ForgedNFT fnft = new ForgedNFT(attacker);
        ForgedTM ftm = new ForgedTM(address(fnft), address(bo));
        assertEq(ftm.troveNFT(), address(fnft), "the forged root still lies, it is just unreachable");

        // The only branch selector the attacker controls is an INDEX. Index 0 is the
        // real branch, so the real TroveNFT answers and the victim owns the trove.
        bytes memory data = abi.encode(uint8(0), BRANCH, VICTIM_TROVE, address(bold), uint256(0), STEAL_BOLD);

        vm.startPrank(attacker);
        permit3.approveTaker(attacker, address(takerModule), keccak256(data), type(uint160).max, 0);
        vm.expectRevert(LiquityV2TroveAuth.InvalidCaller.selector);
        permit3.take(address(takerModule), attacker, uint160(STEAL_BOLD), attacker, data);
        vm.stopPrank();

        assertEq(bold.balanceOf(attacker), 0, "no BOLD minted");
        assertEq(tm.debt(VICTIM_TROVE), 0, "victim takes on no debt");
    }

    /// @dev Same for the collateral leg, which needs no upfront fee and was the
    ///      cleaner steal of the two.
    function test_forgedRoot_isNotInjectable_withdrawColl() public {
        bytes memory data = abi.encode(uint8(1), BRANCH, VICTIM_TROVE, address(collateral));

        vm.startPrank(attacker);
        permit3.approveTaker(attacker, address(takerModule), keccak256(data), type(uint160).max, 0);
        vm.expectRevert(LiquityV2TroveAuth.InvalidCaller.selector);
        permit3.take(address(takerModule), attacker, uint160(STEAL_COLL), attacker, data);
        vm.stopPrank();

        assertEq(collateral.balanceOf(attacker), 0, "attacker took nothing");
        assertEq(tm.coll(VICTIM_TROVE), 20e18, "victim's trove untouched");
    }

    /// @dev A branch the registry does not know fails closed with a named error
    ///      rather than resolving to `address(0)` and reverting somewhere opaque.
    function test_unknownBranch_reverts() public {
        bytes memory data = abi.encode(uint8(0), UNKNOWN_BRANCH, VICTIM_TROVE, address(bold), uint256(0), STEAL_BOLD);

        vm.startPrank(attacker);
        permit3.approveTaker(attacker, address(takerModule), keccak256(data), type(uint160).max, 0);
        vm.expectRevert(LiquityV2TroveAuth.UnknownBranch.selector);
        permit3.take(address(takerModule), attacker, uint160(STEAL_BOLD), attacker, data);
        vm.stopPrank();
    }

    /// @dev The binding is not a ban: the trove's real owner still gets served.
    function test_owner_canStillBorrow() public {
        bytes memory data = abi.encode(uint8(0), BRANCH, VICTIM_TROVE, address(bold), uint256(0), STEAL_BOLD);

        vm.startPrank(victim);
        permit3.approveTaker(victim, address(takerModule), keccak256(data), type(uint160).max, 0);
        permit3.take(address(takerModule), victim, uint160(STEAL_BOLD), victim, data);
        vm.stopPrank();

        assertEq(bold.balanceOf(victim), STEAL_BOLD, "the owner's own borrow still settles");
        assertEq(tm.debt(VICTIM_TROVE), STEAL_BOLD, "and lands on their trove");
    }
}
