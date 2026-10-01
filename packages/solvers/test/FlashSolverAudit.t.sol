// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, LegIn, LegOut, Validator} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver, FlashOpts, IUniV3Router, IUniV3Router02} from "@solvers/base/BaseFlashSolver.sol";
import {LimitOrderLeverageSolver} from "@solvers/single-input/LimitOrderLeverageSolver.sol";
import {AaveV3FlashSolver} from "@solvers/single-input/AaveV3FlashSolver.sol";
import {MorphoFlashSolver} from "@solvers/single-input/MorphoFlashSolver.sol";
import {EulerFlashSolver} from "@solvers/single-input/EulerFlashSolver.sol";
import {MidnightFlashSolver} from "@solvers/single-input/MidnightFlashSolver.sol";
import {MultiInputLeverageSolver} from "@solvers/multi-input/MultiInputLeverageSolver.sol";
import {AaveV3MultiInputFlashSolver} from "@solvers/multi-input/AaveV3MultiInputFlashSolver.sol";
import {MorphoMultiInputFlashSolver} from "@solvers/multi-input/MorphoMultiInputFlashSolver.sol";
import {EulerMultiInputFlashSolver} from "@solvers/multi-input/EulerMultiInputFlashSolver.sol";
import {MultiOutputFlashSolver, OutputLeg} from "@solvers/multi-output/MultiOutputFlashSolver.sol";

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

// ════════════════════════════ local provider / venue mocks ════════════════════════════

interface IBalancerRecipient {
    function receiveFlashLoan(address[] memory, uint256[] memory, uint256[] memory, bytes memory) external;
}

/// @dev Balancer v2 vault: any recipient, no initiator, empty arrays allowed,
///      `nonReentrant` only while a flash is in flight — the properties FLASH-2 uses.
contract FMockBalancerVault {
    bool internal locked;

    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external
    {
        require(!locked, "BAL#400");
        locked = true;
        uint256 n = tokens.length;
        uint256[] memory pre = new uint256[](n);
        for (uint256 i; i < n; i++) {
            pre[i] = MockERC20(tokens[i]).balanceOf(address(this));
            MockERC20(tokens[i]).transfer(recipient, amounts[i]);
        }
        IBalancerRecipient(recipient).receiveFlashLoan(tokens, amounts, new uint256[](n), userData);
        for (uint256 i; i < n; i++) {
            require(MockERC20(tokens[i]).balanceOf(address(this)) >= pre[i], "BAL#515");
        }
        locked = false;
    }
}

interface IAaveRecipient {
    function executeOperation(address, uint256, uint256, address, bytes calldata) external returns (bool);
}

contract FMockAavePool {
    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16) external {
        uint256 premium = (amount * 5) / 10_000;
        MockERC20(asset).transfer(receiver, amount);
        require(IAaveRecipient(receiver).executeOperation(asset, amount, premium, msg.sender, params), "aave cb");
        MockERC20(asset).transferFrom(receiver, address(this), amount + premium);
    }
}

interface IMorphoRecipient {
    function onMorphoFlashLoan(uint256, bytes calldata) external;
}

contract FMockMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        MockERC20(token).transfer(msg.sender, assets);
        IMorphoRecipient(msg.sender).onMorphoFlashLoan(assets, data);
        MockERC20(token).transferFrom(msg.sender, address(this), assets);
    }
}

interface IEulerRecipient {
    function onFlashLoan(bytes calldata) external;
}

contract FMockEulerVault {
    address public immutable asset;

    constructor(address _asset) {
        asset = _asset;
    }

    function flashLoan(uint256 amount, bytes calldata data) external {
        uint256 pre = MockERC20(asset).balanceOf(address(this));
        MockERC20(asset).transfer(msg.sender, amount);
        IEulerRecipient(msg.sender).onFlashLoan(data);
        require(MockERC20(asset).balanceOf(address(this)) >= pre, "E_FlashLoanNotRepaid");
    }
}

