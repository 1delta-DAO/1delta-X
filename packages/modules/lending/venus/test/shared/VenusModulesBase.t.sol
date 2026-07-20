// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {LimitOrderLeverageSolver} from "@solvers/single-input/LimitOrderLeverageSolver.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {IVToken, IVenusComptroller} from "../../src/interfaces/IVenus.sol";
import {VenusDepositModule, VenusRepayModule, VenusTakerModule} from "../../src/VenusModules.sol";

/// @dev Venus (expanded Compound v2) integration harness. Forks mainnet at the
/// default block — the Venus Core pool is live there — and drives a WETH-collateral
/// / USDC-debt position, mirroring the Aave/Comet/Euler harnesses:
///
///   collateral market = vWETH (underlying WETH)
///   borrow     market = vUSDC (underlying USDC)
///
/// Venus authorisation splits by direction. deposit/repay are permissionless
/// value-in (the module funds `mintBehalf`/`repayBorrowBehalf` for the user — no
/// grant needed). borrow/withdraw are value-out: the maker calls
/// `comptroller.updateDelegate(module, true)` once and enters the collateral
/// market; the Permit3 allowances still cap every fill.
abstract contract VenusModulesBase is CoreSettlementBase {
    IVenusComptroller constant COMPTROLLER = IVenusComptroller(0x687a01ecF6d3907658f7A7c714749fAC32336D1B);
    IVToken constant VWETH = IVToken(0x7c8ff7d2A1372433726f879BD945fFb250B94c65); // collateral
    IVToken constant VUSDC = IVToken(0x17C07e0c232f2f80DfDbd7a95b942D893A4C5ACb); // borrow

    VenusDepositModule depositModule;
    VenusRepayModule repayModule;
    VenusTakerModule takerModule;
    LimitOrderLeverageSolver leverageSolver;

    function setUp() public virtual override {
        super.setUp();

        depositModule = new VenusDepositModule(address(permit3), address(settlement));
        repayModule = new VenusRepayModule(address(permit3), address(settlement));
        takerModule = new VenusTakerModule(address(permit3));
        // Balancer v2 Vault + UniswapV3 SwapRouter — mainnet canonical addresses.
        leverageSolver = new LimitOrderLeverageSolver(
            address(permit3),
            address(settlement),
            0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            0xE592427A0AEce92De3Edee1F18E0157C05861564
        );

        vm.label(address(COMPTROLLER), "VenusComptroller");
        vm.label(address(VWETH), "vWETH");
        vm.label(address(VUSDC), "vUSDC");
        vm.label(address(depositModule), "venusDepositModule");
        vm.label(address(repayModule), "venusRepayModule");
        vm.label(address(takerModule), "venusTakerModule");
        vm.label(address(leverageSolver), "leverageSolver");

        // Venus-native authorisation: enter the collateral market, then delegate the
        // value-out modules so `borrowBehalf`/`redeemUnderlyingBehalf` are permitted.
        // deposit/repay need no grant (permissionless value-in).
        vm.startPrank(maker);
        address[] memory markets = new address[](2);
        markets[0] = address(VWETH);
        markets[1] = address(VUSDC);
        COMPTROLLER.enterMarkets(markets);
        COMPTROLLER.updateDelegate(address(takerModule), true);
        vm.stopPrank();
    }

    // ──────────────────── Position reads ────────────────────

    /// @dev Underlying value of the maker's vWETH collateral (view via stored rate).
    function _wethCollateral(address who) internal view returns (uint256) {
        return VWETH.balanceOf(who) * VWETH.exchangeRateStored() / 1e18;
    }

    function _usdcDebt(address who) internal view returns (uint256) {
        return VUSDC.borrowBalanceStored(who);
    }

    // ──────────────────── Position seeding ────────────────────

    /// @dev Maker supplies `amount` WETH into vWETH as collateral (no borrow).
    ///      `mint`/`borrow` act on `msg.sender`, so the maker self-supplies here —
    ///      no on-behalf/delegation needed for seeding. Both return a Compound
    ///      error code (0 == success), checked below.
    function _seedVenusCollateral(uint256 amount) internal {
        deal(WETH, maker, amount);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(VWETH), amount);
        _callOk(address(VWETH), abi.encodeWithSignature("mint(uint256)", amount), "seed mint");
        vm.stopPrank();
    }

    /// @dev Maker supplies `collateral` WETH and borrows `debt` USDC directly,
    ///      dumping the proceeds so the wallet starts clean.
    function _openVenusPosition(uint256 collateral, uint256 debt) internal {
        _seedVenusCollateral(collateral);
        vm.startPrank(maker);
        _callOk(address(VUSDC), abi.encodeWithSignature("borrow(uint256)", debt), "seed borrow");
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    /// @dev Low-level call that reverts on a failed call OR a non-zero Compound code.
    function _callOk(address target, bytes memory cd, string memory what) private {
        (bool ok, bytes memory ret) = target.call(cd);
        require(ok, what);
        require(ret.length < 32 || abi.decode(ret, (uint256)) == 0, what);
    }

    // ──────────────────── Order builders ────────────────────

    function _depositData() internal view returns (bytes memory) {
        return abi.encode(address(VWETH), WETH);
    }

    /// @dev Combined taker data, op-prefixed. op = 0 (Borrow), 1 (Withdraw); the
    ///      op flag makes borrow/withdraw refs (keccak256(data)) distinct.
    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(uint8(VenusTakerModule.Op.Borrow), address(VUSDC), USDC);
    }

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(uint8(VenusTakerModule.Op.Withdraw), address(VWETH), WETH);
    }

    /// @dev Deposit `collateralIn` WETH + borrow `borrowOut` USDC in one order.
    ///      tokenIn = USDC (from the borrow), tokenOut = WETH (from the solver).
    function _buildDepositBorrowOrder(uint256 collateralIn, uint256 borrowOut)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(depositModule), collateralIn, address(0), _depositData());
        items[1] = Item(ItemOp.TAKE, address(takerModule), borrowOut, address(0), _borrowData());
        return _order(maker, 1, USDC, WETH, borrowOut, collateralIn, items);
    }

    function _approveDepositBorrowSide(uint256 collateralIn, uint256 borrowOut) internal {
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(collateralIn), 0);
        permit3.approveTaker(address(settlement), keccak256(_borrowData()), uint160(borrowOut), 0);
        // USDC fallback for the tokenIn shortfall path (never triggers here).
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(borrowOut), 0);
        vm.stopPrank();
    }
}
