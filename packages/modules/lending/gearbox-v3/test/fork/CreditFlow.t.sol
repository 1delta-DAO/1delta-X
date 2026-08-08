// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {
    GearboxCreditAddCollateralModule,
    GearboxCreditBorrowModule,
    GearboxCreditRepayModule,
    GearboxCreditAuth
} from "../../src/GearboxV3Modules.sol";
import {MultiCall} from "../../src/interfaces/IGearboxV3.sol";

// ──────────────────── v3.1 facade surface used by the TEST only ────────────────────
//
// The deployed wstETH suite is CreditFacadeV3 `version() == 3_10`. Verified against
// the live contract (cast probes at the pinned block):
//   • `openCreditAccount(address,(address,bytes)[],uint256)` — external, in dispatcher
//   • `multicall(address,(address,bytes)[])` / `botMulticall(...)` — external
//   • `setBotPermissions(address,address,uint192)` — EXTERNAL owner surface
//     (the multicall-inner `setBotPermissions(address,uint192)` recipe in the
//     module comments also dispatches on this facade; the test grants through the
//     multicall as the docs describe)
interface ICreditFacadeV31 {
    function openCreditAccount(address onBehalfOf, MultiCall[] calldata calls, uint256 referralCode)
        external
        payable
        returns (address creditAccount);
    function multicall(address creditAccount, MultiCall[] calldata calls) external payable;
    function setBotPermissions(address creditAccount, address bot, uint192 permissions) external;
    function debtLimits() external view returns (uint128 minDebt, uint128 maxDebt);
}

/// @dev The multicall-inner grant op (v3.1: bots are (re)registered inside the
///      owner's own multicall).
interface ICreditFacadeV31Multicall {
    function setBotPermissions(address bot, uint192 permissions) external;
}

interface ICreditManagerV31 {
    function creditAccountInfo(address creditAccount)
        external
        view
        returns (
            uint256 debt,
            uint256 cumulativeIndexLastUpdate,
            uint128 cumulativeQuotaInterest,
            uint128 quotaFees,
            uint256 enabledTokensMask,
            uint16 flags,
            uint64 lastDebtUpdate,
            address borrower
        );
}

