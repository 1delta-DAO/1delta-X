// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ListaNativeSupplyCollateralModule, ListaNativeCollateralTakerModule} from "../../src/ListaNativeModules.sol";
import {ListaBrokerModule} from "../../src/ListaBrokerModule.sol";
import {ListaModulesBase, IMoolahSigViews, IListaBrokerViews} from "../shared/ListaModulesBase.t.sol";
import {IMoolah, MarketParams, MarketParamsLib} from "../../src/interfaces/ILista.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

/// @dev BSC-fork coverage of Lista's PROVIDER-GATED (Morpho-shaped) markets —
///      the two provider generations that FORWARD Moolah's own selectors:
///
///      • erc20 (slisBNB provider `0x33f7…`, 5 markets): plain forwarder —
///        the Morpho-shaped modules work pointed at it (supply via the venue
///        word, withdraw via op 2's split venue/auth words).
///      • native (WBNB provider `0x3673…`, WBNB/lisUSD): NOT a forwarder —
///        supply is a 3-arg payable (amount = `msg.value`; the 4-arg ERC20
///        shape reverts, pinned below) and withdraw pays `receiver` raw
///        native, so the market runs on the dedicated wrap/unwrap modules in
///        {ListaNativeModules} (the cEther pattern).
///
///      On both, Moolah itself rejects any non-provider caller
///      ("not provider") — the collateral legs must route via the provider.
///
///      Also pins the wrapped-native LOAN side: slisBNB/WBNB is the ONE market
///      with a loan-side native provider registered (direct EOA borrows pay
///      native BNB there) — the module's on-behalf borrow must still pay WBNB
///      ERC20.
contract ListaProviderMarketsTest is ListaModulesBase {
    using MarketParamsLib for MarketParams;

    // ── slisBNB/WBNB market (id 0x2269…3cac): erc20 provider, nat-loan, orc=brk ──
    address constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant PROVIDER_ERC20 = 0x33f7A980a246f9B8FEA2254E3065576E127D4D5f;
    address constant BROKER_SLIS = 0x1Fa26015286D1270343d7526C60bd57aB6bE8b54;

    // ── WBNB/lisUSD market (id 0x2a67…733b): native provider, legacy oracle ──
    address constant LISUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
    address constant PROVIDER_NATIVE = 0x367384C54756a25340c63057D87eA22d47Fd5701;
    address constant ORACLE_LISUSD = 0xf3afD82A4071f272F403dC176916141f44E6c750;

    uint256 constant COLLATERAL_IN = 1e18;

    function _mpSlis() internal pure returns (MarketParams memory) {
        return MarketParams({loanToken: WBNB, collateralToken: SLISBNB, oracle: BROKER_SLIS, irm: IRM, lltv: 0.965e18});
    }

    function _mpWbnbColl() internal pure returns (MarketParams memory) {
        return MarketParams({loanToken: LISUSD, collateralToken: WBNB, oracle: ORACLE_LISUSD, irm: IRM, lltv: 0.86e18});
    }

    /// @dev Moolah custodies every market's collateral and loan liquidity — the
    ///      one whale guaranteed live at the pin for any listed token.
    function _give(address token, address to, uint256 amount) internal {
        vm.prank(MOOLAH);
        IERC20(token).transfer(to, amount);
    }

    /// @dev Supply `amount` collateral through the provider via the MAKE module.
    function _supplyViaProvider(address provider, MarketParams memory mp, uint256 amount) internal {
        _give(mp.collateralToken, maker, amount);
        vm.startPrank(maker);
        IERC20(mp.collateralToken).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(supplyModule), mp.collateralToken, uint160(amount), 0);
        vm.stopPrank();
        vm.prank(address(settlement));
        supplyModule.makeOnBehalf(maker, amount, abi.encode(provider, mp));
    }

    function _collateral(MarketParams memory mp) internal view returns (uint256) {
        return IMoolah(MOOLAH).position(mp.id(), maker).collateral;
    }

    // ──────────────────── The structural exclusion, pinned ────────────────────

    /// @dev On a provider-gated market Moolah itself refuses every non-provider
    ///      caller — the reason the collateral legs MUST route via the provider.
    function test_providerGated_directMoolahSupply_reverts() public {
        _give(SLISBNB, maker, COLLATERAL_IN);
        vm.startPrank(maker);
        IERC20(SLISBNB).approve(MOOLAH, COLLATERAL_IN);
        vm.expectRevert(bytes("not provider"));
        IMoolah(MOOLAH).supplyCollateral(_mpSlis(), COLLATERAL_IN, maker, "");
        vm.stopPrank();
    }

    // ──────────────────── erc20 provider (slisBNB markets) ────────────────────

    /// @dev The Morpho-shaped MAKE module works pointed at the erc20 provider:
    ///      same selector, provider `transferFrom`s the coin and books the
    ///      collateral on Moolah under the maker.
    function test_erc20Provider_supply_moduleFlow() public {
        uint256 before = _collateral(_mpSlis());
        _supplyViaProvider(PROVIDER_ERC20, _mpSlis(), COLLATERAL_IN);
        assertEq(_collateral(_mpSlis()) - before, COLLATERAL_IN, "collateral booked via provider");
        assertEq(IERC20(SLISBNB).balanceOf(address(supplyModule)), 0, "module holds nothing");
    }

    /// @dev op 2 Exact withdraw through the provider with a PRIOR on-chain
    ///      Moolah grant (the auth gate lives on Moolah, not the provider).
    function test_erc20Provider_withdraw_op2_onchainAuth() public {
        _supplyViaProvider(PROVIDER_ERC20, _mpSlis(), COLLATERAL_IN);
        uint256 out = COLLATERAL_IN / 2;

        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(takerModule), true);

        vm.prank(address(permit3));
        takerModule.takeOnBehalf(maker, out, solver, abi.encode(uint8(2), PROVIDER_ERC20, MOOLAH, _mpSlis()));

        assertEq(IERC20(SLISBNB).balanceOf(solver), out, "solver received the coin");
        assertEq(_collateral(_mpSlis()), COLLATERAL_IN - out, "collateral reduced exactly");
    }

    /// @dev op 2's split venue/auth words: signature-only grant, no prior
    ///      on-chain tx — the sig tail replays against the Moolah SINGLETON
    ///      while the withdraw call goes to the provider. (Pointing op 1 at the
    ///      provider would aim the replay at the provider — a swallowed no-op —
    ///      and the withdraw would revert unauthorized.)
    function test_erc20Provider_withdraw_op2_sigOnlyAuth() public {
        _supplyViaProvider(PROVIDER_ERC20, _mpSlis(), COLLATERAL_IN);
        uint256 out = COLLATERAL_IN / 2;

        assertFalse(IMoolahSigViews(MOOLAH).isAuthorized(maker, address(takerModule)), "no prior grant");

        // base 256, explicit BalanceMode (0 = Exact) @256, auth block @288.
        bytes memory data = abi.encodePacked(
            abi.encode(uint8(2), PROVIDER_ERC20, MOOLAH, _mpSlis(), uint256(0)),
            _moolahAuthBlock(address(takerModule), block.timestamp + 1 days)
        );

        vm.prank(address(permit3));
        takerModule.takeOnBehalf(maker, out, solver, data);

        assertTrue(IMoolahSigViews(MOOLAH).isAuthorized(maker, address(takerModule)), "sig-auth replayed in-call");
        assertEq(IERC20(SLISBNB).balanceOf(solver), out, "solver received the coin");
    }

    /// @dev op 2 Full mode: the whole live position in one slice, provider-routed.
    function test_erc20Provider_withdraw_op2_fullMode() public {
        _supplyViaProvider(PROVIDER_ERC20, _mpSlis(), COLLATERAL_IN);

        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(takerModule), true);

        // base 256, BalanceMode (TAGGED Full — see DustHandler.encodeMode) @256,
        // maker-signed total @288.
        bytes memory data = abi.encode(uint8(2), PROVIDER_ERC20, MOOLAH, _mpSlis(), DustHandler.encodeMode(DustHandler.BalanceMode.Full), COLLATERAL_IN);

        vm.prank(address(permit3));
        takerModule.takeOnBehalf(maker, COLLATERAL_IN, solver, data);

        assertEq(IERC20(SLISBNB).balanceOf(solver), COLLATERAL_IN, "full position delivered");
        assertEq(_collateral(_mpSlis()), 0, "position closed");
        assertEq(IERC20(SLISBNB).balanceOf(address(takerModule)), 0, "module drained");
    }

    // ──────────────────── native provider (WBNB collateral) ────────────────────

    /// @dev The venue fact that forces the dedicated native modules: the native
    ///      provider's 4-arg (Morpho-shaped, ERC20) supply selector reverts —
    ///      supply is payable-only, amount = `msg.value`.
    function test_nativeProvider_erc20ShapeSupply_reverts() public {
        _give(WBNB, maker, COLLATERAL_IN);
        vm.startPrank(maker);
        IERC20(WBNB).approve(PROVIDER_NATIVE, COLLATERAL_IN);
        // Bare on purpose, and the only case in this file that is: the 4-arg
        // selector does not exist on this provider, so the call reverts with EMPTY
        // returndata — there is no message to pin.
        vm.expectRevert();
        IMoolah(PROVIDER_NATIVE).supplyCollateral(_mpWbnbColl(), COLLATERAL_IN, maker, "");
        vm.stopPrank();
    }

    /// @dev The wrap/unwrap module pair end to end: WBNB in (unwrapped at the
    ///      provider boundary), native out wrapped back — maker and solver see
    ///      ERC20 WBNB only.
    function test_nativeProvider_supply_withdraw_moduleFlow() public {
        ListaNativeSupplyCollateralModule nativeSupply =
            new ListaNativeSupplyCollateralModule(address(permit3), address(settlement));
        ListaNativeCollateralTakerModule nativeTaker = new ListaNativeCollateralTakerModule(address(permit3));

        _give(WBNB, maker, COLLATERAL_IN);
        vm.startPrank(maker);
        IERC20(WBNB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(nativeSupply), WBNB, uint160(COLLATERAL_IN), 0);
        vm.stopPrank();

        uint256 before = _collateral(_mpWbnbColl());
        vm.prank(address(settlement));
        nativeSupply.makeOnBehalf(maker, COLLATERAL_IN, abi.encode(PROVIDER_NATIVE, _mpWbnbColl()));
        assertEq(_collateral(_mpWbnbColl()) - before, COLLATERAL_IN, "WBNB collateral booked via native provider");
        assertEq(address(nativeSupply).balance, 0, "no native stranded on the supply module");

        // Withdraw half with a SIGNATURE-ONLY Moolah grant (auth tail @256,
        // explicit Exact mode word @224).
        uint256 out = COLLATERAL_IN / 2;
        bytes memory data = abi.encodePacked(
            abi.encode(PROVIDER_NATIVE, MOOLAH, _mpWbnbColl(), uint256(0)),
            _moolahAuthBlock(address(nativeTaker), block.timestamp + 1 days)
        );

        uint256 nativeBefore = solver.balance;
        vm.prank(address(permit3));
        nativeTaker.takeOnBehalf(maker, out, solver, data);

        assertEq(IERC20(WBNB).balanceOf(solver), out, "solver received WBNB ERC20 (wrapped back)");
        assertEq(solver.balance, nativeBefore, "solver saw no raw native");
        assertEq(address(nativeTaker).balance, 0, "no native stranded on the taker module");
        assertEq(_collateral(_mpWbnbColl()), COLLATERAL_IN - out, "collateral reduced exactly");
    }

    /// @dev Deploy the native pair and seed `amount` WBNB collateral through it.
    ///      Returns both so the caller can drive either leg.
    function _nativePair(uint256 amount)
        internal
        returns (ListaNativeSupplyCollateralModule nativeSupply, ListaNativeCollateralTakerModule nativeTaker)
    {
        nativeSupply = new ListaNativeSupplyCollateralModule(address(permit3), address(settlement));
        nativeTaker = new ListaNativeCollateralTakerModule(address(permit3));

        _give(WBNB, maker, amount);
        vm.startPrank(maker);
        IERC20(WBNB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(nativeSupply), WBNB, uint160(amount), 0);
        vm.stopPrank();
        vm.prank(address(settlement));
        nativeSupply.makeOnBehalf(maker, amount, abi.encode(PROVIDER_NATIVE, _mpWbnbColl()));
    }

    /// @dev Full mode on the native taker: the whole live position out as WBNB.
    function test_nativeProvider_withdraw_fullMode() public {
        (ListaNativeSupplyCollateralModule nativeSupply, ListaNativeCollateralTakerModule nativeTaker) =
            _nativePair(COLLATERAL_IN);
        nativeSupply;

        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(nativeTaker), true);

        // base 224, BalanceMode (TAGGED Full — see DustHandler.encodeMode) @224,
        // maker-signed total @256.
        bytes memory data = abi.encode(PROVIDER_NATIVE, MOOLAH, _mpWbnbColl(), DustHandler.encodeMode(DustHandler.BalanceMode.Full), COLLATERAL_IN);
        vm.prank(address(permit3));
        nativeTaker.takeOnBehalf(maker, COLLATERAL_IN, solver, data);

        assertEq(IERC20(WBNB).balanceOf(solver), COLLATERAL_IN, "full position delivered as WBNB");
        assertEq(_collateral(_mpWbnbColl()), 0, "position closed");
    }

    /// @dev The native taker rides the SAME Moolah grant as every other value-out
    ///      leg in the package — the provider forwards to the singleton and the
    ///      singleton is what checks. With no grant and no sig tail the withdraw
    ///      must fail closed, or the wrap/unwrap pair would be the one value-out
    ///      shape a maker could not gate.
    function test_nativeProvider_withdraw_requiresAuth() public {
        (, ListaNativeCollateralTakerModule nativeTaker) = _nativePair(COLLATERAL_IN);

        assertFalse(IMoolahSigViews(MOOLAH).isAuthorized(maker, address(nativeTaker)), "no grant");

        // NOTE the string: the native provider says `"unauthorized"` where the
        // SmartLP provider says `"unauthorized sender"`. Two generations, two
        // messages, same gate — which is exactly why each is pinned to the venue
        // it actually came from rather than asserted as a bare "it reverts".
        vm.prank(address(permit3));
        vm.expectRevert(bytes("unauthorized"));
        nativeTaker.takeOnBehalf(maker, COLLATERAL_IN / 2, solver, abi.encode(PROVIDER_NATIVE, MOOLAH, _mpWbnbColl()));

        assertEq(_collateral(_mpWbnbColl()), COLLATERAL_IN, "position untouched");
    }

    /// @dev `Full`'s auth tail sits at 288, NOT 256 — the maker-signed total
    ///      occupies 256. Getting that wrong would read the auth block's `nonce`
    ///      as the signed total (the branch-scoped-offset trap the op-1/op-2
    ///      headers call out), so the offset needs its own case rather than
    ///      riding on the Exact one.
    function test_nativeProvider_withdraw_fullMode_sigOnlyAuth() public {
        (, ListaNativeCollateralTakerModule nativeTaker) = _nativePair(COLLATERAL_IN);

        assertFalse(IMoolahSigViews(MOOLAH).isAuthorized(maker, address(nativeTaker)), "no prior grant");

        // base 224, TAGGED Full mode @224, maker-signed total @256, auth @288.
        bytes memory data = abi.encodePacked(
            abi.encode(
                PROVIDER_NATIVE,
                MOOLAH,
                _mpWbnbColl(),
                DustHandler.encodeMode(DustHandler.BalanceMode.Full),
                COLLATERAL_IN
            ),
            _moolahAuthBlock(address(nativeTaker), block.timestamp + 1 days)
        );

        uint256 nativeBefore = solver.balance;
        vm.prank(address(permit3));
        nativeTaker.takeOnBehalf(maker, COLLATERAL_IN, solver, data);

        assertTrue(IMoolahSigViews(MOOLAH).isAuthorized(maker, address(nativeTaker)), "sig-auth replayed in-call");
        assertEq(IERC20(WBNB).balanceOf(solver), COLLATERAL_IN, "full position delivered as WBNB");
        assertEq(solver.balance, nativeBefore, "solver saw no raw native");
        assertEq(_collateral(_mpWbnbColl()), 0, "position closed");
    }

    /// @dev `Full` liquidates the ENTIRE live balance, so a pro-rated slice would
    ///      unwind the whole position and brick the rest of the order. The signed
    ///      total in `data` is what pins the slice to the item.
    function test_nativeProvider_withdraw_fullMode_rejectsPartialSlice() public {
        (, ListaNativeCollateralTakerModule nativeTaker) = _nativePair(COLLATERAL_IN);

        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(nativeTaker), true);

        bytes memory data = abi.encode(
            PROVIDER_NATIVE, MOOLAH, _mpWbnbColl(), DustHandler.encodeMode(DustHandler.BalanceMode.Full), COLLATERAL_IN
        );

        uint256 slice = COLLATERAL_IN / 2;
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, slice, COLLATERAL_IN));
        nativeTaker.takeOnBehalf(maker, slice, solver, data);

        assertEq(_collateral(_mpWbnbColl()), COLLATERAL_IN, "position untouched");
    }

    /// @dev The excess path, which the equal-sized `Full` cases cannot reach:
    ///      `Full` burns the LIVE position, so when the position GREW after the
    ///      order was signed the unwrap produces more than the signed amount. The
    ///      surplus is the maker's — it must not be handed to `receiver`, and it
    ///      must not be left stranded on a shared module where the next filler
    ///      could claim it.
    function test_nativeProvider_withdraw_fullMode_excessGoesToMaker() public {
        (ListaNativeSupplyCollateralModule nativeSupply, ListaNativeCollateralTakerModule nativeTaker) =
            _nativePair(COLLATERAL_IN);

        // The position grows AFTER the signed total was fixed at COLLATERAL_IN.
        uint256 extra = 0.4e18;
        _give(WBNB, maker, extra);
        vm.startPrank(maker);
        permit3.approveToken(address(nativeSupply), WBNB, uint160(extra), 0);
        IMoolah(MOOLAH).setAuthorization(address(nativeTaker), true);
        vm.stopPrank();
        vm.prank(address(settlement));
        nativeSupply.makeOnBehalf(maker, extra, abi.encode(PROVIDER_NATIVE, _mpWbnbColl()));
        assertEq(_collateral(_mpWbnbColl()), COLLATERAL_IN + extra, "position grew past the signed total");

        bytes memory data = abi.encode(
            PROVIDER_NATIVE, MOOLAH, _mpWbnbColl(), DustHandler.encodeMode(DustHandler.BalanceMode.Full), COLLATERAL_IN
        );

        uint256 makerBefore = IERC20(WBNB).balanceOf(maker);
        vm.prank(address(permit3));
        nativeTaker.takeOnBehalf(maker, COLLATERAL_IN, solver, data);

        assertEq(IERC20(WBNB).balanceOf(solver), COLLATERAL_IN, "receiver capped at the signed amount");
        assertEq(IERC20(WBNB).balanceOf(maker) - makerBefore, extra, "the surplus went to the maker");
        assertEq(_collateral(_mpWbnbColl()), 0, "whole live position burned");
        assertEq(IERC20(WBNB).balanceOf(address(nativeTaker)), 0, "no WBNB stranded on the module");
        assertEq(address(nativeTaker).balance, 0, "no native stranded on the module");
    }

    /// @dev The same slice rule on the ERC20-provider path (op 2), whose `Full`
    ///      total sits one word further along than op 1's.
    function test_erc20Provider_withdraw_op2_fullMode_rejectsPartialSlice() public {
        _supplyViaProvider(PROVIDER_ERC20, _mpSlis(), COLLATERAL_IN);

        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(takerModule), true);

        bytes memory data = abi.encode(
            uint8(2),
            PROVIDER_ERC20,
            MOOLAH,
            _mpSlis(),
            DustHandler.encodeMode(DustHandler.BalanceMode.Full),
            COLLATERAL_IN
        );

        uint256 slice = COLLATERAL_IN / 4;
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, slice, COLLATERAL_IN));
        takerModule.takeOnBehalf(maker, slice, solver, data);

        assertEq(_collateral(_mpSlis()), COLLATERAL_IN, "position untouched");
    }

    // ──────────────────── wrapped-native LOAN side ────────────────────

    /// @dev slisBNB/WBNB is the one market whose loan-side native provider is
    ///      registered (direct EOA borrows pay native BNB). The module's
    ///      on-behalf borrow overload must still pay WBNB ERC20 — BROKERS.md
    ///      §4-B, pinned here.
    function test_natLoanMarket_onBehalfBorrow_paysErc20() public {
        _supplyViaProvider(PROVIDER_ERC20, _mpSlis(), COLLATERAL_IN);

        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(brokerModule), true);

        uint256[3][] memory terms = IListaBrokerViews(BROKER_SLIS).getFixedTerms();
        assertGt(terms.length, 0, "live term menu non-empty");
        uint256 borrowOut = 0.05e18; // > minLoan (~0.021 WBNB)

        uint256 nativeBefore = solver.balance;
        vm.prank(address(permit3));
        brokerModule.takeOnBehalf(
            maker, borrowOut, solver, abi.encode(uint8(ListaBrokerModule.Op.Borrow), BROKER_SLIS, terms[0][0])
        );

        assertEq(IERC20(WBNB).balanceOf(solver), borrowOut, "on-behalf borrow pays WBNB ERC20");
        assertEq(solver.balance, nativeBefore, "never native");
        assertGe(IListaBrokerViews(BROKER_SLIS).getUserTotalDebt(maker), borrowOut, "debt booked on the maker");
    }
}
