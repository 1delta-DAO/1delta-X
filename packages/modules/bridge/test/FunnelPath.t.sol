// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";

import {AcrossBridgeOutModule} from "../src/out/AcrossBridgeOutModule.sol";
import {LzOftBridgeOutModule} from "../src/out/LzOftBridgeOutModule.sol";
import {PositionFunnel} from "../src/funnel/PositionFunnel.sol";
import {PositionFunnelFactory} from "../src/funnel/PositionFunnelFactory.sol";
import {FunnelGrantModule} from "../src/funnel/FunnelGrantModule.sol";
import {MockSpokePool, MockOFT} from "./shared/Mocks.t.sol";
import {MockLendingPool, MockSupplyModule, MockBorrowModule} from "./shared/LendingMocks.t.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title FunnelPathTest
/// @notice The full product: a source order that swaps and bridges, then a
///         DESTINATION order — swap or leverage — filled against the user's own
///         funnel, over both bridge families.
///
///         What separates this from the {BridgedOrderInbox} path:
///           • the destination order carries ITEMS, so it can open a position;
///           • that position belongs to the funnel, which belongs to the user —
///             not to a pooled escrow;
///           • the bridge carries NO message (`dstOrderHash == 0`), because the
///             order is normally signed and validated through the funnel's
///             EIP-1271. On LayerZero that means no `lzCompose` at all;
///           • the user sends ZERO transactions on the destination chain. Two
///             off-chain signatures — the order, and one `executeSigned` batch for
///             the grants a borrow needs — are the whole of their involvement.
contract FunnelPathTest is BridgeTestBase {
    PositionFunnelFactory factory;
    FunnelGrantModule grantModule;
    PositionFunnel funnel;

    MockLendingPool pool;
    MockSupplyModule supplyModule;
    MockBorrowModule borrowModule;

    bytes32 constant USER_SALT = bytes32(uint256(1));

    // Source leg: the maker pays tC and the solver delivers tA, which gets bridged.
    uint256 constant PAY = 500e18;
    uint256 constant BRIDGE = 100e18;
    uint16 constant RELAY_FEE_BPS = 100;
    uint256 constant DELIVERED = BRIDGE - (BRIDGE * RELAY_FEE_BPS) / 10_000; // 99e18 lands

    // Destination leverage: user brings the bridged 99 tA, solver adds 198 tA,
    // position ends at 297 tA collateral against 600 tB of debt — roughly 3x.
    uint256 constant SOLVER_COLL = 198e18;
    uint256 constant TOTAL_COLL = DELIVERED + SOLVER_COLL;
    uint256 constant BORROW = 600e18;

    function setUp() public virtual override {
        super.setUp();
        grantModule = new FunnelGrantModule(address(settlement));
        factory = new PositionFunnelFactory(address(permit3), address(settlement), address(lens), address(grantModule));
        funnel = PositionFunnel(payable(factory.funnelFor(maker, USER_SALT)));
        vm.label(address(funnel), "funnel");

        pool = new MockLendingPool(address(tA), address(tB));
        supplyModule = new MockSupplyModule(address(permit3), address(settlement), pool);
        borrowModule = new MockBorrowModule(address(permit3), pool);
    }

    // ──────────────────── Builders ────────────────────

    function _acrossSpec() internal view returns (bytes memory) {
        return abi.encode(
            AcrossBridgeOutModule.AcrossSpec({
                inputToken: address(tA),
                outputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstRecipient: address(funnel), // straight to the user's own account
                exclusiveRelayer: address(0),
                maxRelayFeeBps: RELAY_FEE_BPS,
                fillDeadlineOffset: 2 hours,
                exclusivityOffset: 0,
                dstOrderHash: bytes32(0), // no commitment — the order is owner-signed
                beneficiary: address(0),
                commitmentExpiry: 0
            })
        );
    }

    function _lzSpec() internal view returns (bytes memory) {
        return abi.encode(
            LzOftBridgeOutModule.LzSpec({
                oft: address(oft),
                inputToken: address(tA),
                dstEid: 30_101,
                dstChainId: DST_CHAIN,
                dstRecipient: address(funnel),
                maxSlippageBps: RELAY_FEE_BPS,
                maxNativeFee: 0.05 ether,
                feePayer: maker,
                extraOptions: hex"0003",
                dstOrderHash: bytes32(0),
                beneficiary: address(0),
                commitmentExpiry: 0
            })
        );
    }

    /// @dev Destination LEVERAGE order. Mirrors the real lender-module shape:
    ///        legsOut — solver delivers its share of the collateral to the maker
    ///        items[0] MAKE  — supply the whole collateral stack (bridged + solver)
    ///        items[1] TAKE  — borrow against it, proceeds to Settlement
    ///        legsIn  — the borrow proceeds pay the solver
    ///      The maker is the funnel, so the position lands there.
    function _leverageOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.maker = address(funnel);
        o.legsIn = _legsIn1(address(tB), BORROW);
        LegOut[] memory _tmplegsOut = new LegOut[](1);
        _tmplegsOut[0] = LegOut(address(tA), SOLVER_COLL, 0, address(0)); // 0 == the maker (funnel)
        o.legsOut = PackedEncode.legsOut(_tmplegsOut);
        Item[] memory _tmpitems = new Item[](2);
        _tmpitems[0] =
            Item({op: ItemOp.MAKE, module: address(supplyModule), amount: TOTAL_COLL, recipient: address(0), data: ""});
        _tmpitems[1] =
            Item({op: ItemOp.TAKE, module: address(borrowModule), amount: BORROW, recipient: address(0), data: ""});
        o.items = PackedEncode.items(_tmpitems);
    }

    /// @dev Destination SWAP order — the same funnel hosting the simple case.
    function _swapOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.maker = address(funnel);
        o.legsIn = _legsIn1(address(tA), DELIVERED);
        LegOut[] memory _tmplegsOut = new LegOut[](1);
        _tmplegsOut[0] = LegOut(address(tB), 300e18, 0, endUser);
        o.legsOut = PackedEncode.legsOut(_tmplegsOut);
    }

    // ──────────────────── executeSigned ────────────────────

    bytes32 constant CALL_TH = keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 constant EXEC_TH = keccak256(
        "ExecuteBatch(Call[] calls,uint256 nonce,uint256 deadline)Call(address target,uint256 value,bytes data)"
    );

    function _signExec(PositionFunnel.Call[] memory calls, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32[] memory h = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            h[i] = keccak256(abi.encode(CALL_TH, calls[i].target, calls[i].value, keccak256(calls[i].data)));
        }
        bytes32 structHash = keccak256(abi.encode(EXEC_TH, keccak256(abi.encodePacked(h)), nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", funnel.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The one signed batch a leverage order needs. Three grants, each a
    ///      different authority, none of which a bridged user has on this chain:
    ///
    ///        [0] Permit3 TOKEN allowance to the MAKE module. `enableToken` only
    ///            covers Settlement, which is what pulls `legsIn`; a maker module
    ///            pulls its funding itself and so needs its own capped allowance.
    ///        [1] Permit3 TAKER allowance for the TAKE leg, keyed by
    ///            `(funnel, Settlement, keccak256(item.data))`.
    ///        [2] the lender's own borrow delegation — the protocol-level grant
    ///            that supply does not need but borrow does.
    ///
    ///      All three are relayed by the solver; the user only signs.
    function _grantsForLeverage(Order memory o) internal view returns (PositionFunnel.Call[] memory calls) {
        calls = new PositionFunnel.Call[](3);
        calls[0] = PositionFunnel.Call({
            target: address(permit3),
            value: 0,
            data: abi.encodeCall(
                IPermit3.approveToken, (address(supplyModule), address(tA), uint160(TOTAL_COLL), uint48(0))
            )
        });
        calls[1] = PositionFunnel.Call({
            target: address(permit3),
            value: 0,
            data: abi.encodeCall(
                IPermit3.approveTaker,
                (address(settlement), keccak256(PackedEncode.getItemData(o.items, 1)), uint160(BORROW), uint48(0))
            )
        });
        calls[2] = PositionFunnel.Call({
            target: address(pool),
            value: 0,
            data: abi.encodeCall(MockLendingPool.approveDelegate, (address(borrowModule)))
        });
    }

    // ──────────────────── Source leg ────────────────────

    function _fillSourceAcross() internal onSourceChain {
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(acrossOut), _acrossSpec());
        _wireSourceParties(address(acrossOut), PAY, BRIDGE);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        settlement.fill(src, sig, PAY);
    }

    function _fillSourceLz() internal onSourceChain {
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(lzOut), _lzSpec());
        _wireSourceParties(address(lzOut), PAY, BRIDGE);
        vm.deal(maker, 1 ether);
        vm.prank(maker);
        lzOut.topUpFor{value: 0.1 ether}(maker);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        settlement.fill(src, sig, PAY);
    }

    // ──────────────────── End to end: Across + leverage ────────────────────

    function test_across_swapBridge_thenDestinationLeverage() public {
        Order memory dst = _leverageOrder(1);
        bytes memory dstSig = _signWith(dst, makerPk); // user signs; funnel's 1271 validates

        _fillSourceAcross();

        MockSpokePool.Deposit memory d = spokePool.depositAt(0);
        assertEq(d.recipient, address(funnel), "bridged straight to the user's funnel");
        assertEq(d.message.length, 0, "no commitment needed on the funnel path");

        spokePool.relay(0);
        assertEq(tA.balanceOf(address(funnel)), DELIVERED, "funds waiting at the funnel");

        // Everything below is done by the SOLVER. The user has sent no transaction.
        vm.startPrank(solver);
        address[] memory toks = new address[](1);
        toks[0] = address(tA);
        factory.deployAndEnable(maker, USER_SALT, toks);
        PositionFunnel.Call[] memory grants = _grantsForLeverage(dst);
        funnel.executeSigned(grants, 1, block.timestamp + 1 days, _signExec(grants, 1, block.timestamp + 1 days));

        tA.mint(solver, SOLVER_COLL);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), type(uint160).max, 0);
        settlement.fill(dst, dstSig, BORROW);
        vm.stopPrank();

        assertEq(pool.collateralOf(address(funnel)), TOTAL_COLL, "levered collateral, owned by the funnel");
        assertEq(pool.debtOf(address(funnel)), BORROW, "debt on the funnel");
        assertEq(tB.balanceOf(solver), BORROW, "solver paid out of the borrow proceeds");
        assertEq(tA.balanceOf(address(funnel)), 0, "bridged funds fully deployed");
        assertEq(funnel.owner(), maker, "and the funnel is the user's");
    }

    // ──────────────────── End to end: LayerZero + leverage ────────────────────

    /// @dev Same flow over the OFT/Stargate path. Note there is no `lzCompose`
    ///      anywhere — the send carries no `composeMsg`, so the split-arrival
    ///      orphan risk simply does not exist on this route.
    function test_lz_swapBridge_thenDestinationLeverage() public {
        Order memory dst = _leverageOrder(1);
        bytes memory dstSig = _signWith(dst, makerPk);

        _fillSourceLz();

        MockOFT.Sent memory s = oft.sentAt(0);
        assertEq(s.to, bytes32(uint256(uint160(address(funnel)))), "addressed to the funnel");
        assertEq(s.composeMsg.length, 0, "no compose message, nothing to orphan");

        oft.deliverTokens(0, DELIVERED); // the lzReceive leg is the whole delivery
        assertEq(tA.balanceOf(address(funnel)), DELIVERED, "funds waiting at the funnel");

        vm.startPrank(solver);
        address[] memory toks = new address[](1);
        toks[0] = address(tA);
        factory.deployAndEnable(maker, USER_SALT, toks);
        PositionFunnel.Call[] memory grants = _grantsForLeverage(dst);
        funnel.executeSigned(grants, 1, block.timestamp + 1 days, _signExec(grants, 1, block.timestamp + 1 days));

        tA.mint(solver, SOLVER_COLL);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), type(uint160).max, 0);
        settlement.fill(dst, dstSig, BORROW);
        vm.stopPrank();

        assertEq(pool.collateralOf(address(funnel)), TOTAL_COLL, "position opened");
        assertEq(pool.debtOf(address(funnel)), BORROW, "debt on the funnel");
    }

    // ──────────────────── Destination swap on the same funnel ────────────────────

    function test_across_destinationSwap() public {
        Order memory dst = _swapOrder(1);
        bytes memory dstSig = _signWith(dst, makerPk);

        _fillSourceAcross();
        spokePool.relay(0);

        address[] memory toks = new address[](1);
        toks[0] = address(tA);
        factory.deployAndEnable(maker, USER_SALT, toks);

        _fundSolverOut(300e18);
        vm.prank(solver);
        settlement.fill(dst, dstSig, DELIVERED);

        assertEq(tB.balanceOf(endUser), 300e18, "end user paid out");
        assertEq(tA.balanceOf(solver), DELIVERED, "solver took the bridged input");
    }

    // ──────────────────── Counterfactual delivery ────────────────────

    /// @dev Funds may land at a funnel that has no code yet — an address holds
    ///      ERC20 balances fine. The clone is deployed later by whoever fills.
    function test_fundsArriveBeforeTheFunnelExists() public {
        assertEq(address(funnel).code.length, 0, "not deployed yet");
        _fillSourceAcross();
        spokePool.relay(0);
        assertEq(tA.balanceOf(address(funnel)), DELIVERED, "held at a codeless address");

        address deployed = factory.deploy(maker, USER_SALT);
        assertEq(deployed, address(funnel), "predicted address matches");
        assertEq(funnel.owner(), maker, "initialised to the right owner");
        assertEq(tA.balanceOf(address(funnel)), DELIVERED, "funds intact through deployment");
    }

    function test_deploy_isIdempotent() public {
        address a = factory.deploy(maker, USER_SALT);
        address b = factory.deploy(maker, USER_SALT);
        assertEq(a, b, "second deploy is a no-op");
    }

    /// @dev Pins the address derivation an off-chain implementation must
    ///      reproduce: `CREATE2(factory, keccak256(owner, userSalt), initCodeHash)`.
    ///      Funds are bridged to counterfactual funnels, so an SDK that derives
    ///      this differently sends them somewhere unreachable — this is the check
    ///      that a published registry entry can be validated against.
    function test_addressDerivationIsReproducible() public view {
        bytes32 salt = factory.saltFor(maker, USER_SALT);
        assertEq(salt, keccak256(abi.encode(maker, USER_SALT)), "salt formula");

        address expected = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, factory.initCodeHashFor(maker)))
                )
            )
        );
        assertEq(factory.funnelFor(maker, USER_SALT), expected, "plain CREATE2 over the published inputs");
    }

    /// @dev The init code contains the owner, so the hash is owner-dependent. A
    ///      registry that published one hash for all users would be wrong.
    function test_initCodeHashIsPerOwner() public view {
        assertTrue(factory.initCodeHashFor(maker) != factory.initCodeHashFor(solver), "owner is inside the init code");
    }

    /// @dev The salt commits to the owner, so a funnel address can only ever
    ///      belong to the user it was derived for.
    function test_funnelAddressIsBoundToItsOwner() public view {
        assertTrue(factory.funnelFor(maker, USER_SALT) != factory.funnelFor(solver, USER_SALT), "per-owner");
        assertTrue(factory.funnelFor(maker, USER_SALT) != factory.funnelFor(maker, bytes32(uint256(2))), "per-salt");
    }

    // ──────────────────── Ownership / authorisation guards ────────────────────

    /// @dev There is no `initialize` to front-run: the owner is baked into the
    ///      clone's code, so a funnel is owned from the instant it exists.
    function test_ownerIsSetFromDeployment() public {
        factory.deploy(maker, USER_SALT);
        assertEq(funnel.owner(), maker, "owned immediately, no init step");
    }

    /// @dev The proxy is hand-assembled, so pin its exact shape: 61 bytes of
    ///      runtime plus the 20-byte immutable argument, with the implementation
    ///      at offset 0x18 and the owner as the trailing word. A shifted or
    ///      mis-sized constant in the factory silently produces a proxy that
    ///      "deploys" but misbehaves, which is precisely what this catches.
    function test_cloneRuntimeCodeIsExactlyAsSpecified() public {
        factory.deploy(maker, USER_SALT);
        bytes memory code = address(funnel).code;

        assertEq(code.length, 81, "61 runtime bytes + 20 argument bytes");

        address impl = factory.IMPLEMENTATION();
        bytes20 embeddedImpl;
        bytes20 embeddedOwner;
        for (uint256 i; i < 20; i++) {
            embeddedImpl |= bytes20(code[0x18 + i]) >> (8 * i);
            embeddedOwner |= bytes20(code[61 + i]) >> (8 * i);
        }
        assertEq(address(embeddedImpl), impl, "delegatecall target");
        assertEq(address(embeddedOwner), maker, "owner as the immutable argument");

        // The empty-calldata short circuit and both jump destinations.
        assertEq(uint8(code[0x00]), 0x36, "CALLDATASIZE");
        assertEq(uint8(code[0x01]), 0x15, "ISZERO");
        assertEq(uint8(code[0x03]), 0x3b, "stop JUMPDEST target");
        assertEq(uint8(code[0x39]), 0x5b, "success JUMPDEST");
        assertEq(uint8(code[0x3b]), 0x5b, "stop JUMPDEST");
        assertEq(uint8(code[0x3c]), 0x00, "STOP");
    }

    /// @dev Records the cost of a funnel. The immutable-argument clone pays ~5.8k
    ///      more in code deposit than a bare EIP-1167 proxy but skips the
    ///      `initialize` call and its cold SSTORE (~23k), so it lands well under
    ///      what the storage-owner design cost.
    function test_deploymentCost() public {
        uint256 before = gasleft();
        factory.deploy(maker, USER_SALT);
        uint256 used = before - gasleft();
        emit log_named_uint("funnel deploy gas", used);
        // ~60k measured. The storage-owner variant this replaced cost ~21k more.
        assertLt(used, 70_000, "one CREATE2, no initialize");
    }

    /// @dev Called directly, the implementation reads `owner()` from whatever the
    ///      caller appended to calldata — so every state-changing entry point must
    ///      refuse to run outside a clone.
    function test_implementation_cannotBeUsedDirectly() public {
        PositionFunnel impl = PositionFunnel(payable(factory.IMPLEMENTATION()));
        vm.expectRevert(PositionFunnel.NotProxy.selector);
        impl.enableToken(address(tA));

        PositionFunnel.Call[] memory calls = new PositionFunnel.Call[](0);
        vm.expectRevert(PositionFunnel.NotProxy.selector);
        impl.execute(calls);
    }

    /// @dev Ether must arrive by ANY means. The proxy terminates on empty calldata
    ///      before it delegatecalls, so a transfer never reaches the
    ///      implementation's dispatcher — which is what makes `transfer`/`send`
    ///      viable (the path costs ~19 gas, well inside the 2300 stipend) and
    ///      removes any chance of a value transfer being read as a selector.
    function test_receivesEtherByEveryMeans() public {
        factory.deploy(maker, USER_SALT);
        vm.deal(solver, 10 ether);

        vm.startPrank(solver);
        (bool ok,) = address(funnel).call{value: 1 ether}("");
        assertTrue(ok, "call with empty calldata");

        payable(address(funnel)).transfer(1 ether); // 2300-gas stipend
        assertTrue(payable(address(funnel)).send(1 ether), "send");
        vm.stopPrank();

        assertEq(address(funnel).balance, 3 ether, "every route credited");
    }

    /// @dev The 2300-gas stipend explicitly, so a regression in the proxy prologue
    ///      that pushed the transfer path through the delegatecall would be caught.
    function test_receivesEtherUnderTheStipend() public {
        factory.deploy(maker, USER_SALT);
        vm.deal(solver, 1 ether);
        vm.prank(solver);
        (bool ok,) = address(funnel).call{value: 1 ether, gas: 2300}("");
        assertTrue(ok, "accepted within the transfer stipend");
    }

    function test_unknownSelectorStillReverts() public {
        factory.deploy(maker, USER_SALT);
        vm.prank(solver);
        (bool ok,) = address(funnel).call(abi.encodeWithSignature("nonexistentFunction()"));
        assertFalse(ok, "unmatched selector fails loudly");
    }

    /// @dev Ether the funnel holds is the owner's, withdrawable like any other asset.
    function test_withdrawNative() public {
        factory.deploy(maker, USER_SALT);
        vm.deal(solver, 1 ether);
        vm.prank(solver);
        (bool ok,) = address(funnel).call{value: 1 ether}("");
        assertTrue(ok);

        uint256 before = maker.balance;
        vm.prank(maker);
        funnel.withdrawNative(1 ether, maker);
        assertEq(maker.balance - before, 1 ether, "owner reclaims it");
    }

    /// @dev An order signed by anyone but the owner must not validate, or the
    ///      funnel would be drainable by whoever crafts an order naming it.
    function test_orderSignedByStranger_isRejected() public {
        Order memory dst = _swapOrder(1);
        bytes memory badSig = _signWith(dst, solverPk);

        _fillSourceAcross();
        spokePool.relay(0);
        address[] memory toks = new address[](1);
        toks[0] = address(tA);
        factory.deployAndEnable(maker, USER_SALT, toks);
        _fundSolverOut(300e18);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(dst, badSig, DELIVERED);
    }

    function test_executeSigned_rejectsStrangerSignature() public {
        factory.deploy(maker, USER_SALT);
        PositionFunnel.Call[] memory calls = new PositionFunnel.Call[](1);
        calls[0] = PositionFunnel.Call({
            target: address(pool),
            value: 0,
            data: abi.encodeCall(MockLendingPool.approveDelegate, (address(borrowModule)))
        });

        bytes32 structHash = keccak256(
            abi.encode(
                EXEC_TH,
                keccak256(
                    abi.encodePacked(
                        keccak256(abi.encode(CALL_TH, calls[0].target, calls[0].value, keccak256(calls[0].data)))
                    )
                ),
                uint256(1),
                block.timestamp + 1 days
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", funnel.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(solverPk, digest);

        vm.expectRevert(PositionFunnel.BadSignature.selector);
        funnel.executeSigned(calls, 1, block.timestamp + 1 days, abi.encodePacked(r, s, v));
    }

    function test_executeSigned_nonceIsSingleUse() public {
        factory.deploy(maker, USER_SALT);
        PositionFunnel.Call[] memory calls = new PositionFunnel.Call[](1);
        calls[0] = PositionFunnel.Call({
            target: address(pool),
            value: 0,
            data: abi.encodeCall(MockLendingPool.approveDelegate, (address(borrowModule)))
        });
        bytes memory sig = _signExec(calls, 7, block.timestamp + 1 days);

        funnel.executeSigned(calls, 7, block.timestamp + 1 days, sig);
        vm.expectRevert(PositionFunnel.NonceUsed.selector);
        funnel.executeSigned(calls, 7, block.timestamp + 1 days, sig);
    }

    function test_execute_onlyOwner() public {
        factory.deploy(maker, USER_SALT);
        PositionFunnel.Call[] memory calls = new PositionFunnel.Call[](0);
        vm.prank(solver);
        vm.expectRevert(PositionFunnel.NotOwner.selector);
        funnel.execute(calls);
    }

    // ──────────────────── EIP-1271 consumer gate ────────────────────

    /// @dev The funnel sits at the same address on every chain and holds funds on
    ///      each, so a general-purpose 1271 would make any third-party domain that
    ///      omits `chainId` replayable somewhere real. The consumer set is closed.
    function test_1271_rejectsAnUnknownConsumer() public {
        factory.deploy(maker, USER_SALT);
        Order memory dst = _swapOrder(1);
        bytes memory sig = _signWith(dst, makerPk);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(dst)));

        vm.prank(address(0xDEF1));
        assertEq(funnel.isValidSignature(digest, sig), bytes4(0xffffffff), "stranger gets no attestation");
    }

    /// @dev Settlement must still verify, or nothing fills.
    function test_1271_settlementIsAllowed() public {
        factory.deploy(maker, USER_SALT);
        Order memory dst = _swapOrder(1);
        bytes memory sig = _signWith(dst, makerPk);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(dst)));

        vm.prank(address(settlement));
        assertEq(funnel.isValidSignature(digest, sig), bytes4(0x1626ba7e), "settlement attests");
    }

    /// @dev And the lens must, or the orderbook reads every funnel order as
    ///      unsigned and drops it.
    function test_1271_lensCanStillAttest() public {
        _fillSourceAcross();
        spokePool.relay(0);
        address[] memory toks = new address[](1);
        toks[0] = address(tA);
        factory.deployAndEnable(maker, USER_SALT, toks);

        Order memory dst = _swapOrder(1);
        bytes memory sig = _signWith(dst, makerPk);
        (,, bool sigValid,) = lens.getOrderRelevantState(dst, sig, solver, "");
        assertTrue(sigValid, "preflight attests a funnel order");
    }

    function test_1271_ownerCanOpenAnExtraConsumer() public {
        factory.deploy(maker, USER_SALT);
        Order memory dst = _swapOrder(1);
        bytes memory sig = _signWith(dst, makerPk);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(dst)));

        vm.prank(maker);
        funnel.setSigConsumer(address(0xDEF1), true);

        vm.prank(address(0xDEF1));
        assertEq(funnel.isValidSignature(digest, sig), bytes4(0x1626ba7e), "opted in");
    }

    function test_1271_onlyOwnerOpensConsumers() public {
        factory.deploy(maker, USER_SALT);
        vm.prank(solver);
        vm.expectRevert(PositionFunnel.NotOwner.selector);
        funnel.setSigConsumer(address(0xDEF1), true);
    }

    // ──────────────────── Withdrawal as cancellation ────────────────────

    /// @dev Pulling the funds is the cancel primitive: no nonce burn, no
    ///      signature, no on-chain order state — the fill simply stops being
    ///      possible because Settlement's pull has nothing to take.
    function test_withdraw_cancelsAPendingOrder() public {
        Order memory dst = _swapOrder(1);
        bytes memory dstSig = _signWith(dst, makerPk);

        _fillSourceAcross();
        spokePool.relay(0);
        address[] memory toks = new address[](1);
        toks[0] = address(tA);
        factory.deployAndEnable(maker, USER_SALT, toks);

        // The lens sees it as fillable while the funds sit there.
        (, uint256 fillableBefore,,) = lens.getOrderRelevantState(dst, dstSig, solver, "");
        assertEq(fillableBefore, DELIVERED, "fillable while funded");

        vm.prank(maker);
        funnel.withdraw(address(tA), DELIVERED, maker);
        assertEq(tA.balanceOf(maker), DELIVERED, "user took their funds back");

        (, uint256 fillableAfter,,) = lens.getOrderRelevantState(dst, dstSig, solver, "");
        assertEq(fillableAfter, 0, "order is no longer fillable");

        _fundSolverOut(300e18);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(dst, dstSig, DELIVERED);
    }

    function test_withdraw_onlyOwner() public {
        _fillSourceAcross();
        spokePool.relay(0);
        factory.deploy(maker, USER_SALT);

        vm.prank(solver);
        vm.expectRevert(PositionFunnel.NotOwner.selector);
        funnel.withdraw(address(tA), DELIVERED, solver);
    }

    /// @dev A stray delivery to a funnel needs no rescue machinery at all — there
    ///      is no ambiguity about whose it is.
    function test_strayTokensAreJustTheOwners() public {
        factory.deploy(maker, USER_SALT);
        tC.mint(address(funnel), 5e18);

        vm.prank(maker);
        funnel.withdraw(address(tC), 5e18, maker);
        assertEq(tC.balanceOf(maker), 5e18, "owner simply withdraws");
    }
}
