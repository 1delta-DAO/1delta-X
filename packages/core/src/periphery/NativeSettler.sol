// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UniversalSettlement, Order, CallbackMode} from "../settlement/UniversalSettlement.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title NativeSettler
/// @notice Periphery that lets a maker pay NATIVE currency into a WETH-denominated
///         order, self-settled in one transaction — WITHOUT any change to the
///         ERC20-only core (Settlement/Permit3 never touch native).
///
///         Flow (single-asset SELL, `tokenIn == WETH`): the maker calls this with
///         `msg.value` of native. We wrap it and hand the WETH to the maker so the
///         core's Permit3 pull (which always charges `order.maker`) can collect it
///         as the order's input. We then act as the FILLER of a PostInputs
///         `fillWithCallback`: the core pays us that WETH, the callback swaps it
///         into `tokenOut` on the frontend-supplied route, and Settlement delivers
///         `tokenOut` to the maker.
///
///         Native is thus handled entirely at the edge. Note the maker must
///         (a) sign the order and (b) have a standing Permit3 allowance on WETH to
///         Settlement (a one-time setup, like approving any router). Because the
///         input arrives as `msg.value`, the maker MUST be the caller — this entry
///         is not relayable for the input side (you cannot sign away native ETH).
///
/// @dev    The WETH round-trips (wrap → maker → pulled back to us) purely to satisfy
///         the core's "charge order.maker" invariant; a native-aware core could
///         skip it. Any positive tokenOut slippage the route yields stays here and
///         can be swept by the operator — the maker is guaranteed the signed output
///         by Settlement's mandatory, reverting delivery.
contract NativeSettler {
    IWETH public immutable weth;
    UniversalSettlement public immutable settlement;

    error NotMaker();
    error TokenInNotWeth();

    constructor(address _weth, address _settlement) {
        weth = IWETH(_weth);
        settlement = UniversalSettlement(_settlement);
    }

    /// @param order        maker == msg.sender; single-asset SELL with tokenIn[0] == WETH.
    /// @param sig           the maker's EIP-712 order signature.
    /// @param fillAmount    anchor units (tokenIn[0]) to fill.
    /// @param dexTarget     the frontend's route target (invoked in the fill callback).
    /// @param dexCallData   route calldata; must pull our WETH and return `tokenOut` to us.
    function settleFromNative(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address dexTarget,
        bytes calldata dexCallData
    ) external payable returns (uint256[] memory outs) {
        if (msg.sender != order.maker) revert NotMaker();
        if (order.tokenIn.length != 1 || order.tokenIn[0] != address(weth)) revert TokenInNotWeth();

        // 1) Wrap native → WETH and give it to the maker so the core can charge it.
        weth.deposit{value: msg.value}();
        weth.transfer(order.maker, msg.value);

        // 2) The DEX pulls the WETH the core pays us; Settlement pulls the tokenOut we
        //    produce (via the direct-approval fallback in `_deliverOutputs`).
        SafeTransferLib.forceApprove(address(weth), dexTarget, type(uint256).max);
        SafeTransferLib.forceApprove(order.tokenOut[0], address(settlement), type(uint256).max);

        // 3) Self-settle as the filler.
        outs = settlement.fillWithCallback(
            order, sig, fillAmount, dexTarget, dexCallData, CallbackMode.PostInputs
        );
    }
}
