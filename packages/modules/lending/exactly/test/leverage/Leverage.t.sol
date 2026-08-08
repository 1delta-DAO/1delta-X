// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {ExactlyDepositModule, ExactlyTakerModule} from "../../src/ExactlyModules.sol";
import {IExactlyMarket, IExactlyAuditor} from "../../src/interfaces/IExactly.sol";

/// @title ExactlyLeverageTest
/// @notice Optimism-mainnet fork validation of the Exactly modules' real
///         fund-flow against the live MarketUSDC — the package previously had
///         only no-fork security tests.
///
///  The round-trip: deposit-collateral MAKE (floating `deposit`) + borrow TAKE
///  (floating `borrow` / fixed `borrowAtMaturity`), driven exactly like
///  Settlement would — the MAKE with a pranked settlement sender, the TAKE
///  through Permit3's taker book (`approveTaker` + `take`). Position deltas are
///  asserted through the Market's own views (`maxWithdraw`, `previewDebt`) and
///  raw balances.
///
///  What the on-behalf model requires of the maker (and the tests prove):
///    • `Auditor.enterMarket(market)` — maker-side, msg.sender-keyed: without it
///      the deposit does NOT count as collateral and `borrow` reverts
///      (`test_borrow_requiresEnterMarket`);
///    • ONE ERC-4626 share approval `market.approve(module, max)` covers BOTH
///      taker legs — the same allowance funds the borrow test and the withdraw
///      test (`InsufficientAccountLiquidity`-free thanks to enterMarket).
///
///  Facts of the pinned deployment (probed at FORK_BLOCK via cast):
///    • the NATIVE-USDC market exaUSDC 0x6926…9eb1 (asset 0x0b2C…Ff85) is live:
///      `isFrozen() == false`, not paused, floatingAssets ≈ 1.8M USDC,
///      adjustFactor 0.91e18, reserveFactor 5%, maxFuturePools 10;
///    • the ORIGINAL bridged market exaUSDC.e 0x81C9…4873 is FROZEN
///      (`isFrozen() == true` — deposits/borrows revert `MarketFrozen()`,
///      0xb2ce2a93), so tests must target the native market;
///    • fixed pools run on 4-week maturities (`INTERVAL = 4 weeks`), so the
///      fixed test borrows at the next 4-week boundary after the fork timestamp.
contract ExactlyLeverageTest is Test {
    // ── deployed Exactly suite on Optimism ──
    address internal constant AUDITOR = 0xaEb62e6F27BC103702E7BC879AE98bceA56f027E;
    address internal constant MARKET_USDC = 0x6926B434CCe9b5b7966aE1BfEef6D0A7DCF3A8bb; // exaUSDC (native)
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // native USDC
    address internal constant MARKET_WETH = 0xc4d4500326981eacD020e20A81b1c479c161c7EF; // exaWETH (cross-market leg)
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    uint256 internal constant FORK_BLOCK = 154_900_000;
    uint256 internal constant FIXED_INTERVAL = 4 weeks; // Exactly's maturity grid

    uint256 internal constant DEPOSIT = 10_000e6;
    uint256 internal constant BORROW = 1_000e6;
    uint256 internal constant FIXED_BORROW = 500e6;

    Permit3 internal permit3;
    ExactlyDepositModule internal depositModule;
    ExactlyTakerModule internal takerModule;

    address internal maker;
    address internal settlement = address(0x5E77);
    address internal solver = address(0x50C7E5);

    // ──────────────── fork plumbing (CoreSettlementBase pattern) ────────────────

    function _forkOptimism() internal {
        try vm.envString("OPTIMISM_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        // Public endpoints; the sequencer RPC serves historical state and is the
        // most reliable of the free ones (drpc/1rpc rate-limit or prune).
        string[3] memory rpcs = ["https://mainnet.optimism.io", "https://optimism.drpc.org", "https://1rpc.io/op"];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryFork(rpcs[i])) return;
        }
        revert("ExactlyLeverage: no archive-capable Optimism RPC (set OPTIMISM_RPC_URL)");
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

    // ──────────────── setup ────────────────

    function setUp() public {
        _forkOptimism();

        maker = makeAddr("exactly-maker");

        permit3 = new Permit3();
        depositModule = new ExactlyDepositModule(address(permit3), settlement);
        takerModule = new ExactlyTakerModule(address(permit3));

        vm.label(MARKET_USDC, "MarketUSDC");
        vm.label(USDC, "USDC.e");
        vm.label(AUDITOR, "Auditor");

        deal(USDC, maker, DEPOSIT);

        // Maker-side grants: fund the MAKE through Permit3's token book, and one
        // ERC-4626 share approval for BOTH taker legs (borrow + withdraw).
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), USDC, type(uint160).max, 0);
        IERC20(MARKET_USDC).approve(address(takerModule), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────── data encodings (must match the modules') ────────────────

    function _depositData() internal pure returns (bytes memory) {
        // abi.encode(market, asset, maturity, minAssetsRequired) — floating
        return abi.encode(MARKET_USDC, USDC, uint256(0), uint256(0));
    }

    function _borrowData(uint256 maturity, uint256 maxAssets) internal pure returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Borrow), MARKET_USDC, USDC, maturity, maxAssets);
    }

    function _withdrawData() internal pure returns (bytes memory) {
        // floating, BalanceMode absent ⇒ exact-amount withdraw
        return abi.encode(uint8(ExactlyTakerModule.Op.Withdraw), MARKET_USDC, USDC, uint256(0), uint256(0));
    }

    // ──────────────── drivers ────────────────

    function _makeDeposit(uint256 amount) internal {
        vm.prank(settlement);
        depositModule.makeOnBehalf(maker, amount, _depositData());
    }

    /// TAKE through the Permit3 taker book, as Settlement would dispatch it.
    function _take(bytes memory data, uint256 amount, address receiver) internal {
        vm.prank(maker);
        permit3.approveTaker(settlement, keccak256(data), type(uint160).max, 0);
        vm.prank(settlement);
        permit3.take(address(takerModule), maker, uint160(amount), receiver, data);
    }

    function _enterMarket() internal {
        vm.prank(maker);
        IExactlyAuditor(AUDITOR).enterMarket(MARKET_USDC);
    }

    /// Next 4-week boundary after the fork timestamp — the closest live fixed pool.
    function _nextMaturity() internal view returns (uint256) {
        return block.timestamp - (block.timestamp % FIXED_INTERVAL) + FIXED_INTERVAL;
    }

    // ──────────────── tests ────────────────

    /// Deposit MAKE alone: assets pulled from the maker land in the market
    /// crediting the MAKER (shares to `onBehalfOf`, never the module).
    function test_deposit_make_floating() public {
        _makeDeposit(DEPOSIT);

        assertGt(IERC20(MARKET_USDC).balanceOf(maker), 0, "maker holds the exaUSDC shares");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).maxWithdraw(maker), DEPOSIT, 2, "position ~= deposit");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC forwarded into the market");
        assertEq(IERC20(USDC).balanceOf(address(depositModule)), 0, "deposit module drained");
        assertEq(IERC20(MARKET_USDC).balanceOf(address(depositModule)), 0, "no shares stuck on the module");
    }

    /// The leverage round-trip: deposit-collateral MAKE + floating borrow TAKE.
    /// Debt lands on the maker, proceeds on the receiver.
    function test_depositCollateral_borrow_floating() public {
        _makeDeposit(DEPOSIT);
        _enterMarket();

        _take(_borrowData(0, 0), BORROW, solver);

        assertEq(IERC20(USDC).balanceOf(solver), BORROW, "borrow proceeds routed to the receiver");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).previewDebt(maker), BORROW, 2, "floating debt ~= borrow");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).maxWithdraw(maker), DEPOSIT, 2, "collateral untouched");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "taker module drained");
    }

    /// The fixed leg of the same round-trip: `borrowAtMaturity` at the next
    /// 4-week boundary, bounded by the maker-signed `maxAssets`. The receiver
    /// gets exactly the face amount; the maker owes face + fixed-pool fee.
    function test_depositCollateral_borrowAtMaturity_fixed() public {
        _makeDeposit(DEPOSIT);
        _enterMarket();

        uint256 maturity = _nextMaturity();
        uint256 maxAssets = (FIXED_BORROW * 110) / 100; // 10% fee headroom

        _take(_borrowData(maturity, maxAssets), FIXED_BORROW, solver);

        assertEq(IERC20(USDC).balanceOf(solver), FIXED_BORROW, "receiver gets exactly the face amount");
        uint256 debt = IExactlyMarket(MARKET_USDC).previewDebt(maker);
        assertGe(debt, FIXED_BORROW, "fixed debt >= face");
        assertLe(debt, maxAssets, "fixed debt bounded by the signed maxAssets");
    }

    /// The SECOND consumer of the same share approval: floating withdraw TAKE.
    /// Together with the borrow test this proves the package's "one share
    /// approve covers both taker legs" claim on the live market.
    function test_withdraw_take_sharedShareAllowance() public {
        _makeDeposit(DEPOSIT);

        uint256 part = 2_500e6;
        _take(_withdrawData(), part, solver);

        assertEq(IERC20(USDC).balanceOf(solver), part, "withdrawn assets routed to the receiver");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).maxWithdraw(maker), DEPOSIT - part, 2, "position reduced");
    }

    /// Nuance found on the live Auditor: `checkBorrow` AUTO-ENTERS the borrowed
    /// market into the account's market list, so a SAME-market borrow needs no
    /// explicit `enterMarket` — the fresh USDC deposit backs a USDC borrow
    /// as-is. (The package docs' "collateral only counts after enterMarket"
    /// is therefore a CROSS-market rule; see the next test.)
    function test_sameMarket_borrow_autoEnters() public {
        _makeDeposit(DEPOSIT);
        // deliberately NO _enterMarket()
        _take(_borrowData(0, 0), BORROW, solver);

        assertEq(IERC20(USDC).balanceOf(solver), BORROW, "same-market borrow works without enterMarket");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).previewDebt(maker), BORROW, 2, "debt on the maker");
    }

    /// Where `enterMarket` IS load-bearing: CROSS-market. USDC collateral does
    /// not back a WETH borrow until the maker (msg.sender-keyed on the Auditor,
    /// so no module can do it for them) has entered the USDC market.
    function test_crossMarket_borrow_requiresEnterMarket() public {
        _makeDeposit(DEPOSIT);

        // the borrowed market's share allowance funds the on-behalf borrow leg
        vm.prank(maker);
        IERC20(MARKET_WETH).approve(address(takerModule), type(uint256).max);

        bytes memory data = abi.encode(uint8(ExactlyTakerModule.Op.Borrow), MARKET_WETH, WETH, uint256(0), uint256(0));
        vm.prank(maker);
        permit3.approveTaker(settlement, keccak256(data), type(uint160).max, 0);

        uint256 wethOut = 0.05e18; // ~$200 against $10k collateral

        // without enterMarket: the USDC deposit is invisible to the risk check
        vm.prank(settlement);
        vm.expectRevert(); // Auditor: InsufficientAccountLiquidity
        permit3.take(address(takerModule), maker, uint160(wethOut), solver, data);

        // with it: the same borrow clears
        _enterMarket();
        vm.prank(settlement);
        permit3.take(address(takerModule), maker, uint160(wethOut), solver, data);

        assertEq(IERC20(WETH).balanceOf(solver), wethOut, "WETH routed to the receiver");
        assertApproxEqAbs(IExactlyMarket(MARKET_WETH).previewDebt(maker), wethOut, 2, "WETH debt on the maker");
    }
}
