// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC4626WithdrawModule} from "../src/ERC4626WithdrawModule.sol";
import {ITimelockERC4626} from "../src/interfaces/ITimelockERC4626.sol";

// ── Minimal mock contracts ────────────────────────────────────────────────────

/// @dev Bare-minimum ERC-20 used for both the share token and the underlying asset.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;

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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Mock timelock vault. requestRedeem pulls shares from caller and queues them;
///      claimRedeem releases the underlying after lockDuration has elapsed.
contract MockTimelockVault {
    MockERC20 public shareToken;
    MockERC20 public underlyingAsset;
    uint256 public lockDuration;

    struct Request {
        address requester;
        uint256 shares;
        uint256 requestedAt;
    }

    uint256 private _nextId = 1;
    mapping(uint256 => Request) private _requests;

    /// @dev Pin the id the next `requestRedeem` hands back, so a test can model a
    ///      vault that reuses ids (the ERC-7540 `REQUEST_ID_0` convention, where
    ///      every request shares id 0 and the vault tracks per-controller).
    function setNextRequestId(uint256 id) external {
        _nextId = id;
    }

    error TooEarly();
    error NotRequester();
    error NoRequest();

    constructor(MockERC20 _shareToken, MockERC20 _underlyingAsset, uint256 _lockDuration) {
        shareToken = _shareToken;
        underlyingAsset = _underlyingAsset;
        lockDuration = _lockDuration;
    }

    function asset() external view returns (address) {
        return address(underlyingAsset);
    }

    function requestRedeem(uint256 shares) external returns (uint256 requestId) {
        // Pull shares from caller (caller must have approved this vault).
        shareToken.transferFrom(msg.sender, address(this), shares);
        requestId = _nextId++;
        _requests[requestId] = Request({requester: msg.sender, shares: shares, requestedAt: block.timestamp});
    }

    function claimRedeem(uint256 requestId, address receiver) external returns (uint256 assets) {
        Request memory req = _requests[requestId];
        if (req.requester == address(0)) revert NoRequest();
        if (req.requester != msg.sender) revert NotRequester();
        if (block.timestamp < req.requestedAt + lockDuration) revert TooEarly();

        delete _requests[requestId];

        // 1:1 shares → underlying (simplified; real vaults apply exchange rate).
        assets = req.shares;
        underlyingAsset.transfer(receiver, assets);
    }
}

/// @dev Minimal Permit3 stub that lets the test drive transferFrom calls directly.
///      The settlement and taker gates are bypassed — this is a unit test, not an
///      integration test — so we just expose the two wiring points the module needs.
contract MockPermit3 {
    // Records the last transferFrom call for assertions.
    address public lastFrom;
    address public lastTo;
    address public lastToken;
    uint256 public lastAmount;

    function transferFrom(address from, address to, address token, uint160 amount) external {
        lastFrom = from;
        lastTo = to;
        lastToken = token;
        lastAmount = amount;
        // Actually move tokens so the module's subsequent vault.approve is meaningful.
        MockERC20(token).transferFrom(from, to, amount);
    }
}

// ── Test suite ────────────────────────────────────────────────────────────────

