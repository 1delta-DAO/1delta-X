// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {PermissionlessCallModule} from "../src/PermissionlessCallModule.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

/// @dev A Convex-`earmarkRewards`-shaped poke: anyone may call it, and it pays the
///      CALLER a bounty in `token`.
contract AuditBountyPoker {
    address public immutable token;
    uint256 public immutable bounty;

    constructor(address token_, uint256 bounty_) {
        token = token_;
        bounty = bounty_;
    }

    function poke() external {
        IERC20(token).transfer(msg.sender, bounty);
    }
}

/// @dev The CallSpec wire shape after audit 2026-09-30 MISC-MOD-5, declared locally so
///      this suite encodes the blob independently of the module's own struct.
struct AuditCallSpec {
    address target;
    bytes callData;
    address bountyToken;
}

/// @title Audit20260930PermissionlessCallTest
/// @notice Regression for audit 2026-09-30 MISC-MOD-5: a poke that pays `msg.sender`
///         left its bounty on the shared {PermissionlessCallModule}, claimable by the
///         next self-signed order. A named `bountyToken` is now forwarded to the
///         maker inside the same item, and pre-existing module balance is untouched.
contract Audit20260930PermissionlessCallTest is CoreSettlementBase {
    PermissionlessCallModule module;
    AuditBountyPoker poker;

    uint256 constant USDC_IN = 1_500e6;
    uint256 constant WETH_OUT = 1 ether;
    uint256 constant BOUNTY = 7e6;
    uint256 constant STRAY = 3e6;

    function setUp() public override {
        super.setUp();
        module = new PermissionlessCallModule(address(settlement));
        poker = new AuditBountyPoker(USDC, BOUNTY);
        deal(USDC, address(poker), BOUNTY * 10);
    }

    function _order(uint256 nonce, bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(module), amount: 1, recipient: address(0), data: data});
        return _order(maker, nonce, USDC, WETH, USDC_IN, WETH_OUT, items);
    }

    function test_audit_MISC_MOD_5_pokeBounty_forwardedToMaker() public {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveMakerToSettlement(USDC, USDC_IN);
        _approveSolverSide(WETH_OUT, WETH);
        deal(USDC, address(module), STRAY); // somebody else's residue — must stay put

        bytes memory data = abi.encode(
            AuditCallSpec({
                target: address(poker), callData: abi.encodeCall(AuditBountyPoker.poke, ()), bountyToken: USDC
            })
        );
        Order memory order = _order(0, data);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);

        assertEq(IERC20(USDC).balanceOf(maker), BOUNTY, "the maker's poke bounty reached the maker");
        assertEq(IERC20(USDC).balanceOf(address(module)), STRAY, "nothing of the bounty left on the module");
    }
}
