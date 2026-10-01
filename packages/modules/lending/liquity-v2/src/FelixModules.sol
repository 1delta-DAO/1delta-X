// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LiquityV2RepayModule, LiquityV2TakerModule} from "./LiquityV2Modules.sol";
import {LiquityV2PreFundModule} from "./LiquityV2PreFundModules.sol";

// ──────────────── Felix (HyperEVM) — the renamed-BOLD Liquity v2 fork ────────────────
//
// Felix is Liquity v2 with the BOLD surface renamed to feUSD (2026-09-30 audit,
// G-VENUE_B-2). Verified on HyperEVM (chain 999):
//   • CollateralRegistry 0x9De1e57049c475736289Cb006212F3E1DCe4711B — `boldToken()`
//     REVERTS; `feUSDToken()` returns feUSD 0x02c6a2fA58cC01A18B8D9E00eA48d65E4dF26c70.
//     `getTroveManager`, `getToken` (index 0 = WHYPE 0x5555…5555) and
//     `totalCollaterals` are unchanged.
//   • BorrowerOperations (branch 0 impl 0x343966ab…2125) has NO `repayBold` /
//     `withdrawBold` selectors; it has `repayfeUSD(uint256,uint256)` (0x5fc7fcf4)
//     and `withdrawfeUSD(uint256,uint256,uint256)` (0xb10b6605) with the same
//     arguments and semantics. `addColl`, `withdrawColl`, the manager setters,
//     `troveNFT()`, `borrowerOperations()` and the `LatestTroveData` layout match.
//
// So the canonical modules work verbatim on Felix for every leg that never touches
// the debt token — {LiquityV2AddCollModule}, and {LiquityV2TakerModule} op 1
// (WithdrawColl) — but every repay / borrow leg reverted. These three contracts
// override ONLY the two fork seams ({_debtToken}: the registry's debt-token getter;
// {_repayDebt} / {_withdrawDebt}: the BorrowerOperations entrypoint). Every safety
// property — the registry-rooted ownership binding, the debt/collateral token
// pins, the floors, the delivery bound — is inherited unchanged. `data` layouts
// are identical to the Liquity v2 modules (the `boldToken` word names feUSD).
//
// Deploy with Felix's registry as `_collateralRegistry`. Other forks (Quill,
// Nerite, USDaf, …) must be probed the same way (registry getter + the two
// BorrowerOperations selectors) before being advertised; one that kept the
// canonical names uses the Liquity v2 modules directly.

/// @notice Felix's registry getter for its debt token.
interface IFelixCollateralRegistry {
    function feUSDToken() external view returns (address);
}

/// @notice Felix's renamed debt entrypoints — same arguments as `repayBold` /
///         `withdrawBold`.
interface IFelixBorrowerOperations {
    function repayfeUSD(uint256 _troveId, uint256 _feUSDAmount) external;
    function withdrawfeUSD(uint256 _troveId, uint256 _feUSDAmount, uint256 _maxUpfrontFee) external;
}

/// @notice {LiquityV2RepayModule} for Felix.
contract FelixRepayModule is LiquityV2RepayModule {
    constructor(address _permit3, address _settlement, address _collateralRegistry)
        LiquityV2RepayModule(_permit3, _settlement, _collateralRegistry)
    {}

    function _debtToken() internal view override returns (address) {
        return IFelixCollateralRegistry(collateralRegistry).feUSDToken();
    }

    function _repayDebt(address borrowerOps, uint256 troveId, uint256 amount) internal override {
        IFelixBorrowerOperations(borrowerOps).repayfeUSD(troveId, amount);
    }
}

/// @notice {LiquityV2TakerModule} for Felix (op 0 mints feUSD; op 1 is unchanged).
contract FelixTakerModule is LiquityV2TakerModule {
    constructor(address _permit3, address _collateralRegistry) LiquityV2TakerModule(_permit3, _collateralRegistry) {}

    function _debtToken() internal view override returns (address) {
        return IFelixCollateralRegistry(collateralRegistry).feUSDToken();
    }

    function _withdrawDebt(address borrowerOps, uint256 troveId, uint256 amount, uint256 maxUpfrontFee)
        internal
        override
    {
        IFelixBorrowerOperations(borrowerOps).withdrawfeUSD(troveId, amount, maxUpfrontFee);
    }
}

/// @notice {LiquityV2PreFundModule} for Felix (`Op.Repay` burns feUSD; `Op.AddColl`
///         is unchanged).
contract FelixPreFundModule is LiquityV2PreFundModule {
    constructor(address _permit3, address _settlement, address _collateralRegistry)
        LiquityV2PreFundModule(_permit3, _settlement, _collateralRegistry)
    {}

    function _debtToken() internal view override returns (address) {
        return IFelixCollateralRegistry(collateralRegistry).feUSDToken();
    }

    function _repayDebt(address borrowerOps, uint256 troveId, uint256 amount) internal override {
        IFelixBorrowerOperations(borrowerOps).repayfeUSD(troveId, amount);
    }
}
