// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {
    GearboxCreditAddCollateralModule,
    GearboxCreditBorrowModule,
    GearboxCreditAuth
} from "../../src/GearboxV3Modules.sol";
import {IGearboxBot, IGearboxCreditFacadeV3Multicall, MultiCall} from "../../src/interfaces/IGearboxV3.sol";

// ── Mocks: a faithful-enough Gearbox V3 credit stack ─────────────────────────
//
// Models the three properties the modules actually depend on:
//   1. the CA → CreditManager → CreditFacade address chain,
//   2. bot registration with BotListV3's EXACT-match rule on `requiredPermissions()`,
//   3. `botMulticall` authorising the BOT (never a beneficiary) and the
//      CreditManager — not the facade — executing `addCollateral`'s transferFrom.

contract GbxToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Position contract. Its manager is immutable — the root of the auth chain.
contract GbxCreditAccount {
    address public creditManager;

    constructor(address cm) {
        creditManager = cm;
    }

    /// @dev Real Gearbox moves CA funds through the CreditManager, never directly.
    function transferOut(address token, address to, uint256 amount) external {
        require(msg.sender == creditManager, "only CM");
        GbxToken(token).transfer(to, amount);
    }
}

contract GbxCreditManager {
    address public creditFacade;
    mapping(address => address) public borrowerOf;
    mapping(address => uint256) public debtOf;

    error NoBorrower();

    function setFacade(address f) external {
        creditFacade = f;
    }

    function register(address creditAccount, address owner) external {
        borrowerOf[creditAccount] = owner;
    }

    /// @dev Mirrors Gearbox: an account this manager does not know REVERTS rather
    ///      than returning a zero address that could be compared against.
    function getBorrowerOrRevert(address creditAccount) external view returns (address) {
        address b = borrowerOf[creditAccount];
        if (b == address(0)) revert NoBorrower();
        return b;
    }

    // ── facade-only effects ──
    function pullCollateral(address token, address payer, address creditAccount, uint256 amount) external {
        require(msg.sender == creditFacade, "only facade");
        // The MANAGER is the spender here — this is why modules must approve the
        // CreditManager and not the facade.
        GbxToken(token).transferFrom(payer, creditAccount, amount);
    }

    function borrow(address token, address creditAccount, uint256 amount) external {
        require(msg.sender == creditFacade, "only facade");
        debtOf[creditAccount] += amount;
        GbxToken(token).mint(creditAccount, amount); // stands in for the pool draw
    }

    function withdrawTo(address creditAccount, address token, address to, uint256 amount) external {
        require(msg.sender == creditFacade, "only facade");
        GbxCreditAccount(creditAccount).transferOut(token, to, amount);
    }
}

contract GbxFacade {
    GbxCreditManager public immutable cm;
    address public immutable underlying;

    /// @dev creditAccount => bot => granted mask
    mapping(address => mapping(address => uint192)) public botPermissions;

    uint192 constant ADD_COLLATERAL = 1 << 0;
    uint192 constant INCREASE_DEBT = 1 << 1;
    uint192 constant WITHDRAW_COLLATERAL = 1 << 5;

    error IncorrectBotPermissions();
    error BotNotRegistered();
    error MissingPermission();
    error AdapterCallForbidden();

    constructor(address _cm, address _underlying) {
        cm = GbxCreditManager(_cm);
        underlying = _underlying;
    }

    /// @dev BotListV3's rule: the granted mask must EQUAL the bot's published
    ///      `requiredPermissions()`. A contract not implementing it cannot be
    ///      registered at all — which is what made these modules unusable before.
    function setBotPermissions(address creditAccount, address bot, uint192 mask) external {
        if (IGearboxBot(bot).requiredPermissions() != mask) revert IncorrectBotPermissions();
        botPermissions[creditAccount][bot] = mask;
    }

    /// @dev Authorises the BOT and nothing else — there is no parameter that could
    ///      carry the user the bot is acting for. That absence is the whole reason
    ///      `GearboxCreditAuth` has to exist.
    function botMulticall(address creditAccount, MultiCall[] calldata calls) external {
        uint192 perms = botPermissions[creditAccount][msg.sender];
        if (perms == 0) revert BotNotRegistered();
        address bot = msg.sender;

        for (uint256 i; i < calls.length; i++) {
            if (calls[i].target != address(this)) revert AdapterCallForbidden();
            bytes calldata cd = calls[i].callData;
            bytes4 sel = bytes4(cd[:4]);

            if (sel == IGearboxCreditFacadeV3Multicall.addCollateral.selector) {
                if (perms & ADD_COLLATERAL == 0) revert MissingPermission();
                (address token, uint256 amount) = abi.decode(cd[4:], (address, uint256));
                cm.pullCollateral(token, bot, creditAccount, amount);
            } else if (sel == IGearboxCreditFacadeV3Multicall.increaseDebt.selector) {
                if (perms & INCREASE_DEBT == 0) revert MissingPermission();
                uint256 amount = abi.decode(cd[4:], (uint256));
                cm.borrow(underlying, creditAccount, amount);
            } else if (sel == IGearboxCreditFacadeV3Multicall.withdrawCollateral.selector) {
                if (perms & WITHDRAW_COLLATERAL == 0) revert MissingPermission();
                (address token, uint256 amount, address to) = abi.decode(cd[4:], (address, uint256, address));
                cm.withdrawTo(creditAccount, token, to, amount);
            } else {
                revert AdapterCallForbidden();
            }
        }
    }
}

