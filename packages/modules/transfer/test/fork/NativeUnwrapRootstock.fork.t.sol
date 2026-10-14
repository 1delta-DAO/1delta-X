// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Order, Item, ItemOp, LegIn, LegOut, Settlement} from "@core/settlement/Settlement.sol";
import {NativeUnwrapModule} from "../../src/NativeUnwrapModule.sol";

interface ILensHash {
    function hashOrder(Order calldata order) external pure returns (bytes32);
}

/// @dev Task 28 pre-deploy check: the {NativeUnwrapModule} against the LIVE Rootstock beta
///      (Settlement / Lens deployed 2026-10-09 from b23ec90 — core and module unchanged
///      since) and the real WRBTC. A maker sells USD₮0 and receives raw RBTC in the same
///      fill; the filler is a plain EOA with WRBTC (the inventory shape), so the whole
///      path is the real one minus the solver.
///
///      Opt-in: `RSK_FORK_URL=https://public-node.rsk.co forge test --match-path '*NativeUnwrapRootstock*'`
///      (FOUNDRY_PROFILE=modules-transfer-deploy, the deployed bytecode's Cancun target).
///      Skipped without RSK_FORK_URL.
contract NativeUnwrapRootstockForkTest is Test {
    Settlement constant SETTLEMENT = Settlement(0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5);
    ILensHash constant LENS = ILensHash(0xF9e905EdCC376FDaBF62Ca0966624611721C5206);
    address constant WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    /// @dev The WRBTC/USD₮0 0.3 % pool: a holder of both to fund from.
    address constant POOL = 0xaeF6fABf3b0C9e5F9d6D5170AfC703A633479Bbd;

    NativeUnwrapModule module;
    uint256 makerPk = 0xA11CE;
    address maker;
    address filler = makeAddr("filler");
    bool live;

    function setUp() public {
        string memory url = vm.envOr("RSK_FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        maker = vm.addr(makerPk);
        module = new NativeUnwrapModule(WRBTC, address(SETTLEMENT));
        vm.startPrank(POOL);
        IERC20(USDT0).transfer(maker, 100e6);
        IERC20(WRBTC).transfer(filler, 0.01 ether);
        vm.stopPrank();
        vm.prank(maker);
        IERC20(USDT0).approve(address(SETTLEMENT), type(uint256).max); // the app's direct approval
        vm.prank(filler);
        IERC20(WRBTC).approve(address(SETTLEMENT), type(uint256).max);
    }

    /// @dev Sell `usdtIn` USD₮0 for `rbtcOut` native RBTC: the WRBTC leg goes to the module,
    ///      a MAKE item with the pre-fund leg reference unwraps exactly what was delivered.
    function _order(uint256 nonce, uint256 usdtIn, uint256 rbtcOut, address payout) internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(module),
            amount: 0,
            recipient: address(0),
            data: abi.encode((uint256(5) << 253) | (uint256(uint160(WRBTC)) << 16), payout) // forLegPreFund(0, WRBTC)
        });
        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDT0, usdtIn, 0);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WRBTC, rbtcOut, 0, address(module));
        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: uint256(uint48(block.timestamp + 1 hours)) << 160,
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _sign(Order memory o) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", SETTLEMENT.DOMAIN_SEPARATOR(), LENS.hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_fork_liveSettlement_makerReceivesRawRbtc() public {
        if (!live) return vm.skip(true);
        Order memory o = _order(1, 50e6, 0.0006 ether, address(0));
        bytes memory sig = _sign(o);
        uint256 before = maker.balance;
        vm.prank(filler);
        uint256 g = gasleft();
        SETTLEMENT.fill(o, sig, 50e6);
        emit log_named_uint("fill gas (Cancun schedule)", g - gasleft());
        assertEq(maker.balance - before, 0.0006 ether, "raw RBTC in the maker's wallet");
        assertEq(IERC20(USDT0).balanceOf(filler), 50e6, "filler got the USD0");
        assertEq(IERC20(WRBTC).balanceOf(address(module)), 0, "module holds no WRBTC");
        assertEq(address(module).balance, 0, "module holds no RBTC");
        assertEq(IERC20(WRBTC).balanceOf(maker), 0, "nothing left wrapped");
    }

    function test_fork_partialFills_and_explicitPayout() public {
        if (!live) return vm.skip(true);
        address payee = makeAddr("payee");
        Order memory o = _order(2, 50e6, 0.0006 ether, payee);
        bytes memory sig = _sign(o);
        vm.startPrank(filler);
        SETTLEMENT.fill(o, sig, 20e6);
        SETTLEMENT.fill(o, sig, 30e6);
        vm.stopPrank();
        // SELL legs round up per fill (maker-ward): at most 1 wei over across 2 fills.
        assertApproxEqAbs(payee.balance, 0.0006 ether, 1, "payee got the RBTC");
        assertEq(address(module).balance, 0, "module holds no RBTC");
    }
}
