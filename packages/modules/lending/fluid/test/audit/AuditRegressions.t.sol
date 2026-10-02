// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {FluidModulesBase} from "../shared/FluidModulesBase.t.sol";
import {
    FluidDepositModule,
    FluidRepayModule,
    FluidTakerModule,
    FluidOperateModule,
    FluidTakeForModule
} from "../../src/FluidModules.sol";

interface IFluidVaultFactoryTransfer {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev A "VaultFactory" whose `transferFrom` does nothing — the L-FSE-1 channel (a)
///      custody root.
contract NoopFactory {
    function transferFrom(address, address, uint256) external {}
}

/// @dev A "vault" that, on the fresh-open path, reports a module-owned position id
///      as freshly minted — the L-FSE-1 channel (b). It claims a real vault id so the
///      binding has to be a REGISTRY check, not an existence check.
contract LyingVault {
    uint256 internal immutable strandedId;

    constructor(uint256 id) {
        strandedId = id;
    }

    function VAULT_ID() external pure returns (uint256) {
        return 11; // the real ETH-USDC vault's id
    }

    function constantsView() external pure returns (address, address, address, address, address, address) {
        return (address(0), address(0), address(0), address(0), address(1), address(1));
    }

    function operate(uint256, int256, int256, address) external payable returns (uint256, int256, int256) {
        return (strandedId, 0, 0);
    }
}

/// @title FluidAuditRegressionsTest
/// @notice 2026-09-30 audit regressions on the live Fluid ETH-USDC T1 vault (mainnet
///         fork), each asserting the SAFE end state:
///
///   • L-FSE-1 — a position NFT resident in a custody module can no longer be
///               operated (fake factory) or extracted (lying vault): the modules pin
///               the VaultFactory and bind the vault to it.
///   • L-FSE-3 — native value-out reaches the classic recipient-0 Settlement flow,
///               delivered as WETH (it used to revert: Settlement has no receive()).
///   • L-FSE-6 — runtime test of FluidTakeForModule's spender pin (F27/C-1).
contract FluidAuditRegressionsTest is FluidModulesBase {
    FluidTakeForModule internal takeForModule;
    address internal attacker = address(0xBAD);

    function setUp() public override {
        super.setUp();
        takeForModule = new FluidTakeForModule(address(permit3), address(settlement), VAULT_FACTORY, WETH);
    }

    /// @dev A maker's position sent to `module` with a plain `transferFrom` — the
    ///      only way one becomes module-resident (`safeTransferFrom` reverts: no
    ///      `onERC721Received`). Before the fix, that made it anyone's.
    function _strandIn(address module) internal returns (uint256 nftId) {
        nftId = _openPosition(maker, 1 ether, 1000e6);
        vm.prank(maker);
        IFluidVaultFactoryTransfer(VAULT_FACTORY).transferFrom(maker, module, nftId);
        assertEq(_ownerOf(nftId), module, "precondition: NFT resident in the module");
    }

    // ──────────────── L-FSE-1 (a): no-op factory + real vault ────────────────

    function test_audit_L_FSE_1_fakeFactory_cannotDrainResidentPosition() public {
        uint256 nftId = _strandIn(address(takerModule));
        NoopFactory fake = new NoopFactory();
        bytes memory d = abi.encode(uint8(FluidTakerModule.Op.Withdraw), VAULT, address(fake), nftId);

        vm.startPrank(attacker);
        permit3.approveTaker(attacker, address(takerModule), keccak256(d), uint160(0.1 ether), 0);
        vm.expectRevert(
            abi.encodeWithSignature("WrongFactory(address,address)", address(fake), VAULT_FACTORY)
        );
        permit3.take(address(takerModule), attacker, uint160(0.1 ether), attacker, d);
        vm.stopPrank();

        assertEq(attacker.balance, 0, "attacker got no ETH");
        assertEq(IERC20(WETH).balanceOf(attacker), 0, "attacker got no WETH");
        assertEq(_ownerOf(nftId), address(takerModule), "position untouched");
    }

    /// The same on the composite Close path.
    function test_audit_L_FSE_1_fakeFactory_operateClose_rejected() public {
        uint256 nftId = _strandIn(address(operateModule));
        NoopFactory fake = new NoopFactory();
        bytes memory d = abi.encode(
            FluidOperateModule.OperateData({
                mode: uint256(FluidOperateModule.Mode.Close),
                vault: VAULT,
                factory: address(fake),
                fundingToken: USDC,
                nftId: nftId,
                sideAmount: 0,
                repayCeiling: 0,
                totalAmount: 0.1 ether
            })
        );
        vm.startPrank(attacker);
        permit3.approveTaker(attacker, address(operateModule), keccak256(d), uint160(0.1 ether), 0);
        vm.expectRevert(
            abi.encodeWithSignature("WrongFactory(address,address)", address(fake), VAULT_FACTORY)
        );
        permit3.take(address(operateModule), attacker, uint160(0.1 ether), attacker, d);
        vm.stopPrank();
        assertEq(_ownerOf(nftId), address(operateModule), "position untouched");
    }

    // ──────────────── L-FSE-1 (b): real factory + lying vault ────────────────

    function test_audit_L_FSE_1_lyingVault_operateOpen_cannotExtractNft() public {
        uint256 nftId = _strandIn(address(operateModule));
        LyingVault evil = new LyingVault(nftId);
        deal(USDC, attacker, 1);
        bytes memory d = abi.encode(
            FluidOperateModule.OperateData({
                mode: uint256(FluidOperateModule.Mode.Open),
                vault: address(evil),
                factory: VAULT_FACTORY,
                fundingToken: USDC,
                nftId: 0,
                sideAmount: 1,
                repayCeiling: 0,
                totalAmount: 1
            })
        );
        vm.startPrank(attacker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(operateModule), USDC, 1, 0);
        permit3.approveTaker(attacker, address(operateModule), keccak256(d), 1, 0);
        vm.expectRevert(abi.encodeWithSignature("UnknownVault(address)", address(evil)));
        permit3.take(address(operateModule), attacker, 1, attacker, d);
        vm.stopPrank();

        assertEq(_ownerOf(nftId), address(operateModule), "NFT NOT transferred to the attacker");
    }

    /// The TAKE_FOR sibling, reached the only way it can be: the attacker's OWN
    /// order filled through Settlement (spender pinned to Settlement).
    function test_audit_L_FSE_1_lyingVault_takeForOpen_cannotExtractNft() public {
        uint256 nftId = _strandIn(address(takeForModule));
        LyingVault evil = new LyingVault(nftId);
        bytes memory d = abi.encode(
            FluidTakeForModule.OpenData({
                forDesc: 0,
                forCap: 0,
                vault: address(evil),
                factory: VAULT_FACTORY,
                collateralToken: USDC,
                nftId: 0,
                totalAmount: 1
            })
        );
        vm.prank(attacker);
        permit3.approveTaker(address(settlement), address(takeForModule), keccak256(d), 1, 0);

        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSignature("UnknownVault(address)", address(evil)));
        permit3.takeFor(address(takeForModule), attacker, 1, 0, attacker, d);

        assertEq(_ownerOf(nftId), address(takeForModule), "NFT NOT transferred to the attacker");
    }

