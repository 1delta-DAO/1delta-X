// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {UniversalSettlement, Order, Item, ItemOp, Validator} from "@core/settlement/UniversalSettlement.sol";

/// @dev Minimal, freely-mintable ERC20. Enough for Permit3's transfer paths —
///      no fork / real tokens, so the pure-protocol suites run fast and are
///      RPC-independent.
contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name) {
        name = _name;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Non-fork harness for the pure-protocol suites (relevant-state, batch fill,
///      nonce/cancellation). Deploys Permit3 + Settlement + three mock tokens and
///      provides EIP-712 order builders + signing. Mirrors the hashing in
///      {OrderHash} byte-for-byte.
abstract contract MockSettlementBase is Test {
    Permit3 permit3;
    UniversalSettlement settlement;

    uint256 makerPk = 0xA11CE;
    address maker = vm.addr(makerPk);
    uint256 solverPk = 0x50_1E5;
    address solver = vm.addr(solverPk);

    MockERC20 tA; // "maker gives" default (tokenIn)
    MockERC20 tB; // "maker gets" default (tokenOut)
    MockERC20 tC; // spare, for multi-input / pair tests

    function setUp() public virtual {
        permit3 = new Permit3();
        settlement = new UniversalSettlement(address(permit3));

        tA = new MockERC20("tA");
        tB = new MockERC20("tB");
        tC = new MockERC20("tC");

        vm.label(maker, "maker");
        vm.label(solver, "solver");
        vm.label(address(settlement), "settlement");
    }

    // ──────────────────── Approvals / funding ────────────────────

    /// @dev Maker: ERC20→Permit3 once, then a per-token Permit3 allowance to a spender.
    function _makerApprove(address spender, address token, uint256 cap) internal {
        vm.startPrank(maker);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(spender, token, uint160(cap), 0);
        vm.stopPrank();
    }

    function _solverApprove(address spender, address token, uint256 cap) internal {
        vm.startPrank(solver);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(spender, token, uint160(cap), 0);
        vm.stopPrank();
    }

    // ──────────────────── Array helpers ────────────────────

    function _a1(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _u1(uint256 x) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = x;
    }

    // ──────────────────── Order builder ────────────────────

    function _plainOrder(uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (Order memory)
    {
        return Order({
            maker: maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(tokenIn),
            amountIn: _u1(amountIn),
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: _a1(tokenOut),
            startAmountOut: _u1(amountOut),
            endAmountOut: _u1(amountOut),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
    }

    // ──────────────────── EIP-712: Order (mirrors OrderHash.sol) ────────────────────

    bytes32 constant ITEM_TH = keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");
    bytes32 constant VALIDATOR_TH = keccak256("Validator(address target,bytes data)");
    bytes32 constant ORDER_TH = keccak256(
        "Order(address maker,uint256 nonce,uint256 deadline,address[] tokenIn,uint256[] amountIn,uint32 decayStartTime,uint32 decayDuration,address[] tokenOut,uint256[] startAmountOut,uint256[] endAmountOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAmountIn,Item[] items,Validator[] validators,Validator[] invariants)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "Validator(address target,bytes data)"
    );

    function _hashAddresses(address[] memory a) internal pure returns (bytes32) {
        bytes32[] memory w = new bytes32[](a.length);
        for (uint256 i; i < a.length; i++) {
            w[i] = bytes32(uint256(uint160(a[i])));
        }
        return keccak256(abi.encodePacked(w));
    }

    function _hashUints(uint256[] memory a) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a));
    }

    function _hashItems(Item[] memory items) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](items.length);
        for (uint256 i; i < items.length; i++) {
            h[i] = keccak256(
                abi.encode(
                    ITEM_TH,
                    uint8(items[i].op),
                    items[i].module,
                    items[i].amount,
                    items[i].recipient,
                    keccak256(items[i].data)
                )
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashValidators(Validator[] memory v) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](v.length);
        for (uint256 i; i < v.length; i++) {
            h[i] = keccak256(abi.encode(VALIDATOR_TH, v[i].target, keccak256(v[i].data)));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashOrder(Order memory o) internal pure returns (bytes32) {
        bytes memory head = abi.encode(
            ORDER_TH,
            o.maker,
            o.nonce,
            o.deadline,
            _hashAddresses(o.tokenIn),
            _hashUints(o.amountIn),
            o.decayStartTime,
            o.decayDuration,
            _hashAddresses(o.tokenOut),
            _hashUints(o.startAmountOut),
            _hashUints(o.endAmountOut)
        );
        bytes memory tail = abi.encode(
            o.exclusiveFiller,
            o.exclusivityEndTime,
            o.minFillAmountIn,
            _hashItems(o.items),
            _hashValidators(o.validators),
            _hashValidators(o.invariants)
        );
        return keccak256(bytes.concat(head, tail));
    }

    function _sign(Order memory o) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign an order with an arbitrary key (for bad-signature tests).
    function _signWith(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
