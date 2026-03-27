// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Settlement} from "../src/settlement/Settlement.sol";
import {
    Order,
    LendingItem,
    LendingOp,
    ConversionItem,
    Condition,
    ConditionType
} from "../src/types/DataTypes.sol";
import {OrderLib} from "../src/libraries/OrderLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLendingModule} from "./mocks/MockLendingModule.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockPredicate} from "./mocks/MockPredicate.sol";

contract SettlementTest is Test {
    using OrderLib for Order;

    Settlement settlement;
    MockLendingModule lendingModule;
    MockERC20 weth;
    MockERC20 usdc;

    // Maker = the user who signs orders
    uint256 makerPk = 0xA11CE;
    address maker = vm.addr(makerPk);

    // Solver = fills orders
    address solver = address(0xBEEF);

    function setUp() public {
        settlement = new Settlement();
        lendingModule = new MockLendingModule();
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Whitelist the lending module
        settlement.setModule(address(lendingModule), true);

        // Label addresses for trace readability
        vm.label(maker, "maker");
        vm.label(solver, "solver");
        vm.label(address(settlement), "settlement");
        vm.label(address(lendingModule), "lendingModule");
        vm.label(address(weth), "WETH");
        vm.label(address(usdc), "USDC");
    }

    // ══════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════

    function _signOrder(Order memory order) internal view returns (bytes memory) {
        // Need to convert memory order to the hash
        // We'll use the same logic as OrderLib but for memory structs
        bytes32 orderHash = _hashOrderMemory(order);
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), orderHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    bytes32 constant ORDER_TH = keccak256(
        "Order(address maker,uint256 nonce,uint256 deadline,Condition[] conditions,LendingItem[] items,ConversionItem[] conversions)"
        "Condition(uint8 conditionType,address target,uint256 threshold,bytes data)"
        "ConversionItem(address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut)"
        "LendingItem(uint8 operation,address module,address asset,uint256 amount,bytes data)"
    );
    bytes32 constant COND_TH = keccak256("Condition(uint8 conditionType,address target,uint256 threshold,bytes data)");
    bytes32 constant ITEM_TH = keccak256(
        "LendingItem(uint8 operation,address module,address asset,uint256 amount,bytes data)"
    );
    bytes32 constant CONV_TH = keccak256(
        "ConversionItem(address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut)"
    );

    function _hashOrderMemory(Order memory order) internal pure returns (bytes32) {
        bytes32 condsHash = _hashConds(order.conditions);
        bytes32 itemsHash = _hashItems(order.items);
        bytes32 convsHash = _hashConvs(order.conversions);

        return keccak256(
            abi.encode(ORDER_TH, order.maker, order.nonce, order.deadline, condsHash, itemsHash, convsHash)
        );
    }

    function _hashConds(Condition[] memory conds) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](conds.length);
        for (uint256 i; i < conds.length; i++) {
            h[i] = keccak256(
                abi.encode(COND_TH, conds[i].conditionType, conds[i].target, conds[i].threshold, keccak256(conds[i].data))
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashItems(LendingItem[] memory items) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](items.length);
        for (uint256 i; i < items.length; i++) {
            h[i] = keccak256(
                abi.encode(ITEM_TH, items[i].operation, items[i].module, items[i].asset, items[i].amount, keccak256(items[i].data))
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashConvs(ConversionItem[] memory convs) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](convs.length);
        for (uint256 i; i < convs.length; i++) {
            ConversionItem memory c = convs[i];
            h[i] = keccak256(
                abi.encode(CONV_TH, c.tokenIn, c.tokenOut, c.amountIn, c.decayStartTime, c.decayDuration, c.startAmountOut, c.endAmountOut)
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _noConditions() internal pure returns (Condition[] memory) {
        return new Condition[](0);
    }

    function _noConversions() internal pure returns (ConversionItem[] memory) {
        return new ConversionItem[](0);
    }

    // ══════════════════════════════════════════════
    //  Lending-only tests (MEV-based, no conversion)
    // ══════════════════════════════════════════════

    function test_simpleLendingDeposit() public {
        uint256 depositAmount = 1 ether;

        // Fund maker with WETH and approve settlement
        weth.mint(maker, depositAmount);
        vm.prank(maker);
        weth.approve(address(settlement), type(uint256).max);

        // Build order: deposit 1 WETH into lending module
        LendingItem[] memory items = new LendingItem[](1);
        items[0] = LendingItem({
            operation: LendingOp.DEPOSIT,
            module: address(lendingModule),
            asset: address(weth),
            amount: depositAmount,
            data: ""
        });

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: items,
            conversions: _noConversions()
        });

        bytes memory sig = _signOrder(order);

        // Solver settles the order
        vm.prank(solver);
        settlement.settle(order, sig);

        // Verify: maker's WETH deposited into lending module
        (uint256 deposited,) = lendingModule.positions(maker, address(weth));
        assertEq(deposited, depositAmount, "deposit tracked in module");
        assertEq(weth.balanceOf(maker), 0, "maker WETH spent");
    }

    function test_lendingWithdraw() public {
        // First deposit so there's something to withdraw
        uint256 amount = 2 ether;
        weth.mint(address(lendingModule), amount); // fund module's reserves
        lendingModule.deposit(address(weth), 0, maker, ""); // just set position state
        // Directly set the position for simplicity
        // Actually, let's do a proper deposit first
        weth.mint(maker, amount);
        vm.startPrank(maker);
        weth.approve(address(settlement), type(uint256).max);
        vm.stopPrank();

        // Deposit first via a settle call
        LendingItem[] memory depositItems = new LendingItem[](1);
        depositItems[0] = LendingItem(LendingOp.DEPOSIT, address(lendingModule), address(weth), amount, "");

        Order memory depositOrder = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: depositItems,
            conversions: _noConversions()
        });

        vm.prank(solver);
        settlement.settle(depositOrder, _signOrder(depositOrder));

        // Now withdraw
        LendingItem[] memory withdrawItems = new LendingItem[](1);
        withdrawItems[0] = LendingItem(LendingOp.WITHDRAW, address(lendingModule), address(weth), amount, "");

        Order memory withdrawOrder = Order({
            maker: maker,
            nonce: 1,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: withdrawItems,
            conversions: _noConversions()
        });

        vm.prank(solver);
        settlement.settle(withdrawOrder, _signOrder(withdrawOrder));

        assertEq(weth.balanceOf(maker), amount, "maker received WETH back");
        (uint256 deposited,) = lendingModule.positions(maker, address(weth));
        assertEq(deposited, 0, "deposit zeroed out");
    }

    function test_gasPriceCondition() public {
        weth.mint(maker, 1 ether);
        vm.prank(maker);
        weth.approve(address(settlement), type(uint256).max);

        LendingItem[] memory items = new LendingItem[](1);
        items[0] = LendingItem(LendingOp.DEPOSIT, address(lendingModule), address(weth), 1 ether, "");

        Condition[] memory conds = new Condition[](1);
        conds[0] = Condition(ConditionType.MAX_GAS_PRICE, address(0), 20 gwei, "");

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: conds,
            items: items,
            conversions: _noConversions()
        });

        bytes memory sig = _signOrder(order);

        // Gas price too high → revert
        vm.txGasPrice(30 gwei);
        vm.prank(solver);
        vm.expectRevert(Settlement.ConditionNotMet.selector);
        settlement.settle(order, sig);

        // Gas price within limit → success
        vm.txGasPrice(15 gwei);
        vm.prank(solver);
        settlement.settle(order, sig);
    }

    // ══════════════════════════════════════════════
    //  Conversion tests (dutch auction)
    // ══════════════════════════════════════════════

    /// @notice Simulate a leverage-long: solver provides WETH, maker deposits WETH,
    ///         borrows USDC, and USDC goes to solver.
    function test_leverageLongWithConversion() public {
        // Warp to a sensible timestamp so auction arithmetic doesn't underflow
        vm.warp(1000);

        uint256 makerWeth = 1 ether;
        uint256 solverWeth = 2 ether; // solver provides via flash-loan + swap
        uint256 totalDeposit = makerWeth + solverWeth;
        uint256 borrowUsdc = 2000e6; // borrow 2000 USDC

        // Fund mock lending module with USDC reserves (for borrow)
        usdc.mint(address(lendingModule), borrowUsdc);

        // Fund maker
        weth.mint(maker, makerWeth);
        vm.prank(maker);
        weth.approve(address(settlement), type(uint256).max);

        // Fund solver with WETH (simulating they already did flash-loan + swap)
        weth.mint(solver, solverWeth);
        vm.prank(solver);
        weth.approve(address(settlement), type(uint256).max);

        // Order: deposit 3 WETH, borrow 2000 USDC
        // Conversion: solver provides 2 WETH, takes 2000 USDC
        LendingItem[] memory items = new LendingItem[](2);
        items[0] = LendingItem(LendingOp.DEPOSIT, address(lendingModule), address(weth), totalDeposit, "");
        items[1] = LendingItem(LendingOp.BORROW, address(lendingModule), address(usdc), borrowUsdc, abi.encode(uint256(2))); // variable rate

        // Dutch auction: solver provides 2 WETH for 2000 USDC
        // Auction midpoint → solver must provide 2.0 WETH
        uint32 auctionStart = uint32(block.timestamp) - 50;
        uint32 auctionDuration = 100;

        ConversionItem[] memory conversions = new ConversionItem[](1);
        conversions[0] = ConversionItem({
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: borrowUsdc,
            decayStartTime: auctionStart,
            decayDuration: auctionDuration,
            startAmountOut: 2.1 ether, // best for maker
            endAmountOut: 1.9 ether // worst for maker
        });

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: items,
            conversions: conversions
        });

        bytes memory sig = _signOrder(order);

        vm.prank(solver);
        settlement.settle(order, sig);

        // Verify positions
        (uint256 deposited, uint256 borrowed) = lendingModule.positions(maker, address(weth));
        assertEq(deposited, totalDeposit, "WETH deposited");

        (, uint256 usdcBorrowed) = lendingModule.positions(maker, address(usdc));
        assertEq(usdcBorrowed, borrowUsdc, "USDC borrowed");

        // Solver should have received the borrowed USDC
        assertEq(usdc.balanceOf(solver), borrowUsdc, "solver received USDC");
    }

    // ══════════════════════════════════════════════
    //  Signature & validation tests
    // ══════════════════════════════════════════════

    function test_revertOnInvalidSignature() public {
        LendingItem[] memory items = new LendingItem[](0);

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: items,
            conversions: _noConversions()
        });

        // Sign with wrong key
        uint256 wrongPk = 0xDEAD;
        bytes32 orderHash = _hashOrderMemory(order);
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), orderHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(solver);
        vm.expectRevert(Settlement.InvalidSignature.selector);
        settlement.settle(order, badSig);
    }

    function test_revertOnExpiredOrder() public {
        vm.warp(1000);

        LendingItem[] memory items = new LendingItem[](0);

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp - 1, // already expired
            conditions: _noConditions(),
            items: items,
            conversions: _noConversions()
        });

        bytes memory sig = _signOrder(order);

        vm.prank(solver);
        vm.expectRevert(Settlement.OrderExpired.selector);
        settlement.settle(order, sig);
    }

    function test_revertOnNonceReuse() public {
        weth.mint(maker, 2 ether);
        vm.prank(maker);
        weth.approve(address(settlement), type(uint256).max);

        LendingItem[] memory items = new LendingItem[](1);
        items[0] = LendingItem(LendingOp.DEPOSIT, address(lendingModule), address(weth), 1 ether, "");

        Order memory order = Order({
            maker: maker,
            nonce: 42,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: items,
            conversions: _noConversions()
        });

        bytes memory sig = _signOrder(order);

        vm.prank(solver);
        settlement.settle(order, sig);

        // Second use of same nonce should revert
        vm.prank(solver);
        vm.expectRevert(Settlement.NonceUsed.selector);
        settlement.settle(order, sig);
    }

    function test_revertOnUnwhitelistedModule() public {
        address rogue = address(0xBAD);

        LendingItem[] memory items = new LendingItem[](1);
        items[0] = LendingItem(LendingOp.DEPOSIT, rogue, address(weth), 1 ether, "");

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: items,
            conversions: _noConversions()
        });

        bytes memory sig = _signOrder(order);

        vm.prank(solver);
        vm.expectRevert(Settlement.ModuleNotWhitelisted.selector);
        settlement.settle(order, sig);
    }

    // ══════════════════════════════════════════════
    //  Dutch auction pricing tests
    // ══════════════════════════════════════════════

    function test_dutchAuctionDecay() public {
        // Auction: starts at 100, decays to 80 over 100 seconds
        ConversionItem memory c = ConversionItem({
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: 1000e6,
            decayStartTime: uint32(block.timestamp),
            decayDuration: 100,
            startAmountOut: 100 ether,
            endAmountOut: 80 ether
        });

        // At start: should be 100
        uint256 amount = settlement.previewConversion(c);
        assertEq(amount, 100 ether);

        // At midpoint: should be 90
        vm.warp(block.timestamp + 50);
        amount = settlement.previewConversion(c);
        assertEq(amount, 90 ether);

        // At end: should be 80
        vm.warp(block.timestamp + 50);
        amount = settlement.previewConversion(c);
        assertEq(amount, 80 ether);

        // Past end: should still be 80
        vm.warp(block.timestamp + 100);
        amount = settlement.previewConversion(c);
        assertEq(amount, 80 ether);
    }

    // ══════════════════════════════════════════════
    //  Advanced conditions (oracle, balance, predicate)
    // ══════════════════════════════════════════════

    function test_oraclePriceTrigger_GTE() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(3000e8, 8); // ETH at $3000

        LendingItem[] memory items = new LendingItem[](0);

        // Condition: only settle when ETH >= $3500
        Condition[] memory conds = new Condition[](1);
        conds[0] = Condition(ConditionType.PRICE_GTE, address(feed), 3500e8, "");

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: conds,
            items: items,
            conversions: _noConversions()
        });
        bytes memory sig = _signOrder(order);

        // Price too low → revert
        vm.prank(solver);
        vm.expectRevert(Settlement.ConditionNotMet.selector);
        settlement.settle(order, sig);

        // Price rises above threshold → success
        feed.setPrice(3600e8);
        vm.prank(solver);
        settlement.settle(order, sig);
    }

    function test_oraclePriceTrigger_LTE() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(3000e8, 8);

        LendingItem[] memory items = new LendingItem[](0);

        // Condition: only settle when ETH <= $2500 (stop-loss trigger)
        Condition[] memory conds = new Condition[](1);
        conds[0] = Condition(ConditionType.PRICE_LTE, address(feed), 2500e8, "");

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: conds,
            items: items,
            conversions: _noConversions()
        });
        bytes memory sig = _signOrder(order);

        // Price too high → revert
        vm.prank(solver);
        vm.expectRevert(Settlement.ConditionNotMet.selector);
        settlement.settle(order, sig);

        // Price drops below threshold → success
        feed.setPrice(2400e8);
        vm.prank(solver);
        settlement.settle(order, sig);
    }

    function test_balanceCondition() public {
        LendingItem[] memory items = new LendingItem[](0);

        // Condition: only when maker has >= 5 WETH
        Condition[] memory conds = new Condition[](1);
        conds[0] = Condition(ConditionType.BALANCE_GTE, address(weth), 5 ether, "");

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: conds,
            items: items,
            conversions: _noConversions()
        });
        bytes memory sig = _signOrder(order);

        // Maker has 0 WETH → revert
        vm.prank(solver);
        vm.expectRevert(Settlement.ConditionNotMet.selector);
        settlement.settle(order, sig);

        // Mint enough → success
        weth.mint(maker, 5 ether);
        vm.prank(solver);
        settlement.settle(order, sig);
    }

    function test_predicateCondition() public {
        MockPredicate predicate = new MockPredicate(false);

        LendingItem[] memory items = new LendingItem[](0);

        // Condition: arbitrary predicate must return nonzero
        Condition[] memory conds = new Condition[](1);
        conds[0] = Condition(ConditionType.PREDICATE, address(predicate), 0, abi.encodeCall(MockPredicate.check, ()));

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: conds,
            items: items,
            conversions: _noConversions()
        });
        bytes memory sig = _signOrder(order);

        // Predicate returns false → revert
        vm.prank(solver);
        vm.expectRevert(Settlement.ConditionNotMet.selector);
        settlement.settle(order, sig);

        // Predicate returns true → success
        predicate.setResult(true);
        vm.prank(solver);
        settlement.settle(order, sig);
    }

    function test_multipleConditions_AND() public {
        vm.warp(1000);

        MockChainlinkFeed feed = new MockChainlinkFeed(3000e8, 8);

        LendingItem[] memory items = new LendingItem[](0);

        // Two conditions: ETH >= $2800 AND gas <= 25 gwei
        Condition[] memory conds = new Condition[](2);
        conds[0] = Condition(ConditionType.PRICE_GTE, address(feed), 2800e8, "");
        conds[1] = Condition(ConditionType.MAX_GAS_PRICE, address(0), 25 gwei, "");

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: conds,
            items: items,
            conversions: _noConversions()
        });
        bytes memory sig = _signOrder(order);

        // Price OK but gas too high → revert
        vm.txGasPrice(30 gwei);
        vm.prank(solver);
        vm.expectRevert(Settlement.ConditionNotMet.selector);
        settlement.settle(order, sig);

        // Gas OK but price too low → revert
        feed.setPrice(2500e8);
        vm.txGasPrice(20 gwei);
        vm.prank(solver);
        vm.expectRevert(Settlement.ConditionNotMet.selector);
        settlement.settle(order, sig);

        // Both conditions met → success
        feed.setPrice(3000e8);
        vm.txGasPrice(20 gwei);
        vm.prank(solver);
        settlement.settle(order, sig);
    }

    // ══════════════════════════════════════════════
    //  Order cancellation & nonce bitmap
    // ══════════════════════════════════════════════

    function test_cancelOrders() public {
        weth.mint(maker, 1 ether);
        vm.prank(maker);
        weth.approve(address(settlement), type(uint256).max);

        LendingItem[] memory items = new LendingItem[](1);
        items[0] = LendingItem(LendingOp.DEPOSIT, address(lendingModule), address(weth), 1 ether, "");

        Order memory order = Order({
            maker: maker,
            nonce: 7,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: items,
            conversions: _noConversions()
        });

        bytes memory sig = _signOrder(order);

        // Maker cancels the order
        uint256[] memory noncesToCancel = new uint256[](1);
        noncesToCancel[0] = 7;
        vm.prank(maker);
        settlement.cancelOrders(noncesToCancel);

        // Now settlement should revert
        vm.prank(solver);
        vm.expectRevert(Settlement.NonceUsed.selector);
        settlement.settle(order, sig);
    }

    function test_cancelMultipleOrders() public {
        uint256[] memory noncesToCancel = new uint256[](3);
        noncesToCancel[0] = 0;
        noncesToCancel[1] = 100;
        noncesToCancel[2] = 255;

        vm.prank(maker);
        settlement.cancelOrders(noncesToCancel);

        assertTrue(settlement.isNonceUsed(maker, 0));
        assertTrue(settlement.isNonceUsed(maker, 100));
        assertTrue(settlement.isNonceUsed(maker, 255));
        assertFalse(settlement.isNonceUsed(maker, 1));
        assertFalse(settlement.isNonceUsed(maker, 256));
    }

    function test_invalidateNonceWord() public {
        // Invalidate word 0 (nonces 0-255)
        vm.prank(maker);
        settlement.invalidateNonceWord(0);

        // All nonces in that word should be used
        assertTrue(settlement.isNonceUsed(maker, 0));
        assertTrue(settlement.isNonceUsed(maker, 128));
        assertTrue(settlement.isNonceUsed(maker, 255));

        // Nonce 256 (word 1) should still be available
        assertFalse(settlement.isNonceUsed(maker, 256));
    }

    function test_nonceBitmapCrossWord() public {
        // Use nonce 255 (last bit of word 0) and 256 (first bit of word 1)
        weth.mint(maker, 2 ether);
        vm.prank(maker);
        weth.approve(address(settlement), type(uint256).max);

        LendingItem[] memory items = new LendingItem[](1);
        items[0] = LendingItem(LendingOp.DEPOSIT, address(lendingModule), address(weth), 1 ether, "");

        // Settle nonce 255
        Order memory order1 = Order({
            maker: maker,
            nonce: 255,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: items,
            conversions: _noConversions()
        });
        vm.prank(solver);
        settlement.settle(order1, _signOrder(order1));

        // Settle nonce 256
        Order memory order2 = Order({
            maker: maker,
            nonce: 256,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: items,
            conversions: _noConversions()
        });
        vm.prank(solver);
        settlement.settle(order2, _signOrder(order2));

        assertTrue(settlement.isNonceUsed(maker, 255));
        assertTrue(settlement.isNonceUsed(maker, 256));
        // Adjacent nonces in different words are independent
        assertFalse(settlement.isNonceUsed(maker, 254));
        assertFalse(settlement.isNonceUsed(maker, 257));
    }

    // ══════════════════════════════════════════════
    //  Batch settlement
    // ══════════════════════════════════════════════

    function test_settleBatch() public {
        weth.mint(maker, 3 ether);
        usdc.mint(maker, 5000e6);
        vm.startPrank(maker);
        weth.approve(address(settlement), type(uint256).max);
        usdc.approve(address(settlement), type(uint256).max);
        vm.stopPrank();

        // Order 1: deposit 1 WETH
        LendingItem[] memory items1 = new LendingItem[](1);
        items1[0] = LendingItem(LendingOp.DEPOSIT, address(lendingModule), address(weth), 1 ether, "");
        Order memory order1 = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: items1,
            conversions: _noConversions()
        });

        // Order 2: deposit 2 WETH
        LendingItem[] memory items2 = new LendingItem[](1);
        items2[0] = LendingItem(LendingOp.DEPOSIT, address(lendingModule), address(weth), 2 ether, "");
        Order memory order2 = Order({
            maker: maker,
            nonce: 1,
            deadline: block.timestamp + 1 hours,
            conditions: _noConditions(),
            items: items2,
            conversions: _noConversions()
        });

        Order[] memory orders = new Order[](2);
        orders[0] = order1;
        orders[1] = order2;

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signOrder(order1);
        sigs[1] = _signOrder(order2);

        vm.prank(solver);
        settlement.settleBatch(orders, sigs);

        (uint256 deposited,) = lendingModule.positions(maker, address(weth));
        assertEq(deposited, 3 ether, "total deposited via batch");
    }
}