    /// The binding admits the real vault — the honest path is unchanged.
    function test_audit_L_FSE_1_realVault_realFactory_stillWorks() public {
        uint256 nftId = _openPosition(maker, 1 ether, 1000e6);
        bytes memory d = abi.encode(uint8(FluidTakerModule.Op.Borrow), VAULT, VAULT_FACTORY, nftId);
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(d), 100e6, 0);
        vm.prank(address(settlement));
        permit3.take(address(takerModule), maker, 100e6, recv, d);
        assertEq(IERC20(USDC).balanceOf(recv), 100e6, "honest borrow delivered");
        assertEq(_ownerOf(nftId), maker, "NFT handed back");
    }

    // ──────────────── L-FSE-3: native value-out through Settlement ────────────────

    /// @notice A recipient-0 native-collateral withdraw funding the maker's input leg,
    ///         filled through the REAL Settlement. Raw ETH to Settlement reverted the
    ///         whole fill; the module now delivers WETH, so the order is a WETH leg.
    function test_audit_L_FSE_3_nativeWithdraw_recipientZero_settlesAsWeth() public {
        uint256 nftId = _openPosition(maker, 1 ether, 1000e6);
        uint256 withdrawAmount = 0.1 ether;
        uint256 usdcOut = 200e6;
        bytes memory data = abi.encode(uint8(FluidTakerModule.Op.Withdraw), VAULT, VAULT_FACTORY, nftId);

        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(data), uint160(withdrawAmount), 0);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE, module: address(takerModule), amount: withdrawAmount, recipient: address(0), data: data
        });
        Order memory order = _sellOrder(7, maker, WETH, USDC, withdrawAmount, usdcOut, items);
        bytes memory sig = _sign(order);

        deal(USDC, solver, usdcOut);
        _approveSolverSide(usdcOut, USDC);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 solverWethBefore = IERC20(WETH).balanceOf(solver);

        vm.prank(solver);
        settlement.fill(order, sig, withdrawAmount);

        assertEq(IERC20(WETH).balanceOf(solver) - solverWethBefore, withdrawAmount, "filler paid in WETH");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, usdcOut, "maker got the signed USDC");
        assertEq(_ownerOf(nftId), maker, "position NFT returned to maker");
        assertEq(address(takerModule).balance, 0, "no ETH left on the module");
        assertEq(IERC20(WETH).balanceOf(address(takerModule)), 0, "no WETH left on the module");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "nothing stranded in Settlement");
    }

    /// The TAKE_FOR sibling's lens view now reports the vault's real borrow token.
    function test_audit_L_FSE_3_takeFor_proceedsAsset_readsTheVault() public view {
        bytes memory d = abi.encode(
            FluidTakeForModule.OpenData({
                forDesc: 0,
                forCap: 0,
                vault: VAULT,
                factory: VAULT_FACTORY,
                collateralToken: WETH,
                nftId: 0,
                totalAmount: 1
            })
        );
        assertEq(takeForModule.proceedsAsset(d), USDC, "ETH-USDC vault borrows USDC");
    }

    // ──────────────── L-FSE-6: cross-principal negatives ────────────────

    /// An attacker's OWN taker bucket naming the VICTIM's nftId (real vault, real
    /// factory): the custody pull is `transferFrom(attacker → module, victimId)`,
    /// which the real ERC-721 refuses — even though the victim granted the module
    /// `setApprovalForAll` (the base harness does exactly that).
    function test_audit_L_FSE_6_attackerOrder_namingVictimNft_reverts() public {
        uint256 victimId = _openPosition(maker, 1 ether, 1000e6);
        bytes memory d = abi.encode(uint8(FluidTakerModule.Op.Withdraw), VAULT, VAULT_FACTORY, victimId);
        vm.startPrank(attacker);
        permit3.approveTaker(attacker, address(takerModule), keccak256(d), uint160(0.1 ether), 0);
        vm.expectRevert();
        permit3.take(address(takerModule), attacker, uint160(0.1 ether), attacker, d);
        vm.stopPrank();
        assertEq(_ownerOf(victimId), maker, "victim keeps the position");
        assertEq(IERC20(WETH).balanceOf(attacker), 0, "attacker got nothing");
    }

    // ──────────────── L-FSE-6: TAKE_FOR spender pin at runtime ────────────────

    /// `Permit3.takeFor` is permissionless and `approveTaker` lets a caller name
    /// itself spender — the module must refuse any spender but Settlement (F27/C-1).
    function test_audit_L_FSE_6_takeFor_selfGrantedSpender_rejected() public {
        bytes memory d = abi.encode(
            FluidTakeForModule.OpenData({
                forDesc: (uint256(5) << 253) | uint256(uint160(WETH)) << 16,
                forCap: 0,
                vault: VAULT,
                factory: VAULT_FACTORY,
                collateralToken: WETH,
                nftId: 1,
                totalAmount: 1
            })
        );
        vm.startPrank(attacker);
        permit3.approveTaker(attacker, address(takeForModule), keccak256(d), 1, 0);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        permit3.takeFor(address(takeForModule), attacker, 1, 1 ether, attacker, d);
        vm.stopPrank();
    }
}

