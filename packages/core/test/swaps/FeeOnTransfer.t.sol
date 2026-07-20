// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, Validator} from "@core/settlement/UniversalSettlement.sol";
import {MinBalanceInvariant} from "@core/validators/MinBalanceInvariant.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev A fee-on-transfer ERC20: the recipient is credited `amount − fee`, the fee
///      is burned. Standard FoT semantics — the sender is debited the full amount.
contract MockFoT {
    string public name = "FoT";
    string public symbol = "FOT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint256 public immutable feeBps;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _feeBps) {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - amt;
        _xfer(f, to, amt);
        return true;
    }

    function _xfer(address f, address t, uint256 amt) internal {
        balanceOf[f] -= amt; // sender debited the full amount
        uint256 fee = amt * feeBps / 10_000;
        balanceOf[t] += amt - fee; // recipient credited net
        totalSupply -= fee; // fee burned
    }
}

/// @dev Fee-on-transfer / rebasing tokens in the SIMPLE (single-order plain swap)
/// case. Per the settlement README's FoT stance: Settlement moves NOMINAL amounts
/// and never re-measures receipts, so a simple buy/sell of such a token is
/// FUNCTIONAL — the party on the receiving leg simply nets less (exactly like a
/// swap aggregator, which quotes conservatively). The maker can opt into a hard
/// floor with {MinBalanceInvariant}. (The netted batch/item paths, which DO use
/// balance-delta accounting, are out of scope — they revert safely on FoT.)
contract FeeOnTransferTest is CoreSettlementBase {
    MockFoT fot;
    MinBalanceInvariant minBal;

    uint256 constant FEE_BPS = 100; // 1%

    function setUp() public override {
        super.setUp();
        fot = new MockFoT(FEE_BPS);
        minBal = new MinBalanceInvariant();
        vm.label(address(fot), "FoT");
    }

    function _approveMakerFoT(uint256 cap) internal {
        vm.startPrank(maker);
        fot.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(fot), uint160(cap), 0);
        vm.stopPrank();
    }

    function _approveSolverFoT(uint256 cap) internal {
        vm.startPrank(solver);
        fot.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(fot), uint160(cap), 0);
        vm.stopPrank();
    }

    // ── SELL a FoT token → USDC. The SOLVER is on the receiving leg for the FoT,
    //    so it bears the fee (self-protected: it prices the fee in). Fill succeeds. ──
    function test_sellFoT_solverBearsFee() public {
        uint256 amtIn = 1_000 ether;
        fot.mint(maker, amtIn);
        _approveMakerFoT(amtIn);
        deal(USDC, solver, 2_000e6);
        _approveSolverSide(2_000e6, USDC);

        Order memory o = _order(maker, 1, address(fot), USDC, amtIn, 2_000e6, new Item[](0));
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, amtIn);

        assertEq(fot.balanceOf(maker), 0, "maker's FoT fully spent (nominal)");
        assertEq(IERC20(USDC).balanceOf(maker), 2_000e6, "maker received full USDC output");
        // Solver received the FoT MINUS the 1% fee — the documented, aggregator-style outcome.
        assertEq(fot.balanceOf(solver), amtIn - amtIn * FEE_BPS / 10_000, "solver netted FoT minus fee");
    }

    // ── BUY a FoT token (SELL USDC → FoT). The MAKER is on the receiving leg, so
    //    the maker nets less than the nominal output — but the fill still succeeds. ──
    function test_buyFoT_makerNetsLess_stillFills() public {
        uint256 usdcIn = 2_000e6;
        uint256 fotOut = 1_000 ether;
        deal(USDC, maker, usdcIn);
        _approveMakerToSettlement(USDC, usdcIn);
        fot.mint(solver, fotOut);
        _approveSolverFoT(fotOut);

        Order memory o = _order(maker, 2, USDC, address(fot), usdcIn, fotOut, new Item[](0));
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, usdcIn);

        // Fill succeeded; maker received the FoT minus the fee (silently underpaid,
        // exactly as the README documents for a passive maker on a FoT output).
        assertEq(fot.balanceOf(maker), fotOut - fotOut * FEE_BPS / 10_000, "maker netted FoT minus fee");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker paid the full USDC input");
    }

    // ── The maker CAN protect the FoT-buy with a MinBalanceInvariant floor: if the
    //    fee eats past the floor, the whole fill reverts (aggregator min-return). ──
    function test_buyFoT_minBalanceInvariant_protectsMaker() public {
        uint256 usdcIn = 2_000e6;
        uint256 fotOut = 1_000 ether;
        deal(USDC, maker, usdcIn);
        _approveMakerToSettlement(USDC, usdcIn);
        fot.mint(solver, fotOut);
        _approveSolverFoT(fotOut);

        // Floor demands the FULL nominal output — the 1% fee breaches it → revert.
        Validator[] memory invs = new Validator[](1);
        invs[0] = Validator({target: address(minBal), data: abi.encode(address(fot), maker, fotOut)});
        Order memory o = _orderWithInvariants(3, USDC, address(fot), usdcIn, fotOut, new Item[](0), invs);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(); // InvariantFailed — maker's post-fill FoT balance < floor
        settlement.fill(o, sig, usdcIn);

        // A realistic floor (accepting the fee) passes.
        uint256 netFloor = fotOut - fotOut * FEE_BPS / 10_000;
        invs[0].data = abi.encode(address(fot), maker, netFloor);
        Order memory o2 = _orderWithInvariants(4, USDC, address(fot), usdcIn, fotOut, new Item[](0), invs);
        bytes memory sig2 = _sign(o2);
        vm.prank(solver);
        settlement.fill(o2, sig2, usdcIn);
        assertEq(fot.balanceOf(maker), netFloor, "fills at the accepted net floor");
    }
}
