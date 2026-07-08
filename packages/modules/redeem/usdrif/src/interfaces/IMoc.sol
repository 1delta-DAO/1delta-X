// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Money-on-Chain (MoC) RIF-bucket core surface used by the USDRIF exit
///         integration. Verified on Rootstock mainnet behind an ERC1967 proxy at
///         0xA27024Ed70035E46dba712609fc2Afa1c97aA36A.
interface IMocRif {
    /// @notice Redeem `qTP_` of pegged token `tp_` (USDRIF) for the asset
    ///         collateral (RIF). Escrows the TP and queues a `RedeemTP` op in the
    ///         MocQueue; the RIF is delivered to `recipient_` when the op executes
    ///         (~30–90s later). Payable: `msg.value` funds the queue exec fee.
    /// @return operId The queue operation id (track via MocQueue).
    function redeemTP(
        address tp_,
        uint256 qTP_,
        uint256 qACmin_,
        address recipient_,
        address vendor_
    ) external payable returns (uint256 operId);

    /// @notice Live price of pegged token `tp_` in AC (RIF) terms, 1e18-scaled.
    function getPACtp(address tp_) external view returns (uint256);
}

/// @notice MoC deferred-operation queue. Verified on Rootstock mainnet behind an
///         ERC1967 proxy at 0x47f5014115d3bb29B20b5168Ee75050D6f8c3Bf1.
interface IMocQueue {
    /// @notice Id of the first not-yet-executed operation. Operations execute
    ///         strictly FIFO, so `operId < firstOperId()` ⟺ the op has been
    ///         dequeued (executed or errored). This is the settlement signal.
    function firstOperId() external view returns (uint256);

    /// @notice Total number of operations ever enqueued (next id to assign).
    function operIdCount() external view returns (uint256);

    /// @notice Per-operation type + queued block. `operType == 0` (none) once the
    ///         op has been executed and deleted.
    function opersInfo(uint256 operId) external view returns (uint8 operType, uint248 queuedBlk);

    /// @notice Base exec-cost unit per operation of `operType_` (scaled by gas
    ///         price to get the actual fee). `OperType.redeemTP == 4`.
    function execCost(uint8 operType_) external view returns (uint256);

    /// @notice Native exec fee (wei) required to queue an op of `operType_` at the
    ///         current `tx.gasprice` — this is the exact `msg.value` `redeemTP`
    ///         expects (`execCost * tx.gasprice`).
    function getExecFee(uint8 operType_) external view returns (uint256);

    /// @notice True once the head operation has waited long enough to execute.
    function readyToExecute(uint256 blocksSinceLastPublication_) external view returns (bool);

    /// @notice True when the queue holds no pending operations.
    function isEmpty() external view returns (bool);

    /// @notice The only address allowed to call `execute` (the multi-collateral guard).
    function mocMultiCollateralGuard() external view returns (address);

    /// @notice Execute up to `maxOperPerBatch_` pending operations. Restricted to
    ///         `mocMultiCollateralGuard()`. Does not revert on a single op's
    ///         failure — it emits `OperationError` and moves on.
    function execute(
        address executor_,
        uint256 maxOperPerBatch_,
        uint256 blocksSinceLastPublication_
    ) external returns (uint256 totalExecutionFee, uint256 totalOperExecuted);
}

/// @notice Classic MoC price-provider surface: `peek()` returns a 1e18-scaled
///         price packed in bytes32 plus a validity flag.
interface IPriceProvider {
    function peek() external view returns (bytes32 price, bool has);
}
