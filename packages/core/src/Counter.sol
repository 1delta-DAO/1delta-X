// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract Counter {
    uint256 public count;

    event CountChanged(uint256 newCount);

    error CountUnderflow();

    function increment() external {
        count++;
        emit CountChanged(count);
    }

    function decrement() external {
        if (count == 0) revert CountUnderflow();
        count--;
        emit CountChanged(count);
    }

    function reset() external {
        count = 0;
        emit CountChanged(0);
    }
}
