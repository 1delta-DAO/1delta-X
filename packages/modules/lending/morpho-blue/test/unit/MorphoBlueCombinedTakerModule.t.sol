// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MorphoBlueTakerModule} from "../../src/MorphoBlueModules.sol";
import {MarketParams} from "../../src/interfaces/IMorphoBlue.sol";

// Reuse the mocks + helper from the split-module unit test.
import {MockERC20, MockMorpho, MockPermit3, dummyMarketParams} from "./MorphoBlueTakerModulesTest.t.sol";

// ── MorphoBlueTakerModule (combined borrow + withdraw) tests ──────────────────
//
// The combined module multiplexes both taker legs behind a leading `op` flag.
// These tests assert: (1) each op reaches the right Morpho call, (2) the op flag
// shifts every downstream offset by 32 bytes (auth block / BalanceMode), and
// (3) an unknown op fails closed.
contract MorphoBlueCombinedTakerModuleTest is Test {
    MockERC20 loanToken;
    MockERC20 collateralToken;
    MockMorpho morpho;
    MockPermit3 permit3;
    MorphoBlueTakerModule module;
    MarketParams market;

    address user = address(0xABCD);
    address receiver = address(0xCAFE);
    uint256 constant BORROW = 1000e6;
    uint256 constant WITHDRAW = 500e18;

    uint8 constant OP_BORROW = 0;
    uint8 constant OP_WITHDRAW = 1;
    uint8 constant OP_WITHDRAW_LOAN = 2;

    function setUp() public {
        loanToken = new MockERC20();
        collateralToken = new MockERC20();
        morpho = new MockMorpho(loanToken, collateralToken);
        permit3 = new MockPermit3();
        module = new MorphoBlueTakerModule(address(permit3), address(morpho));
        market = dummyMarketParams(address(loanToken), address(collateralToken));

        morpho.setPositionCollateral(market, user, uint128(WITHDRAW * 10));
        morpho.setPositionSupplyShares(market, user, WITHDRAW * 10);
    }

    // ── Borrow leg (op = 0) ───────────────────────────────────────────────────

    function test_borrow_withAuthSig() public {
        // data = abi.encode(op, MarketParams, nonce, deadline, v, r, s)
        bytes memory data = abi.encode(
            OP_BORROW, market, uint256(0), block.timestamp + 1 hours, uint8(27), bytes32(0), bytes32(0)
        );

        vm.prank(address(permit3));
        module.takeOnBehalf(user, BORROW, receiver, data);

        assertTrue(morpho.authWithSigCalled(), "setAuthorizationWithSig not called");
        assertEq(morpho.lastAuthorizer(), user);
        assertEq(morpho.lastAuthorized(), address(module));
        assertEq(loanToken.balanceOf(receiver), BORROW);
    }

    function test_borrow_withoutSig_standingAuth() public {
        vm.prank(user);
        morpho.setAuthorization(address(module), true);

        bytes memory data = abi.encode(OP_BORROW, market);

        vm.prank(address(permit3));
        module.takeOnBehalf(user, BORROW, receiver, data);

        assertFalse(morpho.authWithSigCalled());
        assertEq(loanToken.balanceOf(receiver), BORROW);
    }

    function test_borrow_revertsIfNotAuthorizedAndNoSig() public {
        bytes memory data = abi.encode(OP_BORROW, market);
        vm.prank(address(permit3));
        vm.expectRevert("morpho: not authorized");
        module.takeOnBehalf(user, BORROW, receiver, data);
    }

    // ── Withdraw leg (op = 1) ─────────────────────────────────────────────────

    function test_withdraw_withAuthSig() public {
        // data = abi.encode(op, MarketParams, BalanceMode=0, nonce, deadline, v, r, s)
        bytes memory data = abi.encode(
            OP_WITHDRAW,
            market,
            uint8(0), // BalanceMode = Exact, explicit slot required ahead of the auth block
            uint256(0), block.timestamp + 1 hours, uint8(27), bytes32(0), bytes32(0)
        );

        vm.prank(address(permit3));
        module.takeOnBehalf(user, WITHDRAW, receiver, data);

        assertTrue(morpho.authWithSigCalled());
        assertEq(morpho.lastAuthorizer(), user);
        assertEq(morpho.lastAuthorized(), address(module));
        assertEq(collateralToken.balanceOf(receiver), WITHDRAW);
    }

    function test_withdraw_withoutSig_standingAuth() public {
        vm.prank(user);
        morpho.setAuthorization(address(module), true);

        bytes memory data = abi.encode(OP_WITHDRAW, market);

        vm.prank(address(permit3));
        module.takeOnBehalf(user, WITHDRAW, receiver, data);

        assertFalse(morpho.authWithSigCalled());
        assertEq(collateralToken.balanceOf(receiver), WITHDRAW);
    }

    function test_withdraw_fullMode_sweepsExcess() public {
        vm.prank(user);
        morpho.setAuthorization(address(module), true);

        // BalanceMode = Full (1): withdraw entire collateral, forward `amount`,
        // sweep the rest back to the user.
        uint256 total = WITHDRAW * 10;
        bytes memory data = abi.encode(OP_WITHDRAW, market, uint8(1));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, WITHDRAW, receiver, data);

        assertEq(collateralToken.balanceOf(receiver), WITHDRAW, "receiver got signed amount");
        assertEq(collateralToken.balanceOf(user), total - WITHDRAW, "excess swept to user");
        assertEq(collateralToken.balanceOf(address(module)), 0, "module retains nothing");
    }

    // ── Loan-withdraw leg (op = 2) ────────────────────────────────────────────

    function test_withdrawLoan_withAuthSig() public {
        // Same byte map as op 1: BalanceMode slot ahead of the auth block.
        bytes memory data = abi.encode(
            OP_WITHDRAW_LOAN,
            market,
            uint8(0), // BalanceMode = Exact, explicit slot required ahead of the auth block
            uint256(0), block.timestamp + 1 hours, uint8(27), bytes32(0), bytes32(0)
        );

        vm.prank(address(permit3));
        module.takeOnBehalf(user, WITHDRAW, receiver, data);

        assertTrue(morpho.authWithSigCalled());
        assertEq(morpho.lastAuthorizer(), user);
        assertEq(morpho.lastAuthorized(), address(module));
        assertEq(loanToken.balanceOf(receiver), WITHDRAW, "loan asset withdrawn to receiver");
    }

    function test_withdrawLoan_withoutSig_standingAuth() public {
        vm.prank(user);
        morpho.setAuthorization(address(module), true);

        bytes memory data = abi.encode(OP_WITHDRAW_LOAN, market);

        vm.prank(address(permit3));
        module.takeOnBehalf(user, WITHDRAW, receiver, data);

        assertFalse(morpho.authWithSigCalled());
        assertEq(loanToken.balanceOf(receiver), WITHDRAW);
    }

    function test_withdrawLoan_fullMode_sweepsExcess() public {
        vm.prank(user);
        morpho.setAuthorization(address(module), true);

        // BalanceMode = Full (1): redeem the entire supply by shares, forward
        // `amount`, sweep the accrued excess back to the user.
        uint256 total = WITHDRAW * 10;
        bytes memory data = abi.encode(OP_WITHDRAW_LOAN, market, uint8(1));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, WITHDRAW, receiver, data);

        assertEq(loanToken.balanceOf(receiver), WITHDRAW, "receiver got signed amount");
        assertEq(loanToken.balanceOf(user), total - WITHDRAW, "excess swept to user");
        assertEq(loanToken.balanceOf(address(module)), 0, "module retains nothing");
    }

    // ── Cross-cutting ─────────────────────────────────────────────────────────

    function test_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(OP_BORROW, market);
        vm.expectRevert(MorphoBlueTakerModule.OnlyPermit3.selector);
        module.takeOnBehalf(user, BORROW, receiver, data);
    }

    function test_revertsOnUnknownOp() public {
        bytes memory data = abi.encode(uint8(3), market);
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(MorphoBlueTakerModule.BadOp.selector, uint8(3)));
        module.takeOnBehalf(user, BORROW, receiver, data);
    }

    /// @dev All three legs must hash to different Permit3 refs — the whole point
    ///      of putting the op flag inside `data`.
    function test_opFlagSeparatesRefs() public view {
        bytes memory borrowData = abi.encode(OP_BORROW, market);
        bytes memory withdrawData = abi.encode(OP_WITHDRAW, market);
        bytes memory loanWithdrawData = abi.encode(OP_WITHDRAW_LOAN, market);
        assertTrue(keccak256(borrowData) != keccak256(withdrawData), "refs must differ by op");
        assertTrue(keccak256(withdrawData) != keccak256(loanWithdrawData), "loan leg ref must differ");
    }
}