/// @title GearboxCreditFlowTest
/// @notice Ethereum-mainnet fork validation of the credit-account modules' REAL
///         fund-flow — the part `src/GearboxV3Modules.sol` flags as "still
///         unvalidated on a fork". `GearboxV3ForkAuth.t.sol` pins the auth chain;
///         this file opens a live credit account, registers the modules as bots
///         with their exact `requiredPermissions()` masks, and drives all three
///         credit multicalls (add-collateral MAKE, borrow TAKE, and the new
///         repay MAKE) against the deployed wstETH credit suite.
///
///  Direct module calls with pranked settlement / spender senders — this
///  validates the Gearbox interaction, not the settlement plumbing (which has
///  its own tests in the core package).
///
///  Facts of the pinned deployment (probed at FORK_BLOCK):
///    • facade/manager `version() == 3_10` (Gearbox v3.1)
///    • underlying = wstETH, `debtLimits() = (20e18, 1000e18)`
///    • `liquidationThresholds(wstETH) = 95.00%`, degenNFT = 0 (permissionless)
///    • pool `availableLiquidity()` ≈ 896 wstETH — plenty for a 25 wstETH draw
///
///  Gearbox rules the flow has to respect (and thereby demonstrates):
///    • BotListV3 enforces mask == `bot.requiredPermissions()` EXACTLY
///      (`test_botGrant_requiresExactMask`);
///    • debt may be updated once per block per account — each debt-touching step
///      runs after `vm.roll(block.number + 1)`;
///    • after `decreaseDebt` the remaining debt must be 0 or ≥ minDebt, so the
///      partial repay leaves ≥ 20 wstETH and the close test repays the exact
///      live debt read from `creditAccountInfo`.
contract GearboxCreditFlowTest is Test {
    // ── deployed wstETH credit suite (same as GearboxV3ForkAuth.t.sol) ──
    address internal constant CREDIT_MANAGER = 0x9fB5493dEb601A0329ad8bFF43cD182a61321ca7;
    address internal constant CREDIT_FACADE = 0xE667676B28C270f5478299CF136Db5407Bf384Ce;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    uint256 internal constant FORK_BLOCK = 25_600_000;

    // 60 in, borrow 25 (minDebt = 20), repay 4 → 21 stays ≥ minDebt.
    uint256 internal constant COLLATERAL = 60e18;
    uint256 internal constant BORROW = 25e18;
    uint256 internal constant REPAY = 4e18;

    Permit3 internal permit3;
    GearboxCreditAddCollateralModule internal addModule;
    GearboxCreditRepayModule internal repayModule;
    GearboxCreditBorrowModule internal borrowModule;

    address internal user;
    uint256 internal userPk;
    address internal settlement = address(0x5E77);
    address internal solver = address(0x50C7E5);

    address internal creditAccount;

    // ──────────────── fork plumbing (CoreSettlementBase pattern) ────────────────

    function _forkMainnet() internal {
        try vm.envString("ETH_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        string[3] memory rpcs = [
            "https://gateway.tenderly.co/public/mainnet", "https://eth.drpc.org", "https://ethereum-rpc.publicnode.com"
        ];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryFork(rpcs[i])) return;
        }
        revert("GearboxCreditFlow: no archive-capable mainnet RPC (set ETH_RPC_URL)");
    }

    function _tryFork(string memory rpc) internal returns (bool) {
        try this.__fork(rpc) {
            return true;
        } catch {
            return false;
        }
    }

    function __fork(string calldata rpc) external {
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    // ──────────────── setup: open a real account, register the bots ────────────────

    function setUp() public {
        _forkMainnet();

        (user, userPk) = makeAddrAndKey("gearbox-user");

        permit3 = new Permit3();
        addModule = new GearboxCreditAddCollateralModule(address(permit3), settlement);
        repayModule = new GearboxCreditRepayModule(address(permit3), settlement);
        borrowModule = new GearboxCreditBorrowModule(address(permit3));

        vm.label(CREDIT_MANAGER, "CreditManager");
        vm.label(CREDIT_FACADE, "CreditFacade");
        vm.label(WSTETH, "wstETH");

        deal(WSTETH, user, 200e18);

        // 1. Open a fresh zero-debt credit account for the user via the real facade.
        vm.prank(user);
        creditAccount = ICreditFacadeV31(CREDIT_FACADE).openCreditAccount(user, new MultiCall[](0), 0);
        vm.label(creditAccount, "creditAccount");
        assertEq(_borrowerOf(creditAccount), user, "account opened for user");

        // 2. Register the three modules as bots with their EXACT masks, through the
        //    owner's own facade multicall (the grant recipe from the module docs).
        _grantBot(address(addModule), addModule.requiredPermissions());
        _grantBot(address(repayModule), repayModule.requiredPermissions());
        _grantBot(address(borrowModule), borrowModule.requiredPermissions());

        // 3. Permit3 plumbing for the two MAKE modules (token book) and the
        //    TAKE module (taker book, granted per-test on the exact data ref).
        vm.startPrank(user);
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(addModule), WSTETH, type(uint160).max, 0);
        permit3.approveToken(address(repayModule), WSTETH, type(uint160).max, 0);
        vm.stopPrank();
    }

    function _grantBot(address bot, uint192 mask) internal {
        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: CREDIT_FACADE, callData: abi.encodeCall(ICreditFacadeV31Multicall.setBotPermissions, (bot, mask))
        });
        vm.prank(user);
        ICreditFacadeV31(CREDIT_FACADE).multicall(creditAccount, calls);
    }

    // ──────────────── views ────────────────

    function _debtOf(address ca) internal view returns (uint256 debt) {
        (debt,,,,,,,) = ICreditManagerV31(CREDIT_MANAGER).creditAccountInfo(ca);
    }

    function _borrowerOf(address ca) internal view returns (address borrower) {
        (,,,,,,, borrower) = ICreditManagerV31(CREDIT_MANAGER).creditAccountInfo(ca);
    }

    function _caBalance() internal view returns (uint256) {
        return IERC20(WSTETH).balanceOf(creditAccount);
    }

    function _data() internal view returns (bytes memory) {
        return abi.encode(creditAccount, WSTETH);
    }

    // ──────────────── module drivers ────────────────

    /// MAKE: settlement calls the add-collateral module; funds pulled from the
    /// user through the Permit3 token book.
    function _makeAddCollateral(uint256 amount) internal {
        vm.prank(settlement);
        addModule.makeOnBehalf(user, amount, _data());
    }

    /// TAKE: dispatched through Permit3's taker book exactly like Settlement
    /// would — user approves (spender = settlement, ref = keccak(data)), the
    /// spender calls `take`, Permit3 invokes the module.
    function _takeBorrow(uint256 amount, address receiver) internal {
        bytes memory data = _data();
        vm.prank(user);
        permit3.approveTaker(settlement, keccak256(data), type(uint160).max, 0);
        vm.prank(settlement);
        permit3.take(address(borrowModule), user, uint160(amount), receiver, data);
    }

    /// MAKE: settlement calls the NEW repay module — botMulticall([addCollateral,
    /// decreaseDebt]).
    function _makeRepay(uint256 amount) internal {
        vm.prank(settlement);
        repayModule.makeOnBehalf(user, amount, _data());
    }

    // ──────────────── the flow ────────────────

    /// The end-to-end fund-flow of all three credit modules on live Gearbox:
    /// add-collateral MAKE → borrow TAKE → (new) repay MAKE, with debt/collateral
    /// deltas asserted through the credit manager after every leg.
    function test_creditFlow_addCollateral_borrow_repay() public {
        // ── leg 1: add-collateral MAKE ──
        uint256 userBefore = IERC20(WSTETH).balanceOf(user);
        _makeAddCollateral(COLLATERAL);

        assertEq(_caBalance(), COLLATERAL, "collateral landed in the credit account");
        assertEq(userBefore - IERC20(WSTETH).balanceOf(user), COLLATERAL, "pulled exactly `amount` from the user");
        assertEq(_debtOf(creditAccount), 0, "no debt yet");
        assertEq(IERC20(WSTETH).balanceOf(address(addModule)), 0, "add module holds nothing");
        assertEq(IERC20(WSTETH).allowance(address(addModule), CREDIT_MANAGER), 0, "add module granted nothing");

        // ── leg 2: borrow TAKE (separate block: once-per-block debt update) ──
        vm.roll(block.number + 1);
        _takeBorrow(BORROW, solver);

        assertEq(IERC20(WSTETH).balanceOf(solver), BORROW, "borrow proceeds routed to the receiver");
        assertEq(_debtOf(creditAccount), BORROW, "debt == drawn amount (fresh index)");
        assertEq(_caBalance(), COLLATERAL, "increaseDebt in + withdrawCollateral out nets to zero on the CA");

        // ── leg 3: the NEW repay MAKE (separate block again) ──
        vm.roll(block.number + 1);
        userBefore = IERC20(WSTETH).balanceOf(user);
        _makeRepay(REPAY);

        assertEq(_debtOf(creditAccount), BORROW - REPAY, "decreaseDebt burned exactly `amount`");
        assertEq(userBefore - IERC20(WSTETH).balanceOf(user), REPAY, "pulled exactly `amount` from the user");
        assertEq(_caBalance(), COLLATERAL, "addCollateral in + decreaseDebt burn nets to zero on the CA");
        assertEq(IERC20(WSTETH).balanceOf(address(repayModule)), 0, "repay module holds nothing");
        assertEq(IERC20(WSTETH).allowance(address(repayModule), CREDIT_MANAGER), 0, "repay module granted nothing");

        // remaining debt (21 wstETH) respects minDebt (20 wstETH)
        (uint128 minDebt,) = ICreditFacadeV31(CREDIT_FACADE).debtLimits();
        assertGe(_debtOf(creditAccount), minDebt, "partial repay left >= minDebt");
    }

    /// Full close through the repay module: repay the EXACT live debt read from
    /// `creditAccountInfo` (vm.roll does not advance time, so no interest accrues
    /// between the draw and the repay) — `decreaseDebt` to zero is the one value
    /// below minDebt Gearbox accepts.
    function test_repayModule_closesFullDebt() public {
        _makeAddCollateral(COLLATERAL);
        vm.roll(block.number + 1);
        _takeBorrow(BORROW, user); // proceeds to the user: they fund the repay

        vm.roll(block.number + 1);
        uint256 debt = _debtOf(creditAccount);
        assertEq(debt, BORROW, "no time elapsed, no interest accrued");

        _makeRepay(debt);

        assertEq(_debtOf(creditAccount), 0, "debt fully closed");
        assertEq(_caBalance(), COLLATERAL, "collateral untouched by the close");
        assertEq(IERC20(WSTETH).balanceOf(address(repayModule)), 0, "repay module holds nothing");
    }

    /// The exact-mask rule the module docs rely on, proven on the REAL BotListV3:
    /// granting anything other than `requiredPermissions()` reverts, so a maker
    /// cannot accidentally hand the deposit-only bot borrow rights.
    function test_botGrant_requiresExactMask() public {
        uint192 wrong = addModule.requiredPermissions() | GearboxCreditAuth.INCREASE_DEBT_PERMISSION;
        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: CREDIT_FACADE,
            callData: abi.encodeCall(ICreditFacadeV31Multicall.setBotPermissions, (address(addModule), wrong))
        });
        vm.prank(user);
        vm.expectRevert();
        ICreditFacadeV31(CREDIT_FACADE).multicall(creditAccount, calls);
    }

    /// Pin the masks the fork flow was granted with — the values in the docs.
    function test_requiredPermissions_masks() public view {
        assertEq(addModule.requiredPermissions(), 0x01, "add-collateral mask");
        assertEq(repayModule.requiredPermissions(), 0x05, "repay mask (ADD_COLLATERAL | DECREASE_DEBT)");
        assertEq(borrowModule.requiredPermissions(), 0x22, "borrow mask (INCREASE_DEBT | WITHDRAW_COLLATERAL)");
    }
}
