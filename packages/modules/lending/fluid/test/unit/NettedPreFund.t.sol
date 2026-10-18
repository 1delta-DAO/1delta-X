// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdError} from "forge-std/StdError.sol";
import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {FluidPreFundModule} from "../../src/FluidPreFundModules.sol";
import {FluidTakerModule} from "../../src/FluidModules.sol";

/// @dev The ERC721 half of Fluid's VaultFactory: positions are NFTs, and
///      `getVaultAddress` binds a vault id to the vault the factory deployed.
contract NettedFluidFactory {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => address) public getVaultAddress;
    uint256 public nextId = 1;

    function register(uint256 vaultId, address vault) external {
        getVaultAddress[vaultId] = vault;
    }

    function mint(address to) external returns (uint256 id) {
        id = nextId++;
        ownerOf[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "not owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        ownerOf[id] = to;
    }
}

/// @dev A T1 vault with Fluid's semantics where these modules depend on them:
///      supply/payback are PERMISSIONLESS and pulled FROM `msg.sender` BY THE VAULT
///      (the `liquidityCallback` spender rule); withdraw/borrow are strict-`ownerOf`;
///      a literal payback above the debt reverts (`Vault__ExcessDebtPayback`);
///      `type(int256).min` pays back exactly the live debt and reverts on a zero debt;
///      one end-of-operate health check (`debt <= col * 90%`, 1:1 price).
contract NettedFluidVault {
    NettedFluidFactory public immutable factory;
    MockERC20 public immutable supplyToken;
    MockERC20 public immutable borrowToken;
    uint256 public immutable VAULT_ID;

    mapping(uint256 => uint256) public col;
    mapping(uint256 => uint256) public debt;

    error NotAnOwner();
    error ExcessDebtPayback();
    error PositionAboveCF();
    error NothingToPayBack();

    constructor(NettedFluidFactory f, uint256 id, MockERC20 s, MockERC20 b) {
        factory = f;
        VAULT_ID = id;
        supplyToken = s;
        borrowToken = b;
    }

    function constantsView() external view returns (address, address, address, address, address, address) {
        return (address(this), address(factory), address(0), address(0), address(supplyToken), address(borrowToken));
    }

    /// @dev Interest accrual: the debt grows with no token moving.
    function accrue(uint256 nftId, uint256 interest) external {
        debt[nftId] += interest;
    }

    function operate(uint256 nftId, int256 newCol, int256 newDebt, address to)
        external
        payable
        returns (uint256, int256, int256)
    {
        if (to == address(0)) to = msg.sender;
        if (nftId == 0) nftId = factory.mint(msg.sender);
        else if ((newCol < 0 || newDebt > 0) && factory.ownerOf(nftId) != msg.sender) revert NotAnOwner();

        if (newCol > 0) {
            supplyToken.transferFrom(msg.sender, address(this), uint256(newCol));
            col[nftId] += uint256(newCol);
        } else if (newCol < 0) {
            col[nftId] -= uint256(-newCol);
            supplyToken.transfer(to, uint256(-newCol));
        }

        if (newDebt > 0) {
            debt[nftId] += uint256(newDebt);
            borrowToken.mint(to, uint256(newDebt));
        } else if (newDebt < 0) {
            uint256 amt;
            if (newDebt == type(int256).min) {
                amt = debt[nftId];
                if (amt == 0) revert NothingToPayBack();
                newDebt = -int256(amt);
            } else {
                amt = uint256(-newDebt);
                if (amt > debt[nftId]) revert ExcessDebtPayback();
            }
            borrowToken.transferFrom(msg.sender, address(this), amt);
            debt[nftId] -= amt;
        }

        if (debt[nftId] * 10 > col[nftId] * 9) revert PositionAboveCF();
        return (nftId, newCol, newDebt);
    }
}