/// @dev A "vault" that returns without calling back.
contract FNoCallbackVault {
    address public immutable asset;

    constructor(address _asset) {
        asset = _asset;
    }

    function flashLoan(uint256, bytes calldata) external {}
}

/// @dev A "vault" whose callback arrives from a DIFFERENT address than the one armed.
contract FForwardingVault {
    address public immutable asset;
    FCallbackPoker public immutable poker;

    constructor(address _asset) {
        asset = _asset;
        poker = new FCallbackPoker();
    }

    function flashLoan(uint256, bytes calldata data) external {
        poker.poke(msg.sender, data);
    }
}

contract FCallbackPoker {
    function poke(address solver, bytes calldata data) external {
        IEulerRecipient(solver).onFlashLoan(data);
    }
}

interface IMidnightRecipient {
    function onFlashLoan(address, address[] calldata, uint256[] calldata, bytes calldata) external returns (bytes32);
}

contract FMockMidnight {
    function flashLoan(address[] calldata tokens, uint256[] calldata assets, address callback, bytes calldata data)
        external
    {
        for (uint256 i; i < tokens.length; i++) {
            MockERC20(tokens[i]).transfer(callback, assets[i]);
        }
        require(
            IMidnightRecipient(callback).onFlashLoan(msg.sender, tokens, assets, data)
                == keccak256("morpho.midnight.callbackSuccess"),
            "midnight cb"
        );
        for (uint256 i; i < tokens.length; i++) {
            MockERC20(tokens[i]).transferFrom(callback, address(this), assets[i]);
        }
    }
}

/// @dev Uniswap v3 SwapRouter (v1 shape, with `deadline`). Pays `rateBps` of the
///      input; reverts on a same-token "pool" like the real router.
contract FMockRouter {
    uint256 public rateBps = 10_000;

    function setRate(uint256 r) external {
        rateBps = r;
    }

    function exactInputSingle(IUniV3Router.ExactInputSingleParams calldata p) external returns (uint256 out) {
        out = _swap(p.tokenIn, p.tokenOut, p.amountIn, p.amountOutMinimum, p.recipient);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        internal
        returns (uint256 out)
    {
        require(tokenIn != tokenOut, "same-token pool");
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = (amountIn * rateBps) / 10_000;
        require(out >= minOut, "Too little received");
        MockERC20(tokenOut).transfer(recipient, out);
    }
}

/// @dev SwapRouter02 shape: no `deadline`, and exposes `factoryV2()`.
contract FMockRouter02 is FMockRouter {
    function factoryV2() external pure returns (address) {
        return address(0xF2);
    }

    function exactInputSingle(IUniV3Router02.ExactInputSingleParams calldata p) external returns (uint256 out) {
        out = _swap(p.tokenIn, p.tokenOut, p.amountIn, p.amountOutMinimum, p.recipient);
    }
}

/// @dev A SETTLE module in the ProportionalSweepModule mould: pays the FILLER a
///      maker token (the maker approved this module directly).
contract FSettleToFiller {
    address public immutable token;

    constructor(address _token) {
        token = _token;
    }

    function settle(address maker, address filler, uint256 amount, bytes calldata) external {
        MockERC20(token).transferFrom(maker, filler, amount);
    }
}

/// @dev A validator that admits a fill only when the filler supplied `takerData == "ok"`.
contract FTakerDataValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata takerData) external pure returns (bool) {
        return keccak256(takerData) == keccak256("ok");
    }
}

/// @dev FLASH-2: a token with a transfer hook. Armed, its next `transfer` (the
///      profit sweep) starts a FOREIGN Balancer flash naming the solver, with an
///      attacker payload — and records whether the solver accepted it.
contract FHookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public vault;
    address public target;
    bytes public payload;
    bool public armed;
    bool public foreignFlashSucceeded;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function arm(address _vault, address _target, bytes calldata _payload) external {
        vault = _vault;
        target = _target;
        payload = _payload;
        armed = true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        bool ok = true;
        if (armed) {
            armed = false;
            address[] memory none = new address[](0);
            try FMockBalancerVault(vault).flashLoan(target, none, new uint256[](0), payload) {
                foreignFlashSucceeded = true;
            } catch {}
        }
        return ok;
    }
}

