// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, OrderSide, Item, ItemOp, Validator, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {LimitOrderLeverageSolver} from "@solvers/single-input/LimitOrderLeverageSolver.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Chains, Lenders} from "@coretest/data/LenderRegistry.sol";

import {IComet} from "../../src/interfaces/ICompoundV3.sol";
import {CometDepositModule, CometRepayModule, CometTakerModule} from "../../src/CompoundV3Modules.sol";

/// @dev Compound v3 (Comet) integration harness. Mirrors the Aave harness but
/// over Comet's position model: there are no aToken/debtToken ERC20s — supply,
/// borrow and collateral balances are read straight off the Comet contract, and
/// the value-out (withdraw/borrow) side is authorised with `comet.allow(module,
/// true)` instead of credit delegation + a receipt-token approval.
///
/// The primary market is the mainnet USDC Comet (base = USDC, collateral = WETH)
/// so the "WETH collateral / USDC debt" intent maps 1:1 to the Aave tests. The
/// USDS Comet is wired in too, as the migration target — its base token (USDS)
/// is chosen because it is a standard, bool-returning ERC20: Settlement pays the
/// solver `tokenIn` with a raw `transfer`, so the settled token must be ERC20-
/// return-compliant (USDT is not, and cannot be `tokenIn`). The dependency
/// points the right way: this package depends on the core package, never the
/// reverse.
abstract contract CompoundV3ModulesBase is CoreSettlementBase {
    CometDepositModule depositModule;
    CometTakerModule takerModule; //  combined withdraw + borrow (op-prefixed data)
    CometRepayModule repayModule;
    LimitOrderLeverageSolver leverageSolver;

    // op flags for the combined taker module's `data` prefix.
    uint8 internal constant OP_BORROW = uint8(CometTakerModule.Op.Borrow); //     0
    uint8 internal constant OP_WITHDRAW = uint8(CometTakerModule.Op.Withdraw); // 1

    /// @dev op-prefixed taker `data` for the borrow / withdraw legs. The op byte
    /// is the first word, so the two legs hash to distinct Permit3 refs.
    function _borrowData(address comet, address asset) internal pure returns (bytes memory) {
        return abi.encode(OP_BORROW, comet, asset);
    }

    function _withdrawData(address comet, address asset) internal pure returns (bytes memory) {
        return abi.encode(OP_WITHDRAW, comet, asset);
    }

    address COMET; //       USDC Comet — base USDC, WETH collateral
    address COMET_USDS; //  USDS Comet — migration target (base USDS, WETH collateral)
    address USDS; //        USDS Comet base token

    function setUp() public virtual override {
        super.setUp();

        COMET = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_USDC];
        COMET_USDS = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_USDS];
        USDS = IComet(COMET_USDS).baseToken();

        depositModule = new CometDepositModule(address(permit3), address(settlement));
        takerModule = new CometTakerModule(address(permit3));
        repayModule = new CometRepayModule(address(permit3), address(settlement));
        // Balancer v2 Vault + UniswapV3 SwapRouter — mainnet canonical addresses.
        leverageSolver = new LimitOrderLeverageSolver(
            address(permit3),
            address(settlement),
            0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            0xE592427A0AEce92De3Edee1F18E0157C05861564
        );

        vm.label(address(depositModule), "cometDepositModule");
        vm.label(address(takerModule), "cometTakerModule");
        vm.label(address(repayModule), "cometRepayModule");
        vm.label(address(leverageSolver), "leverageSolver");
        vm.label(COMET, "cometUSDC");
        vm.label(COMET_USDS, "cometUSDS");
        vm.label(USDS, "USDS");

        // Comet-native authorisation: let the combined taker module act on the
        // maker's USDC-Comet position (covers both withdraw and borrow legs). The
        // Permit3 taker allowance still caps each fill; this is just Comet's
        // permission boolean (infinite scope — see the README's note on `allow`'s
        // breadth).
        vm.prank(maker);
        IComet(COMET).allow(address(takerModule), true);
    }

    // ──────────────────── Position reads (no receipt tokens on Comet) ────────────────────

    function _wethCollateral(address who) internal view returns (uint256) {
        return uint256(IComet(COMET).collateralBalanceOf(who, WETH));
    }

    /// @dev Positive base (USDC) balance — the lend/earn position.
    function _baseSupply(address who) internal view returns (uint256) {
        return IComet(COMET).balanceOf(who);
    }

    function _usdcDebt(address who) internal view returns (uint256) {
        return IComet(COMET).borrowBalanceOf(who);
    }

    // ──────────────────── Position seeding ────────────────────

    function _seedWethCollateral(uint256 amount) internal {
        deal(WETH, maker, amount);
        vm.startPrank(maker);
        IERC20(WETH).approve(COMET, amount);
        IComet(COMET).supply(WETH, amount);
        vm.stopPrank();
    }

    /// @dev Maker supplies `amount` USDC as BASE asset (the earn position).
    function _seedBaseSupply(uint256 amount) internal {
        deal(USDC, maker, amount);
        vm.startPrank(maker);
        IERC20(USDC).approve(COMET, amount);
        IComet(COMET).supply(USDC, amount);
        vm.stopPrank();
    }

    /// @dev Maker supplies 10 WETH collateral + borrows `debt` USDC against it,
    ///      then dumps the borrowed USDC so the wallet starts clean.
    function _openUsdcDebt(uint256 debt) internal {
        deal(WETH, maker, 11 ether);
        vm.startPrank(maker);
        IERC20(WETH).approve(COMET, 10 ether);
        IComet(COMET).supply(WETH, 10 ether);
        IComet(COMET).withdraw(USDC, debt); // base withdraw past supply == borrow
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    /// @dev Maker supplies `collateral` WETH (+1 WETH kept in wallet) and borrows
    ///      `debt` USDC, dumping the proceeds so the wallet starts clean.
    function _openCometPosition(uint256 collateral, uint256 debt) internal {
        deal(WETH, maker, collateral + 1 ether);
        vm.startPrank(maker);
        IERC20(WETH).approve(COMET, collateral);
        IComet(COMET).supply(WETH, collateral);
        IComet(COMET).withdraw(USDC, debt);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    // ──────────────────── Approval helpers ────────────────────

    function _approveMakerSide(uint256 usdcCap, uint256 wethCap) internal {
        vm.startPrank(maker);
        // USDC: Settlement pulls tokenIn from maker on shortfall
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdcCap), 0);
        // WETH: the deposit module pulls WETH from maker during makeOnBehalf
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(wethCap), 0);
        vm.stopPrank();
    }

    function _approveMakerWithdrawSide(
        uint256 wethIn,
        bytes32 ref,
        bytes memory /* takerData */
    )
        internal
    {
        vm.startPrank(maker);
        // Fallback for _payTokenInToSolver — never triggers in this flow.
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(wethIn), 0);
        // No receipt-token pull on Comet: `comet.allow(withdrawModule)` (set in
        // setUp) is the protocol-native gate; the Permit3 taker allowance caps
        // the fill on the exact position.
        permit3.approveTaker(address(settlement), address(takerModule), ref, uint160(wethIn), 0);
        vm.stopPrank();
    }

    function _approveMakerDepositBorrowSide(uint256 collateralIn, uint256 borrowOut) internal {
        bytes memory borrowData = _borrowData(COMET, USDC);
        bytes32 borrowRef = keccak256(borrowData);

        vm.startPrank(maker);
        // WETH: deposit module pulls the collateral via Permit3 during MAKE.
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(collateralIn), 0);

        // Comet account-manager flag for the borrow module is granted in setUp;
        // the Permit3 taker allowance is what caps this borrow.
        permit3.approveTaker(address(settlement), address(takerModule), borrowRef, uint160(borrowOut), 0);

        // USDC fallback allowance for _payTokenInToSolver — never triggers here
        // since the borrow fully funds tokenIn, but keeps the shortfall path safe.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(borrowOut), 0);
        vm.stopPrank();
    }

    function _approveMakerRepaySide(uint256 bufferedAmount, uint256 wethForSolver) internal {
        vm.startPrank(maker);
        // tokenIn leg: maker pays WETH to solver via Permit3
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(wethForSolver), 0);
        // repay leg: repay module pulls USDC from maker
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(bufferedAmount), 0);
        vm.stopPrank();
    }

    function _approveMakerMigrationSide(uint256 bufferedRepay, uint256 exactWeth, uint256 borrowUsds) internal {
        vm.startPrank(maker);

        // [0] Repay leg: maker → repayModule pulls USDC via Permit3.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(bufferedRepay), 0);

        // [1] USDC-Comet withdraw leg: comet.allow(takerModule) set in setUp;
        //     Permit3 taker allowance caps the WETH pulled out.
        bytes memory withdrawData = _withdrawData(COMET, WETH);
        permit3.approveToken(address(settlement), WETH, uint160(exactWeth), 0);
        permit3.approveToken(address(settlement), USDC, uint160(bufferedRepay), 0);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(withdrawData), uint160(exactWeth), 0);

        // [2] USDS-Comet deposit leg: depositModule pulls WETH from maker.
        permit3.approveToken(address(depositModule), WETH, uint160(exactWeth), 0);

        // [3] USDS-Comet borrow leg: Comet account-manager flag + Permit3 cap.
        IComet(COMET_USDS).allow(address(takerModule), true);
        bytes memory borrowData = _borrowData(COMET_USDS, USDS);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(borrowData), uint160(borrowUsds), 0);

        vm.stopPrank();
    }

    // ──────────────────── Module order builders ────────────────────

    function _buildWithdrawOrder(uint256 wethIn, uint256 usdcOut, bytes memory takerData)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE, module: address(takerModule), amount: wethIn, recipient: address(0), data: takerData
        });
        order = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);
    }

    function _buildDepositBorrowOrder(uint256 collateralIn, uint256 borrowOut)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: collateralIn,
            recipient: address(0),
            data: abi.encode(COMET, WETH)
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(takerModule),
            amount: borrowOut,
            recipient: address(0),
            data: _borrowData(COMET, USDC)
        });
        order = _order(maker, 2, USDC, WETH, borrowOut, collateralIn, items);
    }

    function _buildRepayOrder(uint256 bufferedAmount, uint256 wethForSolver)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: bufferedAmount,
            recipient: address(0),
            data: abi.encode(COMET, USDC)
        });
        order = _order(maker, 3, WETH, USDC, wethForSolver, bufferedAmount, items);
    }

    /// @dev Migrate a USDC-Comet position to the USDS Comet in one order: repay
    /// USDC debt, move WETH collateral across, open USDS debt. Because the base
    /// asset differs between markets the swap leg is USDC (solver funds repay) →
    /// USDS (borrow proceeds pay solver), unlike the same-asset Aave→Spark case.
    function _buildMigrationOrder(uint256 bufferedRepay, uint256 exactWeth, uint256 borrowUsds)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](4);

        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: bufferedRepay,
            recipient: address(0),
            data: abi.encode(COMET, USDC)
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(takerModule),
            amount: exactWeth,
            recipient: maker, //          chain WETH into the deposit item
            data: _withdrawData(COMET, WETH)
        });
        items[2] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: exactWeth,
            recipient: address(0),
            data: abi.encode(COMET_USDS, WETH)
        });
        items[3] = Item({
            op: ItemOp.TAKE,
            module: address(takerModule),
            amount: borrowUsds,
            recipient: address(0), //      default = Settlement for tokenIn payout
            data: _borrowData(COMET_USDS, USDS)
        });

        order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 7,
            legsIn: _legsIn1(USDS, borrowUsds), //   Settlement pays solver from the USDS borrow proceeds
            legsOut: _legsOut1(USDC, bufferedRepay), // solver funds the USDC repay
            timing: _deadlineBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: _noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }
}
