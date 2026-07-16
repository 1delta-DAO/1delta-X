// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/UniversalSettlement.sol";
import {LimitOrderLeverageSolver} from "@solvers/single-input/LimitOrderLeverageSolver.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {
    IDolomiteMargin,
    AccountInfo,
    AssetAmount,
    AssetDenomination,
    AssetReference,
    WeiBalance,
    ActionType,
    ActionArgs,
    OperatorArg
} from "../../src/interfaces/IDolomite.sol";
import {
    DolomiteDepositModule,
    DolomiteRepayModule,
    DolomiteTakerModule,
    DolomiteOperateModule
} from "../../src/DolomiteModules.sol";

/// @dev Dolomite integration harness. DolomiteMargin deployed on mainnet after the
/// default harness block, so we pin a later fork. Drives the canonical WETH-
/// collateral / USDC-debt position (WETH = market 0, USDC = market 2) through the
/// single `operate` engine.
///
/// Two Dolomite nuances:
///   • Debt lives in a borrow-position SUB-ACCOUNT (non-zero number), not the main
///     "Dolomite balance" (account 0, lend-only). The modules carry the account
///     number in `data`, so the harness signs a non-zero one. (Unlike Aave there is
///     no explicit "enable collateral" — sub-account balances are collateral
///     implicitly.) Every module also needs the maker to authorise it as a local
///     operator — Dolomite has no permissionless value-in path.
///   • DolomiteMargin consults an on-chain `AccountRiskOverrideSetter` whenever an
///     account holds debt. On this mainnet deployment it only returns the default
///     `(0, 0)` override for positions set up through Dolomite's own borrow-position
///     machinery and reverts (`Invalid account for debt`) for raw test-built ones —
///     a DEPLOYMENT POLICY orthogonal to the module's `operate` encoding. The
///     debt-leg tests neutralise it via `_neutralizeRiskOverride()` so the full
///     `operate` (accounting, default solvency check, transfers) runs and exercises
///     the module end-to-end. Value-in / no-debt tests need no such shim.
abstract contract DolomiteModulesBase is CoreSettlementBase {
    IDolomiteMargin constant DOLOMITE = IDolomiteMargin(0x003Ca23Fd5F0ca87D01F6eC6CD14A8AE60c2b97D);

    address COLL; // WETH (collateral) — assigned from the registry in setUp
    address DEBT; // USDC (borrow)
    uint256 constant COLL_MARKET = 0; // WETH
    uint256 constant DEBT_MARKET = 2; // USDC
    // Debt lives in a borrow-position sub-account, NOT the main "Dolomite balance"
    // (account number 0), which is lend-only and rejected by the risk override.
    uint256 constant ACCOUNT = 1;

    DolomiteDepositModule depositModule;
    DolomiteRepayModule repayModule;
    DolomiteTakerModule takerModule;
    DolomiteOperateModule operateModule;
    LimitOrderLeverageSolver leverageSolver;

    /// @dev DolomiteMargin's account risk-override setter. On mainnet it gates which
    ///      collateral/debt category combinations may carry debt (an e-mode/isolation
    ///      DEPLOYMENT POLICY, not module logic) and reverts otherwise. For
    ///      uncategorised accounts it already returns the "no override" default
    ///      `(0, 0)`; the debt-leg tests force that default so the standard solvency
    ///      check applies and we exercise the module's `operate` encoding end-to-end
    ///      without depending on which exact pairs Dolomite has whitelisted.
    address constant RISK_OVERRIDE_SETTER = 0x7BCaF5253C417c84bBD1b7DfE4Ca4F0A4c4cA435;

    /// @dev Dolomite mainnet is live well before this block (deployed ~22.7M).
    function _forkBlock() internal view virtual override returns (uint256) {
        return 23_000_000;
    }

    /// @dev Neutralise the mainnet risk-override category gate (see above). Leaves
    ///      all real `operate` accounting/solvency/transfers intact.
    function _neutralizeRiskOverride() internal {
        vm.mockCall(
            RISK_OVERRIDE_SETTER,
            abi.encodeWithSignature("getAccountRiskOverride((address,uint256))"),
            abi.encode(uint256(0), uint256(0))
        );
    }

    function setUp() public virtual override {
        super.setUp();

        COLL = WETH;
        DEBT = USDC;

        depositModule = new DolomiteDepositModule(address(permit3), address(settlement));
        repayModule = new DolomiteRepayModule(address(permit3), address(settlement));
        takerModule = new DolomiteTakerModule(address(permit3));
        operateModule = new DolomiteOperateModule(address(permit3));
        // Balancer v2 Vault + UniswapV3 SwapRouter — mainnet canonical addresses.
        leverageSolver = new LimitOrderLeverageSolver(
            address(permit3),
            address(settlement),
            0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            0xE592427A0AEce92De3Edee1F18E0157C05861564
        );

        vm.label(address(DOLOMITE), "DolomiteMargin");
        vm.label(address(leverageSolver), "leverageSolver");
        vm.label(address(depositModule), "dolomiteDepositModule");
        vm.label(address(repayModule), "dolomiteRepayModule");
        vm.label(address(takerModule), "dolomiteTakerModule");
        vm.label(address(operateModule), "dolomiteOperateModule");

        // Dolomite-native authorisation: the maker makes each module a local
        // operator of their account. `operate` rejects any other caller; the
        // Permit3 allowance caps the per-fill amount.
        vm.startPrank(maker);
        OperatorArg[] memory ops = new OperatorArg[](4);
        ops[0] = OperatorArg(address(depositModule), true);
        ops[1] = OperatorArg(address(repayModule), true);
        ops[2] = OperatorArg(address(takerModule), true);
        ops[3] = OperatorArg(address(operateModule), true);
        DOLOMITE.setOperators(ops);
        vm.stopPrank();
    }

    // ──────────────────── Position reads ────────────────────

    function _collateralOf(address who) internal view returns (uint256) {
        WeiBalance memory w = DOLOMITE.getAccountWei(AccountInfo(who, ACCOUNT), COLL_MARKET);
        return w.sign ? w.value : 0;
    }

    function _debtOf(address who) internal view returns (uint256) {
        WeiBalance memory w = DOLOMITE.getAccountWei(AccountInfo(who, ACCOUNT), DEBT_MARKET);
        return w.sign ? 0 : w.value;
    }

    // ──────────────────── Position seeding ────────────────────

    /// @dev Maker supplies `amount` WETH collateral into the borrow-position
    ///      sub-account (no debt) via a one-action `operate`.
    function _seedDolomiteCollateral(uint256 amount) internal {
        deal(COLL, maker, amount);
        vm.startPrank(maker);
        IERC20(COLL).approve(address(DOLOMITE), amount);
        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(maker, ACCOUNT);
        ActionArgs[] memory actions = new ActionArgs[](1);
        actions[0] = ActionArgs({
            actionType: ActionType.Deposit,
            accountId: 0,
            amount: AssetAmount(true, AssetDenomination.Wei, AssetReference.Delta, amount),
            primaryMarketId: COLL_MARKET,
            secondaryMarketId: 0,
            otherAddress: maker,
            otherAccountId: 0,
            data: ""
        });
        DOLOMITE.operate(accounts, actions);
        vm.stopPrank();
    }

    /// @dev Maker supplies `collateral` USDC and borrows `debt` USD1 in one direct
    ///      `operate`, dumping the proceeds so the wallet starts clean.
    function _openDolomitePosition(uint256 collateral, uint256 debt) internal {
        deal(COLL, maker, collateral);
        vm.startPrank(maker);
        IERC20(COLL).approve(address(DOLOMITE), collateral);

        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(maker, ACCOUNT);
        ActionArgs[] memory actions = new ActionArgs[](2);
        actions[0] = ActionArgs({
            actionType: ActionType.Deposit,
            accountId: 0,
            amount: AssetAmount(true, AssetDenomination.Wei, AssetReference.Delta, collateral),
            primaryMarketId: COLL_MARKET,
            secondaryMarketId: 0,
            otherAddress: maker,
            otherAccountId: 0,
            data: ""
        });
        actions[1] = ActionArgs({
            actionType: ActionType.Withdraw,
            accountId: 0,
            amount: AssetAmount(false, AssetDenomination.Wei, AssetReference.Delta, debt),
            primaryMarketId: DEBT_MARKET,
            secondaryMarketId: 0,
            otherAddress: maker,
            otherAccountId: 0,
            data: ""
        });
        DOLOMITE.operate(accounts, actions);

        IERC20(DEBT).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    // ──────────────────── Order builders ────────────────────

    function _depositData() internal view returns (bytes memory) {
        return abi.encode(address(DOLOMITE), COLL_MARKET, COLL, ACCOUNT);
    }

    // Taker data is op-prefixed: op 0 = Borrow, op 1 = Withdraw. The op makes the
    // borrow/withdraw refs (keccak256(data)) distinct under the single module.
    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(uint8(DolomiteTakerModule.Op.Borrow), address(DOLOMITE), DEBT_MARKET, DEBT, ACCOUNT);
    }

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(uint8(DolomiteTakerModule.Op.Withdraw), address(DOLOMITE), COLL_MARKET, COLL, ACCOUNT);
    }

    function _buildDepositBorrowOrder(uint256 collateralIn, uint256 borrowOut)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(depositModule), collateralIn, address(0), _depositData());
        items[1] = Item(ItemOp.TAKE, address(takerModule), borrowOut, address(0), _borrowData());
        return _order(maker, 1, DEBT, COLL, borrowOut, collateralIn, items);
    }

    function _approveDepositBorrowSide(uint256 collateralIn, uint256 borrowOut) internal {
        vm.startPrank(maker);
        IERC20(COLL).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), COLL, uint160(collateralIn), 0);
        permit3.approveTaker(address(settlement), keccak256(_borrowData()), uint160(borrowOut), 0);
        IERC20(DEBT).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), DEBT, uint160(borrowOut), 0);
        vm.stopPrank();
    }
}