/// @title FluidNettedPreFundTest
/// @notice {FluidPreFundModule} on the NETTED path (`matchSettle`), modelled on the
///         aave-v3 `NettedPreFund` suite (review 2026-10-18 M-6).
///
///         Part 1 is the shared-singleton interleaving: two makers' deliveries parked
///         on ONE module between their DELIVER and their ITEM, with residue already
///         there, including a RepayAll that consumes LESS than its delivery (the
///         clamp) — the case where a sweep sized from anything but the pre-call floor
///         would hand the parked delivery to the wrong maker.
///
///         Part 2 is the two acyclic position shapes the module exists for — the
///         open (borrow TAKE early, Deposit late) and the FULL close (withdraw TAKE
///         early, RepayAll late) — at zero solver capital, plus the LTV-edge close
///         that is a true cycle and must revert.
contract FluidNettedPreFundTest is MockSettlementBase {
    FluidPreFundModule preFund;
    FluidTakerModule taker;
    NettedFluidFactory factory;
    NettedFluidVault v1; // supply tB, borrow tA
    NettedFluidVault v2; // supply tA, borrow tB

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);
    uint256 malloryPk = 0xBAD;
    address mallory = vm.addr(malloryPk);

    uint256 constant IN_A = 1_000e18;
    uint256 constant OUT_A = 13e18; //  alice: deposit into v1
    uint256 constant IN_B = 2_000e18;
    uint256 constant OUT_B = 7e18; //   bob: RepayAll on v2, debt below the delivery
    uint256 constant DEBT_B = 5e18; //  → 2e18 must come back to BOB, and only to bob
    uint256 constant RESIDUE = 3e18; // stray tB already on the singleton

    uint256 aliceV1; // alice's v1 position
    uint256 bobV2; //   bob's v2 position

    function setUp() public override {
        super.setUp();
        preFund = new FluidPreFundModule(address(permit3), address(settlement));
        factory = new NettedFluidFactory();
        v1 = new NettedFluidVault(factory, 1, tB, tA);
        v2 = new NettedFluidVault(factory, 2, tA, tB);
        factory.register(1, address(v1));
        factory.register(2, address(v2));
        taker = new FluidTakerModule(address(permit3), address(factory), address(0xE7E7));
        vm.label(address(preFund), "preFund");
        vm.label(address(taker), "fluidTaker");

        tB.mint(address(preFund), RESIDUE);
        aliceV1 = _seed(v1, maker, 10e18, 0);
        bobV2 = _seed(v2, bob, 100e18, DEBT_B);
    }

    // ──────────────────── builders ────────────────────

    /// @dev Open a position directly on the vault (no modules involved).
    function _seed(NettedFluidVault v, address who, uint256 c, uint256 d) internal returns (uint256 id) {
        MockERC20 s = v.supplyToken();
        s.mint(who, c);
        vm.startPrank(who);
        s.approve(address(v), c);
        (id,,) = v.operate(0, int256(c), int256(d), who);
        // The borrowed tokens are not part of any wallet under test.
        MockERC20(address(v.borrowToken())).transfer(address(0xdead), d);
        vm.stopPrank();
    }

    function _approveAs(address who, address token) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
        vm.stopPrank();
    }

    function _desc(uint256 op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (op << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _pfData(uint256 op, NettedFluidVault v, address token, uint256 nftId) internal pure returns (bytes memory) {
        return abi.encode(_desc(op, token, 0), address(v), token, nftId);
    }

    /// @dev `who` pays `amtIn` tA from the wallet for `amtOut` tB delivered to the
    ///      module, consumed by one pre-funded MAKE item carrying `data`.
    function _walletOrder(address who, uint256 amtIn, uint256 amtOut, bytes memory data)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(1);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(tA), amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tB), amtOut, 0, address(preFund));
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(preFund), amount: 0, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    /// @dev A position order: `tokIn` produced by a {FluidTakerModule} TAKE (op
    ///      `takeOp` on `v`), `tokOut` delivered to the module and consumed by the
    ///      pre-fund MAKE (op `makeOp`). The maker's grants are the value-OUT ones only:
    ///      the taker allowance and the factory operator grant for JIT custody.
    function _positionOrder(
        NettedFluidVault v,
        uint256 nftId,
        uint8 takeOp,
        uint256 makeOp,
        address tokIn,
        uint256 amtIn,
        address tokOut,
        uint256 amtOut
    ) internal returns (Order memory o) {
        bytes memory takeData = abi.encode(takeOp, address(v), address(factory), nftId);
        o = _blank(1);
        o.legsIn = PackedEncode.oneLegIn(tokIn, amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(tokOut, amtOut, 0, address(preFund));
        Item[] memory items = new Item[](2);
        items[0] = Item({op: ItemOp.TAKE, module: address(taker), amount: amtIn, recipient: address(0), data: takeData});
        items[1] = Item({
            op: ItemOp.MAKE, module: address(preFund), amount: 0, recipient: address(0), data: _pfData(makeOp, v, tokOut, nftId)
        });
        o.items = PackedEncode.items(items);
        vm.startPrank(maker);
        permit3.approveTaker(address(settlement), address(taker), keccak256(takeData), type(uint160).max, 0);
        factory.setApprovalForAll(address(taker), true);
        vm.stopPrank();
    }

    function _carol(address tokIn, uint256 amtIn, address tokOut, uint256 amtOut) internal returns (Order memory o) {
        MockERC20(tokIn).mint(carol, amtIn);
        _approveAs(carol, tokIn);
        o = _blank(1);
        o.maker = carol;
        o.legsIn = PackedEncode.oneLegIn(tokIn, amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(tokOut, amtOut, 0, address(0));
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
    }

    function _plan(Order[] memory orders, uint256[] memory pks, uint256[] memory fills, uint256[] memory s)
        internal
        view
        returns (MatchPlan memory)
    {
        bytes[] memory sigs = new bytes[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            sigs[i] = _signWith(orders[i], pks[i]);
        }
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
    }

    function _two(Order memory a, Order memory b) internal pure returns (Order[] memory o) {
        o = new Order[](2);
        o[0] = a;
        o[1] = b;
    }

    function _three(Order memory a, Order memory b, Order memory c) internal pure returns (Order[] memory o) {
        o = new Order[](3);
        o[0] = a;
        o[1] = b;
        o[2] = c;
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        x[0] = a;
        x[1] = b;
    }

    function _u3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        x[0] = a;
        x[1] = b;
        x[2] = c;
    }

    function _withMiddle(uint256[] memory mid) internal pure returns (uint256[] memory s) {
        s = new uint256[](mid.length + 4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        for (uint256 i; i < mid.length; i++) {
            s[3 + i] = mid[i];
        }
        s[s.length - 1] = _step(MatchStep.DELIVER, 2, 0);
    }

    /// @dev The acyclic position schedule: ITEM take (early) → PULL maker (nets to
    ///      nothing: the take credited the leg) → PULL carol → DELIVER maker (to the
    ///      module) → ITEM make (late) → DELIVER carol (paid from the take).
    function _acyclic() internal pure returns (uint256[] memory s) {
        s = new uint256[](6);
        s[0] = _step(MatchStep.ITEM, 0, 0);
        s[1] = _step(MatchStep.PULL, 0, 0);
        s[2] = _step(MatchStep.PULL, 1, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.ITEM, 0, 1);
        s[5] = _step(MatchStep.DELIVER, 1, 0);
    }

    /// @dev Alice (Deposit into v1) + Bob (RepayAll on v2) + Carol (sells tB for tA).
    ///      Both pre-fund items spend tB on the ONE singleton.
    function _fundDepositRepayAll() internal returns (Order[] memory orders) {
        tA.mint(maker, IN_A);
        tA.mint(bob, IN_B);
        _approveAs(maker, address(tA));
        _approveAs(bob, address(tA));
        orders = _three(
            _walletOrder(maker, IN_A, OUT_A, _pfData(0, v1, address(tB), aliceV1)),
            _walletOrder(bob, IN_B, OUT_B, _pfData(2, v2, address(tB), bobV2)),
            _carol(address(tB), OUT_A + OUT_B, address(tA), IN_A + IN_B)
        );
    }

    // ──────────────────── part 1: shared-singleton interleaving ────────────────────

    /// DELIVER A, DELIVER B, ITEM B (RepayAll: consumes 5 of 7), ITEM A (deposit 13).
    /// When ITEM B sweeps, the module holds residue + A's 13 + B's 7; the floor is
    /// `residue + 13`, so the sweep returns exactly B's unconsumed 2 — to bob — and A's
    /// delivery is intact for ITEM A.
    function test_netted_interleaved_sweepReturnsOnlyOwnSurplus() public {
        Order[] memory orders = _fundDepositRepayAll();
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 1, 0);
        mid[3] = _step(MatchStep.ITEM, 0, 0);
        MatchPlan memory p =
            _plan(orders, _u3(makerPk, bobPk, carolPk), _u3(IN_A, IN_B, OUT_A + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(v1.col(aliceV1), 10e18 + OUT_A, "alice deposited exactly her delivery");
        assertEq(v2.debt(bobV2), 0, "bob's RepayAll retired the whole live debt");
        assertEq(tB.balanceOf(bob), OUT_B - DEBT_B, "bob got back exactly his unconsumed slice");
        assertEq(tB.balanceOf(maker), 0, "alice received no sweep of anyone's tB");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
        assertEq(tA.balanceOf(carol), IN_A + IN_B, "carol paid");
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver), 0, "zero solver capital, zero take");
        assertEq(tB.balanceOf(address(settlement)), 0, "nothing pooled");
    }

    /// The opposite interleaving gives the same per-maker outcome.
    function test_netted_interleaved_reverseOrder_sameOutcome() public {
        Order[] memory orders = _fundDepositRepayAll();
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0);
        mid[1] = _step(MatchStep.DELIVER, 0, 0);
        mid[2] = _step(MatchStep.ITEM, 0, 0);
        mid[3] = _step(MatchStep.ITEM, 1, 0);
        MatchPlan memory p =
            _plan(orders, _u3(makerPk, bobPk, carolPk), _u3(IN_A, IN_B, OUT_A + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(v1.col(aliceV1), 10e18 + OUT_A, "alice deposited exactly her delivery");
        assertEq(v2.debt(bobV2), 0, "bob's debt retired");
        assertEq(tB.balanceOf(bob), OUT_B - DEBT_B, "bob's own surplus");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
    }

    /// ITEM A scheduled before DELIVER A while B's delivery (and residue) sit on the
    /// module — enough balance for A's floor NOT to underflow. The core ledger refuses
    /// it ({Base.ForLegInvalid}).
    function test_netted_itemBeforeOwnDelivery_failsClosed() public {
        Order[] memory orders = _fundDepositRepayAll();
        orders[0] = _walletOrder(maker, IN_A, 2e18, _pfData(0, v1, address(tB), aliceV1));
        orders[2] = _carol(address(tB), 2e18 + OUT_B, address(tA), IN_A + IN_B);
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0); // bob's 7 parks; with residue that's 10 ≥ 2
        mid[1] = _step(MatchStep.ITEM, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 0, 0); // alice's item before alice's delivery
        mid[3] = _step(MatchStep.DELIVER, 0, 0);
        MatchPlan memory p =
            _plan(orders, _u3(makerPk, bobPk, carolPk), _u3(IN_A, IN_B, 2e18 + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    /// A hostile maker's RepayAll names a position whose debt EXCEEDS her own delivery,
    /// while Bob's delivery is parked on the same singleton. RepayAll's ceiling is the
    /// scoped `forAmount` approval, so the vault cannot draw Bob's tokens to cover her
    /// debt: the plan reverts, and nothing moves.
    function test_netted_hostileRepayAll_aboveOwnDelivery_cannotDrawParkedDelivery() public {
        uint256 malloryV2 = _seed(v2, mallory, 100e18, 50e18); // debt 50 ≫ her delivery
        uint256 outM = 1e18;
        tA.mint(mallory, 1);
        tA.mint(bob, IN_B);
        _approveAs(mallory, address(tA));
        _approveAs(bob, address(tA));
        Order memory m = _walletOrder(mallory, 1, outM, _pfData(2, v2, address(tB), malloryV2));
        Order memory b = _walletOrder(bob, IN_B, OUT_B, _pfData(2, v2, address(tB), bobV2));
        Order memory c = _carol(address(tB), outM + OUT_B, address(tA), IN_B + 1);

        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0); // bob's 7 parks first
        mid[1] = _step(MatchStep.DELIVER, 0, 0); // mallory's 1
        mid[2] = _step(MatchStep.ITEM, 0, 0); //    mallory's RepayAll of 50 against a ceiling of 1
        mid[3] = _step(MatchStep.ITEM, 1, 0);
        MatchPlan memory p =
            _plan(_three(m, b, c), _u3(malloryPk, bobPk, carolPk), _u3(1, IN_B, outM + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        vm.expectRevert(stdError.arithmeticError); // the scoped allowance underflows inside the vault's pull
        settlement.matchSettle(p);
        assertEq(v2.debt(malloryV2), 50e18, "mallory's debt untouched");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton untouched");
    }

    // ──────────────────── part 2: the acyclic position shapes ────────────────────

    /// Acyclic OPEN on alice's v1 position (10 tB collateral, no debt): borrow 5 tA
    /// early against the existing collateral, Carol converts, 4 tB delivered to the
    /// module, Deposit late. Zero wallet, zero solver capital, zero receive-side grant.
    function test_netted_acyclicOpen_borrowEarly_depositLate_zeroCapital() public {
        uint256 borrowAmt = 5e18;
        uint256 colAdd = 4e18;
        Order memory m = _positionOrder(v1, aliceV1, 0, 0, address(tA), borrowAmt, address(tB), colAdd);
        Order memory c = _carol(address(tB), colAdd, address(tA), borrowAmt);
        MatchPlan memory p = _plan(_two(m, c), _u2(makerPk, carolPk), _u2(borrowAmt, colAdd), _acyclic());

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(v1.col(aliceV1), 10e18 + colAdd, "delivered collateral supplied");
        assertEq(v1.debt(aliceV1), borrowAmt, "borrow drawn");
        assertEq(tA.balanceOf(carol), borrowAmt, "carol paid from the borrow");
        assertEq(tA.balanceOf(maker) + tB.balanceOf(maker), 0, "maker wallet untouched");
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver), 0, "zero solver capital");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
        assertEq(factory.ownerOf(aliceV1), maker, "NFT back with the maker");
        (uint160 a,) = permit3.tokenAllowance(maker, address(preFund), address(tB));
        assertEq(a, 0, "no receive-side allowance");
    }

    /// Acyclic FULL CLOSE (review 2026-10-18 M-3) on a v2 position (100 tA collateral,
    /// 40 tB debt + 2 accrued): withdraw 50 tA early (headroom), Carol converts, 45 tB
    /// delivered to the module, RepayAll late — the vault takes exactly the live 42, the
    /// 3 over is swept to the maker, the debt is zero.
    function test_netted_acyclicFullClose_withdrawEarly_repayAllLate_zeroCapital() public {
        uint256 id = _seed(v2, maker, 100e18, 40e18);
        v2.accrue(id, 2e18);
        uint256 colOut = 50e18;
        uint256 debtIn = 45e18;
        Order memory m = _positionOrder(v2, id, 1, 2, address(tA), colOut, address(tB), debtIn);
        Order memory c = _carol(address(tB), debtIn, address(tA), colOut);
        MatchPlan memory p = _plan(_two(m, c), _u2(makerPk, carolPk), _u2(colOut, debtIn), _acyclic());

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(v2.debt(id), 0, "debt fully retired, accrual included");
        assertEq(v2.col(id), 100e18 - colOut, "the rest of the collateral stays, debt-free");
        assertEq(tB.balanceOf(maker), debtIn - 42e18, "repay remainder swept to the maker");
        assertEq(tA.balanceOf(carol), colOut, "carol paid from the withdrawal");
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver), 0, "zero solver capital");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
        assertEq(factory.ownerOf(id), maker, "NFT back with the maker");
    }

    /// Partial deleverage with the EXACT op: withdraw 20 early, repay exactly the 15
    /// delivered late. The debt drops by the delivery; nothing is swept.
    function test_netted_acyclicDeleverage_exactRepay() public {
        uint256 id = _seed(v2, maker, 100e18, 40e18);
        Order memory m = _positionOrder(v2, id, 1, 1, address(tA), 20e18, address(tB), 15e18);
        Order memory c = _carol(address(tB), 15e18, address(tA), 20e18);
        MatchPlan memory p = _plan(_two(m, c), _u2(makerPk, carolPk), _u2(20e18, 15e18), _acyclic());

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(v2.debt(id), 25e18, "debt down by exactly the delivery");
        assertEq(tB.balanceOf(maker), 0, "nothing to sweep");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
    }

    /// The close at the LTV edge is a true CYCLE: the withdraw cannot precede the
    /// repay (the position falls below its collateral factor), so the acyclic plan
    /// reverts. That remainder belongs to the flash family / the fused Close.
    function test_netted_closeAtTheLtvEdge_isACycle_reverts() public {
        uint256 id = _seed(v2, maker, 50e18, 40e18); // 80% LTV, CF 90%
        Order memory m = _positionOrder(v2, id, 1, 2, address(tA), 20e18, address(tB), 45e18);
        Order memory c = _carol(address(tB), 45e18, address(tA), 20e18);
        MatchPlan memory p = _plan(_two(m, c), _u2(makerPk, carolPk), _u2(20e18, 45e18), _acyclic());

        vm.prank(solver);
        vm.expectRevert(NettedFluidVault.PositionAboveCF.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── unit: the door ────────────────────

    function test_unit_onlySettlement() public {
        bytes memory data = _pfData(0, v1, address(tB), aliceV1);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_unit_unknownOp_reverts() public {
        bytes memory data = _pfData(3, v1, address(tB), aliceV1);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(FluidPreFundModule.BadOp.selector, 3));
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_unit_freshPosition_reverts() public {
        bytes memory data = _pfData(0, v1, address(tB), 0);
        vm.prank(address(settlement));
        vm.expectRevert(FluidPreFundModule.FreshPositionUnsupported.selector);
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_unit_pullDescriptor_refused() public {
        // Leg reference WITHOUT the pre-fund bit (the PULL form): `>> 253 == 4`.
        bytes memory data = abi.encode((uint256(1) << 255) | (uint256(uint160(address(tB))) << 16), address(v1), address(tB), aliceV1);
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_unit_tokenOtherThanDescriptor_refused() public {
        // Descriptor names tA, the blob spends tB.
        bytes memory data = abi.encode(_desc(0, address(tA), 0), address(v1), address(tB), aliceV1);
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.FundingTokenMismatch.selector);
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_unit_repayAgainstTheSupplySide_refused() public {
        // RepayAll on v1 names tB, v1's SUPPLY token — the debt side is tA.
        bytes memory data = _pfData(2, v1, address(tB), aliceV1);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(FluidPreFundModule.WrongVaultToken.selector, address(tB), address(tA)));
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_unit_zeroForAmount_isANoOp() public {
        bytes memory data = _pfData(0, v1, address(tB), aliceV1);
        vm.prank(address(settlement));
        preFund.makeOnBehalf(maker, 0, data);
        assertEq(v1.col(aliceV1), 10e18, "nothing supplied");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "residue untouched");
    }

    function test_unit_fundingSource_reportsTheDeliveredToken() public view {
        (address asset, uint256 avail) = preFund.fundingSource(maker, _pfData(2, v2, address(tB), bobV2));
        assertEq(asset, address(tB));
        assertEq(avail, type(uint256).max);
    }
}