// ═══════════════ X-TOKENS-8: no grant survives a fee-on-transfer pull ═══════════════

contract FluidFoTToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _move(from, to, a);
        return true;
    }

    function _move(address from, address to, uint256 a) internal {
        balanceOf[from] -= a;
        balanceOf[to] += a - a / 100; // 1% burned in flight
    }
}

/// @dev An order-chosen "vault" whose liquidity callback pulls exactly what the
///      caller HOLDS — the delivered delta of a fee-on-transfer pull.
contract HoldingsPullVault {
    address internal immutable token;
    /// @dev Position owner for the value-in owner binding (L-CENSUS-8); the vault
    ///      acts as its own VaultFactory.
    address internal immutable owner;

    constructor(address t, address o) {
        token = t;
        owner = o;
    }

    function constantsView() external view returns (address, address, address, address, address, address) {
        return (address(0), address(this), address(0), address(0), address(0), address(0));
    }

    function ownerOf(uint256) external view returns (address) {
        return owner;
    }

    function operate(uint256 nftId, int256, int256, address) external payable returns (uint256, int256, int256) {
        uint256 bal = FluidFoTToken(token).balanceOf(msg.sender);
        FluidFoTToken(token).transferFrom(msg.sender, address(this), bal);
        return (nftId, 0, 0);
    }
}

