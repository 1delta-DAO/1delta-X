// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {MockERC20, MockTakerModule} from "../Permit3.t.sol";

/// @dev Stateful walk over Permit3's two books (audit 2026-09-30 P3-3: the core walk
///      had no Permit3 action at all). One owner, two spenders, one token, one taker
///      position. A ghost ledger records every grant the OWNER made (on-chain approve,
///      or a FRESH signed batch) and every unit a spender actually moved; the
///      invariants are that moved never exceeds granted (finite grants only — the
///      uint160 max sentinel is never used here) and that a spent nonce never
///      re-applies a grant. Like {StateHandler} it RECORDS rather than asserts, since
///      `fail_on_revert = false` swallows a revert inside the handler.
contract Permit3BookHandler is Test {
    Permit3 public immutable permit3;
    MockERC20 public immutable token;
    MockTakerModule public immutable taker;

    uint256 constant OWNER_PK = 0xA11CE;
    address public owner = vm.addr(OWNER_PK);
    address[2] public spenders = [address(0x5EED1), address(0x5EED2)];
    bytes public constant DATA = abi.encode(uint256(42));

    bytes32 constant TOKEN_PERMIT_TH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");
    bytes32 constant PERMIT_BATCH_TH = keccak256(
        "PermitBatch(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline)"
        "TakerPermit(address spender,address module,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
    );

    // ghost ledger, per spender
    uint256[2] public granted; //     cumulative token-book amount the owner authorised
    uint256[2] public moved; //       cumulative tokens a spender pulled through the book
    uint256[2] public takeGranted; // taker book, same idea
    uint256[2] public taken;
    uint256 public nextNonce;
    string public findings;

    constructor() {
        permit3 = new Permit3();
        token = new MockERC20();
        taker = new MockTakerModule(address(permit3));
        token.mint(owner, type(uint128).max);
        vm.prank(owner);
        token.approve(address(permit3), type(uint256).max);
    }

    function _rec(string memory why) internal {
        findings = string.concat(findings, why, "; ");
    }

    /// @dev A grant REPLACES the bucket, so the ledger tracks "authorised since the last
    ///      write": moved resets with it. Moved-within-grant is the property.
    function doApprove(uint256 sSeed, uint256 amtSeed) external {
        uint256 s = sSeed % 2;
        uint160 amt = uint160(amtSeed % 1_000e18);
        vm.prank(owner);
        permit3.approveToken(spenders[s], address(token), amt, 0);
        granted[s] = amt;
        moved[s] = 0;
    }

    function doApproveTaker(uint256 sSeed, uint256 amtSeed) external {
        uint256 s = sSeed % 2;
        uint160 amt = uint160(amtSeed % 1_000e18);
        vm.prank(owner);
        permit3.approveTaker(spenders[s], address(taker), keccak256(DATA), amt, 0);
        takeGranted[s] = amt;
        taken[s] = 0;
    }

    function doTransfer(uint256 sSeed, uint256 amtSeed) external {
        uint256 s = sSeed % 2;
        uint160 amt = uint160(amtSeed % 1_000e18) + 1;
        uint256 pre = token.balanceOf(owner);
        vm.prank(spenders[s]);
        try permit3.transferFrom(owner, address(0xCAFE), address(token), amt) {
            moved[s] += pre - token.balanceOf(owner);
            if (moved[s] > granted[s]) _rec("token book: moved past the grant");
        } catch {}
    }

    function doTake(uint256 sSeed, uint256 amtSeed) external {
        uint256 s = sSeed % 2;
        uint160 amt = uint160(amtSeed % 1_000e18) + 1;
        vm.prank(spenders[s]);
        try permit3.take(address(taker), owner, amt, address(0xCAFE), DATA) {
            taken[s] += amt;
            if (taken[s] > takeGranted[s]) _rec("taker book: took past the grant");
        } catch {}
    }

    function doLockdown(uint256 sSeed) external {
        uint256 s = sSeed % 2;
        IPermit3.TokenSpenderPair[] memory t = new IPermit3.TokenSpenderPair[](1);
        t[0] = IPermit3.TokenSpenderPair(address(token), spenders[s]);
        vm.prank(owner);
        permit3.lockdown(t);
        granted[s] = moved[s]; // nothing further may move
    }

    function _signBatch(IPermit3.PermitBatch memory b) internal view returns (bytes memory) {
        bytes32 tph = keccak256(
            abi.encodePacked(
                keccak256(
                    abi.encode(TOKEN_PERMIT_TH, b.tokens[0].spender, b.tokens[0].token, b.tokens[0].amount, b.tokens[0].expiration)
                )
            )
        );
        bytes32 hs = keccak256(abi.encode(PERMIT_BATCH_TH, tph, keccak256(""), b.nonce, b.deadline));
        (uint8 v, bytes32 r, bytes32 sg) =
            vm.sign(OWNER_PK, keccak256(abi.encodePacked("\x19\x01", permit3.DOMAIN_SEPARATOR(), hs)));
        return abi.encodePacked(r, sg, v);
    }

    /// @dev A FRESH signed batch, applied once (ledger updated), then REPLAYED: the
    ///      replay must not re-grant — whatever was moved in between stays counted.
    function doPermitBatchAndReplay(uint256 sSeed, uint256 amtSeed, uint256 drawSeed) external {
        uint256 s = sSeed % 2;
        uint160 amt = uint160(amtSeed % 1_000e18);
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(spenders[s], address(token), amt, 0);
        IPermit3.PermitBatch memory b = IPermit3.PermitBatch({
            tokens: tp, takers: new IPermit3.TakerPermit[](0), nonce: nextNonce++, deadline: block.timestamp + 1 days
        });
        bytes memory sig = _signBatch(b);
        permit3.permitBatch(owner, b, sig);
        granted[s] = amt;
        moved[s] = 0;

        uint160 draw = amt == 0 ? 0 : uint160(drawSeed % amt);
        if (draw != 0) {
            vm.prank(spenders[s]);
            permit3.transferFrom(owner, address(0xCAFE), address(token), draw);
            moved[s] += draw;
        }
        // Replay of the spent nonce: must revert, must not restore `amt`.
        try permit3.permitBatch(owner, b, sig) {
            _rec("a spent permit nonce was applied twice");
        } catch {}
        (uint160 left,) = permit3.tokenAllowance(owner, spenders[s], address(token));
        if (uint256(left) + moved[s] != amt) _rec("a replay changed the book");
    }
}

contract Permit3BookInvariants is StdInvariant, Test {
    Permit3BookHandler handler;

    function setUp() public {
        handler = new Permit3BookHandler();
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = Permit3BookHandler.doApprove.selector;
        sel[1] = Permit3BookHandler.doApproveTaker.selector;
        sel[2] = Permit3BookHandler.doTransfer.selector;
        sel[3] = Permit3BookHandler.doTake.selector;
        sel[4] = Permit3BookHandler.doLockdown.selector;
        sel[5] = Permit3BookHandler.doPermitBatchAndReplay.selector;
        sel[6] = Permit3BookHandler.doTransfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    function invariant_audit_P3_3_booksNeverMovePastGrants() public view {
        assertEq(bytes(handler.findings()).length, 0, handler.findings());
        for (uint256 s; s < 2; ++s) {
            (uint160 left,) = handler.permit3().tokenAllowance(handler.owner(), handler.spenders(s), address(handler.token()));
            assertLe(handler.moved(s), handler.granted(s), "token book overdrawn");
            assertLe(uint256(left) + handler.moved(s), handler.granted(s) + 0, "book holds more than granted");
        }
    }
}
