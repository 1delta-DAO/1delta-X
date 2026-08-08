// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {Settlement, Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {ListaSupplyCollateralModule, ListaTakerModule} from "../../src/ListaModules.sol";
import {IMoolah, MarketParams, MarketParamsLib, Id} from "../../src/interfaces/ILista.sol";

/// @dev Broker views used only by the tests (not part of the module surface).
interface IListaBrokerViews {
    /// @notice principal + all accrued interest — the authoritative user debt.
    function getUserTotalDebt(address user) external view returns (uint256);
    /// @notice fixed-term menu: [termId, durationSecs, (1+r)*1e27][]
    function getFixedTerms() external view returns (uint256[3][] memory);
}

/// @dev BSC-mainnet fork harness for the Lista (Moolah + LendingBroker) modules.
///
///  Reuses CoreSettlementBase's EIP-712 order machinery/builders but overrides
///  `setUp` entirely: forks BNB Chain instead of Ethereum and deploys the Lista
///  adapters against the live Moolah singleton + a brokered market.
///
///  ── Market choice: USD1/BTCB, NOT the flagship slisBNB/WBNB ──
///
///  Lista's Moolah diverges from Morpho Blue with a per-market, per-token
///  `providers[id][token]` gate (verified in the deployed implementation
///  0x9321…B79A): when a provider is registered for a market's COLLATERAL token,
///  `supplyCollateral` requires `msg.sender == provider` and `withdrawCollateral`
///  requires `msg.sender == provider && receiver == provider` — both revert
///  `"not provider"` for any module. The slisBNB/WBNB market (id 0x2269…3cac) has
///  provider 0x33f7…​ registered for slisBNB, so the collateral legs of the
///  package are structurally unusable THERE. An on-chain scan of all 225 Lista
///  markets found 20 brokered ones; the USD1/BTCB market below is brokered with
///  NO provider on either token, an empty per-market whitelist, and ~450k USD1
///  of free liquidity — the collateral legs behave exactly like Morpho Blue.
///
///  Verified on-chain facts (2026-07-30, block ~113.02M):
///    • Moolah (Morpho-fork singleton): 0x8F73…5D8C
///    • USD1/BTCB brokered market id
///      0x8de2e1f3e3935024a2667d8203983bdff70a1aee0c91665760e02c257d53032f =
///      keccak256(abi.encode(MarketParams(USD1, BTCB, 0x41E2…7981, 0x5F9f…97E6, 0.86e18)))
///    • `Moolah.brokers(id)` = 0x41E2…7981 — the broker doubles as the market's
///      oracle entry (same address in both slots; true for every brokered market).
///    • `broker.getFixedTerms()` = [[1, 7d, ~4.2% APR], [2, 14d, ~4.1%], [3, 30d, 2%]]
///    • the on-behalf `borrow(uint256,uint256,address,address)` selector
///      (0x3d5d4a9e) is present in the broker implementation and reverts
///      `NotAuthorized()` (0xea8e4eb5) for an unauthorized caller.
abstract contract ListaModulesBase is CoreSettlementBase {
    using MarketParamsLib for MarketParams;

    // ──────────────────── Verified BSC mainnet addresses ────────────────────

    address internal constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
    address internal constant BROKER = 0x41E2a8C0f0e60ec228735a9ACDe704ff73df7981;
    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address internal constant IRM = 0x5F9f9173B405C6CEAfa7f98d09e4B8447e9797E6;
    uint256 internal constant LLTV = 0.86e18;

    /// @dev 7-day fixed-term product (termId 1) from the live getFixedTerms menu.
    uint256 internal constant TERM_7D = 1;

    ListaSupplyCollateralModule internal supplyModule;
    ListaTakerModule internal takerModule;

    function setUp() public virtual override {
        _forkBsc();

        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));

        supplyModule = new ListaSupplyCollateralModule(address(permit3), address(settlement));
        takerModule = new ListaTakerModule(address(permit3));

        vm.label(maker, "maker");
        vm.label(solver, "solver");
        vm.label(address(permit3), "permit3");
        vm.label(address(settlement), "settlement");
        vm.label(address(supplyModule), "listaSupplyModule");
        vm.label(address(takerModule), "listaTakerModule");
        vm.label(MOOLAH, "moolah");
        vm.label(BROKER, "listaBroker");
        vm.label(USD1, "USD1");
        vm.label(BTCB, "BTCB");
    }

    // ──────────────────── Fork helper ────────────────────

    /// @dev Recent BSC block (2026-07-30). Archive-capable gateways are listed
    ///      first so lazy state reads at the pinned block don't hit pruned nodes.
    uint256 internal constant BSC_FORK_BLOCK = 113_020_000;

    function _forkBsc() internal {
        try vm.envString("BSC_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0) {
                try this.__forkAt(v, BSC_FORK_BLOCK) {
                    return;
                } catch {}
            }
        } catch {}

        // blastapi first: the only probed PUBLIC gateway serving the full
        // account/storage/code surface at historical blocks (drpc 500s,
        // publicnode 403s archive depth, 1rpc/dataseed prune state).
        string[4] memory rpcs = [
            "https://bsc-mainnet.public.blastapi.io",
            "https://bsc.drpc.org",
            "https://1rpc.io/bnb",
            "https://bsc-dataseed.binance.org"
        ];
        for (uint256 i = 0; i < rpcs.length; i++) {
            try this.__forkAt(rpcs[i], BSC_FORK_BLOCK) {
                return;
            } catch {}
        }
        revert("ListaModulesBase: no working BSC RPC (set BSC_RPC_URL to bypass)");
    }

    /// @dev External self-call so a reverting `createSelectFork` is catchable.
    function __forkAt(string calldata rpc, uint256 blockNumber) external {
        vm.createSelectFork(rpc, blockNumber);
    }

    // ──────────────────── Market fixtures ────────────────────

    /// @dev The USD1/BTCB brokered Moolah market (id 0x8de2…032f).
    ///      NOTE: the market's oracle slot holds the BROKER address.
    function _mp() internal pure returns (MarketParams memory) {
        return MarketParams({loanToken: USD1, collateralToken: BTCB, oracle: BROKER, irm: IRM, lltv: LLTV});
    }

    function _marketId() internal pure returns (Id) {
        return _mp().id();
    }

    function _makerCollateral() internal view returns (uint256) {
        return IMoolah(MOOLAH).position(_marketId(), maker).collateral;
    }

    /// @dev data blob of the fixed-term broker borrow TAKE leg (op 0).
    function _borrowData() internal pure returns (bytes memory) {
        return abi.encode(uint8(0), BROKER, TERM_7D);
    }

    /// @dev data blob of the withdraw-collateral TAKE leg (op 1, Exact mode).
    function _withdrawData() internal pure returns (bytes memory) {
        return abi.encode(uint8(1), MOOLAH, _mp());
    }

    /// @dev data blob of the supply-collateral MAKE leg (base = 192, no permit).
    function _supplyData() internal pure returns (bytes memory) {
        return abi.encode(MOOLAH, _mp());
    }

    // ──────────────────── Position seeding ────────────────────

    /// @dev Maker supplies `amount` BTCB collateral directly (no modules).
    function _seedCollateral(uint256 amount) internal {
        deal(BTCB, maker, amount);
        vm.startPrank(maker);
        IERC20(BTCB).approve(MOOLAH, amount);
        IMoolah(MOOLAH).supplyCollateral(_mp(), amount, maker, "");
        vm.stopPrank();
    }

    // ──────────────────── Approvals ────────────────────

    /// @dev Everything the maker must grant for the [supply MAKE, borrow TAKE]
    ///      leverage order. `authorizeMoolah = false` leaves out the protocol
    ///      grant so the auth-required test can prove the broker enforces it.
    function _approveMakerDepositBorrowSide(uint256 collateralIn, uint256 borrowOut, bool authorizeMoolah) internal {
        vm.startPrank(maker);
        // BTCB: the supply module pulls the collateral via Permit3 during MAKE.
        IERC20(BTCB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(supplyModule), BTCB, uint160(collateralIn), 0);

        // Protocol-native grant: the broker's on-behalf borrow is gated by the
        // maker's Moolah authorization of the calling module.
        if (authorizeMoolah) IMoolah(MOOLAH).setAuthorization(address(takerModule), true);

        // Permit3 taker gate on the exact borrow position + amount.
        permit3.approveTaker(address(settlement), keccak256(_borrowData()), uint160(borrowOut), 0);

        // USD1 fallback allowance for the tokenIn shortfall path — never triggers
        // here (the borrow fully funds tokenIn) but keeps the flow shaped like
        // the reference harness.
        IERC20(USD1).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USD1, uint160(borrowOut), 0);
        vm.stopPrank();
    }

    function _approveMakerWithdrawSide(uint256 withdrawAmount) internal {
        vm.startPrank(maker);
        // Withdraw-collateral runs through the same Moolah authorization.
        IMoolah(MOOLAH).setAuthorization(address(takerModule), true);
        permit3.approveTaker(address(settlement), keccak256(_withdrawData()), uint160(withdrawAmount), 0);
        // Fallback for the tokenIn shortfall path — never triggers here.
        IERC20(BTCB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), BTCB, uint160(withdrawAmount), 0);
        vm.stopPrank();
    }

    // ──────────────────── Order builders ────────────────────

    /// @dev [MAKE supply BTCB collateral, TAKE fixed-term borrow USD1]:
    ///      tokenIn = USD1 (maker gives — sourced from the borrow item),
    ///      tokenOut = BTCB (solver gives → forwarded into the supply item).
    function _buildDepositBorrowOrder(uint256 collateralIn, uint256 borrowOut)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(supplyModule),
            amount: collateralIn,
            recipient: address(0),
            data: _supplyData()
        });
        items[1] = Item({
            op: ItemOp.TAKE, module: address(takerModule), amount: borrowOut, recipient: address(0), data: _borrowData()
        });
        order = _order(maker, 1, USD1, BTCB, borrowOut, collateralIn, items);
    }

    /// @dev [TAKE withdraw BTCB collateral]: tokenIn = BTCB (sourced from the
    ///      withdraw item), tokenOut = USD1 (solver pays the maker).
    function _buildWithdrawOrder(uint256 withdrawAmount, uint256 usd1Out) internal view returns (Order memory order) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(takerModule),
            amount: withdrawAmount,
            recipient: address(0),
            data: _withdrawData()
        });
        order = _order(maker, 2, BTCB, USD1, withdrawAmount, usd1Out, items);
    }
}
