// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {IFluidVault} from "../../src/interfaces/IFluid.sol";
import {FluidDepositModule, FluidRepayModule, FluidTakerModule, FluidOperateModule} from "../../src/FluidModules.sol";

/// @dev ERC721 surface (incl. `setApprovalForAll`) used to seed positions and the
///      one-time operator grant for the value-out modules.
interface IFluidVaultFactory721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
}

/// @dev Fluid integration harness. Forks mainnet (via CoreSettlementBase) and drives
/// a REAL position on the same vault the 1delta composer's FluidLending test uses:
/// the Fluid ETH-USDC T1 vault (native-ETH collateral, USDC debt).
///
/// Fluid authorisation differs per direction, mirroring the module docs:
///   • deposit / repay (value-IN) are permissionless — only a Permit3 token allowance.
///   • borrow / withdraw / operate-close (value-OUT) need the maker to grant each
///     module ERC721 operator rights once (`factory.setApprovalForAll(module, true)`)
///     so the module can pull the position NFT in just-in-time; the Permit3 taker
///     allowance still caps every fill.
abstract contract FluidModulesBase is CoreSettlementBase {
    /// @dev Fluid ETH-USDC vault (T1) on Ethereum mainnet — the composer's test vault.
    address constant VAULT = 0x0C8C77B7FF4c2aF7F6CEBbe67350A490E3DD6cB3;
    /// @dev Fluid VaultFactory (ERC721 holding all position NFTs) on Ethereum mainnet.
    address constant VAULT_FACTORY = 0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d;

    FluidDepositModule depositModule;
    FluidRepayModule repayModule;
    FluidTakerModule takerModule;
    FluidOperateModule operateModule;

    /// @dev A plain EOA that receives value-out proceeds (USDC / native ETH).
    address recv = address(0xCAFE);

    function setUp() public virtual override {
        super.setUp();

        depositModule = new FluidDepositModule(address(permit3), address(settlement));
        repayModule = new FluidRepayModule(address(permit3), address(settlement));
        takerModule = new FluidTakerModule(address(permit3));
        operateModule = new FluidOperateModule(address(permit3));

        vm.label(VAULT, "FluidEthUsdcVault");
        vm.label(VAULT_FACTORY, "FluidVaultFactory");
        vm.label(address(depositModule), "fluidDepositModule");
        vm.label(address(repayModule), "fluidRepayModule");
        vm.label(address(takerModule), "fluidTakerModule");
        vm.label(address(operateModule), "fluidOperateModule");
        vm.label(recv, "receiver");

        // One-time ERC721 operator grant for the value-out (JIT-custody) modules.
        vm.startPrank(maker);
        IFluidVaultFactory721(VAULT_FACTORY).setApprovalForAll(address(takerModule), true);
        IFluidVaultFactory721(VAULT_FACTORY).setApprovalForAll(address(operateModule), true);
        vm.stopPrank();
    }

    /// @dev Fluid's ETH-USDC vault is live well after this block.
    function _forkBlock() internal view virtual override returns (uint256) {
        return 22_000_000;
    }

    /// @dev Open a fresh ETH/USDC position owned by `owner_` directly against the
    ///      vault (NFT mints to `owner_` as the operate caller). Returns the id.
    function _openPosition(address owner_, uint256 ethCol, uint256 usdcDebt) internal returns (uint256 nftId) {
        vm.deal(owner_, owner_.balance + ethCol);
        vm.prank(owner_);
        (nftId,,) = IFluidVault(VAULT).operate{value: ethCol}(0, int256(ethCol), int256(usdcDebt), owner_);
        require(nftId != 0, "open position failed");
    }

    function _ownerOf(uint256 nftId) internal view returns (address) {
        return IFluidVaultFactory721(VAULT_FACTORY).ownerOf(nftId);
    }
}
