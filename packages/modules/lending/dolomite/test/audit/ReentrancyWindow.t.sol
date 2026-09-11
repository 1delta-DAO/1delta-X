// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {
    AccountInfo,
    ActionArgs,
    ActionType,
    WeiBalance
} from "../../src/interfaces/IDolomite.sol";
import {DolomiteOperatorModule} from "../../src/DolomiteOperatorModule.sol";

/// @dev THE ONE CUSTODY WINDOW NO OUTER LOCK COVERS, EXERCISED.
///
///  Every module entrypoint is reached through a locked dispatcher — Settlement for
///  MAKE, Permit3.take / takeFor for the taker seams — with ONE exception that
///  Permit3 documents on purpose ({AllowanceTransfer.transferFrom}: "DELIBERATELY NOT
///  nonReentrant"): a MAKE repay's pull hands control to a maker-chosen token, and a
///  token with a transfer hook can call `Permit3.take` from inside it, because
///  nothing on that path arms Permit3's lock. Settlement's lock is held, so the hook
///  cannot re-enter a MAKE; but it CAN reach this module's `takeOnBehalf` — with
///  `onBehalfOf` = whoever granted the HOOK CONTRACT a taker bucket, i.e. only the
///  attacker themselves (pinned at the Permit3 layer by
///  `test_reentrancy_transferFrom_cannotReachTheSpendersBucket`).
///
///  This file pins the MODULE-layer half: that nested `takeOnBehalf(attacker, …)`,
///  landing mid-repay on the SAME balance the victim's fill is measuring, moves only
///  the attacker's own funds and leaves the victim's accounting byte-identical to an
///  un-attacked fill. That is the property that decides whether a module-level
///  reentrancy guard is load-bearing here. It is not: every custody path measures a
///  same-call delta and caps its payout by it, so an interleaved call has nothing to
///  disturb. The guard the old repay module carried was defence-in-depth for this
///  exact window, written before the delta discipline was universal.
contract DolomiteReentrancyWindowTest is Test {
    Permit3 permit3;
    address settlement = address(0x5E77);
    DolomiteOperatorModule module;
    MockDolomite dolomite;
    HookToken token;

    address victim = address(0xB1C);
    address attacker = address(0xA77);
    address attackerReceiver = address(0xCAFE);

    uint256 constant MARKET = 2;
    uint256 constant ACCOUNT = 1;
    uint256 constant VICTIM_DEBT = 1_000e18;
    uint256 constant ATTACKER_BALANCE = 7_000e18;

    function setUp() public {
        permit3 = new Permit3();
        module = new DolomiteOperatorModule(address(permit3), settlement);
        token = new HookToken();
        dolomite = new MockDolomite(MARKET, address(token));

        // Victim: a debt position, and the wallet + Permit3 grant a repay needs.
        dolomite.setWei(victim, ACCOUNT, MARKET, false, VICTIM_DEBT);
        token.mint(victim, VICTIM_DEBT + 300e18);
        vm.startPrank(victim);
        token.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(module), address(token), type(uint160).max, 0);
        vm.stopPrank();

        // Attacker: a SUPPLY balance to withdraw, and a taker bucket granted to the
        // HOOK CONTRACT as spender — the only way a hook can reach `take`.
        dolomite.setWei(attacker, ACCOUNT, MARKET, true, ATTACKER_BALANCE);
        token.mint(address(dolomite), ATTACKER_BALANCE); // the venue can pay it out
        vm.prank(attacker);
        permit3.approveTaker(address(token), address(module), keccak256(_attackerWithdrawFull()), type(uint160).max, 0);
    }

    function _repayData() internal view returns (bytes memory) {
        return abi.encode(
            uint8(DolomiteOperatorModule.Op.Repay), address(dolomite), MARKET, address(token), ACCOUNT,
            uint8(DustHandler.DustAction.Recycle) // Recycle: the path that DISPOSES a measured residual
        );
    }

    function _attackerWithdrawFull() internal view returns (bytes memory) {
        return abi.encode(
            uint8(DolomiteOperatorModule.Op.Withdraw), address(dolomite), MARKET, address(token), ACCOUNT,
            DustHandler.encodeMode(DustHandler.BalanceMode.Full),
            ATTACKER_BALANCE
        );
    }

    /// @dev The victim's repay with the hook DISARMED — the reference outcome.
    function _referenceOutcome() internal returns (uint256 debtAfter, uint256 recycled, uint256 walletAfter) {
        uint256 snap = vm.snapshotState();
        uint256 ceiling = VICTIM_DEBT + 300e18;
        vm.prank(settlement);
        module.makeOnBehalf(victim, ceiling, _repayData());
        WeiBalance memory w = dolomite.getAccountWei(AccountInfo(victim, ACCOUNT), MARKET);
        debtAfter = w.sign ? 0 : w.value;
        recycled = w.sign ? w.value : 0;
        walletAfter = token.balanceOf(victim);
        vm.revertToState(snap);
    }

    function test_hookReentersTakeMidRepay_victimAccountingUnchanged_attackerMovesOnlyOwnFunds() public {
        (uint256 refDebt, uint256 refRecycled, uint256 refWallet) = _referenceOutcome();
        assertEq(refDebt, 0, "reference: debt closed");
        assertEq(refRecycled, 300e18, "reference: surplus recycled");

        // ARM: when the module RECEIVES the victim's pull, the token calls
        // Permit3.take(attacker, module, ref, …) — landing takeOnBehalf(attacker,
        // Withdraw Full) on this module while the victim's repay is mid-flight, after
        // the victim's tokens have landed on the module balance.
        token.arm(
            address(module),
            address(permit3),
            abi.encodeCall(
                IPermit3.take,
                (address(module), attacker, uint160(ATTACKER_BALANCE), attackerReceiver, _attackerWithdrawFull())
            )
        );

        uint256 ceiling = VICTIM_DEBT + 300e18;
        vm.prank(settlement);
        module.makeOnBehalf(victim, ceiling, _repayData());

        assertTrue(token.fired(), "the hook actually re-entered (else this proves nothing)");
        assertTrue(token.nestedOk(), "the nested take SUCCEEDED - no module guard stopped it");

        // The victim's outcome is byte-identical to the un-attacked reference.
        WeiBalance memory w = dolomite.getAccountWei(AccountInfo(victim, ACCOUNT), MARKET);
        assertEq(w.sign ? 0 : w.value, refDebt, "victim debt: unchanged by the interleaving");
        assertEq(w.sign ? w.value : 0, refRecycled, "victim recycled surplus: unchanged");
        assertEq(token.balanceOf(victim), refWallet, "victim wallet: unchanged");

        // The attacker moved exactly their OWN balance, nothing of the victim's.
        assertEq(token.balanceOf(attackerReceiver), ATTACKER_BALANCE, "attacker got their own position, exactly");
        WeiBalance memory a = dolomite.getAccountWei(AccountInfo(attacker, ACCOUNT), MARKET);
        assertEq(a.value, 0, "attacker's own position was what got withdrawn");
        assertEq(token.balanceOf(address(module)), 0, "module holds nothing after both");
    }
}

