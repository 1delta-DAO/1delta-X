// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Order} from "@core/settlement/Settlement.sol";

import {MocPriceBandValidator} from "../src/MocPriceBandValidator.sol";
import {IMocRif, IPriceProvider} from "../src/interfaces/IMoc.sol";

/// @title Audit20260930MocBandTest
/// @notice Regression for audit 2026-09-30 RIF-3 / VAL-3: {MocPriceBandValidator}
///         could not pass on Rootstock mainnet — the documented price provider is
///         frozen and flagged invalid, and the provider MoC now uses is whitelist-gated.
///         Pinned to a RECENT block (after the provider migration), unlike the exit
///         suite's 8,920,000 pin under which the legacy provider still looked healthy.
contract Audit20260930MocBandTest is Test {
    address constant USDRIF = 0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37;
    address constant MOC_CORE = 0xA27024Ed70035E46dba712609fc2Afa1c97aA36A;
    address constant LEGACY_PROVIDER = 0x6a5b2C84E63b5C1330bf4CcCff1Ad6F23116CC14;
    uint256 constant RECENT_BLOCK = 9_288_000;

    MocPriceBandValidator band;
    Order empty;

    function setUp() public {
        _fork();
        band = new MocPriceBandValidator();
    }

    function _fork() internal {
        try vm.envString("RSK_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        string[3] memory rpcs = ["https://public-node.rsk.co", "https://mycrypto.rsk.co", "https://rootstock.drpc.org"];
        for (uint256 i; i < rpcs.length; i++) {
            if (_tryFork(rpcs[i])) return;
        }
        revert("Audit20260930MocBandTest: no working Rootstock RPC (set RSK_RPC_URL)");
    }

    function _tryFork(string memory rpc) internal returns (bool) {
        try this.__fork(rpc) {
            return true;
        } catch {
            return false;
        }
    }

    function __fork(string calldata rpc) external {
        vm.createSelectFork(rpc, RECENT_BLOCK);
    }

    /// The precondition the finding rests on: the documented provider is frozen and
    /// flagged invalid at a post-migration block.
    function test_audit_RIF_3_legacyProviderIsDead() public view {
        (, bool has) = IPriceProvider(LEGACY_PROVIDER).peek();
        assertFalse(has, "legacy provider reports an invalid price");
    }

    /// A band bracketing the price MoC redeems at PASSES on mainnet today, read from
    /// a contract caller (the validator itself, as inside a fill).
    function test_audit_RIF_3_bandAroundGetPACtp_passes() public view {
        uint256 p = IMocRif(MOC_CORE).getPACtp(USDRIF);
        assertGt(p, 0, "core quotes a price");
        bytes memory data = abi.encode(MOC_CORE, USDRIF, (p * 95) / 100, (p * 105) / 100);
        assertTrue(band.validate(empty, address(this), data, ""), "in-band order passes");
    }

    /// The band is checked against the REDEMPTION price: a band that excludes it
    /// (e.g. one signed off the stale legacy quote, ~9.08e16, ±1%) fails.
    function test_audit_VAL_3_bandIsAgainstRedemptionPrice() public view {
        uint256 p = IMocRif(MOC_CORE).getPACtp(USDRIF);
        assertTrue(band.validate(empty, address(this), abi.encode(MOC_CORE, USDRIF, p, p), ""), "exact price");
        assertFalse(
            band.validate(empty, address(this), abi.encode(MOC_CORE, USDRIF, p + 1, type(uint256).max), ""),
            "above-band floor fails"
        );
        assertFalse(band.validate(empty, address(this), abi.encode(MOC_CORE, USDRIF, 0, p - 1), ""), "cap below fails");
    }
}
