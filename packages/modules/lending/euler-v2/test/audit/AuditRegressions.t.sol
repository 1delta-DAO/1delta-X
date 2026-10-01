// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";

import {IEulerVault, IEVC} from "../../src/interfaces/IEulerV2.sol";
import {EulerV2RepayModule} from "../../src/EulerV2Modules.sol";
import {EulerV2OperatorModule} from "../../src/EulerV2OperatorModule.sol";
import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";

interface IEVCPermitLive {
    function permit(
        address signer,
        address sender,
        uint256 nonceNamespace,
        uint256 nonce,
        uint256 deadline,
        uint256 value,
        bytes calldata data,
        bytes calldata signature
    ) external payable;
    function isControllerEnabled(address account, address vault) external view returns (bool);
    function isCollateralEnabled(address account, address vault) external view returns (bool);
}

/// @title EulerRepayModuleForkTest
/// @notice 2026-09-30 audit L-ED-3 / L-ED-4: `EulerV2RepayModule` had NO executing
///         test, and its `min(amount, debtOf)` clamp is LOAD-BEARING — EVK `repay`
///         reverts `E_RepayTooMuch` above the debt rather than capping (the in-tree
///         NatSpec said the opposite). Live eUSDC-2 on a mainnet fork.
contract EulerRepayModuleForkTest is EulerV2ModulesBase {
    uint256 constant DEBT = 1_000e6;
    uint256 constant BUFFER = 50e6;

    function setUp() public override {
        super.setUp();
        _openEulerPosition(1 ether, DEBT);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, type(uint160).max, 0);
        vm.stopPrank();
    }

    function _repay(uint256 amount, bytes memory data) internal {
        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, amount, data);
    }

    /// The venue premise, pinned: a finite over-debt repay REVERTS on the live EVK,
    /// so the module's clamp is what keeps an over-signed ceiling fillable.
    function test_audit_L_ED_4_evkRepay_revertsAboveDebt_moduleClampIsLoadBearing() public {
        uint256 debt = _usdcDebt(maker);
        deal(USDC, address(this), debt + 1);
        IERC20(USDC).approve(address(EUSDC), debt + 1);
        vm.expectRevert(); // E_RepayTooMuch
        EUSDC.repay(debt + 1, maker);
    }

    /// The other premise: EVK `withdraw` has NO max sentinel.
    function test_audit_L_ED_4_evkWithdraw_hasNoMaxSentinel() public {
        vm.prank(maker);
        vm.expectRevert(); // E_AmountTooLargeToEncode
        EWETH.withdraw(type(uint256).max, maker, maker);
    }

    /// SweepToUser, ceiling ABOVE the debt: the debt is cleared and the buffer never
    /// leaves the maker's wallet (pull-exact).
    function test_audit_L_ED_3_sweepToUser_ceilingAboveDebt_pullsOnlyTheDebt() public {
        uint256 debt = _usdcDebt(maker);
        deal(USDC, maker, debt + BUFFER);

        _repay(debt + BUFFER, abi.encode(address(EUSDC)));

        assertEq(_usdcDebt(maker), 0, "debt cleared");
        assertEq(IERC20(USDC).balanceOf(maker), BUFFER, "buffer stayed in the wallet");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module ends empty");
        assertEq(IERC20(USDC).allowance(address(repayModule), address(EUSDC)), 0, "vault grant cleared");
    }

    /// Recycle: the full ceiling is pulled and the surplus re-supplied as eUSDC
    /// shares for the maker.
    function test_audit_L_ED_3_recycle_resuppliesSurplusAsShares() public {
        uint256 debt = _usdcDebt(maker);
        deal(USDC, maker, debt + BUFFER);
        uint256 sharesBefore = EUSDC.balanceOf(maker);

        _repay(debt + BUFFER, abi.encode(address(EUSDC), uint256(DustHandler.DustAction.Recycle)));

        assertEq(_usdcDebt(maker), 0, "debt cleared");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "whole ceiling pulled");
        assertApproxEqAbs(
            EUSDC.convertToAssets(EUSDC.balanceOf(maker) - sharesBefore), BUFFER, 2, "surplus re-supplied"
        );
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module ends empty");
    }

    /// Partial repay below the debt.
    function test_audit_L_ED_3_partialRepay() public {
        uint256 debt = _usdcDebt(maker);
        deal(USDC, maker, 400e6);
        _repay(400e6, abi.encode(address(EUSDC)));
        assertApproxEqAbs(_usdcDebt(maker), debt - 400e6, 1, "debt reduced by the slice");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "slice pulled");
    }

    /// A pre-existing module balance is the FLOOR — never paid out to the filler.
    function test_audit_L_ED_3_preExistingBalance_untouched() public {
        uint256 debt = _usdcDebt(maker);
        deal(USDC, address(repayModule), 7e6);
        deal(USDC, maker, debt + BUFFER);
        _repay(debt + BUFFER, abi.encode(address(EUSDC), uint256(DustHandler.DustAction.Recycle)));
        assertEq(_usdcDebt(maker), 0, "debt cleared");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 7e6, "the floor stays put");
    }

    function test_audit_L_ED_3_onlySettlement() public {
        vm.expectRevert(EulerV2RepayModule.NotSettlement.selector);
        repayModule.makeOnBehalf(maker, 1e6, abi.encode(address(EUSDC)));
    }
}