contract ERC4626WithdrawModuleTest is Test {
    MockERC20 shareToken;
    MockERC20 underlyingAsset;
    MockTimelockVault vault;
    MockPermit3 permit3;
    ERC4626WithdrawModule module;

    address settlement = address(0x5e77);
    address user = address(0xBEEF);
    address receiver = address(0xCAFE);

    uint256 constant LOCK = 3 days;
    uint256 constant SHARES = 1000e18;

    function setUp() public {
        shareToken = new MockERC20();
        underlyingAsset = new MockERC20();
        vault = new MockTimelockVault(shareToken, underlyingAsset, LOCK);
        permit3 = new MockPermit3();
        module = new ERC4626WithdrawModule(address(permit3), settlement);

        // Fund the user with shares.
        shareToken.mint(user, SHARES);

        // Fund the vault with underlying so it can pay out.
        underlyingAsset.mint(address(vault), SHARES * 10);

        // User approves Permit3 (the mock) to move their shares.
        vm.prank(user);
        shareToken.approve(address(permit3), type(uint256).max);
    }

    // ── Phase 1: Request ─────────────────────────────────────────────────────

    function test_requestStoresWithdrawal() public {
        bytes memory data = abi.encode(address(vault), address(shareToken));

        vm.prank(settlement);
        module.makeOnBehalf(user, SHARES, data);

        // The vault pulls requestId=1 (first request).
        (address beneficiary, uint256 unlocksAt) = module.pendingWithdrawals(address(vault), 1);
        assertEq(beneficiary, user);
        assertEq(unlocksAt, block.timestamp + LOCK);
        // Shares moved from user to vault (via module).
        assertEq(shareToken.balanceOf(user), 0);
        assertEq(shareToken.balanceOf(address(vault)), SHARES);
    }

    function test_requestRevertsIfNotSettlement() public {
        bytes memory data = abi.encode(address(vault), address(shareToken));
        vm.expectRevert(ERC4626WithdrawModule.NotSettlement.selector);
        module.makeOnBehalf(user, SHARES, data);
    }

    // ── Phase 2: Claim ───────────────────────────────────────────────────────

    function _doRequest() internal returns (uint256 requestId) {
        bytes memory data = abi.encode(address(vault), address(shareToken));
        vm.prank(settlement);
        module.makeOnBehalf(user, SHARES, data);
        requestId = 1;
    }

    function test_claimAfterLockSucceeds() public {
        uint256 requestId = _doRequest();

        vm.warp(block.timestamp + LOCK);

        bytes memory claimData = abi.encode(address(vault), requestId, uint256(0));
        vm.prank(address(permit3));
        module.takeOnBehalf(user, SHARES, receiver, claimData);

        // Receiver got the underlying assets.
        assertEq(underlyingAsset.balanceOf(receiver), SHARES);

        // Pending withdrawal was cleared.
        (address beneficiary,) = module.pendingWithdrawals(address(vault), requestId);
        assertEq(beneficiary, address(0));
    }

    function test_claimRevertsBeforeLock() public {
        uint256 requestId = _doRequest();

        vm.warp(block.timestamp + LOCK - 1);

        bytes memory claimData = abi.encode(address(vault), requestId, uint256(0));
        vm.prank(address(permit3));
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626WithdrawModule.TimelockActive.selector,
                block.timestamp + 1, // unlocksAt
                block.timestamp // currentTime
            )
        );
        module.takeOnBehalf(user, SHARES, receiver, claimData);
    }

    function test_claimRevertsIfNotPermit3() public {
        uint256 requestId = _doRequest();
        vm.warp(block.timestamp + LOCK);

        bytes memory claimData = abi.encode(address(vault), requestId, uint256(0));
        vm.expectRevert(ERC4626WithdrawModule.OnlyPermit3.selector);
        module.takeOnBehalf(user, SHARES, receiver, claimData);
    }

    function test_claimRevertsIfWrongBeneficiary() public {
        uint256 requestId = _doRequest();
        vm.warp(block.timestamp + LOCK);

        bytes memory claimData = abi.encode(address(vault), requestId, uint256(0));
        vm.prank(address(permit3));
        vm.expectRevert(ERC4626WithdrawModule.NotBeneficiary.selector);
        module.takeOnBehalf(address(0xDEAD), SHARES, receiver, claimData);
    }

    function test_claimRevertsIfNoPendingWithdrawal() public {
        bytes memory claimData = abi.encode(address(vault), uint256(99), uint256(0));
        vm.prank(address(permit3));
        vm.expectRevert(ERC4626WithdrawModule.NoPendingWithdrawal.selector);
        module.takeOnBehalf(user, SHARES, receiver, claimData);
    }

    function test_claimRevertsIfBelowMinAssets() public {
        uint256 requestId = _doRequest();
        vm.warp(block.timestamp + LOCK);

        // The slippage floor now lives in `data` (maker-signed); `amount` is the
        // Permit3 cap, not the floor.
        bytes memory claimData = abi.encode(address(vault), requestId, SHARES + 1);
        vm.prank(address(permit3));
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626WithdrawModule.InsufficientAssets.selector, SHARES, SHARES + 1)
        );
        module.takeOnBehalf(user, SHARES, receiver, claimData);
    }

    // ──────────────── Regression: allowance is a CAP, not a floor ────────────────

    /// Permit3 decrements `amount`, so `amount` must bound what leaves. Previously
    /// the module forwarded the ENTIRE claim regardless: a user capping their
    /// allowance at a fraction to bound exposure was in fact authorising the whole
    /// position. The surplus now goes back to the beneficiary.
    function test_claimCapsAtAllowance_surplusToBeneficiary() public {
        uint256 requestId = _doRequest();
        vm.warp(block.timestamp + LOCK);

        uint256 cap = SHARES / 4;
        uint256 userBefore = underlyingAsset.balanceOf(user);

        bytes memory claimData = abi.encode(address(vault), requestId, uint256(0));
        vm.prank(address(permit3));
        module.takeOnBehalf(user, cap, receiver, claimData);

        assertEq(underlyingAsset.balanceOf(receiver), cap, "receiver bounded by the allowance");
        assertEq(underlyingAsset.balanceOf(user) - userBefore, SHARES - cap, "surplus returned to beneficiary");
        assertEq(underlyingAsset.balanceOf(address(module)), 0, "module holds nothing");
    }

    // ──────────────── Regression: asset comes from the vault ────────────────

    /// `asset` used to be caller-supplied, so a holder of any valid pending request
    /// could name a token the module happened to hold and have `received` units of
    /// it sent to their own receiver. It is now read from the vault, so `data`
    /// cannot express a different token at all.
    function test_assetIsReadFromVault_notCallerSupplied() public {
        uint256 requestId = _doRequest();
        vm.warp(block.timestamp + LOCK);

        // Strand a share-token balance on the module — the balance the old bug
        // would have handed over.
        shareToken.mint(address(module), 5_000e18);

        bytes memory claimData = abi.encode(address(vault), requestId, uint256(0));
        vm.prank(address(permit3));
        module.takeOnBehalf(user, SHARES, receiver, claimData);

        assertEq(underlyingAsset.balanceOf(receiver), SHARES, "paid in the vault's real asset");
        assertEq(shareToken.balanceOf(receiver), 0, "not a single share token leaked");
        assertEq(shareToken.balanceOf(address(module)), 5_000e18, "stranded balance untouched");
    }

    // ──────────────── Regression: requestId collision ────────────────

    /// A vault that reuses request ids (the ERC-7540 `REQUEST_ID_0` convention)
    /// used to silently clobber the first beneficiary, making their shares
    /// permanently unclaimable — the module is the vault's only authorised claimer.
    function test_requestIdCollision_failsClosed() public {
        uint256 requestId = _doRequest();

        // Force the vault to hand back the SAME id for the next request.
        vault.setNextRequestId(requestId);

        address other = address(0xB0B);
        shareToken.mint(other, SHARES);
        vm.prank(other);
        shareToken.approve(address(permit3), type(uint256).max);

        bytes memory data = abi.encode(address(vault), address(shareToken));
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626WithdrawModule.RequestIdCollision.selector, address(vault), requestId)
        );
        module.makeOnBehalf(other, SHARES, data);

        // The first beneficiary's entry survives intact.
        (address beneficiary,) = module.pendingWithdrawals(address(vault), requestId);
        assertEq(beneficiary, user, "original beneficiary preserved");
    }
}