/// @title FlashSolverAudit20260930Test
/// @notice Regression tests for the 2026-09-30 audit findings on the flash-solver
///         family: PERIPH-4.v1 (SETTLE receipts), FLASH-1 (multi-input into
///         MultiOutput), FLASH-2 (callback gate armed through the sweep), FLASH-3
///         (profit swept in the wrong token), FLASH-7 (takerData / recipient /
///         sentinel / SwapRouter02 / same-token), FLASH-8 (negative guard coverage
///         for every provider + zero-residue after every fill). Local mocks only —
///         no fork — so every revert asserted is this package's own.
contract FlashSolverAudit20260930Test is MockSettlementBase {
    uint256 constant IN_B = 100e18; // maker pays tB (the "borrow proceeds")
    uint256 constant OUT_A = 90e18; // solver fronts tA (the "collateral")

    FMockRouter router;
    FMockBalancerVault vault;
    FMockAavePool aave;
    FMockMorpho morpho;
    FMockEulerVault eulerVault;
    FMockMidnight midnight;

    LimitOrderLeverageSolver bal;
    AaveV3FlashSolver aaveS;
    MorphoFlashSolver morphoS;
    EulerFlashSolver eulerS;
    MidnightFlashSolver midnightS;
    MultiInputLeverageSolver balM;
    AaveV3MultiInputFlashSolver aaveM;
    MorphoMultiInputFlashSolver morphoM;
    EulerMultiInputFlashSolver eulerM;
    MultiOutputFlashSolver outS;

    function setUp() public override {
        super.setUp();
        router = new FMockRouter();
        vault = new FMockBalancerVault();
        aave = new FMockAavePool();
        morpho = new FMockMorpho();
        eulerVault = new FMockEulerVault(address(tA));
        midnight = new FMockMidnight();

        address p = address(permit3);
        address s = address(settlement);
        bal = new LimitOrderLeverageSolver(p, s, address(vault), address(router));
        aaveS = new AaveV3FlashSolver(p, s, address(aave), address(router));
        morphoS = new MorphoFlashSolver(p, s, address(morpho), address(router));
        eulerS = new EulerFlashSolver(p, s, address(router));
        midnightS = new MidnightFlashSolver(p, s, address(midnight), address(router));
        balM = new MultiInputLeverageSolver(p, s, address(vault), address(router));
        aaveM = new AaveV3MultiInputFlashSolver(p, s, address(aave), address(router));
        morphoM = new MorphoMultiInputFlashSolver(p, s, address(morpho), address(router));
        eulerM = new EulerMultiInputFlashSolver(p, s, address(router));
        outS = new MultiOutputFlashSolver(p, s, address(vault), address(router));

        // Provider + venue liquidity.
        for (uint256 i; i < 2; i++) {
            MockERC20 t = i == 0 ? tA : tB;
            t.mint(address(vault), 1_000e18);
            t.mint(address(aave), 1_000e18);
            t.mint(address(morpho), 1_000e18);
            t.mint(address(midnight), 1_000e18);
            t.mint(address(router), 1_000e18);
        }
        tA.mint(address(eulerVault), 1_000e18);
        tC.mint(address(router), 1_000e18);

        // Every solver lets Settlement pull the collateral it flashes.
        address[10] memory all = _all();
        for (uint256 i; i < all.length; i++) {
            BaseFlashSolver(all[i]).setupTokenApproval(address(tA));
            BaseFlashSolver(all[i]).setupTokenApproval(address(tB));
        }

        tB.mint(maker, 10_000e18);
        tC.mint(maker, 10_000e18);
        _makerApprove(address(settlement), address(tB), type(uint160).max);
        _makerApprove(address(settlement), address(tC), type(uint160).max);
    }

    function _all() internal view returns (address[10] memory a) {
        a = [
            address(bal),
            address(aaveS),
            address(morphoS),
            address(eulerS),
            address(midnightS),
            address(balM),
            address(aaveM),
            address(morphoM),
            address(eulerM),
            address(outS)
        ];
    }

    /// @dev maker sells IN_B of tB for OUT_A of tA — the solver flashes tA.
    function _order(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tB), address(tA), IN_B, OUT_A);
    }

    function _settleItem(uint256 amount) internal returns (bytes memory) {
        FSettleToFiller m = new FSettleToFiller(address(tC));
        vm.prank(maker);
        tC.approve(address(m), type(uint256).max);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.SETTLE, module: address(m), amount: amount, recipient: address(0), data: ""});
        return PackedEncode.items(items);
    }

    function _fees() internal pure returns (uint24[] memory f) {
        f = new uint24[](1);
        f[0] = 500;
    }

    function _mins() internal pure returns (uint256[] memory m) {
        m = new uint256[](1);
    }

    /// @dev Drive solver `s` (by index into {_all}) on `o`.
    function _exec(uint256 which, Order memory o, bytes memory sig, uint256 amt) internal {
        if (which == 0) {
            bal.executeFill(address(tA), OUT_A, o, sig, amt, 500, 0);
        } else if (which == 1) {
            aaveS.executeFill(address(tA), OUT_A, o, sig, amt, 500, 0);
        } else if (which == 2) {
            morphoS.executeFill(address(tA), OUT_A, o, sig, amt, 500, 0);
        } else if (which == 3) {
            eulerS.executeFill(address(eulerVault), OUT_A, o, sig, amt, 500, 0);
        } else if (which == 4) {
            midnightS.executeFill(address(tA), OUT_A, o, sig, amt, 500, 0);
        } else if (which == 5) {
            balM.executeFill(address(tA), OUT_A, o, sig, amt, _fees(), _mins());
        } else if (which == 6) {
            aaveM.executeFill(address(tA), OUT_A, o, sig, amt, _fees(), _mins());
        } else if (which == 7) {
            morphoM.executeFill(address(tA), OUT_A, o, sig, amt, _fees(), _mins());
        } else if (which == 8) {
            eulerM.executeFill(address(eulerVault), OUT_A, o, sig, amt, _fees(), _mins());
        } else {
            OutputLeg[] memory legs = new OutputLeg[](1);
            legs[0] = OutputLeg({token: address(tA), flashAmount: OUT_A, dexFee: 500, spendIn: OUT_A, minOut: OUT_A});
            outS.executeFill(o, sig, amt, legs);
        }
    }

    // ═══════════════════════ FLASH-8: every provider, happy path + zero residue ═══════════════════════

    /// FLASH-8: every one of the ten flash solvers fills the plain shape and ends the
    /// fill holding NOTHING of any token it touched (the operating rule that makes
    /// the permissionless entry safe), with the profit at the caller.
    function test_audit_FLASH_8_everySolverFillsAndHoldsNothing() public {
        address[10] memory all = _all();
        for (uint256 i; i < all.length; i++) {
            Order memory o = _order(100 + i);
            bytes memory sig = _sign(o);
            uint256 before = tA.balanceOf(address(this)) + tB.balanceOf(address(this));
            _exec(i, o, sig, IN_B);
            assertEq(tA.balanceOf(all[i]), 0, "no tA residue");
            assertEq(tB.balanceOf(all[i]), 0, "no tB residue");
            assertGt(tA.balanceOf(address(this)) + tB.balanceOf(address(this)), before, "profit reached the caller");
        }
    }

    // ═══════════════════════ PERIPH-4.v1: SETTLE items ═══════════════════════

    /// PERIPH-4.v1: a SETTLE item pays `ctx.filler` — the solver — a token none of
    /// its sweeps names, so the receipt stayed behind for any back-runner. Every one
    /// of the ten solvers (incl. MultiOutput, which bypasses `_fillAndSwap`) now
    /// refuses the order before the flash.
    function test_audit_PERIPH_4_v1_everySolverRefusesSettleItems() public {
        address[10] memory all = _all();
        for (uint256 i; i < all.length; i++) {
            Order memory o = _order(200 + i);
            o.items = _settleItem(IN_B);
            bytes memory sig = _sign(o);
            vm.expectRevert(BaseFlashSolver.SettleItemsUnsupported.selector);
            _exec(i, o, sig, IN_B);
            assertEq(tC.balanceOf(all[i]), 0, "no SETTLE receipt stranded on the solver");
        }
    }

    /// MAKE/TAKE items are untouched by the SETTLE refusal: a no-op MAKE item still
    /// fills (the leverage shapes depend on it).
    function test_audit_PERIPH_4_v1_makeItemsStillFill() public {
        FNoopMaker m = new FNoopMaker();
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(m), amount: IN_B, recipient: address(0), data: ""});
        Order memory o = _order(250);
        o.items = PackedEncode.items(items);
        bytes memory sig = _sign(o);
        bal.executeFill(address(tA), OUT_A, o, sig, IN_B, 500, 0);
        assertTrue(m.called(), "MAKE item ran");
    }

    // ═══════════════════════ FLASH-1: multi-input into MultiOutput ═══════════════════════

    /// FLASH-1: a second input leg was paid to MultiOutputFlashSolver and never
    /// swept — claimable by anyone. Refused up front, like its siblings.
    function test_audit_FLASH_1_multiOutputRefusesMultiInputOrders() public {
        LegIn[] memory legsIn = new LegIn[](2);
        legsIn[0] = LegIn(address(tB), IN_B, 0);
        legsIn[1] = LegIn(address(tC), 50e18, 0);
        Order memory o = _order(300);
        o.legsIn = PackedEncode.legsIn(legsIn);
        bytes memory sig = _sign(o);

        OutputLeg[] memory legs = new OutputLeg[](1);
        legs[0] = OutputLeg({token: address(tA), flashAmount: OUT_A, dexFee: 500, spendIn: OUT_A, minOut: OUT_A});
        vm.expectRevert(BaseFlashSolver.MultiInputUnsupported.selector);
        outS.executeFill(o, sig, IN_B, legs);
        assertEq(tC.balanceOf(address(outS)), 0, "no second input leg stranded");
    }

    // ═══════════════════════ FLASH-2: gate armed through the sweep ═══════════════════════

    /// FLASH-2: MultiOutputFlashSolver sweeps `legsIn[0]` FIRST, while the surplus
    /// output is still parked. A hostile input token's transfer hook starts a
    /// foreign Balancer flash naming the solver (Balancer has no initiator) with an
    /// attacker order that has the solver pay the attacker that surplus. The gate is
    /// now closed once the provider returns (and Balancer callbacks are bound to the
    /// committed payload), so the foreign flash fails and the honest caller is paid.
    function test_audit_FLASH_2_foreignBalancerFlashDuringSweepIsRefused() public {
        FHookToken hook = new FHookToken();
        hook.mint(maker, IN_B);
        _makerApprove(address(settlement), address(hook), type(uint160).max);
        hook.mint(address(router), 1_000e18);

        // Honest order: maker pays HOOK, receives OUT_A of tA. The buyback spends
        // OUT_A HOOK at 1:1.2, leaving 18e18 tA surplus parked until the sweep.
        Order memory o = _plainOrder(400, address(hook), address(tA), IN_B, OUT_A);
        bytes memory sig = _sign(o);
        router.setRate(12_000);

        // Attacker order: the attacker "sells" 1 wei of tB for the solver's parked tA.
        uint256 attackerPk = 0xA77;
        address attacker = vm.addr(attackerPk);
        tB.mint(attacker, 1);
        vm.startPrank(attacker);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.stopPrank();
        Order memory evil = _plainOrder(1, address(tB), address(tA), 1, 18e18);
        evil.maker = attacker;
        bytes memory evilSig = _signWith(evil, attackerPk);
        hook.arm(address(vault), address(outS), abi.encode(evil, evilSig, uint256(1), new OutputLeg[](0), bytes("")));

        OutputLeg[] memory legs = new OutputLeg[](1);
        legs[0] = OutputLeg({token: address(tA), flashAmount: OUT_A, dexFee: 500, spendIn: OUT_A, minOut: 0});
        uint256 before = tA.balanceOf(address(this));
        outS.executeFill(o, sig, IN_B, legs);

        assertFalse(hook.foreignFlashSucceeded(), "the foreign flash was refused");
        assertEq(tA.balanceOf(attacker), 0, "attacker took none of the surplus");
        assertEq(tA.balanceOf(address(this)) - before, 18e18, "the honest caller got the whole surplus");
        assertEq(tA.balanceOf(address(outS)), 0, "nothing left behind");
    }

    /// FLASH-2: a Balancer callback carrying a payload other than the committed one
    /// is refused even while a flash is in flight (unit-level, via the real vault
    /// address).
    function test_audit_FLASH_2_strayBalancerCallbackOutsideFlashRefused() public {
        vm.prank(address(vault));
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        bal.receiveFlashLoan(new address[](0), new uint256[](0), new uint256[](0), "");
        vm.prank(address(vault));
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        balM.receiveFlashLoan(new address[](0), new uint256[](0), new uint256[](0), "");
    }

    // ═══════════════════════ FLASH-3: sweep the repaid asset ═══════════════════════

    /// FLASH-3: leg 0 is a zero-priced leg in tC (the core skips it) and the collateral
    /// is leg 1. The surplus lives in the flash asset, tA; the old sweep named leg 0's
    /// token and left the whole tA surplus behind as public residue.
    function test_audit_FLASH_3_surplusSweptInTheFlashAsset() public {
        for (uint256 which; which < 4; which++) {
            LegOut[] memory legsOut = new LegOut[](2);
            legsOut[0] = LegOut(address(tC), 0, 0, address(0));
            legsOut[1] = LegOut(address(tA), OUT_A, 0, address(0));
            Order memory o = _order(500 + which);
            o.legsOut = PackedEncode.legsOut(legsOut);
            bytes memory sig = _sign(o);
            uint256 before = tA.balanceOf(address(this));
            if (which == 0) bal.executeFill(address(tA), OUT_A, o, sig, IN_B, 500, 0);
            else if (which == 1) aaveS.executeFill(address(tA), OUT_A, o, sig, IN_B, 500, 0);
            else if (which == 2) eulerS.executeFill(address(eulerVault), OUT_A, o, sig, IN_B, 500, 0);
            else balM.executeFill(address(tA), OUT_A, o, sig, IN_B, _fees(), _mins());
            address s =
                which == 0 ? address(bal) : which == 1 ? address(aaveS) : which == 2 ? address(eulerS) : address(balM);
            assertEq(tA.balanceOf(s), 0, "no flash-asset surplus stranded");
            assertGt(tA.balanceOf(address(this)), before, "the surplus reached the caller");
        }
    }

    // ═══════════════════════ FLASH-7: shapes the family could not handle ═══════════════════════

    /// FLASH-7a: an order gated on a filler-supplied blob. The plain overload cannot
    /// carry it; the {FlashOpts} overload forwards it to the settler.
    function test_audit_FLASH_7_takerDataReachesTheValidators() public {
        FTakerDataValidator v = new FTakerDataValidator();
        Validator[] memory vs = new Validator[](1);
        vs[0] = Validator({target: address(v), data: ""});
        Order memory o = _order(600);
        o.validators = PackedEncode.validators(vs);
        bytes memory sig = _sign(o);

        vm.expectRevert();
        bal.executeFill(address(tA), OUT_A, o, sig, IN_B, 500, 0);

        bal.executeFill(address(tA), OUT_A, o, sig, IN_B, 500, 0, FlashOpts({recipient: address(0), takerData: "ok"}));
        assertEq(tA.balanceOf(maker), OUT_A, "filled with the attested blob");
    }

    /// FLASH-7d: the profit goes to a named recipient, and the two destinations where
    /// it would be claimable by the next caller — this contract and Settlement's
    /// shared EXECUTOR — are refused.
    function test_audit_FLASH_7_profitRecipientIsExplicitAndNeverTheExecutor() public {
        address treasury = address(0x7EA);
        Order memory o = _order(601);
        bytes memory sig = _sign(o);
        aaveS.executeFill(address(tA), OUT_A, o, sig, IN_B, 500, 0, FlashOpts({recipient: treasury, takerData: ""}));
        assertGt(tA.balanceOf(treasury), 0, "profit at the named recipient");

        Order memory o2 = _order(602);
        bytes memory sig2 = _sign(o2);
        vm.expectRevert(BaseFlashSolver.BadProfitRecipient.selector);
        aaveS.executeFill(
            address(tA), OUT_A, o2, sig2, IN_B, 500, 0, FlashOpts({recipient: address(aaveS), takerData: ""})
        );

        address exec = address(settlement.EXECUTOR());
        assertEq(aaveS.EXECUTOR(), exec, "executor read at construction");
        vm.prank(exec);
        vm.expectRevert(BaseFlashSolver.BadProfitRecipient.selector);
        aaveS.executeFill(address(tA), OUT_A, o2, sig2, IN_B, 500, 0);
    }

    /// FLASH-7b: the any-size sentinel fills whatever remains.
    function test_audit_FLASH_7_sentinelFillsTheRemainder() public {
        Order memory o = _order(603);
        bytes memory sig = _sign(o);
        morphoS.executeFill(address(tA), OUT_A, o, sig, type(uint256).max, 500, 0);
        assertEq(tA.balanceOf(maker), OUT_A, "whole order filled");
    }

    /// FLASH-7c: a SwapRouter02 deployment (no `deadline`) is detected at
    /// construction and spoken to in its own shape; the v1 shape would revert there.
    function test_audit_FLASH_7_swapRouter02IsSupported() public {
        FMockRouter02 r2 = new FMockRouter02();
        tA.mint(address(r2), 1_000e18);
        LimitOrderLeverageSolver s2 =
            new LimitOrderLeverageSolver(address(permit3), address(settlement), address(vault), address(r2));
        assertTrue(s2.ROUTER02(), "SwapRouter02 detected");
        assertFalse(bal.ROUTER02(), "v1 router detected as v1");
        s2.setupTokenApproval(address(tA));
        Order memory o = _order(604);
        bytes memory sig = _sign(o);
        s2.executeFill(address(tA), OUT_A, o, sig, IN_B, 500, 0);
        assertEq(tA.balanceOf(maker), OUT_A, "filled through SwapRouter02");
        assertEq(tA.balanceOf(address(s2)), 0, "nothing left behind");
    }

    /// FLASH-7e: an input already in the collateral asset needs no swap — the router
    /// would revert on a same-token pool.
    function test_audit_FLASH_7_sameTokenInputSkipsTheSwap() public {
        tA.mint(maker, IN_B);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        Order memory o = _plainOrder(605, address(tA), address(tA), IN_B, OUT_A);
        bytes memory sig = _sign(o);
        uint256 before = tA.balanceOf(address(this));
        bal.executeFill(address(tA), OUT_A, o, sig, IN_B, 500, 0);
        assertEq(tA.balanceOf(address(this)) - before, IN_B - OUT_A, "spread swept, no swap needed");
    }

    // ═══════════════════════ FLASH-8: negative guards per provider ═══════════════════════

    function test_audit_FLASH_8_aaveGuards() public {
        vm.expectRevert(AaveV3FlashSolver.OnlyPool.selector);
        aaveS.executeOperation(address(tA), 1, 0, address(aaveS), "");
        vm.prank(address(aave));
        vm.expectRevert(AaveV3FlashSolver.BadInitiator.selector);
        aaveS.executeOperation(address(tA), 1, 0, address(0xBAD), "");
        vm.prank(address(aave));
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        aaveS.executeOperation(address(tA), 1, 0, address(aaveS), "");

        vm.expectRevert(AaveV3MultiInputFlashSolver.OnlyPool.selector);
        aaveM.executeOperation(address(tA), 1, 0, address(aaveM), "");
        vm.prank(address(aave));
        vm.expectRevert(AaveV3MultiInputFlashSolver.BadInitiator.selector);
        aaveM.executeOperation(address(tA), 1, 0, address(0xBAD), "");
        vm.prank(address(aave));
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        aaveM.executeOperation(address(tA), 1, 0, address(aaveM), "");
    }

    function test_audit_FLASH_8_morphoGuards() public {
        vm.expectRevert(MorphoFlashSolver.OnlyMorpho.selector);
        morphoS.onMorphoFlashLoan(1, "");
        vm.prank(address(morpho));
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        morphoS.onMorphoFlashLoan(1, "");

        vm.expectRevert(MorphoMultiInputFlashSolver.OnlyMorpho.selector);
        morphoM.onMorphoFlashLoan(1, "");
        vm.prank(address(morpho));
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        morphoM.onMorphoFlashLoan(1, "");
    }

    function test_audit_FLASH_8_balancerMultiInputGuards() public {
        vm.expectRevert(MultiInputLeverageSolver.OnlyVault.selector);
        balM.receiveFlashLoan(new address[](0), new uint256[](0), new uint256[](0), "");
    }

    /// FLASH-8 / H-5: the Euler guards — a stray callback, a callback from an address
    /// other than the armed vault, and a "vault" that never calls back.
    function test_audit_FLASH_8_eulerGuards() public {
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        eulerS.onFlashLoan("");
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        eulerM.onFlashLoan("");

        Order memory o = _order(700);
        bytes memory sig = _sign(o);

        FForwardingVault fwd = new FForwardingVault(address(tA));
        vm.expectRevert(BaseFlashSolver.UnexpectedFlashProvider.selector);
        eulerS.executeFill(address(fwd), OUT_A, o, sig, IN_B, 500, 0);
        vm.expectRevert(BaseFlashSolver.UnexpectedFlashProvider.selector);
        eulerM.executeFill(address(fwd), OUT_A, o, sig, IN_B, _fees(), _mins());

        // A pre-existing balance makes the missing-callback path a theft attempt:
        // without the check the sweep would pay it to the caller on an unsigned order.
        tA.mint(address(eulerS), 5e18);
        tA.mint(address(eulerM), 5e18);
        FNoCallbackVault none = new FNoCallbackVault(address(tA));
        vm.expectRevert(BaseFlashSolver.FlashCallbackMissing.selector);
        eulerS.executeFill(address(none), OUT_A, o, sig, IN_B, 500, 0);
        vm.expectRevert(BaseFlashSolver.FlashCallbackMissing.selector);
        eulerM.executeFill(address(none), OUT_A, o, sig, IN_B, _fees(), _mins());
    }

    /// FLASH-8: the slippage bound reverts with the router's own reason (not a bare
    /// "it reverted somewhere").
    function test_audit_FLASH_8_repaymentSwapSlippageIsTheRoutersRevert() public {
        Order memory o = _order(701);
        bytes memory sig = _sign(o);
        vm.expectRevert(bytes("Too little received"));
        bal.executeFill(address(tA), OUT_A, o, sig, IN_B, 500, 1_000e18);
    }
}

contract FNoopMaker {
    bool public called;

    fallback() external {
        called = true;
    }
}
