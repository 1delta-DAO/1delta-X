// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20PermitTransferModule} from "../src/ERC20PermitTransferModule.sol";

// ── Mock contracts ────────────────────────────────────────────────────────────

/// @dev ERC-20 + EIP-2612 mock. Signs permits via the vm cheatcode.
contract MockERC2612 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public DOMAIN_SEPARATOR;
    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MockToken"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline, "permit expired");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recovered = ecrecover(digest, v, r, s);
        require(recovered == owner, "invalid permit sig");
        allowance[owner][spender] = value;
    }
}

/// @dev Minimal Permit3 stub — mimics permit3.transferFrom by moving ERC-20 tokens.
contract MockPermit3 {
    function transferFrom(address from, address to, address token, uint160 amount) external {
        MockERC2612(token).transferFrom(from, to, amount);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

contract ERC20PermitTransferModuleTest is Test {
    MockERC2612 token;
    MockPermit3 permit3;
    ERC20PermitTransferModule module;

    uint256 constant TRANSFER_AMOUNT = 1000e6; // 1000 USDC
    uint256 constant FEE = 5e6; // 5 USDC
    uint256 constant GROSS = TRANSFER_AMOUNT + FEE;

    address settlement = address(0x5e77);
    address user;
    uint256 userKey;
    address recipient = address(0xCAFE);
    address solver = address(0x50C0); // Settlement acts as receiver in our test

    function setUp() public {
        (user, userKey) = makeAddrAndKey("user");

        token = new MockERC2612();
        permit3 = new MockPermit3();
        module = new ERC20PermitTransferModule(address(permit3));

        token.mint(user, GROSS * 10);
    }

    // ── Helper: build a permit sig ────────────────────────────────────────────

    function _permitSig(uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        user,
                        address(permit3),
                        value,
                        token.nonces(user),
                        deadline
                    )
                )
            )
        );
        (v, r, s) = vm.sign(userKey, digest);
    }

    // ── Happy path: permit + transfer + fee ───────────────────────────────────

    function test_transferWithPermit() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(GROSS, deadline);

        bytes memory data = abi.encode(address(token), recipient, TRANSFER_AMOUNT, deadline, v, r, s);

        vm.prank(address(permit3));
        module.takeOnBehalf(user, GROSS, solver, data);

        assertEq(token.balanceOf(recipient), TRANSFER_AMOUNT, "recipient got wrong amount");
        assertEq(token.balanceOf(solver), FEE, "solver got wrong fee");
        assertEq(token.balanceOf(user), GROSS * 10 - GROSS, "user balance wrong");
    }

    // ── Without permit (standing ERC-20 allowance) ────────────────────────────

    function test_transferWithoutPermit_standingAllowance() public {
        // User pre-approves Permit3 at ERC-20 level (standing allowance path).
        vm.prank(user);
        token.approve(address(permit3), type(uint256).max);

        bytes memory data = abi.encode(address(token), recipient, TRANSFER_AMOUNT);

        vm.prank(address(permit3));
        module.takeOnBehalf(user, GROSS, solver, data);

        assertEq(token.balanceOf(recipient), TRANSFER_AMOUNT);
        assertEq(token.balanceOf(solver), FEE);
    }

    // ── Zero fee (full transfer, no solver fee) ───────────────────────────────

    function test_transferZeroFee() public {
        vm.prank(user);
        token.approve(address(permit3), type(uint256).max);

        bytes memory data = abi.encode(address(token), recipient, TRANSFER_AMOUNT);

        vm.prank(address(permit3));
        module.takeOnBehalf(user, TRANSFER_AMOUNT, solver, data);

        assertEq(token.balanceOf(recipient), TRANSFER_AMOUNT);
        assertEq(token.balanceOf(solver), 0);
    }

    // ── Reverts ───────────────────────────────────────────────────────────────

    function test_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(address(token), recipient, TRANSFER_AMOUNT);
        vm.expectRevert(ERC20PermitTransferModule.OnlyPermit3.selector);
        module.takeOnBehalf(user, GROSS, solver, data);
    }

    function test_revertsIfTransferAmountExceedsGross() public {
        vm.prank(user);
        token.approve(address(permit3), type(uint256).max);

        // transferAmount > gross
        bytes memory data = abi.encode(address(token), recipient, GROSS + 1);

        vm.prank(address(permit3));
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20PermitTransferModule.TransferAmountExceedsGross.selector, GROSS + 1, GROSS
            )
        );
        module.takeOnBehalf(user, GROSS, solver, data);
    }

    function test_revertsOnExpiredPermit() public {
        uint256 deadline = block.timestamp - 1; // already expired
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(GROSS, deadline);

        bytes memory data = abi.encode(address(token), recipient, TRANSFER_AMOUNT, deadline, v, r, s);

        vm.prank(address(permit3));
        vm.expectRevert("permit expired");
        module.takeOnBehalf(user, GROSS, solver, data);
    }
}
