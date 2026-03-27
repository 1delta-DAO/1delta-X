// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFlashLoanProvider, IFlashLoanReceiver} from "../../src/interfaces/IFlashLoanProvider.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Mock flash-loan provider for testing.
///         Transfers assets to the receiver, calls executeOperation, then pulls back principal + premium.
contract MockFlashLoan is IFlashLoanProvider {
    uint256 public constant PREMIUM_BPS = 9; // 0.09% (Aave V3 default)

    function flashLoan(address receiver, address[] calldata assets, uint256[] calldata amounts, bytes calldata params)
        external
        override
    {
        uint256[] memory premiums = new uint256[](assets.length);

        // Transfer assets to receiver
        for (uint256 i; i < assets.length; i++) {
            premiums[i] = (amounts[i] * PREMIUM_BPS) / 10_000;
            MockERC20(assets[i]).transfer(receiver, amounts[i]);
        }

        // Callback
        IFlashLoanReceiver(receiver).executeOperation(assets, amounts, premiums, msg.sender, params);

        // Pull back principal + premium
        for (uint256 i; i < assets.length; i++) {
            MockERC20(assets[i]).transferFrom(receiver, address(this), amounts[i] + premiums[i]);
        }
    }
}
