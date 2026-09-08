// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {ExactlyDepositModule, ExactlyTakerModule} from "../../src/ExactlyModules.sol";
import {IExactlyMarket} from "../../src/interfaces/IExactly.sol";
import {IERC2612} from "@lib/interfaces/IERC2612.sol";

/// @title ExactlySharePermitProbeTest
/// @notice Pins the LIVE Optimism MarketUSDC's EIP-2612 surface: Exactly's
///         Market is built on solmate's ERC4626/ERC20, whose base carries
///         `permit` / `nonces` / `DOMAIN_SEPARATOR`. The permit call here is
///         deliberately UN-CAUGHT — if the deployed market ever stopped
///         verifying solmate-shaped permits, this test is the tripwire.
contract ExactlySharePermitProbeTest is Test {
    address internal constant MARKET_USDC = 0x6926B434CCe9b5b7966aE1BfEef6D0A7DCF3A8bb; // exaUSDC (native)
    uint256 internal constant FORK_BLOCK = 154_900_000;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _forkOptimism() internal {
        try vm.envString("OPTIMISM_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        string[3] memory rpcs = ["https://mainnet.optimism.io", "https://optimism.drpc.org", "https://1rpc.io/op"];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryFork(rpcs[i])) return;
        }
        revert("ExactlySharePermit: no archive-capable Optimism RPC (set OPTIMISM_RPC_URL)");
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
    }

    /// Sign a share permit with a fresh key against the market's OWN
    /// DOMAIN_SEPARATOR and call `permit` directly — no try/catch. Success
    /// proves the deployed proxy exposes the full solmate 2612 triple and
    /// verifies signatures over its live separator.
    function test_liveMarket_exposesSolmatePermit() public {
        (address owner, uint256 key) = makeAddrAndKey("permit-probe-owner");
        address spender = address(0xBEEF);
        uint256 value = 123e6;
        uint256 deadline = block.timestamp + 1 hours;

        uint256 nonce = IERC2612(MARKET_USDC).nonces(owner);
        assertEq(nonce, 0, "fresh key starts at nonce 0");

        bytes32 domain = IERC2612(MARKET_USDC).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", domain, keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);

        IERC2612(MARKET_USDC).permit(owner, spender, value, deadline, v, r, s);

        assertEq(IERC20(MARKET_USDC).allowance(owner, spender), value, "permit set the share allowance");
        assertEq(IERC2612(MARKET_USDC).nonces(owner), 1, "nonce consumed");
    }
}