// ──────────────────── mocks ────────────────────

/// @dev ERC20 whose transfer INTO `hookTarget` makes a low-level call to `hookCallee`
///      with `hookData` — an ERC777-style receive hook, minimal.
contract HookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address hookTarget;
    address hookCallee;
    bytes hookData;
    bool public fired;
    bool public nestedOk;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(address target, address callee, bytes calldata data) external {
        hookTarget = target;
        hookCallee = callee;
        hookData = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        // Fire ONCE, after the balance update, only on the armed edge.
        if (to == hookTarget && hookCallee != address(0) && !fired) {
            fired = true;
            (bool ok,) = hookCallee.call(hookData);
            nestedOk = ok;
        }
        return true;
    }
}

/// @dev Just enough of DolomiteMargin: per-(owner, account, market) signed wei
///      balances, and an `operate` that moves ONE token per market. Deposit pulls
///      from `otherAddress` (the module approved it); Withdraw pays `otherAddress`.
contract MockDolomite {
    struct Bal {
        bool sign;
        uint256 value;
    }

    uint256 immutable market;
    address immutable token;
    mapping(address => mapping(uint256 => Bal)) bal; // owner → account → balance in `market`

    constructor(uint256 _market, address _token) {
        market = _market;
        token = _token;
    }

    function setWei(address owner, uint256 account, uint256, bool sign, uint256 value) external {
        bal[owner][account] = Bal(sign, value);
    }

    function getAccountWei(AccountInfo calldata a, uint256) external view returns (WeiBalance memory) {
        Bal memory b = bal[a.owner][a.number];
        return WeiBalance(b.sign, b.value);
    }

    function operate(AccountInfo[] calldata accounts, ActionArgs[] calldata actions) external {
        for (uint256 i; i < actions.length; ++i) {
            ActionArgs calldata act = actions[i];
            AccountInfo calldata acc = accounts[act.accountId];
            Bal storage b = bal[acc.owner][acc.number];
            uint256 amt = act.amount.value;
            if (act.actionType == ActionType.Deposit) {
                IERC20(token).transferFrom(act.otherAddress, address(this), amt);
                _add(b, amt);
            } else {
                _sub(b, amt);
                IERC20(token).transfer(act.otherAddress, amt);
            }
        }
    }

    function _add(Bal storage b, uint256 amt) private {
        if (b.sign) b.value += amt;
        else if (amt >= b.value) (b.sign, b.value) = (true, amt - b.value);
        else b.value -= amt;
    }

    function _sub(Bal storage b, uint256 amt) private {
        if (!b.sign) b.value += amt;
        else if (amt > b.value) (b.sign, b.value) = (false, amt - b.value);
        else b.value -= amt;
    }
}
