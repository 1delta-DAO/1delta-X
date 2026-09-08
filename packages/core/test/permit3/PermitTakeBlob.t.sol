// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";

/// @dev Replicates, verbatim, the two halves of the `FillCtx.permitTake` round-trip
///      that {Core.fillWithPermitTake} and {Base._takeByPermit} hand-roll. Keeping a
///      copy here rather than reaching into Settlement is deliberate: the property
///      under test is that the LAYOUT is canonical, and a differential against
///      `abi.encode`/`abi.decode` is the only way to state that as a property rather
///      than as a comment.
contract Harness {
    function handEncode(IPermit3.PermitTake calldata permit, bytes calldata sig) external pure returns (bytes memory) {
        bytes memory blob;
        /// @solidity memory-safe-assembly
        assembly {
            blob := mload(0x40)
            let n := sig.length
            let total := add(0xE0, and(add(n, 31), not(31)))
            mstore(blob, total)
            calldatacopy(add(blob, 0x20), permit, 0xa0)
            mstore(add(blob, 0xc0), 0xc0)
            mstore(add(blob, 0xe0), n)
            calldatacopy(add(blob, 0x100), sig.offset, n)
            mstore(add(add(blob, 0x100), n), 0)
            mstore(0x40, add(add(blob, 0x20), total))
        }
        return blob;
    }

    function handDecode(bytes memory blob) external pure returns (IPermit3.PermitTake memory permit, bytes memory sig) {
        /// @solidity memory-safe-assembly
        assembly {
            permit := add(blob, 0x20)
            sig := add(blob, 0xE0)
        }
    }

    function solcEncode(IPermit3.PermitTake calldata permit, bytes calldata sig) external pure returns (bytes memory) {
        return abi.encode(permit, sig);
    }
}

/// @title PermitTakeBlob
/// @notice The one-shot taker permit is threaded from {Core.fillWithPermitTake} to
///         {Base._takeByPermit} through `FillCtx.permitTake`, a `bytes` field. That
///         used to cost a full `abi.encode` of a struct-plus-`bytes` tuple on the way
///         in and a full validating `abi.decode` on the way out — 209 bytes, in a
///         contract with none to spare, to move data that arrived already typed.
///
///         Both halves are hand-rolled now, and that is safe for one specific reason:
///         the PRODUCER and the CONSUMER are the same contract one frame apart, so the
///         blob never passes through anyone else's encoder and the decoder's bounds
///         checks would only re-prove what calldata typing proved on entry.
///
///         That reason is worth exactly as much as the layout actually matching. These
///         pin it against solc's own encoder over fuzzed inputs — including the two
///         boundaries a hand-rolled length calculation gets wrong: an EMPTY signature,
///         and one whose length is not a multiple of 32.
contract PermitTakeBlobTest is Test {
    Harness h;

    function setUp() public {
        h = new Harness();
    }

    function _permit() internal pure returns (IPermit3.PermitTake memory) {
        return IPermit3.PermitTake({
            module: address(0xA11CE),
            ref: keccak256("ref"),
            amount: 1_500e6,
            nonce: 7,
            deadline: 1_900_000_000
        });
    }

    /// The layout IS solc's, byte for byte — the claim the read side's pointer
    /// arithmetic depends on.
    function testFuzz_handEncode_matchesSolc(bytes memory sig) public view {
        vm.assume(sig.length <= 512);
        assertEq(h.handEncode(_permit(), sig), h.solcEncode(_permit(), sig), "layout diverged from abi.encode");
    }

    /// …and the round-trip is lossless for every field, including the ones the
    /// zero-copy read ALIASES rather than copies.
    function testFuzz_roundTrip(bytes memory sig, address module, uint160 amount, uint256 nonce, uint256 deadline)
        public
        view
    {
        vm.assume(sig.length <= 512);
        IPermit3.PermitTake memory p =
            IPermit3.PermitTake({module: module, ref: keccak256(sig), amount: amount, nonce: nonce, deadline: deadline});
        (IPermit3.PermitTake memory got, bytes memory gotSig) = h.handDecode(h.handEncode(p, sig));
        assertEq(got.module, p.module, "module");
        assertEq(got.ref, p.ref, "ref");
        assertEq(got.amount, p.amount, "amount");
        assertEq(got.nonce, p.nonce, "nonce");
        assertEq(got.deadline, p.deadline, "deadline");
        assertEq(gotSig, sig, "sig");
    }

    /// The read side must agree with solc's DECODER too, not merely with its own
    /// writer — otherwise a layout both halves got wrong the same way would pass.
    function testFuzz_handDecode_matchesSolc(bytes memory sig) public view {
        vm.assume(sig.length <= 512);
        bytes memory blob = h.solcEncode(_permit(), sig);
        (IPermit3.PermitTake memory want, bytes memory wantSig) = abi.decode(blob, (IPermit3.PermitTake, bytes));
        (IPermit3.PermitTake memory got, bytes memory gotSig) = h.handDecode(blob);
        assertEq(got.module, want.module, "module");
        assertEq(got.nonce, want.nonce, "nonce");
        assertEq(gotSig, wantSig, "sig");
    }

    /// The boundaries a hand-rolled `and(add(n, 31), not(31))` gets wrong.
    function test_boundaries_emptyAndUnalignedSignature() public view {
        bytes memory empty = "";
        assertEq(h.handEncode(_permit(), empty), h.solcEncode(_permit(), empty), "empty sig");
        assertEq(h.handEncode(_permit(), empty).length, 0xE0, "empty sig is head-only");

        bytes memory ecdsa = new bytes(65); // the ordinary case: 65 -> padded to 96
        for (uint256 i; i < 65; ++i) {
            ecdsa[i] = bytes1(uint8(i + 1));
        }
        assertEq(h.handEncode(_permit(), ecdsa), h.solcEncode(_permit(), ecdsa), "65-byte sig");

        bytes memory exact = new bytes(64); // already word-aligned: no padding word
        assertEq(h.handEncode(_permit(), exact), h.solcEncode(_permit(), exact), "64-byte sig");
    }

    /// The padding tail is ZEROED, not left holding whatever was in free memory. The
    /// blob is re-encoded by solc on its way into Permit3, so a dirty tail is exactly
    /// the kind of thing that passes every test until it does not.
    function test_paddingTailIsZeroed() public view {
        bytes memory sig = new bytes(65);
        bytes memory blob = h.handEncode(_permit(), sig);
        uint256 tail;
        /// @solidity memory-safe-assembly
        assembly {
            tail := mload(add(add(blob, 0x100), 64)) // the word holding sig[64] + padding
        }
        assertEq(tail & type(uint248).max, 0, "padding after the last signature byte is not zero");
    }
}
