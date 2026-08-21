// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IDeployFactory
/// @notice The shared CREATE2 factory the whole multi-chain rollout deploys through,
///         live at {DEPLOY_FACTORY} on every chain surveyed in
///         `docs/deterministic-deployment.md` §4.
///
///  This is an EXTERNAL, already-deployed contract — there is no source for it in
///  this repo and nothing here deploys it. It is declared as an interface so the
///  scripts can call it and so the address lives in exactly one place.
///
///  ⚠ FOUR VARIANTS OF ITS RUNTIME CODE EXIST across chains (§1.1). That is not a
///  determinism problem — a CREATE2 child depends on the factory ADDRESS, not its
///  code — but only so long as every variant derives addresses identically. That
///  was verified behaviourally, not assumed: for one fixed `(salt, initCodeHash)`
///  all four return the same {computeAddress}, and a simulated {deploy} returns
///  that same address from two different senders, so no variant salts with
///  `msg.sender`. Re-run that check before adding a chain whose factory hash is
///  none of the four listed (§1.1 found MegaETH's variant exactly this way).
///
///  ⚠ `deploy` HAS NO ACCESS CONTROL and the salt is not sender-scoped — anyone may
///  call it with any salt. This cannot let a stranger plant hostile code at an
///  address you predicted, because the address binds `keccak256(init_code)` and
///  constructor arguments are part of init code. What it does allow, once your
///  constructor inputs are public, is someone deploying your BYTE-IDENTICAL
///  contract at your address on a chain you have not reached yet. The contract is
///  then the one you wanted, but your own run reverts on the collision — which is
///  why {DeployCore} treats "already deployed with the right code" as success and
///  verifies the code rather than assuming it.
interface IDeployFactory {
    /// @notice CREATE2-deploy `bytecode` (creation code ‖ ABI-encoded ctor args).
    /// @dev    NOT payable — no constructor in this package needs ETH, but it does
    ///         rule out funding at construction. Emits NO event, which is why the
    ///         deployment registry has to be maintained off-chain (§1).
    function deploy(bytes32 salt, bytes memory bytecode) external returns (address addr);

    /// @notice The address `deploy(salt, bytecode)` would produce.
    function computeAddress(bytes32 salt, bytes32 bytecodeHash) external view returns (address);
}

// The one address the rollout depends on. Identical on every chain in the matched
// set; a chain where this is absent can never join it (§7 step 3). A plain comment
// rather than a natspec tag: solc rejects @notice on file-level variables.
address constant DEPLOY_FACTORY = 0x16c4Dc0f662E2bEceC91fC5E7aeeC6a25684698A;
