// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, LegOut} from "@core/settlement/Settlement.sol";
import {NativeForwarderFactory, WethUnwrapForwarder} from "@periphery/NativeForwarderFactory.sol";

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

/// @dev Minimal WETH: mint-free deposit/withdraw over the MockERC20 book.
contract MockWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth send");
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract EthRejecter {
    // no receive/fallback — plain ETH transfers revert

    }

/// @title NativeForwarder
/// @notice Maker receives NATIVE ETH from a WETH output leg: the signed
///         `recipient` is the maker's CREATE2-predicted {WethUnwrapForwarder};
///         delivery lands as WETH, `sweep()` unwraps and pushes ETH. Covers the
///         pay-before-deploy ordering, permissionless-but-maker-only sweeping,
///         and the ETH-rejecting-maker failure mode.
contract NativeForwarderTest is MockSettlementBase {
    MockWETH weth;
    NativeForwarderFactory factory;

    uint256 constant IN_ = 1_000e18; // tA the maker sells
    uint256 constant OUT_ = 2 ether; // WETH the solver delivers

    function setUp() public override {
        super.setUp();
        weth = new MockWETH();
        factory = new NativeForwarderFactory(address(weth));
        // Solver holds WETH (wrapped) and allows the settlement to pull it.
        vm.deal(solver, OUT_);
        vm.startPrank(solver);
        weth.deposit{value: OUT_}();
        weth.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(weth), uint160(OUT_), 0);
        vm.stopPrank();
        // Maker sells tA.
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), IN_);
    }

    function _orderPayingForwarder(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(weth), IN_, OUT_);
        o.legsOut = PackedEncode.setLegOutRecipient(o.legsOut, 0, factory.forwarderFor(maker)); // signed BEFORE deployment
    }

    function test_nativeOut_fill_thenDeployAndSweep() public {
        Order memory order = _orderPayingForwarder(1);
        bytes memory sig = _sign(order);

        // Fill pays WETH to the PREDICTED (still codeless) forwarder address.
        vm.prank(solver);
        settlement.fill(order, sig, IN_);
        address fwd = factory.forwarderFor(maker);
        assertEq(weth.balanceOf(fwd), OUT_, "leg delivered to the predicted address");

        // Anyone deploys + sweeps; the maker ends with raw ETH.
        factory.deploy(payable(maker));
        WethUnwrapForwarder(payable(fwd)).sweep();
        assertEq(maker.balance, OUT_, "maker received native ETH");
        assertEq(weth.balanceOf(fwd), 0, "forwarder drained");
    }

    function test_sweep_byStranger_stillPaysMaker() public {
        address fwd = factory.deploy(payable(maker));
        vm.deal(solver, 1 ether);
        vm.prank(solver);
        weth.deposit{value: 1 ether}();
        vm.prank(solver);
        weth.transfer(fwd, 1 ether);

        vm.prank(address(0xBAD)); // hostile sweeper
        WethUnwrapForwarder(payable(fwd)).sweep();
        assertEq(maker.balance, 1 ether, "sweep can only accelerate the maker's payout");
    }

    function test_sweep_alsoForwardsRawEthDonations() public {
        address fwd = factory.deploy(payable(maker));
        vm.deal(fwd, 0.5 ether);
        WethUnwrapForwarder(payable(fwd)).sweep();
        assertEq(maker.balance, 0.5 ether, "raw ETH swept too");
    }

    function test_sweep_ethRejectingMaker_reverts_fundsWait() public {
        address payable rejecter = payable(address(new EthRejecter()));
        address fwd = factory.deploy(rejecter);
        vm.deal(fwd, 1 ether);
        vm.expectRevert(WethUnwrapForwarder.EthSendFailed.selector);
        WethUnwrapForwarder(payable(fwd)).sweep();
        assertEq(fwd.balance, 1 ether, "funds wait, retriable");
    }

    function test_predictedAddress_matchesDeployment() public {
        assertEq(factory.deploy(payable(maker)), factory.forwarderFor(maker), "CREATE2 prediction exact");
    }
}
