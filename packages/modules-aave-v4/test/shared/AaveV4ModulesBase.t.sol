// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp} from "@core/settlement/LimitOrderSettlement.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {IGiverPositionManager, ITakerPositionManager, ISpokeV4} from "../../src/interfaces/IAaveV4.sol";
import {
    AaveV4DepositModule,
    AaveV4RepayModule,
    AaveV4WithdrawModule,
    AaveV4BorrowModule
} from "../../src/AaveV4Modules.sol";

/// @dev Reserve-id resolution surface, not part of the module interfaces.
interface IHubV4 {
    function getAssetId(address underlying) external view returns (uint256);
}

interface ISpokeReserves {
    function getReserveId(address hub, uint256 assetId) external view returns (uint256);
}

/// @dev Aave v4 integration harness — the v4 sibling of `AaveModulesBase`. Extends
/// the module-free `CoreSettlementBase` (which forks latest mainnet, where the v4
/// Hub/Spoke + position managers are live) and layers the v4 adapter fixtures plus
/// the position-seeding / approval / order-building helpers the action tests use.
///
/// v4 routes every action through a position manager the user approved on the
/// spoke (`setUserPositionManager`). MAKE ops (deposit/repay) go through the
/// GiverPositionManager and only need that approval + a Permit3 token allowance.
/// TAKE ops (withdraw/borrow) go through the TakerPositionManager and additionally
/// need a per-(spoke, reserveId) `approveWithdraw` / `approveBorrow` grant to the
/// module — the v4-native analogue of v3's aToken pull / credit delegation.
abstract contract AaveV4ModulesBase is CoreSettlementBase {
    AaveV4DepositModule depositModule;
    AaveV4WithdrawModule withdrawModule;
    AaveV4BorrowModule borrowModule;
    AaveV4RepayModule repayModule;

    // Aave V4 Ethereum mainnet addresses (live; position managers activated on the
    // Main Spoke). Mirrors the composer's AaveV4Lending fork test.
    address constant CORE_HUB = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
    address constant MAIN_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address constant GIVER_PM = 0x17A54b8d6D9C68e7fa1C7112AC998EA1BA51d11e;
    address constant TAKER_PM = 0x6c044c0D3801499bCAbfAd458B70880bc518e9F7;

    uint256 usdcReserveId;
    uint256 wethReserveId;

    /// @dev V4 Hub/Spoke + position managers were activated on the Main Spoke at
    ///      ~block 24_727_090; pin comfortably after that so they are live.
    function _forkBlock() internal view virtual override returns (uint256) {
        return 24_900_000;
    }

    function setUp() public virtual override {
        super.setUp();

        depositModule = new AaveV4DepositModule(address(permit3));
        withdrawModule = new AaveV4WithdrawModule(address(permit3));
        borrowModule = new AaveV4BorrowModule(address(permit3));
        repayModule = new AaveV4RepayModule(address(permit3));

        // Resolve reserve ids dynamically (avoids pinning to a block).
        usdcReserveId = ISpokeReserves(MAIN_SPOKE).getReserveId(CORE_HUB, IHubV4(CORE_HUB).getAssetId(USDC));
        wethReserveId = ISpokeReserves(MAIN_SPOKE).getReserveId(CORE_HUB, IHubV4(CORE_HUB).getAssetId(WETH));

        vm.label(address(depositModule), "aaveV4DepositModule");
        vm.label(address(withdrawModule), "aaveV4WithdrawModule");
        vm.label(address(borrowModule), "aaveV4BorrowModule");
        vm.label(address(repayModule), "aaveV4RepayModule");
        vm.label(CORE_HUB, "coreHub");
        vm.label(MAIN_SPOKE, "mainSpoke");
        vm.label(GIVER_PM, "giverPM");
        vm.label(TAKER_PM, "takerPM");
    }

    // ──────────────────── Position seeding ────────────────────

    /// @dev Maker supplies `amount` WETH collateral via the giver PM.
    function _seedV4WethPosition(uint256 amount) internal {
        deal(WETH, maker, amount);
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(GIVER_PM, true);
        IERC20(WETH).approve(GIVER_PM, amount);
        IGiverPositionManager(GIVER_PM).supplyOnBehalfOf(MAIN_SPOKE, wethReserveId, amount, maker);
        vm.stopPrank();
    }

    /// @dev Maker supplies 10 WETH collateral (+1 WETH kept in wallet for the
    ///      repay order's tokenIn leg) + borrows `debt` USDC, then dumps the
    ///      borrowed USDC so the wallet starts clean.
    function _openV4UsdcDebt(uint256 debt) internal {
        deal(WETH, maker, 11 ether);
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(GIVER_PM, true);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(TAKER_PM, true);
        IERC20(WETH).approve(GIVER_PM, 10 ether);
        IGiverPositionManager(GIVER_PM).supplyOnBehalfOf(MAIN_SPOKE, wethReserveId, 10 ether, maker);
        // v4 does not auto-enable supplied collateral — turn it on before borrowing.
        ISpokeV4(MAIN_SPOKE).setUsingAsCollateral(wethReserveId, true, maker);
        // Borrow as our own spender, then dump the proceeds.
        ITakerPositionManager(TAKER_PM).approveBorrow(MAIN_SPOKE, usdcReserveId, maker, debt);
        ITakerPositionManager(TAKER_PM).borrowOnBehalfOf(MAIN_SPOKE, usdcReserveId, debt, maker);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    // ──────────────────── Approval helpers ────────────────────

    function _approveMakerDepositBorrowSide(uint256 collateralIn, uint256 borrowOut) internal {
        bytes memory borrowData = abi.encode(MAIN_SPOKE, TAKER_PM, usdcReserveId, USDC);
        bytes32 borrowRef = keccak256(borrowData);

        vm.startPrank(maker);
        // Approve both position managers on the spoke (v4-native delegation).
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(GIVER_PM, true);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(TAKER_PM, true);
        // Enable WETH as collateral up front so the in-order deposit counts toward
        // the borrow's health factor (v4 has no auto-enable).
        ISpokeV4(MAIN_SPOKE).setUsingAsCollateral(wethReserveId, true, maker);

        // WETH: deposit module pulls the collateral via Permit3 during MAKE.
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(collateralIn), 0);

        // Borrow PM grant: lets the borrow module incur USDC debt on the maker.
        ITakerPositionManager(TAKER_PM).approveBorrow(MAIN_SPOKE, usdcReserveId, address(borrowModule), borrowOut);

        // Permit3 taker gate on the exact borrow position + amount.
        permit3.approveTaker(address(borrowModule), borrowRef, uint160(borrowOut), 0);

        // USDC fallback for _payTokenInToSolver — never triggers here.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(borrowOut), 0);
        vm.stopPrank();
    }

    function _approveMakerWithdrawSide(uint256 wethIn, bytes32 ref) internal {
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(TAKER_PM, true);

        // Fallback for _payTokenInToSolver — never triggers in this flow.
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(wethIn), 0);

        // Withdraw PM grant + Permit3 taker gate on the exact position.
        ITakerPositionManager(TAKER_PM).approveWithdraw(MAIN_SPOKE, wethReserveId, address(withdrawModule), wethIn);
        permit3.approveTaker(address(withdrawModule), ref, uint160(wethIn), 0);
        vm.stopPrank();
    }

    function _approveMakerRepaySide(uint256 bufferedAmount, uint256 wethForSolver) internal {
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(GIVER_PM, true);
        // tokenIn leg: maker pays WETH to solver via Permit3.
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(wethForSolver), 0);
        // repay leg: repay module pulls USDC from maker.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(bufferedAmount), 0);
        vm.stopPrank();
    }

    // ──────────────────── Module order builders ────────────────────

    function _buildV4DepositBorrowOrder(uint256 collateralIn, uint256 borrowOut)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: collateralIn,
            recipient: address(0),
            data: abi.encode(MAIN_SPOKE, GIVER_PM, wethReserveId, WETH)
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(borrowModule),
            amount: borrowOut,
            recipient: address(0),
            data: abi.encode(MAIN_SPOKE, TAKER_PM, usdcReserveId, USDC)
        });
        order = _order(maker, 2, USDC, WETH, borrowOut, collateralIn, items);
    }

    function _buildV4WithdrawOrder(uint256 wethIn, uint256 usdcOut, bytes memory takerData)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: wethIn,
            recipient: address(0),
            data: takerData
        });
        order = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);
    }

    function _buildV4RepayOrder(uint256 bufferedAmount, uint256 wethForSolver)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: bufferedAmount,
            recipient: address(0),
            data: abi.encode(MAIN_SPOKE, GIVER_PM, usdcReserveId, USDC)
        });
        order = _order(maker, 3, WETH, USDC, wethForSolver, bufferedAmount, items);
    }
}