/// @title GearboxCreditAccountTest
/// @notice End-to-end scenarios for the Gearbox credit-account modules: a working
///         deposit, a working borrow, and the self-signed-order drain that the
///         ownership binding must prevent.
///
///         The attack runs through the REAL Permit3, which is the point. Permit3's
///         taker book is keyed by the APPROVER (`_takerAllowance[user][spender][ref]`,
///         `ref = keccak256(data)`), so an attacker can self-approve a ref computed
///         over a VICTIM's credit account. Gearbox's own auth cannot stop what
///         follows — it authorises the bot (the module), which is registered on
///         every onboarded account. Only `GearboxCreditAuth.authorize` does.
contract GearboxCreditAccountTest is Test {
    Permit3 permit3;

    GbxToken collateral;
    GbxToken underlying;
    GbxCreditManager cm;
    GbxFacade facade;

    GearboxCreditAddCollateralModule depositModule;
    GearboxCreditBorrowModule borrowModule;

    address settlement = address(0x5E77);
    address maker = address(0xA11CE); // the victim
    address attacker = address(0xBAD);
    address receiver = address(0xFEE);

    address makerCA;
    address attackerCA;

    uint256 constant DEPOSIT = 10e18;
    uint256 constant BORROW = 4_000e6;

    function setUp() public {
        permit3 = new Permit3();
        collateral = new GbxToken();
        underlying = new GbxToken();

        cm = new GbxCreditManager();
        facade = new GbxFacade(address(cm), address(underlying));
        cm.setFacade(address(facade));

        makerCA = address(new GbxCreditAccount(address(cm)));
        attackerCA = address(new GbxCreditAccount(address(cm)));
        cm.register(makerCA, maker);
        cm.register(attackerCA, attacker);

        depositModule = new GearboxCreditAddCollateralModule(address(permit3), settlement);
        borrowModule = new GearboxCreditBorrowModule(address(permit3));

        // Both users onboard exactly as the docs instruct: grant each module the
        // bot role with its published mask. This is the precondition for the
        // attack, not a misconfiguration.
        facade.setBotPermissions(makerCA, address(depositModule), depositModule.requiredPermissions());
        facade.setBotPermissions(makerCA, address(borrowModule), borrowModule.requiredPermissions());
        facade.setBotPermissions(attackerCA, address(borrowModule), borrowModule.requiredPermissions());

        // Maker funds + Permit3 grants.
        collateral.mint(maker, DEPOSIT);
        vm.startPrank(maker);
        collateral.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), address(collateral), uint160(DEPOSIT), 0);
        vm.stopPrank();
    }

    function _borrowData(address ca) internal view returns (bytes memory) {
        return abi.encode(ca, address(underlying));
    }

    // ──────────────── Scenario 1: deposit ────────────────

    function test_deposit_addsCollateralToOwnAccount() public {
        vm.prank(settlement);
        depositModule.makeOnBehalf(maker, DEPOSIT, abi.encode(makerCA, address(collateral)));

        assertEq(collateral.balanceOf(makerCA), DEPOSIT, "collateral landed in the maker's account");
        assertEq(collateral.balanceOf(maker), 0, "pulled from the maker");
        // Invariant 6: the module ends every call holding nothing and granting nothing.
        assertEq(collateral.balanceOf(address(depositModule)), 0, "module holds no residue");
        assertEq(collateral.allowance(address(depositModule), address(cm)), 0, "no standing allowance");
    }

    // ──────────────── Scenario 2: borrow ────────────────

    function test_borrow_drawsDebtAndRoutesProceeds() public {
        bytes memory data = _borrowData(makerCA);

        vm.prank(maker);
        permit3.approveTaker(settlement, keccak256(data), uint160(BORROW), 0);

        vm.prank(settlement);
        permit3.take(address(borrowModule), maker, uint160(BORROW), receiver, data);

        assertEq(cm.debtOf(makerCA), BORROW, "debt recorded against the maker's account");
        assertEq(underlying.balanceOf(receiver), BORROW, "proceeds routed to the order receiver");
        assertEq(underlying.balanceOf(makerCA), 0, "nothing stranded on the account");
    }

    // ──────────────── Scenario 3: the attack, prevented ────────────────

    /// The full drain, end to end through the real Permit3. The attacker never
    /// forges a signature and never touches the maker's allowances — they simply
    /// approve a ref of their OWN over the maker's account and fill their own order.
    function test_attacker_cannot_borrow_against_victim_account() public {
        bytes memory victimData = _borrowData(makerCA); // <- the maker's account

        // The attacker self-approves. This SUCCEEDS: the taker book is keyed by the
        // approver, so nothing here belongs to the maker.
        vm.prank(attacker);
        permit3.approveTaker(settlement, keccak256(victimData), type(uint160).max, 0);

        // Permit3's gate now passes on the attacker's own allowance. Everything
        // downstream rests on the module's ownership binding.
        vm.prank(settlement);
        vm.expectRevert(GearboxCreditAuth.InvalidCaller.selector);
        permit3.take(address(borrowModule), attacker, uint160(BORROW), attacker, victimData);

        assertEq(cm.debtOf(makerCA), 0, "no debt drawn against the maker");
        assertEq(underlying.balanceOf(attacker), 0, "attacker received nothing");
    }

    /// Proof the gate the attacker cleared really was open: the identical call with
    /// the attacker's OWN account succeeds. So the revert above is the ownership
    /// binding doing the work, not an incidental failure somewhere earlier.
    function test_attacker_can_still_borrow_against_their_own_account() public {
        bytes memory ownData = _borrowData(attackerCA);

        vm.prank(attacker);
        permit3.approveTaker(settlement, keccak256(ownData), type(uint160).max, 0);

        vm.prank(settlement);
        permit3.take(address(borrowModule), attacker, uint160(BORROW), attacker, ownData);

        assertEq(cm.debtOf(attackerCA), BORROW, "attacker's own account works normally");
        assertEq(underlying.balanceOf(attacker), BORROW, "and they keep their own debt");
    }

    /// The deposit leg needs the same binding: an attacker must not be able to push
    /// funds into someone else's position either.
    function test_attacker_cannot_addCollateral_to_victim_account() public {
        collateral.mint(attacker, DEPOSIT);
        vm.startPrank(attacker);
        collateral.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), address(collateral), uint160(DEPOSIT), 0);
        vm.stopPrank();

        vm.prank(settlement);
        vm.expectRevert(GearboxCreditAuth.InvalidCaller.selector);
        depositModule.makeOnBehalf(attacker, DEPOSIT, abi.encode(makerCA, address(collateral)));

        assertEq(collateral.balanceOf(makerCA), 0, "victim's account untouched");
    }

    // ──────────────── Bot registration + permission scoping ────────────────

    /// Registration is the fix that made these modules usable at all: with no
    /// `requiredPermissions()` the call below reverts and no user can ever onboard.
    function test_modules_are_registerable_with_their_published_mask() public {
        address freshCA = address(new GbxCreditAccount(address(cm)));
        cm.register(freshCA, maker);

        facade.setBotPermissions(freshCA, address(borrowModule), 0x22);
        assertEq(facade.botPermissions(freshCA, address(borrowModule)), 0x22, "borrow bot registered");

        facade.setBotPermissions(freshCA, address(depositModule), 0x01);
        assertEq(facade.botPermissions(freshCA, address(depositModule)), 0x01, "deposit bot registered");
    }

    /// Gearbox matches the mask EXACTLY, so a maker cannot over-grant by mistake —
    /// asking for the composer's monolithic 0x67 on a borrow-only module reverts.
    function test_overbroad_mask_is_rejected() public {
        vm.expectRevert(GbxFacade.IncorrectBotPermissions.selector);
        facade.setBotPermissions(makerCA, address(borrowModule), 0x67);
    }

    /// Because the modules are separate contracts with separate masks, the deposit
    /// module physically cannot draw debt even if it tried.
    function test_depositModule_lacks_borrow_permission() public {
        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: address(facade),
            callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.increaseDebt, (BORROW))
        });

        vm.prank(address(depositModule));
        vm.expectRevert(GbxFacade.MissingPermission.selector);
        facade.botMulticall(makerCA, calls);
    }
}
