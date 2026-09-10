// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ListaSmartSupplyCollateralModule, ListaSmartTakerModule} from "../../src/ListaSmartModules.sol";
import {ListaBrokerModule} from "../../src/ListaBrokerModule.sol";
import {ListaModulesBase, IMoolahSigViews, IListaBrokerViews} from "../shared/ListaModulesBase.t.sol";
import {IMoolah, MarketParams, MarketParamsLib} from "../../src/interfaces/ILista.sol";

/// @dev BSC-fork coverage of the SmartLP (`SmartProvider`) collateral shape on
///      the ONE brokered SmartLP market — slisBNB & BNB-SmartLP / WBNB
///      (id 0x34b1…b8e4, provider 0xC3be…, broker 0x3ade…, oracle = broker).
///
///      The collateral token is a receipt only Moolah can hold, so the legs run
///      the SmartProvider ABI: one-sided coin in (`supplyCollateral` with the
///      other amount 0), one coin out (`withdrawCollateralOneCoin`). The pool is
///      `[slisBNB, native BNB]` (coin order from `dex.coins(i)`, roster-pinned) —
///      the modules use coin 0 (slisBNB); the native coin index fails closed.
///
///      The borrow leg then rides the ORDINARY broker taker op on the same
///      market — proving the "LP broker" combination end to end: SmartLP
///      collateral in, fixed-term WBNB debt out.
contract ListaSmartLpTest is ListaModulesBase {
    using MarketParamsLib for MarketParams;

    address constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant PROVIDER_SMART = 0xC3be83DE4b19aFC4F6021Ea5011B75a3542024dE;
    address constant RECEIPT = 0x719f6445cdAC08B84611D0F19d733F57214bcfee; // slisBNB&BNB-SmartLP
    address constant BROKER_SMART = 0x3ade951523e81dD45e5787bb0b95Ce7341Db1287;

    uint256 constant COIN_IN = 1e18; //           slisBNB zapped in
    /// @dev slisBNB ≈ 1.05 BNB at the pin and the LP is BNB-denominated, so one
    ///      coin mints ≳1 LP; 0.9 is a wide floor (the maker prices the margin).
    uint256 constant MIN_LP_RATE = 0.9e18; //     LP-wei per slisBNB-wei floor
    /// @dev The inverse leg: one LP burns to ≲0.97 slisBNB one-sided.
    uint256 constant MIN_OUT_RATE = 0.85e18; //   slisBNB-wei per LP-wei floor

    ListaSmartSupplyCollateralModule smartSupply;
    ListaSmartTakerModule smartTaker;

    function setUp() public override {
        super.setUp();
        smartSupply = new ListaSmartSupplyCollateralModule(address(permit3), address(settlement));
        smartTaker = new ListaSmartTakerModule(address(permit3));
        vm.label(address(smartSupply), "listaSmartSupplyModule");
        vm.label(address(smartTaker), "listaSmartTakerModule");
        vm.label(PROVIDER_SMART, "smartProvider");
        vm.label(RECEIPT, "smartLpReceipt");
    }

    function _mpSmart() internal pure returns (MarketParams memory) {
        return MarketParams({loanToken: WBNB, collateralToken: RECEIPT, oracle: BROKER_SMART, irm: IRM, lltv: 0.965e18});
    }

    function _collateral() internal view returns (uint256) {
        return IMoolah(MOOLAH).position(_mpSmart().id(), maker).collateral;
    }

    function _smartSupplyData() internal pure returns (bytes memory) {
        return abi.encode(PROVIDER_SMART, SLISBNB, uint256(0), MIN_LP_RATE, _mpSmart());
    }

    function _smartWithdrawData() internal pure returns (bytes memory) {
        return abi.encode(PROVIDER_SMART, MOOLAH, uint256(0), MIN_OUT_RATE, _mpSmart());
    }

    /// @dev Moolah custodies all listed tokens — the guaranteed live whale.
    function _give(address token, address to, uint256 amount) internal {
        vm.prank(MOOLAH);
        IERC20(token).transfer(to, amount);
    }

    function _giveSlis(address to, uint256 amount) internal {
        _give(SLISBNB, to, amount);
    }

    /// @dev Zap `COIN_IN` slisBNB into LP collateral via the MAKE module.
    function _supplyLp() internal returns (uint256 minted) {
        _giveSlis(maker, COIN_IN);
        vm.startPrank(maker);
        IERC20(SLISBNB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(smartSupply), SLISBNB, uint160(COIN_IN), 0);
        vm.stopPrank();

        uint256 before = _collateral();
        vm.prank(address(settlement));
        smartSupply.makeOnBehalf(maker, COIN_IN, _smartSupplyData());
        minted = _collateral() - before;
    }

    // ──────────────────── Supply (one-sided coin zap) ────────────────────

    function test_smartSupply_oneCoin_creditsLpCollateral() public {
        uint256 minted = _supplyLp();
        assertGe(minted, COIN_IN * MIN_LP_RATE / 1e18, "at least the signed LP floor minted");
        assertEq(IERC20(SLISBNB).balanceOf(maker), 0, "coin fully consumed");
        assertEq(IERC20(SLISBNB).balanceOf(address(smartSupply)), 0, "module holds nothing");
        assertEq(IERC20(SLISBNB).allowance(address(smartSupply), PROVIDER_SMART), 0, "provider approval cleared");
    }

    /// @dev A native coin index fails closed: the provider requires the native
    ///      coin's amount to equal `msg.value`, which a token-funded module
    ///      never sends.
    function test_smartSupply_nativeCoinIndex_failsClosed() public {
        _giveSlis(maker, COIN_IN);
        vm.startPrank(maker);
        IERC20(SLISBNB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(smartSupply), SLISBNB, uint160(COIN_IN), 0);
        vm.stopPrank();

        bytes memory data = abi.encode(PROVIDER_SMART, SLISBNB, uint256(1), MIN_LP_RATE, _mpSmart());
        vm.prank(address(settlement));
        vm.expectRevert(bytes("amount1 should equal msg.value"));
        smartSupply.makeOnBehalf(maker, COIN_IN, data);
    }

    // ──────────────────── Withdraw (one coin out) ────────────────────

    function test_smartWithdraw_oneCoin_onchainAuth() public {
        uint256 minted = _supplyLp();
        uint256 burn = minted / 2;

        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(smartTaker), true);

        vm.prank(address(permit3));
        smartTaker.takeOnBehalf(maker, burn, solver, _smartWithdrawData());

        assertGe(IERC20(SLISBNB).balanceOf(solver), burn * MIN_OUT_RATE / 1e18, "solver got >= the signed coin floor");
        assertEq(_collateral(), minted - burn, "LP units burned exactly");
    }

    /// @dev The exact gap the calldata-sdk route matrix flags as needing "a
    ///      dedicated adapter the user authorizes": the withdraw gate is
    ///      `Moolah.isAuthorized`, grantable SIGNATURE-ONLY through the module's
    ///      auth tail (target = the Moolah singleton, not the provider).
    function test_smartWithdraw_sigOnlyAuth() public {
        uint256 minted = _supplyLp();
        uint256 burn = minted / 2;

        assertFalse(IMoolahSigViews(MOOLAH).isAuthorized(maker, address(smartTaker)), "no prior grant");

        bytes memory data =
            abi.encodePacked(_smartWithdrawData(), _moolahAuthBlock(address(smartTaker), block.timestamp + 1 days));

        vm.prank(address(permit3));
        smartTaker.takeOnBehalf(maker, burn, solver, data);

        assertTrue(IMoolahSigViews(MOOLAH).isAuthorized(maker, address(smartTaker)), "sig-auth replayed in-call");
        assertGe(IERC20(SLISBNB).balanceOf(solver), burn * MIN_OUT_RATE / 1e18, "solver got the coin");
    }

    function test_smartWithdraw_requiresAuth() public {
        uint256 minted = _supplyLp();
        vm.prank(address(permit3));
        vm.expectRevert(bytes("unauthorized sender"));
        smartTaker.takeOnBehalf(maker, minted / 2, solver, _smartWithdrawData());
        assertEq(_collateral(), minted, "position untouched");
    }

    // ──────────────────── The signed slippage floors ────────────────────
    //
    // Both SmartLP legs cross a POOL, so both carry a maker-signed 1e18-scaled
    // RATE rather than an absolute minimum — the module multiplies it by the
    // per-slice amount so a partial fill gets a proportional floor. A floor that
    // is carried in `data` but never enforced is indistinguishable from a floor
    // that is, until the day the pool moves, so each direction gets a case that
    // makes it bite.

    /// @dev Supply: `minLpRate` is LP-wei per coin-wei. One slisBNB mints ≈1 LP,
    ///      so demanding 100 LP per coin cannot be met and the mint must revert
    ///      rather than credit the position with whatever the pool gave.
    function test_smartSupply_minLpRate_floorBites() public {
        _giveSlis(maker, COIN_IN);
        vm.startPrank(maker);
        IERC20(SLISBNB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(smartSupply), SLISBNB, uint160(COIN_IN), 0);
        vm.stopPrank();

        uint256 before = _collateral();
        bytes memory data = abi.encode(PROVIDER_SMART, SLISBNB, uint256(0), uint256(100e18), _mpSmart());

        // The pool's own check, reached because the module forwarded
        // `amount * minLpRate / 1e18` as the venue's `minLp` argument.
        vm.prank(address(settlement));
        vm.expectRevert(bytes("Slippage screwed you"));
        smartSupply.makeOnBehalf(maker, COIN_IN, data);

        assertEq(_collateral(), before, "no collateral credited");
        assertEq(IERC20(SLISBNB).balanceOf(maker), COIN_IN, "the maker's coin stayed put");
    }

    /// @dev Withdraw: `minOutRate` is coin-wei per LP-wei — the inverse leg. One
    ///      LP burns to ≲1 slisBNB, so demanding 100 must revert; without the
    ///      floor a drained pool would pay the receiver dust for a real burn.
    function test_smartWithdraw_minOutRate_floorBites() public {
        uint256 minted = _supplyLp();
        uint256 burn = minted / 2;

        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(smartTaker), true);

        bytes memory data = abi.encode(PROVIDER_SMART, MOOLAH, uint256(0), uint256(100e18), _mpSmart());

        // The pool's own check on the way out, reached because the module
        // forwarded `amount * minOutRate / 1e18` as the venue's minimum.
        vm.prank(address(permit3));
        vm.expectRevert(bytes("Not enough coins removed"));
        smartTaker.takeOnBehalf(maker, burn, solver, data);

        assertEq(_collateral(), minted, "no LP burned");
        assertEq(IERC20(SLISBNB).balanceOf(solver), 0, "receiver got nothing");
    }

    // ──────────────────── The coin/index pairing ────────────────────

    /// @dev `coin` and `coinIndex` are two independent maker-signed fields naming
    ///      ONE thing, and the module never derives either from the other — the
    ///      roster's coin order is authoritative. A mismatched pair must fail
    ///      closed: the module pulls and approves the `coin` it was given, while
    ///      the provider `transferFrom`s the coin its INDEX names, which this
    ///      module never approved. Pinned because "fails closed" here rests on
    ///      the venue, not on a check in our own code.
    function test_smartSupply_coinIndexMismatch_failsClosed() public {
        _giveSlis(maker, COIN_IN);
        _give(WBNB, maker, COIN_IN);
        // Approve BOTH coins all the way through, so the mismatch is the only
        // thing left that can fail. Without this the call dies on the module's
        // own pull and the test would pass without ever reaching the provider.
        vm.startPrank(maker);
        IERC20(SLISBNB).approve(address(permit3), type(uint256).max);
        IERC20(WBNB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(smartSupply), SLISBNB, uint160(COIN_IN), 0);
        permit3.approveToken(address(smartSupply), WBNB, uint160(COIN_IN), 0);
        vm.stopPrank();

        uint256 before = _collateral();

        // coinIndex 0 (slisBNB) paired with WBNB as the pulled coin. The module
        // pulls and approves WBNB; the provider `transferFrom`s slisBNB — the coin
        // the INDEX names — from a module that approved it nothing.
        vm.prank(address(settlement));
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        smartSupply.makeOnBehalf(maker, COIN_IN, abi.encode(PROVIDER_SMART, WBNB, uint256(0), MIN_LP_RATE, _mpSmart()));

        assertEq(_collateral(), before, "no collateral credited");
        assertEq(IERC20(SLISBNB).balanceOf(address(smartSupply)), 0, "module holds no coin");
        assertEq(IERC20(WBNB).balanceOf(address(smartSupply)), 0, "module holds no coin");

        // The positive control: the SAME grants with a correctly-paired blob go
        // through, which is what isolates the pairing as the cause above.
        vm.prank(address(settlement));
        smartSupply.makeOnBehalf(maker, COIN_IN, _smartSupplyData());
        assertGt(_collateral(), before, "the correctly-paired blob credits collateral");
    }

    /// @dev The header's fail-closed claim for a position that moved between
    ///      signing and filling: `amount` is LP UNITS and there is no BalanceMode
    ///      here, so a burn larger than the live position reverts in the venue
    ///      rather than silently taking whatever is left.
    function test_smartWithdraw_burnAbovePosition_failsClosed() public {
        uint256 minted = _supplyLp();

        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(smartTaker), true);

        // Fails as an arithmetic PANIC, not a `require` — Moolah subtracts the
        // burn from the position and underflows. Pinned as such because "reverts"
        // and "reverts with a checked message" are different guarantees, and only
        // one of them survives a venue upgrade that adds unchecked math.
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        smartTaker.takeOnBehalf(maker, minted + 1, solver, _smartWithdrawData());

        assertEq(_collateral(), minted, "position untouched");
    }



    // ──────────────────── The LP BROKER combination ────────────────────

    /// @dev SmartLP collateral + fixed-term broker debt on the same market:
    ///      the collateral leg runs the SmartProvider ABI, the borrow leg the
    ///      ordinary broker taker op — end to end against the live deployment.
    function test_smartLpCollateral_thenBrokerBorrow() public {
        uint256 minted = _supplyLp();
        assertGt(minted, 0, "LP collateral in place");

        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(brokerModule), true);

        uint256[3][] memory terms = IListaBrokerViews(BROKER_SMART).getFixedTerms();
        assertGt(terms.length, 0, "live term menu non-empty");
        uint256 borrowOut = 0.05e18; // WBNB, > minLoan (~0.021)

        vm.prank(address(permit3));
        brokerModule.takeOnBehalf(
            maker, borrowOut, solver, abi.encode(uint8(ListaBrokerModule.Op.Borrow), BROKER_SMART, terms[0][0])
        );

        assertEq(IERC20(WBNB).balanceOf(solver), borrowOut, "WBNB debt proceeds delivered ERC20");
        assertGe(IListaBrokerViews(BROKER_SMART).getUserTotalDebt(maker), borrowOut, "broker debt on the maker");
    }
}
