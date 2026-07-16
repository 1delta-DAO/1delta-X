// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/UniversalSettlement.sol";
import {LimitOrderLeverageSolver} from "@solvers/single-input/LimitOrderLeverageSolver.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {ICErc20, ICompoundV2Comptroller} from "../../src/interfaces/ICompoundV2.sol";
import {
    CompoundV2DepositModule,
    CompoundV2RepayModule,
    CompoundV2WithdrawModule
} from "../../src/CompoundV2Modules.sol";

/// @dev Compound v2 integration harness — all ops EXCEPT borrow (vanilla Compound
/// v2 has no `borrowBehalf`, so a router can't borrow for a user). Forks mainnet
/// at the default block and drives the canonical Compound v2 markets:
///
///   cUSDC (underlying USDC) — collateral leg
///   cDAI  (underlying DAI)  — debt / second-collateral leg
///
/// Authorisation: deposit/repay are permissionless value-in (the module funds
/// `mint`/`repayBorrowBehalf` — no grant). withdraw pulls the user's cTokens, so
/// the maker infinite-approves the cToken to the withdraw module via Permit3 (the
/// Aave-aToken pattern); the Permit3 taker allowance caps each fill.
abstract contract CompoundV2ModulesBase is CoreSettlementBase {
    ICompoundV2Comptroller constant COMPTROLLER = ICompoundV2Comptroller(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    ICErc20 constant CUSDC = ICErc20(0x39AA39c021dfbaE8faC545936693aC917d5E7563);
    ICErc20 constant CDAI = ICErc20(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643);
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    CompoundV2DepositModule depositModule;
    CompoundV2RepayModule repayModule;
    CompoundV2WithdrawModule withdrawModule;
    LimitOrderLeverageSolver leverageSolver;

    function setUp() public virtual override {
        super.setUp();

        depositModule = new CompoundV2DepositModule(address(permit3), address(settlement));
        repayModule = new CompoundV2RepayModule(address(permit3), address(settlement));
        withdrawModule = new CompoundV2WithdrawModule(address(permit3));
        // Balancer v2 Vault + UniswapV3 SwapRouter — mainnet canonical addresses.
        leverageSolver = new LimitOrderLeverageSolver(
            address(permit3),
            address(settlement),
            0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            0xE592427A0AEce92De3Edee1F18E0157C05861564
        );

        vm.label(address(COMPTROLLER), "Comptroller");
        vm.label(address(CUSDC), "cUSDC");
        vm.label(address(CDAI), "cDAI");
        vm.label(DAI, "DAI");
        vm.label(address(depositModule), "compoundV2DepositModule");
        vm.label(address(repayModule), "compoundV2RepayModule");
        vm.label(address(withdrawModule), "compoundV2WithdrawModule");
        vm.label(address(leverageSolver), "leverageSolver");

        // Enter both markets so supplied cTokens count as collateral. deposit/repay
        // need no grant; the withdraw module pulls cTokens via the Permit3 token
        // allowance set per-test.
        vm.startPrank(maker);
        address[] memory markets = new address[](2);
        markets[0] = address(CUSDC);
        markets[1] = address(CDAI);
        COMPTROLLER.enterMarkets(markets);
        vm.stopPrank();
    }

    // ──────────────────── Position reads ────────────────────

    function _usdcCollateral(address who) internal view returns (uint256) {
        return CUSDC.balanceOf(who) * CUSDC.exchangeRateStored() / 1e18;
    }

    function _daiCollateral(address who) internal view returns (uint256) {
        return CDAI.balanceOf(who) * CDAI.exchangeRateStored() / 1e18;
    }

    function _daiDebt(address who) internal view returns (uint256) {
        return CDAI.borrowBalanceStored(who);
    }

    // ──────────────────── Position seeding ────────────────────

    /// @dev Maker supplies `amount` USDC into cUSDC as collateral (self-mint —
    ///      `mint` acts on msg.sender, no on-behalf needed for seeding).
    function _seedUsdcCollateral(uint256 amount) internal {
        deal(USDC, maker, amount);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(CUSDC), amount);
        _callOk(address(CUSDC), abi.encodeWithSignature("mint(uint256)", amount), "seed mint");
        vm.stopPrank();
    }

    /// @dev Maker supplies `collateral` USDC and borrows `debt` DAI directly,
    ///      dumping the proceeds so the wallet starts clean.
    function _openDaiDebt(uint256 collateral, uint256 debt) internal {
        _seedUsdcCollateral(collateral);
        vm.startPrank(maker);
        _callOk(address(CDAI), abi.encodeWithSignature("borrow(uint256)", debt), "seed borrow");
        IERC20(DAI).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    /// @dev Low-level call that reverts on a failed call OR a non-zero Compound code.
    function _callOk(address target, bytes memory cd, string memory what) private {
        (bool ok, bytes memory ret) = target.call(cd);
        require(ok, what);
        require(ret.length < 32 || abi.decode(ret, (uint256)) == 0, what);
    }

    // ──────────────────── Order data ────────────────────

    function _withdrawUsdcData() internal view returns (bytes memory) {
        return abi.encode(address(CUSDC), USDC);
    }

    function _depositDaiData() internal pure returns (bytes memory) {
        return abi.encode(address(CDAI), DAI);
    }

    function _repayDaiData() internal pure returns (bytes memory) {
        return abi.encode(address(CDAI), DAI);
    }
}