/// @title FluidFoTGrantClearTest
/// @notice X-TOKENS-8: `_returnUnused` cleared the vault grant only on its refund
///         branch. A fee-on-transfer token delivers less than the nominal approval,
///         the vault pulls the delta, the balance returns to the floor — and the
///         difference stayed granted. Asserted end state: no grant survives.
contract FluidFoTGrantClearTest is Test {
    Permit3 internal permit3;
    FluidDepositModule internal depositModule;
    FluidRepayModule internal repayModule;
    FluidFoTToken internal token;
    HoldingsPullVault internal vault;
    address internal maker = address(0xA11CE);
    address internal settlement = address(0x5E77);

    function setUp() public {
        permit3 = new Permit3();
        depositModule = new FluidDepositModule(address(permit3), settlement);
        repayModule = new FluidRepayModule(address(permit3), settlement);
        token = new FluidFoTToken();
        vault = new HoldingsPullVault(address(token), maker);
        token.mint(maker, 10_000e6);
        vm.startPrank(maker);
        token.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), address(token), type(uint160).max, 0);
        permit3.approveToken(address(repayModule), address(token), type(uint160).max, 0);
        vm.stopPrank();
    }

    function test_audit_X_TOKENS_8_deposit_fotCollateral_noStandingGrant() public {
        vm.prank(settlement);
        depositModule.makeOnBehalf(maker, 500e6, abi.encode(address(vault), address(token), uint256(1)));
        assertEq(token.balanceOf(address(depositModule)), 0, "precondition: balance back at the floor");
        assertEq(token.allowance(address(depositModule), address(vault)), 0, "no grant outlives the call");
    }

    function test_audit_X_TOKENS_8_repay_fotDebt_noStandingGrant() public {
        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, 500e6, abi.encode(address(vault), address(token), uint256(1)));
        assertEq(token.balanceOf(address(repayModule)), 0, "precondition: balance back at the floor");
        assertEq(token.allowance(address(repayModule), address(vault)), 0, "no grant outlives the call");
    }
}
