// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {AllowanceHolder} from "../../src/permit3/AllowanceHolder.sol";
import {IAllowanceHolder} from "../../src/interfaces/IAllowanceHolder.sol";

/// @dev Minimal ERC20. `balanceOf` is public, so it also serves as the
///      confused-deputy probe target.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
}

/// @dev Stand-in for a settlement/router contract: the operator of an `exec` that
///      pulls the caller's tokens through the holder.
contract MockSettler {
    error Boom(uint256 code);

    IAllowanceHolder public immutable HOLDER;
    address public lastSender;

    constructor(address holder) {
        HOLDER = IAllowanceHolder(holder);
    }

    /// @dev Pulls from the ERC-2771-style appended sender, i.e. whoever called `exec`.
    function pull(address token, address recipient, uint256 amount) external payable returns (bytes32) {
        address sender = _msgSender();
        lastSender = sender;
        HOLDER.transferFrom(token, sender, recipient, amount);
        return keccak256("pulled");
    }

    /// @dev Pulls naming an explicit owner — used to prove the holder's key binds
    ///      the payer, not just the operator.
    function pullFrom(address token, address from, address recipient, uint256 amount) external {
        HOLDER.transferFrom(token, from, recipient, amount);
    }

    function reenter(address token, uint256 amount, address target, bytes calldata data) external {
        HOLDER.exec(address(this), token, amount, payable(target), data);
    }

    function boom() external pure {
        revert Boom(7);
    }

    function _msgSender() internal pure returns (address s) {
        assembly {
            s := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }
}

/// @dev An operator that is not the target of the `exec`.
contract MockThief {
    IAllowanceHolder public immutable HOLDER;

    constructor(address holder) {
        HOLDER = IAllowanceHolder(holder);
    }

    function steal(address token, address from, address to, uint256 amount) external {
        HOLDER.transferFrom(token, from, to, amount);
    }
}

/// @title AllowanceHolderTest
/// @notice The holder's whole security story is that authority exists only inside
///         one call, is keyed to the account that granted it, and can never be
///         pointed at a token contract.
contract AllowanceHolderTest is Test {
    AllowanceHolder holder;
    MockERC20 token;
    MockSettler settler;

    address owner = address(0xA11CE);
    address victim = address(0x71C7);
    address recipient = address(0xCAFE);
    address attacker = address(0xBAD);

    function setUp() public {
        holder = new AllowanceHolder();
        token = new MockERC20();
        settler = new MockSettler(address(holder));

        token.mint(owner, 1_000e18);
        token.mint(victim, 500e18);

        // Both users grant the holder a standing ERC20 approval — the whole point
        // of the design, and the thing every guard below exists to protect.
        vm.prank(owner);
        token.approve(address(holder), type(uint256).max);
        vm.prank(victim);
        token.approve(address(holder), type(uint256).max);
    }

    function _pullData(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(MockSettler.pull, (address(token), recipient, amount));
    }

    // ════════════════ Happy path ════════════════

    function test_exec_pullsThroughOperator() public {
        vm.prank(owner);
        bytes memory result =
            holder.exec(address(settler), address(token), 100e18, payable(address(settler)), _pullData(100e18));

        assertEq(token.balanceOf(recipient), 100e18, "tokens delivered");
        assertEq(abi.decode(result, (bytes32)), keccak256("pulled"), "return data passed through");
        assertEq(settler.lastSender(), owner, "appended sender is the exec caller");
    }

    function test_exec_allowanceIsGoneAfterwards() public {
        vm.prank(owner);
        holder.exec(address(settler), address(token), 100e18, payable(address(settler)), _pullData(40e18));

        assertEq(holder.ephemeralAllowance(address(settler), owner, address(token)), 0, "nothing survives the call");

        // The unused 60e18 cannot be picked up later.
        vm.expectRevert(abi.encodeWithSelector(IAllowanceHolder.InsufficientEphemeralAllowance.selector, 0));
        settler.pullFrom(address(token), owner, recipient, 60e18);
    }

    function test_exec_forwardsValue() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        holder.exec{value: 1 ether}(
            address(settler), address(token), 100e18, payable(address(settler)), _pullData(1e18)
        );

        assertEq(address(settler).balance, 1 ether, "msg.value forwarded");
        assertEq(address(holder).balance, 0, "holder keeps nothing");
    }

    // ════════════════ Authority is bounded ════════════════

    function test_transferFrom_revert_outsideExec() public {
        vm.expectRevert(abi.encodeWithSelector(IAllowanceHolder.InsufficientEphemeralAllowance.selector, 0));
        settler.pullFrom(address(token), owner, recipient, 1e18);
    }

    function test_transferFrom_revert_overGrant() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceHolder.InsufficientEphemeralAllowance.selector, 10e18));
        holder.exec(address(settler), address(token), 10e18, payable(address(settler)), _pullData(10e18 + 1));
    }

    /// @dev The grant names ONE operator. A second contract cannot ride along on it
    ///      even while the exec is in flight.
    function test_transferFrom_revert_wrongOperator() public {
        MockThief thief = new MockThief(address(holder));
        bytes memory data = abi.encodeCall(MockThief.steal, (address(token), owner, attacker, 1e18));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceHolder.InsufficientEphemeralAllowance.selector, 0));
        holder.exec(address(settler), address(token), 100e18, payable(address(thief)), data);
    }

    /// @dev The key binds the PAYER. An operator with a live grant from the attacker
    ///      cannot redirect it at someone else's balance.
    function test_transferFrom_revert_otherOwnersTokens() public {
        bytes memory data = abi.encodeCall(MockSettler.pullFrom, (address(token), victim, attacker, 100e18));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceHolder.InsufficientEphemeralAllowance.selector, 0));
        holder.exec(address(settler), address(token), 100e18, payable(address(settler)), data);

        assertEq(token.balanceOf(victim), 500e18, "victim untouched");
    }

    // ════════════════ Confused deputy ════════════════

    /// @dev THE attack the `_rejectIfERC20` probe exists for. Every user's approval
    ///      sits on the holder, so if `exec` could call a token DIRECTLY, an
    ///      attacker would simply have the holder spend them — its own `amount`
    ///      grant never enters into it.
    function test_exec_revert_targetIsERC20() public {
        bytes memory drain = abi.encodeCall(MockERC20.transferFrom, (victim, attacker, 500e18));

        vm.prank(attacker);
        vm.expectRevert(IAllowanceHolder.ConfusedDeputy.selector);
        holder.exec(address(settler), address(token), 0, payable(address(token)), drain);

        assertEq(token.balanceOf(victim), 500e18, "victim untouched");
        assertEq(token.balanceOf(attacker), 0);
    }

    /// @dev Short calldata takes the fallback probe address rather than reading a
    ///      first argument that isn't there.
    function test_exec_revert_targetIsERC20_shortCalldata() public {
        vm.prank(attacker);
        vm.expectRevert(IAllowanceHolder.ConfusedDeputy.selector);
        holder.exec(address(settler), address(token), 0, payable(address(token)), hex"deadbeef");
    }

    function test_exec_revert_targetIsSelf() public {
        vm.prank(attacker);
        vm.expectRevert(IAllowanceHolder.InvalidTarget.selector);
        holder.exec(address(settler), address(token), 0, payable(address(holder)), "");
    }

    // ════════════════ Nesting ════════════════

    function test_exec_revert_nestedSameTriple() public {
        // settler re-enters exec for (settler, settler-as-owner...) — the inner call
        // is made BY the settler, so owner differs and the triple differs; force a
        // true collision by having the owner's own exec re-enter with the same key.
        bytes memory inner = abi.encodeCall(
            MockSettler.reenter, (address(token), 1e18, address(settler), abi.encodeCall(MockSettler.boom, ()))
        );

        // Outer grant: (operator=settler, owner=settler, token). The settler's
        // re-entry recreates exactly that triple.
        vm.prank(address(settler));
        vm.expectRevert(IAllowanceHolder.AllowanceInFlight.selector);
        holder.exec(address(settler), address(token), 100e18, payable(address(settler)), inner);
    }

    function test_exec_nestedDifferentTokenIsFine() public {
        MockERC20 other = new MockERC20();
        other.mint(address(settler), 10e18);
        vm.prank(address(settler));
        other.approve(address(holder), type(uint256).max);

        bytes memory inner = abi.encodeCall(
            MockSettler.reenter,
            (
                address(other),
                5e18,
                address(settler),
                abi.encodeCall(MockSettler.pull, (address(other), recipient, 5e18))
            )
        );

        vm.prank(address(settler));
        holder.exec(address(settler), address(token), 100e18, payable(address(settler)), inner);

        assertEq(other.balanceOf(recipient), 5e18, "inner exec on a different token succeeded");
        assertEq(holder.ephemeralAllowance(address(settler), address(settler), address(other)), 0);
        assertEq(holder.ephemeralAllowance(address(settler), address(settler), address(token)), 0);
    }

    // ════════════════ Reverts ════════════════

    function test_exec_bubblesTargetRevert() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MockSettler.Boom.selector, uint256(7)));
        holder.exec(
            address(settler), address(token), 100e18, payable(address(settler)), abi.encodeCall(MockSettler.boom, ())
        );

        assertEq(holder.ephemeralAllowance(address(settler), owner, address(token)), 0, "grant unwound with the revert");
    }
}
