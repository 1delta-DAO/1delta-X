// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

/// @dev A lender reduced to the two properties that matter for the cross-chain
///      leverage flow, modelled on the real Liquity/Aave shape:
///
///        • SUPPLY is permissionless on behalf of anyone — you are giving them
///          money, so no grant is needed. (Aave `supply`, Morpho `supply`.)
///        • BORROW is NOT. It requires the position owner to have delegated, which
///          is the destination-chain authorisation a bridged user does not have.
///          (Aave credit delegation, Liquity's remove-manager, Morpho `authorize`.)
///
///      That asymmetry is the whole reason a leverage destination order needs a
///      user-owned funnel that can grant on its own behalf.
contract MockLendingPool {
    address public immutable COLL;
    address public immutable DEBT;

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;
    /// @notice position owner → module allowed to borrow for them.
    mapping(address => mapping(address => bool)) public isDelegate;

    error NotDelegated();

    constructor(address coll, address debt) {
        COLL = coll;
        DEBT = debt;
    }

    /// @notice Position owner grants a module borrow rights. Must be called BY the
    ///         position owner — the funnel does this via `executeSigned`.
    function approveDelegate(address module) external {
        isDelegate[msg.sender][module] = true;
    }

    function revokeDelegate(address module) external {
        isDelegate[msg.sender][module] = false;
    }

    /// @notice Permissionless on behalf of `user`.
    function supply(address user, uint256 amount) external {
        MockERC20(COLL).transferFrom(msg.sender, address(this), amount);
        collateralOf[user] += amount;
    }

    /// @notice Gated on the owner's delegation.
    function borrow(address user, uint256 amount, address receiver) external {
        if (!isDelegate[user][msg.sender]) revert NotDelegated();
        debtOf[user] += amount;
        MockERC20(DEBT).mint(receiver, amount);
    }
}

/// @dev MAKE leg: pulls the collateral from `onBehalfOf` via Permit3 and supplies
///      it to their position. Mirrors e.g. `LiquityV2AddCollModule`.
contract MockSupplyModule is IMakerModule {
    IPermit3 public immutable PERMIT3;
    address public immutable SETTLEMENT;
    MockLendingPool public immutable POOL;

    error OnlySettlement();

    constructor(address permit3, address settlement, MockLendingPool pool) {
        PERMIT3 = IPermit3(permit3);
        SETTLEMENT = settlement;
        POOL = pool;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata) external override {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        PERMIT3.transferFrom(onBehalfOf, address(this), POOL.COLL(), uint160(amount));
        MockERC20(POOL.COLL()).approve(address(POOL), amount);
        POOL.supply(onBehalfOf, amount);
    }
}

/// @dev TAKE leg: borrows against `onBehalfOf` and sends the proceeds to
///      `receiver` (Settlement, which then pays the solver). Mirrors e.g.
///      `LiquityV2TakerModule`. Called only by Permit3, after the taker-allowance
///      gate — so the fill needs BOTH a Permit3 taker approval and the pool's own
///      delegation, and the funnel grants both.
contract MockBorrowModule is ITakerModule {
    address public immutable PERMIT3;
    MockLendingPool public immutable POOL;

    error OnlyPermit3();

    constructor(address permit3, MockLendingPool pool) {
        PERMIT3 = permit3;
        POOL = pool;
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata) external override {
        if (msg.sender != PERMIT3) revert OnlyPermit3();
        POOL.borrow(onBehalfOf, amount, receiver);
    }
}
