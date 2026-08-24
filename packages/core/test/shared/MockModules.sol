// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFillModule} from "@core/interfaces/IFillModule.sol";
import {IPriceModule} from "@core/interfaces/IPriceModule.sol";
import {ISettlementModule} from "@core/interfaces/ISettlementModule.sol";
import {Order} from "@core/settlement/Structs.sol";

/// @title MockModules
/// @notice Minimal stand-ins for the four module seams the core dispatches to.
///
///  The core deliberately ships NO modules of its own — every one of them lives in
///  `packages/modules`, because nothing in `packages/core/src` imports a module and
///  a module is reached only through a maker-signed `pricingModule` / `fillModule` /
///  item `module` field. What core must still prove is that its side of each seam is
///  correct: that it resolves the delta the fill module returns, pins and clamps the
///  bump the price module returns, and hands a SETTLE item its exact pro-rata slice.
///
///  Testing that against a shipped product would measure two things at once. These
///  mocks measure one: each is a directly-controllable answer, so a failing test
///  points at the core rather than at a module's own arithmetic.
///
///  @dev Suite-local mocks (`MockFillModule`, `EchoFillModule`, `ClampingFillModule`,
///       `MockDepositMaker`, `ReentrantMakerModule`) stay where they are — this file
///       is only for the seams shared across suites.

/// @dev Consumes the entire remaining denominator, so one fill completes the order.
///      The all-or-nothing shape, without depending on `FullFillModule`.
contract FullFillMock is IFillModule {
    function resolveFill(Order calldata order, uint256 prevFilled, uint256, bytes calldata)
        external
        pure
        returns (uint256)
    {
        return order.fillTotal - prevFilled;
    }
}

/// @dev Answers one fixed bump, whatever the order or the clock says. Lets a test
///      state the pinned value it expects instead of deriving it from a real
///      module's curve.
contract FixedBumpModule is IPriceModule {
    uint256 public immutable BPS;

    constructor(uint256 bps) {
        BPS = bps;
    }

    function bump(bytes32, address, address, uint256, uint256, uint256, bytes calldata, bytes calldata, bytes calldata)
        external
        view
        returns (uint256)
    {
        return BPS;
    }
}

/// @dev Prices on fill progress: `START_BPS` at 0% filled → `END_BPS` at 100%,
///      linear in between. The volume axis, reproduced locally so core's
///      module-dispatch tests do not import the shipped `RangePriceModule`.
contract ProgressBumpModule is IPriceModule {
    uint256 public immutable START_BPS;
    uint256 public immutable END_BPS;

    constructor(uint256 startBps, uint256 endBps) {
        START_BPS = startBps;
        END_BPS = endBps;
    }

    function bump(
        bytes32,
        address,
        address,
        uint256 prevFilled,
        uint256 total,
        uint256,
        bytes calldata,
        bytes calldata,
        bytes calldata
    ) external view returns (uint256) {
        if (total == 0 || prevFilled == 0) return START_BPS;
        if (prevFilled >= total) return END_BPS;
        return END_BPS >= START_BPS
            ? START_BPS + ((END_BPS - START_BPS) * prevFilled) / total
            : START_BPS - ((START_BPS - END_BPS) * prevFilled) / total;
    }
}

/// @dev Records every SETTLE dispatch instead of transferring anything. This is what
///      makes core's slice arithmetic DIRECTLY assertable: a test reads the exact
///      `slice` the core computed rather than inferring it from a token balance, and
///      `totalSlice` proves slices accumulate to the item's signed `amount` across
///      partial fills.
contract SliceRecorderModule is ISettlementModule {
    struct Call {
        address maker;
        address filler;
        uint256 slice;
        bytes data;
    }

    address public immutable SETTLEMENT;
    Call[] internal _calls;
    uint256 public totalSlice;

    error OnlySettlement();

    constructor(address settlement) {
        SETTLEMENT = settlement;
    }

    function settle(address maker, address filler, uint256 slice, bytes calldata data) external {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        _calls.push(Call(maker, filler, slice, data));
        totalSlice += slice;
    }

    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    function callAt(uint256 i) external view returns (Call memory) {
        return _calls[i];
    }
}

/// @dev Minimal ERC-721 / ERC-1155 surfaces the settle mocks below need.
interface IMock721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IMock1155 {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

/// @dev Hands the maker's ERC-721 to the filler. Deliberately IGNORES `slice`, which
///      is the indivisible shape: an order using it must be full-fill only, and the
///      core's {Base.SettleSliceZero} floor is what stops a dust fill from taking the
///      token for nothing.
contract Erc721SettleMock is ISettlementModule {
    address public immutable SETTLEMENT;

    error OnlySettlement();

    constructor(address settlement) {
        SETTLEMENT = settlement;
    }

    function settle(address maker, address filler, uint256, bytes calldata data) external {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        (address collection, uint256 tokenId) = abi.decode(data, (address, uint256));
        IMock721(collection).safeTransferFrom(maker, filler, tokenId);
    }
}

/// @dev The divisible counterpart: moves exactly `slice` units, so a test can watch
///      the core's pro-rata arithmetic land in real balances across partial fills.
contract Erc1155SettleMock is ISettlementModule {
    address public immutable SETTLEMENT;

    error OnlySettlement();

    constructor(address settlement) {
        SETTLEMENT = settlement;
    }

    function settle(address maker, address filler, uint256 slice, bytes calldata data) external {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        (address collection, uint256 id) = abi.decode(data, (address, uint256));
        IMock1155(collection).safeTransferFrom(maker, filler, id, slice, "");
    }
}

/// @dev A Chainlink-shaped feed, for benches that need a real price module wired
///      to something answerable.
///
///      ⚠ A LOCAL COPY, DELIBERATELY. The identical mock exists in the chainlink
///      module's own suite, and importing it from there would be a `.t.sol` →
///      `.t.sol` edge across a package boundary — which drags that package's
///      whole test suite into the `core` profile, re-coupling the core gas
///      baseline to a module release. Fifteen lines duplicated is the cheaper
///      side of that trade; see the header of this file.
contract PriceFeedMock {
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 10;
    uint80 public answeredInRound = 10;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, 0, updatedAt, answeredInRound);
    }
}
