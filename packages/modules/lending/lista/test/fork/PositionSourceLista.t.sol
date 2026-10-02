// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/Settlement.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {ListaNativeSupplyCollateralModule, ListaNativeCollateralTakerModule} from "../../src/ListaNativeModules.sol";
import {ListaModulesBase} from "../shared/ListaModulesBase.t.sol";
import {IMoolah, MarketParams, MarketParamsLib} from "../../src/interfaces/ILista.sol";

/// @title Audit 2026-09-30 L-LIB-8 — Lista withdraw modules report the live position
/// @notice {ListaTakerModule} (ops 1 and 2) and {ListaNativeCollateralTakerModule}
///         had `BalanceMode.Full` withdraws but no {IPositionSource} reader, so a
///         position-sized exit reverted `NoPositionItem`. Raw staticcalls so this
///         compiles — and fails — against the pre-fix modules.
contract PositionSourceListaTest is ListaModulesBase {
    using MarketParamsLib for MarketParams;

    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
    address constant PROVIDER_NATIVE = 0x367384C54756a25340c63057D87eA22d47Fd5701;
    address constant ORACLE_LISUSD = 0xf3afD82A4071f272F403dC176916141f44E6c750;

    function _pos(address module, bytes memory data) internal view returns (address asset, uint256 amount) {
        (bool ok, bytes memory ret) =
            module.staticcall(abi.encodeCall(IPositionSource.positionOf, (maker, data)));
        assertTrue(ok && ret.length == 64, "module answers positionOf");
        (asset, amount) = abi.decode(ret, (address, uint256));
    }

    function test_audit_L_LIB_8_listaTakerPositionOfAndPositionSizedFill() public {
        _seedCollateral(2e17);
        (address asset, uint256 amount) = _pos(address(takerModule), _withdrawData());
        assertEq(asset, BTCB, "denominated in the collateral token");
        assertEq(amount, _makerCollateral(), "the raw Moolah collateral");

        // op 2 reads the SAME singleton position through the provider-split layout.
        (asset, amount) = _pos(address(takerModule), abi.encode(uint8(2), address(0xBEEF), MOOLAH, _mp()));
        assertEq(amount, _makerCollateral(), "op 2: position from the Moolah singleton");

        PositionFillModule pfm = new PositionFillModule();
        Order memory o = _buildWithdrawOrder(3e17, 1_000e18);
        o.fillModule = address(pfm);
        o.fillTotal = 3e17;
        assertEq(pfm.resolveFill(o, 0, type(uint256).max, ""), _makerCollateral(), "fill sized from the position");
    }

    function test_audit_L_LIB_8_listaNativeTakerPositionOf() public {
        ListaNativeSupplyCollateralModule nativeSupply =
            new ListaNativeSupplyCollateralModule(address(permit3), address(settlement));
        ListaNativeCollateralTakerModule nativeTaker = new ListaNativeCollateralTakerModule(address(permit3));
        MarketParams memory mp =
            MarketParams({loanToken: LISUSD, collateralToken: WBNB, oracle: ORACLE_LISUSD, irm: IRM, lltv: 0.86e18});
        vm.prank(MOOLAH);
        IERC20(WBNB).transfer(maker, 1e18);
        vm.startPrank(maker);
        IERC20(WBNB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(nativeSupply), WBNB, uint160(1e18), 0);
        vm.stopPrank();
        vm.prank(address(settlement));
        nativeSupply.makeOnBehalf(maker, 1e18, abi.encode(PROVIDER_NATIVE, mp));

        (address asset, uint256 amount) = _pos(address(nativeTaker), abi.encode(PROVIDER_NATIVE, MOOLAH, mp));
        assertEq(asset, WBNB, "the wrapped native the module delivers");
        assertEq(amount, IMoolah(MOOLAH).position(mp.id(), maker).collateral, "raw Moolah collateral");
        assertGe(amount, 1e18);
    }
}
