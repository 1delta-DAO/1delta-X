// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {LiquityV2TakerModule, LiquityV2AddCollModule, LiquityV2TroveAuth} from "../../src/LiquityV2Modules.sol";
import {ILiquityV2TroveManager, ITroveNFT, LatestTroveData} from "../../src/interfaces/ILiquityV2.sol";

interface IBorrowerOpsFork {
    function setRemoveManagerWithReceiver(uint256 troveId, address manager, address receiver) external;
    function setAddManager(uint256 troveId, address manager) external;
    function withdrawBold(uint256 troveId, uint256 amount, uint256 maxUpfrontFee) external;
}

/// @title LiquityV2ForkAuthTest
/// @notice Ethereum-mainnet fork validation of the trove ownership binding.
///
///  Why this exists: the unit tests run against mocks I wrote, so they can only
///  prove the modules behave correctly against MY model of Liquity. This file
///  proves the model is real. It caught a genuine bug — the binding was first
///  written rooted at `BorrowerOperations.troveManager()`, which does not exist on
///  mainnet (that call reverts), so the whole chain would have failed on the first
///  real fill. `test_authChain_resolvesOnMainnet` pins that discovery.
///
///  Addresses are the WETH branch of Liquity V2, verified on-chain via the
///  CollateralRegistry (0xf949982B91C8c61e952B3bA942cbbfaef5386684, branch 0).
abstract contract LiquityV2ForkBase is Test {
    // ── Verified Ethereum mainnet addresses (Liquity V2, WETH branch) ──
    address internal constant TROVE_MANAGER = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address internal constant TROVE_NFT = 0x1A0FC0b843aFD9140267D25d4E575Cb37a838013;
    address internal constant BORROWER_OPS = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65;
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev An active WETH-branch trove at the pinned block: ~541 WETH collateral
    ///      backing ~687k BOLD, so it has ample headroom for the small test borrow.
    uint256 internal constant TROVE_ID =
        102036905498439360210701303197562255497830229508729325448634378946648943354674;
    address internal constant TROVE_OWNER = 0xDf6E7fd41ef192dF5d37f766435162b4e579fdb0;

    uint256 internal constant FORK_BLOCK = 25_600_000;

    Permit3 internal permit3;
    LiquityV2TakerModule internal takerModule;
    LiquityV2AddCollModule internal addCollModule;

    address internal settlement = address(0x5E77);
    address internal attacker = address(0xBAD);
    address internal receiver = address(0xFEE);

    /// @dev `ETH_RPC_URL` if set, else a public archive endpoint. Archive access is
    ///      required: the block is pinned so the trove's state (and therefore the
    ///      test's meaning) cannot drift, and most public nodes only serve ~128
    ///      blocks of state.
    function _forkMainnet() internal {
        try vm.envString("ETH_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        if (_tryFork("https://gateway.tenderly.co/public/mainnet")) return;
        revert("LiquityV2Fork: no archive-capable mainnet RPC (set ETH_RPC_URL)");
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

    function setUp() public virtual {
        _forkMainnet();

        permit3 = new Permit3();
        takerModule = new LiquityV2TakerModule(address(permit3));
        addCollModule = new LiquityV2AddCollModule(address(permit3), settlement);

        vm.label(TROVE_MANAGER, "TroveManager");
        vm.label(TROVE_NFT, "TroveNFT");
        vm.label(BORROWER_OPS, "BorrowerOperations");
        vm.label(BOLD, "BOLD");
        vm.label(TROVE_OWNER, "troveOwner");
    }

    /// @dev `op = 0` (Borrow) payload. Leading address is the TroveManager — the
    ///      single caller-supplied root the rest of the chain is derived from.
    function _borrowData(uint256 troveId) internal pure returns (bytes memory) {
        return abi.encode(uint8(0), TROVE_MANAGER, troveId, BOLD, type(uint256).max);
    }

    function _debtOf(uint256 troveId) internal view returns (uint256) {
        LatestTroveData memory d = ILiquityV2TroveManager(TROVE_MANAGER).getLatestTroveData(troveId);
        return d.entireDebt;
    }
}

contract LiquityV2ForkAuthTest is LiquityV2ForkBase {
    uint256 constant BORROW = 100e18; // 100 BOLD against a ~687k BOLD trove

    // ──────────────── The address chain ────────────────

    /// Pins the exact getters `LiquityV2TroveAuth` depends on. The first version of
    /// the fix rooted the chain at `BorrowerOperations.troveManager()`; this test
    /// is what proved that call does not exist, so it also asserts the revert to
    /// stop anyone rerooting the chain back onto it.
    function test_authChain_resolvesOnMainnet() public view {
        assertEq(ILiquityV2TroveManager(TROVE_MANAGER).troveNFT(), TROVE_NFT, "troveManager.troveNFT()");
        assertEq(
            ILiquityV2TroveManager(TROVE_MANAGER).borrowerOperations(),
            BORROWER_OPS,
            "troveManager.borrowerOperations()"
        );
        assertEq(ITroveNFT(TROVE_NFT).ownerOf(TROVE_ID), TROVE_OWNER, "troveNFT.ownerOf()");

        // BorrowerOperations exposes no `troveManager()` — this is WHY the root is
        // the TroveManager. If a future Liquity release adds it, this assertion
        // fails loudly rather than letting the chain be silently rerooted.
        (bool ok,) = BORROWER_OPS.staticcall(abi.encodeWithSignature("troveManager()"));
        assertFalse(ok, "BorrowerOperations.troveManager() must not resolve");
    }

    /// A trove id that was never minted fails closed on the real ERC-721 rather
    /// than resolving to `address(0)`.
    function test_nonexistentTrove_failsClosedOnRealNFT() public {
        vm.expectRevert();
        ITroveNFT(TROVE_NFT).ownerOf(uint256(keccak256("no such trove")));
    }

    // ──────────────── Real borrow by the real owner ────────────────

    function test_realOwner_canBorrowThroughModule() public {
        bytes memory data = _borrowData(TROVE_ID);

        // The owner onboards exactly as documented.
        vm.startPrank(TROVE_OWNER);
        IBorrowerOpsFork(BORROWER_OPS).setRemoveManagerWithReceiver(
            TROVE_ID, address(takerModule), address(takerModule)
        );
        permit3.approveTaker(settlement, keccak256(data), uint160(BORROW), 0);
        vm.stopPrank();

        uint256 debtBefore = _debtOf(TROVE_ID);
        uint256 balBefore = IERC20(BOLD).balanceOf(receiver);

        vm.prank(settlement);
        permit3.take(address(takerModule), TROVE_OWNER, uint160(BORROW), receiver, data);

        assertEq(IERC20(BOLD).balanceOf(receiver) - balBefore, BORROW, "receiver got the borrowed BOLD");
        assertGe(_debtOf(TROVE_ID) - debtBefore, BORROW, "debt grew by at least the borrow (plus upfront fee)");
        assertEq(IERC20(BOLD).balanceOf(address(takerModule)), 0, "module forwarded everything, holds no residue");
    }

    // ──────────────── The attack, against a REAL trove ────────────────

    /// The drain, end to end on mainnet state. The attacker forges nothing: they
    /// approve a ref of their OWN over the victim's real trove and have it filled.
    function test_attacker_cannot_borrow_against_real_trove() public {
        bytes memory victimData = _borrowData(TROVE_ID);

        // The victim has completed the documented setup — this is the precondition
        // for the attack, not a misconfiguration.
        vm.prank(TROVE_OWNER);
        IBorrowerOpsFork(BORROWER_OPS).setRemoveManagerWithReceiver(
            TROVE_ID, address(takerModule), address(takerModule)
        );

        // Succeeds: the taker book is keyed by the approver, so nothing here
        // belongs to the victim.
        vm.prank(attacker);
        permit3.approveTaker(settlement, keccak256(victimData), type(uint160).max, 0);

        uint256 debtBefore = _debtOf(TROVE_ID);

        vm.prank(settlement);
        vm.expectRevert(LiquityV2TroveAuth.InvalidCaller.selector);
        permit3.take(address(takerModule), attacker, uint160(BORROW), attacker, victimData);

        assertEq(_debtOf(TROVE_ID), debtBefore, "victim's debt unchanged");
        assertEq(IERC20(BOLD).balanceOf(attacker), 0, "attacker received nothing");
    }

    /// THE control, and the reason the finding is real: with the victim's grant in
    /// place, real Liquity is perfectly happy to let this module drain that trove.
    /// Calling `withdrawBold` directly AS the module succeeds — no beneficiary is
    /// consulted anywhere in the protocol. So the only thing standing between the
    /// victim and any filler who knows their trove id is the module's own check.
    function test_protocolItselfWouldHaveAllowedTheDrain() public {
        vm.prank(TROVE_OWNER);
        IBorrowerOpsFork(BORROWER_OPS).setRemoveManagerWithReceiver(
            TROVE_ID, address(takerModule), address(takerModule)
        );

        uint256 debtBefore = _debtOf(TROVE_ID);
        uint256 modBefore = IERC20(BOLD).balanceOf(address(takerModule));

        // No Permit3, no order, no ownership check — just the module's protocol
        // authority, exercised directly.
        vm.prank(address(takerModule));
        IBorrowerOpsFork(BORROWER_OPS).withdrawBold(TROVE_ID, BORROW, type(uint256).max);

        assertEq(
            IERC20(BOLD).balanceOf(address(takerModule)) - modBefore,
            BORROW,
            "Liquity minted the victim's borrow to the module with no beneficiary check"
        );
        assertGe(_debtOf(TROVE_ID) - debtBefore, BORROW, "and charged the victim the debt");
    }
}
