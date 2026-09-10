// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {IMorphoAuth} from "@lib/interfaces/IMorphoAuth.sol";

import {ListaBrokerModule} from "../../src/ListaBrokerModule.sol";
import {ListaModulesBase, IListaBrokerViews} from "../shared/ListaModulesBase.t.sol";

/// @dev Views the deployed Moolah exposes around its Morpho-style sig-auth.
///      ⚠ Moolah renames Morpho's `DOMAIN_SEPARATOR()` view to
///      `domainSeparator()` (selector 0xf698da25; 0x3644e515 is absent from the
///      implementation) — the VALUE is Morpho's exact scheme:
///      keccak256(abi.encode(keccak256("EIP712Domain(uint256 chainId,address
///      verifyingContract)"), block.chainid, proxy)). `nonce(address)` and
///      `isAuthorized(address,address)` keep Morpho's names.
interface IMoolahAuthViews {
    function domainSeparator() external view returns (bytes32);
    function nonce(address authorizer) external view returns (uint256);
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
}

/// @dev BSC-fork validation that Lista's Moolah singleton accepts Morpho Blue's
///      `setAuthorizationWithSig` verbatim, and that the ListaTakerModule's
///      optional auth-block tail turns the Moolah `setAuthorization` grant into
///      a signature-only step (no prior on-chain tx from the maker).
contract MoolahAuthWithSigTest is ListaModulesBase {
    /// @dev Morpho Blue's authorization typehash — verified below against the
    ///      DEPLOYED Moolah by a successful direct `setAuthorizationWithSig`.
    bytes32 internal constant AUTHORIZATION_TYPEHASH =
        keccak256("Authorization(address authorizer,address authorized,bool isAuthorized,uint256 nonce,uint256 deadline)");

    uint256 constant COLLATERAL_IN = 0.1e18; //  BTCB the maker deposits
    uint256 constant BORROW_OUT = 1_000e18; //   USD1 the maker borrows

    // ──────────────────── Signing helper ────────────────────

    /// @dev Signs the Morpho-shaped authorization digest for `maker` → module
    ///      against the LIVE Moolah domain separator, returning the 160-byte
    ///      auth block `abi.encode(nonce, deadline, v, r, s)`.
    function _signMoolahAuth(address authorized, uint256 deadline) internal view returns (bytes memory block160) {
        uint256 nonce = IMoolahAuthViews(MOOLAH).nonce(maker);
        bytes32 structHash =
            keccak256(abi.encode(AUTHORIZATION_TYPEHASH, maker, authorized, true, nonce, deadline));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IMoolahAuthViews(MOOLAH).domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        block160 = abi.encode(nonce, deadline, v, r, s);
    }

    // ──────────────────── 1. Direct on-fork shape verification ────────────────────

    /// @dev Signs Morpho's AUTHORIZATION_TYPEHASH digest against the deployed
    ///      Moolah's `domainSeparator()` and submits `setAuthorizationWithSig`
    ///      directly (from an unrelated caller, as Morpho allows). Success pins:
    ///      typehash, struct layout, Signature{v,r,s} tuple, nonce view, and the
    ///      domain scheme — i.e. `DelegationHelper.replayMorphoAuth` fits as-is.
    function test_moolah_setAuthorizationWithSig_matchesMorphoShape() public {
        assertFalse(IMoolahAuthViews(MOOLAH).isAuthorized(maker, address(takerModule)), "fresh maker not authorized");
        uint256 nonceBefore = IMoolahAuthViews(MOOLAH).nonce(maker);

        uint256 deadline = block.timestamp + 1 days;
        bytes memory block160 = _signMoolahAuth(address(takerModule), deadline);
        (uint256 nonce,, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(block160, (uint256, uint256, uint8, bytes32, bytes32));

        vm.prank(solver); // anyone may relay the signed authorization
        IMorphoAuth(MOOLAH).setAuthorizationWithSig(
            IMorphoAuth.Authorization({
                authorizer: maker, authorized: address(takerModule), isAuthorized: true, nonce: nonce, deadline: deadline
            }),
            IMorphoAuth.Signature({v: v, r: r, s: s})
        );

        assertTrue(IMoolahAuthViews(MOOLAH).isAuthorized(maker, address(takerModule)), "authorization landed");
        assertEq(IMoolahAuthViews(MOOLAH).nonce(maker), nonceBefore + 1, "Morpho-style sequential nonce spent");
    }

    // ──────────────────── Tailed data blobs ────────────────────

    /// @dev {ListaBrokerModule} op-1 borrow data with the optional auth tail: base
    ///      96, moolah at 96, auth block at 128 (total 288). The auth target is the
    ///      BROKER module now — it is the contract the broker's on-behalf gate sees.
    function _borrowDataWithAuth(uint256 deadline) internal view returns (bytes memory) {
        return abi.encodePacked(
            abi.encode(uint8(ListaBrokerModule.Op.Borrow), BROKER, TERM_7D, MOOLAH),
            _signMoolahAuth(address(brokerModule), deadline)
        );
    }

    /// @dev op-1 Exact-mode withdraw data with the auth tail: base 224,
    ///      explicit BalanceMode (0 = Exact) at 224, auth block at 256 (total 416).
    function _withdrawDataWithAuth(uint256 deadline) internal view returns (bytes memory) {
        return abi.encodePacked(
            abi.encode(uint8(1), MOOLAH, _mp(), uint256(0)), _signMoolahAuth(address(takerModule), deadline)
        );
    }

    // ──────────────────── 2. Signature-only fixed-term borrow fill ────────────────────

    /// @dev The maker NEVER calls Moolah `setAuthorization` on-chain. The signed
    ///      auth block rides inside the borrow item's `data`; the module replays
    ///      it in-call, the broker's on-behalf gate passes, and the leverage fill
    ///      lands end-to-end. Companion no-tail tests (byte map unchanged):
    ///      {ListaDepositBorrowTest.test_supplyCollateral_and_fixedTermBorrow_lista}
    ///      and {…test_fixedTermBorrow_requiresMoolahAuthorization}.
    function test_fixedTermBorrow_sigOnlyAuth_noPriorSetAuthorization() public {
        deal(BTCB, solver, COLLATERAL_IN);
        bytes memory borrowData = _borrowDataWithAuth(block.timestamp + 1 days);

        // Maker grants: token pulls + the taker gate on the TAILED data ref.
        // Deliberately NO `IMoolah.setAuthorization` call anywhere.
        vm.startPrank(maker);
        IERC20(BTCB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(supplyModule), BTCB, uint160(COLLATERAL_IN), 0);
        permit3.approveTaker(address(settlement), address(brokerModule), keccak256(borrowData), uint160(BORROW_OUT), 0);
        IERC20(USD1).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USD1, uint160(BORROW_OUT), 0);
        vm.stopPrank();
        _approveSolverSide(COLLATERAL_IN, BTCB);

        assertFalse(IMoolahAuthViews(MOOLAH).isAuthorized(maker, address(brokerModule)), "no prior on-chain grant");

        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(supplyModule),
            amount: COLLATERAL_IN,
            recipient: address(0),
            data: _supplyData()
        });
        items[1] = Item({
            op: ItemOp.TAKE, module: address(brokerModule), amount: BORROW_OUT, recipient: address(0), data: borrowData
        });
        Order memory order = _order(maker, 1, USD1, BTCB, BORROW_OUT, COLLATERAL_IN, items);
        bytes memory sig = _sign(order);

        uint256 debtBefore = IListaBrokerViews(BROKER).getUserTotalDebt(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, BORROW_OUT)[0];
        assertEq(paid, COLLATERAL_IN, "solver paid the full collateral");

        // The signature became a live authorization, and the borrow landed on it.
        assertTrue(IMoolahAuthViews(MOOLAH).isAuthorized(maker, address(brokerModule)), "sig-auth replayed in-call");
        assertEq(_makerCollateral(), COLLATERAL_IN, "maker Moolah collateral up");
        assertGe(IListaBrokerViews(BROKER).getUserTotalDebt(maker) - debtBefore, BORROW_OUT, "broker debt opened");
        assertEq(IERC20(USD1).balanceOf(solver), BORROW_OUT, "solver received the borrow proceeds");
    }

    // ──────────────────── 3. Signature-only withdraw-collateral fill ────────────────────

    /// @dev Same signature-only grant on the op-1 Exact path (auth block at 256
    ///      after an explicitly-encoded BalanceMode). No-tail companion:
    ///      {ListaDepositBorrowTest.test_withdrawCollateral_take}.
    function test_withdrawCollateral_sigOnlyAuth() public {
        uint256 seeded = 0.1e18;
        uint256 withdrawAmount = 0.04e18;
        uint256 usd1Out = 4_000e18;

        _seedCollateral(seeded);
        deal(USD1, solver, usd1Out);

        bytes memory withdrawData = _withdrawDataWithAuth(block.timestamp + 1 days);

        vm.startPrank(maker);
        permit3.approveTaker(
            address(settlement), address(takerModule), keccak256(withdrawData), uint160(withdrawAmount), 0
        );
        IERC20(BTCB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), BTCB, uint160(withdrawAmount), 0);
        vm.stopPrank();
        _approveSolverSide(usd1Out, USD1);

        assertFalse(IMoolahAuthViews(MOOLAH).isAuthorized(maker, address(takerModule)), "no prior on-chain grant");

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(takerModule),
            amount: withdrawAmount,
            recipient: address(0),
            data: withdrawData
        });
        Order memory order = _order(maker, 2, BTCB, USD1, withdrawAmount, usd1Out, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, withdrawAmount);

        assertTrue(IMoolahAuthViews(MOOLAH).isAuthorized(maker, address(takerModule)), "sig-auth replayed in-call");
        assertEq(seeded - _makerCollateral(), withdrawAmount, "maker collateral down");
        assertEq(IERC20(BTCB).balanceOf(solver), withdrawAmount, "solver received BTCB");
        assertEq(IERC20(USD1).balanceOf(maker), usd1Out, "maker received USD1");
    }

    // ──────────────────── 4. Front-run of the auth sig is harmless ────────────────────

    /// @dev A griefer who lifts the signed block from pending calldata and lands
    ///      the authorization directly (spending the nonce) must NOT brick the
    ///      fill: the replay is best-effort try/catch, and the grant it wanted is
    ///      exactly the one the front-runner installed — the {DelegationHelper}
    ///      kill-switch reasoning, exercised against the DEPLOYED Moolah.
    function test_fixedTermBorrow_sigOnlyAuth_frontRunTolerated() public {
        deal(BTCB, solver, COLLATERAL_IN);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory borrowData = _borrowDataWithAuth(deadline);

        vm.startPrank(maker);
        IERC20(BTCB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(supplyModule), BTCB, uint160(COLLATERAL_IN), 0);
        permit3.approveTaker(address(settlement), address(brokerModule), keccak256(borrowData), uint160(BORROW_OUT), 0);
        IERC20(USD1).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USD1, uint160(BORROW_OUT), 0);
        vm.stopPrank();
        _approveSolverSide(COLLATERAL_IN, BTCB);

        // Front-runner relays the maker's authorization sig directly.
        (uint256 nonce,, uint8 v, bytes32 r, bytes32 s) = abi.decode(
            _slice(borrowData, 128, 160), (uint256, uint256, uint8, bytes32, bytes32)
        );
        vm.prank(address(0xBAD));
        IMorphoAuth(MOOLAH).setAuthorizationWithSig(
            IMorphoAuth.Authorization({
                authorizer: maker, authorized: address(brokerModule), isAuthorized: true, nonce: nonce, deadline: deadline
            }),
            IMorphoAuth.Signature({v: v, r: r, s: s})
        );
        assertTrue(IMoolahAuthViews(MOOLAH).isAuthorized(maker, address(brokerModule)), "front-runner spent the nonce");

        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(supplyModule),
            amount: COLLATERAL_IN,
            recipient: address(0),
            data: _supplyData()
        });
        items[1] = Item({
            op: ItemOp.TAKE, module: address(brokerModule), amount: BORROW_OUT, recipient: address(0), data: borrowData
        });
        Order memory order = _order(maker, 1, USD1, BTCB, BORROW_OUT, COLLATERAL_IN, items);
        bytes memory sig = _sign(order);

        // The in-call replay now reverts inside Moolah (spent nonce) — and is
        // swallowed; the fill still lands on the standing authorization.
        vm.prank(solver);
        settlement.fill(order, sig, BORROW_OUT);
        assertEq(_makerCollateral(), COLLATERAL_IN, "fill survived the front-run");
        assertEq(IERC20(USD1).balanceOf(solver), BORROW_OUT, "solver received the borrow proceeds");
    }

    // ──────────────────── util ────────────────────

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = data[start + i];
        }
    }
}