/// @title EulerSubAccountForkTest
/// @notice 2026-09-30 audit L-ED-6: every Euler op was pinned to the maker's PRIMARY
///         EVC account, and the EVC allows one controller per account — so a maker
///         could hold at most one Euler borrow position through these modules. A
///         maker-signed `subId` now selects the sub-account `maker ^ subId`.
contract EulerSubAccountForkTest is EulerV2ModulesBase {
    uint256 constant SUB = 1;
    address sub;

    function setUp() public override {
        super.setUp();
        sub = address(uint160(maker) ^ uint160(SUB));
        vm.startPrank(maker);
        EVC.enableCollateral(sub, address(EWETH));
        EVC.enableController(sub, address(EUSDC));
        EVC.setAccountOperator(sub, address(operatorModule), true);
        vm.stopPrank();
    }

    function _borrowData(uint256 subId) internal pure returns (bytes memory) {
        return abi.encode(uint256(EulerV2OperatorModule.Op.Borrow) | (subId << 8), address(EUSDC));
    }

    /// A SECOND, independent borrow position: the primary account already borrows,
    /// and a leverage open on sub-account 1 (deposit + borrow, one Settlement fill)
    /// lands entirely on the sub-account.
    function test_audit_L_ED_6_subAccount_leverageOpen_isolatedFromPrimary() public {
        _openEulerPosition(1 ether, 500e6); // primary position
        uint256 primaryDebt = _usdcDebt(maker);
        uint256 primaryCol = _wethCollateral(maker);

        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 800e6;
        bytes memory depositData = abi.encode(address(EWETH), SUB);
        bytes memory borrowData = _borrowData(SUB);

        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(depositModule), collateralIn, address(0), depositData);
        items[1] = Item(ItemOp.TAKE, address(operatorModule), borrowOut, address(0), borrowData);
        Order memory order = _order(maker, 11, USDC, WETH, borrowOut, collateralIn, items);
        bytes memory sig = _sign(order);

        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(collateralIn), 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(borrowData), uint160(borrowOut), 0);
        vm.stopPrank();
        deal(WETH, solver, collateralIn);
        _approveSolverSide(collateralIn, WETH);

        vm.prank(solver);
        settlement.fill(order, sig, borrowOut);

        assertApproxEqAbs(_wethCollateral(sub), collateralIn, 2, "collateral on the SUB-account");
        assertApproxEqAbs(_usdcDebt(sub), borrowOut, 1, "debt on the SUB-account");
        assertEq(_usdcDebt(maker), primaryDebt, "primary debt untouched");
        assertEq(_wethCollateral(maker), primaryCol, "primary collateral untouched");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received the borrow");

        // The position reader follows the sub-account too.
        bytes memory wd = abi.encode(uint256(EulerV2OperatorModule.Op.Withdraw) | (SUB << 8), address(EWETH));
        (, uint256 pos) = operatorModule.positionOf(maker, wd);
        assertApproxEqAbs(pos, collateralIn, 2, "positionOf reads the sub-account");

        // And the repay module retires the SUB-account's debt, sweeping to the wallet.
        deal(USDC, maker, borrowOut + 10e6);
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, type(uint160).max, 0);
        vm.stopPrank();
        vm.prank(address(settlement));
        repayModule.makeOnBehalf(
            maker, borrowOut + 10e6, abi.encode(address(EUSDC), uint256(DustHandler.DustAction.SweepToUser), SUB)
        );
        assertEq(_usdcDebt(sub), 0, "sub-account debt repaid");
        assertEq(_usdcDebt(maker), primaryDebt, "primary debt still untouched");
    }

    /// The maker opts in PER sub-account: without the EVC operator grant on
    /// `maker ^ 2`, a borrow naming it reverts in the EVC.
    function test_audit_L_ED_6_subAccount_requiresItsOwnOperatorGrant() public {
        bytes memory d = _borrowData(2);
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(d), 100e6, 0);
        vm.prank(address(settlement));
        vm.expectRevert(); // EVC_NotAuthorized
        permit3.take(address(operatorModule), maker, 100e6, recvAddr(), d);
    }

    /// Word 0 admits only `op | subId << 8`: any higher bit is still `BadOp`.
    function test_audit_L_ED_6_highBitsInOpWord_stillBadOp() public {
        uint256 w = uint256(EulerV2OperatorModule.Op.Borrow) | (uint256(1) << 16);
        bytes memory d = abi.encode(w, address(EUSDC));
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(d), 100e6, 0);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(EulerV2OperatorModule.BadOp.selector, w));
        permit3.take(address(operatorModule), maker, 100e6, recvAddr(), d);
    }

    /// The optional maker-module word is range-checked: a `subId` >= 256 is not an
    /// EVC sub-account and is refused rather than truncated.
    function test_audit_L_ED_6_depositSubIdOutOfRange_reverts() public {
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSignature("BadSubAccount(uint256)", uint256(256))); // EulerSubAccount.BadSubAccount
        depositModule.makeOnBehalf(maker, 1, abi.encode(address(EWETH), uint256(256)));
    }

    function recvAddr() internal pure returns (address) {
        return address(0xCAFE);
    }
}

