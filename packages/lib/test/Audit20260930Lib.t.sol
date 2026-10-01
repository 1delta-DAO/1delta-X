// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {DustHandler} from "@lib/DustHandler.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Regression tests for the 2026-09-30 whole-tree audit, packages/lib group:
//    L-ED-1   EVC permit replayed with `sender = address(0)` (liftable after cancel)
//    L-LIB-3  one sealed EVC batch: operator already set ⇒ the enables are lost
//    L-LIB-4  best-effort replays SET rather than raise a standing grant
//    L-AAVE-2 replay value bound to the slice ⇒ gasless orders full-fill-only
//    L-CMT-3  in-fill Comet/Morpho replay must CONSUME the nonce (pin)
//    L-LIB-7  zero-floor `disposeResidual` overload removed (pin)
// ════════════════════════════════════════════════════════════════════════════

// ───────────────────────────── EVC model ─────────────────────────────
//
// A faithful slice of EthereumVaultConnector's permit semantics:
//   • `sender != 0 && sender != msg.sender` ⇒ NotAuthorized
//   • nonces SEQUENTIAL per (signer, namespace); burned only on success
//   • EIP-712 digest commits to `sender`; ECDSA (r, s, v) over it
//   • the signed bytes run as a self-call authenticated as `signer`
//   • `setAccountOperator` reverts when the status would not change;
//     `enableController` / `enableCollateral` are idempotent inserts
//   • `batch` reverts as a whole on any failed item
contract MockEVC {
    struct BatchItem {
        address targetContract;
        address onBehalfOfAccount;
        uint256 value;
        bytes data;
    }

    bytes32 constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address signer,address sender,uint256 nonceNamespace,uint256 nonce,uint256 deadline,uint256 value,bytes data)"
    );

    error EVC_NotAuthorized();
    error EVC_InvalidNonce();
    error EVC_InvalidTimestamp();
    error EVC_InvalidOperatorStatus();

    mapping(address => mapping(uint256 => uint256)) public nonces;
    mapping(address => mapping(address => bool)) public operator;
    mapping(address => mapping(address => bool)) public controller;
    mapping(address => mapping(address => bool)) public collateral;

    address private _permitSigner;

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("Ethereum Vault Connector")), block.chainid, address(this))
        );
    }

    function permitDigest(
        address signer,
        address sender,
        uint256 ns,
        uint256 nonce,
        uint256 deadline,
        uint256 value,
        bytes memory data
    ) public view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, signer, sender, ns, nonce, deadline, value, keccak256(data)));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function permit(
        address signer,
        address sender,
        uint256 ns,
        uint256 nonce,
        uint256 deadline,
        uint256 value,
        bytes calldata data,
        bytes calldata signature
    ) external payable {
        if (sender != address(0) && sender != msg.sender) revert EVC_NotAuthorized();
        if (nonces[signer][ns] != nonce) revert EVC_InvalidNonce();
        if (deadline < block.timestamp) revert EVC_InvalidTimestamp();
        _verify(signer, permitDigest(signer, sender, ns, nonce, deadline, value, data), signature);
        nonces[signer][ns] = nonce + 1;
        _selfCall(signer, data);
    }

    function _verify(address signer, bytes32 digest, bytes calldata signature) private pure {
        (bytes32 r, bytes32 s) = abi.decode(signature[:64], (bytes32, bytes32));
        if (ecrecover(digest, uint8(signature[64]), r, s) != signer) revert EVC_NotAuthorized();
    }

    function _selfCall(address signer, bytes calldata data) private {
        _permitSigner = signer;
        (bool ok, bytes memory ret) = address(this).call(data);
        _permitSigner = address(0);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _auth(address account) private view {
        if (msg.sender == account) return;
        if (msg.sender == address(this) && _permitSigner == account) return;
        revert EVC_NotAuthorized();
    }

    function batch(BatchItem[] calldata items) external {
        for (uint256 i; i < items.length; ++i) {
            (bool ok, bytes memory ret) = items[i].targetContract.call(items[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function setAccountOperator(address account, address op, bool authorized) external {
        _auth(account);
        if (operator[account][op] == authorized) revert EVC_InvalidOperatorStatus();
        operator[account][op] = authorized;
    }

    function enableController(address account, address vault) external {
        _auth(account);
        controller[account][vault] = true;
    }

    function enableCollateral(address account, address vault) external {
        _auth(account);
        collateral[account][vault] = true;
    }
}

/// @dev Stands in for EulerV2OperatorModule: the lib is internal, so `msg.sender`
///      of `EVC.permit` is THIS contract.
contract EvcReplayModule {
    function open(bytes calldata data, address evc, address signer) external {
        DelegationHelper.replayEvcPermit(data, 0, evc, signer);
    }
}

// ───────────────────────── permit / delegation model ─────────────────────────

/// @dev ERC-2612 whose "signature" commits to `value`: `sign(owner, spender,
///      value)` records the one value the owner signed at the current nonce, and
///      `permit` verifies against it — the property a real 2612 digest has. SETs
///      the allowance, like every production permit.
contract ValueBoundPermitToken {
    mapping(address => uint256) public nonces;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(bytes32 => bool) private _signed;

    error BadSig();

    function sign(address owner, address spender, uint256 value) external {
        _signed[keccak256(abi.encode(owner, spender, value, nonces[owner]))] = true;
    }

    function approve(address spender, uint256 value) external {
        allowance[msg.sender][spender] = value;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8, bytes32, bytes32) external {
        require(block.timestamp <= deadline, "expired");
        if (!_signed[keccak256(abi.encode(owner, spender, value, nonces[owner]))]) revert BadSig();
        nonces[owner]++;
        allowance[owner][spender] = value;
    }

    /// @dev The pull that follows the replay in a real module.
    function spend(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] -= amount;
    }
}

/// @dev Aave-style debt token: `delegationWithSig` commits to `value` and SETS
///      the borrow allowance; the borrow spends it.
contract ValueBoundDebtToken {
    mapping(address => uint256) public nonces;
    mapping(address => mapping(address => uint256)) public borrowAllowance;
    mapping(bytes32 => bool) private _signed;

    error BadSig();

    function sign(address delegator, address delegatee, uint256 value) external {
        _signed[keccak256(abi.encode(delegator, delegatee, value, nonces[delegator]))] = true;
    }

    function approveDelegation(address delegatee, uint256 value) external {
        borrowAllowance[msg.sender][delegatee] = value;
    }

    function delegationWithSig(
        address delegator,
        address delegatee,
        uint256 value,
        uint256 deadline,
        uint8,
        bytes32,
        bytes32
    ) external {
        require(block.timestamp <= deadline, "expired");
        if (!_signed[keccak256(abi.encode(delegator, delegatee, value, nonces[delegator]))]) revert BadSig();
        nonces[delegator]++;
        borrowAllowance[delegator][delegatee] = value;
    }

    function borrow(address delegator, address delegatee, uint256 amount) external {
        borrowAllowance[delegator][delegatee] -= amount;
    }
}

/// @dev Comet / Morpho-style boolean sig grants: nonce consumed on every landing,
///      even when the flag is already set (both venues behave so).
contract BoolSigVenue {
    mapping(address => uint256) public userNonce;
    mapping(address => mapping(address => bool)) public isAllowed;

    function allow(address manager, bool allowed) external {
        isAllowed[msg.sender][manager] = allowed; // direct grant/revoke: nonce untouched
    }

    function allowBySig(
        address owner,
        address manager,
        bool isAllowed_,
        uint256 nonce,
        uint256 expiry,
        uint8,
        bytes32,
        bytes32
    ) external {
        require(block.timestamp < expiry, "expired");
        require(nonce == userNonce[owner]++, "bad nonce");
        isAllowed[owner][manager] = isAllowed_;
    }
}

contract LibReplayHarness {
    function replayPermit(bytes calldata data, uint256 baseLen, address token, address owner, address spender, uint256 amount)
        external
    {
        PermitHelper.replayIfPresent(data, baseLen, token, owner, spender, amount);
    }

    function replayValuePermit(bytes calldata data, uint256 baseLen, address token, address owner, address spender)
        external
    {
        PermitHelper.replayValueIfPresent(data, baseLen, token, owner, spender);
    }

    function replayDelegation(bytes calldata data, uint256 baseLen, address delegator, address delegatee, uint256 amount)
        external
    {
        DelegationHelper.replayAaveDelegation(data, baseLen, delegator, delegatee, amount);
    }

    function replayComet(bytes calldata data, uint256 baseLen, address comet, address owner, address manager) external {
        DelegationHelper.replayCometAllow(data, baseLen, comet, owner, manager);
    }

    function dispose(
        address token,
        uint256 residual,
        uint256 floor,
        address onBehalfOf,
        DustHandler.DustAction action,
        address recycleTarget,
        bytes memory recycleCall
    ) external {
        DustHandler.disposeResidual(token, residual, floor, onBehalfOf, action, recycleTarget, recycleCall);
    }
}

/// @dev Recycle target that consumes half of what it is approved for.
contract HalfSink {
    function take(address token, uint256 amount) external {
        SimpleToken(token).transferFrom(msg.sender, address(this), amount / 2);
    }
}

contract SimpleToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ═════════════════════════════ EVC tests ═════════════════════════════

contract Audit20260930EvcReplayTest is Test {
    MockEVC evc;
    EvcReplayModule module;

    uint256 makerPk = 0xA11CE;
    address maker;
    address griefer = address(0xBADD);
    address constant BORROW_VAULT = address(0xB0);
    address constant COLLATERAL_VAULT = address(0xC0);

    function setUp() public {
        evc = new MockEVC();
        module = new EvcReplayModule();
        maker = vm.addr(makerPk);
    }

    function _operatorData() internal view returns (bytes memory) {
        return abi.encodeCall(MockEVC.setAccountOperator, (maker, address(module), true));
    }

    function _enablesData() internal view returns (bytes memory) {
        MockEVC.BatchItem[] memory items = new MockEVC.BatchItem[](2);
        items[0] = MockEVC.BatchItem(address(evc), address(0), 0, abi.encodeCall(MockEVC.enableController, (maker, BORROW_VAULT)));
        items[1] =
            MockEVC.BatchItem(address(evc), address(0), 0, abi.encodeCall(MockEVC.enableCollateral, (maker, COLLATERAL_VAULT)));
        return abi.encodeCall(MockEVC.batch, (items));
    }

    /// The pre-fix canonical shape: operator + enables sealed in ONE batch.
    function _bundledData() internal view returns (bytes memory) {
        MockEVC.BatchItem[] memory items = new MockEVC.BatchItem[](3);
        items[0] = MockEVC.BatchItem(address(evc), address(0), 0, _operatorData());
        items[1] = MockEVC.BatchItem(address(evc), address(0), 0, abi.encodeCall(MockEVC.enableController, (maker, BORROW_VAULT)));
        items[2] =
            MockEVC.BatchItem(address(evc), address(0), 0, abi.encodeCall(MockEVC.enableCollateral, (maker, COLLATERAL_VAULT)));
        return abi.encodeCall(MockEVC.batch, (items));
    }

    function _sign(address sender, uint256 ns, uint256 nonce, uint256 deadline, bytes memory data)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, evc.permitDigest(maker, sender, ns, nonce, deadline, 0, data));
        return abi.encodePacked(r, s, v);
    }

    function _permit(address sender, uint256 ns, bytes memory data)
        internal
        view
        returns (DelegationHelper.EvcPermit memory p)
    {
        uint256 deadline = block.timestamp + 1 days;
        p = DelegationHelper.EvcPermit(ns, 0, deadline, data, _sign(sender, ns, 0, deadline, data));
    }

    function _tail1(DelegationHelper.EvcPermit memory a) internal pure returns (bytes memory) {
        DelegationHelper.EvcPermit[] memory ps = new DelegationHelper.EvcPermit[](1);
        ps[0] = a;
        return abi.encode(ps);
    }

    function _tail2(DelegationHelper.EvcPermit memory a, DelegationHelper.EvcPermit memory b)
        internal
        pure
        returns (bytes memory)
    {
        DelegationHelper.EvcPermit[] memory ps = new DelegationHelper.EvcPermit[](2);
        ps[0] = a;
        ps[1] = b;
        return abi.encode(ps);
    }

    function _assertGrants(bool expected) internal view {
        assertEq(evc.operator(maker, address(module)), expected, "operator");
        assertEq(evc.controller(maker, BORROW_VAULT), expected, "controller");
        assertEq(evc.collateral(maker, COLLATERAL_VAULT), expected, "collateral");
    }

    /// L-ED-1: the module submits `sender = address(this)`, so the maker signs a
    /// MODULE-BOUND permit. It lands through the module's fill path and cannot be
    /// landed by anyone else — before the fill, or after the maker cancels.
    function test_audit_L_ED_1_moduleBoundPermit_landsInFill_notByThirdParty() public {
        DelegationHelper.EvcPermit memory op = _permit(address(module), 1, _operatorData());
        DelegationHelper.EvcPermit memory en = _permit(address(module), 2, _enablesData());

        // The tail is published with the order. A third party lifts it and tries to
        // land it directly — as the module's named sender, and as an any-sender.
        vm.startPrank(griefer);
        vm.expectRevert(MockEVC.EVC_NotAuthorized.selector);
        evc.permit(maker, address(module), op.nonceNamespace, op.nonce, op.deadline, 0, op.evcData, op.sig);
        vm.expectRevert(MockEVC.EVC_NotAuthorized.selector);
        evc.permit(maker, address(0), op.nonceNamespace, op.nonce, op.deadline, 0, op.evcData, op.sig);
        vm.stopPrank();
        _assertGrants(false);

        // The live fill of the maker's own order lands both.
        module.open(_tail2(op, en), address(evc), maker);
        _assertGrants(true);
        assertEq(evc.nonces(maker, 1), 1, "operator permit consumed");
        assertEq(evc.nonces(maker, 2), 1, "enables permit consumed");
    }

    /// L-ED-1: an ANY-SENDER permit is no longer honoured by the module — the
    /// replay names the module as sender, the digest commits to it, so a liftable
    /// `sender = 0` signature grants nothing through the fill. (Makers must not
    /// sign them at all: published, they are landable by anyone after a cancel.)
    function test_audit_L_ED_1_anySenderPermit_notReplayedByModule() public {
        DelegationHelper.EvcPermit memory op = _permit(address(0), 1, _bundledData());
        module.open(_tail1(op), address(evc), maker);
        _assertGrants(false);
        assertEq(evc.nonces(maker, 1), 0, "nothing landed");
    }

    /// L-ED-1 cancellation scenario end to end: the maker abandons the order and
    /// the published module-bound permit stays unlandable; the maker's revoke of a
    /// previously granted operator flag cannot be undone by a third party.
    function test_audit_L_ED_1_revokedOperator_notReinstalledByLiftedPermit() public {
        DelegationHelper.EvcPermit memory op = _permit(address(module), 1, _operatorData());
        // Operator granted earlier, then revoked by the maker directly.
        vm.prank(maker);
        evc.setAccountOperator(maker, address(module), true);
        vm.prank(maker);
        evc.setAccountOperator(maker, address(module), false);

        vm.prank(griefer);
        vm.expectRevert(MockEVC.EVC_NotAuthorized.selector);
        evc.permit(maker, address(module), op.nonceNamespace, op.nonce, op.deadline, 0, op.evcData, op.sig);
        assertFalse(evc.operator(maker, address(module)), "revoke is durable against lifted permit");
    }

    /// L-LIB-3: operator already set by other means (a manual grant, an earlier
    /// order). Each permit is replayed independently, so this order's enables land
    /// even though its operator permit reverts on the EVC's unchanged-status check.
    function test_audit_L_LIB_3_operatorAlreadySet_enablesStillLand() public {
        vm.prank(maker);
        evc.setAccountOperator(maker, address(module), true);

        DelegationHelper.EvcPermit memory op = _permit(address(module), 1, _operatorData());
        DelegationHelper.EvcPermit memory en = _permit(address(module), 2, _enablesData());
        module.open(_tail2(op, en), address(evc), maker);

        _assertGrants(true);
        assertEq(evc.nonces(maker, 1), 0, "operator permit reverted (unchanged status), nonce kept");
        assertEq(evc.nonces(maker, 2), 1, "enables permit landed");
    }

    /// L-LIB-3 control: the pre-fix bundled shape really does lose the enables
    /// when the operator is already set — the independent permits above are what
    /// fixes it, not a quirk of the model.
    function test_audit_L_LIB_3_control_bundledBatchLosesEnables() public {
        vm.prank(maker);
        evc.setAccountOperator(maker, address(module), true);

        module.open(_tail1(_permit(address(module), 1, _bundledData())), address(evc), maker);
        assertFalse(evc.controller(maker, BORROW_VAULT), "bundled: controller lost");
        assertFalse(evc.collateral(maker, COLLATERAL_VAULT), "bundled: collateral lost");
    }

    /// Already-landed permits (a re-fill, or the same order filled twice) stay a
    /// silent no-op — the best-effort guarantee is preserved.
    function test_audit_L_LIB_3_replayTwice_isNoOp() public {
        bytes memory tail =
            _tail2(_permit(address(module), 1, _operatorData()), _permit(address(module), 2, _enablesData()));
        module.open(tail, address(evc), maker);
        module.open(tail, address(evc), maker); // must not revert
        _assertGrants(true);
    }

    /// Absent tail ⇒ no-op, unchanged.
    function test_audit_L_ED_1_noTail_isNoOp() public {
        module.open("", address(evc), maker);
        _assertGrants(false);
    }
}

// ═════════════════════════ permit / delegation tests ═════════════════════════

contract Audit20260930PermitReplayTest is Test {
    LibReplayHarness harness;
    ValueBoundPermitToken token;
    ValueBoundDebtToken debt;

    address maker = address(0xA11CE);
    address spender = address(0x9E3D);
    address griefer = address(0xBADD);

    uint256 constant TOTAL = 1_000e18;

    function setUp() public {
        harness = new LibReplayHarness();
        token = new ValueBoundPermitToken();
        debt = new ValueBoundDebtToken();
    }

    function _permitTail() internal view returns (bytes memory) {
        return abi.encode(address(0xBA5E), address(0xBA5E2), block.timestamp + 1 days, uint8(27), bytes32(0), bytes32(0));
    }

    function _permitTailWithValue(uint256 value) internal view returns (bytes memory) {
        return bytes.concat(_permitTail(), abi.encode(value));
    }

    function _delegationTail() internal view returns (bytes memory) {
        return abi.encode(
            address(0xBA5E), address(0xBA5E2), address(debt), block.timestamp + 1 days, uint8(27), bytes32(0), bytes32(0)
        );
    }

    function _delegationTailWithValue(uint256 value) internal view returns (bytes memory) {
        return bytes.concat(_delegationTail(), abi.encode(value));
    }

    // ── L-LIB-4: set, not raise ──

    /// A maker holding a standing max approval to Permit3 appends a permit for the
    /// slice. The replay must NOT shrink the standing grant (it used to set it to
    /// the slice, and the pull spent it to 0 — breaking the maker's other orders).
    function test_audit_L_LIB_4_permitReplay_doesNotShrinkStandingAllowance() public {
        vm.prank(maker);
        token.approve(spender, type(uint256).max);
        token.sign(maker, spender, TOTAL);

        harness.replayPermit(_permitTail(), 64, address(token), maker, spender, TOTAL);
        assertEq(token.allowance(maker, spender), type(uint256).max, "standing max grant untouched");
        assertEq(token.nonces(maker), 0, "permit not consumed");
    }

    function test_audit_L_LIB_4_valuePermitReplay_doesNotShrinkStandingAllowance() public {
        vm.prank(maker);
        token.approve(spender, type(uint256).max);
        token.sign(maker, spender, TOTAL);

        bytes memory data = abi.encode(
            address(0xBA5E), address(0xBA5E2), TOTAL, block.timestamp + 1 days, uint8(27), bytes32(0), bytes32(0)
        );
        harness.replayValuePermit(data, 64, address(token), maker, spender);
        assertEq(token.allowance(maker, spender), type(uint256).max, "standing max grant untouched");
    }

    function test_audit_L_LIB_4_delegationReplay_doesNotShrinkStandingDelegation() public {
        vm.prank(maker);
        debt.approveDelegation(spender, type(uint256).max);
        debt.sign(maker, spender, TOTAL);

        harness.replayDelegation(_delegationTail(), 64, maker, spender, TOTAL);
        assertEq(debt.borrowAllowance(maker, spender), type(uint256).max, "standing max delegation untouched");
        assertEq(debt.nonces(maker), 0, "delegation not consumed");
    }

    /// Without a standing grant the replay still lands (the happy gasless path).
    function test_audit_L_LIB_4_noStandingGrant_permitStillLands() public {
        token.sign(maker, spender, TOTAL);
        harness.replayPermit(_permitTail(), 64, address(token), maker, spender, TOTAL);
        assertEq(token.allowance(maker, spender), TOTAL);
    }

    // ── L-AAVE-2: the signed value, so partial fills work ──

    /// Maker signs ONE permit for the item total and appends the value. A 40/60
    /// partial fill: slice 1 lands the total, slice 2 finds the remainder and
    /// skips. Pre-fix the replay signed over the SLICE, so slice 1's permit failed
    /// (signature commits to the total) and the gasless order could not partial-fill.
    function test_audit_L_AAVE_2_permitSignedValue_supportsPartialFills() public {
        token.sign(maker, spender, TOTAL);
        bytes memory data = _permitTailWithValue(TOTAL);

        uint256 slice1 = 400e18;
        harness.replayPermit(data, 64, address(token), maker, spender, slice1);
        assertEq(token.allowance(maker, spender), TOTAL, "slice 1: grant for the total landed");
        token.spend(maker, spender, slice1);

        uint256 slice2 = TOTAL - slice1;
        harness.replayPermit(data, 64, address(token), maker, spender, slice2);
        assertEq(token.allowance(maker, spender), slice2, "slice 2: remainder covers, replay skipped");
        token.spend(maker, spender, slice2);
        assertEq(token.allowance(maker, spender), 0);
    }

    function test_audit_L_AAVE_2_delegationSignedValue_supportsPartialFills() public {
        debt.sign(maker, spender, TOTAL);
        bytes memory data = _delegationTailWithValue(TOTAL);

        uint256 slice1 = 250e18;
        harness.replayDelegation(data, 64, maker, spender, slice1);
        assertEq(debt.borrowAllowance(maker, spender), TOTAL, "slice 1: delegation of the total landed");
        debt.borrow(maker, spender, slice1);

        uint256 slice2 = TOTAL - slice1;
        harness.replayDelegation(data, 64, maker, spender, slice2);
        debt.borrow(maker, spender, slice2); // reverts (underflow) if the remainder were missing
        assertEq(debt.borrowAllowance(maker, spender), 0);
    }

    /// Legacy 128/160-byte blocks (no value word) keep their old meaning: the
    /// replay signs over the slice — a full fill of exactly the signed amount works.
    function test_audit_L_AAVE_2_legacyBlock_fullFillStillWorks() public {
        token.sign(maker, spender, TOTAL);
        harness.replayPermit(_permitTail(), 64, address(token), maker, spender, TOTAL);
        assertEq(token.allowance(maker, spender), TOTAL);

        debt.sign(maker, spender, TOTAL);
        harness.replayDelegation(_delegationTail(), 64, maker, spender, TOTAL);
        assertEq(debt.borrowAllowance(maker, spender), TOTAL);
    }

    // ── L-CMT-3 (pin): the in-fill boolean replay must CONSUME the venue nonce
    //    even when the grant is already set, so the published signature dies with
    //    the fill instead of staying liftable to undo a later revoke. ──
    function test_audit_L_CMT_3_cometReplay_consumesNonceEvenWhenAlreadyAllowed() public {
        BoolSigVenue comet = new BoolSigVenue();
        vm.prank(maker);
        comet.allow(spender, true); // standing grant

        bytes memory data = abi.encode(
            address(0xBA5E), address(0xBA5E2), uint256(0), block.timestamp + 1 days, uint8(27), bytes32(0), bytes32(0)
        );
        harness.replayComet(data, 64, address(comet), maker, spender);
        assertEq(comet.userNonce(maker), 1, "signature consumed in-fill");

        // Maker later revokes; the lifted signature can no longer re-grant.
        vm.prank(maker);
        comet.allow(spender, false);
        vm.prank(griefer);
        vm.expectRevert(bytes("bad nonce"));
        comet.allowBySig(maker, spender, true, 0, block.timestamp + 1 days, 27, bytes32(0), bytes32(0));
        assertFalse(comet.isAllowed(maker, spender), "revoke durable");
    }
}

// ═════════════════════════ DustHandler (L-LIB-7 pin) ═════════════════════════

contract Audit20260930DustFloorTest is Test {
    LibReplayHarness harness;
    SimpleToken token;
    HalfSink sink;
    address user = address(0xA11CE);

    function setUp() public {
        harness = new LibReplayHarness();
        token = new SimpleToken();
        sink = new HalfSink();
    }

    /// The only remaining `disposeResidual` takes a floor; after a partial
    /// recycle it sweeps the remainder ABOVE the floor and keeps the stranded
    /// balance (the zero-floor overload that swept everything was deleted).
    function test_audit_L_LIB_7_recycleSweepsOnlyAboveFloor() public {
        uint256 stranded = 7e18;
        uint256 residual = 10e18;
        token.mint(address(harness), stranded + residual);

        harness.dispose(
            address(token),
            residual,
            stranded,
            user,
            DustHandler.DustAction.Recycle,
            address(sink),
            abi.encodeCall(HalfSink.take, (address(token), residual))
        );
        assertEq(token.balanceOf(address(sink)), residual / 2, "half recycled");
        assertEq(token.balanceOf(user), residual / 2, "remainder above floor swept");
        assertEq(token.balanceOf(address(harness)), stranded, "stranded balance retained");
    }
}
