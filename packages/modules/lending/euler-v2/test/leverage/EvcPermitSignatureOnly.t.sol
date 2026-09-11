// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IEVC} from "../../src/interfaces/IEulerV2.sol";
import {EulerV2OperatorModule} from "../../src/EulerV2OperatorModule.sol";
import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";

/// @dev The slice of the LIVE EVC's surface this test needs beyond the package's
///      minimal `IEVC`: the permit entrypoint itself plus the views that prove
///      the maker's auth state before and after. Declared test-locally — the
///      production interface stays minimal.
interface IEVCPermitViews {
    function permit(
        address signer,
        address sender,
        uint256 nonceNamespace,
        uint256 nonce,
        uint256 deadline,
        uint256 value,
        bytes calldata data,
        bytes calldata signature
    ) external payable;

    function getNonce(bytes19 addressPrefix, uint256 nonceNamespace) external view returns (uint256);
    function isControllerEnabled(address account, address vault) external view returns (bool);
    function isCollateralEnabled(address account, address vault) external view returns (bool);
}

/// @dev SIGNATURE-ONLY Euler auth: the maker's operator/controller/collateral
/// grants ride into the fill as an EVC `permit` tail on the pre-fund module's `data`
/// ({DelegationHelper.replayEvcPermit}), so a maker who has NEVER sent an EVC
/// transaction opens a levered position — the Euler analogue of what Aave gets
/// from `delegationWithSig` (see PreFundOneSided.t.sol's
/// `test_oneSignature_crossAssetOpen_XtoAB_onlyXApproved`).
///
/// The EIP-712 surface is validated EMPIRICALLY against the live mainnet EVC in
/// `test_evcPermit_digestValidatedAgainstLiveEvc` (a direct, un-caught `permit`
/// call must succeed), then the same tail is driven through the in-fill replay.
///
/// The maker here is a FRESH key: the harness's `maker` is rebound after the
/// base `setUp` so none of the base grants (or even its bare ERC20 approvals)
/// exist for it. Its account nonce is asserted 0 after the fill — the maker
/// broadcast NOTHING, ever.
///
/// The NO-TAIL path is unchanged by construction (`data.length <= baseLen` is a
/// no-op) and stays covered by PreFundTakeForOpen.t.sol — all three tests there
/// (`test_preFundFunded_opensPosition_zeroReceiveSideApprovals`,
/// `test_preFundFunded_partialFills_moduleDrainedAcrossSlices`,
/// `test_preFundFunded_samePosition_andCostsNoMore`) run tail-less `OpenData`
/// against pre-granted makers in this same suite.
contract EvcPermitSignatureOnlyTest is EulerV2ModulesBase {

    uint256 constant COLLATERAL = 1 ether;
    uint256 constant BORROW = 1_500e6;

    // ── The EVC's EIP-712 shape, from the verified EthereumVaultConnector source
    //    (note: NO version field in the domain) — proven against the live
    //    deployment by the direct-permit test below. ──
    bytes32 constant EVC_DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 constant EVC_PERMIT_TYPEHASH = keccak256(
        "Permit(address signer,address sender,uint256 nonceNamespace,uint256 nonce,uint256 deadline,uint256 value,bytes data)"
    );

    function setUp() public override {
        super.setUp();
        vm.label(address(operatorModule), "eulerPreFundTakeForModule");

        // Rebind the harness's maker to a FRESH key with zero history: the base
        // setUp granted operator/controller/collateral (and ERC20 approvals) to
        // the old maker, which is exactly the state this test must not have.
        makerPk = 0xF4E511;
        maker = vm.addr(makerPk);
        vm.label(maker, "freshMaker");
    }

    // ──────────────────── EVC permit plumbing ────────────────────

    function _evcDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(EVC_DOMAIN_TYPEHASH, keccak256(bytes("Ethereum Vault Connector")), block.chainid, address(EVC))
        );
    }

    /// @dev Sign the EVC `Permit` digest with the maker's pk. `sender = 0` — any
    ///      filler may land it; `value = 0` — the grants move no ETH.
    function _signEvcPermit(uint256 ns, uint256 nonce, uint256 deadline, bytes memory evcData)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(EVC_PERMIT_TYPEHASH, maker, address(0), ns, nonce, deadline, uint256(0), keccak256(evcData))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _evcDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v); // the EVC reads (r, s, v)
    }

    /// @dev The signed self-call: one `EVC.batch` whose items target the EVC
    ///      itself (onBehalfOfAccount MUST be 0 for self-targeted items) and
    ///      grant the maker's whole auth surface in one blob.
    function _grantBatchData() internal view returns (bytes memory) {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(EVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.setAccountOperator, (maker, address(operatorModule), true))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(EVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (maker, address(EUSDC)))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(EVC),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeCall(IEVC.enableCollateral, (maker, address(EWETH)))
        });
        return abi.encodeCall(IEVC.batch, (items));
    }

    function _makerNonce(uint256 ns) internal view returns (uint256) {
        return IEVCPermitViews(address(EVC)).getNonce(bytes19(uint152(uint160(maker) >> 8)), ns);
    }

    // ──────────────────── Order plumbing (the pre-fund shape) ────────────────────

    function _forLeg(uint256 j, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[j].recipient == module` (F27/H-1).
        // The op rides bits [244,252) — see {EulerV2OperatorModule}. Inside `ref`, so
        // the taker grant binds it.
        return (uint256(1) << 255) | (uint256(EulerV2OperatorModule.Op.Open) << 244)
            | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | j;
    }

    /// @dev The 128-byte {OpenData} head + the {DelegationHelper.replayEvcPermit}
    ///      tail: abi.encode(ns, nonce, deadline, evcData, sig).
    function _dataWithTail(uint256 ns, uint256 nonce, uint256 deadline, bytes memory evcData, bytes memory permitSig)
        internal
        view
        returns (bytes memory)
    {
        bytes memory head = abi.encode(
            EulerV2OperatorModule.OpenData({
                forDesc: _forLeg(0, WETH),
                forCap: 0,
                collateralVault: address(EWETH),
                borrowVault: address(EUSDC)
            })
        );
        return bytes.concat(head, abi.encode(ns, nonce, deadline, evcData, permitSig));
    }

    function _preFundOrder(uint256 nonce, bytes memory data) internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(operatorModule), BORROW, address(0), data);
        o = _order(maker, nonce, USDC, WETH, BORROW, COLLATERAL, items);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, COLLATERAL, 0, address(operatorModule)); // delivered to the module
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    function _assertNoGrants() internal view {
        assertFalse(EVC.isAccountOperatorAuthorized(maker, address(operatorModule)), "no operator grant pre-fill");
        assertFalse(IEVCPermitViews(address(EVC)).isControllerEnabled(maker, address(EUSDC)), "no controller pre-fill");
        assertFalse(IEVCPermitViews(address(EVC)).isCollateralEnabled(maker, address(EWETH)), "no collateral pre-fill");
    }

    function _assertGrants() internal view {
        assertTrue(EVC.isAccountOperatorAuthorized(maker, address(operatorModule)), "operator granted");
        assertTrue(IEVCPermitViews(address(EVC)).isControllerEnabled(maker, address(EUSDC)), "controller enabled");
        assertTrue(IEVCPermitViews(address(EVC)).isCollateralEnabled(maker, address(EWETH)), "collateral enabled");
    }

    // ── Digest validation, EMPIRICAL: a direct, un-caught `permit` against the
    //    LIVE mainnet EVC. If the typehash/domain above were wrong this reverts
    //    loudly here instead of vanishing inside the in-fill try/catch. ──
    function test_evcPermit_digestValidatedAgainstLiveEvc() public {
        _assertNoGrants();
        assertEq(_makerNonce(0), 0, "fresh key, virgin nonce");

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory evcData = _grantBatchData();
        bytes memory sig = _signEvcPermit(0, 0, deadline, evcData);

        // sender = 0 in the signed message ⇒ ANY submitter may land it.
        vm.prank(address(0xD00D));
        IEVCPermitViews(address(EVC)).permit(maker, address(0), 0, 0, deadline, 0, evcData, sig);

        _assertGrants();
        assertEq(_makerNonce(0), 1, "permit nonce burned");
    }

    // ── The claim itself: a levered open with ZERO prior maker transactions of
    //    any kind. Fresh key, no EVC grants, no ERC20 approvals, no Permit3
    //    entries; the EVC grants ride the item's tail and the Permit3 taker
    //    allowance rides the witness-bound PermitBatch — two maker signatures,
    //    no maker transactions. ──
    function test_oneSignature_leveredOpen_zeroPriorMakerTransactions() public {
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);

        // The maker's world is EMPTY. Prove it, don't assume it.
        _assertNoGrants();
        assertEq(vm.getNonce(maker), 0, "the maker never broadcast a transaction");
        assertEq(IERC20(WETH).allowance(maker, address(permit3)), 0, "no ERC20 approval, receive side");
        assertEq(IERC20(USDC).allowance(maker, address(permit3)), 0, "no ERC20 approval, debt side");
        (uint160 amt,) = permit3.tokenAllowance(maker, address(operatorModule), WETH);
        assertEq(amt, 0, "no Permit3 book entry");

        // Signature 1: the EVC permit, sealed into the item's data tail.
        bytes memory data;
        {
            uint256 deadline = block.timestamp + 1 hours;
            bytes memory evcData = _grantBatchData();
            data = _dataWithTail(0, 0, deadline, evcData, _signEvcPermit(0, 0, deadline, evcData));
        }

        Order memory o = _preFundOrder(31, data);

        // Signature 2: the witness-bound PermitBatch — the borrow's taker
        // allowance, bound to this order's hash. No token permits: the push
        // shape needs none.
        IPermit3.PermitBatch memory batch = _buildBatch(
            new IPermit3.TokenPermit[](0),
            _takerPermits1(address(settlement), address(operatorModule), keccak256(data), BORROW),
            0,
            _expiry(o)
        );
        bytes memory sig = _signPermitWitness(batch, _hashOrder(o));

        uint256 col0 = _wethCollateral(maker);
        uint256 debt0 = _usdcDebt(maker);

        vm.prank(solver);
        settlement.fillWithPermit(o, batch, sig, BORROW);

        // The position, and the grants that made it possible.
        _assertGrants();
        assertApproxEqRel(_wethCollateral(maker) - col0, COLLATERAL, 1e15, "delivered leg became collateral");
        assertApproxEqRel(_usdcDebt(maker) - debt0, BORROW, 1e15, "debt drawn");

        // Standard push asserts: nothing transited the maker, nothing stranded.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "the maker's wallet never saw the WETH");
        assertEq(IERC20(WETH).balanceOf(address(operatorModule)), 0, "module drained: delivery fully deposited");
        assertEq(IERC20(USDC).balanceOf(solver), BORROW, "solver received the input leg");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement drained");
        assertEq(vm.getNonce(maker), 0, "still zero maker transactions: signature-only throughout");
    }

    // ── The best-effort clause under fire: a griefer lifts the permit out of
    //    pending calldata and lands it FIRST. The in-fill replay's nonce is then
    //    burned (and `setAccountOperator` would revert as unchanged), the
    //    try/catch swallows it, and the fill still succeeds on the grants the
    //    front-runner helpfully installed. ──
    function test_frontRunLandedPermit_fillStillSucceeds() public {
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory evcData = _grantBatchData();
        bytes memory permitSig = _signEvcPermit(0, 0, deadline, evcData);
        bytes memory data = _dataWithTail(0, 0, deadline, evcData, permitSig);

        Order memory o = _preFundOrder(32, data);
        IPermit3.PermitBatch memory batch = _buildBatch(
            new IPermit3.TokenPermit[](0),
            _takerPermits1(address(settlement), address(operatorModule), keccak256(data), BORROW),
            0,
            _expiry(o)
        );
        bytes memory sig = _signPermitWitness(batch, _hashOrder(o));

        // The front-run: same bytes, landed directly, by anyone.
        vm.prank(address(0xBADD));
        IEVCPermitViews(address(EVC)).permit(maker, address(0), 0, 0, deadline, 0, evcData, permitSig);
        _assertGrants();
        assertEq(_makerNonce(0), 1, "nonce burned by the front-runner");

        uint256 col0 = _wethCollateral(maker);
        uint256 debt0 = _usdcDebt(maker);

        vm.prank(solver);
        settlement.fillWithPermit(o, batch, sig, BORROW); // must NOT brick

        assertApproxEqRel(_wethCollateral(maker) - col0, COLLATERAL, 1e15, "position opened regardless");
        assertApproxEqRel(_usdcDebt(maker) - debt0, BORROW, 1e15, "debt drawn regardless");
        assertEq(IERC20(WETH).balanceOf(address(operatorModule)), 0, "module drained");
    }
}