/// @title EulerPullOpenEvcTailTest
/// @notice 2026-09-30 audit L-ED-5 (Euler half): the EVC-permit tail was enabled on
///         the PULL shape of `Op.Open` by the merge, but every EVC-permit test built
///         the pre-fund descriptor. A fresh maker with NO EVC grants opens through the
///         pull shape; the operator/controller/collateral grants ride the tail.
contract EulerPullOpenEvcTailTest is EulerV2ModulesBase {
    uint256 constant COLLATERAL = 1 ether;
    uint256 constant BORROW = 1_500e6;

    bytes32 constant EVC_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 constant EVC_PERMIT_TYPEHASH = keccak256(
        "Permit(address signer,address sender,uint256 nonceNamespace,uint256 nonce,uint256 deadline,uint256 value,bytes data)"
    );

    function setUp() public override {
        super.setUp();
        makerPk = 0xF4E512;
        maker = vm.addr(makerPk);
    }

    function _signEvcPermit(uint256 deadline, bytes memory evcData) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(EVC_DOMAIN_TYPEHASH, keccak256(bytes("Ethereum Vault Connector")), block.chainid, address(EVC))
        );
        bytes32 structHash = keccak256(
            abi.encode(
                EVC_PERMIT_TYPEHASH,
                maker,
                address(operatorModule), // sender = module: only the maker's own fill can land it (L-ED-1)
                uint256(0),
                uint256(0),
                deadline,
                uint256(0),
                keccak256(evcData)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _grantBatchData() internal view returns (bytes memory) {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem(
            address(EVC), address(0), 0, abi.encodeCall(IEVC.setAccountOperator, (maker, address(operatorModule), true))
        );
        items[1] =
            IEVC.BatchItem(address(EVC), address(0), 0, abi.encodeCall(IEVC.enableController, (maker, address(EUSDC))));
        items[2] =
            IEVC.BatchItem(address(EVC), address(0), 0, abi.encodeCall(IEVC.enableCollateral, (maker, address(EWETH))));
        return abi.encodeCall(IEVC.batch, (items));
    }

    function test_audit_L_ED_5_pullShapeOpen_evcPermitTail_grantsAndOpens() public {
        assertFalse(EVC.isAccountOperatorAuthorized(maker, address(operatorModule)), "fresh maker: no operator");

        bytes memory data;
        {
            uint256 deadline = block.timestamp + 1 hours;
            bytes memory evcData = _grantBatchData();
            // PULL shape: leg reference WITHOUT bit 253 — the leg goes to the maker
            // and the module draws it back through Permit3.
            uint256 forDesc = (uint256(1) << 255) | (uint256(EulerV2OperatorModule.Op.Open) << 244);
            bytes memory head = abi.encode(
                EulerV2OperatorModule.OpenData({
                    forDesc: forDesc, forCap: 0, collateralVault: address(EWETH), borrowVault: address(EUSDC)
                })
            );
            // The EvcPermit[] tail ({DelegationHelper}, 2026-09-30 audit L-ED-1 ABI).
            DelegationHelper.EvcPermit[] memory permits = new DelegationHelper.EvcPermit[](1);
            permits[0] = DelegationHelper.EvcPermit(0, 0, deadline, evcData, _signEvcPermit(deadline, evcData));
            data = bytes.concat(head, abi.encode(permits));
        }

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(operatorModule), BORROW, address(0), data);
        Order memory o = _order(maker, 41, USDC, WETH, BORROW, COLLATERAL, items);
        bytes memory sig = _sign(o);

        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(operatorModule), WETH, uint160(COLLATERAL), 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(data), uint160(BORROW), 0);
        vm.stopPrank();
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);

        vm.prank(solver);
        settlement.fill(o, sig, BORROW);

        assertTrue(EVC.isAccountOperatorAuthorized(maker, address(operatorModule)), "operator granted by the tail");
        assertTrue(IEVCPermitLive(address(EVC)).isControllerEnabled(maker, address(EUSDC)), "controller enabled");
        assertApproxEqRel(_wethCollateral(maker), COLLATERAL, 1e15, "pulled leg became collateral");
        assertApproxEqRel(_usdcDebt(maker), BORROW, 1e15, "debt drawn");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "delivered leg drawn back from the wallet");
        assertEq(IERC20(USDC).balanceOf(solver), BORROW, "solver received the input leg");
    }
}
