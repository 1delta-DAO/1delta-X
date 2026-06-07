// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Counter} from "../src/Counter.sol";

contract CounterTest is Test {
    Counter counter;

    event CountChanged(uint256 newCount);

    function setUp() public {
        counter = new Counter();
    }

    function test_initialCountIsZero() public view {
        assertEq(counter.count(), 0);
    }

    function test_increment() public {
        counter.increment();
        assertEq(counter.count(), 1);
    }

    function test_incrementEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit CountChanged(1);
        counter.increment();
    }

    function test_decrement() public {
        counter.increment();
        counter.increment();
        counter.decrement();
        assertEq(counter.count(), 1);
    }

    function test_decrementRevertsOnUnderflow() public {
        vm.expectRevert(Counter.CountUnderflow.selector);
        counter.decrement();
    }

    function test_reset() public {
        counter.increment();
        counter.increment();
        counter.reset();
        assertEq(counter.count(), 0);
    }

    function testFuzz_incrementMultiple(uint8 n) public {
        for (uint8 i = 0; i < n; i++) {
            counter.increment();
        }
        assertEq(counter.count(), n);
    }
}