/// @title ExactlyGaslessShareGrantTest
/// @notice The SIGNATURE-ONLY venue grant end-to-end: a maker who NEVER calls
///         `market.approve` on-chain funds the taker legs through the optional
///         2612 share-permit tail in {ExactlyTakerModule}'s data. Offsets under
///         test: Borrow tail at 192, Withdraw tail at 224 (after the padded
///         BalanceMode slot). The pre-existing no-tail behaviour is pinned by
///         Leverage.t.sol / TakerModuleAuth.t.sol, whose data blobs are
///         byte-identical to before this change.
contract ExactlyGaslessShareGrantTest is Test {
    address internal constant AUDITOR = 0xaEb62e6F27BC103702E7BC879AE98bceA56f027E;
    address internal constant MARKET_USDC = 0x6926B434CCe9b5b7966aE1BfEef6D0A7DCF3A8bb; // exaUSDC (native)
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    uint256 internal constant FORK_BLOCK = 154_900_000;
    uint256 internal constant DEPOSIT = 10_000e6;
    uint256 internal constant BORROW = 1_000e6;
    uint256 internal constant WITHDRAW = 2_500e6;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    Permit3 internal permit3;
    ExactlyDepositModule internal depositModule;
    ExactlyTakerModule internal takerModule;

    address internal maker;
    uint256 internal makerKey;
    address internal settlement = address(0x5E77);
    address internal solver = address(0x50C7E5);

    function _forkOptimism() internal {
        try vm.envString("OPTIMISM_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        string[3] memory rpcs = ["https://mainnet.optimism.io", "https://optimism.drpc.org", "https://1rpc.io/op"];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryFork(rpcs[i])) return;
        }
        revert("ExactlySharePermit: no archive-capable Optimism RPC (set OPTIMISM_RPC_URL)");
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

        (maker, makerKey) = makeAddrAndKey("gasless-exactly-maker");

        permit3 = new Permit3();
        depositModule = new ExactlyDepositModule(address(permit3), settlement);
        takerModule = new ExactlyTakerModule(address(permit3));

        deal(USDC, maker, DEPOSIT);

        // Value-IN funding only (the deposit MAKE's asset pull). The venue's
        // value-OUT grant — the ERC-4626 share approval — is deliberately NEVER
        // set on-chain in this suite: it rides inside the order data.
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), USDC, type(uint160).max, 0);
        vm.stopPrank();

        vm.prank(settlement);
        depositModule.makeOnBehalf(maker, DEPOSIT, abi.encode(MARKET_USDC, USDC, uint256(0), uint256(0)));
    }

    // ──────────────── helpers ────────────────

    /// Sign a 2612 permit over the MARKET's shares approving the taker MODULE.
    function _signSharePermit(uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC2612(MARKET_USDC).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        maker,
                        address(takerModule),
                        value,
                        IERC2612(MARKET_USDC).nonces(maker),
                        deadline
                    )
                )
            )
        );
        (v, r, s) = vm.sign(makerKey, digest);
    }

    /// Borrow data with the permit tail at its fixed offset 192.
    function _borrowDataWithTail(uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            abi.encode(uint8(ExactlyTakerModule.Op.Borrow), MARKET_USDC, USDC, uint256(0), uint256(0), BORROW),
            abi.encode(value, deadline, v, r, s)
        );
    }

    /// Withdraw data with the permit tail at its fixed offset 224 — the
    /// BalanceMode slot at 192 MUST be encoded (0 = Exact) when the tail follows.
    function _withdrawDataWithTail(uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            abi.encode(
                uint8(ExactlyTakerModule.Op.Withdraw), MARKET_USDC, USDC, uint256(0), uint256(0), WITHDRAW, uint256(0)
            ),
            abi.encode(value, deadline, v, r, s)
        );
    }

    function _take(bytes memory data, uint256 amount) internal {
        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), type(uint160).max, 0);
        vm.prank(settlement);
        permit3.take(address(takerModule), maker, uint160(amount), solver, data);
    }

    // ──────────────── tests ────────────────

    /// Floating borrow funded PURELY by the permit tail: share allowance is zero
    /// before the fill, the maker sent no `approve` transaction, and the fill
    /// lands debt on the maker + proceeds on the receiver. `value` is sized in
    /// asset units — an over-approximation of the share cost (share price >= 1).
    function test_borrow_gasless_permitTailAt192() public {
        assertEq(IERC20(MARKET_USDC).allowance(maker, address(takerModule)), 0, "NO on-chain share approval");
        uint256 nonceBefore = IERC2612(MARKET_USDC).nonces(maker);

        uint256 value = BORROW; // assets >= shares while share price >= 1
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signSharePermit(value, deadline);

        _take(_borrowDataWithTail(value, deadline, v, r, s), BORROW);

        assertEq(IERC20(USDC).balanceOf(solver), BORROW, "borrow proceeds routed to the receiver");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).previewDebt(maker), BORROW, 2, "floating debt on the maker");
        assertEq(IERC2612(MARKET_USDC).nonces(maker), nonceBefore + 1, "permit consumed inside the fill");
        assertLt(IERC20(MARKET_USDC).allowance(maker, address(takerModule)), value, "share allowance was spent");
    }

    /// Floating withdraw through the SAME signature-only grant, tail at 224.
    function test_withdraw_gasless_permitTailAt224() public {
        assertEq(IERC20(MARKET_USDC).allowance(maker, address(takerModule)), 0, "NO on-chain share approval");

        uint256 value = WITHDRAW; // assets >= shares while share price >= 1
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signSharePermit(value, deadline);

        _take(_withdrawDataWithTail(value, deadline, v, r, s), WITHDRAW);

        assertEq(IERC20(USDC).balanceOf(solver), WITHDRAW, "withdrawn assets routed to the receiver");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).maxWithdraw(maker), DEPOSIT - WITHDRAW, 2, "position reduced");
    }

    /// Front-run tolerance: a griefer lifts (value, deadline, v, r, s) out of the
    /// pending calldata and lands `market.permit` FIRST, consuming the nonce. The
    /// module's best-effort replay swallows the resulting revert and the fill
    /// still succeeds — the chain is in exactly the state the fill wanted.
    function test_borrow_gasless_frontRunReplayTolerated() public {
        uint256 value = BORROW;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signSharePermit(value, deadline);
        bytes memory data = _borrowDataWithTail(value, deadline, v, r, s);

        // griefer replays the exact permit from the mempool
        vm.prank(address(0xBAD));
        IERC2612(MARKET_USDC).permit(maker, address(takerModule), value, deadline, v, r, s);
        assertEq(IERC20(MARKET_USDC).allowance(maker, address(takerModule)), value, "griefer landed the allowance");

        // the untouched fill (same bytes — the tail is frozen into keccak(data))
        _take(data, BORROW);

        assertEq(IERC20(USDC).balanceOf(solver), BORROW, "fill unaffected by the front-run");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).previewDebt(maker), BORROW, 2, "debt on the maker");
    }

    /// A garbage tail also never bricks the fill when a standing on-chain
    /// allowance exists — the replay is best-effort in BOTH directions.
    function test_borrow_badTail_fallsBackToStandingAllowance() public {
        vm.prank(maker);
        IERC20(MARKET_USDC).approve(address(takerModule), type(uint256).max);

        bytes memory data = _borrowDataWithTail(BORROW, block.timestamp + 1 hours, 27, bytes32(uint256(1)), bytes32(uint256(2)));
        _take(data, BORROW);

        assertEq(IERC20(USDC).balanceOf(solver), BORROW, "fill funded by the standing allowance");
    }
}
