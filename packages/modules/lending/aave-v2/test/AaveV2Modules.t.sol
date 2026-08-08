// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    AaveV2DepositModule,
    AaveV2RepayModule,
    AaveV2WithdrawModule,
    AaveV2BorrowModule
} from "../src/AaveV2Modules.sol";

// ── Mock contracts ────────────────────────────────────────────────────────────

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
        require(block.timestamp <= deadline, "expired");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        require(ecrecover(digest, v, r, s) == owner, "bad sig");
        allowance[owner][spender] = value;
    }
}

contract MockAaveV2Pool {
    MockERC2612 public asset;
    MockERC2612 public aToken;
    MockERC2612 public debtToken;

    constructor(MockERC2612 _asset, MockERC2612 _aToken, MockERC2612 _debtToken) {
        asset = _asset;
        aToken = _aToken;
        debtToken = _debtToken;
    }

    function deposit(address _asset, uint256 amount, address onBehalfOf, uint16) external {
        MockERC2612(_asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address _asset, uint256 amount, address to) external returns (uint256) {
        // Simplified: pool owns the backing asset, just transfer it out.
        // Real Aave burns aTokens internally (pool has admin role; no transferFrom needed).
        MockERC2612(_asset).transfer(to, amount);
        return amount;
    }

    function repay(address _asset, uint256 amount, uint256, address) external returns (uint256) {
        MockERC2612(_asset).transferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function borrow(address _asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        debtToken.mint(onBehalfOf, amount);
        MockERC2612(_asset).transfer(msg.sender, amount);
    }
}

contract MockPermit3 {
    function transferFrom(address from, address to, address token, uint160 amount) external {
        MockERC2612(token).transferFrom(from, to, amount);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

contract AaveV2ModulesTest is Test {
    MockERC2612 asset;
    MockERC2612 aToken;
    MockERC2612 debtToken;
    MockAaveV2Pool pool;
    MockPermit3 permit3;

    AaveV2DepositModule depositModule;
    AaveV2RepayModule repayModule;
    AaveV2WithdrawModule withdrawModule;
    AaveV2BorrowModule borrowModule;

    address settlement = address(0x5e77);
    address user;
    uint256 userKey;
    address receiver = address(0xCAFE);

    uint256 constant AMOUNT = 1000e18;

    function setUp() public {
        (user, userKey) = makeAddrAndKey("user");

        asset = new MockERC2612();
        aToken = new MockERC2612();
        debtToken = new MockERC2612();
        pool = new MockAaveV2Pool(asset, aToken, debtToken);
        permit3 = new MockPermit3();

        depositModule = new AaveV2DepositModule(address(permit3), settlement);
        repayModule = new AaveV2RepayModule(address(permit3), settlement);
        withdrawModule = new AaveV2WithdrawModule(address(permit3));
        borrowModule = new AaveV2BorrowModule(address(permit3));

        asset.mint(user, AMOUNT * 10);
        asset.mint(address(pool), AMOUNT * 10); // pool liquidity
    }

    function _permitSig(MockERC2612 tok, address spender, uint256 value)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                tok.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        user,
                        spender,
                        value,
                        tok.nonces(user),
                        block.timestamp + 1 hours
                    )
                )
            )
        );
        (v, r, s) = vm.sign(userKey, digest);
    }

    // ── Deposit ───────────────────────────────────────────────────────────────

    function test_deposit_standingAllowance() public {
        vm.prank(user);
        asset.approve(address(permit3), type(uint256).max);

        vm.prank(settlement);
        depositModule.makeOnBehalf(user, AMOUNT, abi.encode(address(pool), address(asset)));

        assertEq(aToken.balanceOf(user), AMOUNT);
    }

    function test_deposit_withPermit() public {
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(asset, address(permit3), AMOUNT);
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(settlement);
        depositModule.makeOnBehalf(user, AMOUNT, abi.encode(address(pool), address(asset), deadline, v, r, s));

        assertEq(aToken.balanceOf(user), AMOUNT);
        // ERC-20 allowance was consumed via permit
        assertEq(asset.nonces(user), 1);
    }

    function test_deposit_revertsIfNotSettlement() public {
        vm.expectRevert(AaveV2DepositModule.NotSettlement.selector);
        depositModule.makeOnBehalf(user, AMOUNT, abi.encode(address(pool), address(asset)));
    }

    // ── Repay ─────────────────────────────────────────────────────────────────

    function test_repay_standingAllowance() public {
        // Give user some debt to repay
        debtToken.mint(user, AMOUNT);

        vm.prank(user);
        asset.approve(address(permit3), type(uint256).max);

        bytes memory data = abi.encode(address(pool), address(asset), uint256(2), address(debtToken));
        vm.prank(settlement);
        repayModule.makeOnBehalf(user, AMOUNT, data);

        assertEq(asset.balanceOf(user), AMOUNT * 10 - AMOUNT);
    }

    function test_repay_withPermit() public {
        debtToken.mint(user, AMOUNT);

        (uint8 v, bytes32 r, bytes32 s) = _permitSig(asset, address(permit3), AMOUNT);
        uint256 deadline = block.timestamp + 1 hours;

        // data = (pool, asset, rateMode, debtToken, DustAction=0, deadline, v, r, s)
        bytes memory data =
            abi.encode(address(pool), address(asset), uint256(2), address(debtToken), uint8(0), deadline, v, r, s);
        vm.prank(settlement);
        repayModule.makeOnBehalf(user, AMOUNT, data);

        assertEq(asset.nonces(user), 1);
    }

    // ── Withdraw ──────────────────────────────────────────────────────────────

    function test_withdraw() public {
        // Give user aTokens and approve module via permit3
        aToken.mint(user, AMOUNT);
        vm.prank(user);
        aToken.approve(address(permit3), type(uint256).max);

        bytes memory data = abi.encode(address(pool), address(asset), address(aToken));
        vm.prank(address(permit3));
        withdrawModule.takeOnBehalf(user, AMOUNT, receiver, data);

        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_withdraw_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(address(pool), address(asset), address(aToken));
        vm.expectRevert(AaveV2WithdrawModule.OnlyPermit3.selector);
        withdrawModule.takeOnBehalf(user, AMOUNT, receiver, data);
    }

    // ── Borrow ────────────────────────────────────────────────────────────────

    function test_borrow() public {
        bytes memory data = abi.encode(address(pool), address(asset), uint256(2));
        vm.prank(address(permit3));
        borrowModule.takeOnBehalf(user, AMOUNT, receiver, data);

        assertEq(asset.balanceOf(receiver), AMOUNT);
        assertEq(debtToken.balanceOf(user), AMOUNT);
    }
}
