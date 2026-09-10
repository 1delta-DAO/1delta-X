// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Chains, Tokens} from "@coretest/data/LenderRegistry.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {SiloTakerModule} from "../../src/SiloModules.sol";
import {ISilo} from "../../src/interfaces/ISilo.sol";

/// @dev POSITION-SIZED FILLS ON SILO — the coverage gap the 2026-09-10 audit found.
///
/// `docs/position-sized-fills.md` declares seven `positionOf` readers; only three
/// (aave-v3, compound-v3, morpho-blue) had tests. The four untested ones were
/// exactly the four reading `maxWithdraw`, and two of the audit's top three findings
/// lived in that gap. This closes silo's half.
///
/// The headline is `test_positionOf_isRawPosition_notMaxWithdraw`: it opens a
/// LEVERED position so `maxWithdraw` is solvency-clipped strictly below the real
/// balance, then asserts `positionOf` reports the raw one. That assertion FAILED
/// before the fix — and because `resolveFill` runs BEFORE a close's own repay item,
/// the clipped number was what a `[repay, withdraw]` close got priced at: the close
/// half-exited while SUCCEEDING, and `AlreadyFilled` then spent the maker's order.
contract SiloPositionSizedTest is CoreSettlementBase {
    // Silo v2 wstETH/WETH market, Ethereum mainnet — same pins as the leverage suite.
    address internal constant SILO_WSTETH = 0x1a132e4e90D66E2f4FCDc99420F204D46F907aDB;
    address internal constant SILO_WETH = 0x02AE6A64a0DC17ffFDC5722Ad8270a7B32Be44db;

    address internal WSTETH;

    SiloTakerModule internal takerModule;
    PositionFillModule internal fillModule;

    address internal liquidityProvider = address(0x11D0);

    uint256 internal constant COLLATERAL = 5 ether;
    uint256 internal constant DEBT = 2 ether;
    uint256 internal constant CAP = 5.25 ether;
    uint256 internal constant QUOTE = 6 ether;

    function _forkBlock() internal view virtual override returns (uint256) {
        return 25_600_000;
    }

    function setUp() public virtual override {
        super.setUp();

        WSTETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH];
        takerModule = new SiloTakerModule(address(permit3));
        fillModule = new PositionFillModule();

        vm.label(SILO_WSTETH, "siloWstETH");
        vm.label(SILO_WETH, "siloWETH");
        vm.label(WSTETH, "wstETH");
        vm.label(address(fillModule), "positionFillModule");

        // Borrowable WETH liquidity — organic depth at the pin is too thin.
        deal(WETH, liquidityProvider, 25 ether);
        vm.startPrank(liquidityProvider);
        IERC20(WETH).approve(SILO_WETH, type(uint256).max);
        ISilo(SILO_WETH).deposit(25 ether, liquidityProvider);
        vm.stopPrank();
    }

    // ──────────────────── Fixtures ────────────────────

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(uint8(1), SILO_WSTETH, WSTETH);
    }

    /// @dev The RAW position: share balance converted at the current rate. This is
    ///      what `positionOf` must report; `maxWithdraw` is a different number once
    ///      there is debt or the vault is short of cash.
    function _rawPosition(address who) internal view returns (uint256) {
        return ISilo(SILO_WSTETH).previewRedeem(ISilo(SILO_WSTETH).balanceOf(who));
    }

    function _supplyCollateral(uint256 amount) internal {
        deal(WSTETH, maker, amount);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(SILO_WSTETH, amount);
        ISilo(SILO_WSTETH).deposit(amount, maker);
        vm.stopPrank();
    }

    /// @dev Supply AND borrow, so `maxWithdraw` is solvency-clipped.
    function _openLevered() internal {
        _supplyCollateral(COLLATERAL);
        vm.startPrank(maker);
        ISilo(SILO_WETH).borrow(DEBT, maker, maker);
        IERC20(WETH).transfer(address(0xdead), DEBT); // wallet starts clean
        vm.stopPrank();
    }

    /// @dev The withdraw grant is an ERC-20 SHARE allowance to the module (the silo
    ///      is its own collateral share token) — not the debt-share receive approval
    ///      the borrow leg needs.
    function _approveMaker(bytes memory data, uint256 cap) internal {
        vm.startPrank(maker);
        IERC20(SILO_WSTETH).approve(address(takerModule), type(uint256).max);
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WSTETH, uint160(cap), 0);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(data), uint160(cap), 0);
        vm.stopPrank();
    }

    function _positionOrder(uint256 nonce) internal view returns (Order memory order) {
        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(takerModule), amount: CAP, recipient: address(0), data: _withdrawData()});
        order = _order(maker, nonce, WSTETH, WETH, CAP, QUOTE, items);
        order.fillModule = address(fillModule);
        order.fillTotal = CAP;
    }

    // ──────────────────── The audit regression ────────────────────

    /// @dev FINDING 1 REGRESSION. Asserts BOTH halves, so it cannot pass by
    /// coincidence: that `maxWithdraw` really is clipped here, and that `positionOf`
    /// reports the raw figure anyway.
    function test_positionOf_isRawPosition_notMaxWithdraw() public {
        _openLevered();

        uint256 raw = _rawPosition(maker);
        uint256 reachable = ISilo(SILO_WSTETH).maxWithdraw(maker);

        assertGt(raw, 0, "position exists");
        assertLt(reachable, raw, "maxWithdraw IS clipped by the open debt: the finding premise");

        (address asset, uint256 reported) = takerModule.positionOf(maker, _withdrawData());
        assertEq(asset, ISilo(SILO_WSTETH).asset(), "asset read from the vault");
        assertEq(reported, raw, "positionOf reports the RAW position");
        assertGt(reported, reachable, "and therefore NOT maxWithdraw");
    }

    /// @dev And the number the fill is priced at is that same raw one.
    function test_resolveFill_pricesOffTheRawPosition() public {
        _openLevered();
        _approveMaker(_withdrawData(), CAP);

        Order memory order = _positionOrder(1);
        (uint256 delta,,) = lens.previewFill(order, order.fillTotal, solver, "");

        assertEq(delta, _rawPosition(maker), "delta is the raw position");
        assertGt(delta, ISilo(SILO_WSTETH).maxWithdraw(maker), "not the solvency-clipped figure");
    }

    // ──────────────────── End to end ────────────────────

    function test_positionSized_withdraw_sellsWholePosition() public {
        _supplyCollateral(COLLATERAL);
        _approveMaker(_withdrawData(), CAP);
        deal(WETH, solver, QUOTE);
        _approveSolverSide(QUOTE, WETH);

        Order memory order = _positionOrder(2);
        bytes memory sig = _sign(order);

        (uint256 delta,,) = lens.previewFill(order, order.fillTotal, solver, "");
        assertEq(delta, _rawPosition(maker), "sized from the live position");
        assertLt(delta, CAP, "below the cap, so a partial fill");

        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, delta)[0];

        assertEq(paid, (delta * QUOTE + CAP - 1) / CAP, "paid pro rata (ceilDiv, as Pricing does)");
        assertEq(IERC20(WETH).balanceOf(maker) - makerWethBefore, paid, "maker received it");
        assertApproxEqAbs(IERC20(WSTETH).balanceOf(solver), delta, 2, "solver bought the position");
        assertLe(_rawPosition(maker), 2, "position fully exited");
        assertEq(IERC20(WSTETH).balanceOf(address(takerModule)), 0, "module drained");
        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement drained");
    }

    /// @dev FINDING 2 REGRESSION on this venue. A `Full` leg short of the signed
    /// amount must REVERT, not deliver less and let `Core._payInputsToSolver` bill
    /// the shortfall to the maker's wallet.
    function test_fullMode_shortPosition_revertsInsteadOfBillingTheMaker() public {
        _supplyCollateral(1 ether); //  only 1 wstETH held
        uint256 signed = 3 ether; //    the order asks for 3

        bytes memory data = abi.encode(
            uint8(1), SILO_WSTETH, WSTETH, DustHandler.encodeMode(DustHandler.BalanceMode.Full), signed
        );
        _approveMaker(data, signed);

        vm.prank(address(permit3));
        vm.expectRevert(); // ShortWithdraw, or the venue on insufficient shares
        takerModule.takeOnBehalf(maker, signed, address(settlement), data);
    }
}
