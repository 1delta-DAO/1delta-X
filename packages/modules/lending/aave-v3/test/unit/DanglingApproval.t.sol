// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AaveV3DepositModule} from "../../src/AaveV3Modules.sol";

/// @dev Minimal ERC-20 with a real allowance ledger — the point of these tests.
contract ApprovalERC20 {
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A `pool` that accepts the call and pulls NOTHING — the case that leaves a
///      standing allowance behind. An attacker-authored order can name any address
///      here, including one that deliberately never pulls.
contract NonConsumingPool {
    function supply(address, uint256, address, uint16) external {}
}

contract Permit3Stub {
    function transferFrom(address from, address to, address token, uint160 amount) external {
        ApprovalERC20(token).transferFrom(from, to, amount);
    }
}

/// @title AaveDanglingApprovalTest
/// @notice F25 / lead A-3 — a scoped approval must be CLEARED, not left standing.
///
///  `pool` is decoded from the order's `data` on a SHARED singleton module, and
///  anyone can author an order naming themselves as maker — so the spender is
///  attacker-choosable. `SafeTransferLib.ensureApproval`'s own note forbids the
///  shape: "Do NOT use with a spender decoded from caller/order data on a shared
///  contract — a standing max allowance to an attacker-chosen spender lets it drain
///  any future balance of `token`."
///
///  There is no direct theft here: `forceApprove` writes an exact amount rather
///  than accumulating, and the tokens involved are the attacker's own. What it
///  leaves is a permanent third-party claim on any FUTURE balance of that token at
///  the module — which is precisely what converts a later residual-stranding bug
///  into a theft. F25/G-1 and G-6 were six such bugs, in sibling packages, found in
///  the same audit. One SSTORE removes the class.
contract AaveDanglingApprovalTest is Test {
    ApprovalERC20 asset;
    NonConsumingPool pool;
    Permit3Stub permit3;
    AaveV3DepositModule module;

    address settlement = address(0x5E77);
    address maker = address(0xABCD);
    uint256 constant AMOUNT = 1_000e18;

    function setUp() public {
        asset = new ApprovalERC20();
        pool = new NonConsumingPool();
        permit3 = new Permit3Stub();
        module = new AaveV3DepositModule(address(permit3), settlement);

        asset.mint(maker, AMOUNT);
        vm.prank(maker);
        asset.approve(address(permit3), AMOUNT);
    }

    function test_deposit_leavesNoStandingAllowanceToAnOrderSuppliedPool() public {
        bytes memory data = abi.encode(address(pool), address(asset));

        vm.prank(settlement);
        module.makeOnBehalf(maker, AMOUNT, data);

        assertEq(
            asset.allowance(address(module), address(pool)),
            0,
            "module must leave no standing allowance to an order-supplied pool"
        );
    }

    /// @dev The clear must not depend on the target having consumed anything: this
    ///      pool pulls nothing at all, which is the worst case and the whole point.
    function test_deposit_clearsEvenWhenTheTargetConsumesNothing() public {
        bytes memory data = abi.encode(address(pool), address(asset));

        vm.prank(settlement);
        module.makeOnBehalf(maker, AMOUNT, data);

        assertEq(asset.balanceOf(address(module)), AMOUNT, "pool pulled nothing, as constructed");
        assertEq(asset.allowance(address(module), address(pool)), 0, "and the allowance is still cleared");
    }
}
