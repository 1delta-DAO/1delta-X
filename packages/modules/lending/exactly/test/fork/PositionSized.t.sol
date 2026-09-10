// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {ExactlyDepositModule, ExactlyTakerModule} from "../../src/ExactlyModules.sol";
import {IExactlyMarket} from "../../src/interfaces/IExactly.sol";

interface IExactlyAuditor {
    function enterMarket(address market) external;
}

/// @dev POSITION-SIZED READS ON EXACTLY — one of the four venues the 2026-09-10
/// audit found had NO `positionOf` coverage. Two of its findings lived here:
///
///   • FINDING 1 — the reader returned `maxWithdraw`, a reachability figure
///     `IPositionSource` forbids ("Fail closed, not small").
///   • FINDING 3 — it ignored `maturity`, so a FIXED-maturity exit was priced off
///     the FLOATING ledger, a book the item never touches. Exactly is the only
///     venue in the set with two books behind one address, and its own `Full`
///     branch is already gated on `maturity == 0` — the gate landed there and
///     missed `positionOf`.
///
/// Driven the way the package's other suites drive it: a pranked settlement sender
/// and a real Permit3, so the module is exercised without a full Settlement.
contract ExactlyPositionSizedTest is Test {
    address internal constant AUDITOR = 0xaEb62e6F27BC103702E7BC879AE98bceA56f027E;
    address internal constant MARKET_USDC = 0x6926B434CCe9b5b7966aE1BfEef6D0A7DCF3A8bb;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    uint256 internal constant FORK_BLOCK = 154_900_000;
    uint256 internal constant FIXED_INTERVAL = 4 weeks;
    uint256 internal constant DEPOSIT = 10_000e6;

    Permit3 internal permit3;
    ExactlyDepositModule internal depositModule;
    ExactlyTakerModule internal takerModule;

    address internal maker;
    address internal settlement = address(0x5E77);
    address internal receiver = address(0xBEEF);

    /// @dev Same RPC-fallback ladder the leverage suite uses — env var first, then
    ///      public Optimism endpoints, so the suite runs without local config.
    function _forkOptimism() internal {
        try vm.envString("OPTIMISM_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        string[3] memory rpcs = ["https://mainnet.optimism.io", "https://optimism.drpc.org", "https://1rpc.io/op"];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryFork(rpcs[i])) return;
        }
        revert("ExactlyPositionSized: no archive-capable Optimism RPC (set OPTIMISM_RPC_URL)");
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

    function setUp() public {
        _forkOptimism();

        maker = makeAddr("exactly-maker");
        permit3 = new Permit3();
        depositModule = new ExactlyDepositModule(address(permit3), settlement);
        takerModule = new ExactlyTakerModule(address(permit3));

        vm.label(MARKET_USDC, "MarketUSDC");
        vm.label(USDC, "USDC.e");

        deal(USDC, maker, DEPOSIT);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), USDC, type(uint160).max, 0);
        IERC20(MARKET_USDC).approve(address(takerModule), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────── Fixtures ────────────────────

    function _floatingWithdrawData() internal pure returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Withdraw), MARKET_USDC, USDC, uint256(0), uint256(0), uint256(0));
    }

    function _fixedWithdrawData(uint256 maturity) internal pure returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Withdraw), MARKET_USDC, USDC, maturity, uint256(0), uint256(0));
    }

    function _rawPosition(address who) internal view returns (uint256) {
        return IExactlyMarket(MARKET_USDC).previewRedeem(IExactlyMarket(MARKET_USDC).balanceOf(who));
    }

    function _deposit(uint256 amount) internal {
        vm.prank(settlement);
        depositModule.makeOnBehalf(maker, amount, abi.encode(MARKET_USDC, USDC, uint256(0), uint256(0)));
    }

    function _nextMaturity() internal view returns (uint256) {
        return ((block.timestamp / FIXED_INTERVAL) + 1) * FIXED_INTERVAL;
    }

    // ──────────────────── Finding 1 ────────────────────

    /// @dev The reader must report the RAW share conversion, never `maxWithdraw`.
    /// Asserted unconditionally because it is the interface contract; the divergence
    /// between the two is asserted separately wherever this venue produces one.
    function test_positionOf_isTheRawShareConversion() public {
        _deposit(DEPOSIT);

        (address asset, uint256 reported) = takerModule.positionOf(maker, _floatingWithdrawData());

        assertEq(asset, IExactlyMarket(MARKET_USDC).asset(), "asset read from the market");
        assertEq(reported, _rawPosition(maker), "positionOf is previewRedeem(balanceOf), the RAW position");
        assertApproxEqAbs(reported, DEPOSIT, 2, "and it is the deposit");
    }

    /// @dev Where the market's own reachability figure differs from the raw one, the
    /// reader must follow the raw one. Skips itself (with a log) when the fork state
    /// happens not to diverge, rather than asserting something untrue of the block.
    function test_positionOf_followsRawWhenMaxWithdrawDiverges() public {
        _deposit(DEPOSIT);
        _enterMarketAndBorrow();

        uint256 raw = _rawPosition(maker);
        uint256 reachable = IExactlyMarket(MARKET_USDC).maxWithdraw(maker);
        (, uint256 reported) = takerModule.positionOf(maker, _floatingWithdrawData());

        assertEq(reported, raw, "reader is raw");
        if (reachable < raw) {
            assertGt(reported, reachable, "and strictly above the reachability figure");
        } else {
            emit log_string("note: maxWithdraw does not diverge at this fork state; contract still pinned");
        }
    }

    function _enterMarketAndBorrow() internal {
        vm.startPrank(maker);
        IExactlyAuditor(AUDITOR).enterMarket(MARKET_USDC);
        IExactlyMarket(MARKET_USDC).borrow(DEPOSIT / 4, maker, maker);
        vm.stopPrank();
    }

    // ──────────────────── Finding 3 ────────────────────

    /// @dev FINDING 3 REGRESSION. `maturity != 0` selects the FIXED book, which
    /// `maxWithdraw` does not see. Sizing a fill off the floating balance for such an
    /// item prices it against a ledger the withdraw never touches — so the reader
    /// must REFUSE, per `IPositionSource`'s "MUST revert ... rather than return a
    /// wrong-but-plausible number".
    function test_positionOf_refusesFixedMaturity() public {
        _deposit(DEPOSIT);
        uint256 maturity = _nextMaturity();

        // The floating leg of the very same market answers fine …
        (, uint256 floating) = takerModule.positionOf(maker, _floatingWithdrawData());
        assertGt(floating, 0, "floating book is readable");

        // … while the fixed leg is refused rather than answered from it.
        vm.expectRevert(abi.encodeWithSelector(ExactlyTakerModule.BadOp.selector, uint8(1)));
        takerModule.positionOf(maker, _fixedWithdrawData(maturity));
    }

    /// @dev And the borrow op stays refused, as it always was.
    function test_positionOf_refusesBorrowOp() public {
        _deposit(DEPOSIT);
        bytes memory borrowData =
            abi.encode(uint8(ExactlyTakerModule.Op.Borrow), MARKET_USDC, USDC, uint256(0), uint256(0), uint256(0));
        vm.expectRevert(abi.encodeWithSelector(ExactlyTakerModule.BadOp.selector, uint8(0)));
        takerModule.positionOf(maker, borrowData);
    }

    // ──────────────────── Finding 2 ────────────────────

    /// @dev A `Full` leg short of the signed amount must revert rather than deliver
    /// less and let the core bill the shortfall to the maker's wallet.
    function test_fullMode_shortPosition_reverts() public {
        _deposit(1_000e6); //      only 1,000 held
        uint256 signed = 5_000e6; // the order asks for 5,000

        bytes memory data = abi.encode(
            uint8(ExactlyTakerModule.Op.Withdraw),
            MARKET_USDC,
            USDC,
            uint256(0),
            uint256(0),
            signed,
            DustHandler.encodeMode(DustHandler.BalanceMode.Full),
            signed
        );

        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), type(uint160).max, 0);
        vm.prank(settlement);
        vm.expectRevert(); // ShortWithdraw, or the market on insufficient shares
        permit3.take(address(takerModule), maker, uint160(signed), receiver, data);
    }
}
