// SPDX-License-Identifier: BUSL-1.1
// solhint-disable max-line-length

pragma solidity ^0.8.28;

struct LenderTokens {
    address collateral;
    address debt;
    address stableDebt;
}

struct ChainInfo {
    string rpcUrl;
    uint256 chainId;
}

contract LenderRegistry {
    // chainId -> lender -> underlying -> data
    mapping(string => mapping(string => mapping(address => LenderTokens))) lendingTokens;
    mapping(string => mapping(string => address)) lendingControllers;
    // chainId -> lender -> baseAssets
    mapping(string => mapping(string => address)) cometToBase;

    // chain -> symbol -> address
    mapping(string => mapping(string => address)) tokens;

    // chain -> chain info (rpc, chainId, forkBlock)
    mapping(string => ChainInfo) chainInfo;

    constructor() {
        chainInfo[Chains.MOONBEAM] = ChainInfo("https://rpc.api.moonbeam.network", 1284);
        chainInfo[Chains.CRONOS_MAINNET] = ChainInfo("https://evm.cronos.org", 25);
        chainInfo[Chains.MONAD_MAINNET] = ChainInfo("https://rpc.monad.xyz", 143);
        chainInfo[Chains.ETHEREUM_MAINNET] = ChainInfo("https://eth.drpc.org", 1);
        chainInfo[Chains.OP_MAINNET] = ChainInfo("https://mainnet.optimism.io", 10);
        chainInfo[Chains.BNB_SMART_CHAIN_MAINNET] = ChainInfo("https://bsc-dataseed1.bnbchain.org", 56);
        chainInfo[Chains.GNOSIS] = ChainInfo("https://rpc.gnosischain.com", 100);
        chainInfo[Chains.POLYGON_MAINNET] = ChainInfo("https://polygon-rpc.com/", 137);
        chainInfo[Chains.SONIC_MAINNET] = ChainInfo("https://rpc.soniclabs.com", 146);
        chainInfo[Chains.ZKSYNC_MAINNET] = ChainInfo("https://mainnet.era.zksync.io", 324);
        chainInfo[Chains.METIS_ANDROMEDA_MAINNET] = ChainInfo("https://andromeda.metis.io/?owner=1088", 1088);
        chainInfo[Chains.SONEIUM] = ChainInfo("https://rpc.soneium.org", 1868);
        chainInfo[Chains.MANTLE] = ChainInfo("https://rpc.mantle.xyz", 5000);
        chainInfo[Chains.BASE] = ChainInfo("https://mainnet.base.org/", 8453);
        chainInfo[Chains.PLASMA_MAINNET] = ChainInfo("https://rpc.plasma.to", 9745);
        chainInfo[Chains.ARBITRUM_ONE] = ChainInfo("https://arbitrum.drpc.org", 42161);
        chainInfo[Chains.CELO_MAINNET] = ChainInfo("https://forno.celo.org", 42220);
        chainInfo[Chains.AVALANCHE_C_CHAIN] = ChainInfo("https://api.avax.network/ext/bc/C/rpc", 43114);
        chainInfo[Chains.LINEA] = ChainInfo("https://rpc.linea.build", 59144);
        chainInfo[Chains.SCROLL] = ChainInfo("https://rpc.scroll.io", 534352);
        chainInfo[Chains.HARMONY_MAINNET_SHARD_0] = ChainInfo("https://api.harmony.one", 1666600000);
        chainInfo[Chains.TAIKO_ALETHIA] = ChainInfo("https://rpc.mainnet.taiko.xyz", 167000);
        chainInfo[Chains.MORPH] = ChainInfo("https://rpc.morphl2.io", 2818);
        chainInfo[Chains.TELOS_EVM_MAINNET] = ChainInfo("https://mainnet.telos.net/evm", 40);
        chainInfo[Chains.METER_MAINNET] = ChainInfo("https://rpc.meter.io", 82);
        chainInfo[Chains.FUSE_MAINNET] = ChainInfo("https://rpc.fuse.io", 122);
        chainInfo[Chains.TARAXA_MAINNET] = ChainInfo("https://rpc.mainnet.taraxa.io/", 841);
        chainInfo[Chains.ARTELA_MAINNET] = ChainInfo("https://node-euro.artela.network/rpc", 11820);
        chainInfo[Chains.KAIA_MAINNET] = ChainInfo("https://public-en.node.kaia.io", 8217);
        chainInfo[Chains.HEMI_NETWORK] = ChainInfo("https://rpc.hemi.network/rpc", 43111);
        chainInfo[Chains.CORE_BLOCKCHAIN_MAINNET] = ChainInfo("https://rpc.coredao.org/", 1116);
        chainInfo[Chains.BLAST] = ChainInfo("https://rpc.blast.io", 81457);
        chainInfo[Chains.HYPEREVM] = ChainInfo("https://rpc.hyperliquid.xyz/evm", 999);
        chainInfo[Chains.MODE] = ChainInfo("https://mainnet.mode.network", 34443);
        chainInfo[Chains.CORN] = ChainInfo("https://mainnet.corn-rpc.com", 21000000);
        chainInfo[Chains.ZETACHAIN_MAINNET] = ChainInfo("https://zetachain-evm.blockpi.network/v1/rpc/public", 7000);
        chainInfo[Chains.MERLIN_MAINNET] = ChainInfo("https://rpc.merlinchain.io", 4200);
        chainInfo[Chains.IOTEX_NETWORK_MAINNET] = ChainInfo("https://babel-api.mainnet.iotex.io", 4689);
        chainInfo[Chains.BOB] = ChainInfo("https://rpc.gobob.xyz", 60808);
        chainInfo[Chains.BITLAYER_MAINNET] = ChainInfo("https://rpc.bitlayer.org", 200901);
        chainInfo[Chains.B2_MAINNET] = ChainInfo("https://mainnet.b2-rpc.com", 223);
        chainInfo[Chains.SEI_NETWORK] = ChainInfo("https://evm-rpc.sei-apis.com", 1329);
        chainInfo[Chains.GOAT_NETWORK] = ChainInfo("https://rpc.goat.network", 2345);
        chainInfo[Chains.OPBNB_MAINNET] = ChainInfo("https://opbnb-mainnet-rpc.bnbchain.org", 204);
        chainInfo[Chains.MANTA_PACIFIC_MAINNET] = ChainInfo("https://pacific-rpc.manta.network/http", 169);
        chainInfo[Chains.X_LAYER_MAINNET] = ChainInfo("https://rpc.xlayer.tech", 196);
        chainInfo[Chains.ABSTRACT] = ChainInfo("https://api.mainnet.abs.xyz", 2741);
        chainInfo[Chains.ZIRCUIT_MAINNET] = ChainInfo("https://zircuit1-mainnet.p2pify.com/", 48900);
        chainInfo[Chains.BERACHAIN] = ChainInfo("https://rpc.berachain.com", 80094);
        chainInfo[Chains.FANTOM_OPERA] = ChainInfo("https://rpc.ftm.tools", 250);
        chainInfo[Chains.NEON_EVM_MAINNET] = ChainInfo("https://neon-proxy-mainnet.solana.p2p.org", 245022934);
        chainInfo[Chains.PULSECHAIN] = ChainInfo("https://rpc.pulsechain.com", 369);
        chainInfo[Chains.XDC_NETWORK] = ChainInfo("https://erpc.xinfin.network", 50);
        chainInfo[Chains.KATANA] = ChainInfo("https://rpc.katana.network", 747474);
        chainInfo[Chains.UNICHAIN] = ChainInfo("https://mainnet.unichain.org", 130);
        chainInfo[Chains.TAC_MAINNET] = ChainInfo("https://rpc.tac.build", 239);
        chainInfo[Chains.FRAXTAL] = ChainInfo("https://rpc.frax.com", 252);
        chainInfo[Chains.WORLD_CHAIN] = ChainInfo("https://worldchain-mainnet.g.alchemy.com/public", 480);
        chainInfo[Chains.LISK] = ChainInfo("https://rpc.api.lisk.com", 1135);
        chainInfo[Chains.BOTANIX_MAINNET] = ChainInfo("https://rpc.btxtestchain.com", 3637);
        chainInfo[Chains.ETHERLINK_MAINNET] = ChainInfo("https://node.mainnet.etherlink.com", 42793);
        chainInfo[Chains.INK] = ChainInfo("https://rpc-gel.inkonchain.com", 57073);
        chainInfo[Chains.PLUME_MAINNET] = ChainInfo("https://phoenix-rpc.plumenetwork.xyz", 98866);
        chainInfo[Chains.FLAME] = ChainInfo("https://rpc.flame.astria.org", 253368190);
        chainInfo[Chains.BASECAMP] = ChainInfo("https://rpc.basecamp.t.raas.gelato.cloud", 123420001114);
        chainInfo[Chains.RONIN_MAINNET] = ChainInfo("https://api.roninchain.com/rpc", 2020);
        chainInfo[Chains.ZKLINK_NOVA_MAINNET] = ChainInfo("https://rpc.zklink.io", 810180);
        chainInfo[Chains.CONFLUX_ESPACE] = ChainInfo("https://evm.confluxrpc.com", 1030);

        // Initialize AAVE protocol data
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] = LenderTokens(
            0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8,
            0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0] = LenderTokens(
            0x0B925eD163218f6662a35e0f0371Ac234f9E9371,
            0xC96113eED8cAB59cD8A66813bCB0cEb29F06D2e4,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] = LenderTokens(
            0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8,
            0x40aAbEf1aa8f0eEc637E0E7d92fbfFB2F26A8b7B,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = LenderTokens(
            0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c,
            0x72E95b8931767C79bA4EeE721354d6E99a61D004,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x6B175474E89094C44Da98b954EedeAC495271d0F] = LenderTokens(
            0x018008bfb33d285247A21d44E50697654f754e63,
            0xcF8d0c70c850859266f5C338b38F9D663181C314,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x514910771AF9Ca656af840dff83E8264EcF986CA] = LenderTokens(
            0x5E8C8A7243651DB1384C0dDfDbE39761E8e7E51a,
            0x4228F8895C7dDA20227F6a5c6751b8Ebf19a6ba8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9] = LenderTokens(
            0xA700b4eB416Be35b2911fd5Dee80678ff64fF6C9,
            0xBae535520Abd9f8C85E58929e0006A2c8B372F74,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xBe9895146f7AF43049ca1c1AE358B0541Ea49704] = LenderTokens(
            0x977b6fc5dE62598B08C85AC8Cf2b745874E8b78c,
            0x0c91bcA95b5FE69164cE583A2ec9429A569798Ed,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xdAC17F958D2ee523a2206206994597C13D831ec7] = LenderTokens(
            0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a,
            0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xae78736Cd615f374D3085123A210448E74Fc6393] = LenderTokens(
            0xCc9EE9483f662091a1de4795249E24aC0aC2630f,
            0xae8593DD575FE29A9745056aA91C4b746eee62C8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x5f98805A4E8be255a32880FDeC7F6728C6568bA0] = LenderTokens(
            0x3Fe6a295459FAe07DF8A0ceCC36F37160FE86AA9,
            0x33652e48e4B74D18520f11BfE58Edd2ED2cEc5A2,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xD533a949740bb3306d119CC777fa900bA034cd52] = LenderTokens(
            0x7B95Ec873268a6BFC6427e7a28e396Db9D0ebc65,
            0x1b7D3F4b3c032a5AE656e30eeA4e8E1Ba376068F,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2] = LenderTokens(
            0x8A458A9dc9048e005d22849F470891b840296619,
            0x6Efc73E54E41b27d2134fF9f98F15550f30DF9B1,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F] = LenderTokens(
            0xC7B4c17861357B8ABB91F25581E7263E08DCB59c,
            0x8d0de040e8aAd872eC3c33A3776dE9152D3c34ca,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xba100000625a3754423978a60c9317c58a424e3D] = LenderTokens(
            0x2516E7B3F76294e03C42AA4c5b5b4DCE9C436fB8,
            0x3D3efceb4Ff0966D34d9545D3A2fa2dcdBf451f2,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984] = LenderTokens(
            0xF6D2224916DDFbbab6e6bd0D1B7034f4Ae0CaB18,
            0xF64178Ebd2E2719F2B1233bCb5Ef6DB4bCc4d09a,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32] = LenderTokens(
            0x9A44fd41566876A39655f74971a3A6eA0a17a454,
            0xc30808705C01289A3D306ca9CAB081Ba9114eC82,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72] = LenderTokens(
            0x545bD6c032eFdde65A377A6719DEF2796C8E0f2e,
            0xd180D7fdD4092f07428eFE801E17BC03576b3192,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x111111111117dC0aa78b770fA6A738034120C302] = LenderTokens(
            0x71Aef7b30728b9BB371578f36c5A1f1502a5723e,
            0xA38fCa8c6Bf9BdA52E76EB78f08CaA3BE7c5A970,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x853d955aCEf822Db058eb8505911ED77F175b99e] = LenderTokens(
            0xd4e245848d6E1220DBE62e155d89fa327E43CB06,
            0x88B8358F5BC87c2D7E116cCA5b65A9eEb2c5EA3F,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f] = LenderTokens(
            0x00907f9921424583e7ffBfEdf84F92B7B2Be4977,
            0x786dBff3f1292ae8F92ea68Cf93c30b34B1ed04B,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xD33526068D116cE69F19A9ee46F0bd304F21A51f] = LenderTokens(
            0xB76CF92076adBF1D9C39294FA8e7A67579FDe357,
            0x8988ECA19D502fd8b9CCd03fA3bD20a6f599bc2A,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x83F20F44975D03b1b09e64809B757c47f942BEeA] = LenderTokens(
            0x4C612E3B15b96Ff9A6faED838F8d07d479a8dD4c,
            0x8Db9D35e117d8b93C6Ca9b644b25BaD5d9908141,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xAf5191B0De278C7286d6C7CC6ab6BB8A73bA2Cd6] = LenderTokens(
            0x1bA9843bD4327c6c77011406dE5fA8749F7E3479,
            0x655568bDd6168325EC7e58Bf39b21A856F906Dc2,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xdeFA4e8a7bcBA345F687a2f1456F5Edd9CE97202] = LenderTokens(
            0x5b502e3796385E1e9755d7043B9C945C3aCCeC9C,
            0x253127Ffc04981cEA8932F406710661c2f2c3fD2,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0] = LenderTokens(
            0x82F9c5ad306BBa1AD0De49bB5FA6F01bf61085ef,
            0x68e9f0aD4e6f8F5DB70F6923d4d6d5b225B83b16,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E] = LenderTokens(
            0xb82fa9f31612989525992FCfBB09AB22Eff5c85A,
            0x028f7886F3e937f8479efaD64f31B3fE1119857a,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x6c3ea9036406852006290770BEdFcAbA0e23A0e8] = LenderTokens(
            0x0C0d01AbF3e6aDfcA0989eBbA9d6e85dD58EaB1E,
            0x57B67e4DE077085Fd0AF2174e9c14871BE664546,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee] = LenderTokens(
            0xBdfa7b7893081B35Fb54027489e2Bc7A38275129,
            0x77ad9BF13a52517AD698D65913e8D381300c8Bf3,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38] = LenderTokens(
            0x927709711794F3De5DdBF1D176bEE2D55Ba13c21,
            0x8838eefF2af391863E1Bb8b1dF563F86743a8470,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x4c9EDD5852cd905f086C759E8383e09bff1E68B3] = LenderTokens(
            0x4F5923Fc5FD4a93352581b38B7cD26943012DECF,
            0x015396E1F286289aE23a762088E863b3ec465145,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xA35b1B31Ce002FBF2058D22F30f95D405200A15b] = LenderTokens(
            0x1c0E06a0b1A4c160c17545FF2A951bfcA57C0002,
            0x08a8Dc81AeA67F84745623aC6c72CDA3967aab8b,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x9D39A5DE30e57443BfF2A8307A4256c8797A3497] = LenderTokens(
            0x4579a27aF00A62C0EB156349f31B345c08386419,
            0xeFFDE9BFA8EC77c14C364055a200746d6e12BeD6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x18084fbA666a33d37592fA2633fD49a74DD93a88] = LenderTokens(
            0x10Ac93971cdb1F5c778144084242374473c350Da,
            0xAC50890a80A2731eb1eA2e9B4F29569CeB06D960,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0x5c647cE0Ae10658ec44FA4E11A51c96e94efd1Dd,
            0xeB284A70557EFe3591b9e6D9D720040E02c54a4d,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xdC035D45d973E3EC169d2276DDab16f1e407384F] = LenderTokens(
            0x32a6268f9Ba3642Dda7892aDd74f1D34469A4259,
            0x490E0E6255bF65b43E2e02F7acB783c5e04572Ff,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7] = LenderTokens(
            0x2D62109243b87C4bA3EE7bA1D91B0dD0A074d7b1,
            0x6De3E52A1B7294A34e271a508082b1Ff4a37E30e,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x8236a87084f8B84306f72007F36F2618A5634494] = LenderTokens(
            0x65906988ADEe75306021C417a1A3458040239602,
            0x68aeB290C7727D899B47c56d1c96AEAC475cD0dD,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x657e8C867D8B37dCC18fA4Caead9C45EB088C642] = LenderTokens(
            0x5fefd7069a7D91d01f269DADE14526CCF3487810,
            0x47eD0509e64615c0d5C6d39AF1B38D02Bc9fE58f,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD] = LenderTokens(
            0xFa82580c16A31D0c1bC632A36F82e83EfEF3Eec0,
            0xBdFe7aD7976d5d7E0965ea83a81Ca1bCfF7e84a9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x50D2C7992b802Eef16c04FeADAB310f31866a545] = LenderTokens(
            0x4B0821e768Ed9039a70eD1E80E15E76a5bE5Df5F,
            0x3c20fbFD32243Dd9899301C84bCe17413EeE0A0C,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x3b3fB9C57858EF816833dC91565EFcd85D96f634] = LenderTokens(
            0xDE6eF6CB4aBd3A473ffC2942eEf5D84536F8E864,
            0x8C6FeaF5d58BA1A6541F9c4aF685f62bFCBaC3b1,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xC139190F447e929f090Edeb554D95AbB8b18aC1C] = LenderTokens(
            0xEc4ef66D4fCeEba34aBB4dE69dB391Bc5476ccc8,
            0xeA85a065F87FE28Aa8Fbf0D6C7deC472b106252C,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x917459337CaAC939D41d7493B3999f571D20D667] = LenderTokens(
            0x312ffC57778CEfa11989733e6E08143E7E229c1c,
            0xd90DA2Df915B87fE1621A7F2201FbF4ff2cCA031,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x14Bdc3A3AE09f5518b923b69489CBcAfB238e617] = LenderTokens(
            0x2eDff5AF94334fBd7C38ae318edf1c40e072b73B,
            0x22517fE16DEd08e52E7EA3423A2EA4995b1f1731,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x90D2af7d622ca3141efA4d8f1F24d86E5974Cc8F] = LenderTokens(
            0x5F9190496e0DFC831C3bd307978de4a245E2F5cD,
            0x48351fCc9536dA440AE9471220F6dC921b0eB703,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xC96dE26018A54D51c097160568752c4E3BD6C364] = LenderTokens(
            0xcCA43ceF272c30415866914351fdfc3E881bb7c2,
            0x4A35FD7F93324Cc48bc12190D3F37493437b1Eff,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c] = LenderTokens(
            0xAA6e91C82942aeAE040303Bf96c15a6dBcB82CA0,
            0x6c82c66622Eb360FC973D3F492f9D8E9eA538b08,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x9F56094C450763769BA0EA9Fe2876070c0fD5F77] = LenderTokens(
            0x5f4a0873a3A02f7C0CB0e13a1d4362a1AD90e751,
            0xc9AD8Dd111e6384128146467aAf92B81EC422848,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xBC6736d346a5eBC0dEbc997397912CD9b8FAe10a] = LenderTokens(
            0x38A5357Ce55c81add62aBc84Fb32981e2626ADEf,
            0x0D8486E1CAbf3C9407B3DdA0cfc4d9C3101fB683,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xD11c452fc99cF405034ee446803b6F6c1F6d5ED8] = LenderTokens(
            0x481a2acf3A72ffDc602A9541896Ca1DB87f86cf7,
            0x7EC9Afe70f8FD603282eBAcbc9058A83623E2899,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xbf5495Efe5DB9ce00f80364C8B423567e58d2110] = LenderTokens(
            0x4E2a4d9B3DF7Aae73b418Bd39F3af9e148E3F479,
            0x730318dB7b830d324fC3fEDDB1d212Ec64bD3141,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x68749665FF8D2d112Fa859AA293F07A622782F38] = LenderTokens(
            0x8A2b6f94Ff3A89a03E8c02Ee92b55aF90c9454A2,
            0xa665bB258D2a732C170dFD505924214c0b1AC74F,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xe6A934089BBEe34F832060CE98848359883749B3] = LenderTokens(
            0x285866acB0d60105B4Ed350a463361c2d9afA0E2,
            0x690Df181701C11C53EA33bBF303C25834b66bD14,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x62C6E813b9589C3631Ba0Cdb013acdB8544038B7] = LenderTokens(
            0x38C503a438185cDE29b5cF4dC1442FD6F074F1cc,
            0x2CE7e7b238985A8aD3863De03F200B245B0c1216,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x1F84a51296691320478c98b8d77f2Bbd17D34350] = LenderTokens(
            0xE728577e9a1Fe7032bc309B4541F58f45443866e,
            0x9D244A99801dc05cbC04183769c17056B8A1Ad53,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xE8483517077afa11A9B07f849cee2552f040d7b2] = LenderTokens(
            0xbe54767735fB7Acca2aa7E2d209a6f705073536D,
            0xA803414f84fCEF00e745bE7CC2A315908927f15D,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xacA92E438df0B2401fF60dA7E4337B687a2435DA] = LenderTokens(
            0xAa0200d169fF3ba9385c12E073c5d1d30434AE7b,
            0xE35e6A0D3AbC28289f5d4C2d262a133Df936b98D,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D] = LenderTokens(
            0x24Ab03a9a5Bc2C49E5523e8d915A3536ac38B91D,
            0xAEf73b04654931B94920a3D7AE62032b79fB6d0c,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xe343167631d89B6Ffc58B88d6b7fB0228795491D] = LenderTokens(
            0x7c0477d085ECb607CF8429f3eC91Ae5E1e460F4F,
            0x4f97B950a30321c181E974971E156E19fAD184A3,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0xAeBf0Bb9f57E89260d57f31AF34eB58657d96Ce0] = LenderTokens(
            0xE036478Da9A7ed89b56FE39A06e1FC1a4b38D4Ea,
            0x04142fc546D59838852873bba5C8827601A13FC8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x3de0ff76E8b528C092d47b9DaC775931cef80F49] = LenderTokens(
            0x81b76ff3FeD28BA0B4a5D4c76Bd5C13Bd0641d86,
            0x762Edb8D79b97487F82093f85059e42EeEf61E9e,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][0x9Bf45ab47747F4B4dD09B3C2c73953484b4eB375] = LenderTokens(
            0x1241ec22C9BdF16BA1Eb636F2a8de7e28A4343Cf,
            0xacD3d3FaCeA0424984F662827B988f4581a3cE31,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] = LenderTokens(
            0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE,
            0x8619d80FB0141ba7F184CbF22fd724116D9f7ffC,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6] = LenderTokens(
            0x191c10Aa4AF7C30e871E70C95dB0E4eb77237530,
            0x953A573793604aF8d41F306FEb8274190dB4aE0e,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x7F5c764cBc14f9669B88837ca1490cCa17c31607] = LenderTokens(
            0x625E7708f30cA75bfd92586e17077590C60eb4cD,
            0xFCCf3cAbbe80101232d343252614b6A3eE81C989,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x68f180fcCe6836688e9084f035309E29Bf0A2095] = LenderTokens(
            0x078f358208685046a11C85e8ad32895DED33A249,
            0x92b42c66840C7AD907b4BF74879FF3eF7c529473,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x4200000000000000000000000000000000000006] = LenderTokens(
            0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8,
            0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x94b008aA00579c1307B0EF2c499aD98a8ce58e58] = LenderTokens(
            0x6ab707Aca953eDAeFBc4fD23bA73294241490620,
            0xfb00AC187a8Eb5AFAE4eACE434F493Eb62672df7,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x76FB31fb4af56892A25e32cFC43De717950c9278] = LenderTokens(
            0xf329e36C7bF6E5E86ce2150875a84Ce77f477375,
            0xE80761Ea617F66F96274eA5e8c37f03960ecC679,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9] = LenderTokens(
            0x6d80113e533a2C0fe82EaBD35f1875DcEA89Ea97,
            0x4a1c3aD6Ed28a636ee1751C69071f6be75DEb8B8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x4200000000000000000000000000000000000042] = LenderTokens(
            0x513c7E3a9c69cA3e22550eF58AC1C0088e918FFf,
            0x77CA01483f379E58174739308945f044e1a764dc,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb] = LenderTokens(
            0xc45A479877e1e9Dfe9FcD4056c699575a1045dAA,
            0x34e2eD44EF7466D5f9E0b782B5c08b57475e7907,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0xc40F949F8a4e094D1b49a23ea9241D289B7b2819] = LenderTokens(
            0x8Eb270e296023E9D92081fdF967dDd7878724424,
            0xCE186F6Cccb0c955445bb9d10C59caE488Fea559,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0xdFA46478F9e5EA86d57387849598dbFB2e964b02] = LenderTokens(
            0x8ffDf2DE812095b1D19CB146E4c004587C0A0692,
            0xA8669021776Bc142DfcA87c21b4A52595bCbB40a,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x9Bcef72be871e61ED4fBbc7630889beE758eb81D] = LenderTokens(
            0x724dc807b04555b71ed48a6896b6F41593b8C637,
            0xf611aEb5013fD2c0511c9CD55c7dc5C1140741A6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.AAVE_V3][0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85] = LenderTokens(
            0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5,
            0x5D557B07776D12967914379C71a1310e917C7555,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AAVE_V3][0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82] = LenderTokens(
            0x4199CC1F5ed0d796563d7CcB2e036253E2C18281,
            0xE20dBC7119c635B1B51462f844861258770e0699,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AAVE_V3][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] = LenderTokens(
            0x9B00a09492a626678E5A3009982191586C444Df9,
            0x0E76414d433ddfe8004d2A7505d218874875a996,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AAVE_V3][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] = LenderTokens(
            0x56a7ddc4e848EbF43845854205ad71D5D5F72d3D,
            0x7b1E82F4f542fbB25D64c5523Fe3e44aBe4F2702,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AAVE_V3][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] = LenderTokens(
            0x2E94171493fAbE316b6205f1585779C887771E2F,
            0x8FDea7891b4D6dbdc746309245B316aF691A636C,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AAVE_V3][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] = LenderTokens(
            0x00901a076785e0906d1028c7d6372d247bec7d61,
            0xcDBBEd5606d9c5C98eEedd67933991dC17F0c68d,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AAVE_V3][0x55d398326f99059fF775485246999027B3197955] = LenderTokens(
            0xa9251ca9DE909CB71783723713B21E4233fbf1B1,
            0xF8bb2Be50647447Fb355e3a77b81be4db64107cd,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AAVE_V3][0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409] = LenderTokens(
            0x75bd1A659bdC62e4C313950d44A2416faB43E785,
            0xE628B8a123e6037f1542e662B9F55141a16945C8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AAVE_V3][0x26c5e01524d2E6280A48F2c50fF6De7e52E9611C] = LenderTokens(
            0xBDFd4E51D3c14a232135f04988a42576eFb31519,
            0x2c391998308c56D7572A8F501D58CB56fB9Fe1C5,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.GNOSIS][Lenders.AAVE_V3][0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1] = LenderTokens(
            0xa818F1B57c201E092C4A2017A91815034326Efd1,
            0x0c0fce05F2314540EcB095bF4D069e5E0ED90fF8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.GNOSIS][Lenders.AAVE_V3][0x6C76971f98945AE98dD7d4DFcA8711ebea946eA6] = LenderTokens(
            0x23e4E76D01B2002BE436CE8d6044b0aA2f68B68a,
            0x9D881f67F20B49243c98f53d2B9E91E39d02Ae09,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.GNOSIS][Lenders.AAVE_V3][0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb] = LenderTokens(
            0xA1Fa064A85266E2Ca82DEe5C5CcEC84DF445760e,
            0xBc59E99198DbA71985A66E1713cC89FFEC53f7FC,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.GNOSIS][Lenders.AAVE_V3][0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83] = LenderTokens(
            0xc6B7AcA6DE8a6044E0e32d0c841a89244A10D284,
            0x5F6f7B0a87CA3CF3d0b431Ae03EF3305180BFf4d,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.GNOSIS][Lenders.AAVE_V3][0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d] = LenderTokens(
            0xd0Dd6cEF72143E22cCED4867eb0d5F2328715533,
            0x281963D7471eCdC3A2Bd4503e24e89691cfe420D,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.GNOSIS][Lenders.AAVE_V3][0xcB444e90D8198415266c6a2724b7900fb12FC56E] = LenderTokens(
            0xEdBC7449a9b594CA4E053D9737EC5Dc4CbCcBfb2,
            0xb96404e475f337A7E98e4a541C9b71309BB66c5A,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.GNOSIS][Lenders.AAVE_V3][0xaf204776c7245bF4147c2612BF6e5972Ee483701] = LenderTokens(
            0x7a5c3860a77a8DC1b225BD46d0fb2ac1C6D191BC,
            0x8Fe06E1D8Aff42Bf6812CacF7854A2249a00bED7,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.GNOSIS][Lenders.AAVE_V3][0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0] = LenderTokens(
            0xC0333cb85B59a788d8C7CAe5e1Fd6E229A3E5a65,
            0x37B9Ad6b5DC8Ad977AD716e92F49e9D200e58431,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.GNOSIS][Lenders.AAVE_V3][0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73] = LenderTokens(
            0x3FdCeC11B4f15C79d483Aedc56F37D302837Cf4d,
            0x2766EEFE0311Bf7421cC30155b03d210BCE30dF8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063] = LenderTokens(
            0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE,
            0x8619d80FB0141ba7F184CbF22fd724116D9f7ffC,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x53E0bca35eC356BD5ddDFebbD1Fc0fD03FaBad39] = LenderTokens(
            0x191c10Aa4AF7C30e871E70C95dB0E4eb77237530,
            0x953A573793604aF8d41F306FEb8274190dB4aE0e,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174] = LenderTokens(
            0x625E7708f30cA75bfd92586e17077590C60eb4cD,
            0xFCCf3cAbbe80101232d343252614b6A3eE81C989,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6] = LenderTokens(
            0x078f358208685046a11C85e8ad32895DED33A249,
            0x92b42c66840C7AD907b4BF74879FF3eF7c529473,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619] = LenderTokens(
            0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8,
            0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0xc2132D05D31c914a87C6611C10748AEb04B58e8F] = LenderTokens(
            0x6ab707Aca953eDAeFBc4fD23bA73294241490620,
            0xfb00AC187a8Eb5AFAE4eACE434F493Eb62672df7,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0xD6DF932A45C0f255f85145f286eA0b292B21C90B] = LenderTokens(
            0xf329e36C7bF6E5E86ce2150875a84Ce77f477375,
            0xE80761Ea617F66F96274eA5e8c37f03960ecC679,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270] = LenderTokens(
            0x6d80113e533a2C0fe82EaBD35f1875DcEA89Ea97,
            0x4a1c3aD6Ed28a636ee1751C69071f6be75DEb8B8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x172370d5Cd63279eFa6d502DAB29171933a610AF] = LenderTokens(
            0x513c7E3a9c69cA3e22550eF58AC1C0088e918FFf,
            0x77CA01483f379E58174739308945f044e1a764dc,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x0b3F868E0BE5597D5DB7fEB59E1CADBb0fdDa50a] = LenderTokens(
            0xc45A479877e1e9Dfe9FcD4056c699575a1045dAA,
            0x34e2eD44EF7466D5f9E0b782B5c08b57475e7907,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x385Eeac5cB85A38A9a07A70c73e0a3271CfB54A7] = LenderTokens(
            0x8Eb270e296023E9D92081fdF967dDd7878724424,
            0xCE186F6Cccb0c955445bb9d10C59caE488Fea559,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x9a71012B13CA4d3D0Cdc72A177DF3ef03b0E76A3] = LenderTokens(
            0x8ffDf2DE812095b1D19CB146E4c004587C0A0692,
            0xA8669021776Bc142DfcA87c21b4A52595bCbB40a,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x85955046DF4668e1DD369D2DE9f3AEB98DD2A369] = LenderTokens(
            0x724dc807b04555b71ed48a6896b6F41593b8C637,
            0xf611aEb5013fD2c0511c9CD55c7dc5C1140741A6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0xE111178A87A3BFf0c8d18DECBa5798827539Ae99] = LenderTokens(
            0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5,
            0x5D557B07776D12967914379C71a1310e917C7555,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x4e3Decbb3645551B8A19f0eA1678079FCB33fB4c] = LenderTokens(
            0x6533afac2E7BCCB20dca161449A13A32D391fb00,
            0x44705f578135cC5d703b4c9c122528C73Eb87145,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0xE0B52e49357Fd4DAf2c15e02058DCE6BC0057db4] = LenderTokens(
            0x8437d7C167dFB82ED4Cb79CD44B7a32A1dd95c77,
            0x3ca5FA07689F266e907439aFd1fBB59c44fe12f6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0xa3Fa99A148fA48D14Ed51d610c367C61876997F1] = LenderTokens(
            0xeBe517846d0F36eCEd99C735cbF6131e1fEB775D,
            0x18248226C16BF76c032817854E7C83a2113B4f06,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x3A58a54C066FdC0f2D55FC9C89F0415C92eBf3C4] = LenderTokens(
            0xEA1132120ddcDDA2F119e99Fa7A27a0d036F7Ac9,
            0x6b030Ff3FB9956B1B69f475B77aE0d3Cf2CC5aFa,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0xfa68FB4628DFF1028CFEc22b4162FCcd0d45efb6] = LenderTokens(
            0x80cA0d8C38d2e2BcbaB66aA1648Bd1C7160500FE,
            0xB5b46F918C2923fC7f26DB76e8a6A6e9C4347Cf9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x03b54A6e9a984069379fae1a4fC4dBAE93B3bCCD] = LenderTokens(
            0xf59036CAEBeA7dC4b86638DFA2E3C97dA9FcCd40,
            0x77fA66882a8854d883101Fb8501BD3CaD347Fc32,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V3][0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359] = LenderTokens(
            0xA4D94019934D8333Ef880ABFFbF2FDd611C762BD,
            0xE701126012EC0290822eEA17B794454d1AF8b030,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AAVE_V3][0x50c42dEAcD8Fc9773493ED674b675bE577f2634b] = LenderTokens(
            0xe18Ab82c81E7Eecff32B8A82B1b7d2d23F1EcE96,
            0x07B1adFB7d5795Cf21baE8a77Eceb222F2FafBCE,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AAVE_V3][0x29219dd400f2Bf60E5a23d13Be72B486D4038894] = LenderTokens(
            0x578Ee1ca3a8E1b54554Da1Bf7C583506C4CD11c6,
            0x2273caBAd63b7D247A6b107E723c803fc49953A0,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AAVE_V3][0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38] = LenderTokens(
            0x6C5E14A212c1C3e4Baf6f871ac9B1a969918c131,
            0xF6089B790Fbf8F4812a79a31CFAbeB00B06BA7BD,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AAVE_V3][0xE5DA20F15420aD15DE0fa650600aFc998bbE3955] = LenderTokens(
            0xeAa74D7F42267eB907092AF4Bc700f667EeD0B8B,
            0x333cFdCB6457C409e4f0C88F3806252bEe5fe425,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.AAVE_V3][0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4] = LenderTokens(
            0xE977F9B2a5ccf0457870a67231F23BE4DaecfbDb,
            0x0049250D15A8550c5a14Baa5AF5B662a93a525B9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.AAVE_V3][0x493257fD37EDB34451f62EDf8D2a0C418852bA4C] = LenderTokens(
            0xC48574bc5358c967d9447e7Df70230Fdb469e4E7,
            0x8992DB58077fe8C7B80c1B3a738eAe8A7BdDbA34,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.AAVE_V3][0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91] = LenderTokens(
            0xb7b93bCf82519bB757Fd18b23A389245Dbd8ca64,
            0x98dC737eA0E9bCb254c3F98510a71c5E11F74238,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.AAVE_V3][0x703b52F2b28fEbcB60E1372858AF5b18849FE867] = LenderTokens(
            0xd4e607633F3d984633E946aEA4eb71f92564c1c9,
            0x6aD279F6523f6421fD5B0324a97D8F62eeCD80c8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.AAVE_V3][0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E] = LenderTokens(
            0xd6cD2c0fC55936498726CacC497832052A9B2D1B,
            0x6450fd7F877B5bB726F7Bc6Bf0e6ffAbd48d72ad,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.AAVE_V3][0xc1Fa6E2E8667d9bE0Ca938a54c7E0285E9Df924a] = LenderTokens(
            0xE818A67EE5c0531AFaa31Aa6e20bcAC36227A641,
            0xf31E1599b4480d07Fa96a7248c4f05cA84DA7fa8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.AAVE_V3][0xAD17Da2f6Ac76746EF261E835C50b2651ce36DA8] = LenderTokens(
            0xF3c9d58B76AC6Ee6811520021e9A9318c49E4CFa,
            0xDeBb4ddaaaB1676775214552a7a05D6A13f905Da,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.AAVE_V3][0xd4169E045bcF9a86cC00101225d9ED61D2F51af2] = LenderTokens(
            0x5722921bb6C37EaEb78b993765Aa5D79CC50052F,
            0x97deC07366Be72884331BE21704Fd93BF35286f9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.AAVE_V3][0x4c078361FC9BbB78DF910800A991C7c3DD2F6ce0] = LenderTokens(
            0x85ABAdDcae06efee2CB5F75f33b6471759eFDE24,
            0x13Bd89aF338f3c7eAE9a75852fC2F1ca28B4DDbF,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.AAVE_V3][0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000] = LenderTokens(
            0x7314Ef2CA509490f65F52CC8FC9E0675C66390b8,
            0x0110174183e13D5Ea59D7512226c5D5A47bA2c40,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.AAVE_V3][0xEA32A96608495e54156Ae48931A7c20f0dcc1a21] = LenderTokens(
            0x885C8AEC5867571582545F894A5906971dB9bf27,
            0x571171a7EF1e3c8c83d47EF1a50E225E9c351380,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.AAVE_V3][0xbB06DCA3AE6887fAbF931640f67cab3e3a16F4dC] = LenderTokens(
            0xd9fa75D14c26720d5ce7eE2530793a823e8f07b9,
            0x6B45DcE8aF4fE5Ab3bFCF030d8fB57718eAB54e5,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.AAVE_V3][0x420000000000000000000000000000000000000A] = LenderTokens(
            0x8acAe35059C9aE27709028fF6689386a44c09f3a,
            0x8Bb19e3DD277a73D4A95EE434F14cE4B92898421,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SONEIUM][Lenders.AAVE_V3][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x1bD45Cc20CE61BE344A64218E6Ade01E72b08f39,
            0xC52375A5A04C0ABe5a6Ca5F3a344be2415EF54dB,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SONEIUM][Lenders.AAVE_V3][0xbA9986D2381edf1DA03B0B9c1f8b00dc4AacC369] = LenderTokens(
            0xb2C9E934A55B58D20496A5019F8722a96d8A44d8,
            0xccE2594ea5bC482DB9b4826Ce25d0764fE56BfD8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SONEIUM][Lenders.AAVE_V3][0x3A337a6adA9d885b6Ad95ec48F9b75f197b5AE35] = LenderTokens(
            0xBAB0366ADdA6d2845c6BB5db4339A824350d24F7,
            0xb3B6f42Ef71DDd9348136FFBdF02B545c0d2B799,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.AAVE_V3][0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111] = LenderTokens(
            0xeAC30Ed8609F564aE65C809C4bf42dB2fF426D2C,
            0x0baF5974838114e7001D02782e6B1D8aEE1fc626,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.AAVE_V3][0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8] = LenderTokens(
            0x85d86061e94CE01D3DA0f9EFa289c86ff136125a,
            0x9c27A8ffacAbdEE0Ac5c415E018D295BB6444F0E,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.AAVE_V3][0x779Ded0c9e1022225f8E0630b35a9b54bE713736] = LenderTokens(
            0x7053bAD224F0C021839f6AC645BdaE5F8b585b69,
            0x5d9e4663d3d532179c404dBe9edF93045F89aDed,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.AAVE_V3][0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9] = LenderTokens(
            0xcb8164415274515867ec43CbD284ab5d6d2b304F,
            0xCea474BDa7Ad0a8F62e938a5563edfAEf7368Fc0,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.AAVE_V3][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0xb9aCA933C9c0aa854a6DBb7b12f0CC3FdaC15ee7,
            0x0169FD279c8c656037E5D199Cff8137f1e2d807c,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.AAVE_V3][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0xaf972F332FF79bd32A6CB6B54f903eA0F9b16C2a,
            0xc42B44c65bBe7AA8E5b02416918688c244ec7847,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.AAVE_V3][0xC96dE26018A54D51c097160568752c4E3BD6C364] = LenderTokens(
            0xfa14c9DE267b59A586043372bd98Ed99e3Ee0533,
            0x691AbCD512C1Cfef99442b0ACD3eD98Ee7F4e64E,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.AAVE_V3][0x051665f2455116e929b9972c36d23070F5054Ce0] = LenderTokens(
            0xF8400F3FA9cD9F9E84e93cD9De9f14EB7B5b59b5,
            0x2E20c5291CD675bFe52a533a6208588f5484999e,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.AAVE_V3][0x93e855643e940D025bE2e529272e4Dbd15a2Cf74] = LenderTokens(
            0x5cC6999aC46F4627309a7ce0F321a3f45D138ED5,
            0x7C5549DE0dEb930bAb1e11B075151a19e400605c,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.AAVE_V3][0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73] = LenderTokens(
            0x8917d4eE4609f991b559DAF8D0aD1b892c13B127,
            0xeE1eABe23fA42028809F587B8fE1936b154d2620,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0x4200000000000000000000000000000000000006] = LenderTokens(
            0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7,
            0x24e6e0795b3c7c71D965fCc4f371803d1c1DcA1E,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22] = LenderTokens(
            0xcf3D55c10DB69f28fD1A75Bd73f3D8A2d9c595ad,
            0x1DabC36f19909425f654777249815c073E8Fd79F,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA] = LenderTokens(
            0x0a1d576f3eFeF75b330424287a95A366e8281D54,
            0x7376b2F323dC56fCd4C191B34163ac8a84702DAB,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452] = LenderTokens(
            0x99CBC45ea5bb7eF3a5BC08FB1B7E56bB2442Ef0D,
            0x41A7C3f5904ad176dACbb1D99101F59ef0811DC1,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = LenderTokens(
            0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB,
            0x59dca05b6c26dbd64b5381374aAaC5CD05644C28,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A] = LenderTokens(
            0x7C307e128efA31F540F2E2d976C995E0B65F51F6,
            0x8D2e3F1f4b38AA9f1ceD22ac06019c7561B03901,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0xBdb9300b7CDE636d9cD4AFF00f6F009fFBBc8EE6,
            0x05e08702028de6AaD395DC6478b554a56920b9AD,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0xDD5745756C2de109183c6B5bB886F9207bEF114D,
            0xbc4f5631f2843488792e4F1660d0A51Ba489bdBd,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee] = LenderTokens(
            0x067ae75628177FD257c2B1e500993e1a0baBcBd1,
            0x38e59ADE183BbEb94583d44213c8f3297e9933e9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0xEDfa23602D0EC14714057867A78d01e94176BEA0] = LenderTokens(
            0x80a94C36747CF51b2FbabDfF045f6D22c1930eD1,
            0xe9541C77a111bCAa5dF56839bbC50894eba7aFcb,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0xecAc9C5F704e954931349Da37F60E39f515c11c1] = LenderTokens(
            0x90072A4aA69B5Eb74984Ab823EFC5f91e90b3a72,
            0xa2525b3f058846075506903d792d58C5a0D834c9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42] = LenderTokens(
            0x90DA57E0A6C0d166Bf15764E03b83745Dc90025B,
            0x03D01595769333174036832e18fA2f17C74f8161,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0x63706e401c06ac8513145b7687A14804d17f814b] = LenderTokens(
            0x67EAF2BeE4384a2f84Da9Eb8105C661C123736BA,
            0xcEC1Ea95dDEF7CFC27D3D9615E05b035af460978,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0x236aa50979D5f3De3Bd1Eeb40E81137F22ab794b] = LenderTokens(
            0xbcFFB4B3beADc989Bd1458740952aF6EC8fBE431,
            0x182cDEEC1D52ccad869d621bA422F449FA5809f5,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.AAVE_V3][0x660975730059246A68521a3e2FBD4740173100f5] = LenderTokens(
            0xD7424238CcbE7b7198Ab3cFE232e0271E22da7bd,
            0x57B8C05ee2cD9d0143eBC21FBD9288C39B9F716c,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb] = LenderTokens(
            0x5D72a9d9A9510Cd8cBdBA12aC62593A58930a948,
            0xCBBC427b5658672768E11BFDa00879839DB4785F,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x7519403E12111ff6b710877Fcd821D0c12CAF43A,
            0xEa650893085DAd858150915291645F57164A4257,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0xC1A318493fF07a68fE438Cee60a7AD0d0DBa300E,
            0xc7A92af2ca7b75FC608A8F0C08640dE5b339BfC0,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0x1B64B9025EEbb9A6239575dF9Ea4b9Ac46D4d193] = LenderTokens(
            0x5c43D6C075C7CF95fb188FB2977eeD3E3F2a92c2,
            0x20091c402C2933144Bd9a9B1B07dBEBf19c6d5A1,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0xA3D68b74bF0528fdD07263c60d6488749044914b] = LenderTokens(
            0xAf1a7a488c8348b41d5860C04162af7d3D38A996,
            0x34542B95Efdf2dFbD59978C2F620FBd7275E9323,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0x9895D81bB462A195b4922ED7De0e3ACD007c32CB] = LenderTokens(
            0xf1aB7f60128924d69f6d7dE25A20eF70bBd43d07,
            0x638d7db63cd5c902bDd9A91cf195870551c3c7B3,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0x93B544c330F60A2aa05ceD87aEEffB8D38FD8c9a] = LenderTokens(
            0xEa601A9FECF80bFC529F08A51bD8Cb0d72fc862A,
            0xD73253B18124837465b0c1fCB1A947d0542a991B,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0x02FCC4989B4C9D435b7ceD3fE1Ba4CF77BBb5Dd8] = LenderTokens(
            0x0b9A412c94f07223752031f75a20DDe542D63d5C,
            0xb2A5AD339d9687B5606b21B37F72f350e5BbC622,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0xe48D935e6C9e735463ccCf29a7F11e32bC09136E] = LenderTokens(
            0x140Bc58975DFba4D30fE65c4F6262a6c314683cf,
            0xE476310751953E3aC32bbe4fc6218748fe02c4d2,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0xe561FE05C39075312Aa9Bc6af79DdaE981461359] = LenderTokens(
            0x41c7aCCC0fB97470bFB48014bad52E0d99447E79,
            0xe5A29d07F3D532Cd16bD53376053C2aa5B320cB9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0xC4374775489CB9C56003BF2C9b12495fC64F0771] = LenderTokens(
            0xD4eE376C40EdC83832aAaFc18fC0272660F5e90b,
            0xDA5D1a9b7F515457638c01db13a18Bd3514fC4A6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0x6100E367285b01F48D07953803A2d8dCA5D19873] = LenderTokens(
            0x5aA4bc74811D672DA5308019dA4779f673e60B47,
            0x7ec35d7008682c33dBC6b214E01D919e8d441e48,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0xab509448ad489e2E1341e25CC500f2596464Cc82] = LenderTokens(
            0x53349cBeD7A3F851f0722Bf3Fa8f1b93fA939BeF,
            0xA4408E7C8b5D4481a2D8aD7Aa89f3576a6A4a5D6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.AAVE_V3][0x54Dc267be2839303ff1e323584A16e86CeC4Aa44] = LenderTokens(
            0x9326fA5a71C93D5De313c91C3b80D74d0c3a0F5A,
            0xA746feD5635787e2d97da1979c714BfcDf60fa1A,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] = LenderTokens(
            0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE,
            0x8619d80FB0141ba7F184CbF22fd724116D9f7ffC,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0xf97f4df75117a78c1A5a0DBb814Af92458539FB4] = LenderTokens(
            0x191c10Aa4AF7C30e871E70C95dB0E4eb77237530,
            0x953A573793604aF8d41F306FEb8274190dB4aE0e,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8] = LenderTokens(
            0x625E7708f30cA75bfd92586e17077590C60eb4cD,
            0xFCCf3cAbbe80101232d343252614b6A3eE81C989,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] = LenderTokens(
            0x078f358208685046a11C85e8ad32895DED33A249,
            0x92b42c66840C7AD907b4BF74879FF3eF7c529473,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] = LenderTokens(
            0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8,
            0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] = LenderTokens(
            0x6ab707Aca953eDAeFBc4fD23bA73294241490620,
            0xfb00AC187a8Eb5AFAE4eACE434F493Eb62672df7,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0xba5DdD1f9d7F570dc94a51479a000E3BCE967196] = LenderTokens(
            0xf329e36C7bF6E5E86ce2150875a84Ce77f477375,
            0xE80761Ea617F66F96274eA5e8c37f03960ecC679,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0xD22a58f79e9481D1a88e00c343885A588b34b68B] = LenderTokens(
            0x6d80113e533a2C0fe82EaBD35f1875DcEA89Ea97,
            0x4a1c3aD6Ed28a636ee1751C69071f6be75DEb8B8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x5979D7b546E38E414F7E9822514be443A4800529] = LenderTokens(
            0x513c7E3a9c69cA3e22550eF58AC1C0088e918FFf,
            0x77CA01483f379E58174739308945f044e1a764dc,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x3F56e0c36d275367b8C502090EDF38289b3dEa0d] = LenderTokens(
            0xc45A479877e1e9Dfe9FcD4056c699575a1045dAA,
            0x34e2eD44EF7466D5f9E0b782B5c08b57475e7907,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8] = LenderTokens(
            0x8Eb270e296023E9D92081fdF967dDd7878724424,
            0xCE186F6Cccb0c955445bb9d10C59caE488Fea559,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x93b346b6BC2548dA6A1E7d98E9a421B42541425b] = LenderTokens(
            0x8ffDf2DE812095b1D19CB146E4c004587C0A0692,
            0xA8669021776Bc142DfcA87c21b4A52595bCbB40a,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0xaf88d065e77c8cC2239327C5EDb3A432268e5831] = LenderTokens(
            0x724dc807b04555b71ed48a6896b6F41593b8C637,
            0xf611aEb5013fD2c0511c9CD55c7dc5C1140741A6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F] = LenderTokens(
            0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5,
            0x5D557B07776D12967914379C71a1310e917C7555,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x912CE59144191C1204E64559FE8253a0e49E6548] = LenderTokens(
            0x6533afac2E7BCCB20dca161449A13A32D391fb00,
            0x44705f578135cC5d703b4c9c122528C73Eb87145,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe] = LenderTokens(
            0x8437d7C167dFB82ED4Cb79CD44B7a32A1dd95c77,
            0x3ca5FA07689F266e907439aFd1fBB59c44fe12f6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33] = LenderTokens(
            0xeBe517846d0F36eCEd99C735cbF6131e1fEB775D,
            0x18248226C16BF76c032817854E7C83a2113B4f06,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0xEA1132120ddcDDA2F119e99Fa7A27a0d036F7Ac9,
            0x1fFD28689DA7d0148ff0fCB669e9f9f0Fc13a219,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x4186BFC76E2E237523CBC30FD220FE055156b41F] = LenderTokens(
            0x6b030Ff3FB9956B1B69f475B77aE0d3Cf2CC5aFa,
            0x80cA0d8C38d2e2BcbaB66aA1648Bd1C7160500FE,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AAVE_V3][0x6c84a8f1c29108F47a79964b5Fe888D4f4D0dE40] = LenderTokens(
            0x62fC96b27a510cF4977B59FF952Dc32378Cc221d,
            0xB5b46F918C2923fC7f26DB76e8a6A6e9C4347Cf9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.CELO_MAINNET][Lenders.AAVE_V3][0xcebA9300f2b948710d2653dD7B07f33A8B32118C] = LenderTokens(
            0xFF8309b9e99bfd2D4021bc71a362aBD93dBd4785,
            0xDbe517c0FA6467873B684eCcbED77217E471E862,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.CELO_MAINNET][Lenders.AAVE_V3][0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e] = LenderTokens(
            0xDeE98402A302e4D707fB9bf2bac66fAEEc31e8Df,
            0xE15324a9887999803b931Ac45aa89a94A9750052,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.CELO_MAINNET][Lenders.AAVE_V3][0xD8763CBa276a3738E6DE85b4b3bF5FDed6D6cA73] = LenderTokens(
            0x34c02571094e08E935B8cf8dC10F1Ad6795f1f81,
            0x5C2B7EB5886B3cEc5CCE1019E34493da33291aF5,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.CELO_MAINNET][Lenders.AAVE_V3][0x765DE816845861e75A25fCA122bb6898B8B1282a] = LenderTokens(
            0xBba98352628B0B0c4b40583F593fFCb630935a45,
            0x05Ee3d1fBACbDbA1259946033cd7A42FDFcCcF0d,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.CELO_MAINNET][Lenders.AAVE_V3][0x471EcE3750Da237f93B8E339c536989b8978a438] = LenderTokens(
            0xC3e77dC389537Db1EEc7C33B95Cf3beECA71A209,
            0xaEa37B42955De2Ba2E4AF6581E46349bCD3Ea2d6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.CELO_MAINNET][Lenders.AAVE_V3][0xD221812de1BD094f35587EE8E174B07B6167D9Af] = LenderTokens(
            0xf385280F36e009C157697D25E0B802EfaBfd789c,
            0x6508cff7c5FbA053Af00a4E894500e6fA00274B7,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0xd586E7F844cEa2F87f50152665BCbc2C279D8d70] = LenderTokens(
            0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE,
            0x8619d80FB0141ba7F184CbF22fd724116D9f7ffC,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x5947BB275c521040051D82396192181b413227A3] = LenderTokens(
            0x191c10Aa4AF7C30e871E70C95dB0E4eb77237530,
            0x953A573793604aF8d41F306FEb8274190dB4aE0e,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E] = LenderTokens(
            0x625E7708f30cA75bfd92586e17077590C60eb4cD,
            0xFCCf3cAbbe80101232d343252614b6A3eE81C989,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x50b7545627a5162F82A992c33b87aDc75187B218] = LenderTokens(
            0x078f358208685046a11C85e8ad32895DED33A249,
            0x92b42c66840C7AD907b4BF74879FF3eF7c529473,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB] = LenderTokens(
            0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8,
            0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7] = LenderTokens(
            0x6ab707Aca953eDAeFBc4fD23bA73294241490620,
            0xfb00AC187a8Eb5AFAE4eACE434F493Eb62672df7,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x63a72806098Bd3D9520cC43356dD78afe5D386D9] = LenderTokens(
            0xf329e36C7bF6E5E86ce2150875a84Ce77f477375,
            0xE80761Ea617F66F96274eA5e8c37f03960ecC679,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7] = LenderTokens(
            0x6d80113e533a2C0fe82EaBD35f1875DcEA89Ea97,
            0x4a1c3aD6Ed28a636ee1751C69071f6be75DEb8B8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE] = LenderTokens(
            0x513c7E3a9c69cA3e22550eF58AC1C0088e918FFf,
            0x77CA01483f379E58174739308945f044e1a764dc,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0xD24C2Ad096400B6FBcd2ad8B24E7acBc21A1da64] = LenderTokens(
            0xc45A479877e1e9Dfe9FcD4056c699575a1045dAA,
            0x34e2eD44EF7466D5f9E0b782B5c08b57475e7907,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x5c49b268c9841AFF1Cc3B0a418ff5c3442eE3F3b] = LenderTokens(
            0x8Eb270e296023E9D92081fdF967dDd7878724424,
            0xCE186F6Cccb0c955445bb9d10C59caE488Fea559,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x152b9d0FdC40C096757F570A51E494bd4b943E50] = LenderTokens(
            0x8ffDf2DE812095b1D19CB146E4c004587C0A0692,
            0xA8669021776Bc142DfcA87c21b4A52595bCbB40a,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a] = LenderTokens(
            0x724dc807b04555b71ed48a6896b6F41593b8C637,
            0xDC1fad70953Bb3918592b6fCc374fe05F5811B6a,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73] = LenderTokens(
            0xf611aEb5013fD2c0511c9CD55c7dc5C1140741A6,
            0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD] = LenderTokens(
            0x8a9FdE6925a839F6B1932d16B36aC026F8d3FbdB,
            0x5D557B07776D12967914379C71a1310e917C7555,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x6533afac2E7BCCB20dca161449A13A32D391fb00,
            0x6B4b37618D85Db2a7b469983C888040F7F05Ea3D,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0x44705f578135cC5d703b4c9c122528C73Eb87145,
            0x8437d7C167dFB82ED4Cb79CD44B7a32A1dd95c77,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3][0x7bFd4CA2a6Cf3A3fDDd645D10B323031afe47FF0] = LenderTokens(
            0x40B4BAEcc69B882e8804f9286b12228C27F8c9BF,
            0x3ca5FA07689F266e907439aFd1fBB59c44fe12f6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.LINEA][Lenders.AAVE_V3][0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f] = LenderTokens(
            0x787897dF92703BB3Fc4d9Ee98e15C0b8130Bf163,
            0x0e7543a9dA61b2E71fC880685eD2945B7426a689,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.LINEA][Lenders.AAVE_V3][0x3aAB2285ddcDdaD8edf438C1bAB47e1a9D05a9b4] = LenderTokens(
            0x37f7E06359F98162615e016d0008023D910bB576,
            0x74A1b56f5137b00AA0ADA1dD964a3A361Ecc32e9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.LINEA][Lenders.AAVE_V3][0x176211869cA2b568f2A7D4EE941E073a821EE1ff] = LenderTokens(
            0x374D7860c4f2f604De0191298dD393703Cce84f3,
            0x63aB166e6E1b6Fb705b6ca23686FaD9705EB3534,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.LINEA][Lenders.AAVE_V3][0xA219439258ca9da29E9Cc4cE5596924745e12B93] = LenderTokens(
            0x88231dfEC71D4FF5c1e466D08C321944A7adC673,
            0x4CEdfa47F7d0e9036110B850Ce49f4cd47b28a2F,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.LINEA][Lenders.AAVE_V3][0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F] = LenderTokens(
            0x58943d20e010d9E34C4511990e232783460d0219,
            0x81C1a619Be23050B3242B41a739e6B6CfDa56687,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.LINEA][Lenders.AAVE_V3][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0x935EfCBeFc1dF0541aFc3fE145134f8c9a0beB89,
            0x1fE3452CEF885724F8aDF1382ee17d05d7e01CaB,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.LINEA][Lenders.AAVE_V3][0x1Bf74C010E6320bab11e2e5A532b5AC15e0b8aA6] = LenderTokens(
            0x0C7921aB4888fd06731898b3fffFeB06781D5F4F,
            0x37a843725508243952950307CeacE7A9f5D5c280,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.LINEA][Lenders.AAVE_V3][0xD2671165570f41BBB3B0097893300b6EB6101E6C] = LenderTokens(
            0xCDD80E6211FC767352B198f827200C7e93d7Bb04,
            0xf3C806a402E4E9101373F76C05880EEAc91BB5b9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.LINEA][Lenders.AAVE_V3][0xacA92E438df0B2401fF60dA7E4337B687a2435DA] = LenderTokens(
            0x61B19879F4033c2b5682a969cccC9141e022823c,
            0x8619B395Fd96DCFe3f2711d8BF84b26338db0294,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SCROLL][Lenders.AAVE_V3][0x5300000000000000000000000000000000000004] = LenderTokens(
            0xf301805bE1Df81102C957f6d4Ce29d2B8c056B2a,
            0xfD7344CeB1Df9Cf238EcD667f4A6F99c6Ef44a56,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SCROLL][Lenders.AAVE_V3][0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4] = LenderTokens(
            0x1D738a3436A8C49CefFbaB7fbF04B660fb528CbD,
            0x3d2E209af5BFa79297C88D6b57F89d792F6E28EE,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SCROLL][Lenders.AAVE_V3][0xf610A9dfB7C89644979b4A0f27063E9e7d7Cda32] = LenderTokens(
            0x5B1322eeb46240b02e20062b8F0F9908d525B09c,
            0x8a035644322129800C3f747f54Db0F4d3c0A2877,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SCROLL][Lenders.AAVE_V3][0x01f0a31698C4d065659b9bdC21B3610292a1c506] = LenderTokens(
            0xd80A5e16DBDC52Bd1C947CEDfA22c562Be9129C8,
            0x009D88C6a6B4CaA240b71C98BA93732e26F2A55A,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.SCROLL][Lenders.AAVE_V3][0xd29687c813D741E2F938F4aC377128810E217b1b] = LenderTokens(
            0x25718130C2a8eb94e2e1FAFB5f1cDd4b459aCf64,
            0xFFbA405BBF25B2e6C454d18165F2fd8786858c6B,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HARMONY_MAINNET_SHARD_0][Lenders.AAVE_V3][0xEf977d2f931C1978Db5F6747666fa1eACB0d0339] = LenderTokens(
            0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE,
            0x8619d80FB0141ba7F184CbF22fd724116D9f7ffC,
            0xd94112B5B62d53C9402e7A60289c6810dEF1dC9B
        );
        lendingTokens[Chains.HARMONY_MAINNET_SHARD_0][Lenders.AAVE_V3][0x218532a12a389a4a92fC0C5Fb22901D1c19198aA] = LenderTokens(
            0x191c10Aa4AF7C30e871E70C95dB0E4eb77237530,
            0x953A573793604aF8d41F306FEb8274190dB4aE0e,
            0x89D976629b7055ff1ca02b927BA3e020F22A44e4
        );
        lendingTokens[Chains.HARMONY_MAINNET_SHARD_0][Lenders.AAVE_V3][0x985458E523dB3d53125813eD68c274899e9DfAb4] = LenderTokens(
            0x625E7708f30cA75bfd92586e17077590C60eb4cD,
            0xFCCf3cAbbe80101232d343252614b6A3eE81C989,
            0x307ffe186F84a3bc2613D1eA417A5737D69A7007
        );
        lendingTokens[Chains.HARMONY_MAINNET_SHARD_0][Lenders.AAVE_V3][0x3095c7557bCb296ccc6e363DE01b760bA031F2d9] = LenderTokens(
            0x078f358208685046a11C85e8ad32895DED33A249,
            0x92b42c66840C7AD907b4BF74879FF3eF7c529473,
            0x633b207Dd676331c413D4C013a6294B0FE47cD0e
        );
        lendingTokens[Chains.HARMONY_MAINNET_SHARD_0][Lenders.AAVE_V3][0x6983D1E6DEf3690C4d616b13597A09e6193EA013] = LenderTokens(
            0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8,
            0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351,
            0xD8Ad37849950903571df17049516a5CD4cbE55F6
        );
        lendingTokens[Chains.HARMONY_MAINNET_SHARD_0][Lenders.AAVE_V3][0x3C2B8Be99c50593081EAA2A724F0B8285F5aba8f] = LenderTokens(
            0x6ab707Aca953eDAeFBc4fD23bA73294241490620,
            0xfb00AC187a8Eb5AFAE4eACE434F493Eb62672df7,
            0x70eFfc565DB6EEf7B927610155602d31b670e802
        );
        lendingTokens[Chains.HARMONY_MAINNET_SHARD_0][Lenders.AAVE_V3][0xcF323Aad9E522B93F11c352CaA519Ad0E14eB40F] = LenderTokens(
            0xf329e36C7bF6E5E86ce2150875a84Ce77f477375,
            0xE80761Ea617F66F96274eA5e8c37f03960ecC679,
            0xfAeF6A702D15428E588d4C0614AEFb4348D83D48
        );
        lendingTokens[Chains.HARMONY_MAINNET_SHARD_0][Lenders.AAVE_V3][0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a] = LenderTokens(
            0x6d80113e533a2C0fe82EaBD35f1875DcEA89Ea97,
            0x4a1c3aD6Ed28a636ee1751C69071f6be75DEb8B8,
            0xF15F26710c827DDe8ACBA678682F3Ce24f2Fb56E
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3] = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
        lendingControllers[Chains.OP_MAINNET][Lenders.AAVE_V3] = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AAVE_V3] = 0x6807dc923806fE8Fd134338EABCA509979a7e0cB;
        lendingControllers[Chains.GNOSIS][Lenders.AAVE_V3] = 0xb50201558B00496A145fE76f7424749556E326D8;
        lendingControllers[Chains.POLYGON_MAINNET][Lenders.AAVE_V3] = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        lendingControllers[Chains.SONIC_MAINNET][Lenders.AAVE_V3] = 0x5362dBb1e601abF3a4c14c22ffEdA64042E5eAA3;
        lendingControllers[Chains.ZKSYNC_MAINNET][Lenders.AAVE_V3] = 0x78e30497a3c7527d953c6B1E3541b021A98Ac43c;
        lendingControllers[Chains.METIS_ANDROMEDA_MAINNET][Lenders.AAVE_V3] = 0x90df02551bB792286e8D4f13E0e357b4Bf1D6a57;
        lendingControllers[Chains.SONEIUM][Lenders.AAVE_V3] = 0xDd3d7A7d03D9fD9ef45f3E587287922eF65CA38B;
        lendingControllers[Chains.MANTLE][Lenders.AAVE_V3] = 0x458F293454fE0d67EC0655f3672301301DD51422;
        lendingControllers[Chains.BASE][Lenders.AAVE_V3] = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
        lendingControllers[Chains.PLASMA_MAINNET][Lenders.AAVE_V3] = 0x925a2A7214Ed92428B5b1B090F80b25700095e12;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.AAVE_V3] = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        lendingControllers[Chains.CELO_MAINNET][Lenders.AAVE_V3] = 0x3E59A31363E2ad014dcbc521c4a0d5757d9f3402;
        lendingControllers[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V3] = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        lendingControllers[Chains.LINEA][Lenders.AAVE_V3] = 0xc47b8C00b0f69a36fa203Ffeac0334874574a8Ac;
        lendingControllers[Chains.SCROLL][Lenders.AAVE_V3] = 0x11fCfe756c05AD438e312a7fd934381537D3cFfe;
        lendingControllers[Chains.HARMONY_MAINNET_SHARD_0][Lenders.AAVE_V3] = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_PRIME][0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0] = LenderTokens(
            0xC035a7cf15375cE2706766804551791aD035E0C2,
            0xE439edd2625772AA635B437C099C607B6eb7d35f,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_PRIME][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] = LenderTokens(
            0xfA1fDbBD71B0aA16162D76914d69cD8CB3Ef92da,
            0x91b7d78BF92db564221f6B5AeE744D1727d1Dd1e,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_PRIME][0xdC035D45d973E3EC169d2276DDab16f1e407384F] = LenderTokens(
            0x09AA30b182488f769a9824F15E6Ce58591Da4781,
            0x2D9fe18b6c35FE439cC15D932cc5C943bf2d901E,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_PRIME][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = LenderTokens(
            0x2A1FBcb52Ed4d9b23daD17E1E8Aed4BB0E6079b8,
            0xeD90dE2D824Ee766c6Fd22E90b12e598f681dc9F,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_PRIME][0xbf5495Efe5DB9ce00f80364C8B423567e58d2110] = LenderTokens(
            0x74e5664394998f13B07aF42446380ACef637969f,
            0x08e1bba76D27841dD91FAb4b3a636A0D5CF8c3E9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_PRIME][0x9D39A5DE30e57443BfF2A8307A4256c8797A3497] = LenderTokens(
            0xc2015641564a5914A17CB9A92eC8d8feCfa8f2D0,
            0x2ABbAab3EF4e4A899d39e7EC996b5715E76b399a,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_PRIME][0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f] = LenderTokens(
            0x18eFE565A5373f430e2F809b97De30335B3ad96A,
            0x18577F0f4A0B2Ee6F4048dB51c7acd8699F97DB8,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_PRIME][0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7] = LenderTokens(
            0x56D919E7B25aA42F3F8a4BC77b8982048F2E84B4,
            0x2c2163f120cf58631368981BC16e90190Bc6C644,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_PRIME][0xD11c452fc99cF405034ee446803b6F6c1F6d5ED8] = LenderTokens(
            0xce8c60fd8390eFCc3Fc66A3f0bd64BEb969e750E,
            0xe7ea6125490ae4594aD9B44D05dFF9F2A4343134,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_PRIME] = 0x4e033931ad43597d96D6bcc25c280717730B58B1;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_ETHER_FI][0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee] = LenderTokens(
            0xbe1F842e7e0afd2c2322aae5d34bA899544b29db,
            0x16264412CB72F0d16A446f7D928Dd0D822810048,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_ETHER_FI][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = LenderTokens(
            0x7380c583cDe4409eFF5DD3320D93a45D96B80E2e,
            0x9355032d747f1e08F8720CD01950E652eE15cdB7,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_ETHER_FI][0x6c3ea9036406852006290770BEdFcAbA0e23A0e8] = LenderTokens(
            0xdF7f48892244C6106EA784609f7de10AB36F9c7e,
            0xD2cf07dEE40d3D530D15b88d689f5cd97A31FC3D,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_ETHER_FI][0x853d955aCEf822Db058eb8505911ED77F175b99e] = LenderTokens(
            0x6914ECCf50837dC61b43ee478a9BD9B439648956,
            0xfd3aDA5AAbdc6531C7C2AC46c00eBf870f5a0E6B,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_ETHER_FI] = 0x0AA97c284e98396202b6A04024F5E2c65026F3c0;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_HORIZON][0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f] = LenderTokens(
            0x946281A2d0DD6e650d08f74833323D66AE4c8b12,
            0xdec2401c9B0B2E480e627E2a712C11AdDbf46E3e,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_HORIZON][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = LenderTokens(
            0x68215B6533c47ff9f7125aC95adf00fE4a62f79e,
            0x4139EcBe83d78ef5EFF0A6eDA6f894Be9D590FC7,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_HORIZON][0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD] = LenderTokens(
            0xE3190143Eb552456F88464662f0c0C4aC67A77eB,
            0xACE8a1c0eC12aE81814377491265b47F4eE5D3dD,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_HORIZON][0x43415eB6ff9DB7E26A15b704e7A3eDCe97d31C4e] = LenderTokens(
            0x4E58a2E433A739726134c83d2f07b2562e8dFdB3,
            0xC435b02dcBef2e9BdE55e28d39f53ddbe0760a2c,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_HORIZON][0x14d60E7FDC0D71d8611742720E4C50E7a974020c] = LenderTokens(
            0x08b798c40b9AB931356d9aB4235F548325C4cb80,
            0xA0Ec4758d806A3F41532C8E97Ea0c85940182B0f,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_HORIZON][0x136471a34f6ef19fE571EFFC1CA711fdb8E49f2b] = LenderTokens(
            0xc167932AC4EEc2B65844EF00D31b4550250536A5,
            0x818d560Bf1e54f92D1089710F9F4b29C2e6c9248,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_HORIZON][0x8c213ee79581Ff4984583C6a801e5263418C4b86] = LenderTokens(
            0x844f07AB09aa5dBDCE6A9b1206CE150E1eaDacCb,
            0x327f61fA4BE6F578DB5cc51e40da4eC4361a349c,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_HORIZON][0x5a0F93D040De44e78F251b03c43be9CF317Dcf64] = LenderTokens(
            0xB0EC6c4482Ac1Ef77bE239C0AC833CF37A27c876,
            0x7bd81B1e0137Fc0fa013b1De2Be81180814C5deb,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_HORIZON][0x2255718832bC9fD3bE1CaF75084F4803DA14FF01] = LenderTokens(
            0xE1CfD16b8E4B1C86Bb5b7A104cfEFbc7b09326dD,
            0xEAf93Fd541f11D2617C2915D02F7fe67bCa71d4f,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3_HORIZON] = 0xAe05Cd22df81871bc7cC2a04BeCfb516bFe332C8;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xdAC17F958D2ee523a2206206994597C13D831ec7] = LenderTokens(
            0x3Ed3B47Dd13EC9a98b44e6204A523E766B225811,
            0x531842cEbbdD378f8ee36D171d6cC9C4fcf475Ec,
            0xe91D55AB2240594855aBd11b3faAE801Fd4c4687
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] = LenderTokens(
            0x9ff58f4fFB29fA2266Ab25e75e2A8b3503311656,
            0x9c39809Dec7F95F5e0713634a4D0701329B3b4d2,
            0x51B039b9AFE64B78758f8Ef091211b5387eA717c
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] = LenderTokens(
            0x030bA81f1c18d280636F32af80b9AAd02Cf0854e,
            0xF63B34710400CAd3e044cFfDcAb00a0f32E33eCf,
            0x4e977830ba4bd783C0BB7F15d3e243f73FF57121
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e] = LenderTokens(
            0x5165d24277cD063F5ac44Efd447B27025e888f37,
            0x7EbD09022Be45AD993BAA1CEc61166Fcc8644d97,
            0xca823F78C2Dd38993284bb42Ba9b14152082F7BD
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xE41d2489571d322189246DaFA5ebDe1F4699F498] = LenderTokens(
            0xDf7FF54aAcAcbFf42dfe29DD6144A69b629f8C9e,
            0x85791D117A392097590bDeD3bD5abB8d5A20491A,
            0x071B4323a24E73A5afeEbe34118Cd21B8FAAF7C3
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984] = LenderTokens(
            0xB9D7CB55f463405CDfBe4E90a6D2Df01C2B92BF1,
            0x5BdB050A92CADcCfCDcCCBFC17204a1C9cC0Ab73,
            0xD939F7430dC8D5a427f156dE1012A56C18AcB6Aa
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9] = LenderTokens(
            0xFFC97d72E13E01096502Cb8Eb52dEe56f74DAD7B,
            0xF7DBA49d571745D9d7fcb56225B05BEA803EBf3C,
            0x079D6a3E844BcECf5720478A718Edb6575362C5f
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x0D8775F648430679A709E98d2b0Cb6250d2887EF] = LenderTokens(
            0x05Ec93c0365baAeAbF7AefFb0972ea7ECdD39CF1,
            0xfc218A6Dfe6901CB34B1a5281FC6f1b8e7E56877,
            0x277f8676FAcf4dAA5a6EA38ba511B7F65AA02f9F
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x4Fabb145d64652a948d72533023f6E7A623C7C53] = LenderTokens(
            0xA361718326c15715591c299427c62086F69923D9,
            0xbA429f7011c9fa04cDd46a2Da24dc0FF0aC6099c,
            0x4A7A63909A72D268b1D8a93a9395d098688e0e5C
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x6B175474E89094C44Da98b954EedeAC495271d0F] = LenderTokens(
            0x028171bCA77440897B824Ca71D1c56caC55b68A3,
            0x6C3c78838c761c6Ac7bE9F59fe808ea2A6E4379d,
            0x778A13D3eeb110A4f7bb6529F99c000119a08E92
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xF629cBd94d3791C9250152BD8dfBDF380E2a3B9c] = LenderTokens(
            0xaC6Df26a590F08dcC95D5a4705ae8abbc88509Ef,
            0x38995F292a6E31b78203254fE1cdd5Ca1010A446,
            0x943DcCA156b5312Aa24c1a08769D67FEce4ac14C
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xdd974D5C2e2928deA5F71b9825b8b646686BD200] = LenderTokens(
            0x39C6b3e42d6A679d7D776778Fe880BC9487C2EDA,
            0x6B05D1c608015Ccb8e205A690cB86773A96F39f1,
            0x9915dfb872778B2890a117DA1F35F335eb06B54f
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x514910771AF9Ca656af840dff83E8264EcF986CA] = LenderTokens(
            0xa06bC25B5805d5F8d82847D191Cb4Af5A3e873E0,
            0x0b8f12b1788BFdE65Aa1ca52E3e9F3Ba401be16D,
            0xFB4AEc4Cc858F2539EBd3D37f2a43eAe5b15b98a
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x0F5D2fB29fb7d3CFeE444a200298f468908cC942] = LenderTokens(
            0xa685a61171bb30d4072B338c80Cb7b2c865c873E,
            0x0A68976301e46Ca6Ce7410DB28883E309EA0D352,
            0xD86C74eA2224f4B8591560652b50035E4e5c0a3b
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2] = LenderTokens(
            0xc713e5E149D5D0715DcD1c156a020976e7E56B88,
            0xba728eAd5e496BE00DCF66F650b6d7758eCB50f8,
            0xC01C8E4b12a89456a9fD4e4e75B72546Bf53f0B5
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x408e41876cCCDC0F92210600ef50372656052a38] = LenderTokens(
            0xCC12AbE4ff81c9378D670De1b57F8e0Dd228D77a,
            0xcd9D82d33bd737De215cDac57FE2F7f04DF77FE0,
            0x3356Ec1eFA75d9D150Da1EC7d944D9EDf73703B7
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F] = LenderTokens(
            0x35f6B052C598d933D69A4EEC4D04c73A191fE6c2,
            0x267EB8Cf715455517F9BD5834AeAE3CeA1EBdbD8,
            0x8575c8ae70bDB71606A53AeA1c6789cB0fBF3166
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x57Ab1ec28D129707052df4dF418D58a2D46d5f51] = LenderTokens(
            0x6C5024Cd4F8A59110119C56f8933403A539555EB,
            0xdC6a3Ab17299D9C2A412B0e0a4C1f55446AE0817,
            0x30B0f7324feDF89d8eff397275F8983397eFe4af
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x0000000000085d4780B73119b644AE5ecd22b376] = LenderTokens(
            0x101cc05f4A51C0319f570d5E146a8C625198e636,
            0x01C0eb1f8c6F1C1bF74ae028697ce7AA2a8b0E92,
            0x7f38d60D94652072b2C44a18c0e14A481EC3C0dd
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = LenderTokens(
            0xBcca60bB61934080951369a648Fb03DF4F96263C,
            0x619beb58998eD2278e08620f97007e1116D5D25b,
            0xE4922afAB0BbaDd8ab2a88E0C79d884Ad337fcA6
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xD533a949740bb3306d119CC777fa900bA034cd52] = LenderTokens(
            0x8dAE6Cb04688C62d939ed9B68d32Bc62e49970b1,
            0x00ad8eBF64F141f1C81e9f8f792d3d1631c6c684,
            0x9288059a74f589C919c7Cf1Db433251CdFEB874B
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd] = LenderTokens(
            0xD37EE7e4f452C6638c96536e68090De8cBcdb583,
            0x279AF5b99540c1A3A7E3CDd326e19659401eF99e,
            0xf8aC64ec6Ff8E0028b37EB89772d21865321bCe0
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xba100000625a3754423978a60c9317c58a424e3D] = LenderTokens(
            0x272F97b7a56a387aE942350bBC7Df5700f8a4576,
            0x13210D4Fe0d5402bd7Ecbc4B5bC5cFcA3b71adB0,
            0xe569d31590307d05DA3812964F1eDd551D665a0b
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x8798249c2E607446EfB7Ad49eC89dD1865Ff4272] = LenderTokens(
            0xF256CC7847E919FAc9B808cC216cAc87CCF2f47a,
            0xfAFEDF95E21184E3d880bd56D4806c4b8d31c69A,
            0x73Bfb81D7dbA75C904f430eA8BAe82DB0D41187B
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xD5147bc8e386d91Cc5DBE72099DAC6C9b99276F5] = LenderTokens(
            0x514cd6756CCBe28772d4Cb81bC3156BA9d1744aa,
            0x348e2eBD5E962854871874E444F4122399c02755,
            0xcAad05C49E14075077915cB5C820EB3245aFb950
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919] = LenderTokens(
            0xc9BC48c72154ef3e5425641a3c747242112a46AF,
            0xB5385132EE8321977FfF44b60cDE9fE9AB0B4e6b,
            0x9C72B8476C33AE214ee3e8C20F0bc28496a62032
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xD46bA6D942050d489DBd938a2C909A5d5039A161] = LenderTokens(
            0x1E6bb68Acec8fefBD87D192bE09bb274170a0548,
            0xf013D90E4e4E3Baf420dFea60735e75dbd42f1e1,
            0x18152C9f77DAdc737006e9430dB913159645fa87
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x8E870D67F660D95d5be530380D0eC0bd388289E1] = LenderTokens(
            0x2e8F4bdbE3d47d7d7DE490437AeA9915D930F1A3,
            0xFDb93B3b10936cf81FA59A02A7523B6e2149b2B7,
            0x2387119bc85A74e0BBcbe190d80676CB16F10D4F
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x1494CA1F11D487c2bBe4543E90080AeBa4BA3C2b] = LenderTokens(
            0x6F634c6135D2EBD550000ac92F494F9CB8183dAe,
            0x4dDff5885a67E4EffeC55875a3977D7E60F82ae0,
            0xa3953F07f389d719F99FC378ebDb9276177d8A6e
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x853d955aCEf822Db058eb8505911ED77F175b99e] = LenderTokens(
            0xd4937682df3C8aEF4FE912A96A74121C0829E664,
            0xfE8F19B17fFeF0fDbfe2671F248903055AFAA8Ca,
            0x3916e3B6c84b161df1b2733dFfc9569a1dA710c2
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x956F47F50A910163D8BF957Cf5846D573E7f87CA] = LenderTokens(
            0x683923dB55Fead99A79Fa01A27EeC3cB19679cC3,
            0xC2e10006AccAb7B45D9184FcF5b7EC7763f5BaAe,
            0xd89cF9E8A858F8B4b31Faf793505e112d6c17449
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84] = LenderTokens(
            0x1982b2F5814301d4e9a8b0201555376e62F82428,
            0xA9DEAc9f00Dc4310c35603FCD9D34d1A750f81Db,
            0x66457616Dd8489dF5D0AFD8678F4A260088aAF55
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72] = LenderTokens(
            0x9a14e23A58edf4EFDcB360f68cd1b95ce2081a2F,
            0x176808047cc9b7A2C9AE202c593ED42dDD7C0D13,
            0x34441FFD1948E49dC7a607882D0c38Efd0083815
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0xa693B19d2931d498c5B318dF961919BB4aee87a5] = LenderTokens(
            0xc2e2152647F4C26028482Efaf64b2Aa28779EFC4,
            0xaf32001cf2E66C4C3af4205F6EA77112AA4160FE,
            0x7FDbfB0412700D94403c42cA3CAEeeA183F07B26
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B] = LenderTokens(
            0x952749E07d7157bb9644A894dFAF3Bad5eF6D918,
            0x4Ae5E4409C6Dbc84A00f9f89e4ba096603fb7d50,
            0xB01Eb1cE1Da06179136D561766fc2d609C5F55Eb
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x111111111117dC0aa78b770fA6A738034120C302] = LenderTokens(
            0xB29130CBcC3F791f077eAdE0266168E808E5151e,
            0xD7896C1B9b4455aFf31473908eB15796ad2295DA,
            0x1278d6ED804d59d2d18a5Aa5638DfD591A79aF0a
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][0x5f98805A4E8be255a32880FDeC7F6728C6568bA0] = LenderTokens(
            0xce1871f791548600cb59efbefFC9c38719142079,
            0x411066489AB40442d6Fc215aD7c64224120D33F2,
            0x39f010127274b2dBdB770B45e1de54d974974526
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063] = LenderTokens(
            0x27F8D03b3a2196956ED754baDc28D73be8830A6e,
            0x75c4d1Fb84429023170086f06E682DcbBF537b7d,
            0x2238101B7014C279aaF6b408A284E49cDBd5DB55
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174] = LenderTokens(
            0x1a13F4Ca1d028320A707D99520AbFefca3998b7F,
            0x248960A9d75EdFa3de94F7193eae3161Eb349a12,
            0xdeb05676dB0DB85cecafE8933c903466Bf20C572
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0xc2132D05D31c914a87C6611C10748AEb04B58e8F] = LenderTokens(
            0x60D55F02A771d515e077c9C2403a1ef324885CeC,
            0x8038857FD47108A07d1f6Bf652ef1cBeC279A2f3,
            0xe590cfca10e81FeD9B0e4496381f02256f5d2f61
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6] = LenderTokens(
            0x5c2ed810328349100A66B82b78a1791B101C9D61,
            0xF664F50631A6f0D72ecdaa0e49b0c019Fa72a8dC,
            0x2551B15dB740dB8348bFaDFe06830210eC2c2F13
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619] = LenderTokens(
            0x28424507fefb6f7f8E9D3860F56504E4e5f5f390,
            0xeDe17e9d79fc6f9fF9250D9EEfbdB88Cc18038b5,
            0xc478cBbeB590C76b01ce658f8C4dda04f30e2C6f
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270] = LenderTokens(
            0x8dF3aad3a84da6b69A4DA8aeC3eA40d9091B2Ac4,
            0x59e8E9100cbfCBCBAdf86b9279fa61526bBB8765,
            0xb9A6E29fB540C5F1243ef643EB39b0AcbC2e68E3
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0xD6DF932A45C0f255f85145f286eA0b292B21C90B] = LenderTokens(
            0x1d2a0E5EC8E5bBDCA5CB219e649B565d8e5c3360,
            0x1c313e9d0d826662F5CE692134D938656F681350,
            0x17912140e780B29Ba01381F088f21E8d75F954F9
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x385Eeac5cB85A38A9a07A70c73e0a3271CfB54A7] = LenderTokens(
            0x080b5BF8f360F624628E0fb961F4e67c9e3c7CF1,
            0x36e988a38542C3482013Bb54ee46aC1fb1efedcd,
            0x6A01Db46Ae51B19A6B85be38f1AA102d8735d05b
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x9a71012B13CA4d3D0Cdc72A177DF3ef03b0E76A3] = LenderTokens(
            0xc4195D4060DaEac44058Ed668AA5EfEc50D77ff6,
            0x773E0e32e7b6a00b7cA9daa85dfba9D61B7f2574,
            0xbC30bbe0472E0E86b6f395f9876B950A13B23923
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x85955046DF4668e1DD369D2DE9f3AEB98DD2A369] = LenderTokens(
            0x81fB82aAcB4aBE262fc57F06fD4c1d2De347D7B1,
            0x43150AA0B7e19293D935A412C8607f9172d3d3f3,
            0xA742710c0244a8Ebcf533368e3f0B956B6E53F7B
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x172370d5Cd63279eFa6d502DAB29171933a610AF] = LenderTokens(
            0x3Df8f92b7E798820ddcCA2EBEA7BAbda2c90c4aD,
            0x780BbcBCda2cdb0d2c61fd9BC68c9046B18f3229,
            0x807c97744e6C9452e7C2914d78f49d171a9974a0
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x0b3F868E0BE5597D5DB7fEB59E1CADBb0fdDa50a] = LenderTokens(
            0x21eC9431B5B55c5339Eb1AE7582763087F98FAc2,
            0x9CB9fEaFA73bF392C905eEbf5669ad3d073c3DFC,
            0x7Ed588DCb30Ea11A54D8a5E9645960262A97cd54
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.AAVE_V2][0x53E0bca35eC356BD5ddDFebbD1Fc0fD03FaBad39] = LenderTokens(
            0x0Ca2e42e8c21954af73Bc9af1213E4e81D6a669A,
            0xCC71e4A38c974e19bdBC6C0C19b63b8520b1Bb09,
            0x9fb7F546E60DDFaA242CAeF146FA2f4172088117
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V2][0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB] = LenderTokens(
            0x53f7c5869a859F0AeC3D334ee8B4Cf01E3492f21,
            0x4e575CacB37bc1b5afEc68a0462c4165A5268983,
            0x60F6A45006323B97d97cB0a42ac39e2b757ADA63
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V2][0xd586E7F844cEa2F87f50152665BCbc2C279D8d70] = LenderTokens(
            0x47AFa96Cdc9fAb46904A55a6ad4bf6660B53c38a,
            0x1852DC24d1a8956a0B356AA18eDe954c7a0Ca5ae,
            0x3676E4EE689D527dDb89812B63fAD0B7501772B3
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V2][0xc7198437980c041c805A1EDcbA50c1Ce5db95118] = LenderTokens(
            0x532E6537FEA298397212F09A61e03311686f548e,
            0xfc1AdA7A288d6fCe0d29CcfAAa57Bc9114bb2DbE,
            0x9c7B81A867499B7387ed05017a13d4172a0c17bF
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V2][0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664] = LenderTokens(
            0x46A51127C3ce23fb7AB1DE06226147F446e4a857,
            0x848c080d2700CBE1B894a3374AD5E887E5cCb89c,
            0x5B14679135dbE8B02015ec3Ca4924a12E4C6C85a
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V2][0x63a72806098Bd3D9520cC43356dD78afe5D386D9] = LenderTokens(
            0xD45B7c061016102f9FA220502908f2c0f1add1D7,
            0x8352E3fd18B8d84D3c8a1b538d788899073c7A8E,
            0x66904E4F3f44e3925D22ceca401b6F2DA085c98f
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V2][0x50b7545627a5162F82A992c33b87aDc75187B218] = LenderTokens(
            0x686bEF2417b6Dc32C50a3cBfbCC3bb60E1e9a15D,
            0x2dc0E35eC3Ab070B8a175C829e23650Ee604a9eB,
            0x3484408989985d68C9700dc1CFDFeAe6d2f658CF
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V2][0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7] = LenderTokens(
            0xDFE521292EcE2A4f44242efBcD66Bc594CA9714B,
            0x66A0FE52Fb629a6cB4D10B8580AFDffE888F5Fd4,
            0x2920CD5b8A160b2Addb00Ec5d5f4112255d4ae75
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2] = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
        lendingControllers[Chains.POLYGON_MAINNET][Lenders.AAVE_V2] = 0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf;
        lendingControllers[Chains.AVALANCHE_C_CHAIN][Lenders.AAVE_V2] = 0x4F01AeD16D97E3aB5ab2B501154DC9bb0F1A5A2C;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9] = LenderTokens(
            0xF36AFb467D1f05541d998BBBcd5F7167D67bd8fC,
            0x334a542b51212b8Bcd6F96EfD718D55A9b7D1c35,
            0xEe8D412A4EF6613c08889f9CD1Fd7D4a065f9A8B
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE] = LenderTokens(
            0xE71cbaaa6B093FcE66211E6f218780685077D8B5,
            0xaC3c14071c80819113DF501E1AB767be910d5e5a,
            0xEA8BD20f6c5424Ab4acf132c70b6C7355e11F62e
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0xCAbAE6f6Ea1ecaB08Ad02fE02ce9A44F09aebfA2] = LenderTokens(
            0x44CCCBbD7A5A9e2202076ea80C185DA0058f1715,
            0x42f9F9202D5F4412148662Cf3bC68D704c8E354f,
            0x1817Cde5CD6423C3b87039e1CB000BB2aC4E05c7
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111] = LenderTokens(
            0x787Cb0D29194f0fAcA73884C383CF4d2501bb874,
            0x5DF9a4BE4F9D717b2bFEce9eC350DcF4cbCb91d8,
            0x0cA5e3CD5f3273B066422291edDa3768451FbB68
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8] = LenderTokens(
            0x683696523512636B46A826A7e3D1B0658E8e2e1c,
            0x18d3E4F9951fedcdDD806538857eBED2F5F423B7,
            0xafefc53Be7e32C7510f054Abb1ec5E44C03fCCaB
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0xcDA86A272531e8640cD7F1a92c01839911B90bb0] = LenderTokens(
            0x0e927Aa52A38783C1Fd5DfA5c8873cbdBd01D2Ca,
            0xd739fB7a3b652306d00F92b20439aFC637650254,
            0x614110493CEAe1171532eB635242E4ca71CcBBa2
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x2CfA1e69C8A8083Aa52CfCF22d8caFF7521E1E7E,
            0x08C830f79917205Ff1605325FcFbb3eFC0c16cB5,
            0x10475947ABA834a0DbE60910eE787968B3e14917
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0xC96dE26018A54D51c097160568752c4E3BD6C364] = LenderTokens(
            0xDef3542BB1B2969c1966DD91ebc504f4b37462FE,
            0x874712C653AaAa7cfB201317f46E00238C2649bb,
            0x08FC23aF290D538647aa2836C5B3CF2fB3313759
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA] = LenderTokens(
            0x68a1b2756B41CE837d73A801E18a06E13eac50e1,
            0x880A809CA9dc0A35F5015d31f1f2273A489695Eb,
            0x2Ab8f08a60C17F801BF3CDd1373fD40e99f4F9fd
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a] = LenderTokens(
            0x90F22aa619217765c8eA84B18130fF60ad0d5dE1,
            0xA1D2E7033D691A2b87A92f95C6735fDbC2032B9A,
            0x20EFcCbDA64Abc26B96f0AeBe475AA1dB9a984bd
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0x8e3f5E745A030a384fbd19c97a56Da5337147376,
            0x48B6C9ad51009061f02bA36cddC4bF5FfD08519E,
            0xA74F820DeEEE37A963C826395B67cf8c9E66eca0
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE] = 0xCFa5aE7c2CE8Fadc6426C1ff872cA45378Fb7cF3;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_CMETH][0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA] = LenderTokens(
            0xDd085C6ab6d106A2dB5188Da7ACe1A8D8eeF0D8b,
            0xEF3D5c731f2c232d37263Ebacd260fd185908f1F,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_CMETH][0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111] = LenderTokens(
            0x49baC03Ed969902f79c3198FDbFfE4DC8c897D66,
            0xEA68dAAB414D6c702EeD8b05FAb4c7e0c2ba151c,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_CMETH] = 0xd9a41322336133f2b026a65F2426647BD0Bf690C;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_SUSDE][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0x990E45784520C3ff1ebD67976Db07087Bcf9FE9b,
            0x96E48331ca2E826E7d1dF9cF6c32789EFfAd8B4a,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_SUSDE][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x0ABC61618A2E35c5cDA43bF6c51164f3E799fa29,
            0x4D7eb17Aa7eAe225A921877c9a7a8aF0102C2260,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_SUSDE] = 0xA9c90b947a45E70451a9C16a8D5BeC2F855DbD1d;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_SUSDE_USDT][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0xf93bC96f96Bb12A5F2461990ba2DE322001d1314,
            0xdc5e6851e2974E9aECE4614a20162c43F7fe05fA,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_SUSDE_USDT][0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE] = LenderTokens(
            0xA5309F42Ca457B2145092ac7CceF33838232c187,
            0x5b19cDF2Ba4F9c23e4eA1CCA74D6E2B3F21F02AB,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_SUSDE_USDT] = 0x82ca5d1117C8499b731423711272C5ad05Ad693a;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_METH_WETH][0xcDA86A272531e8640cD7F1a92c01839911B90bb0] = LenderTokens(
            0x69871F4C3081dC1747e19c86273CB7827FEf4c52,
            0xdAf138f0aEc91863c3BcF579B03a58B40A208bcD,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_METH_WETH][0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111] = LenderTokens(
            0xe12Ebe0f7BB0264DdE0b7dFd071Eb6C08510988C,
            0x87AA23A250033d68149076bA99A3a17b0E226936,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_METH_WETH] = 0x9CdF3c151BE88921544902088fdb54DDf08431d1;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_METH_USDE][0xcDA86A272531e8640cD7F1a92c01839911B90bb0] = LenderTokens(
            0x025606eD9ed50e14F7D26dfF0Fc8a6A2B7149Dd8,
            0xd943Da6F6Cb40AF1c367516E1364a790A9073Ac6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_METH_USDE][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x59B2F0AaE2128610B0AA8f10f46337c039c589C6,
            0x9A0834A893AD596B8Ed295B9d4b3a2237C7c6343,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_METH_USDE] = 0xA11A13DE301C3f17c3892786720179750a25450A;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_CMETH_WETH][0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA] = LenderTokens(
            0x3A128c1EdbCaA8dA3a68d9C35621956FeD54B7Fb,
            0x96B76C21fbdbF85f486f847207b197b1F5e456de,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_CMETH_WETH][0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111] = LenderTokens(
            0xC67cf25FC70d3F95eec7795fD35b9eF8BBd1bD73,
            0x7a09d7C669C325d88a2afee9bE17D4f6517acdC7,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_CMETH_WETH] = 0x6815B0570ea49ccC09F4d910787b0993013DBDAA;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_CMETH_USDE][0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA] = LenderTokens(
            0x55c46Af22B64b8A466433730cEC1F2F1F79E7C1F,
            0x71FE3d4d85DC47e773424917D04Fb09C52D5d5c6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_CMETH_USDE][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x422028e5af77909c6AE37fF9afa413916635bee4,
            0x2E92474289000679b20A8fb4e6C9356ab10C1a6e,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_CMETH_USDE] = 0xEE50fb458a41C628E970657e6d0f01728c64545D;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_CMETH_WMNT][0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA] = LenderTokens(
            0x04Af8b7419bE56381F4fb97326f77312378e31f3,
            0xe0c90dc5b22a4eEe1aA7C8B5b17ddd75F2f694e4,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_CMETH_WMNT][0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8] = LenderTokens(
            0x7128883bd1fDB932D4DAa4676be96a4378559f8A,
            0x24c04f2e3B6f2D66D4E823cdb2331291BE246012,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_CMETH_WMNT] = 0x256eCC6C2b013BFc8e5Af0AD9DF8ebd10122d018;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_FBTC_WETH][0xC96dE26018A54D51c097160568752c4E3BD6C364] = LenderTokens(
            0x6F057dDe1D984C2850E48d083D07629fb5192ea8,
            0x3cDfC22b8740aFBcfbf610BA906CA751246243CD,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_FBTC_WETH][0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111] = LenderTokens(
            0xe37f6909c507741005BAC1D2C74Cd17e16a0caEf,
            0xD8902164CB06e217a81de80307d0e86B30463941,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_FBTC_WETH] = 0x9f2eb80B3c49A5037Fa97d9Ff85CdE1cE45A7fa0;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_FBTC_USDE][0xC96dE26018A54D51c097160568752c4E3BD6C364] = LenderTokens(
            0x7fdAcA61aE0a320a8Da3B4d67dEBD6554FA1bC56,
            0x21bD8aFEfE853Cb493dc6d56cc1473C367845732,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_FBTC_USDE][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0xd37101aaD875Ee1b1C630cB080752Ae19ae284Ac,
            0x1775233BAe456DB49ECeb351A9dDa0c21d3D8011,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_FBTC_USDE] = 0x42C5EbFD934923Cc2aB6a3FD91A0d92B6064DFBc;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_FBTC_WMNT][0xC96dE26018A54D51c097160568752c4E3BD6C364] = LenderTokens(
            0x835173165E78d6dFd39eb59FB651A961E3729643,
            0x27194A3A5a8F68745C1De6ad8D4F567551aF0AC4,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_FBTC_WMNT][0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8] = LenderTokens(
            0x395eE48E72b63CC63cb1E9725A6EB9F6e0e9104e,
            0x4D43A0ce8d268B969b22d640Ede588612779a6a7,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_FBTC_WMNT] = 0x5CAd26932A8D17Ba0540EeeCb3ABAdf7722DA9a0;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_WMNT_WETH][0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8] = LenderTokens(
            0x3B7F9b064fC284EbAA2349be4831853bE71a39C7,
            0x3D2db868Ae6bF09D05D40c2A5c71bF51BA5d6eCB,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_WMNT_WETH][0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111] = LenderTokens(
            0x9C8f2331365CC9147d4a8B7347123664CC8Aa0A8,
            0xB11EcAc1ca15A01a8E3e852B254a9a1bB7884F95,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_WMNT_WETH] = 0xeaFF9A5F8676D20F5F1C391902d9584C1b6f33f5;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_WMNT_USDE][0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8] = LenderTokens(
            0xF1965ceC21BF576F4DaA0ac56d8512b60C3CAE8D,
            0x0Ea491b40FCB5e596A6890522391bbaEFff6B7c1,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_WMNT_USDE][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x6B45202AF001b7C89Df38d9a9BCb1E3F1F286aB2,
            0x28C1EecF3B7DcE7235B1e0985f73F89De1c7D783,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_WMNT_USDE] = 0xecce86d3D3f1b33Fe34794708B7074CDe4aBe9d4;
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_PT_CMETH][0x698eB002A4Ec013A33286f7F2ba0bE3970E66455] = LenderTokens(
            0x4715A0ED5678D9cd1056856B8ec3966b8995Be68,
            0xd50Da2cf791F88AEdAC6b357af3bF99F6818EaE5,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.MANTLE][Lenders.LENDLE_PT_CMETH][0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111] = LenderTokens(
            0x4bb0a2766705922EB0232Ff3d3Ec4717d2EfdC31,
            0x46897B857F7B4423bdace4B6a214afEfd02deFF9,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.MANTLE][Lenders.LENDLE_PT_CMETH] = 0x5d7b73f9271c40ff737f98B8F818e7477761041f;
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.HANA][0x07d83526730c7438048D55A4fc0b850e2aaB6f0b] = LenderTokens(
            0x5C9bC967E338F48535c3DF7f80F2DB0A366D36b2,
            0x0247606c3D3F62213bbC9D7373318369e6860eb1,
            0x56EcD6eC282e650Be8405AD374fbEB5bEE5Ed616
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.HANA][0xA51894664A773981C6C112C43ce576f315d5b1B6] = LenderTokens(
            0xacd2E13C933aE1EF97698f00D14117BB70C77Ef1,
            0xf1777EAD4098F574c68E59905588f3C9875251ed,
            0x7379c947f186b1023D3c51CA997Dd74aD7EaD003
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.HANA][0xA9d23408b9bA935c230493c40C73824Df71A0975] = LenderTokens(
            0x67F1E0A9c9D540F61D50B974DBd63aABf636a296,
            0x1592Ff6f057d65a17Be56116e2B3cbfD4d2314C2,
            0x0B56C272ED45016563096cde3a67B261dd81892b
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.HANA][0x19e26B0638bf63aa9fa4d14c6baF8D52eBE86C5C] = LenderTokens(
            0x5F438F142225AAB92d6D234B9df3180891BB52C4,
            0xe5e8fe8e8891123Ff9994734c3dcdCa7500B3D79,
            0x85E0A512bCF466f90AC7f46f0202917b9c250fC0
        );
        lendingControllers[Chains.TAIKO_ALETHIA][Lenders.HANA] = 0x4aB85Bf9EA548410023b25a13031E91B4c4f3b91;
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9] = LenderTokens(
            0x833b5C0379A597351c6Cd3eFE246534bf3aE5f9F,
            0xaA9c890CA3E6B163487dE3C11847B50e48230b45,
            0xB41Cf1EEAdfD17FBc0086E9e856f1ac5460064d2
        );
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE] = LenderTokens(
            0x893DA3225a2FCF13cCA674d1A1bb5a2eA1F3DD14,
            0xc799FE29b67599010A55Ec14a8031aF2a2521470,
            0x61627C3E37A4e57A4Edb5cd52Ce8221d9C5bDA3d
        );
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0xCAbAE6f6Ea1ecaB08Ad02fE02ce9A44F09aebfA2] = LenderTokens(
            0xF91798762cc61971df6Df0e15F0904e174387477,
            0xd632fd1D737c6Db356D747D09642Bef8Ae453f4D,
            0xBc9B223D335c624f55C8b3a70f883FfEFB890A0E
        );
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111] = LenderTokens(
            0xc3B515BCa486520483EF182c3128F72ce270C069,
            0x45cccE9bC8e883ef7805Ea73B88D5D528C7CEc55,
            0xFbacE7bf40Dd1B9158236a23e96C11eBD03a2D42
        );
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8] = LenderTokens(
            0x067DDc903148968d49AbC3144fd7619820F16949,
            0x4C3c0650DdCB767D71c91fA89ee9e5a2CD335834,
            0x6110868e963F8Badf4D79Bc79C8Ac1e13cd59735
        );
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0xcDA86A272531e8640cD7F1a92c01839911B90bb0] = LenderTokens(
            0xBb406187C01cC1c9EAf9d4b5C924b7FA37aeCEFD,
            0x00dFD5F920CCf08eB0581D605BAb413d289c21b4,
            0x2D422c5EaD5fA3c26aeC97D070343353e2086A1d
        );
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x7bDb0095429F8eFf1Efb718aABc912B2489Ba5b3,
            0xcbE019C9C44954D388602A99a45A1d7DA61321CF,
            0x7F9C39386bE3F6A8C1753B5FbE8c96F7eaEF88e1
        );
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0x5bE26527e817998A7206475496fDE1E68957c5A6] = LenderTokens(
            0xFdD2eBc184b4ff6dF14562715452E970c82Fe49A,
            0x2D55f5558AEa4c25Fcc1Ff78b10265755AFF3856,
            0xe0ae10fB6cB1A366C56204aFe1ae2a94a0ed9A11
        );
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0xC96dE26018A54D51c097160568752c4E3BD6C364] = LenderTokens(
            0x491F8FBC6b9a5db31c959a702aB6A0dCBEA73a48,
            0xd2ea6612f6c7c11626F7D5D801D08B53BCe52511,
            0x88140812eE16B48447eAF7BA9A5649D1F9A2d949
        );
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA] = LenderTokens(
            0x76f727F55074931221Fc88a188B7915084011dCF,
            0x0aa17f21dC8977CDf0141e35543f094fB9eDaECE,
            0x5625062966B5c7E36cDA5A7e18c5c8D2Fd2bfF98
        );
        lendingTokens[Chains.MANTLE][Lenders.AURELIUS][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0x32670A5337ae105A67312006f190503A0bee4DD2,
            0x899Bf182cAbA1038205d32F22DD88490dAa85826,
            0x37694C364560e8736c80c0CF27111F9Efc7f8cf3
        );
        lendingControllers[Chains.MANTLE][Lenders.AURELIUS] = 0x7c9C6F5BEd9Cfe5B9070C7D3322CF39eAD2F9492;
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.TAKOTAKO][0x07d83526730c7438048D55A4fc0b850e2aaB6f0b] = LenderTokens(
            0x79a741EBFE9c323CF63180c405c050cdD98c21d8,
            0x72C6bDf69952b6bc8aCc18c178d9E03EAc5eaD50,
            0x4617e7cD8387cB5CC9f2B71055b012C3691bf8cC
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.TAKOTAKO][0x9c2dc7377717603eB92b2655c5f2E7997a4945BD] = LenderTokens(
            0x86a76CB11B5B17e048360a9D6d04135FC9138e12,
            0x3b8c0590B95021509CC7bc8c905166f9D0C471a2,
            0xFFAC48Df9C21769CF2aAd19fE48916c5A7d99e25
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.TAKOTAKO][0xA51894664A773981C6C112C43ce576f315d5b1B6] = LenderTokens(
            0x6Afa285ab05657f7102F66F1B384347aEF3Ef6Aa,
            0x19871b9911ddbd422e06F66427768f9B65d36F81,
            0x3194b9f616d289DAFC6E05a8d4Fc3e985a4f2Be8
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.TAKOTAKO][0xA9d23408b9bA935c230493c40C73824Df71A0975] = LenderTokens(
            0xbbFa45a92d9d071554B59D2d29174584D9b06bc3,
            0x0f0244337f1215E6D8e13Af1b5ae639244d8a6f6,
            0x9fe2D5104e1299A31c62dB35306233DC1BbB1f14
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.TAKOTAKO][0x2DEF195713CF4a606B49D07E520e22C17899a736] = LenderTokens(
            0x7945F98240b310bD21F8814bdCEeBA6775a9A36A,
            0x820C66D8316856655AdB42B3b6cB6a1728D29567,
            0x3340ca54dffB17dFEa5be60802757B84c31dAd2d
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.TAKOTAKO][0xf7fB2DF9280eB0a76427Dc3b34761DB8b1441a49] = LenderTokens(
            0x418D47E8283BC7867a6e42a2F62425F8798f060e,
            0xA6325b88bF0c69679c93F9750b1CB62ff63333eE,
            0xE1eB0d79dfAaBB0837b4705b7B1195912bd99779
        );
        lendingControllers[Chains.TAIKO_ALETHIA][Lenders.TAKOTAKO] = 0x3A2Fd8a16030fFa8D66E47C3f1C0507c673C841e;
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.TAKOTAKO_ETH][0xA51894664A773981C6C112C43ce576f315d5b1B6] = LenderTokens(
            0x46A0E9885E848e90fd353622762f1a550a0393f1,
            0xE8f7a8a185d6f9401eF0cCb6c4f9a0793eba57EE,
            0xD0029bcA9a299a7a684f1795330B4f4D4681cB3F
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.TAKOTAKO_ETH][0x756B6574b3162077A630895995B443aA68cD2015] = LenderTokens(
            0xfd789Fc41f673e5Be0f6A0768899eC79Db86AAc5,
            0xb87c9C0394cbA6a3E4f72fa98AEbCe27c8BEC4E1,
            0x7b81391C0d3d04DA0239C56f9A9dE762120FB695
        );
        lendingControllers[Chains.TAIKO_ALETHIA][Lenders.TAKOTAKO_ETH] = 0xe882a56b8c0C1a5561Febf846614B88718Dc5D9E;
        lendingTokens[Chains.MORPH][Lenders.QUOKKA_LEND][0xe34c91815d7fc18A9e2148bcD4241d0a5848b693] = LenderTokens(
            0x72f29e8e47859d2754109A61C23A11075C22E1CD,
            0xF907406bcC3DDc77f20974Bc70dDeFd31833e961,
            0x5985DDeBE17943366137F697912F1A0Dd909aE6A
        );
        lendingTokens[Chains.MORPH][Lenders.QUOKKA_LEND][0xc7D67A9cBB121b3b0b9c053DD9f469523243379A] = LenderTokens(
            0x655AE1B344992d13EA18e08ec5D7D55B379b2988,
            0x7d2e61f2b67803B9C446fb8603bff3Cc40dD7172,
            0xbc1348440a46DCE165B3EDBe197631f51CF94aA2
        );
        lendingTokens[Chains.MORPH][Lenders.QUOKKA_LEND][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0xD887bE68019a802c213C2ebbd82E77E70Ec7B133,
            0xFf753f202a9eDDeFF68e2Ddf245E2339fbb5cDc0,
            0x163570dA06C96B1a5E6f29fBAdE7fE9065434F72
        );
        lendingTokens[Chains.MORPH][Lenders.QUOKKA_LEND][0x5300000000000000000000000000000000000011] = LenderTokens(
            0x33Dda42a34beDaF88eC069981a2C6E7d1D9E86ae,
            0xA0B9Fc2aDC0F0ACb7D999E8500C7DC92ce281069,
            0x2e9446d0A41aa3d53C44142B4CE9456eafDaaE60
        );
        lendingTokens[Chains.MORPH][Lenders.QUOKKA_LEND][0x7DCC39B4d1C53CB31e1aBc0e358b43987FEF80f7] = LenderTokens(
            0x0c2ceB91E8e9F27F8aEc68744f3Ef130d3b90862,
            0xdf40b9a005DBB1B794043e78a6d56003352AcDbF,
            0x14522d0B7ac9ac1e9770C8277EF95d920679ee80
        );
        lendingTokens[Chains.MORPH][Lenders.QUOKKA_LEND][0x803DcE4D3f4Ae2e17AF6C51343040dEe320C149D] = LenderTokens(
            0xdC888Ce29BE8CBc34aeaddf435C0d49F650d9A05,
            0x84848443188F6CD446d6b005264F9e6017CE904c,
            0xDA187a42cF396046b106A0291d509bB21d9a7466
        );
        lendingTokens[Chains.MORPH][Lenders.QUOKKA_LEND][0x55d1f1879969bdbB9960d269974564C58DBc3238] = LenderTokens(
            0x9F6CBE51Cd014A4F4196cfE585e5555D81378bd2,
            0x9Af93aC8FE84b1218D834dEfa9C7400487aE8b1c,
            0x0f6a0652B3f28476D837DfE694934DB6b6F4C725
        );
        lendingTokens[Chains.MORPH][Lenders.QUOKKA_LEND][0x950e7FB62398C3CcaBaBc0e3e0de3137fb0daCd2] = LenderTokens(
            0x15086E035b24274eda26d5bFF96BDf9B47E43a50,
            0xd2AA5b2145508Df4A68E112B9E310236AB06247c,
            0xe73EdCA95fb2D5Ce42B03cf06a93434e82585fd5
        );
        lendingControllers[Chains.MORPH][Lenders.QUOKKA_LEND] = 0x876B85955803938F5590326098cBA6C1dB94CA12;
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0xA0fB8cd450c8Fd3a11901876cD5f17eB47C6bc50] = LenderTokens(
            0x00cb290CA9D475506300a60D9e2A775e730b3323,
            0x0B8F80Dd1935f018894b8063A7CED8996823FC29,
            0x58fa9bd464858ABc2A511766F6e16b7FFF862Bb4
        );
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0x975Ed13fa16857E83e7C493C7741D556eaaD4A3f] = LenderTokens(
            0x06D8a9CD225c6Ba0e60166C2e7C2c89509892Ccc,
            0x4c21EF6a836A9ccB980b4A94BF0c48E3380846B6,
            0x25c9c1569bff4e388607E8a94cb7373b4cEAdD49
        );
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0x8f7D64ea96D729EF24a0F30b4526D47b80d877B9] = LenderTokens(
            0xdd417E6f46e7247628FA26EFaf28a10eF5E960a8,
            0x550139d40655F7765fb69502B05379BCEE4fBa59,
            0xBcCd25Eb975275E4404d96771AcB2C9E73793fa7
        );
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0x8D97Cea50351Fb4329d591682b148D43a0C3611b] = LenderTokens(
            0x24b376800dd8F589d92Ba0c5Da099Dcdaa44Ef33,
            0x89d4560C1cb9353947a501e93D441F42f7e11cef,
            0x75da5Cc19666Ff9CBEc4b3a309202851d47AcE9e
        );
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0xB4B01216a5Bc8F1C8A33CD990A1239030E60C905] = LenderTokens(
            0x776ADcF4E1c1C252FA783034fd1682C214Da23d4,
            0xb52797316C4dD061C29d07bacb7bF64feBC384c8,
            0x2DAf736e1B83D3157295E8207743c2EedA7e718c
        );
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0x7627b27594bc71e6Ab0fCE755aE8931EB1E12DAC] = LenderTokens(
            0x2E87E434662fFEBA007CA3f6375B20d38a7354d3,
            0xBC006364c098312dC0bA94776DAE7ADDa345D437,
            0xec83802a1d79411a9a3Bf92C6A38F5B9A1689e2b
        );
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0xD102cE6A4dB07D247fcc28F366A623Df0938CA9E] = LenderTokens(
            0xa55E6dC5aEC7D16793aEfE29DB74C9EED888103e,
            0x99c912A1031393ee374332A74F5110Cf7d2C9050,
            0xf37092624C841B1609891eb23201Bb9f59718B07
        );
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0xF1815bd50389c46847f0Bda824eC8da914045D14] = LenderTokens(
            0x9EeD5C8E0155aBc3C0946004Af377455e8c9494c,
            0x9a92a718319689dE423122e409BA54cE3F2E9176,
            0x8d16643cf555b2a1966487E3373C54b253bE4FF0
        );
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0x674843C06FF83502ddb4D37c2E09C01cdA38cbc8] = LenderTokens(
            0xb7c7f4fF127102739d9DeC23DcD494F1fF392ba4,
            0x98aD709f03A2FbAC6482901fb4cfc8Cd1B343afE,
            0xf6f0B503d60C957ff952B7c40A8347768377deb7
        );
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0xBAb93B7ad7fE8692A878B95a8e689423437cc500] = LenderTokens(
            0xB09919dB290aD745fa66A5dFFD4E70812f5a2088,
            0xfdd4f5D0588fe5A8fb640447d22eE1831752B925,
            0x1cCbc3985cC085935326bD80b863680016b98659
        );
        lendingTokens[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN][0x0555E30da8f98308EdB960aa94C0Db47230d2B9c] = LenderTokens(
            0x151A141d41CE54d30DEb2e99d0272B5B597ED293,
            0x11924596d8ca4CD4E067261cA3eB35a3A562c6C4,
            0x7b5dE5649abCBA54064b7509eC3cadE9eb4923A3
        );
        lendingTokens[Chains.FUSE_MAINNET][Lenders.MERIDIAN][0x5622F6dC93e08a8b717B149677930C38d5d50682] = LenderTokens(
            0xeC3911CCa56Ad400047EC78BbD4EDc9DcE27A745,
            0x0A3305108968F63AE5D5cBb16569c81a3baa9C9B,
            0x3097Ab4a3CdBA42BB13197b8e022FeDCA308490a
        );
        lendingTokens[Chains.FUSE_MAINNET][Lenders.MERIDIAN][0x68c9736781E9316ebf5c3d49FE0C1f45D2D104Cd] = LenderTokens(
            0xcf85542F02414f4Ff8888d174B16E27393Bd0AfD,
            0xF5b748c9692EdeB8C3D317f961d2143252AFf3b3,
            0x904019b6d6C482e600D97FBDDa3c681D68578c04
        );
        lendingTokens[Chains.FUSE_MAINNET][Lenders.MERIDIAN][0x28C3d1cD466Ba22f6cae51b1a4692a831696391A] = LenderTokens(
            0x8e4eC003B88c0A00229E31d451A9FD1533266FF1,
            0xFc15f06085e8FE68E02E80072cA8Ee18019033cc,
            0x321b4dF0E6713a204e17EE68e97A9C28f3e52DFa
        );
        lendingTokens[Chains.FUSE_MAINNET][Lenders.MERIDIAN][0x0BE9e53fd7EDaC9F859882AfdDa116645287C629] = LenderTokens(
            0xb012458830ed5B5A699ed2cc3A29C4b102abed6a,
            0xc246eBCB3331a866f56a9e6C757809Cc31201b09,
            0x24EfEb76A42B0210EeB40f4D40163a1c9546A417
        );
        lendingTokens[Chains.FUSE_MAINNET][Lenders.MERIDIAN][0x2931B47c2cEE4fEBAd348ba3d322cb4A17662C34] = LenderTokens(
            0xe939B9607fD0821310dEf5998A05eb4147Be3423,
            0xfcC4cFa21eFB7fe64D3fC7Ce63D6dD396c784546,
            0xF7CfBFa24Ac330b42AbF6e47e9810116aF559eb0
        );
        lendingTokens[Chains.FUSE_MAINNET][Lenders.MERIDIAN][0x3695Dd1D1D43B794C0B13eb8be8419Eb3ac22bf7] = LenderTokens(
            0x856ad1e764eF9188b52f2CeD1598121B86aaE6e6,
            0xb5f91619bCF12d42cb33eb7B628A1409D6B73B7A,
            0xC60F4C8f42eC6f1C67405e8E5Cd1809534B9f1F6
        );
        lendingTokens[Chains.FUSE_MAINNET][Lenders.MERIDIAN][0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9] = LenderTokens(
            0xEA4DA5e0fec9E6cd228Ef44E9AF03606E2bfeB2F,
            0x8E5e1fEDF95673B86736a90dE1B5Fd57570e2a64,
            0x97E4046FFDF52B1A93Eb151f9FC36edf38702e83
        );
        lendingTokens[Chains.FUSE_MAINNET][Lenders.MERIDIAN][0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590] = LenderTokens(
            0x8FBC597BaC2C37AC7C2Bf9b981E6FB0fce2A4A34,
            0x3E8386be8008Dd19229321060f1bc317d5Ca03c9,
            0xAab127d677E99FCd0577Be27aBBDaa15189E26C2
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.MERIDIAN][0xA51894664A773981C6C112C43ce576f315d5b1B6] = LenderTokens(
            0xB908808F52116380FFADCaebcab97A8cAD9409D2,
            0x3Ef9b96D8a88Df1CAAB4A060e2904Fe26aE518Ce,
            0x6171390c9E926eE91e0D055FdA2C46675B59fb86
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.MERIDIAN][0xA9d23408b9bA935c230493c40C73824Df71A0975] = LenderTokens(
            0xc2aB0FE37dB900ed7b7d3E0bc6a194cB78E33FB4,
            0xce0f8615380843EFa8CF6650a712c05e534A0e3F,
            0x56252761C000C3F30c5273f6985d798289719Fa4
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.MERIDIAN][0x07d83526730c7438048D55A4fc0b850e2aaB6f0b] = LenderTokens(
            0x3807A7D65D82784E91Fb4eaD75044C7B4F03A462,
            0xd37B96C82D4540610017126c042AFdde28578Afa,
            0xCe3b4ae5266146823cC60Ae06B4a8a34FcCa5AB6
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.MERIDIAN][0x19e26B0638bf63aa9fa4d14c6baF8D52eBE86C5C] = LenderTokens(
            0xa3f248A1779364FB8B6b59304395229ea8241229,
            0x22F48Ddbc34Fa22eda937496Fe702f2095D70a8e,
            0x73A3329d4Ad0b472d3720266B113b4b0826B14B3
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.MERIDIAN][0x9c2dc7377717603eB92b2655c5f2E7997a4945BD] = LenderTokens(
            0x4361736820d9fE2A354225c7afDc246E5013135D,
            0x6cD8F57977bB325359d0761b6B334D76697dA441,
            0xE7a5596A2B9e11b98a14547807A236B53b0DeDC5
        );
        lendingControllers[Chains.TELOS_EVM_MAINNET][Lenders.MERIDIAN] = 0xd8d02083570f457f96864CEb1720E368B5C9Fe51;
        lendingControllers[Chains.METER_MAINNET][Lenders.MERIDIAN] = 0xDcA551F04EfA24D7B850D7D6B35F6767b950C840;
        lendingControllers[Chains.FUSE_MAINNET][Lenders.MERIDIAN] = 0x08E387E24E3b431790E845D1b3c02913679A8b2F;
        lendingControllers[Chains.TARAXA_MAINNET][Lenders.MERIDIAN] = 0x4682f6BC97D7ee6ecF264Ed624374D5Ab7d0E184;
        lendingControllers[Chains.ARTELA_MAINNET][Lenders.MERIDIAN] = 0x6F01F552AC50992Cd51E1fBcD14a26eE319F0198;
        lendingControllers[Chains.TAIKO_ALETHIA][Lenders.MERIDIAN] = 0x1697A950a67d9040464287b88fCa6cb5FbEC09BA;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0x6B175474E89094C44Da98b954EedeAC495271d0F] = LenderTokens(
            0x4DEDf26112B3Ec8eC46e7E31EA5e123490B05B8B,
            0xf705d2B7e92B3F38e6ae7afaDAA2fEE110fE5914,
            0xfe2B7a7F4cC0Fb76f7Fc1C6518D586F1e4559176
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0x83F20F44975D03b1b09e64809B757c47f942BEeA] = LenderTokens(
            0x78f897F0fE2d3B5690EbAe7f19862DEacedF10a7,
            0xaBc57081C04D921388240393ec4088Aa47c6832B,
            0xEc6C6aBEd4DC03299EFf82Ac8A0A83643d3cB335
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = LenderTokens(
            0x377C3bd93f2a2984E1E7bE6A5C22c525eD4A4815,
            0x7B70D04099CB9cfb1Db7B6820baDAfB4C5C70A67,
            0x887Ac022983Ff083AEb623923789052A955C6798
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] = LenderTokens(
            0x59cD1C87501baa753d0B5B5Ab5D8416A45cD71DB,
            0x2e7576042566f8D6990e07A1B61Ad1efd86Ae70d,
            0x3c6b93D38ffA15ea995D1BC950d5D0Fa6b22bD05
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0] = LenderTokens(
            0x12B54025C112Aa61fAce2CDB7118740875A566E9,
            0xd5c3E3B566a42A6110513Ac7670C1a86D76E13E6,
            0x9832D969a0c8662D98fFf334A4ba7FeE62b109C2
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] = LenderTokens(
            0x4197ba364AE6698015AE5c1468f54087602715b2,
            0xf6fEe3A8aC8040C3d6d81d9A4a168516Ec9B51D2,
            0x4b29e6cBeE62935CfC92efcB3839eD2c2F35C1d9
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0x6810e776880C02933D47DB1b9fc05908e5386b96] = LenderTokens(
            0x7b481aCC9fDADDc9af2cBEA1Ff2342CB1733E50F,
            0x57a2957651DA467fCD4104D749f2F3684784c25a,
            0xbf13910620722D4D4F8A03962894EB3335Bf4FaE
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0xae78736Cd615f374D3085123A210448E74Fc6393] = LenderTokens(
            0x9985dF20D7e9103ECBCeb16a84956434B6f06ae8,
            0xBa2C8F2eA5B56690bFb8b709438F049e5Dd76B96,
            0xa9a4037295Ea3a168DC3F65fE69FdA524d52b3e1
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0xdAC17F958D2ee523a2206206994597C13D831ec7] = LenderTokens(
            0xe7dF13b8e3d6740fe17CBE928C7334243d86c92f,
            0x529b6158d1D2992E3129F7C69E81a7c677dc3B12,
            0x0Dae62F953Ceb2E969fB4dE85f3F9074fa920776
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee] = LenderTokens(
            0x3CFd5C0D4acAA8Faee335842e4f31159fc76B008,
            0xc2bD6d2fEe70A0A73a33795BdbeE0368AeF5c766,
            0x5B1F8aF3E6C0BF4d20e8e5220a4e4A3A8fA6Dc0A
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0xb3973D459df38ae57797811F2A1fd061DA1BC123,
            0x661fE667D2103eb52d3632a3eB2cAbd123F27938,
            0x26a76E2fa1EaDbe7C30f0c333059Bcc3642c28d2
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD] = LenderTokens(
            0x6715bc100A183cc65502F05845b589c1919ca3d3,
            0x4e89b83f426fED3f2EF7Bb2d7eb5b53e288e1A13,
            0x55580770e14E008082aB2E8d08a16Cc1dC192741
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0xdC035D45d973E3EC169d2276DDab16f1e407384F] = LenderTokens(
            0xC02aB1A5eaA8d1B114EF786D9bde108cD4364359,
            0x8c147debea24Fb98ade8dDa4bf142992928b449e,
            0xDFf828d767E560cf94E4907b2e60673E772748A4
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0x8236a87084f8B84306f72007F36F2618A5634494] = LenderTokens(
            0xa9d4EcEBd48C282a70CfD3c469d6C8F178a5738E,
            0x096bdDFEE63F44A97cC6D2945539Ee7C8f94637D,
            0xfBaF333a919cb92CAf9e85966D4E28FFF80e5D1D
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0x18084fbA666a33d37592fA2633fD49a74DD93a88] = LenderTokens(
            0xce6Ca9cDce00a2b0c0d1dAC93894f4Bd2c960567,
            0x764591dC9ba21c1B92049331b80b6E2a2acF8B17,
            0xf4B45Ed75B50eC613661bcdF2353AA45a288872E
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0xbf5495Efe5DB9ce00f80364C8B423567e58d2110] = LenderTokens(
            0xB131cD463d83782d4DE33e00e35EF034F0869bA1,
            0xB0B14Dd477E6159B4F3F210cF45F0954F57c0FAb,
            0x6bA1a093F5328cA31Ee6ed70E243cBA40d24B174
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7] = LenderTokens(
            0x856f1Ea78361140834FDCd0dB0b08079e4A45062,
            0xc528F0C91CFAE4fd86A68F6Dfd4d7284707Bec68,
            0x1B16e95958e06291c028e709727f8B0BB56451D3
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][0x6c3ea9036406852006290770BEdFcAbA0e23A0e8] = LenderTokens(
            0x779224df1c756b4EDD899854F32a53E8c2B2ce5d,
            0x3357D2DB7763D6Cd3a99f0763EbF87e0096D95f9,
            0x76e39b016ae2B4db14b40845aBE4B9b7aDAf0c12
        );
        lendingTokens[Chains.GNOSIS][Lenders.SPARK][0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d] = LenderTokens(
            0xC9Fe2D32E96Bb364c7d29f3663ed3b27E30767bB,
            0x868ADfDf12A86422524EaB6978beAE08A0008F37,
            0xab1B62A1346Acf534b581684940E2FD781F2EA22
        );
        lendingTokens[Chains.GNOSIS][Lenders.SPARK][0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1] = LenderTokens(
            0x629D562E92fED431122e865Cc650Bc6bdE6B96b0,
            0x0aD6cCf9a2e81d4d48aB7db791e9da492967eb84,
            0xe21Bf3FB5A2b5Bf7BAE8c6F1696c4B097F5D2f93
        );
        lendingTokens[Chains.GNOSIS][Lenders.SPARK][0x6C76971f98945AE98dD7d4DFcA8711ebea946eA6] = LenderTokens(
            0x9Ee4271E17E3a427678344fd2eE64663Cb78B4be,
            0x3294dA2E28b29D1c08D556e2B86879d221256d31,
            0x0F0e336Ab69D9516A9acF448bC59eA0CE79E4a42
        );
        lendingTokens[Chains.GNOSIS][Lenders.SPARK][0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb] = LenderTokens(
            0x5671b0B8aC13DC7813D36B99C21c53F6cd376a14,
            0xd4bAbF714964E399f95A7bb94B3DeaF22d9F575d,
            0x2f589BADbE2024a94f144ef24344aF91dE21a33c
        );
        lendingTokens[Chains.GNOSIS][Lenders.SPARK][0xaf204776c7245bF4147c2612BF6e5972Ee483701] = LenderTokens(
            0xE877b96caf9f180916bF2B5Ce7Ea8069e0123182,
            0x1022E390E2457A78E18AEEE0bBf0E96E482EeE19,
            0x2cF710377b3576287Be7cf352FF75D4472902789
        );
        lendingTokens[Chains.GNOSIS][Lenders.SPARK][0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83] = LenderTokens(
            0x5850D127a04ed0B4F1FCDFb051b3409FB9Fe6B90,
            0xBC4f20DAf4E05c17E93676D2CeC39769506b8219,
            0x40BF0Bf6AECeE50eCE10C74E81a52C654A467ae4
        );
        lendingTokens[Chains.GNOSIS][Lenders.SPARK][0x4ECaBa5870353805a9F068101A40E0f32ed605C6] = LenderTokens(
            0x08B0cAebE352c3613302774Cd9B82D08afd7bDC4,
            0x3A98aBC6F46CA2Fc6c7d06eD02184D63C55e19B2,
            0x4cB3F681B5e393947BD1e5cAE84764f5892923C2
        );
        lendingTokens[Chains.GNOSIS][Lenders.SPARK][0xcB444e90D8198415266c6a2724b7900fb12FC56E] = LenderTokens(
            0x6dc304337BF3EB397241d1889cAE7da638e6e782,
            0x0b33480d3FbD1E2dBE88c82aAbe191D7473759D5,
            0x80F87B8F9c1199e468923D8EE87cEE311690FDA6
        );
        lendingTokens[Chains.GNOSIS][Lenders.SPARK][0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0] = LenderTokens(
            0xA34DB0ee8F84C4B90ed268dF5aBbe7Dcd3c277ec,
            0x397b97b572281d0b3e3513BD4A7B38050a75962b,
            0xC5dfde524371F9424c81F453260B2CCd24936c15
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.SPARK] = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
        lendingControllers[Chains.GNOSIS][Lenders.SPARK] = 0x2Dae5307c5E3FD1CF5A72Cb6F698f915860607e0;
        lendingTokens[Chains.KAIA_MAINNET][Lenders.RHOMBUS][0x19Aac5f612f524B754CA7e7c41cbFa2E981A4432] = LenderTokens(
            0xa5B2312DdF69a4246B7bAD2104a95d977D818CfF,
            0xCD03A36155b6F1f643B5C5BE3bE72Da61e555A99,
            0xbBD02C805b13ab41aE536eef7d015111E70E008B
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.RHOMBUS][0x5C13E303a62Fc5DEdf5B52D66873f2E59fEdADC2] = LenderTokens(
            0x2d722711f868dc060c09AA766EF51f883f4969DE,
            0x406e0EBE5dEb1a4cc0Ce7f73dde8BE1EFE2480B0,
            0x08a7b222a00f27E4Ef338A6059bbDf431Ca573ce
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.RHOMBUS][0x608792Deb376CCE1c9FA4D0E6B7b44f507CfFa6A] = LenderTokens(
            0x64f46414A52fBF9DcDB98C06aB5dBE388f061353,
            0x02A2E27210b129DFC95353Ee52c102901e5349C8,
            0xF3e5ffF1440fc5b95d4e992901403a3511177514
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.RHOMBUS][0x98A8345bB9D3DDa9D808Ca1c9142a28F6b0430E1] = LenderTokens(
            0xae1d479c877A7d16d60F9C099f1F40eC478866Cb,
            0x6F239A867D9db8310b9f40f0D7D4504F1B387E7c,
            0xe77639F7503cbb2B17FB4F39e703f492c23B0C31
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.RHOMBUS][0x42952B873ed6f7f0A7E4992E2a9818E3A9001995] = LenderTokens(
            0xeD259BDAA23978EaDc61697F2e27e0A3F003664B,
            0x306c95483a70bA2514D98470840Eb5Bbe2d08D54,
            0x4531455D86CB69cc726Ee7d42D581bAEdc014799
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.RHOMBUS][0xa9999999c3D05Fb75cE7230e0D22F5625527d583] = LenderTokens(
            0xB598faFc0d4140e5C167c58C21CcB895845aeA94,
            0xCE9e35787c1D646BaEBA0f01383830baCe1d9C6f,
            0xdBe4E0Dd0B5D82Bc87bBB9ce2f18aEf92D6205eD
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.RHOMBUS][0x84F8C3C8d6eE30a559D73Ec570d574f671E82647] = LenderTokens(
            0x266fd06f005833a00AcD1a2e4F37e2aBE9a7E464,
            0x5a5Cc5d8D1877fbCf1BA718F03AA5A1B5b35CaC3,
            0xc4aB1d0B4F7a738827ab118b48bfc21a810B5F77
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.RHOMBUS][0x9bcb2EFC545f89986CF70d3aDC39079a1B730D63] = LenderTokens(
            0x8C92f2408E5471225a1998582948A8fee85D1941,
            0x9cf5cf2c03110ad99e4fAa333908fF931e604F99,
            0xBf971Ae4E6b18eeBF52045bc5A55f180442E3b8B
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.RHOMBUS][0x7FC692699f2216647a0E06225d8bdF8cDeE40e7F] = LenderTokens(
            0x29E7D1070808d47ddf60217d42c7976cAF8EB3Fc,
            0xFdDdcD6EeB39dE5447445B982fe8a64E75474bF7,
            0x4e8b7e204C85f6596Da34fFf857fa29EE9489EDf
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.RHOMBUS][0x02cbE46fB8A1F579254a9B485788f2D86Cad51aa] = LenderTokens(
            0xb38706E363F3bc04C0c420B028270A3411097902,
            0x7Dfc38C5dD47ADD601001b148D19EF1FC2c67A0A,
            0x073e6d84b93Ac73dd7AF219d053C29aCB88A7C35
        );
        lendingControllers[Chains.KAIA_MAINNET][Lenders.RHOMBUS] = 0xc17bDf95aBD73B851917B6233090E025427e1e84;
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0x078dB7827a5531359f6CB63f62CFA20183c4F10c] = LenderTokens(
            0xca3Bac04C7e7E0AFEFf9a5180119a9F64EA3e5F9,
            0x1ef3b5a08736Ee46AF98a9d14e6abFE67da6139C,
            0x0fFd09d4EA35bc3Fad2F47b803F1BE3052d93bfa
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0x6270B58BE569a7c0b8f47594F191631Ae5b2C86C] = LenderTokens(
            0x7D274dce8E2467fc4cdb6E8e1755db5686DAEBBb,
            0x20cE3cdA90632fFf46B9f93038Da97b4E65A0106,
            0xCd02C5549C5780Ec5735672D03dE075Cf5A3aC55
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0xd6dAb4CfF47dF175349e6e7eE2BF7c40Bb8C05A3] = LenderTokens(
            0xFD19C7C4c37332B8cc71B8a7fb42B6F58Db78Cdf,
            0xa41881f4435e60A96F88031A68272BFc31951840,
            0xD90045d45CBd43d4fe3BD8460b99B6803eD9D325
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0xDCbacF3f7a069922E677912998c8d57423C37dfA] = LenderTokens(
            0x364166aff4699f21F541C235F674774b07b75cA7,
            0xE4c1a6F1c177D03754B74647c94583053ac85C21,
            0x70FC0e8B39f18e0ec9D5a5d47DCC1a2E777bC026
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0xCD6f29dC9Ca217d0973d3D21bF58eDd3CA871a86] = LenderTokens(
            0x0098108191E4E8cd37f13f347743EC76b1Bf8852,
            0xF992337092aA80097a995A2f40913969E0Ca391b,
            0xC41F40B340573543c3710ABa89beD94061cE6D9d
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0xe4f05A66Ec68B54A58B17c22107b02e0232cC817] = LenderTokens(
            0x5BC2785782C0bba162C78a76F0eE308ec5f601B7,
            0x5061Fb48F937b4bc42F818A9730b4ca65D5D4925,
            0x0ff94BdE71c0eB14eA34ceb81b016ba01cB8184D
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0x98A8345bB9D3DDa9D808Ca1c9142a28F6b0430E1] = LenderTokens(
            0x09AA7178049Ba617119425A80faeee12dBe121de,
            0x44f3a877d801954626d19939D18Aff86a58CFe7d,
            0x61D23b71A6413fc79e0EB9eAcf28D7D1764c1503
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0x981846bE8d2d697f4dfeF6689a161A25FfbAb8F9] = LenderTokens(
            0xCb56645C57E02A981F89505dBA4FEf65EA78D869,
            0xC29568e1fbB2cf5917A9bec388De66256D757d24,
            0xb215746cabF3486e22A97A77b7cA9BF9ED2C8593
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0x608792Deb376CCE1c9FA4D0E6B7b44f507CfFa6A] = LenderTokens(
            0x98CB7533a3dBcB295C360bc24c2E7f169Fc90D30,
            0xd6Dc9802ccFa43871a424fC561732EBC44FAFf31,
            0x899985F892E5dA0EcCC69E23807Eb62Ea11DB20f
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0x5C13E303a62Fc5DEdf5B52D66873f2E59fEdADC2] = LenderTokens(
            0x46896309C943fB642E7e564bb25aC3E85a80698B,
            0x292FEF4F3982baBF05f89482150d4ff530cedd92,
            0xfa77d532E1234d9c7f0C4F2d60632Cc668124795
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0xCB2C7998696Ef7a582dFD0aAFadCd008D03E791A] = LenderTokens(
            0x4C86823eD95A0A85EA91cb783b559a93b6A2dD02,
            0xc8b6BCD627948193202576f87b3376b2c8dD5f32,
            0xdD010C606Cbc59830644978013E3E06b1d2fD0e8
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0xaC9C1E4787139aF4c751B1C0fadfb513C44Ed833] = LenderTokens(
            0xa6822cc9041D27b318aEB2F6509B27f1e81175fc,
            0xD21d33118B0Fe704c25a4c5E7065136edBA26376,
            0x6db200Ed6c7fc29D9d2a86eb729C122e29c3a7Ac
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0xE2765F3721dab5f080Cf14ACe661529e1ab9adE7] = LenderTokens(
            0x98671F24B2b5215b937524a1073fd382f3972E0d,
            0xabd47e52313ea57A36350227F6Cc61EE948a9047,
            0xAD58DA118b6FcF5CCF17FCDa6e328B42F49Cc610
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0x45830b92443a8f750247da2A76C85c70d0f1EBF3] = LenderTokens(
            0x219df846aDdcc4DA8C95cE204Ff49E35A712Fe00,
            0xB19888951EA51046Fd8664b5D54ABA1ff8a4a07a,
            0xbef05eb13fE78b2D35e1AA10a08583FB697BCA26
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0xfAA03A2AC2d1B8481Ec3fF44A0152eA818340e6d] = LenderTokens(
            0x1B7576E52cEe48791926D81012b534C923cc602A,
            0xBB1A25A5A8f694604a6e3e11b00407c532AFE1A2,
            0x90d06d639D620ab3A9F404EAd6bA41fcAfA5d289
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0xceE8FAF64bB97a73bb51E115Aa89C17FfA8dD167] = LenderTokens(
            0x006a4D856ff905849b0999978d95bd30CA0d6f66,
            0x68BAf69056B83D999baC4aB5464b34b565575184,
            0x5EB92aa72DE1ed1020Ec3c6FcfF5d04641a9eac4
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAP][0x4Fa62F1f404188CE860c8f0041d6Ac3765a72E67] = LenderTokens(
            0x09DB8199a93C90e066A50898E569629E86aD17bD,
            0xeA2F4468F4aF80139eE43fbFE8ced24e009b2188,
            0xA5dcC2D63222D42985Eb09F1774220aABE3cb8Fd
        );
        lendingControllers[Chains.KAIA_MAINNET][Lenders.KLAP] = 0x1b9c074111ec65E1342Ea844f7273D5449D2194B;
        lendingTokens[Chains.GNOSIS][Lenders.RMM][0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d] = LenderTokens(
            0x0cA4f5554Dd9Da6217d62D8df2816c82bba4157b,
            0x9908801dF7902675C3FEDD6Fea0294D18D5d5d34,
            0x8ACD88D494cFA56F542234f8924F06024b5795B5
        );
        lendingTokens[Chains.GNOSIS][Lenders.RMM][0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83] = LenderTokens(
            0xeD56F76E9cBC6A64b821e9c016eAFbd3db5436D1,
            0x69c731aE5f5356a779f44C355aBB685d84e5E9e6,
            0x3D1Dae285860153169E17A5365492C6bbA16979e
        );
        lendingTokens[Chains.GNOSIS][Lenders.RMM][0xd3DFf217818b4F33eB38a243158FBeD2BBB029D3] = LenderTokens(
            0xF3220Cd8F66AEB86fC2A82502977EAb4BFd2f647,
            0x9fC319476836E4b7d70D332aea3e33ec3F14ffdE,
            0x2629EeDFD294172b26972444e5985c362Eb9604D
        );
        lendingControllers[Chains.GNOSIS][Lenders.RMM] = 0xFb9b496519fCa8473fba1af0850B6B8F476BFdB3;
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x4DC7c9eC156188Ea46F645E8407738C32c2B5B58,
            0x310DDe1DB3611d78B24DC17460dd1beb15354000,
            0x38E49164CCFb46EF446ff056c5bB97b7fA50F155
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0x2CAE934a1e84F693fbb78CA5ED3B0A6893259441] = LenderTokens(
            0xA0b7108f28b4449354152334E14140b7A6d2070B,
            0xc51FcFe6e8E4B95f818d0a7b635901E7C3E03c12,
            0xa2f5e16D9C16D417aD80B8939688aE861F9FF018
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0xbA9986D2381edf1DA03B0B9c1f8b00dc4AacC369] = LenderTokens(
            0x4491B60c8fdD668FcC2C4dcADf9012b3fA71a726,
            0xe0c2e7DDA57ae7caf8D61D5B5f3395a0928cc331,
            0x9bC851D790cE02c27490E5645d5Dd876f6511fFC
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0xf24e57b1cb00d98C31F04f86328e22E8fcA457fb] = LenderTokens(
            0x9FE39076043D19B87247DE15095b4e9b3c7d6f61,
            0xEC00bF784A650aC162599efe651a18b31Ce0847F,
            0xbAb6A0f56d53dfF21BF990676C5feD9b47A060C8
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0x3A337a6adA9d885b6Ad95ec48F9b75f197b5AE35] = LenderTokens(
            0xe4dD5EF3c90136f72A163904d2A7E9de3771Ece7,
            0x91872142444Dd849c6BC5e3f0Bf28600a612bC76,
            0x02A6832aF138ABb790E9E8769EbA3790eFd3C6d8
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] = LenderTokens(
            0xE11d68AC80d6D8CCbaC28ed5D0f80bd6477BFe41,
            0xcC388DAc15CEB26f4d668664e458F40c49Ccb2AE,
            0xBdE521Efd65341B3aD48c11de371BE7546987482
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0xCC0966D8418d412c599A6421b760a847eB169A8c] = LenderTokens(
            0xA95F849718acfFC6cE1736416aaFB4d14A998AF3,
            0x7e1f9ba9F9Db09cD0294e5ebdC551e42a727D045,
            0xef214FFDC037baDF8d9c34Bd68235cac820570E1
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0x6c460b2c6D6719562D5dA43E5152B375e79B9A8B] = LenderTokens(
            0x0526CF96Ad808f8E11A5a9F1012edf67F4BAf519,
            0x2b510b2fDF38148C7EbCa0a9B9777Fbd9AAaDAdd,
            0x6345447100C2AD8dfc962926ba76bf7656D72D75
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0x102d758f688a4C1C5a80b116bD945d4455460282] = LenderTokens(
            0xC04D50506986504f992Fe4e68F98A6e23C11Bcef,
            0x3d15Ff402140eE524981d512E079aB1354aA115B,
            0x84d59EACc5c0D12D87C9BF56a695cC58517cEc23
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0xAffEb8576b927050f5a3B6fbA43F360D2883A118] = LenderTokens(
            0xE41959F80437496a9B2241609E6e7F3feeFA4C3A,
            0x40b49B84bA6Aa416980A76FaEBe2F5828dB701ff,
            0xf854251E650b4c5bF65366805667FA9f59fa4eDb
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0x139450C2dCeF827C9A2a0Bb1CB5506260940c9fd] = LenderTokens(
            0xEB2dc4d4B64D1c2e2270C5AB57DdBa4c428f5b15,
            0x3595987f1C30583474a4D8958294D9e0Ece962C6,
            0xCB569BD7C913176e0D09eECCE8036EF901932251
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE][0x2a52B289bA68bBd02676640aA9F605700c9e5699] = LenderTokens(
            0x55CdA22e998589add9707a83E85AE04877eA1bCf,
            0xe67BAceBF6956cba28Ada8B54B626E0250DD9f58,
            0x7D822700cc9A472824C99B09F3681439e60AB1F4
        );
        lendingControllers[Chains.SONEIUM][Lenders.SAKE] = 0x3C3987A310ee13F7B8cBBe21D97D4436ba5E4B5f;
        lendingTokens[Chains.SONEIUM][Lenders.SAKE_ASTAR][0x2CAE934a1e84F693fbb78CA5ED3B0A6893259441] = LenderTokens(
            0x36ed877D3BbB868eAe4A89D6705e55a3Ed2B66DC,
            0xDbbE40d007F12b74b0A06153753aFdD26a0dfB5B,
            0x863DB6084F0625Ed20c9797f79B5747d98e4D302
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE_ASTAR][0xc67476893C166c537afd9bc6bc87b3f228b44337] = LenderTokens(
            0x8007b302B5208a2f75Faa241f7B2653ac61e1df0,
            0xC905AA400b788A74C6EC369F1Df152AB08d8d654,
            0x45DB2A72fFCCD2E0aec67885cE92F9e2BF4F6607
        );
        lendingTokens[Chains.SONEIUM][Lenders.SAKE_ASTAR][0x3b0DC2daC9498A024003609031D973B1171dE09E] = LenderTokens(
            0x8B76ac181fd1E8CE6F6338b58Afa60bd1911FBf4,
            0x5795F80B2d74B682278230F3CEaAfc4E5CF51350,
            0x98c012564f4B41091c5f2a8bA1bd45645fEa088B
        );
        lendingControllers[Chains.SONEIUM][Lenders.SAKE_ASTAR] = 0x0Bd12d3C4E794cf9919618E2bC71Bdd0C4FF1cF6;
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0xF9775085d726E782E83585033B58606f7731AB18] = LenderTokens(
            0x8331bEca9EBC2489f07ef484EF84718480f7A648,
            0x7259e12f985A712e0AF32565757a784efF28ddA1,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0xbB0D083fb1be0A9f6157ec484b6C79E0A4e31C2e] = LenderTokens(
            0x7E238b5cF1860484B77C0F1D09bC89b931e6235C,
            0xCCFCc21eCE4702AF98CBB63058B3799D2991ECCc,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0x7A06C4AeF988e7925575C50261297a946aD204A8] = LenderTokens(
            0x3ab333d502792231D86a946E564Ab8344c85D9D0,
            0xc8C0ed6bfa789A440bEB238B0599238E443C8e71,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0xad11a8BEb98bbf61dbb1aa0F6d6F2ECD87b35afA] = LenderTokens(
            0x04D37B3B79cE30CD95582DC4B5394d6942E2C3a7,
            0x33214895FeA90D1AC4c7993b1d03cdfDcaE0a9f4,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x2858A7065e7694C496b710fdaEE52225953Ca8c4,
            0x32AD91629AAeA085c8D00F757DA5804f5dE65706,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3] = LenderTokens(
            0x8Ae2BA1c439469CdFD0d915e57CbD5fBD01bD451,
            0xadba20998183E801D72c7048c2fbBE0FC3142213,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0x93919784C523f39CACaa98Ee0a9d96c3F32b593e] = LenderTokens(
            0x988cE0809806F5cff00FE16d31C0E719C26a9649,
            0x014ee047620C4941c93Baa3fF33cB2d013EcaA2F,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0x78E26E8b953C7c78A58d69d8B9A91745C2BbB258] = LenderTokens(
            0x979a38146E6763e10E9BE88ddcAa3c90D23998eb,
            0x5F1340A374d4D4c8076223a8873cc9E5C980F10C,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0x8154Aaf094c2f03Ad550B6890E1d4264B5DdaD9A] = LenderTokens(
            0x9979a1406f67d47C1715411767e7db734B691BA0,
            0x748Bc8f14426EeA7307aff5d0273DC81E14B3CB4,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0x9BFA177621119e64CecbEabE184ab9993E2ef727] = LenderTokens(
            0xC796Ae0F952EdC249cb03e322326edacc32f5B48,
            0xeC099B5516E65B112138B438042aB18Dc5D44607,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0x6A9A65B84843F5fD4aC9a0471C4fc11AFfFBce4a] = LenderTokens(
            0x9260c231349153853bf77d39c1203F8C50855e59,
            0x8556754fb8bAc8a447d8448FEB5059b9E3F8af8a,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0xAA40c0c7644e0b2B224509571e10ad20d9C4ef28] = LenderTokens(
            0x9D33a5cC90A328C8d0af588e44689aECfe4AE421,
            0xC82f430F87b9ec2c9B960B8D644D2BEBBB8f26d1,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3][0x99e3dE3817F6081B2568208337ef83295b7f591D] = LenderTokens(
            0x3B10b01c31EFF86D90c6c129a53a9b0114CE9796,
            0x9Ea71e8579713c409228e3E35615D402f9c14A3f,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.HEMI_NETWORK][Lenders.LAYERBANK_V3] = 0xfeAce246DC83Ba5E4E95A67b1357D6Fd7C3C088f;
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0x900101d06A7426441Ae63e9AB3B9b0F63Be145F1] = LenderTokens(
            0x98cD652fD1f5324A1AF6D64b3F6c8DCF2d8cd0D3,
            0x1628434cAd032060a2d49aB2d6ab63FE63c66Dec,
            0xC97945fab5e42095da881bE1f8A8Ba53312C2384
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0xa4151B2B3e269645181dCcF2D426cE75fcbDeca9] = LenderTokens(
            0x8f9d6649C4ac1d894BB8A26c3eed8f1C9C5f82Dd,
            0x6e4DF18dff9a577f7B1583B71888F45CacBa5d42,
            0x1f06da6Dd1dCc30A073858CdCda5B87eFdFFb8ED
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0x8034aB88C3512246Bf7894f57C834DdDBd1De01F] = LenderTokens(
            0xDA596bFD3Acc60552Aa1e7504CeDB51e6EC93aB2,
            0xD6F6DA8B1EDd9d77B8c82a611cBEbb4E45cEadB1,
            0xf727126808cFccabf9450C730a0f33987E461DF5
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0x40375C92d9FAf44d2f9db9Bd9ba41a3317a2404f] = LenderTokens(
            0xf06C8db5f143fC9359d6af8BD07Adc845d2F3EF8,
            0xAc98BB397b8ba98FffDd0124Cdc50fA08d7C7a00,
            0x57F0b3F998164e1caBDBf24B05F5321603bB6204
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0x5832f53d147b3d6Cd4578B9CBD62425C7ea9d0Bd] = LenderTokens(
            0x2e3ea6cf100632A4A4B34F26681A6f50347775C9,
            0x614917a75A00f757aa5EDADB5a92675Af587085E,
            0x0C08B2c774b9cf45Fd6162213ee9Eb73DF980E2b
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0x5B1Fb849f1F76217246B8AAAC053b5C7b15b7dc3] = LenderTokens(
            0x58e95162dBc71650BCac4AeAD39fe2d758Fc967C,
            0x4894cca8d8F5154315111AD6E9154Db32AE5a2d4,
            0x8d07EB09F03F39556947bD71f45491Aa4883BDfa
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0x7A6888c85eDBA8E38F6C7E0485212da602761C08] = LenderTokens(
            0x2bE8CA9b70ea8e8C878dd2c2793841aC617fFc4a,
            0x9d92c320c09d52C377923a2eeCE6cBEef668Fd7B,
            0xcaD1ab73252dBEc4129695CDc4AEd61Af2cc2855
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0x70727228DB8C7491bF0aD42C180dbf8D95B257e2] = LenderTokens(
            0x14587De6Ba3e1DF2940ECf46d26DfcED6905Dd63,
            0xAd0D9106e356C3BD1C36AbF8f14FDf0B4E84f644,
            0xd3e5BeBC13eF43ef9e7e07e27d484f3D7f09859e
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0xe04d21d999FaEDf1e72AdE6629e20A11a1ed14FA] = LenderTokens(
            0xC995f5420E42842A5499d809dedad4F18EAa538D,
            0x0cEB735ebb9feFd3a8A54887a6aF4543C182B9c6,
            0x5fFF86394aEdaa65b6D997EceD15FB203F9533dA
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0xb3A8F0f0da9ffC65318aA39E55079796093029AD] = LenderTokens(
            0x9e99442AF8eaE003038Cbd0D36d60A0cA7a0fBDe,
            0x287CDBae4087a57Dc74dA7E1C94072a99906f011,
            0x86eBd97f5e096dB1511A9E984807dd78d02603C4
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0x30A540B05468A250fCc17Da2D9D4aaa84B358eA7] = LenderTokens(
            0xbFF5dE60A0dC1292610A300086C9f8Da3bE9E9b8,
            0xCE4419f3B540b6c46E1Ec19E5379F92B54a648DB,
            0x3B0eE651A5c71ecc749f48fd12749795DB0E6e84
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a] = LenderTokens(
            0xc3B8Af6903a97062937E1460e5706D73c82545Dc,
            0xa363A81D9d5C09e1A98fd290ce07526bb9a2A924,
            0xF2124554a06111B89b3B255F17F86940075406F4
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0xeAB3aC417c4d6dF6b143346a46fEe1B847B50296] = LenderTokens(
            0xC4ee71bB16142a61d8a26c85B10ECc13A223C701,
            0x566aAa5E6799136a2cde700911c2A8bDDb44115d,
            0x24A4759B990AfFC8Ff942A3cc5f1a539f2c13aa9
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND][0x6120725CFa1062B0596C48D356E4beC6A44fEece] = LenderTokens(
            0x21F971518Fe51fed475e42Be47aaC57DF74E9DCD,
            0xcA610E94BCc00fE6aF6e3da7f21BFB3F9b24d6D6,
            0xdf8767f71dF00ae4420D0053e28a286528fA26b2
        );
        lendingControllers[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND] = 0x0CEa9F0F49F30d376390e480ba32f903B43B19C5;
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND_LSTBTC][0x8034aB88C3512246Bf7894f57C834DdDBd1De01F] =
            LenderTokens(
                0x413Fd3417D5d7102246A57D85b65388EafbD2747,
                0x1363332A49E9b8F09D2A0CeD7A4fd0a84b4a9887,
                0xE3E1c9C03B58B11eaA21D76309EAbc5D244fc226
            );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND_LSTBTC][0x40375C92d9FAf44d2f9db9Bd9ba41a3317a2404f] =
            LenderTokens(
                0x46F9ce2B0aD0632858580eF66912D3F58a993571,
                0x43ff4F3B9e449FFdCb39590B856787c7f227d76D,
                0xbae94dCFFC814F31b9522bC0d44002a8f863e34E
            );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND_LSTBTC][0x5B1Fb849f1F76217246B8AAAC053b5C7b15b7dc3] =
            LenderTokens(
                0xc07f04546CEBB934250EbfF8f99C34ECfE7D9E82,
                0x462510982Df703c45A459fA4087814e4d8007A08,
                0xA2486155d52fBC522B6706acffEfC7763F836262
            );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND_LSTBTC][0x7A6888c85eDBA8E38F6C7E0485212da602761C08] =
            LenderTokens(
                0x02aB35C55760fBF778CA9946713C41D84F487a9C,
                0x57b896f1FA02259270F1f499129E245c72DB7F82,
                0xbE90D8180Fe55623E6C2b7708F554FE33d8b8587
            );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND_LSTBTC][0x9410e8052Bc661041e5cB27fDf7d9e9e842af2aa] =
            LenderTokens(
                0x6FBd77889Bbc55d52c5aE554aaaFD922322AeAFB,
                0x84D57E9a8b8A0526fF854A095b6BE061B4556984,
                0xFd37f378B4e7CDbbA270ea3A39Dd94b446878f29
            );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND_LSTBTC][0x5a2aa871954eBdf89b1547e75d032598356caad5] =
            LenderTokens(
                0xCd4a30e9d66348aDf8F753A6700c2C6bBaAdAf37,
                0x1dE8dB0F367ed55eB345efAAD3C9707C936Bd19c,
                0xCA56346d6922aD526EB6686d7869cF7E7b62C296
            );
        lendingControllers[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.COLEND_LSTBTC] = 0x29A462DC59d7e624E1A3295b9d38416908bae1F4;
        lendingTokens[Chains.BLAST][Lenders.PAC][0x4300000000000000000000000000000000000004] = LenderTokens(
            0x63749b03bdB4e86E5aAF7E5a723bF993DBf0c1c5,
            0x7cB8a894b163848bccee03fD71b098693eE7a77D,
            0xDc1C1257637d5e9dE85F66d14030809A4dB16456
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x4300000000000000000000000000000000000003] = LenderTokens(
            0xc7206216F28C23B2Da6537d296e789CFB81b31Ef,
            0x325261d7bD4BDa7bAF38d08217793e94B19C8fC7,
            0x3FDda42F3be9b827ECd17786b4bDcb4466F7F15F
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x66714DB8F3397c767d0A602458B5b4E3C0FE7dd1] = LenderTokens(
            0x2B8476064d5a6EE4821c6dbbc4F0221B1DC9cBeD,
            0xbcdeAE2CF126d474E7362f2b8953787bA5dC0c46,
            0x7d87E39682F425596f18a432b93e7a389954d21b
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x866f2C06B83Df2ed7Ca9C2D044940E7CD55a06d6] = LenderTokens(
            0xEEBdE4c9249E290dD463E22dF1d3f2abA711A576,
            0x0919D45b90b9342a7ea2599E1F3B6E2439848cF9,
            0x9a0Df522d8A05529C0dA92CE2faA6aE6e0F777e8
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x9BE8a40C9cf00fe33fd84EAeDaA5C4fe3f04CbC3] = LenderTokens(
            0xc57B31204B1dFD80Ad4D58F2D571aa05Fd98dFD9,
            0x05bc646E0A77f2dC00cD0bBE3E99638d46C7F0b0,
            0x43a70Dc02A7EE2eEbd05CA026c4738853dA31b06
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x0872b71EFC37CB8DdE22B2118De3d800427fdba0] = LenderTokens(
            0x68915399201380f392019555947491e5b3eDFa0e,
            0xA42d362e5b40acd0AcF622185b658828bc58C34E,
            0x39Ae45B7c68a860ef1439889A878900dF3F2Df37
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x9aECEdCD6A82d26F2f86D331B17a1C1676442A87] = LenderTokens(
            0xce7c5A6a86206b68A746615C1F6b473EdB6470B3,
            0xD6BC56E862Dad1b07dB267884a8F2974789d1538,
            0xB080bacb643eB0ff28d3130BdF08491B2128d547
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0x01BfaE5e4fdfCFB514B65B8ed4F515327bBE994d,
            0x60faaa431dB080AA16e7699fEa6EBbc563714E06,
            0x6373cf837a1ebB950c8C3E689CC674502Aa6c4f6
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x56e0f6DF03883611C9762e78d4091E39aD9c420E] = LenderTokens(
            0xfAf2efFa654AcA37F45d1dbE1b88f3fB0Dd1E41f,
            0x75AFbb2F98BC962CEBb3991F035C800B69A723BE,
            0x27f509458Db141CDB9354412DD95e84b3EC6f1dD
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x3D4621fa5ff784dfB2fcDFd5B293224167F239db] = LenderTokens(
            0x5cc3094909FA8EDf7a18351c8B5A2b9D1467df01,
            0xD4b4f875B1B5a71EAFCBE17109BB01Ec5C283834,
            0x210B623B1C73e408415828de21335184E9a20fD0
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x12c69BFA3fb3CbA75a1DEFA6e976B87E233fc7df] = LenderTokens(
            0xF60Eb659169a49d4cb21381BdbbEB13ABB6df527,
            0xb131623530d1E262C45504089Be63B6644aE9374,
            0x4b5Cb99709a10bcd06FF9483caBc94cDa6e6a012
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0xF7bc58b8D8f97ADC129cfC4c9f45Ce3C0E1D2692] = LenderTokens(
            0x427D0e5493A1EC15D8f9777b7E2C33B9E4c50E57,
            0xcc316E6Ad7A65bB882b37104Ba2f002230454654,
            0xb935C8864944fF221A9BD84Dc4b65838Bf2Eb5c7
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0xe7903B1F75C534Dd8159b313d92cDCfbC62cB3Cd] = LenderTokens(
            0xF5f8be345234487f6F574e821547342656Aab417,
            0xF5764dEabC3ecCbe25afe2ca83C034949A8A2912,
            0x18a52e5Df8A3C14001Ddb76E602D6Fb7bB35cb7E
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x1Da40C742F32bBEe81694051c0eE07485fC630f6] = LenderTokens(
            0x97257A7c033773d54dFe83bFcdce056af8321ae2,
            0x109195c9a8DD285b549f8963bcF80EAaE370927F,
            0xdea6f93e0c3699b09e1D63D2A7e04A0471BE5e21
        );
        lendingTokens[Chains.BLAST][Lenders.PAC][0x1A3D9B2fa5c6522c8c071dC07125cE55dF90b253] = LenderTokens(
            0x3B51C9b48Bdf91c7267B63ec663E64E9580E7Bdf,
            0xf967757e4A0Bc2BBe798F95fDB9049daB12b6913,
            0x7e7a66b6E7389E854648B346e115D07F586600c9
        );
        lendingControllers[Chains.BLAST][Lenders.PAC] = 0xd2499b3c8611E36ca89A70Fda2A72C49eE19eAa8;
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0x5555555555555555555555555555555555555555] = LenderTokens(
            0x0D745EAA9E70bb8B6e2a0317f85F1d536616bD34,
            0x747d0d4Ba0a2083651513cd008deb95075683e82,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0x94e8396e0869c9F2200760aF0621aFd240E1CF38] = LenderTokens(
            0x0Ab8AAE3335Ed4B373A33D9023b6A6585b149D33,
            0x45686A849e77CCb909F5d575F51C372bf26103D6,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0x9FDBdA0A5e284c32744D2f17Ee5c74B284993463] = LenderTokens(
            0xd2012c6DfF7634f9513A56a1871b93e4505EA851,
            0xE16a14972bcDE3f9Bd637502C86384533F27DA07,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0xBe6727B535545C67d5cAa73dEa54865B92CF7907] = LenderTokens(
            0xdBA3B25643C11be9BDF457D6b3926992A735c523,
            0x14E10FA4E016183a024c74ACF539bb875c54e70C,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x333819c04975554260AaC119948562a0E24C2bd6,
            0x1EFA0f7A12cEF73e23dE30b7013a252231Ea50f9,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb] = LenderTokens(
            0x10982ad645D5A112606534d8567418Cf64c14cB5,
            0x1EF897622D62335e7FC88Fb0605FbBa28eC0b01d,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0xf6ba4169e1a1B467D32B8884C4B42de6454B4E4f,
            0x044388Eed86eF67c126Db5A66428F30797B0ABF5,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0xb50A96253aBDF803D85efcDce07Ad8becBc52BD5] = LenderTokens(
            0x0b936DE4370E4B2bE947C01fe0a6FB5f987c4709,
            0x94c03Ed369B706Ad6957cF42aFB0b5b02F924099,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0xfD739d4e423301CE9385c1fb8850539D657C296D] = LenderTokens(
            0xa55DE93CDE5A34c5521B7584022846829CB74366,
            0x185697d814330430b8D4B3121fAB9c811B59798D,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0x0aD339d66BF4AeD5ce31c64Bc37B3244b6394A77] = LenderTokens(
            0x2A2d7663Cb77220de9BA55Aa9aAe2b360F2c23fC,
            0xd1b2c6Be5Ae55F3aBfdDE8070fD3322e87Cfb895,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0x311dB0FDe558689550c68355783c95eFDfe25329] = LenderTokens(
            0x329FebbBF38A6C202786fCc8Ac02DbD2f40D5a18,
            0x957fb7538cA456824314051A7fc6F0eAC5E7345c,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0xb7379d395F3c83952ad794896205f7E33E358735] = LenderTokens(
            0xec2767311eBf57C02de9866fDACdfefAc4AdAe6B,
            0x5533124cE92737bc209d2730836114F118BFeAf0,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0x068f321Fa8Fb9f0D135f290Ef6a3e2813e1c8A29] = LenderTokens(
            0xE14b4526438Ae5ee26596de1936280E4d6bDDEb5,
            0x64dF524260FECd833258d26A3a7AeB415d20C512,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0xd8FC8F0b03eBA61F64D08B0bef69d80916E5DdA9] = LenderTokens(
            0x48a278aA1eab4de5b74897230Ae57FB9e7B1497A,
            0x3f6f19E098e3c0C996d11cE4d4816aC470C40708,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0xb88339CB7199b77E23DB6E890353E22632Ba630f] = LenderTokens(
            0x744E4f26ee30213989216E1632D9BE3547C4885b,
            0xD612513cB3b2C52abCD6d4b338374C09AdA4657d,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0x111111a1a0667d36bD57c0A9f569b98057111111] = LenderTokens(
            0x143A24569a73AFB856A2ee3D554AbcA860118785,
            0x51aF159cF648B59efC7de2830134FA5Ca7109fDd,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERLEND][0xea84ca9849D9e76a78B91F221F84e9Ca065FC9f5] = LenderTokens(
            0x7686fEdD785663e437a409abB55a9BB36fA2DCf2,
            0xffc3d92cFb1F160De9AdecF449a1b41c9e72453C,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.HYPEREVM][Lenders.HYPERLEND] = 0x00A89d7a5A02160f20150EbEA7a2b5E4879A1A8b;
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0x5555555555555555555555555555555555555555] = LenderTokens(
            0x7C97cd7B57b736c6AD74fAE97C0e21e856251dcf,
            0x37E44F3070b5455f1f5d7aaAd9Fc8590229CC5Cb,
            0x7938045B86812e51a3e01cD4aFbCfbc4921F2ec3
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0x94e8396e0869c9F2200760aF0621aFd240E1CF38] = LenderTokens(
            0xC8b6E0acf159E058E22c564C0C513ec21f8a1Bf5,
            0x699898383Dfad4d134e3789F0Ed3090Bd1833df9,
            0x60583f5d2ca95D460a800aBA936490ba63116A23
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0xca79db4B49f608eF54a5CB813FbEd3a6387bC645] = LenderTokens(
            0x7911c2c9c5f5a6f4Bef58d7dF35903abd3EE9DD6,
            0xa0399Ff8F46Ce6C2Cfee05C5F67307C7F390a439,
            0x4db65f302d732fDE8638688d106Ece85ea1e5dD1
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0x9FDBdA0A5e284c32744D2f17Ee5c74B284993463] = LenderTokens(
            0x02379E4a55111d999Ac18C367F5920119398b94B,
            0x109d266513D01cA87E50E4DA18739D936046FbC3,
            0x88138f2552674A48a666C4305b8822a75460B1DC
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0xBe6727B535545C67d5cAa73dEa54865B92CF7907] = LenderTokens(
            0x68717797aAAe1b009C258b6fF5403AeCCB7010c0,
            0x670f4AdC643Bd6F6daC15bb59163380Bda0A8112,
            0x635e2EA1EFC300a0B14D2713AB52c868C90A9234
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0xe8F7D82A73f13A64d689e7ddAD06139BFb51f9C6,
            0x0Ab2d0574aE072a635cB58c36650175F76579E9c,
            0x4a234613211ab42E985EB166443eb943BCe9befE
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0x02c6a2fA58cC01A18B8D9E00eA48d65E4dF26c70] = LenderTokens(
            0xAEA02692F502b47e116bdfA9a4CeB3138Bd8B516,
            0xf59EA0912321A3059e51504fcaCC2a6B22735996,
            0x2FB7F4bAAf775b42c2f7fFc63F533862f0d2C476
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb] = LenderTokens(
            0x1Ca7e21B2dAa5Ab2eB9de7cf8f34dCf9c8683007,
            0x31f3FBAD8B3D2136546e2032bEC791f6D167d277,
            0x2CF46C30f0068E643AA24c6361Cf75Caa7EB6485
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0xb50A96253aBDF803D85efcDce07Ad8becBc52BD5] = LenderTokens(
            0xFd32712A1cb152c03a62D54557fcb1dE372ABfe9,
            0x54b94844D8db335686A87667D0468272a936D21F,
            0x58517EaA61B7E5F08c021107c947a0cF2810d3fB
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0x068f321Fa8Fb9f0D135f290Ef6a3e2813e1c8A29] = LenderTokens(
            0x64A0f4Ed4151d6381c509C0E64f0257e179120EC,
            0xF1c499Bb1A93958d764c674ceaFFF8F950B3Bd9D,
            0x4DD6B1c2Dbeaf9E17880Ca1AC6e34a28C3569fF2
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0xfD739d4e423301CE9385c1fb8850539D657C296D] = LenderTokens(
            0xCAe9e2A86c146b084169E170E63d340bF34d6b83,
            0x429aB5569EE85B2750683F675278713C6A3e0292,
            0xe326D83Ab778Bba36b229dcE15dabE307B1E5d35
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0xf4D9235269a96aaDaFc9aDAe454a0618eBE37949] = LenderTokens(
            0x22ee197111BC4c009Da9174113526290Fa500DC1,
            0x9425B3efa7D89498D2f495B397B00c27666547B6,
            0x122dCC0EBDDe9CC0B6B3e49419C4B1ae219e6237
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0xfDD22Ce6D1F66bc0Ec89b20BF16CcB6670F55A5a] = LenderTokens(
            0xf9C625FAf1160f00E3AC16e8e3e24F09B107ae53,
            0x934D13E0643b72DA388e1A533424b8f42cEbF8Ed,
            0x157f51bB990D67E4A6d291654B920B7A5A8a0dee
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0x85c88bfBbb3Cf5178bDc4f90289c9aFDbBCc1ED9,
            0x5542A3E093D03b2f421f1b3432a2C70bCE19D410,
            0xE98EFC32f28293cbAF5c9B4C98c3514032274821
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0x311dB0FDe558689550c68355783c95eFDfe25329] = LenderTokens(
            0x68A0d8F2dfe817F3A6Aa85EE430D42BA256fC8f4,
            0x5A2242551E4A94221667a184C0172ccbB6666163,
            0x39fbcaf4Dc6BC36CF22b3c3f02675f20e69d3116
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0xd8FC8F0b03eBA61F64D08B0bef69d80916E5DdA9] = LenderTokens(
            0x3b967db41B6bE6A42B3F42077Ee707aF2F45713e,
            0x201153BCfAdFa658d81724Bc7b6688782506871a,
            0xc35ec8b5AFE1Fdd3259bf53879Cf3364B2a14ed0
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0xb88339CB7199b77E23DB6E890353E22632Ba630f] = LenderTokens(
            0x280535137Dd84080d97d0826c577B4019d8e1BEb,
            0x27949Aaed7FA3231fAd190B7C035f557f82Dabdc,
            0x4Cb411281a87dBFA7c25b09D8094926828b13cDc
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0x111111a1a0667d36bD57c0A9f569b98057111111] = LenderTokens(
            0x5F137306A1692207624FB0f012ac19fD42698756,
            0x1BD8616684219578F6E95c31be6Eb0e34914c959,
            0x3c034A601602aa449b7B54929afF590fa5436ff4
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPURRFI][0xea84ca9849D9e76a78B91F221F84e9Ca065FC9f5] = LenderTokens(
            0xB55780B08b18A57590e7B2729CaeA5a6818Ba035,
            0xE6F233E286852ee5599213Da8C7E9d418B74D9C9,
            0xe2eFEAE1C388c598554637d7a0817613eCbF6c0D
        );
        lendingControllers[Chains.HYPEREVM][Lenders.HYPURRFI] = 0xceCcE0EB9DD2Ef7996e01e25DD70e461F918A14b;
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERYIELD][0x5555555555555555555555555555555555555555] = LenderTokens(
            0xA3F4962B4dE6c0CC2BFf758a4CF4F5A8A310fAdE,
            0x9Ff84cb719E9f73B4C3D40a016414f7E8c099c1A,
            0xadF24989b681C68aE7b2640822748Ec2D27EC839
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERYIELD][0x94e8396e0869c9F2200760aF0621aFd240E1CF38] = LenderTokens(
            0x599d155d5C97335c026f9ff7d8EF26753a609272,
            0x7917e998738211ecd821c47e0D000359B9B957f8,
            0xE505FC452a1DEdE56F39a6C866125652d664BE5d
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERYIELD][0x02c6a2fA58cC01A18B8D9E00eA48d65E4dF26c70] = LenderTokens(
            0x453fe0184a38e0344081301be3C320af4459f0AC,
            0xDA1FAB12f9eacD7bC12f7590A0c5885f6D0Df534,
            0x073834567DE5B0E4a18A265a4D336c2Cb44444E8
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERYIELD][0xca79db4B49f608eF54a5CB813FbEd3a6387bC645] = LenderTokens(
            0xcf03FD0F7c0D96c56BD36D27B4BA854f7822Ce7b,
            0xC69381c30ADDA87a3c432FCDdc0b38D1B2fF8eFC,
            0x7De158D8f4600Dc585CF7C272639C8C7473d3CD3
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERYIELD][0xBe6727B535545C67d5cAa73dEa54865B92CF7907] = LenderTokens(
            0x4538191dDcf5798e6e27d2830121649653a2C067,
            0xc7fdD961C4cd7806a65B27243d44302fE1F0c656,
            0x8a24B7FA3354ac874d8D532Db1731cdA65a84797
        );
        lendingTokens[Chains.HYPEREVM][Lenders.HYPERYIELD][0x9b498C3c8A0b8CD8BA1D9851d40D186F1872b44E] = LenderTokens(
            0xda92BBc1ba3345F3dF82a34299F3AAFC04397738,
            0x9A2f9cDfbbAF553A3753e29855c3808c78d84440,
            0x6Db2f37e985fB323d6160ad01e1403557d657108
        );
        lendingControllers[Chains.HYPEREVM][Lenders.HYPERYIELD] = 0xC0Fd3F8e8b0334077c9f342671be6f1a53001F12;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0xdAC17F958D2ee523a2206206994597C13D831ec7] = LenderTokens(
            0x3c19d9F2Df0E25C077A637692DA2337D51daf8B7,
            0x2D4fc0D5421C0d37d325180477ba6e16ae3aBAA7,
            0xB2b2C56005BA1EfD4c031F3E12d699A6A24DB19F
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = LenderTokens(
            0x9E85DF2B42b2aE5e666D7263ED81a744a534BF1f,
            0x490726291F6434646FEb2eC96d2Cc566b18a122F,
            0xf8A345C151F7503C3959343d70F5F110e0d7b099
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] = LenderTokens(
            0xd10c315293872851184F484E9431dAf4dE6AA992,
            0xDf1E9234d4F10eF9FED26A7Ae0EF43e5e03bfc31,
            0xa401f1Fa922c7a78224d932037f9B79276D9e1cD
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] = LenderTokens(
            0xE57538e4075446e42907Ea48ABFa83B864F518e4,
            0x0184eB8A4d86ff250cB2F7F3146AeCC14ccb73A4,
            0x7b656BD0b8bB6b83F698cAE3E4567fb751d334AA
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0] = LenderTokens(
            0x83B3896EC36cB20cFB430fCFE8Da23D450Dd09B5,
            0xc8CBb48a0EED0e406bb52a5cC939358c0aB644A7,
            0x1C2F0512442181746d4671b9E41daDc43cd991B7
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x83F20F44975D03b1b09e64809B757c47f942BEeA] = LenderTokens(
            0x473693EcDAd05f5002ff5F63880CFA5901FB50E8,
            0xE491C1A4150E9925e8427bea4CDCBD250B730e5C,
            0x499a735be1956B3AEb5C61da2b44CA551d5409bE
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0xae78736Cd615f374D3085123A210448E74Fc6393] = LenderTokens(
            0x03AB03DA2c5012855c743bc318c19EF3dE5Bc906,
            0x6a0e8b4D16d5271492bb151Eb4767f25cFc23f03,
            0x1AA74FFDb440aF3fFCeE21594409FDDff1CCd34C
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee] = LenderTokens(
            0x1d25Bd8AbfEb1D6517Cc21BeCA20b5cd2df8247c,
            0xcDE79c767826849e30AAe7c241c369FCe54dB707,
            0xa3BA267512F5505fdf6680c1d357eb26Bd8870ce
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x514910771AF9Ca656af840dff83E8264EcF986CA] = LenderTokens(
            0x0B87dF21F2E093f779F846FE388d9688C343D5e7,
            0x660fe1FAB4079D6abc335A117C8Fc4cB2db88375,
            0xB66bE4a7627231B7cB24F33548d3e4cCe1057960
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0xdC035D45d973E3EC169d2276DDab16f1e407384F] = LenderTokens(
            0x8dD4D313dEd77c399fED700d54cBdea2c24227D6,
            0x85f97456D05bAFa87e09c75A7e8c8238Cfa9C9c7,
            0xAd7E2B3fE207CF9e273F4cCfDbE179657d16e858
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x18084fbA666a33d37592fA2633fD49a74DD93a88] = LenderTokens(
            0x457885E79A6627318721f86d16601FB42f4aD052,
            0xB146DAcc41eE3bf5acDa69f232F32Db74f00570e,
            0x645933d05f29BB7D916A19cD6E7cFE6c6FF5bB86
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x4c9EDD5852cd905f086C759E8383e09bff1E68B3] = LenderTokens(
            0xa6ea758C6e447b7c134Dd2F1c11187EaFf26279b,
            0x8BeC003E9FEA2fF3B25ED7bcDa3A7280217A8385,
            0x56DD83576Ed110651a16aa68403f45D14f636575
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984] = LenderTokens(
            0xE2A9e57B7A4A4F85BCa3AA2CDed9Ae98647066C9,
            0xeC8218D3f2155bCD9DDF1E8d7F228864a2e052d9,
            0x01e2485d4f45211E3EcF3A9eB6b7C81057FE9830
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0xdD4C49DAC41ED743052E9f7abaC316b76EE42e36,
            0xBA831825E3bC7CDaFb59cA02eD2b31A1232d3b33,
            0xD8261FB5aA367006057758234533FAe08e6D5509
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0xBe9895146f7AF43049ca1c1AE358B0541Ea49704] = LenderTokens(
            0xA9F92E32a1c0c0bdc58EaE49585FFB2e3B8A99d2,
            0xb41bD965FD0954C3bd4EdAE1A9A07816788B657C,
            0x1b7666d926c3e715D342E61C2913f15F8a8ca421
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x6c3ea9036406852006290770BEdFcAbA0e23A0e8] = LenderTokens(
            0x24378AA0D97E3bD72bd0A0443306602DE4583456,
            0xaC1bbb316c84B672a86AaBEc5d4ec53b8D26cE98,
            0xeCc06b626930B70937C58c51F97Ac34d56aEa7b6
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x9D39A5DE30e57443BfF2A8307A4256c8797A3497] = LenderTokens(
            0x25dE46b8491c43C88c9E615336210928CA64091C,
            0xa9f3915ed6d1473AeE84a3666155eA8A84719177,
            0x4aDb7d1d5408C696F75f6147F9C3a07c0B0ce195
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x8236a87084f8B84306f72007F36F2618A5634494] = LenderTokens(
            0x37b64FC5BABDf70A027099FC7B75bF77a0b23e34,
            0x8715d51b9760EE99Cf4c623337EC5d673434cC3f,
            0x782167D86b9cfFC5AD3aB128854645e948f8AE03
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x45804880De22913dAFE09f4980848ECE6EcbAf78] = LenderTokens(
            0xf63667FAb833B603252482De83DE152034c2B7Ab,
            0xE45c5C5e45782CDd46B0D714fBFc65E906fd910E,
            0xC047Ddc4C3334F5c4CEb54e665bE03c82C65b161
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2][0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9] = LenderTokens(
            0x250eE3866880524423d5BB7059a9D33678475b6F,
            0x31afFa4d49122F8EcD984f2eAd2DDa3F574Fbdc2,
            0x176fe15d75B87b3836CcC7374372c834fdbB59c0
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.RADIANT_V2][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(
                0x9915A7389f8FB33f9b77d84119c06e8BFfB12BE4,
                0xC1e02d3F3C7282Cc2D15fb6a5Cc40130427107b1,
                0xFaf76422fb363aED15DAD0eeC5aD1876AaDc3782
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.RADIANT_V2][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] =
            LenderTokens(
                0x40351090037b9c4f6555071e9B24A82B068F2c05,
                0xf81c76A058Ed8962b4EAE814cd8339790BD7b4c8,
                0x48594F06F59CaaA19a78124CED2c8a91403aea58
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.RADIANT_V2][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(
                0xD083Fb8dB6Dbc83386dc20075BEc8D0722b3056B,
                0xc589B9AE9E4aA780AF7a6BC2E9DE27a532B2A278,
                0x735717CADd9e0506459Ec9a24a968857A8d4D13a
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.RADIANT_V2][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(
                0x36594B6C976d05A6fF442B38Cfc3eFe0C01E0359,
                0x7473D4Eddd1d78b7df950219003d1B9D74e3980f,
                0xA8A933acD3D86269540BB218B50991de43fea3Cf
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.RADIANT_V2][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(
                0x15cc621cfD1D0527CE6894fc07D97B2C06520D57,
                0x94B6F75cb5c5E01cDFd1396420B499F3a7496300,
                0x94D651D2482850E7453aF87bdc46D57425CaB022
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.RADIANT_V2][0xa2E3356610840701BDf5611a53974510Ae27E2e1] =
            LenderTokens(
                0xd456F6216cB098b7999c76BE4F58f5121BAd8be8,
                0x75CcD694D057086DB838e0cbE91E92223A6b5C55,
                0xc3C358eC31914EC442868fC4b2987C0f5c2cF87f
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.RADIANT_V2][0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409] =
            LenderTokens(
                0xD319E074c789C978E92f20345Eb739b9A670e4d8,
                0x054321Fe1549502a702883712B70C48977a923bf,
                0x4be93E11f7039993f0Bd04a97990BB29F3106c96
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.RADIANT_V2][0x26c5e01524d2E6280A48F2c50fF6De7e52E9611C] =
            LenderTokens(
                0x701810c95AA1521d56C2BE5848A1B15be5954Ec3,
                0x5cc83215C1E225105Fe787b6F21A884c75Aecf22,
                0xb249efF73E043bC2e4E76F11657eC55700f1Aa6d
            );
        lendingTokens[Chains.BASE][Lenders.RADIANT_V2][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = LenderTokens(
            0xC2dDb87Da8F16f1c3983Fa7112419A1381919b14,
            0x392376C337413ce2e9ad7dD5F3468Ae58F323B00,
            0x1d8234E53Dde5F2859e5EE67Afe9E6782C80890F
        );
        lendingTokens[Chains.BASE][Lenders.RADIANT_V2][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x47CeFa4f2170e6CbA87452E9053540e05182A556,
            0x2455485C868C94781AA25f3fe9a5F9A6771D659C,
            0x65675c472A5F40565B07F0947E2798c6F46cAaFa
        );
        lendingTokens[Chains.BASE][Lenders.RADIANT_V2][0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452] = LenderTokens(
            0x43095e6e52A603FA571DDE18a7A123ec407433fE,
            0xb8EB4737c7dA019F26a297C8020F024BAA0c61D7,
            0x2D5c83a489880C0366695e03490Cd85FEBDc370C
        );
        lendingTokens[Chains.BASE][Lenders.RADIANT_V2][0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22] = LenderTokens(
            0x20508bA938fEdaE646FCAd48416bC9B6a448786E,
            0xf349787feD9c02bB7D4928FBc2c3d51A38ED7FbB,
            0xfE29c44869Cf1cA7b34AEFa4A7204b47797340C2
        );
        lendingTokens[Chains.BASE][Lenders.RADIANT_V2][0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A] = LenderTokens(
            0x223A4066bd6A30477Ead12a7AF52125390C735dA,
            0x73a53a1d90FC37bC6EF66e25C819976CC2ad7D22,
            0x89Cc1618C774626Ca81710C3CdA8a269aF972EBf
        );
        lendingTokens[Chains.BASE][Lenders.RADIANT_V2][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0x633eBD78E0eBE2ff2e2E169a4010B9Ca4f7bCAa1,
            0x40eb2d8E246915d768a218880CC52BC6993Dc2b4,
            0x204d3fDEf84BA08A452FbED235ECfC8431CCe97f
        );
        lendingTokens[Chains.BASE][Lenders.RADIANT_V2][0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42] = LenderTokens(
            0xCF2170F09De0DF8454c865d972414F5bE696CF89,
            0x7A2D83558c405D7179843C338644a22e7e5bA28A,
            0x2ff00F60872124Fb24191Dc7b36ce2C55F489268
        );
        lendingTokens[Chains.BASE][Lenders.RADIANT_V2][0xecAc9C5F704e954931349Da37F60E39f515c11c1] = LenderTokens(
            0x6F77BE7bBd7c24565a68781030341a7E3DB2946a,
            0xdD8FF03a171e976fb5624e9Ebc1d397cB242c4BE,
            0x5f53dD0C58978b9E8999d22A57ff5ecd25BAD1C5
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] = LenderTokens(
            0xa366742D785C288EcAD8120D5303Db4EB675c9EC,
            0x2cECa734Ae0A437314a73401Db89a2560584b17F,
            0x42c43096272bE726fEfa0D667021205B42F9f780
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] = LenderTokens(
            0xfB6f79Db694Ab6B7bf9Eb71b3e2702191A91dF56,
            0x330243dcBd91AcDD99b73a7C73c8A46e47FE386c,
            0x09136677313D3E2dA36a41cb912B15766883268b
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0xaf88d065e77c8cC2239327C5EDb3A432268e5831] = LenderTokens(
            0xb1D71c15D7c00A1b38C7ad182FA49889A70DB4be,
            0x7bF39AF1Dd18D6dAfca6B931589eF850F9D0Be25,
            0x22fED8c48Da3a66321b488b5219F162a2D29e941
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] = LenderTokens(
            0x62f9F05F3af1A934f0e02EAd202E3de36a6501E6,
            0xe0499561642AFf7a149f59Cc599484d9D2dC60DA,
            0xDF21fc8bafEFbb19A9e9040Fe2840Ac218683dF3
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0x5979D7b546E38E414F7E9822514be443A4800529] = LenderTokens(
            0xBe6E57d96674e4873173DA7D48c1efbC55F2fA37,
            0x78587e08e71a65976e98E4eef9f3337a1dFB6eBA,
            0x36424f81740658F63f93648D4E86A254852d5e97
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe] = LenderTokens(
            0x44e1C41E6CA07198edBdb4d3E41A7dEF2e06CD8F,
            0x04f2a8F7fCC86cdDCCA89e1EA98F333Cc072FB95,
            0x75D2aA6a86381AeA3f7e2577c7A1435dbcA83A6D
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0x912CE59144191C1204E64559FE8253a0e49E6548] = LenderTokens(
            0xC103b64Ae78AbDF2B643AA684440ef4CF3759B0B,
            0x60a60E28fD7E44c60c4087837716374b14C7450D,
            0x2335A96B3Bf7cacb7c38d7F7DB59141BBEa18423
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8] = LenderTokens(
            0x24957644116967962bF1f507e7aD9498836a0132,
            0x9D4179826950a36a46144AEdB51269cA6c4ae87b,
            0x5009E5a7785abFd77868Ec436ea32f27a2efEfe7
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0xf97f4df75117a78c1A5a0DBb814Af92458539FB4] = LenderTokens(
            0x1F6cE88620326B146C47cCCD115D23EE48042b9F,
            0x469be5f178c3b4BC43F8ac420958d58f8889E5F8,
            0x4b35273FAD7833456B395F8737437995f9936f29
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0x4186BFC76E2E237523CBC30FD220FE055156b41F] = LenderTokens(
            0x75ec0FccaBB297849BBCb4C2A1c3B760F1d8968f,
            0xB73d597F15278bE1233F0822B177Df2f90Af5E2a,
            0x5a0c707132EDb0D1C487B711c4A4fe4cD8847395
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0x3c284500401C12D873ff156b131901AB73CCA34E,
            0x0e95Fe1DA263F267A6B7c7fe9632BF2a6b178C66,
            0x01902ECF8faCbf339F66d8E177aB58Fda4507365
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.RADIANT_V2] = 0xA950974f64aA33f27F6C5e017eEE93BF7588ED07;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.RADIANT_V2] = 0xCcf31D54C3A94f67b8cEFF8DD771DE5846dA032c;
        lendingControllers[Chains.BASE][Lenders.RADIANT_V2] = 0x30798cFe2CCa822321ceed7e6085e633aAbC492F;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.RADIANT_V2] = 0xE23B4AE3624fB6f7cDEF29bC8EAD912f1Ede6886;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_SOLVBTC][0x7A56E1C57C7475CCf742a1832B028F0456652F97] = LenderTokens(
            0xd6890176e8d912142AC489e8B5D8D93F8dE74D60,
            0xc319b085c78b55683BbDbE717a3aeb6858D5BAc3,
            0xB05b8D868153d656EB40444b0333Fb0DaD464Fb8
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_SOLVBTC][0xC96dE26018A54D51c097160568752c4E3BD6C364] = LenderTokens(
            0x5E007Ed35c7d89f5889eb6FD0cdCAa38059560ef,
            0xf7d1F417712205D51350aE9585E0A277695D9dee,
            0xaf84eb227e51Dbbb5560f7Cf507e3101ef98147b
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_SOLVBTC][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] = LenderTokens(
            0x81392304A5bE58e1eb72053A47798b9285Eb948E,
            0x33D54cdD544bFDB408dabD916Af6736Ea5be867D,
            0xd684C4B6abeeaa5cA79F30D346719c727D2072D3
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_SOLVBTC][0xd9D920AA40f578ab794426F5C90F6C731D159DEf] = LenderTokens(
            0x2E6500A7Add9a788753a897e4e3477f651c612eb,
            0x5ee930400cc7675B301d57E38AE627822CafDF68,
            0xe8fD5c5f889cd7fb67Ea2b58E9246131Fb2aBb6A
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_SOLVBTC][0x23e479ddcda990E8523494895759bD98cD2fDBF6] = LenderTokens(
            0xc6AB82fc782E29B385E775Aa0D12C3278358c9e2,
            0x6effd87a9fB070eeCBcEbdC68AeF055cAeD6EFf5,
            0x539DB87e80c706fA3789Cf55d743b5FDf61aCE49
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_SOLVBTC][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] =
            LenderTokens(
                0xB74eb18445A5CDe001fdfcC74DdbA368CF4C6f2F,
                0xfb6950161d274aD71E60A133a026809ba3aE76eD,
                0x4568911872E6aD1f641eF59a5C3962aef4fCE46E
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_SOLVBTC][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(
                0xd9F57906908A81B9EBB9D1aAD8E9e0182ac40CcA,
                0x6FA965fbA8CAC1c7eCC34D17bA8da5da68E3b6c5,
                0x05DD96317BF7c6d412e96807c36da0521F856F0E
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_SOLVBTC][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(
                0xfcefbD84BA5d64cd530Afb2e8DDEa7b399A9fC53,
                0xF9BFCA5be4b8F0Ea9897C3AEfEEe2600d8F482F4,
                0xB1CbA901451fa865e0EbBFa8f96786824d21f3D0
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_SOLVBTC][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(
                0x5d0bCE6C62CcaAB75Eb91916e58639205C421828,
                0xBDA5E2c16c0C116815CEeb9AddBC71cD03A58f04,
                0x5aB9c74D24131bbE78EecBcD8c7F341e71Ca5Fd2
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_SOLVBTC][0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7] =
            LenderTokens(
                0x516490F83f7587fc74c02bF0a0D06547f8Edb0Ab,
                0xDe42ce975c4D1164DdC2a51911d75c56390c09f1,
                0xa8A1Efb71aF0bBFE357CB922c7E88eC111E50995
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_SOLVBTC][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(
                0x69a8727c11d82fAc82beDEcC51Ae5513ECeb6989,
                0xAA43Ce91bDeBCccedd0d2A974B0F534AF7F010FA,
                0x66DFA369fc913C16DCEA3Dc12C28c1cD3e2B9ed7
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_SOLVBTC][0x53E63a31fD1077f949204b94F431bCaB98F72BCE] =
            LenderTokens(
                0x81F3652c30644E5608318767DFA5CF34Ca74fDf5,
                0xb34ba89157B22F8E4A9f177F203C9ae4BBc4df84,
                0xF755A976b925F4dAA397E8AbD6F189B0Fabc10dd
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_SOLVBTC][0x1346b618dC92810EC74163e4c27004c921D446a5] =
            LenderTokens(
                0x5264ddCF2bb6A14eA72300E6e7f2d547be386553,
                0xb73beC58fd93c56beEB22f1967CDED1C994Bf7C9,
                0x1217A4FC546BdC9f5600f07a3E1c55dAa25B9EB9
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_SOLVBTC][0x541B5eEAC7D4434C8f87e2d32019d67611179606] =
            LenderTokens(
                0xdFDcc76a07cd126f43D3845184e56D4bb4F253bC,
                0xD0B3F785dF374F7Ee8AE8A4760E2FF8A515Bb772,
                0x0ff054D3c7eA2097d9682139744399F6c4E83B3b
            );
        lendingTokens[Chains.MODE][Lenders.AVALON_SOLVBTC][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] = LenderTokens(
            0x81F758C30b4c32e928B0E46AA9e98B0831DA8DA3,
            0xfDB6B779779B5e6426779EA2680cdB19967DD240,
            0x90FE578317018CA5dcCA53573A6e9beb838747D0
        );
        lendingTokens[Chains.MODE][Lenders.AVALON_SOLVBTC][0x59889b7021243dB5B1e065385F918316cD90D46c] = LenderTokens(
            0xEcEEd2A7be46f06AEe1D8f1B6ad73020E67dDF32,
            0xF8432Fb5921e380B17DaeD24C0BE669EcE3d6248,
            0x1f9E332806C67dC741DdF25F52ABd0e4230Eb22c
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.AVALON_SOLVBTC][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] = LenderTokens(
            0x8C9510db49b00F44e9C358016E95C8103b362bDe,
            0xF8B03861429336D592225a404360EE96C7Cbc411,
            0x88449B49264b948929ffA0E6986f528DA9Bf4114
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.AVALON_SOLVBTC][0xCC0966D8418d412c599A6421b760a847eB169A8c] = LenderTokens(
            0x2e7dc6260112F2d496A9Ff7D0A5CC38B3eaddDba,
            0xaE28c4d9EC1F095aE9151c13B29c58c74e020141,
            0xdee8aFF742789A51cecE45A2Ee849Eb5C2D98967
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.AVALON_SOLVBTC][0xf7fB2DF9280eB0a76427Dc3b34761DB8b1441a49] = LenderTokens(
            0x89c4e1834F4b3131f8a67F60d85E0C36f12D3fcc,
            0xb128D37bC3F84022A667440Bc5d4340f313a8522,
            0x731b895d0CD5f2210D259C6e95Bd320816F11aaf
        );
        lendingTokens[Chains.CORN][Lenders.AVALON_SOLVBTC][0xda5dDd7270381A7C2717aD10D1c0ecB19e3CDFb2] = LenderTokens(
            0x1c0e090319797284D30e346F18A56389d52a4825,
            0x2258c93b4dD7108407b83cF5028D45536401d963,
            0xEf31ABf53DC6d89dcAd8ae71f044e698cF46937f
        );
        lendingTokens[Chains.CORN][Lenders.AVALON_SOLVBTC][0xCC0966D8418d412c599A6421b760a847eB169A8c] = LenderTokens(
            0xBAba0f474c481F4E8420AB9A7E0c82e5198Cfc93,
            0x077d0583b68873E8ee726AD6225d7aE96Da22267,
            0x625c588c1F18Eb3CB2A21f7A38245038f8B92338
        );
        lendingTokens[Chains.CORN][Lenders.AVALON_SOLVBTC][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] = LenderTokens(
            0xa5E99997DAffaAfd74e2F521c5DcFc5ac37CFe6a,
            0x172E6af1202d6753Edf7CbA82f34C3aa412Dd11D,
            0x75733A2Eb3e3466e09F8FEc9f92524167dEd99d0
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AVALON_SOLVBTC] = 0x35B3F1BFe7cbE1e95A3DC2Ad054eB6f0D4c879b6;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_SOLVBTC] = 0xf9278C7c4AEfAC4dDfd0D496f7a1C39cA6BCA6d4;
        lendingControllers[Chains.MODE][Lenders.AVALON_SOLVBTC] = 0x7454E4ACC4B7294F740e33B81224f50C28C29301;
        lendingControllers[Chains.TAIKO_ALETHIA][Lenders.AVALON_SOLVBTC] = 0x9dd29AA2BD662E6b569524ba00C55be39e7B00fB;
        lendingControllers[Chains.CORN][Lenders.AVALON_SOLVBTC] = 0xd63C731c8fBC672B69257f70C47BD8e82C9efBb8;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_PUMPBTC][0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e] = LenderTokens(
            0x1A91E084c693dB7DBEaCd7726DB56e5A340Fef10,
            0x35AfAeC9c4Fd186235EfCa0F5e56C5a421C48876,
            0x6B5480427b0c2E3816FbB30cA1A481a32a07e76D
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_PUMPBTC][0xC96dE26018A54D51c097160568752c4E3BD6C364] = LenderTokens(
            0x249E8e0045d7c3d0dcD38943b83FEed190a62F44,
            0xbE6089669BCFAbEfa6E87599D7205BA8Cd4FaE20,
            0xbA37B83e82BCcBD1A48b500692F6106cF9e36C14
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_PUMPBTC][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] = LenderTokens(
            0xdd92Bb45815Ea0C3461EC2FF2B6f5Cd6b99294c6,
            0x9CE87e03E3e2623e79Fc8020da472715bfCBf40F,
            0x0f2A52E961EcE431E40cC1068862d96E54D76e54
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_PUMPBTC][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(
                0x67ff045c9e904616F650e8125a4176aE6EC23ECc,
                0x8834E0732Ac0d37e14956c542b9D8dC30eb40eE4,
                0x9126F9bC64CE6ad0f326a6e31B4c27DB38a5b5b0
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_PUMPBTC][0xf9C4FF105803A77eCB5DAE300871Ad76c2794fa4] =
            LenderTokens(
                0x1fa40670A571b17E3F61251880C768ede5764fCc,
                0x65a3B6E4C557AaE79d0F1FB3184b732ade66Fe7A,
                0x373611A337B6c7A89a1202f8FCd04045E47b233f
            );
        lendingTokens[Chains.ZETACHAIN_MAINNET][Lenders.AVALON_PUMPBTC][0x1fCca65fb6Ae3b2758b9b2B394CB227eAE404e1E] = LenderTokens(
            0x81F758C30b4c32e928B0E46AA9e98B0831DA8DA3,
            0xfDB6B779779B5e6426779EA2680cdB19967DD240,
            0x90FE578317018CA5dcCA53573A6e9beb838747D0
        );
        lendingTokens[Chains.ZETACHAIN_MAINNET][Lenders.AVALON_PUMPBTC][0x13A0c5930C028511Dc02665E7285134B6d11A5f4] = LenderTokens(
            0xEcEEd2A7be46f06AEe1D8f1B6ad73020E67dDF32,
            0xF8432Fb5921e380B17DaeD24C0BE669EcE3d6248,
            0x1f9E332806C67dC741DdF25F52ABd0e4230Eb22c
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AVALON_PUMPBTC][0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e] = LenderTokens(
            0x9a02588DDff4d079cC5BEB1b864B12410049288a,
            0x02edfFA0298313763803089e92e491C915E0e7dD,
            0xb765168E68936Ce1C6dD03a56f0D4d70B833A5bC
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AVALON_PUMPBTC][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] = LenderTokens(
            0x0b37eE41a3b80431A444d7F3d9F0edE9023BE000,
            0xCb4d00EaaF3562469a397994897e7384A124395a,
            0xd7470Feb942dAA7BaEE8b1Ea807db7abE5d04447
        );
        lendingTokens[Chains.CORN][Lenders.AVALON_PUMPBTC][0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e] = LenderTokens(
            0x6b00d96982bDddABC6c8B77c7F927fc36F52956F,
            0x7A2F15121a318b4c62C8F7CC3b8112C4e4c20aE5,
            0xdD95Bb6898A50422341ccD5888cf7ec3188A7CC2
        );
        lendingTokens[Chains.CORN][Lenders.AVALON_PUMPBTC][0xda5dDd7270381A7C2717aD10D1c0ecB19e3CDFb2] = LenderTokens(
            0x397070528a821d68C26f0558f4E816c91a0B3417,
            0xb3dA65Fb32382292aaC3FA2638C71f142362c537,
            0xf3B59e299Bf9cfbc2e5729d88b5b1F2797D4d72B
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AVALON_PUMPBTC] = 0x1c8091b280650aFc454939450699ECAA67C902d9;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_PUMPBTC] = 0xeCaC6332e2De19e8c8e6Cd905cb134E980F18cC4;
        lendingControllers[Chains.ZETACHAIN_MAINNET][Lenders.AVALON_PUMPBTC] = 0x7454E4ACC4B7294F740e33B81224f50C28C29301;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.AVALON_PUMPBTC] = 0x4B801fb6f0830D070f40aff9ADFC8f6939Cc1F8D;
        lendingControllers[Chains.CORN][Lenders.AVALON_PUMPBTC] = 0xdef0EB584700Fc81C73ACcd555cB6cea5FB85C3e;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_SWELLBTC][0x8DB2350D78aBc13f5673A411D4700BCF87864dDE] = LenderTokens(
            0x1F0b7f50F8b4F4e7C65988cb074bf96beAD580BA,
            0xc3ff8F91F47487a2BA8De69F901d6b91CC4FE797,
            0xbC1b3B8dc8ADEAd5556359454e8E2f1f27125d7F
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_SWELLBTC][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] = LenderTokens(
            0x1C2C0B01E32b747A06e6eA0C2D07Da1a586C59bB,
            0xce9CeFF2e11c8e28B7F70BFa62C65D3BF46b7bcd,
            0x0F84A47844FfD67db55A3013A68A7DFbf5c1DE83
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AVALON_SWELLBTC] = 0xE0E468687703dD02BEFfB0BE13cFB109529F38e0;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_EBTC_LBTC][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] = LenderTokens(
            0x822790Ffcce58EaF79D869404402378C05Bc2c69,
            0x3cc219F53d813054DD5F5a6126404E6a029006A6,
            0x6e26bF6122b68Ee15d54E7D486E6242d0688Ec92
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_EBTC_LBTC][0x657e8C867D8B37dCC18fA4Caead9C45EB088C642] = LenderTokens(
            0x3C9f186f1c11d28d28cDfbfbb74fe311baE9C059,
            0x9E1Bfcb533104b5Aa1F80b33e10BEbdbd78f0637,
            0x1D76FD1466a356d6A823408f3139669DEa21cb23
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_EBTC_LBTC][0x332A8ee60EdFf0a11CF3994b1b846BBC27d3DcD6] = LenderTokens(
            0x243744653A4Cf96e974A3B9C19C93bFF287727ec,
            0x682A2B28E94BD3B52140feaEBBd4EfEc02082a48,
            0x27B58833BB08Dd478d12Bb93Ae0dDa012FE7468a
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_EBTC_LBTC][0xB997B3418935A1Df0F914Ee901ec83927c1509A0] = LenderTokens(
            0x442252245af0e6F7410F1a79E0F186e2d91907CB,
            0xD350e7DAcdBe19008D2530Fb256b5B6C8a583033,
            0x128321c3fA48B47BA4E4BD1648F829F5F6048FFA
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_EBTC_LBTC][0xEc5a52C685CC3Ad79a6a347aBACe330d69e0b1eD] = LenderTokens(
            0x950Ab8C438099dda466020986c4aD74F0747441B,
            0x87423FCA4EEf5F4144fD8dF95f158C8579C0eE52,
            0x7216b99E42c2537DD0f1E36FBB5ce0336b225a95
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AVALON_EBTC_LBTC][0x8236a87084f8B84306f72007F36F2618A5634494] = LenderTokens(
            0x8ae0014964227fE378bC1C4Cc27982e6b4351a65,
            0xba835C7e44d522814486CeaedDad030aDD6c00F0,
            0x37D07BDd191e77ee5538BF6446a3e77A3158FF79
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AVALON_EBTC_LBTC] = 0xCfe357D2dE5aa5dAB5fEf255c911D150d0246423;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_UNIBTC][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(
                0xd8207B6D219c5D40c868f1C4e5235573a8B566BF,
                0x1348A512Bc5aea5a39BB3C78636E230D27C71F1C,
                0xA5CdAFfB57e7C1e73483C1b394B317553058B10E
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_UNIBTC][0x6B2a01A5f79dEb4c2f3c0eDa7b01DF456FbD726a] =
            LenderTokens(
                0x12Ce224e5948288Ee8F5eCa838195dB472f5428A,
                0xb1E1C2635a35210e49d0e7a47378330295870FD4,
                0xB16d7CBAD0942647AA15efF717F39bc644CB519F
            );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_UNIBTC][0xF6D226f9Dc15d9bB51182815b320D3fBE324e1bA] = LenderTokens(
            0x810405900a4bF739A6fE39227f5f7b95a4B929a8,
            0x2300B1eD110050d46A3999A9c1C79D44c7FD6919,
            0x024bcB9944F019Cb2Ef3FddDEcBb81ABc006e543
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_UNIBTC][0xB880fd278198bd590252621d4CD071b1842E9Bcd] = LenderTokens(
            0x2eDBa2700891b285Bff6d7951579E27ea7aBe8A5,
            0x5609CaA0914CfcB6164b5B84483524779AA2516a,
            0xFFC00750b49e9846991e6113B2D8587BB57FeDAa
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_UNIBTC][0x93919784C523f39CACaa98Ee0a9d96c3F32b593e] = LenderTokens(
            0xcB0F3A8fd1eF0548bd4bf0454546c7B304920E9e,
            0x23B8138aDe9C304582C97dfCEa7f490cdA0C73e1,
            0x4AF698391297c36351217A0a450b0BEC39166C30
        );
        lendingTokens[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON_UNIBTC][0x93919784C523f39CACaa98Ee0a9d96c3F32b593e] =
            LenderTokens(
                0x7b15b3267E8bfAE333e09F5829fc25E9a1D1Ca2a,
                0x1c37e7285511FC4414fBe6D270a7fDb1b86B1cd5,
                0xfCeab0B7700D5037411016D44e4b5A6428f5d7A4
            );
        lendingTokens[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON_UNIBTC][0x6fbCdc1169B5130C59E72E51Ed68A84841C98cd1] =
            LenderTokens(
                0x3a6ad8BE3DfBeE6D41ffcCa63D770C23B3b426E2,
                0x359FDe7d98989a6701d98A24477F3a194f978e3f,
                0xc469BDAE8255C3a42CDCd53344920ccB053c9c1b
            );
        lendingTokens[Chains.MODE][Lenders.AVALON_UNIBTC][0x6B2a01A5f79dEb4c2f3c0eDa7b01DF456FbD726a] = LenderTokens(
            0x72419C43BD1d16A1C1dBaac6DD46E696C6584b87,
            0x4a5D56b92B0384579102abF131C45a1Ed425F935,
            0x0EE4609905D0421c95Bd2869Ae5981a3dCBa6FdA
        );
        lendingTokens[Chains.MODE][Lenders.AVALON_UNIBTC][0x59889b7021243dB5B1e065385F918316cD90D46c] = LenderTokens(
            0x78637bFb0f5989c4F595AD46dae9F255e00862bC,
            0xb4309E1559C857758C82CD469431CFA81d19e8E4,
            0xD3b07edaF1DeeCe44d87BC84d6feB5AFe383964f
        );
        lendingTokens[Chains.BOB][Lenders.AVALON_UNIBTC][0x236f8c0a61dA474dB21B693fB2ea7AAB0c803894] = LenderTokens(
            0x68a9830103793AB3b3B4114E1e4E7EFd5F776dcA,
            0xa33BC30B0d2F9390f81110911265FEBA75842e14,
            0x10F118B8e31435dD3e7Ef1Bfe3Ce9FA7AD27b598
        );
        lendingTokens[Chains.BOB][Lenders.AVALON_UNIBTC][0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3] = LenderTokens(
            0xED9BdAE9E7Cae0E7f2775ef5AcdbC2EA800EDad5,
            0xDa41747B8617305B0E370Bcc49259F876489b4f5,
            0x33d348BBE2480cC3e3E189FcCCcccbF592a12314
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON_UNIBTC][0xfF204e2681A6fA0e2C3FaDe68a1B28fb90E4Fc5F] = LenderTokens(
            0xBdd2e24c10bD4668bf838dBcA5287BbD21da0Ca8,
            0x0D62Fe8F31Fd249747e6169E453Ba5162142162a,
            0xBacF6534A60D8DBb599d755b4355f4B2C480f44f
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON_UNIBTC][0x93919784C523f39CACaa98Ee0a9d96c3F32b593e] = LenderTokens(
            0x513794d3d6c3B6dCe31Dd58c7f27E2529105F90C,
            0xFb10da763B363aB911a95763A8A01Fc7A58e1aB6,
            0x379628F8563A1b90F552447f4c195fCa5f1a5F5b
        );
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_UNIBTC] = 0x795Ae4Bd3B63aA8657a7CC2b3e45Fb0F7c9ED9Cc;
        lendingControllers[Chains.MERLIN_MAINNET][Lenders.AVALON_UNIBTC] = 0x155d50D9c1D589631eA4E2eaD744CE82622AD9D3;
        lendingControllers[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON_UNIBTC] = 0x99a05a9210B2861ccED5db7696eED3f4D73EB70c;
        lendingControllers[Chains.MODE][Lenders.AVALON_UNIBTC] = 0x2c373aAB54b547Be9b182e795bed34cF9955dc34;
        lendingControllers[Chains.BOB][Lenders.AVALON_UNIBTC] = 0x6d8fE6EAa893860aA1B877A8cA4f0A6cbd4249f7;
        lendingControllers[Chains.BITLAYER_MAINNET][Lenders.AVALON_UNIBTC] = 0xC486115C7db399F0e080A3713BF01B65CC8A5b64;
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AVALON][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] = LenderTokens(
            0x6c56DDcCB3726fAa089A5e9E29b712525Cf916D7,
            0x09d18C81d3e651C0f892233Ae5B39a9cBF684FF0,
            0x56F4e2CEDD5f33040bF3381870C0BA7df843DC27
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AVALON][0xCC0966D8418d412c599A6421b760a847eB169A8c] = LenderTokens(
            0xe3a97c4Cc6725B96fb133c636D2e88Cc3d6CfdBE,
            0xa28677f431E3597b70cbbD561F801868dC37e946,
            0x7D2A701b4dE51A751E8C744207f1b4dB6E180C14
        );
        lendingTokens[Chains.B2_MAINNET][Lenders.AVALON][0x796e4D53067FF374B89b2Ac101ce0c1f72ccaAc2] = LenderTokens(
            0x3C38b2e9A9F5213748F68cD4d4cd04168BC727A3,
            0x16F7b7e84ACA905FA45EAbEDC4E1D0e098557C27,
            0x5AE01d9996C7af35768F571267397E230d94d858
        );
        lendingTokens[Chains.B2_MAINNET][Lenders.AVALON][0xf6718b2701D4a6498eF77D7c152b2137Ab28b8A3] = LenderTokens(
            0x7f9771A4515e21AFf520ce7AfF5Df34c39389002,
            0x296831a1C196ad924C21243e26F5E286ECaCDf08,
            0x680915169D27Fa3Fcf6d94EbD0dAb15D6332a2b2
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON][0x40375C92d9FAf44d2f9db9Bd9ba41a3317a2404f] = LenderTokens(
            0x93De2dBbF2e4905dBc3186558f0DBA15be00f7F8,
            0xE27eDe8d845801ef9E3362eB0580840b97630f26,
            0xAAddfb476c1c895Ec4BcD024420A2267A56709FA
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON][0x8034aB88C3512246Bf7894f57C834DdDBd1De01F] = LenderTokens(
            0xaB91398e0C94064F7725a169bf8889efDaDa153f,
            0x399142e408265A4d1913E9ce8F711E4509482c84,
            0x07C6a61DbC10D44a4518d02BD73b08BEE096399c
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON][0xa4151B2B3e269645181dCcF2D426cE75fcbDeca9] = LenderTokens(
            0x07820af656f52fCE6a98e0096a5a2B3289C88022,
            0x9726AAFc19a4c3bAcc23AcE00754675Ef783b8D3,
            0x6ce20896fFBBEA849F0A183Ba7E032E62dCDf7E1
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON][0x900101d06A7426441Ae63e9AB3B9b0F63Be145F1] = LenderTokens(
            0x3b4102fDcE56e1Ab83a2003c2C82750FeCe130b7,
            0xA5C74913B5895bA84eb6F0EB61878a3ea96268D5,
            0x071d70ac38eac7bfbA7d5E33d27d62C02c33A725
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON][0x5B1Fb849f1F76217246B8AAAC053b5C7b15b7dc3] = LenderTokens(
            0x4C94260Bf9E0E1f168F3812A34F8E16EAf1446D5,
            0x4A474c53A4e62D9Fba99711907507ef1C9607097,
            0xE12Ea0eb3e6D221574bf7a66c97BB6269A55b895
        );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON][0xe04d21d999FaEDf1e72AdE6629e20A11a1ed14FA] = LenderTokens(
            0x848f91AfeFaDfC925C57939494599E44280E55E7,
            0xa401101c7b035773D536c734643cc31fB0D31368,
            0xA3B1153313667a91E7f5c0d95c1dE19c9Cc978b2
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.AVALON][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] = LenderTokens(
            0xB580f9e4936F3fF990A4fbe4821f43D42eFfFa67,
            0x56dB14cA01dC473Ee585917760717F8dB0bce431,
            0xB3665339B5e81B0d9EBDFcc95aC28f5C546995A1
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.AVALON][0xCC0966D8418d412c599A6421b760a847eB169A8c] = LenderTokens(
            0xab7035BB3C8511191DCc059831511cC116E60300,
            0xD767f1B7504d1c0dcb4CFB7CCCCf0402C6e7D923,
            0xe4607cfC503cDFb91882396e67379BF9cb137573
        );
        lendingTokens[Chains.GOAT_NETWORK][Lenders.AVALON][0xE1AD845D93853fff44990aE0DcecD8575293681e] = LenderTokens(
            0x9a02588DDff4d079cC5BEB1b864B12410049288a,
            0x02edfFA0298313763803089e92e491C915E0e7dD,
            0xb765168E68936Ce1C6dD03a56f0D4d70B833A5bC
        );
        lendingTokens[Chains.GOAT_NETWORK][Lenders.AVALON][0x3022b87ac063DE95b1570F46f5e470F8B53112D8] = LenderTokens(
            0x0b37eE41a3b80431A444d7F3d9F0edE9023BE000,
            0xCb4d00EaaF3562469a397994897e7384A124395a,
            0xd7470Feb942dAA7BaEE8b1Ea807db7abE5d04447
        );
        lendingTokens[Chains.GOAT_NETWORK][Lenders.AVALON][0xbC10000000000000000000000000000000000000] = LenderTokens(
            0x0ba2D99059e43f0437E28F9C5B5dE1a736643AD0,
            0x812b06C9D2985eDa494a1C8BBA1F25A369F84848,
            0x55ce81413Fa3df21A42ce54dd94762dE58c3A664
        );
        lendingTokens[Chains.GOAT_NETWORK][Lenders.AVALON][0xfe41e7e5cB3460c483AB2A38eb605Cda9e2d248E] = LenderTokens(
            0xf3B922f1554bbCa5225B76d4386A5b35eec56668,
            0xD3D9A5517F5Dee1362eF8e4e14C1e7D0E139fb89,
            0x234C3FbA94830A22dbf0F1385f2431fd118b76eB
        );
        lendingTokens[Chains.GOAT_NETWORK][Lenders.AVALON][0x1E0d0303a8c4aD428953f5ACB1477dB42bb838cf] = LenderTokens(
            0xFA4474bE3227456E6E648CbeDCb3CC9c4374b0CA,
            0x9A342d5205A4895aeb3ED4b7EC24fc7B29461132,
            0x5cad4AC41925D19D1fF403FdBCBf7fDcE20c66a0
        );
        lendingTokens[Chains.GOAT_NETWORK][Lenders.AVALON][0x3a1293Bdb83bBbDd5Ebf4fAc96605aD2021BbC0f] = LenderTokens(
            0x7A3bFA1250Bf14233350a67b8849D9FC15cE0A09,
            0x50eAe08834FA629CB689f99543d6a628D54af197,
            0x564810351842a5cCdd02B57a86c45964D167607b
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0xF6D226f9Dc15d9bB51182815b320D3fBE324e1bA] = LenderTokens(
            0xA984b70f7B41EE736B487D5F3D9C1e1026476Ea3,
            0xc7d82b035ca1A8AEFc1c7A077AeeffBBac27e3bB,
            0xfBF7754a9E38BBbFE1cb746419f3e8f0Bf3Ba79D
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0xB880fd278198bd590252621d4CD071b1842E9Bcd] = LenderTokens(
            0xF5b689D772e4Bd839AD9247A326A21a0A74a07f0,
            0xd07A95547961c080401733139f225b694489291A,
            0x4586D19D085e498925b20105254684AcDf6f531A
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0x967aEC3276b63c5E2262da9641DB9dbeBB07dC0d] = LenderTokens(
            0xCcEC084081dEacAe8eA1b539F33d17F555316990,
            0xE3fC988F3e86F47E95Cf85d86647C91BB35B4dcD,
            0xD2a8A0bE29E2D2a2c40E84cDef39E6d2a1fD2963
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0x6b4eCAdA640F1B30dBdB68f77821A03A5f282EbE] = LenderTokens(
            0x9A6Ae5622990BA5eC1691648c3A2872469d161f9,
            0xF813C26941d7435c06c17cc044c300081168D700,
            0xD8Bc00d2548A320232801AB474414eF73C35730D
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0x41D9036454BE47d3745A823C4aaCD0e29cFB0f71] = LenderTokens(
            0xC39E757dCb2b17B79A411eA1C2810735dc9032F8,
            0x273b485837b95871d56B2dAD7884D57362Aead6b,
            0x475483D8CfeB10cE87e4Cd330FDFb347726CDAC3
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0x0726523Eba12EdaD467c55a962842Ef358865559] = LenderTokens(
            0xE465c55D68EC371B79A40FbC3B62Ba78A1D3CC7F,
            0x8dB8693e8e9ba494cf16b7f381C12417b14a0A87,
            0xec5AcF563d57877B51FEf8BA2FFFADEA1B334175
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0x5c46bFF4B38dc1EAE09C5BAc65872a1D8bc87378] = LenderTokens(
            0xFA4BE25a704dF74064eb0bFD0E3E3e460F4d16fc,
            0x39025b6e71bd95c8a5C241C23c3665B3585996A4,
            0xB82b4e6E19Ef0C0A738B1EFf93A582fbD29Fa1C9
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0xB5d8b1e73c79483d7750C5b8DF8db45A0d24e2cf] = LenderTokens(
            0x610765EB14b1508BD1E8A987f820617a0Ab742FF,
            0x5af0F8De3Fb66430d2EeF8C23F8168D4CAa90148,
            0xa40A72be6CD2e71402882A93D0DC9f1DeF23703a
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0x7dcb50b2180BC896Da1200D2726a88AF5D2cBB5A] = LenderTokens(
            0x114e9Fcc2895B82552D1FA5A6B3Ba5d572F58557,
            0x62D81409d85F10B035BFED444B605e3Fa928c184,
            0x71df6F472f560Fc7e89Ec69Cf6f445e89f14CCb8
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0x88c618B2396C1A11A6Aabd1bf89228a08462f2d2] = LenderTokens(
            0x5cc81D1E35618a15291E418C32aE99B4c6aA8430,
            0xba41Bce29150C9e93edc0d3f6109edea1e102476,
            0xC7967a4412928D355fFeDC856Ca74FdA43A6fE7a
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON][0x1760900aCA15B90Fa2ECa70CE4b4EC441c2CF6c5] = LenderTokens(
            0x2a9ab4560F30DBB4231Db16d2f86a4ff5EA889C0,
            0xf5a73dc1aa6D672E3329e30D6647B23d59383835,
            0x12123Ac2BBD007B6b40aCFd4a0b01a3fb4A4d3B7
        );
        lendingTokens[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON][0xA00744882684C3e4747faEFD68D283eA44099D03] = LenderTokens(
            0x2EE273D00253af3C8db56dCdC1F33bfF4f5EfE98,
            0xfE463C00d6E06AE6720A2f055a56Fff580DEa3AA,
            0xF820fEef75Da5D0F73202f90334341a81e95d2A8
        );
        lendingTokens[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON][0x6fbCdc1169B5130C59E72E51Ed68A84841C98cd1] = LenderTokens(
            0x5e5914a018D7ee9C93c6727E5c7e5aEEBEa1FBC6,
            0x75A992db54E1Ff6eE864519713A0480a1e701C2b,
            0x312fC46802aC581294eDdE4123d4f73006F7D101
        );
        lendingTokens[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON][0x3B2bf2b523f54C4E454F08Aa286D03115aFF326c] = LenderTokens(
            0x74F94406B6561c6Cf9A952696E1316Ee85B4BeB8,
            0xE7986A0d68AB54f5729Fead2Ee405fc663B41dD4,
            0x4456c5fd76Cb2600BF989090b48c3f8C816C0DC7
        );
        lendingTokens[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON][0xcDf79194C6C285077A58da47641D4dBe51F63542] = LenderTokens(
            0x91e0CED4656B88078B9abfd8664c223584F21187,
            0xfBa234d0204bD2032667e671702f6B0105085EFd,
            0x10B43573E15C453a421d51a1DFF5201D8C3Ca2B3
        );
        lendingTokens[Chains.ZETACHAIN_MAINNET][Lenders.AVALON][0x5F0b1a82749cb4E2278EC87F8BF6B618dC71a8bf] = LenderTokens(
            0x1F6804674aD75895d446dF4D32E23085a68261Cf,
            0xC823D0d62cF9d3f5eed220a214B2167Ed663B0CE,
            0xeE7A8a28147e79693D4799845AFB04F144ed9C94
        );
        lendingTokens[Chains.ZETACHAIN_MAINNET][Lenders.AVALON][0x7c8dDa80bbBE1254a7aACf3219EBe1481c6E01d7] = LenderTokens(
            0xFcFe0AA262b47cDA89c4461FBd52ee49F30e9cB5,
            0x7872Dc150a355cEAAD962dB9aD6cdB9e371eE1aB,
            0x364Cd4567A9401E66020Bd04b83572a7d249bd9d
        );
        lendingTokens[Chains.ZETACHAIN_MAINNET][Lenders.AVALON][0xd97B1de3619ed2c6BEb3860147E30cA8A7dC9891] = LenderTokens(
            0x61C301B789552D01938841A566A820Fc625EFa69,
            0x1B579AbC45ca519eE0Edf0a0637f2BB61e164223,
            0x62Fe24AD3f564F59Ad3F6a77Eff0C16ac824E5a0
        );
        lendingTokens[Chains.ZETACHAIN_MAINNET][Lenders.AVALON][0x91d4F0D54090Df2D81e834c3c8CE71C6c865e79F] = LenderTokens(
            0xAEca3d82084CD1999639772303FDA7130588483F,
            0xB5D23A8695274B3CC4BFeC523fF7688241Fb67DB,
            0x1EB1392b714B59C7eFdB069314C30360a3A071DB
        );
        lendingTokens[Chains.ZETACHAIN_MAINNET][Lenders.AVALON][0x05BA149A7bd6dC1F937fA9046A9e05C05f3b18b0] = LenderTokens(
            0xFc6480C5c89183224D4B81b8F153FFcC359ac94d,
            0xDBE32d6bb7A8A5240525ecD7Ad41DC549Ff6d488,
            0xE9a53BAe360CA8b94248b594A5032167865bd21F
        );
        lendingTokens[Chains.ZETACHAIN_MAINNET][Lenders.AVALON][0x0cbe0dF132a6c6B4a2974Fa1b7Fb953CF0Cc798a] = LenderTokens(
            0x4F5504f3ba8ae8DA3b48cB90C28980Fa5a46A49B,
            0x1F8d3471092de67C88c05Fa34a4C44c5E76b5E24,
            0x6c5822AB68302da484Be52f260ACdAA64db81088
        );
        lendingTokens[Chains.ZETACHAIN_MAINNET][Lenders.AVALON][0x13A0c5930C028511Dc02665E7285134B6d11A5f4] = LenderTokens(
            0x849ADA0648857b44c97F6d1E981E5Fe0160dc15A,
            0x0046185a91B0efdE66a123483d242713E19d9bD9,
            0xc606c6aA2D4Bb6a479fA023AD5835F92fa203d5D
        );
        lendingTokens[Chains.ZETACHAIN_MAINNET][Lenders.AVALON][0x48f80608B672DC30DC7e3dbBd0343c5F02C738Eb] = LenderTokens(
            0x2c3Fd0D9500bCa142363E83559493Fde5644B699,
            0xb7666E1f3d124B65BEFe9f81dAf0f81D98E85abF,
            0x4489EC031549aBDc65F1FaD7E9ed7241dbc8500B
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON][0x19Aac5f612f524B754CA7e7c41cbFa2E981A4432] = LenderTokens(
            0x75879754040101F831ccbF13B3d5A785612051cb,
            0xaDa27a9E7fC5E5256Adf1225BC94e30973fAC274,
            0x23f8182237152E8C1280A77fe976e5f85d34c47a
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON][0x98A8345bB9D3DDa9D808Ca1c9142a28F6b0430E1] = LenderTokens(
            0xAf4F993CF366eDFe80F6FAb9446287F9A33c999b,
            0xa0f150B6a7649B3BFB3973d5C3a011DE237BE58C,
            0x6608a29101D6D2f5C31D19bf7972985C3EEA6160
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON][0x15D9f3AB1982B0e5a415451259994Ff40369f584] = LenderTokens(
            0x1cdD79A4725aD4C484F623D351994B3A6BCbd31b,
            0xf36E7E7f71B64068AA34BF3A7728180a9D9e89c2,
            0xE9aA3B72837fD8E472C9B6fcd277F5960865Cc9e
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON][0x5C13E303a62Fc5DEdf5B52D66873f2E59fEdADC2] = LenderTokens(
            0xF79305376841810112D1a37bA4D1F6FE5Fd610EC,
            0xA9F23143c38FBFb2fa299b604a2402Bab1E541FC,
            0x689034d0c674685A03576E0BEb9aB601ce33Db7A
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON][0x608792Deb376CCE1c9FA4D0E6B7b44f507CfFa6A] = LenderTokens(
            0x9503482f84b07b487B6001433D2f2f685769E8B9,
            0x4880c4B5a3D83965c78FAEd3373154610B39046B,
            0xE403D4f591535c10B53fE347AbA4b55672DF350E
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON][0x585e26627c3B630B3c45b4f0E007dB5d90Fae9b2] = LenderTokens(
            0x59EBF20504d4e50eeC63E30C546349e1bb94c6a3,
            0x2c5a402aE0b9d2F587457cFC682aB20aA7db631E,
            0x70bAa14712Dd09b10330781AF50b34F0ff90e07e
        );
        lendingTokens[Chains.BASE][Lenders.AVALON][0x3B86Ad95859b6AB773f55f8d94B4b9d443EE931f] = LenderTokens(
            0x3D315dE4FDDFf5F6FF0Fd524d662d043d2f0318c,
            0x15bcB8789568d82C8A3D8Bd2Be133a5F44404c1d,
            0xa3B7f215E678f8E971d3CD3617e21d737b50eE74
        );
        lendingTokens[Chains.BASE][Lenders.AVALON][0xC26C9099BD3789107888c35bb41178079B282561] = LenderTokens(
            0xEBe7445081A9Ce942f6dcFf724355E235862A822,
            0xe11333BC86f00895D9B147113c1BB8aA2D6787ff,
            0xC242b0Ba6fB60CF7DdA34A06c5c8D5961F65aAca
        );
        lendingTokens[Chains.BASE][Lenders.AVALON][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0xb142eA19c5C6b01c71068778696d442e9Cc62c8e,
            0xcE85098c171EF00165D55cc9d27fedC011fB30D0,
            0xA10cCA1dD26A394781e22549AbB8411d7285ED2c
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AVALON][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] = LenderTokens(
            0x09586F5EEF369909F321F9A313B6D51db1946119,
            0x2B8360cfC4d18D0C614C8e3BaD1990858b9b68C0,
            0x40a13E22fb4B041e3d9e8482b343c09BAEAFEDAf
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AVALON][0xaf88d065e77c8cC2239327C5EDb3A432268e5831] = LenderTokens(
            0xb05088c49F74092A1fDa87257648f92ad0547753,
            0x15D67fA0a1e579765d0E9211313E4d0F5788256f,
            0x753Dc449BcAf4706159F8E8078A47ACc7d844D49
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AVALON][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] = LenderTokens(
            0x5D383D2A1Dc3e5E82ACb2035C10ba1bAC989fE42,
            0x703cC5Fca1c0BCb3446E20bf52Ab9C5A188c9425,
            0x2af52EF42F352f160C7042925d1Cbef4792b9fd5
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AVALON][0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] = LenderTokens(
            0xb57905AB2c72E4354acbA8A885294de277c0A7AE,
            0xa8c3064709A53F8d1C5784b060b29464028C61c4,
            0x66a81FbBFeD54d8888c44D9E0b57F9Ce28Aa7B0d
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AVALON][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] = LenderTokens(
            0xABc4B43c27b458745a802E8Fa3D00c5E96Db0BfC,
            0x9dCa1b6E1F62b324166De1c2Ae7B640fAD80a237,
            0x5CCe6387b88b4911eAe01037213D2D75624AEcD7
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AVALON][0x3647c54c4c2C65bC7a2D63c0Da2809B399DBBDC0] = LenderTokens(
            0x3e5E8569B2aa2A8Bd235104944868913B23a0D64,
            0x504ED6c8A0c5b04990dA91C0bf9d11f6Ee2e6C28,
            0x3A791E680019072Bf8A353F142De7610282e52c2
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AVALON][0xaFAfd68AFe3fe65d376eEC9Eab1802616cFacCb8] = LenderTokens(
            0x039FAd6071212aC685833F2060D29cd9F75d8ad7,
            0xF14f9F26AC113c1899d4c1eaaF67d4c04A2b5565,
            0xc887a51a9156ad3a388b8fcFeEE35aa3Ca735B97
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.AVALON][0x346c574C56e1A4aAa8dc88Cda8F7EB12b39947aB] = LenderTokens(
            0x95118fb8aeD1877DB25E5F72d319b7aE45E9D101,
            0x93c138D0295a1b1a715B2751d286732D8F2f4A92,
            0xF45080Fa91f6317b92E29efdC14dbeb4bf695D80
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.AVALON][0x2DEF195713CF4a606B49D07E520e22C17899a736] = LenderTokens(
            0x0b22C0dC82842c407Cbae963853b48De7Dc7B743,
            0x34a651Ba099127fFab65FF7E7c8e78d5e3b4C1f0,
            0xF039cf20b133eCC1FBD0A47C3F09D41f3C81FefF
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.AVALON][0x07d83526730c7438048D55A4fc0b850e2aaB6f0b] = LenderTokens(
            0x23c94De1451B0B76958C8aC6347C211E063aa8e5,
            0x2ad41c6A230b7f570829F78271BC829B4E41b2cA,
            0xB7d517481DC8569D9451a7Dbb27cF02d89c8a68d
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.AVALON][0xA9d23408b9bA935c230493c40C73824Df71A0975] = LenderTokens(
            0x367E33d5562b03ed89165f59247B9562f6168999,
            0x566F56b37959e0D1C928bf0Fe01b4Bd27F2Bbe1e,
            0x0dD7A778C6d57D102AcD9E24a55518C8012f0b29
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON][0xfF204e2681A6fA0e2C3FaDe68a1B28fb90E4Fc5F] = LenderTokens(
            0xA984b70f7B41EE736B487D5F3D9C1e1026476Ea3,
            0xc7d82b035ca1A8AEFc1c7A077AeeffBBac27e3bB,
            0xfBF7754a9E38BBbFE1cb746419f3e8f0Bf3Ba79D
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON][0xEf63d4E178b3180BeEc9B0E143e0f37F4c93f4C2] = LenderTokens(
            0xF5b689D772e4Bd839AD9247A326A21a0A74a07f0,
            0xd07A95547961c080401733139f225b694489291A,
            0x4586D19D085e498925b20105254684AcDf6f531A
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON][0x9827431e8b77E87C9894BD50B055D6BE56bE0030] = LenderTokens(
            0x8Ae2E5e6C5C7C9E88c05083a3010C8D8667c6867,
            0x52E222b0401705fd868fd95150e5cE46c27439eF,
            0x6367Bd452ecD97F509b0F351e99f384064f19cbb
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON][0xfe9f969faf8Ad72a83b761138bF25dE87eFF9DD2] = LenderTokens(
            0x47392DdBFA39dD373822bf6d3b8556407D148ae6,
            0x35d5eAD2450483C6e892Af2d7C774BdFF9c77f54,
            0xc9451447E5f95e8d77798c5967A9748dF54801A9
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON][0x07373d112EDc4570B46996Ad1187bc4ac9Fb5Ed0] = LenderTokens(
            0xCcEC084081dEacAe8eA1b539F33d17F555316990,
            0xE3fC988F3e86F47E95Cf85d86647C91BB35B4dcD,
            0xD2a8A0bE29E2D2a2c40E84cDef39E6d2a1fD2963
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON][0xf6718b2701D4a6498eF77D7c152b2137Ab28b8A3] = LenderTokens(
            0x9A6Ae5622990BA5eC1691648c3A2872469d161f9,
            0xF813C26941d7435c06c17cc044c300081168D700,
            0xD8Bc00d2548A320232801AB474414eF73C35730D
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON][0xe04d21d999FaEDf1e72AdE6629e20A11a1ed14FA] = LenderTokens(
            0xC39E757dCb2b17B79A411eA1C2810735dc9032F8,
            0x273b485837b95871d56B2dAD7884D57362Aead6b,
            0x475483D8CfeB10cE87e4Cd330FDFb347726CDAC3
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON][0xb88A54EBBdA8EdbC1c2816aCE1DC2B7C6715972d] = LenderTokens(
            0xE465c55D68EC371B79A40FbC3B62Ba78A1D3CC7F,
            0x8dB8693e8e9ba494cf16b7f381C12417b14a0A87,
            0xec5AcF563d57877B51FEf8BA2FFFADEA1B334175
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON][0xb750f79Cf4768597F4D05d8009FCc7cEe2704824] = LenderTokens(
            0xFA4BE25a704dF74064eb0bFD0E3E3e460F4d16fc,
            0x39025b6e71bd95c8a5C241C23c3665B3585996A4,
            0xB82b4e6E19Ef0C0A738B1EFf93A582fbD29Fa1C9
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON][0xf8C374CE88A3BE3d374e8888349C7768B607c755] = LenderTokens(
            0x610765EB14b1508BD1E8A987f820617a0Ab742FF,
            0x5af0F8De3Fb66430d2EeF8C23F8168D4CAa90148,
            0xa40A72be6CD2e71402882A93D0DC9f1DeF23703a
        );
        lendingTokens[Chains.SCROLL][Lenders.AVALON][0xf610A9dfB7C89644979b4A0f27063E9e7d7Cda32] = LenderTokens(
            0xa0EAf2406597A4c38139d3D31350c17896f7D959,
            0xEf6C22d039caa6bC3FD8a5C58f3d38C70D4ABE83,
            0xaf2b2993eD33BD94Cbb75C9AA6db750A0d2BA6B8
        );
        lendingTokens[Chains.SCROLL][Lenders.AVALON][0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4] = LenderTokens(
            0x4D95814493DA9e96dE31DbC6f32ad2BE92cae3cd,
            0xf2059EC09e885F717B6580F394d76DFA0441e5c5,
            0x08B0020498ec336EB005372bF369ba9CA869eB57
        );
        lendingTokens[Chains.CORN][Lenders.AVALON][0xda5dDd7270381A7C2717aD10D1c0ecB19e3CDFb2] = LenderTokens(
            0x75C2354b9076795169aab4FEf124b571214963D1,
            0xD161151e9262405c33638f31b81E1f2AcF918f31,
            0x4c9BfCAF04e8b2dcEe0BbA0FEBF37276543a4CE7
        );
        lendingTokens[Chains.CORN][Lenders.AVALON][0xDF0B24095e15044538866576754F3C964e902Ee6] = LenderTokens(
            0x7Db9a5458432e810A2787B15f712Da1eCC3afe41,
            0x052eF2323d022a2401dAEf88b68e563EfE8FE1fa,
            0xDe2FFC43eD62BA2ecdF9C56d3e94f4faf19BA5D9
        );
        lendingControllers[Chains.SONIC_MAINNET][Lenders.AVALON] = 0x974E2B16ddbF0ae6F78b4534353c2871213f2Dc9;
        lendingControllers[Chains.B2_MAINNET][Lenders.AVALON] = 0xC0843a5A8527FD7221256893D4a4305145937E8c;
        lendingControllers[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON] = 0x67197DE79B2a8Fc301bAB591C78aE5430b9704fd;
        lendingControllers[Chains.SEI_NETWORK][Lenders.AVALON] = 0xE5eB6aBbA365A49C8624532acaed54A47cc36D3C;
        lendingControllers[Chains.GOAT_NETWORK][Lenders.AVALON] = 0x4B801fb6f0830D070f40aff9ADFC8f6939Cc1F8D;
        lendingControllers[Chains.MERLIN_MAINNET][Lenders.AVALON] = 0xEA5c99A3cca5f95Ef6870A1B989755f67B6B1939;
        lendingControllers[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON] = 0x29ee512B76F58FF4d281c49c7D1B6B248c79f009;
        lendingControllers[Chains.ZETACHAIN_MAINNET][Lenders.AVALON] = 0x6935B1196426586b527c8D13Ce42ff12eEc2A5fC;
        lendingControllers[Chains.KAIA_MAINNET][Lenders.AVALON] = 0xCf1af042f2A071DF60a64ed4BdC9c7deE40780Be;
        lendingControllers[Chains.BASE][Lenders.AVALON] = 0x6374a1F384737bcCCcD8fAE13064C18F7C8392e5;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.AVALON] = 0xe1ee45DB12ac98d16F1342a03c93673d74527b55;
        lendingControllers[Chains.TAIKO_ALETHIA][Lenders.AVALON] = 0xA7f1c55530B1651665C15d8104663B3f03E3386f;
        lendingControllers[Chains.BITLAYER_MAINNET][Lenders.AVALON] = 0xEA5c99A3cca5f95Ef6870A1B989755f67B6B1939;
        lendingControllers[Chains.SCROLL][Lenders.AVALON] = 0xA90FB5234A659b7e5738775F8B48f8f833b3451C;
        lendingControllers[Chains.CORN][Lenders.AVALON] = 0xd412D77A4920317ffb3F5deBAD29B1662FBA53DF;
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AVALON_USDA][0x2840F9d9f96321435Ab0f977E7FDBf32EA8b304f] = LenderTokens(
            0x91Aee6cC85Ab68A02C288F8d8e7A4F5A704Ad746,
            0xbEC96E9263FB57Af244E8266bF954A1Cc0c89499,
            0xD6662E373c826dd99E641371B79C28C158Ed3aFE
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AVALON_USDA][0xff12470a969Dd362EB6595FFB44C82c959Fe9ACc] = LenderTokens(
            0x9d703fe0324fE009B55e8837F88B4BC131ef77Ad,
            0x9B3633199cd79b9723fEC0211A1441f6dc83B05f,
            0x4f90BcED506A38E037E4161867D0156aE845A0b0
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AVALON_USDA][0x29219dd400f2Bf60E5a23d13Be72B486D4038894] = LenderTokens(
            0x8EF62553117F7b613101d5f729c7718F4b8936eb,
            0xBA6d7Cfd50891C797eAA636C45d5f4Dad7a0664e,
            0x241680050Bf8B3169c76078449A7441C7E304B6c
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.AVALON_USDA][0x6aB5d5E96aC59f66baB57450275cc16961219796] = LenderTokens(
            0x9586f42695B7cd2c451d6d361E9C08D04395bb07,
            0x591e6e66958a254E2C0133598bB9Cb2aB5255C95,
            0x4312Af8A2f3A8313DeD042dE942E3ebBd4F0F6Ec
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.AVALON_USDA][0xff12470a969Dd362EB6595FFB44C82c959Fe9ACc] = LenderTokens(
            0xf501e9153e4A14E2EB314c6383027179c9516Db1,
            0xBB94CC4C4b96A60f3D2E508591F6cf8535422f83,
            0x73135CF7b7f9Eb6a5F3951150533B36aF00e6B93
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.AVALON_USDA][0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1] = LenderTokens(
            0x80d515B3c537896A8e2f5800bc9E55Ff8cc4A377,
            0x7869e9e1600Bd7f14C32d920573906A6DAaF625C,
            0xa101a1014E84c2778E96c7fE877CD44f7d657867
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.AVALON_USDA][0xB75D0B03c06A926e488e2659DF1A861F860bD3d1] = LenderTokens(
            0x6Be8b7c145041B02E0859233c62A1E69f4eFF821,
            0xe8c660ec6213b82546B1b73235699fd1b7C34917,
            0x586449A809F3BC4739909d25cA67371157091F28
        );
        lendingTokens[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON_USDA][0xA00744882684C3e4747faEFD68D283eA44099D03] = LenderTokens(
            0xE96f26Ec61A17Dda747b0f28c409173b353545E7,
            0x3e9CDd0aDC08E2DCe7EAaD4f43cD73b5E9b9b729,
            0xC90eFf0980FaCD84e97eec83B3779D7C1732808c
        );
        lendingTokens[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON_USDA][0x2d9526e2cABD30c6E8f89ea60D230503C59C6603] = LenderTokens(
            0x02c4Fdd91e45088183b4D2A161CAf2aAc301F3d6,
            0x5f5DA68dee05C8F507Ec12eaf51D3f2e19282af9,
            0xF351b7A6B34F6E4D571aA709Ddd5BCaBaBEf28B7
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON_USDA][0x585e26627c3B630B3c45b4f0E007dB5d90Fae9b2] = LenderTokens(
            0x786f2243352C95a9Ec86D800092cf0D3463a89C8,
            0xaDf40A99d7652895FE745d4B1552550863a5181c,
            0xeF495C30C4C1bdBc07255da7b4DE3600847DD873
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON_USDA][0xdC3Cf1961B08da169b078F7DF6F26676Bf6a4FF6] = LenderTokens(
            0xBc0AABeF3148C25288c73F0D2d5E1c231e6E8BA1,
            0x86d6F9097B80D320700292000c9874F0c5F97950,
            0x833B18d395881cD623D7181122010a6011c87C17
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON_USDA][0x5C13E303a62Fc5DEdf5B52D66873f2E59fEdADC2] = LenderTokens(
            0x7B19A6b38Dc8d40a3c22A7A8BcC229b1D55E3dbE,
            0xB06492e2DE0f835af7eD1c1511D7CD810f813E49,
            0x5a09359Ad3A75C3aAa8917ff389E7085cD0DAC70
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON_USDA][0x608792Deb376CCE1c9FA4D0E6B7b44f507CfFa6A] = LenderTokens(
            0x6a04C4528ee1eA1f2bBd3eA73843f0A8b38979A0,
            0x01BE555A133988549F89Be1A719983ceb09278a3,
            0x0C4919CE3A6C49B583203B702769e5A7Ae9D87Ee
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.AVALON_USDA][0x5d5c8Aec46661f029A5136a4411C73647a5714a7] = LenderTokens(
            0x9586f42695B7cd2c451d6d361E9C08D04395bb07,
            0x591e6e66958a254E2C0133598bB9Cb2aB5255C95,
            0x4312Af8A2f3A8313DeD042dE942E3ebBd4F0F6Ec
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.AVALON_USDA][0xff12470a969Dd362EB6595FFB44C82c959Fe9ACc] = LenderTokens(
            0xf501e9153e4A14E2EB314c6383027179c9516Db1,
            0xBB94CC4C4b96A60f3D2E508591F6cf8535422f83,
            0x73135CF7b7f9Eb6a5F3951150533B36aF00e6B93
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.AVALON_USDA][0x2DEF195713CF4a606B49D07E520e22C17899a736] = LenderTokens(
            0x80d515B3c537896A8e2f5800bc9E55Ff8cc4A377,
            0x7869e9e1600Bd7f14C32d920573906A6DAaF625C,
            0xa101a1014E84c2778E96c7fE877CD44f7d657867
        );
        lendingTokens[Chains.TAIKO_ALETHIA][Lenders.AVALON_USDA][0x07d83526730c7438048D55A4fc0b850e2aaB6f0b] = LenderTokens(
            0x6Be8b7c145041B02E0859233c62A1E69f4eFF821,
            0xe8c660ec6213b82546B1b73235699fd1b7C34917,
            0x586449A809F3BC4739909d25cA67371157091F28
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON_USDA][0xE8cfc9F5C3Ad6EeeceD88534aA641355451DB326] = LenderTokens(
            0xAe407D0dCc0006194A4Fa2F16375f0250d8cB71A,
            0x7231F628c7539E156d8b61edC167Bae012642142,
            0xCE41cF8989e446D9c95C438D989DD36Ff6735B7B
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON_USDA][0x91BD7F5E328AEcd1024E4118ADE0Ccb786f55DB1] = LenderTokens(
            0xB081f19737831c9d3c0dE2004e7E4Fb1b52D10Fb,
            0xA145Ca16cA92A64946320972eAa4047c1f718f78,
            0xA390Ce82D76F3249F11Ed154af43f34C31eF4De2
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON_USDA][0xfe9f969faf8Ad72a83b761138bF25dE87eFF9DD2] = LenderTokens(
            0x156C9b35F4B9F01b22d2Fa845A1a9E327F14e8FA,
            0x9Fe0cD07f3d3140848a1183b820a1f5961458a33,
            0x62A32941b25A9A757240C1449F3634112Dca7F4B
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON_USDA][0x9827431e8b77E87C9894BD50B055D6BE56bE0030] = LenderTokens(
            0xA2b1db2342C6243CB27d8c61bB64921f54195C82,
            0x829A11ea619527Fd26eaD1e797d31036e719033C,
            0xbbe5113d1860AD35214b04890EcF75E96325f7f7
        );
        lendingTokens[Chains.CORN][Lenders.AVALON_USDA][0x2840F9d9f96321435Ab0f977E7FDBf32EA8b304f] = LenderTokens(
            0x6D6a39fC102A970DB5D746A2075a9e949ce3BacB,
            0x881E7c8C4B1E6322b9999f604EcB89087eE58A64,
            0x534c84DA649b23e93f50b51a951E6Dc7f85B64E9
        );
        lendingTokens[Chains.CORN][Lenders.AVALON_USDA][0xff12470a969Dd362EB6595FFB44C82c959Fe9ACc] = LenderTokens(
            0x6d5eD8185986bACAc3e01963d7D546Da3A2d9E59,
            0xf49E64c72421cf712AFc982DB2329f9EfaADB818,
            0x946F32144085972fDc1275B049BAe8eA33B760CF
        );
        lendingTokens[Chains.CORN][Lenders.AVALON_USDA][0xDF0B24095e15044538866576754F3C964e902Ee6] = LenderTokens(
            0x8F4118c4a978c7a2434F5Fd79ac5DC1215C11f56,
            0xF93F89bfFDf9B65a382A75fD88d943c3EBC2BE29,
            0x2c1e453Db68D1eD76A66EbF3C8b69C5dc171b7A1
        );
        lendingControllers[Chains.SONIC_MAINNET][Lenders.AVALON_USDA] = 0xD33Ee43551167cdd15Ef9CF87ceecC0fF69Cc922;
        lendingControllers[Chains.SEI_NETWORK][Lenders.AVALON_USDA] = 0xC1bFbF4E0AdCA79790bfa0A557E4080F05e2B438;
        lendingControllers[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON_USDA] = 0xaB82814E4c5bC2Ede88DB334276dFe01a4BcCFd0;
        lendingControllers[Chains.KAIA_MAINNET][Lenders.AVALON_USDA] = 0x65bB26fa8D2774313202029619767A3727C98B1b;
        lendingControllers[Chains.TAIKO_ALETHIA][Lenders.AVALON_USDA] = 0xC1bFbF4E0AdCA79790bfa0A557E4080F05e2B438;
        lendingControllers[Chains.BITLAYER_MAINNET][Lenders.AVALON_USDA] = 0xA51d264A033cD0D3205CD4C6D51310dA841D15DE;
        lendingControllers[Chains.CORN][Lenders.AVALON_USDA] = 0xf659a3fa012f5847067239a6009309323011815d;
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON_SKAIA][0x19Aac5f612f524B754CA7e7c41cbFa2E981A4432] = LenderTokens(
            0xe0Ca3726CC7aFFe829d836377E85aB897E232c80,
            0xd9239bC54D3cC9c4cc1C199579f57BB0f7325Ab1,
            0x3A282091Dd8875ac957C41fDd4be162B01f26205
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.AVALON_SKAIA][0x42952B873ed6f7f0A7E4992E2a9818E3A9001995] = LenderTokens(
            0x99a7b7112e489902A130d0C5b6C43293828A0C30,
            0x68B5602b86239a7d6d00CBf1651502137bF5a70d,
            0xf68aD4b0ADb3fe1d1806B8587E046b97Ea376434
        );
        lendingControllers[Chains.KAIA_MAINNET][Lenders.AVALON_SKAIA] = 0x4659F938458afB37F3340270FC9CdFe665809c1b;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_USDX][0x7788A3538C5fc7F9c7C8A74EAC4c898fC8d87d92] =
            LenderTokens(
                0xa3E657d8e18748B570d0A0Dd8Fe5904756c1C8a7,
                0xc24B34A2241b7e1A009A0af672374108C3158825,
                0x540addFd7883667D2229B593478fCe28C6DFa01F
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_USDX][0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef] =
            LenderTokens(
                0xaa84aF1d9D52fcaeb2f1bea08446a40EE6965639,
                0xE2017C935B0859029EcFd858d4f67505dB8ADa84,
                0xB933669990c2c9189687307a9953BBAcf5781871
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_USDX][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(
                0x6aD8d45Cd6830a5F72e71793F0F8925d4fb8042F,
                0x5f1bbB29224a51B5e1f296087484EDF501D3DEEB,
                0x19Dc7fE9e9a353Bf2777eDF1ad6960f4f8280734
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_USDX][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(
                0xD4c3C2FE42E9868CEa6c7c85107E4cdb9e37D0Eb,
                0x42Ec32B6275F044a2F81b10D4cd029B83dADD0b9,
                0x3740412B9d9A8D1128BF5B241ab9D16A9167aAAB
            );
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_USDX] = 0x77fF9B0cdbb6039b9D42d92d7289110E6CCD3890;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_XAUM][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(
                0x9a02588DDff4d079cC5BEB1b864B12410049288a,
                0x02edfFA0298313763803089e92e491C915E0e7dD,
                0xb765168E68936Ce1C6dD03a56f0D4d70B833A5bC
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_XAUM][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(
                0x0b37eE41a3b80431A444d7F3d9F0edE9023BE000,
                0xCb4d00EaaF3562469a397994897e7384A124395a,
                0xd7470Feb942dAA7BaEE8b1Ea807db7abE5d04447
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_XAUM][0x23AE4fd8E7844cdBc97775496eBd0E8248656028] =
            LenderTokens(
                0x0ba2D99059e43f0437E28F9C5B5dE1a736643AD0,
                0x812b06C9D2985eDa494a1C8BBA1F25A369F84848,
                0x55ce81413Fa3df21A42ce54dd94762dE58c3A664
            );
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_XAUM] = 0x4B801fb6f0830D070f40aff9ADFC8f6939Cc1F8D;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LBTC][0xecAc9C5F704e954931349Da37F60E39f515c11c1] =
            LenderTokens(
                0x18B424B44134ae47A7F68f59a854568789E8132B,
                0xa963e7E0870fD4869a1518EB40128F56f7aDb934,
                0x5D149A1fDcbce0cB5DCe6044Fe9953c425C28Fd2
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LBTC][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(
                0x0CA8f4C7a8820Aa3e1678DdE67816bb27582fB67,
                0xa8055D0a95EFc2A0F1b5b1F17345203B11183F4E,
                0x4FF96c3631C4379E8e38f46EEb0120d1bCA22B70
            );
        lendingTokens[Chains.CORN][Lenders.AVALON_LBTC][0xecAc9C5F704e954931349Da37F60E39f515c11c1] = LenderTokens(
            0x9586f42695B7cd2c451d6d361E9C08D04395bb07,
            0x591e6e66958a254E2C0133598bB9Cb2aB5255C95,
            0x4312Af8A2f3A8313DeD042dE942E3ebBd4F0F6Ec
        );
        lendingTokens[Chains.CORN][Lenders.AVALON_LBTC][0xda5dDd7270381A7C2717aD10D1c0ecB19e3CDFb2] = LenderTokens(
            0xf501e9153e4A14E2EB314c6383027179c9516Db1,
            0xBB94CC4C4b96A60f3D2E508591F6cf8535422f83,
            0x73135CF7b7f9Eb6a5F3951150533B36aF00e6B93
        );
        lendingTokens[Chains.CORN][Lenders.AVALON_LBTC][0xDF0B24095e15044538866576754F3C964e902Ee6] = LenderTokens(
            0x80d515B3c537896A8e2f5800bc9E55Ff8cc4A377,
            0x7869e9e1600Bd7f14C32d920573906A6DAaF625C,
            0xa101a1014E84c2778E96c7fE877CD44f7d657867
        );
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LBTC] = 0x390166389f5D30281B9bDE086805eb3c9A10F46F;
        lendingControllers[Chains.CORN][Lenders.AVALON_LBTC] = 0xC1bFbF4E0AdCA79790bfa0A557E4080F05e2B438;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_WBTC][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] =
            LenderTokens(
                0xd381eaAcBd0fBd3f06d9f8A668A8f3CAE6a027F4,
                0xa6308152eC0CB8D7158Fa98D7f3644CdF5D462ef,
                0x0738c89C28B149B06A1cC0595e1677288DC170B2
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_WBTC][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(
                0xB5De799e18D291B4e9aD145Ea7c10C74D4063F19,
                0xA009058792c6Ad29130bC4106c977428c5EbAF1D,
                0xC306824985618fd945B5C24db420320E67396D14
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_WBTC][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(
                0xf01b9fB0199276790a3D7CEF93c0683A9Dd97744,
                0xafAB2b9b98014F5707f63432770854178F2d2311,
                0x6C093f61D05dB65614D0b5504025d77868ad914f
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_WBTC][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(
                0x038754f29f84b0bD891877D08B4B0481fC123F63,
                0xddA33dB9464EBD6516274c808C13b37A5e645117,
                0x7F9c2243dAB239Ab1E07560998E8bbbdeeC9858d
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_WBTC][0x0555E30da8f98308EdB960aa94C0Db47230d2B9c] =
            LenderTokens(
                0x31964267Dca022b4a6496C404679c8Ca3d6E6B99,
                0xC14BAE99f67e876c076Bc566DBe4bcb633d005EB,
                0x7854FB71189294c7774652495f16eb8BA6a99Bf9
            );
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_WBTC] = 0xF8718Fc27eF04633B7EB372F778348dE02642207;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LISTA][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] =
            LenderTokens(
                0xCdE1B8bc80f971F1f09842b1Ad824C48111B95dD,
                0x3B4B6C1757779ba05Ef5946F5B9916a2678Da2EE,
                0xcdE62Fe4F736Baa4e15f90cC7C97cD7B9B06A424
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LISTA][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(
                0x5657E23F2802cFb7193F9dd49Bc9c4a1bCeCaD2d,
                0x289a36392B0cc0717199748f6D881A005093e928,
                0x349d0D38495a0Fe057cAF92a572727F6E848329C
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LISTA][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(
                0xE28339350C884a77f9194b58c149265E1c175f85,
                0x06C753347ed228773918400518d16597E9c488c4,
                0xd4F31e1EDb4D753FA56A5842eDF30219c8f6f975
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LISTA][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(
                0x5525016cC03E336cf7dd46c193c90e5a3A80CcE0,
                0x81C7dd6531173044B015eC296B4579312190961f,
                0xAe80eb30A1ae25Bf459CdE7e1fc6e0FD7b4E75Bd
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LISTA][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(
                0xBc60701885A1393c26308A9Ab12877B9F27dE480,
                0x27114d631860A0DF1AC2848c9E9218c0252fa04B,
                0x2029A8686fE24617a88479fEb8aC7e7333FC7450
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LISTA][0xFceB31A79F71AC9CBDCF853519c1b12D379EdC46] =
            LenderTokens(
                0xB371BCA4217735c5dF6D07A2101Ab3942142265a,
                0xB72d4e761e0aFa19C1B4819312E2684C81eEB496,
                0x6b4d92a2A2B76eaE607899Bc0608F122d7A13Edf
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LISTA][0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409] =
            LenderTokens(
                0x6A9e4C20a9850308263b7d529F102A163958E9c5,
                0x3e41342D217183A673955B5766be573Ad22960b0,
                0x65A55d9724Ac52eDB613864F60D9a6B7abb4BAB5
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LISTA][0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B] =
            LenderTokens(
                0x892C4250Ce1c2f1Ba41C6cab81f636fd8eE6fd88,
                0x665EEeB7fb2f63a772A91b1B6E1EB24F4Df9d4B2,
                0xBc6F78f15163ccdC26dC5AE33e8A9f06eCe35314
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LISTA][0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5] =
            LenderTokens(
                0x90e69ca775bC254Fdb0D2B20749D980A903349a8,
                0xadA976F1664228029674091bFc9A1Dc206387A14,
                0x6E04462730fd51BA0f806Ed3A53f3674274846ce
            );
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_LISTA] = 0x54925C6dDeB73A962B3C3A21B10732eD5548e43a;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_STBTC][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(
                0x4bCc83780cFda6ad663F4639c8430bb088Cd74Fe,
                0xE479EF0E4CE928ED49877714Ed97c12bC0A4a764,
                0xa0169B051681bC0174EB8942746736bE840D9afB
            );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_STBTC][0xf6718b2701D4a6498eF77D7c152b2137Ab28b8A3] =
            LenderTokens(
                0x52c6BB4Fc974CF73c37A169f5D0Dc88a76F52F5D,
                0xfd9D9C357443267C2ef210A12CD44c3F2C588a84,
                0x4AE77Ff56d07Fba1ff0ACdD46065993221Edb3A1
            );
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.AVALON_STBTC] = 0x05C194eE95370ED803B1526f26EFd98C79078ab5;
        lendingTokens[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON_UNIIOTX][0xA00744882684C3e4747faEFD68D283eA44099D03] =
            LenderTokens(
                0x9a02588DDff4d079cC5BEB1b864B12410049288a,
                0x02edfFA0298313763803089e92e491C915E0e7dD,
                0xb765168E68936Ce1C6dD03a56f0D4d70B833A5bC
            );
        lendingTokens[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON_UNIIOTX][0x236f8c0a61dA474dB21B693fB2ea7AAB0c803894] =
            LenderTokens(
                0x0b37eE41a3b80431A444d7F3d9F0edE9023BE000,
                0xCb4d00EaaF3562469a397994897e7384A124395a,
                0xd7470Feb942dAA7BaEE8b1Ea807db7abE5d04447
            );
        lendingControllers[Chains.IOTEX_NETWORK_MAINNET][Lenders.AVALON_UNIIOTX] = 0x4B801fb6f0830D070f40aff9ADFC8f6939Cc1F8D;
        lendingTokens[Chains.BOB][Lenders.AVALON_BOB][0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3] = LenderTokens(
            0xd6890176e8d912142AC489e8B5D8D93F8dE74D60,
            0xc319b085c78b55683BbDbE717a3aeb6858D5BAc3,
            0xB05b8D868153d656EB40444b0333Fb0DaD464Fb8
        );
        lendingTokens[Chains.BOB][Lenders.AVALON_BOB][0xBBa2eF945D523C4e2608C9E1214C2Cc64D4fc2e2] = LenderTokens(
            0x5E007Ed35c7d89f5889eb6FD0cdCAa38059560ef,
            0xf7d1F417712205D51350aE9585E0A277695D9dee,
            0xaf84eb227e51Dbbb5560f7Cf507e3101ef98147b
        );
        lendingTokens[Chains.BOB][Lenders.AVALON_BOB][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] = LenderTokens(
            0x81392304A5bE58e1eb72053A47798b9285Eb948E,
            0x33D54cdD544bFDB408dabD916Af6736Ea5be867D,
            0xd684C4B6abeeaa5cA79F30D346719c727D2072D3
        );
        lendingTokens[Chains.BOB][Lenders.AVALON_BOB][0xCC0966D8418d412c599A6421b760a847eB169A8c] = LenderTokens(
            0x2E6500A7Add9a788753a897e4e3477f651c612eb,
            0x5ee930400cc7675B301d57E38AE627822CafDF68,
            0xe8fD5c5f889cd7fb67Ea2b58E9246131Fb2aBb6A
        );
        lendingTokens[Chains.BOB][Lenders.AVALON_BOB][0x0555E30da8f98308EdB960aa94C0Db47230d2B9c] = LenderTokens(
            0xc6AB82fc782E29B385E775Aa0D12C3278358c9e2,
            0x6effd87a9fB070eeCBcEbdC68AeF055cAeD6EFf5,
            0x539DB87e80c706fA3789Cf55d743b5FDf61aCE49
        );
        lendingControllers[Chains.BOB][Lenders.AVALON_BOB] = 0x35B3F1BFe7cbE1e95A3DC2Ad054eB6f0D4c879b6;
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON_OBTC][0x5832f53d147b3d6Cd4578B9CBD62425C7ea9d0Bd] =
            LenderTokens(
                0x4d6FAAd7630E1b5e35dE0d6C1e43834aa2B4bE80,
                0x0E3B48CcdA6E547Ce6411B22fB4909C379fB6ea3,
                0x1C7E501b5d1273328847fC54fA33938Cd2F6De84
            );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON_OBTC][0x000734cF9E469BAd78c8EC1b0dEeD83D0A03C1F8] =
            LenderTokens(
                0x87Fd795665b5FFbb3D547BB51734C025d0fbd1FF,
                0xBB665C4582eeEdf8e50f55FB1139E49c83Ae93d6,
                0x91fB4E6265414d19cA35461A28398FC16089Ee13
            );
        lendingControllers[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON_OBTC] = 0x2f3552CE2F071B642Deeae5c84eD2EEe3Ed08D43;
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON_UBTC][0x5832f53d147b3d6Cd4578B9CBD62425C7ea9d0Bd] =
            LenderTokens(
                0x0B7D80cc8ddA70d2B1c4aA9935bC4625444de87d,
                0xe95aD7EB372c3E267162500B2D0DBB5aA5cD89D0,
                0x11e7f21CB553A119047FEEc781ce1f699BbC6387
            );
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON_UBTC][0xbB4A26A053B217bb28766a4eD4b062c3B4De58ce] =
            LenderTokens(
                0x24A30623c0F281a3f609b1301E571da9a2775bC7,
                0x2038C26E95060969547d4Cec4A949EDDB82f3f0c,
                0x3445c170d07c1416F5aF59b42D0a092Bf62866b6
            );
        lendingControllers[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.AVALON_UBTC] = 0x7f6f0e50dB09C49027314103aa5a8F6Db862dBd0;
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON_LORENZO][0xfF204e2681A6fA0e2C3FaDe68a1B28fb90E4Fc5F] = LenderTokens(
            0x70c65E0F9618604A8BD9047a32dF2444e80669b9,
            0xa39F81095dF0531E34D251056fABc901d04F66B2,
            0xc5d85103a76931424eC254E0814DF911a2792274
        );
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.AVALON_LORENZO][0xf6718b2701D4a6498eF77D7c152b2137Ab28b8A3] = LenderTokens(
            0xea5Ce3b4a20C27436d9866620dF331Aa7fBce88A,
            0x27A8f1E66fe35191443A6A9C9Eb937236C83E588,
            0xDff1a8DFf6fA073Bb3e9C893260BeF5F03c681AA
        );
        lendingControllers[Chains.BITLAYER_MAINNET][Lenders.AVALON_LORENZO] = 0xeD6d6d18F20f8b419B5442C43D3e48EE568dEc14;
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AVALON_BEETS][0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38] = LenderTokens(
            0xeF360eA0d9f9c354ce5Df48cdCfE2337c491aFc9,
            0x6b900eAd4aDDb843a57c50C77E0Cce7EFC648da5,
            0x818D4e6575D686b096d4Ece2f572CE7a1e8cc893
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.AVALON_BEETS][0xE5DA20F15420aD15DE0fa650600aFc998bbE3955] = LenderTokens(
            0x718aA85242149102262ef492BBdD1FA66e2b1Aab,
            0xB4D5814efcb4Bb65cFEb6AC93976c9E08B8298C5,
            0x048327822DD0499b77B124153D01d7723a47a1ff
        );
        lendingControllers[Chains.SONIC_MAINNET][Lenders.AVALON_BEETS] = 0x6CCE1BC3fe54C9B1915e5f01ee076E4c4C3Cdd19;
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0xB880fd278198bd590252621d4CD071b1842E9Bcd] = LenderTokens(
            0xaeB2B74c730fA1b1D677cA845E5E5c23bE2d1E82,
            0x0dE878F7d7d72A82cA17cca430ECadE6f189834b,
            0xE987bCb0B79A12545af247153143eA60acB72754
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x480E158395cC5b41e5584347c495584cA2cAf78d] = LenderTokens(
            0xFde83259C37d5Ef194d26CA578a9F63a96A068a6,
            0x45D5406Ae6668335851781c292fD233542eC2f8b,
            0x027a444d2afD8d95F4fCa593d6d02a6C307b6025
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x7a677e59dC2C8a42d6aF3a62748c5595034A008b] = LenderTokens(
            0xf99De300aA64Faf4987FDAC6268e092BA17E2527,
            0x22868BFb68A901a4AeAF6a7bF9ca9b010C31e4cF,
            0x3f5B70F2A2A9fC560F71DdD169d890DC9950ecda
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x4DCb91Cc19AaDFE5a6672781EB09abAd00C19E4c] = LenderTokens(
            0x7b64c30C517b5A1cBd907611985A5FF5cA01f9B0,
            0x76AF72d3e4Ff21B3aADFd9B88EE949Fe222F35D4,
            0x5F06B0Cf96e846a9FF1171A98454eeabad003D05
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x69181A1f082ea83A152621e4FA527C936abFa501] = LenderTokens(
            0xc5fDF4d0Bed781508675fA921BAEE71b23c875Ab,
            0xfd7a79c0F3c797539f9DBf8d42aF67eeC9cDf2C1,
            0x2d564157c416fB6979699dBC114198314067F3b8
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0xbd40c74cb5cf9f9252B3298230Cb916d80430bBa] = LenderTokens(
            0x9E918DfB9b0e756395e2e8E86e892364c1D804dB,
            0xaC25FB3C99D1Cb64d987fafFCBa9ffEb64fDe36a,
            0x0F53a51d5548D8d327a302A5615560cA71055a28
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x7126bd63713A7212792B08FA2c39d39190A4cF5b] = LenderTokens(
            0x203307e615d7Eb459EeED83B5a900dC853f7e57d,
            0x91c8159129E049D43140b53509e09BddbC19c3A9,
            0xce059Fa3a0f0112054D4A77c4CE7482E16529Fb6
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x27622B326Ff3ffa7dc10AE291800c3073b55AA39] = LenderTokens(
            0xa1E50D0303ce3e0f6114d3c6D610e7E0bFc6F92A,
            0x1835343135602298AA798a87fDadcAaAC5BB2437,
            0x912f362B293629d587635aB04D3bfEfA4Ec148E1
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x33c70a08D0D427eE916576a7594b50d7F8f3FbE1] = LenderTokens(
            0x44D637a62ee64AF6Cc87A6fc8D877110C5738087,
            0x00d67A35707f6e2Eb2efd006CfEA41a7cE9923b1,
            0x2EE3cfA015BbdB348C58dA136ACF88162E6f9aCe
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x09401c470a76Ec07512EEDDEF5477BE74bac2338] = LenderTokens(
            0x7CA6A097A5FA5c3c90BE425e404247c5fb1c20ef,
            0x946d8d84DC4D602b306Db6eC16FDc88Fd0AA58B9,
            0xf3166638786E9b2D601231d23C49a236C130Dc5a
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x4920FB03F3Ea1C189dd216751f8d073dd680A136] = LenderTokens(
            0x28d05426331532D9a6e6c719f58bA022Ea0c2E40,
            0x5E0B994A8B412B27941D0711C8dA2AF0eac0A8F6,
            0x2D406426225bd2538b2eE612b4255F5c9ce4Be58
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0xb00db5fAAe7682d80cA3CE5019E710ca08Bfbd66] = LenderTokens(
            0x524cA87AA172286F72D7C75B4f19164c73e011F7,
            0xB8437b673bA5Fb9E06ef3396D88134ef2f685E68,
            0x9Ef4ec76492DA47EEC7148D379f875d189f41d5d
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0xa41a8C64a324cD00CB70C2448697E248EA0b1ff2] = LenderTokens(
            0x729cC15FdB243A51B643a4B0F2a97b4763EB664A,
            0x29da8d6B7cEc3312e1b05652476938711A09a578,
            0x05C89E5F2B6b4c539B8bD165b544DE9F90109a29
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x32A4b8b10222F85301874837F27F4c416117B811] = LenderTokens(
            0xF6171ccbB2FA1Bd9f08cD4Ddf012696FCdec1BD9,
            0xE8cdffEa60e01adeb44c7521E27A455Da4cea349,
            0x6f257c732F836C0F64F95ff6Dc1e5dBb116E9900
        );
        lendingTokens[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION][0x5c46bFF4B38dc1EAE09C5BAc65872a1D8bc87378] = LenderTokens(
            0xb9DEA832b5b734932F8bfBA2D8d9fE2Fc7F58430,
            0x3D3C17134a0F4d7b529fb5c05002f949313806AF,
            0x31E438d7449995162142D5D95C59e724eBF5A7Bf
        );
        lendingControllers[Chains.MERLIN_MAINNET][Lenders.AVALON_INNOVATION] = 0xdCB0FAA822B99B87E630BF47399C5a0bF3C642cf;
        lendingTokens[Chains.BASE][Lenders.MOONCAKE][0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA] = LenderTokens(
            0xfb5cDCa3d8dbF44d7EB6D6e2eA41a1dA8B838EEc,
            0x48D6F2D147eB6E304dFFD513CA0800a799148930,
            0x1a18D6F0BdF9FA8942DEfa8a07D406Dc1A0E1fdD
        );
        lendingTokens[Chains.BASE][Lenders.MOONCAKE][0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb] = LenderTokens(
            0xE8D0DEEC9d28a5E60B8333F42364974877DD7f8F,
            0x12764Cb05537176FB995387bcAeDE3A7c67a8984,
            0x4F36485B14E3dFE56CF6697A3145780a1AE60d2B
        );
        lendingTokens[Chains.BASE][Lenders.MOONCAKE][0x4200000000000000000000000000000000000006] = LenderTokens(
            0xb0f711e269D52535A64E2306C5ACbDB3DB042703,
            0xDbb73714A37a3220C6d02D36F0CBE26677a6039F,
            0x648EC781244A019201CF2cb3b05D7Dc91B1df398
        );
        lendingTokens[Chains.LINEA][Lenders.MOONCAKE][0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f] = LenderTokens(
            0x7D5cDa275D2311F218bd8833e64A87a0767B5b11,
            0x70ee7b4B40aDC4190Fd9D47d03b4C5e50e7115F4,
            0xb0E2F0e5EAa62c1fd5D172E80c0F9E32a8858c96
        );
        lendingTokens[Chains.LINEA][Lenders.MOONCAKE][0x176211869cA2b568f2A7D4EE941E073a821EE1ff] = LenderTokens(
            0xB06050FBd23dF8490C830D19d2f478fa2D0cbFa8,
            0x80F8BBd798883c6FA03B85be724b5A7a7cBc2187,
            0x43451178fa9Da4c2E12ce1736a062e2428517A93
        );
        lendingTokens[Chains.LINEA][Lenders.MOONCAKE][0x7d43AABC515C356145049227CeE54B608342c0ad] = LenderTokens(
            0x2194783551b15A6011f52AFb2521b35219820127,
            0x604Bf12Bc27a44708507Bc1D352c2f3644532b0e,
            0x999554ed926E150B05A123A749c4cb549AF5BCB2
        );
        lendingTokens[Chains.LINEA][Lenders.MOONCAKE][0xA219439258ca9da29E9Cc4cE5596924745e12B93] = LenderTokens(
            0xeb8A8dfeAC40BB6f02EE06bcF05A3CbBF5B57964,
            0x3773e3773EDccF69CEe9F00d0d7ca88693A12c14,
            0xF55ca1F247a6190B9138F7b845aE6794750DDd8C
        );
        lendingControllers[Chains.BASE][Lenders.MOONCAKE] = 0x6aBEa1a2B47f09C779Cb3D52B85097cB2BFaBcb0;
        lendingControllers[Chains.LINEA][Lenders.MOONCAKE] = 0x5DB340cEfE09a9fFD1883f572C09917De5bcA230;
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB] = LenderTokens(
            0x92F79834fC52f0Aa328f991C91185e081ea4f957,
            0x21cBa92ce2cff49c3557FC97854bdC4f33D91690,
            0x38e5b3BA108D7cc204db1873965c5442D6525c42
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0xd586E7F844cEa2F87f50152665BCbc2C279D8d70] = LenderTokens(
            0x6Ce0e6e81Dc7A5D997E6169cD5f8C982DA83e49e,
            0x12a2a382f84e21Fca9A25CaF2BB74eF453b5079e,
            0xd7215143d2e083464c2c2Faa7958A2e7e7571666
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0xc7198437980c041c805A1EDcbA50c1Ce5db95118] = LenderTokens(
            0x29F511e6f62118b27D9B47d1AcD6fDd5cD0B4C64,
            0x61824D93f80bcAEb1ef4FAF076b9e12Ec49f5D1b,
            0x8D8ebD44bebf42EaC0eEC7252c129de73a5d79a3
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664] = LenderTokens(
            0x723191E7F8D87eC22E682c13Df504E5E3432e53E,
            0x385b7BA56A779C4F84E80506687ADd054d0be0e8,
            0x3b25ad77A16Da4905513b2639d9857D129dc7521
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0x50b7545627a5162F82A992c33b87aDc75187B218] = LenderTokens(
            0x3D8231cE419886a5D400dD5a168C8917aEeAB25C,
            0x62aa44df460C048B06aC50DaE4C7aa56eBefA141,
            0x8ED258D46D24272E5Aa206Eb46f05A96BB720A82
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7] = LenderTokens(
            0x6d9336ce867606Dcb1aeC02C8Ef0EDF0FF22d247,
            0x1Eff4e26F7a7Bb4FEfa93f678dE98971f6A75723,
            0x598B152Acce4f811f8378B4d63f8b5933A96Ba78
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0x249848BeCA43aC405b8102Ec90Dd5F22CA513c06] = LenderTokens(
            0x073ac157eE4bA69f47e0cA8b99EBAB0365ef23de,
            0xBdFC5AA69f781C56E592B4D7C7C5cbeE8a20a771,
            0xEE0B9648626978cD1d2AcD6E6C5B839C7a74cE2B
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd] = LenderTokens(
            0xFaf3D4A4988C9a9209b1160A741907E1D552082B,
            0xF5D0E380f694056293ceCcE7235df5D1b7381ec9,
            0xD941c501d2ef885Ce970Fe6Ca8b4C19Ecf66fee8
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0xb599c3590F42f8F995ECfa0f85D2980B76862fc1] = LenderTokens(
            0xFDe88D24253474e02A32729159F4D6C14cfFAbb8,
            0x74048560b06CA507f3804509EC9f5513211D390E,
            0x05fd5435D0307B5eAe64Ba311804105a92DCdfcB
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0x47536F17F4fF30e64A96a7555826b8f9e66ec468] = LenderTokens(
            0xb8F2cd4e08Ec2F192cFB916B8C9a4308baaf3C90,
            0x771e2e1D0bFD4615Cfa011F86f9EE30bB5453495,
            0xf19655fA22Bd8EfD04A88Ef0bC825263361a361f
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS][0xfcDe4A87b8b6FA58326BB462882f1778158B02F1] = LenderTokens(
            0xaB95ae6510c7415b7Af4aE04674b408708C5bC72,
            0xC46739C2D5854d6b40ca8F81233255a412A6216b,
            0x821E1c1D9E2A87Ec014991CE581cC50069EA5613
        );
        lendingControllers[Chains.AVALANCHE_C_CHAIN][Lenders.NEREUS] = 0xB9257597EDdfA0eCaff04FF216939FBc31AAC026;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] = LenderTokens(
            0x6BdCBeF41Ca2ABE587cE7CcC895320e0061EdbA4,
            0xCD74352A42940cDf07Bf494BabF2B289696F7A0c,
            0xB40ae838b300f0d260Ac2e915e339bbb616E28FB
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0] = LenderTokens(
            0xf818fbB391f0E84b620D48d8C2c8345E59f605eB,
            0xa4e3aDBA0308c4e12dFC9489F11200395537A29f,
            0x7904647F8056C077C540f7a396137B2c1A8737F3
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0xbf5495Efe5DB9ce00f80364C8B423567e58d2110] = LenderTokens(
            0x6679DFcbc9000dCF9A798B8f0f2B1C12D164cDd4,
            0xd025BBAc4D3A7Ab979DC0BB82f0466417D76E952,
            0xDc3c3a77a709605F07C500EDD05C8a86deFe5404
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7] = LenderTokens(
            0x0CF5a1Ab4185C69Ef715190B9c9f93b3B05ff55B,
            0xAf3B303f904caDA1e4a648555f78735bb432106B,
            0x995DC3420a58943108A9229E0039a5f0920708B4
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0xD9A442856C234a39a81a089C06451EBAa4306a72] = LenderTokens(
            0x5651bb75dE3c78815D420602B4Ce67D04a233873,
            0x62C4405476250D28AF421ca7839064Ce4Ad96B5f,
            0xBC0ae314A016E9b0bf92E9116fCeE2071C3Ec8a0
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee] = LenderTokens(
            0xd7ecAcF4cDAe0C59CDd034C6f0D959e7933bFD6c,
            0x2cF0F840D0Dcc15DAa37F4899371951B934c02ac,
            0x45D36490B0658Ba7c05C3B994B4BB283a3A03CD0
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0xae78736Cd615f374D3085123A210448E74Fc6393] = LenderTokens(
            0x16E22798a2064AdFaA09FD7c380D5CA8C895c296,
            0x240C6bAB702BA827eD11A99dF390326AD6662119,
            0x9f941E3eeF5BaA6992e5ec141216Da051B221684
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = LenderTokens(
            0x89c15CAde77CbA4f5C78D1fa845B854623Ad8696,
            0xa3c0a19b999ff397A4B3C62cA10611EEE315F426,
            0x1D21395B8fea4e0Cc20F7b13ecFfCeE7a86255c1
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0x6B175474E89094C44Da98b954EedeAC495271d0F] = LenderTokens(
            0x75287853d44f263639AF649283403eC39F895dAb,
            0xf8F0198a277f71f15D4E8c32Ae533f36dFA3084A,
            0xd15D760BdF334b3c217cC7B341c91361b592E254
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] = LenderTokens(
            0x48dFa0f826E8026ba51342FFf61E9584ECCadF69,
            0xE9e4064E4e4F7dacB787c5466DBcA8579B9def2B,
            0x37D9d4dFF739ac695ef6c5cBb1eBC4EBAEC750da
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0xdAC17F958D2ee523a2206206994597C13D831ec7] = LenderTokens(
            0xf96eB7018654082198da9Be23dd8ab1CD05A175b,
            0x271e7BA790ddEd05E5F1Cffdf6f75d0e069C34db,
            0x87A4c77F204b75fe758b61F03B803667F5AB2D24
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0x23a1E3281500AB6CF9F7caE71939a6cBFBE79435,
            0x8b134D066242E74e65D7DA62953350CCE4d2d022,
            0x7D9bF3BdCAE5BDd09c23ccF93492Bc86f04Bc361
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f] = LenderTokens(
            0x31fD1bF3C7cd90B9beC6cde73FB51763365a5522,
            0xef0791c1906190977906a49F76d3270b4c03f0C4,
            0x63E4D1fb7e0ea421915D4B9a224eb40B37152EF3
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0x657e8C867D8B37dCC18fA4Caead9C45EB088C642] = LenderTokens(
            0x022C0c5D172C91E7428867549DB2a77AFF86059A,
            0xB9FF21d4E4cBd1CeE4C1cFd0F3c953d515D9B2c8,
            0x6aCAF88F5c16bD449162E7DF7020Ff12f6321F5a
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.KINZA][0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5] = LenderTokens(
            0x7aAE11fAc797e9B21794Abd8132079cC64b6B4D4,
            0x992D2d8387B0cD432408907DD5eAC70e18760E38,
            0x781D2cF1B7bAc969d6f67dB80D2352759dC05953
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56] = LenderTokens(
            0x77800d2550d1115FB2cdBFF440F85d98A1792139,
            0x1e91220b7321767a7b1C2bA7584eE32bbbF278fD,
            0x985A6cE1D8A6Fd51faD7685B36f278A1A85D4503
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] = LenderTokens(
            0x26c8c9d74eAe6182316B30dE9ac60e2AdC9F4a04,
            0x6DAdaaf2d4a191db51854A60e4a6e23D3776EB16,
            0xDbfD649a8d5427d32742Cc82e7ceD5E81e42f74D
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x55d398326f99059fF775485246999027B3197955] = LenderTokens(
            0xA1C7f76CbCdB87B17aBF825eC2b5A1Eb823e26F1,
            0xB82C3631081eE5D1339e77b46C3E476f1fDD4a19,
            0x2e9481Be233bb47A4Bc79A4dbA55d1dABde6C687
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9] = LenderTokens(
            0xc65132D8289d39bccc3B0e72a8B901b8B180E7D9,
            0x0158d5a1D32f96F4cE68beD28F9ADdB0c43361E5,
            0xfE59cf48605C6280065a30e54D223CB8fB232C66
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] = LenderTokens(
            0x95AAE09ad8557126b169056B9bD0Ff6b5456239d,
            0x2682bD101e64f0367D3ac1261EB311EeD8B7f751,
            0xB4f997e78cF3B1B69aA69F786303939f322Dfad0
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] = LenderTokens(
            0xfd087dd64FB79E749fD8C85C64096144118B9554,
            0xb5D9e75141Dc6c264666782fA31c1b4330A5E6b4,
            0xC8F32E6d09CAb228467971DC63bAca9Ec48b3695
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] = LenderTokens(
            0xf5e0ADda6Fb191A332A787DEeDFD2cFFC72Dba0c,
            0xEAbcDA7Cfb0780A028C1fD1162e52942B96FBe10,
            0x098591e7F7051388D5ad79146161105288BC73DF
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0xa2E3356610840701BDf5611a53974510Ae27E2e1] = LenderTokens(
            0xb98EaF6CA73C13c7533dAa722223e3Dc32dD0ee5,
            0xb9755ecEA9bb7080414b0a3a4c9504F985F3F9aD,
            0xeE50f476aF1C599A9b8ddBe1951f6b039e327994
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5] = LenderTokens(
            0xC16bBfba00a2264AAb2883C49d53833F42c80B95,
            0x00107060f34B437C5A7dAF6C247e6329CF613759,
            0x85305e89CBF53744c59fD04c8A2513DD67aff724
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B] = LenderTokens(
            0xa79Befa293C06396dc49f5f80C07C2F44862eefc,
            0xee302680C91EA5773c7Dc11F6d4A4096f22c1F04,
            0xc80dffB9F13790e599aF13829Ded8b2125557037
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0xEeaA03ed0aa69fCb6e340d47FFa91A0B3426e1CD] = LenderTokens(
            0x38fc72e24Ea7372C9F9D842467c629680CDB6cBC,
            0xB0298302028681E5D71f1e469842b3E4eafEd04b,
            0x79d382b572Df5F4a0c8cEE50a05595DBb8ACe3Ce
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x45b817B36cadBA2c3B6c2427db5b22e2e65400dD] = LenderTokens(
            0xEEAa5aA3388D6A2796Ac815447a301607B52d25F,
            0x23CFaE853cDf08D3eFe4817e2016DBe47b937D35,
            0x8D20545bf6bFd29024D018062a06903276c6c683
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0xCee8c9cCd07ac0981ef42F80Fb63df3CC36F196e] = LenderTokens(
            0xc5606c8A773F4399D52391830522f113a1448404,
            0x658823636Ba31060382eA01CebB9b6B3ffe80985,
            0x78625bDF48C2905FA30A53FA43816076A756ea6a
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x2DD73dCc565761b684c56908fa01Ac270A03F70F] = LenderTokens(
            0x9F65dA9Bd6BC7D14eAcff42e918344784DFC2384,
            0x0d2ef920e4DDf573266EF9b6304407B64127e8b7,
            0xB9c9db2EE269BF6a155eAE9060e769f13bc1DAab
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0xF0DaF89F387D9D4Ac5E3326EADb20E7bEC0Ffc7C] = LenderTokens(
            0x294c4a3Eb851e7b6D296a5E8a250adE2a24dc40d,
            0x2A1431415F9F729c557e6C817eB80791e9D2C974,
            0x3810F111fb7e5861e5F66a8922758936C9A841AB
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409] = LenderTokens(
            0x8473168406d620B5cF2fc55e80B6D331E737d2e1,
            0x74aFc76da686CaC5ec786566e128CFe61822c055,
            0x17Ce8Aa97fb745bFb595Ee5dB22dFBdf41e68074
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0x19136A96B202685a2768Eb99068AdF3341414bDB,
            0xED692ba8dfAbdDCaEaC2bB76F833E00906824874,
            0x8E48fA01c17760Bc91dE60af8aF8a43b505F57a5
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x80137510979822322193FC997d400D5A6C747bf7] = LenderTokens(
            0x96619Fc54940e4147f2445b06Be857E8f11f5E8A,
            0xD197294763a82B930ab578491DFBD293846F759e,
            0x41266EDA9adecDecE2CbA377992c31CC2327DB88
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x64274835D88F5c0215da8AADd9A5f2D2A2569381] = LenderTokens(
            0x9c6faE23FdffFBE1199bABB11bc9A6859493A5a1,
            0x9cf92292C4d58745964c7ea076950438F519f3fB,
            0x8ddC850430d96aa537Bb5053950c9E031Eed4B00
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7] = LenderTokens(
            0x446B2ab906C20F9AeA62b03C86b332004EceAADC,
            0xA66Ae2356735eC9CD35Ede3ed87e556561CE462A,
            0xd28CBc4a9FDcd05C75083a0412477f0e949CB653
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82] = LenderTokens(
            0xa8D9BFcD2b4BB9C30794Ad7D49Ab1B8Da2b9f700,
            0x55371316Eb587078c5576F0f24597B1E92c5B208,
            0x8eDE75B9793D258A31f7911Be84c1c80D7962E79
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x1346b618dC92810EC74163e4c27004c921D446a5] = LenderTokens(
            0xe0169336403F03922BBF66Ca01394e4191B87C78,
            0x910D7ce736EE2e7f108aD2FffEA66D19a8179CbB,
            0x29185275606aCd18fe52d0df0Ea8132C9C859635
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0xf6718b2701D4a6498eF77D7c152b2137Ab28b8A3] = LenderTokens(
            0xe4C60C28943a7d8945683d5a6c15f59280A0D29e,
            0xe3c7183648dcAe991425Fe22117b37Aca7E91D3F,
            0x063aA144AF15367aB566913C2f4f41244a8630a4
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x23AE4fd8E7844cdBc97775496eBd0E8248656028] = LenderTokens(
            0xC390614e71512B2Aa9D91AfA7E183cb00EB92518,
            0xA5b7da4E275B1E8A5FA0b5C9088A937AF5D565d2,
            0xE188C03D384208551De30A748C6d870A9201C535
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA][0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d] = LenderTokens(
            0xE48967b3Ea41484Cf70F171627948084CB796f5c,
            0x7A07518d4BFcbf3BAddf69718711345Dd4907c19,
            0xE0Ec0CAaB656426Be033cB0045bE4517f7F595ab
        );
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.KINZA][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x54C547D42b16EB2B6AB84bE94C2dec2bd810DF4c,
            0x30c16485e6753c0Ded57a9a49c86C08a968BAF78,
            0xf8492A69F5AB2f677F4eA1798AA10BC2837f2441
        );
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.KINZA][0x9e5AAC1Ba1a2e6aEd6b32689DFcF62A509Ca96f3] = LenderTokens(
            0x8934b92c2Be79399aB78a06847CCe8a5Db5B07a2,
            0x996908b0633710d0800326478Ea0E14E2D7eF7cB,
            0xc9F77E3FA84F188A3e587dBa8764743E85C2319c
        );
        lendingTokens[Chains.MANTLE][Lenders.KINZA][0x5bE26527e817998A7206475496fDE1E68957c5A6] = LenderTokens(
            0xA077eeD346acC9DfA18C9AB7c9d76977495E27Ce,
            0x03BF771B1ead173608625264B1702EF96378D875,
            0x54d02834d033158Aa39d6CB44dE2a5bb3bA75DE4
        );
        lendingTokens[Chains.MANTLE][Lenders.KINZA][0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9] = LenderTokens(
            0x1B66b556fe5b75b327d8EC6cc1Cb4a8B76963986,
            0x8e5D37568b64E81d99c4fbeaF6981bF83DA44bFe,
            0x37491858e76a19F0e010b7Bf69c673a260A1a5F1
        );
        lendingTokens[Chains.MANTLE][Lenders.KINZA][0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE] = LenderTokens(
            0x6565b79A30F38199679aC604D4d0077A08a7f982,
            0x72a7FCE2E6DB4347dC9F0E92c81B3a62DEA2d829,
            0xCF168D295fE13FC8A34dc9A4C9C8151c40a3173C
        );
        lendingTokens[Chains.MANTLE][Lenders.KINZA][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0xc1DC4F83788eDaAc72d41E0a2751a194882C86D2,
            0x3f83Be6e450A44CEd037452185f83d5F8C910089,
            0xaDC60F68D003f48C80821F804b90A016d7A2C412
        );
        lendingTokens[Chains.MANTLE][Lenders.KINZA][0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111] = LenderTokens(
            0x438af1feD30EE1C849E731878Fa1901A6B61A723,
            0x9b2B7b7C38fC3B70045f7E3Cb282d30aE31dCCdE,
            0x5E493fBFc6EDb28E736B4A47C3791C3Cd9A2A79D
        );
        lendingTokens[Chains.MANTLE][Lenders.KINZA][0xcDA86A272531e8640cD7F1a92c01839911B90bb0] = LenderTokens(
            0x9Ac70a8142c616e23d4756268bBC4e6c55BC0d4b,
            0x9e83A5829072e251E5FdbcEf89b953e670805B3B,
            0x55E29EafD72e2c0f54871f6B51F41C9292a2867A
        );
        lendingTokens[Chains.MANTLE][Lenders.KINZA][0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8] = LenderTokens(
            0x84bdA98851b20Ba5D5C39Ce1a859a51370195624,
            0x59224Ea7F07a7fb0Cfea1FC57E8Ed2Bfe3Bd14D9,
            0x67d993891aEA01a3dfe250283D5A1Aa5c8eA9917
        );
        lendingTokens[Chains.MANTLE][Lenders.KINZA][0xC96dE26018A54D51c097160568752c4E3BD6C364] = LenderTokens(
            0xb408192471491b4FcDf5483CfE66Df9780e8fCdf,
            0x59F476DEC1da0Ca2D1A1Cd7f43A5349CaC5c7882,
            0x3A556Faba96Fb8CF0d1264f4094b108585993ecC
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.KINZA] = 0xeA14474946C59Dee1F103aD517132B3F19Cef1bE;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.KINZA] = 0xcB0620b181140e57D1C0D8b724cde623cA963c8C;
        lendingControllers[Chains.OPBNB_MAINNET][Lenders.KINZA] = 0x3Aadc38eBAbD6919Fbd00C118Ae6808CBfE441CB;
        lendingControllers[Chains.MANTLE][Lenders.KINZA] = 0x5757b15f60331eF3eDb11b16ab0ae72aE678Ed51;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(
                0x3ce38A9e2403415c50661a3f78acf4d392320e7E,
                0xdA6991Cf0Eb96d29D42682Bd201B678944Bf9D6b,
                0xBbf306933B1a0E8F0F7e9E4Cbc49cC83E2969ddF
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0xdAC17F958D2ee523a2206206994597C13D831ec7] =
            LenderTokens(
                0x4aEaFA9F24096bFe4b7354c16B2D34e2a7B92B78,
                0xE7a632694Dc4ac65583248aaf92FB5bECB54011e,
                0xf4bd886991234A94e7B1Ef6D4032bB6373e27135
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0xdC035D45d973E3EC169d2276DDab16f1e407384F] =
            LenderTokens(
                0x6125F4a075a793D53307f077d22671c57F4D1d1A,
                0x2e15D7e91a4CDC41F7feb0E1060161ff53D8a388,
                0x35D76f23ce40C91a9601f4d776195fdE7C38B60C
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x69000405f9DcE69BD4Cbf4f2865b79144A69BFE0] =
            LenderTokens(
                0xC79b0AF546577Fd71C14641473451836Abb6f109,
                0x8F3D01E68CE1c6C4d80d015c02fBC02ECA2cd157,
                0x391Fd24C210dd0Aa7D4C62309D30d8D9b6C718eE
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x939778D83b46B456224A33Fb59630B11DEC56663] =
            LenderTokens(
                0x00CB081494bDA5aCbdda7E2740f9F8b2Fbe61EE4,
                0x8f6e597e6972a1Dd1844004543Af0ea786f63e35,
                0xaaC420348Cf19C9F0A22ca424AafFA1766B57A9C
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5] =
            LenderTokens(
                0xe4F3C29Ae5fA179A86bb707d6aaB3DB2655Edcee,
                0x69B43ff2CAd50Fa9A5D567a4a4c51f804fCf6b21,
                0xfD9D36bE93D02B04165F39Ec27e1FcB4E3151533
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x35D8949372D46B7a3D5A56006AE77B215fc69bC0] =
            LenderTokens(
                0xeB02A10B2D083B08365c59A8Df01786236a29C5B,
                0x1178Dfa1c6a1d7E9eD1347f13b50ca76A399f623,
                0xA00D15745dA54b17e78eFC4a1fC762F4561703B6
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x270d664d2Fc7D962012a787Aec8661CA83DF24EB] =
            LenderTokens(
                0x905cb1537D65Fd48a2068EDa270ac2Bd30376Da6,
                0xC4A2A577DECA52b7ce26FA7a3d2893Db8429680d,
                0x988CD1D7c812896F81588F54eC4C1BCf55B468d4
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x0022228a2cc5E7eF0274A7Baa600d44da5aB5776] =
            LenderTokens(
                0x529877D3E56991080161eB1751a4b96B7109504B,
                0x1453d1E45157B434178770a75BfeB6be0c2e5253,
                0x797f7efB3E4A6fbc12a80F68B804B478E375b40a
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x5BaE9a5D67d1CA5b09B14c91935f635CFBF3b685] =
            LenderTokens(
                0x81f6494De3854cbD9d2f59dd98F4F1Eca57BFCa9,
                0x1247E1E295368C721ab8d8D48685eb4f143D432a,
                0x24Fe0b5c92a1E3C184Ec76c47fDe06B5d4a25739
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x9D39A5DE30e57443BfF2A8307A4256c8797A3497] =
            LenderTokens(
                0xE24933aA6dFb66A32Df7eA897A1818ECAaBD54E1,
                0x04A4EF5f64b31ca668380F1f0306E87B3237dD88,
                0x647b33d0B4ef15C6198EeFe7Ab2F151A080B5fC5
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x4c9EDD5852cd905f086C759E8383e09bff1E68B3] =
            LenderTokens(
                0x11cB6FD58eFF7DB834Bf00469963f7643a319fC7,
                0x934a8B117204e236D1B20b54eFdaBaBB141e67E8,
                0xe4C5171B9C648Bd37693c6E1dd0cff266fd0e2F6
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b] =
            LenderTokens(
                0x4F5Db48D5F352B3640BcAD228f37d5C982Ac1718,
                0x1fC0D61075c31b72172c8a2d01225EF330059853,
                0x18B09aFe507F865c3CEe682C9c9af9CBC3CeF59e
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d] =
            LenderTokens(
                0xA3F893Ef2d974569Dfb726B87779ED99CbE813AB,
                0xc25Ae3eb2e8c93852cC4aa2e54811B9Cd44F73FD,
                0x56bbeef5694c872ADCc209C607A06f8de60B9985
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0xE00bd3Df25fb187d6ABBB620b3dfd19839947b81] =
            LenderTokens(
                0xB73CA924Bf3e1C2C5ac4D7718700650d706aAd73,
                0x6e5B5334AA7156076F71A71472bC9e70EFCa8855,
                0x2f131E389445E7d6c44794192caE17A3CC9D189a
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x8A47b431A7D947c6a3ED6E42d501803615a97EAa] =
            LenderTokens(
                0x691aD41906e3FE78c3fE1328eCddC9BD7c0e5eb8,
                0x985Da6368e99AFB371b01cb32e34a4d7B444F70F,
                0xb182265117182989986Fd6a693908dEAe69ABcc2
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x69000dFD5025E82f48Eb28325A2B88a241182CEd] =
            LenderTokens(
                0x61C6E3081323c673D9E447A4f353F57fAD2562Ec,
                0x9EF8dBaC7eb158f16503675A96Be3e392D83e505,
                0x92400fDfdE8EEDeB7DF6fB580a48B5A4ad54787c
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x69000195D5e3201Cf73C9Ae4a1559244DF38D47C] =
            LenderTokens(
                0xe5df480329595dD4bE082Be548629c0E5420Eb9f,
                0x984a2c88f1d71bC6e415c36965Fa155cb724980c,
                0xd26cB0D7DdACb19392769218f4e379181898B92E
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x4F8E1426A9d10bddc11d26042ad270F16cCb95F2] =
            LenderTokens(
                0xc57c57523416671E494f4594a6926f39d255674B,
                0xBbb1920b54f096C8ecf1eE9cF8d4726e5C86aC0E,
                0xC49C40F7018fa3c1E1C799434aCA435a67d028A8
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA][0x1CE7D9942ff78c328A4181b9F3826fEE6D845A97] =
            LenderTokens(
                0x798D024f96fB220F701f4Aee3Bc0EF5c64dD172E,
                0xBF9126198EE2dDf2C59B0b2DB35844E600557Edb,
                0xd2C66e588B2917Dc2cdE8037B50A5a4c4A8215f1
            );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_STABLECOINS_RWA] = 0xD3a4DA66EC15a001466F324FA08037f3272BDbE8;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0x6B175474E89094C44Da98b954EedeAC495271d0F] =
            LenderTokens(
                0x29a3a6Af690942A3b7665bb2839a3f563C6F987b,
                0x0047cAC82cf5Fb36954de1B9D86d657915ab3b47,
                0x8569052157069eD81F603001596Ee8ae1c85E049
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(
                0xb2feb2c46305329a340E6188532f31FcE9347a5c,
                0x227f86FbfCCB5664403B62a5b6D4e0e593968275,
                0x7Fae822dC0A2ae436Ec10B83AE5686C008fCA718
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0xdAC17F958D2ee523a2206206994597C13D831ec7] =
            LenderTokens(
                0x6c735966bC965BD4066c14fcA3Df443496CE14fb,
                0xdAccF47046aE4FEE3F9f3bcFe68696A95dB6ccB7,
                0x14b0F7eDb2471350DEE88B1C423E0Df25C37B638
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] =
            LenderTokens(
                0xFb932A75c5F69d03B0F6e59573FDe6976aF0D88C,
                0x7EF98CD28902Ce57b7aEeC66DFB06B454CdA1941,
                0x346623fAf3cd1dBE9024c1D160cd40E6a90092ed
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee] =
            LenderTokens(
                0x84E55c6Bc5B7e9505d87b3Df6Ceff7753e15A0c5,
                0x53C94fd63Ef4001d45744c311d6BBe2171D4a11e,
                0x4931DAE3F419649931918D9E545D0F52cAE0dbEc
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0xbf5495Efe5DB9ce00f80364C8B423567e58d2110] =
            LenderTokens(
                0x68fD75cF5a91F49EFfAd0E857ef2E97e5d1f35e7,
                0x27C1706ddd2467622CA63aaEc03332127919A690,
                0x1e7f2AfD1d534077656A0cFA7871358Cb346f578
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7] =
            LenderTokens(
                0xeF4A41E692319aE4AA596314D282B3F2a3830bED,
                0xE4fe2d282DEAD5759199Df364F3F419DFaC17339,
                0x3aF8BAd4CA56AFAE60FA3a2F116cDEA803c80fbc
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0xD9A442856C234a39a81a089C06451EBAa4306a72] =
            LenderTokens(
                0xdD7Afc0f014A1E1716307Ff040704fA12E8D33A3,
                0xF99728A4b9F3371Cfcf671099edF00f49b006125,
                0x0155719a1401fDbaa62e7c6Ccd46207A0dE3282A
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0xf951E335afb289353dc249e82926178EaC7DEd78] =
            LenderTokens(
                0xB7caDc9CdFBBEf6d230DD99A7c62e294FC44BFC6,
                0xb04adAFF2f221f63B977185F5A7D8EE49aacBafF,
                0x9924462B20A93551EFBeC5EECC437b632B3cb48C
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0x8c9532a60E0E7C6BbD2B2c1303F63aCE1c3E9811] =
            LenderTokens(
                0xd9855847FFD9Bc0c5f3efFbEf67B558dBf090a71,
                0x8e3e54599d6F40c8306B895214f54882d98CD2b5,
                0x7333113aC92A86e7d562fBe9F03c62D2007Cd295
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0x7bAf258049cc8B9A78097723dc19a8b103D4098F] =
            LenderTokens(
                0x7740f60f773bc743ED76310Ac1D054A4A4A17E7C,
                0xb8D45C7FbBbc6E1D36bc1caA7d43dcc7D0513Cfd,
                0x8983845311F9df4465b8A94713A2d5824b943251
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS][0xf7906F274c174A52d444175729E3fa98f9bde285] =
            LenderTokens(
                0xb2Db477A6c198F5c524302bb67085f8f3Ab06059,
                0x8EB2F05a24b6859AAdB5D26abBc129f53D10e934,
                0x11acaa3C40A2885dBaB3265Df94272EcFEB2b8FB
            );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_ETH_LRTS] = 0x3BC3D34C32cc98bf098D832364Df8A222bBaB4c0;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] =
            LenderTokens(
                0x1d5f4e8c842a5655f9B722cAC40C6722794b75f5,
                0xa2962376f68eDb09b08F9B433F4ecae8D3217Eec,
                0xfF9E7b7b8cA570A0D655a6D6D2338721Df51e505
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0x657e8C867D8B37dCC18fA4Caead9C45EB088C642] =
            LenderTokens(
                0x52bB650211e8a6986287306A4c09B73A9Affd5e9,
                0x57C0FbFEfA18c6b438A4eb3c01354640017BF154,
                0x5cB91bEad3A3e9AD4c030A13Ef5c209dc41e4bd7
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0xB997B3418935A1Df0F914Ee901ec83927c1509A0] =
            LenderTokens(
                0x75351765D44e322681dCeb691c85eAce247E5627,
                0xCFBFCFDD63fb2305B433CBF433D7EbA21D8BF0EA,
                0x10C71923abfdaE4DBe5E78df23fD98f9787ecB80
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0x8236a87084f8B84306f72007F36F2618A5634494] =
            LenderTokens(
                0xcABB8fa209CcdF98a7A0DC30b1979fC855Cb3Eb3,
                0x028cf048867D37566b60Cee7822C857441DaC9E7,
                0xE2b6adeEdcCb6302397135Aa8254b843103871AD
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] =
            LenderTokens(
                0x0Ea724A5571ED15209dD173B77fE3cDa3F371Fe3,
                0x0519D972fdcA215e6b555B0Bb4d8D95704206B58,
                0xA8ce68264E58c0A0b2553A28890Af090b0855b28
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0x332A8ee60EdFf0a11CF3994b1b846BBC27d3DcD6] =
            LenderTokens(
                0xD9484f9d140f3300C6527B50ff81d46a9D53AcCa,
                0xef25246cfa723FDdFB54e87060A750fD5aF8679E,
                0x59dFf8a0C065722Ee0c150780Ffc2c4a0bb6f122
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0xd9D920AA40f578ab794426F5C90F6C731D159DEf] =
            LenderTokens(
                0x5d9155032e3Cd6bb2C6b6A448b79Bacb0fF01Be9,
                0x250d1435b02ddce933f73317feeBA58F78861108,
                0xfAe48848b299553EA3061c0257a86E8b36b43E53
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0x2F913C820ed3bEb3a67391a6eFF64E70c4B20b19] =
            LenderTokens(
                0xffB7Fea7567E5a84656E4fcb66a743A8C62EEF36,
                0x7f9CF95f4B8cbDC754A797da420eaEd2C6cD586A,
                0x8cD349FeFAbE744e9Ba136A705Bccc196610A87c
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0xEc5a52C685CC3Ad79a6a347aBACe330d69e0b1eD] =
            LenderTokens(
                0x813ff1cf08b381632D0087Cc6D9E17fF73A7afC8,
                0x479Fd96c82eA46Dd12244000Ba8040C9461d71D9,
                0x19936593A4Cc9019A3A8D8F93CCD759097bf170d
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0x44A7876cA99460ef3218bf08b5f52E2dbE199566] =
            LenderTokens(
                0xe2E3075C8962010E0d0B3A945c4671cc652ad5B7,
                0x6F8d2d734A77616EB45b941d12CF7D989c483421,
                0xD8EeFCB25f18Ed5b537A760e12424DCfA4306dBF
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e] =
            LenderTokens(
                0x4bF0C3a20367FA710173e660Ef7411b8B72E1795,
                0x8Ae28540B53B3a874dEd303dDbC5a233d331f6c2,
                0x9A76A2677A9F47F516137d338c6F1035966adc02
            );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS][0x18084fbA666a33d37592fA2633fD49a74DD93a88] =
            LenderTokens(
                0xbBF42226BF52241FBeAEE2331817cFD8f678676C,
                0x7d3Ee60D86fd918d5AB699c63093CE9566FfC8a9,
                0x0BC9726596a8c7D176382A75CfF6715eC9c9CCE8
            );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.ZEROLEND_BTC_LRTS] = 0xCD2b31071119D7eA449a9D211AC8eBF7Ee97F987;
        lendingTokens[Chains.MANTA_PACIFIC_MAINNET][Lenders.ZEROLEND][0x6Fae4D9935E2fcb11fC79a64e917fb2BF14DaFaa] = LenderTokens(
            0x8B6E58eA81679EeCd63468c6D4EAefA48A45868D,
            0xF61a1d02103958b8603f1780702982E2ec9F9E68,
            0x60C28A4cb4E78E9FEe49BcaAE3f4DBCde77F412f
        );
        lendingTokens[Chains.MANTA_PACIFIC_MAINNET][Lenders.ZEROLEND][0xEc901DA9c68E90798BbBb74c11406A32A70652C3] = LenderTokens(
            0x8d8b70a576113FEEdd7E3810cE61f5E243B01264,
            0x3Da71Ad7E055ee9716bBA4DaC53E37cDDF60D509,
            0x7675AbDC6139dbF46D3BB5a3DCF79e6cAd936765
        );
        lendingTokens[Chains.MANTA_PACIFIC_MAINNET][Lenders.ZEROLEND][0xb73603C5d87fA094B7314C74ACE2e64D165016fb] = LenderTokens(
            0xB4FFEf15daf4C02787bC5332580b838cE39805f5,
            0xCb2dA0F5aEce616e2Cbf29576CFc795fb15c6133,
            0x27C7733D7A0F142720Af777E70eBc33CA485d014
        );
        lendingTokens[Chains.MANTA_PACIFIC_MAINNET][Lenders.ZEROLEND][0xf417F5A458eC102B90352F697D6e2Ac3A3d2851f] = LenderTokens(
            0x759cb97fbc452BAFD49992BA88d3C5dA4Dd9B0e7,
            0xc1d9ca73f57930D4303D380C5DC668C40B38598B,
            0xB8E26F3C4AFb4f56f430a390Dc3f3b12f8A50B26
        );
        lendingTokens[Chains.MANTA_PACIFIC_MAINNET][Lenders.ZEROLEND][0x305E88d809c9DC03179554BFbf85Ac05Ce8F18d6] = LenderTokens(
            0xE7e54ca3D6F8a5561f8cee361260E537BDc5bE48,
            0xe6B9b00d42fA5831ccE4E44D9d6D8C51ba17cd1E,
            0x7C2e57764eC33292fE098636AaA5D0357d814d16
        );
        lendingTokens[Chains.MANTA_PACIFIC_MAINNET][Lenders.ZEROLEND][0x0Dc808adcE2099A9F62AA87D9670745AbA741746] = LenderTokens(
            0x0684FC172a0B8e6A65cF4684eDb2082272fe9050,
            0xcC7b5Fd2F290a61587352343b7Cf77bB35cB6f00,
            0xFFa256Ad2487c4D989C3DFA6A6e9C13Fe33beba4
        );
        lendingTokens[Chains.MANTA_PACIFIC_MAINNET][Lenders.ZEROLEND][0x2FE3AD97a60EB7c79A976FC18Bb5fFD07Dd94BA5] = LenderTokens(
            0x0ab214F127998a36Ce7aB0087a9B0D20adc2d5AD,
            0xb5EEf4Df2e48Fb41E6eaE6778c14787bAAa181F1,
            0x28D7246cd9da102c75FAa7d4Cf1c5399B323F084
        );
        lendingTokens[Chains.MANTA_PACIFIC_MAINNET][Lenders.ZEROLEND][0xbdAd407F77f44F7Da6684B416b1951ECa461FB07] = LenderTokens(
            0x77E305B4D4D3b9DA4e82Cefd564F5b948366A44b,
            0x5F62aEa5549CdF5dc309255946D69E516a9C2042,
            0xBa832bC55AF97867170271F3AfEAB5ebA1405eBC
        );
        lendingTokens[Chains.MANTA_PACIFIC_MAINNET][Lenders.ZEROLEND][0x95CeF13441Be50d20cA4558CC0a27B601aC544E5] = LenderTokens(
            0x03114e4C29EA95BF26108c2c47338488555cEd1a,
            0x061ca6fDF24D586EE9a4e4B4A1D61f9090aB48e9,
            0x7101Ff22ea63464cc106e0A3274eF4A2d28cd292
        );
        lendingTokens[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND][0xC5015b9d9161Dca7e18e32f6f25C4aD850731Fd4] = LenderTokens(
            0xA8184C63fD78EBaEd24e8f9d1c3D322357B4Aedc,
            0xa0E48Fe416fF74AE711b01540FF2144E3a1A9171,
            0xD9DD8C0Df3CcDC87d0C24AfE9a5d94C68e6Eb9F8
        );
        lendingTokens[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND][0x74b7F16337b8972027F6196A17a631aC6dE26d22] = LenderTokens(
            0x8C2399B1B6CdeEE1Dce3D211660536aBB6A19eae,
            0xE6C189b3F6cdf47184DC6DD59b28fEF0D0862b39,
            0xa316d2A934c2eD41d3F2D8A5ee99adaE92008263
        );
        lendingTokens[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND][0x1E4a5963aBFD975d8c9021ce480b42188849D41d] = LenderTokens(
            0x6D7dF47e72891C0217761b7f9a636FDbB7AD28CB,
            0xCa63175F32aB1962eeeFD80734Ad2dc360292c3c,
            0x19796424b4AF33460294Ffd616F6c422Fc61410a
        );
        lendingTokens[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND][0xEA034fb02eB1808C2cc3adbC15f447B93CbE08e1] = LenderTokens(
            0x11F1e8AD126D19f58947Cf4555118c456AFF2A41,
            0x0c87Ca5de4b9313D15337CDC0dbDE5f835558bDE,
            0x9A01FF3A7459A75C46F8C407ba50031f830516C0
        );
        lendingTokens[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND][0x5A77f1443D16ee5761d310e38b62f77f726bC71c] = LenderTokens(
            0xb85018b38030E51745b97e4D1F7814AD724C932A,
            0x0D78fac08b5DC929219ed534dF28ce3616d8b9de,
            0xE1b1167655b52782E8660Bb04bc93Ce3FA6F241f
        );
        lendingTokens[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND][0xe538905cf8410324e03A5A23C1c177a474D59b2b] = LenderTokens(
            0xDB32FcF62fc0f8720944F136A72c47C17929C877,
            0x099963068180E0f616A0040f31144b4F6218A1FC,
            0x9E5a96adeED6f94adBf76f0e50F630a62769D1e1
        );
        lendingTokens[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND][0xd077ABE1663166c0920d41Fd37ea2D9A00faBd40] = LenderTokens(
            0xed68D1Ae4EdB847Ff62398B0003a5D8C31670eFB,
            0x9328632d4b0DeC7055c32a42cf08D9DaA16330A9,
            0x54c63a74068Aa0a43fac05771d00857a7bedAD0F
        );
        lendingTokens[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND][0x5A7a183B6B44Dc4EC2E3d2eF43F98C5152b1d76d] = LenderTokens(
            0x4D63006426ACBc2cA59d92025403F821f3Bc4603,
            0x1Ad866cce39698861A0a8F1e4C9B71Afea23e15D,
            0x21786646667964AC7D402Ceea87f251fa1dD65D4
        );
        lendingTokens[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND][0x80137510979822322193FC997d400D5A6C747bf7] = LenderTokens(
            0x9cb22Ee01f5B75cB6ed8F94CC53103BF8b31341e,
            0x087Bd20A1EFc11C78AAcC8246eDAc67F871a2a8b,
            0x905449D38c6945192a23aBC17CBD2395d3B72538
        );
        lendingTokens[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND][0x5A71f5888EE05B36Ded9149e6D32eE93812EE5e9] = LenderTokens(
            0x8fB68c7367Ecd7086AAFfB4B614cc793e8Db6cF6,
            0xab9d326Dbb9C17DA56Fba2af61895ac3Fcd6Bd67,
            0x98D55416E44f47FA3BE059Da597d6B4Bc610fbe0
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4] = LenderTokens(
            0x016341e6Da8da66b33Fd32189328c102f32Da7CC,
            0xE60E1953aF56Db378184997cab20731d17c65004,
            0x5faC4FD2e4bCE392d34600d94Aa1114274e54Dff
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91] = LenderTokens(
            0x9002ecb8a06060e3b56669c6B8F18E1c3b119914,
            0x56f58d9BE10929CdA709c4134eF7343D73B080Cf,
            0x9c9158BFF47342A20b7D2Ac09F89e96F3A209b9B
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x493257fD37EDB34451f62EDf8D2a0C418852bA4C] = LenderTokens(
            0x9ca4806fa54984Bf5dA4E280b7AA8bB821D21505,
            0xa333c6FF89525939271E796FbDe2a2D9A970F831,
            0x6F977fD05962d67Eb7B16b15684fbEa0462F442d
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x90059C32Eeeb1A2aa1351a58860d98855f3655aD] = LenderTokens(
            0x52846A8D972ABbF49F67d83d5509aa4129257F46,
            0x77dcEd4833E3a91437Ed9891117BD5a61C2AD520,
            0x10eB1198B55e709309d1e6c94dbEE2b9B4977924
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x503234F203fC7Eb888EEC8513210612a43Cf6115] = LenderTokens(
            0xd97Ac0ce99329EE19b97d03E099eB42D7Aa19ddB,
            0x41c618CCE58Fb27cAF4EEb1dd25de1d03A0DAAc6,
            0x029214A5cd528433b8A4EccD7eF798210dB3518C
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0xBBeB516fb02a01611cBBE0453Fe3c580D7281011] = LenderTokens(
            0x7c65E6eC6fECeb333092e6FE69672a3475C591fB,
            0xaBd3C4E4AC6e0d81FCfa5C41a76e9583a8f81909,
            0x3f574632D049F7Cded52c529238e5c530e589b36
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0xFD282F16a64c6D304aC05d1A58Da15bed0467c71] = LenderTokens(
            0x54330D2333AdBF715eB449AAd38153378601cf67,
            0x963Cc035Edd4BC0F4a89987888304580DfA9be60,
            0xbA0bA840A827aa9F3C5EC0e6E13E6bB4dd026DdE
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x2039bb4116B4EFc145Ec4f0e2eA75012D6C0f181] = LenderTokens(
            0xb727F8e11bc417c90D4DcaF82EdA06cf590533B5,
            0x3E1F1812c2a4f356d1b4FB5Ff7cca5B2ac653b94,
            0xD47c789f91cef19C124D53087D99860cE34bE4a5
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x4d321cd88c5680Ce4f85bb58c578dFE9C2Cc1eF6] = LenderTokens(
            0x2B1BBe3ba39B943eEEf675d6d42607c958F8d20f,
            0x0EEDe84dD0dEa309382d23dD5591077127759A77,
            0xeEA10809Dd23FEbF628003B4B998821BC6aF4217
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x240f765Af2273B0CAb6cAff2880D6d8F8B285fa4] = LenderTokens(
            0xDB87A5493e308Ee0DEb24C822a559bee52460AFC,
            0x1f3DA58fAC996C2094EeC9801867028953A45325,
            0xEA8D6CE63498dda36A58374106fD6Dd3bed9DFF7
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x99bBE51be7cCe6C8b84883148fD3D12aCe5787F2] = LenderTokens(
            0x1f2dA4FF84d46B12f8931766D6D728a806B410d6,
            0x9Bad0035B31c0193Fed4322D1eb2c29AeaD799f8,
            0xbA15A3ac405C7311dd1234bfc21cc9e1f5c1b52f
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x0e97C7a0F8B2C9885C8ac9fC6136e829CbC21d42] = LenderTokens(
            0xc3b6D357e0BeADb18A23a53E1dc4839C2D15bdC2,
            0xa734aBE2A512dabf23146C97307cfC5B347Ae50A,
            0x0b272319cf39cf5FA8d2976d54189dAde1E90c2c
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x4B9eb6c0b6ea15176BBF62841C6B2A8a398cb656] = LenderTokens(
            0x15b362768465F966F1E5983b7AE87f4C5Bf75C55,
            0x0325F21eB0A16802E2bACD931964434929985548,
            0xb6ABb4183B98A2a85E1d8e9aC93542446461E2d7
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x3A287a06c66f9E95a56327185cA2BDF5f031cEcD] = LenderTokens(
            0x0A2374D4387E9c8d730e7C90eED23C045938fdBb,
            0xf001d84605B2e7Dbaaec545b431088BBF8E21DEa,
            0x033599B0BC6012Be8CD08b258569773B610e680B
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x703b52F2b28fEbcB60E1372858AF5b18849FE867] = LenderTokens(
            0xe855E73cAd110D2F3eE2288D506D6140722C04c7,
            0xa351D9EB46D4fB3269e0Fe9B7416ec2318151BC0,
            0xad99D8AafB6Aaa110E7883F0b91ab912219f965D
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E] = LenderTokens(
            0x072416442a0e40135E75C0EEfB4BE708b74B6c8a,
            0x863CD5f43a50E1141574b796D412F73232CbA60C,
            0x09990d77De57895C9227321811aFe2D6f3C8b55c
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0xE757355edba7ced7B8c0271BBA4eFDa184aD75Ab] = LenderTokens(
            0xafe91971600af83D23AB691B0a1A566d5F8E42c0,
            0x8450646d1ea5F4FeF8Ab6aF95CFfbb29664Af011,
            0xf84E6AfEAB770E08299F20c1f039dE2c07175A12
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4] = LenderTokens(
            0x9E20e83d636870A887CE7C85CeCfB8b3e95c9Db2,
            0x5C9fa0a3EE84cbc892AB9968d7c5086CC506432d,
            0x8F44D6ab626B2C3831B9A0D84322961e20d94B26
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0xA900cbE7739c96D2B153a273953620A701d5442b] = LenderTokens(
            0x76D2f67698B7bD6eC78262e4170de089B9bB7549,
            0x27024aEc8E3B9e1B2b255b982E4F2b1FECFbb2a3,
            0xDE4EA959fFA449E516287e77Da69d10447C6e02D
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0xc1Fa6E2E8667d9bE0Ca938a54c7E0285E9Df924a] = LenderTokens(
            0x05ef103F8ea305f71f037AF636bcf68f8aE047c5,
            0x06f7B47194B9956d0eaC62Adf0827752A29c08F5,
            0x4376bef9f6f3342F8B94A1cD520c13f4704E417C
        );
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND][0x0469d9d1dE0ee58fA1153ef00836B9BbCb84c0B6] = LenderTokens(
            0xe2b026b30deA792e56201308Bd566C1e1F43FB2C,
            0xD3CEe59667aC8ee5A1E2FBfF75E3F3195811885b,
            0x01C8c65D352b7C0e7d3a3f45F21b4cB66f41D8DB
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x4677201DbB575D485ad69E5c5B1e7e7888c3Ab29,
            0xfec889b48d8cb51BFd988bF211d4CfE854AF085C,
            0xb375197dC09E06382A05bE306df6a551F08a3B7B
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x940181a94A35A4569E4529A3CDfB74e38FD98631] = LenderTokens(
            0x3c2b86d6308c24632Bb8716ED013567C952b53AE,
            0x98Ef767a6184323Bf2788a0936706432698D3400,
            0xE37b9Dd1cDF9F411A9F6BB8D0c1Fa2af6B960A47
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = LenderTokens(
            0xd09600475435CaB0E40DabDb161Fb5A3311EFcB3,
            0xA397391B718f3c7F21c63E8bEb09b66607419C38,
            0x1d32fD6F0dDa3F3ef74E5BC3Da3166FEBdd698B5
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x0A27E060C0406f8Ab7B64e3BEE036a37e5a62853] = LenderTokens(
            0x2e1f66d89a95a88AFe594f6ED936B1ca76Efb74C,
            0x5E4043a302a827bfA4cb51Fa18C66109683D08eE,
            0x6017B28d5b8a46474673aD7a4914318Ad5E6dB5E
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22] = LenderTokens(
            0x1F3f89ffC8CD686ceCc845b5f52246598f1e3196,
            0x371cFA36Ef5e33c46D1E0ef2111862D5ff9f78CD,
            0x65D178978A458ff3ca39bc3df3aD9d0A0957D1bD
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0x4433Cf6E9458027FF0833f22a3CF73318908e48E,
            0x7e1B2aC5339E8bBA83c67A9444e9EE981c46cE42,
            0xf29faB0A70ad1F8aa88B2B389d4c84083f73301E
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d] = LenderTokens(
            0xB6ccD85f92FB9a8bBC99b55091855714aAeEBFEE,
            0x80E898E5AD81940fE094AC3159b08a3494198570,
            0xCD18e7d74d8aE9228c3405149725d7813363fcde
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x1097dFe9539350cb466dF9CA89A5e61195A520B0] = LenderTokens(
            0x89bb87137AfE8BaE03f4aB286de667a513cEeBdd,
            0x6b0B75C223DdD146B213Ef4E35Bc61d1De7b46A4,
            0x6bb22Ac00925F75e0A089178835CB98239B0ad30
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x04D5ddf5f3a8939889F11E97f8c4BB48317F1938] = LenderTokens(
            0x9357e7f1C49E6D0094287f882fC47774FD3bC291,
            0x19887E3d984cBBD75805dfDbC9810EFe923b897F,
            0xa5760c5e8927DDfF5fe77719890522d5432A7C3A
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0xe31eE12bDFDD0573D634124611e85338e2cBF0cF] = LenderTokens(
            0xf382E613ff8EE69F3f7557424E7cfd48792286c5,
            0x591d8D962278bD35182DECb2852dE50F83dd29d0,
            0x1F69F0A0204f059527eAe5dF451460A1cbe4b54f
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0xDBFeFD2e8460a6Ee4955A68582F85708BAEA60A3] = LenderTokens(
            0xe48d605Bb303F7e88561A9b09640AF4323C5B921,
            0xD6290195faab4B78f43EB38554e36f243218f334,
            0xE126b8eCAf14c5485B31dfdc29241d0f9141be73
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e] = LenderTokens(
            0x4759417285100F0A11846304AF76d1Ed8D9AD253,
            0x95bEB0d11951e3e4140F1265B3DF76F685740E18,
            0xE4616A793E4533C1B3069afd70161c31fD323b5A
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x7FcD174E80f264448ebeE8c88a7C4476AAF58Ea6] = LenderTokens(
            0x134eFC999957FC7984c5aB91BC7EC0f0D373b71E,
            0x1C7f3d9d02aD5fEFd1A8fEeD65957Be1EA5f649C,
            0xE3F7084849029144233F00036611245d638033eD
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0xecAc9C5F704e954931349Da37F60E39f515c11c1] = LenderTokens(
            0xbBB4080b4D4510ace168D1FF8c5cC256Ab74E1FB,
            0x8307952247925a2Ed9F5729EAF67172A77e08999,
            0x33A0A85a3f184E75333B8c25307AcFb9A5e4cB57
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0xE46c8bA948f8071b425a1f7Ba45c0a65CBAcea2e] = LenderTokens(
            0xfC68bFBf891c0e61Bc0DbA0A2DB05632E551E570,
            0x053Cf31De7D82DEaC8E026ac2078Bf7d9D3eaB14,
            0x34793C55A62C345eDd897B01D1CC78418167CAc0
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x5d746848005507DA0b1717C137A10C30AD9ee307] = LenderTokens(
            0x09ff10b3bD188EAf1b972379cc4940833361e5a8,
            0xa59bA82Be54926368407F67fc80a26e4768B6dD1,
            0x5B8aa69c812bCF29040Ec1119B0D8c6dAC4122c3
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x69000dFD5025E82f48Eb28325A2B88a241182CEd] = LenderTokens(
            0xb2dE5aceA05a42b05D05BCF252A2e15a3C93c19E,
            0xc9Fcd2e88662191706657adC69A3cbdD641D53aE,
            0x93503EcC378F723A1520BEd1b24e906dB6CC8801
        );
        lendingTokens[Chains.BASE][Lenders.ZEROLEND][0x35E5dB674D8e93a03d814FA0ADa70731efe8a4b9] = LenderTokens(
            0x9e08E9119883F9FFC59F97BBab45340F4DA0dB39,
            0x4DFa4449f0ddD7FDEA916D1242acD8a7f78259Df,
            0x52582BC17928F6a0f365728FA715649367455d05
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0xAA40c0c7644e0b2B224509571e10ad20d9C4ef28] = LenderTokens(
            0x0300FAE55cEE71a38fd80dF46Ed005Dbb40b11D7,
            0xAb3a8aEeaFcfAEEe357dB1A92f44587d70A7AD60,
            0x65c2Dd0Af6C8FC10B2cA7D228c024c718E5eFB83
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0x9BFA177621119e64CecbEabE184ab9993E2ef727] = LenderTokens(
            0x65394234796c6df1F1749cc86959162faBA3c9ff,
            0x5f9d238DbADeabfc4300D7086F7C9FEfad1301bd,
            0x57576485BEf9683c0Bcd1714401B57Ade6629E72
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e] = LenderTokens(
            0x341f4b7F8Ef76d7d8fF024cCa0AA4eA16371DfeF,
            0xdc44c343824798f57fa294Cf521a864b04Dd1BeE,
            0xf4CEB2416f2d028CAA0aa3F01B11FC6bD7774f13
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0xc3eACf0612346366Db554C991D7858716db09f58] = LenderTokens(
            0x93101C75Ba01877d5719Bf1063129995fd552982,
            0x961a14Baa7110939eda43ceBC61197087D26fE75,
            0xb6FF6beE848c1de0651Ee838F16eC63A78b061f4
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0xad11a8BEb98bbf61dbb1aa0F6d6F2ECD87b35afA] = LenderTokens(
            0x9D6256c132EdE5CEf0C0F2041E81831ae1eA5838,
            0x9076292c7203ba41A03dC59758aC4321eA54Cc03,
            0xa7c5eAe8042564dF81518bD1F994AC84B53BaBe3
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0xbB0D083fb1be0A9f6157ec484b6C79E0A4e31C2e] = LenderTokens(
            0xA9D26645559c765190d6D72370fd68C084BC56d3,
            0x4852f3d4986F25e71379db7Cd41dB7D6C44ecfA9,
            0x62eb4696Ba6Bc9978B36C7Dad4Eed2a1E518C871
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0x7A06C4AeF988e7925575C50261297a946aD204A8] = LenderTokens(
            0x007a47d8e27Cd142e300737296121aD11FfEFD8e,
            0x02c20e02b8f5FB96FF975e0Fc3f5E852e8936638,
            0x8F3E2C8C4c66Fb473227fF4679BC6E2E398995A5
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3] = LenderTokens(
            0x4Cd05D0B76E0bd902494Ac41f76970b0516FE284,
            0x15f1Ffa884Dd3635972B963DB9ca6c00F60b2Ed8,
            0xa27eBaAD7A92E5579DD248f6b6b1F8D2CF415007
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x568059251E0FC2DF2558671507eF5d7A59dcc6C3,
            0x0c5e1E5d86C208CC3A6282bEF3859CedFBCb65C1,
            0x2d861763d7416B0D693BaDc1A358f727E99C9E88
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0x93919784C523f39CACaa98Ee0a9d96c3F32b593e] = LenderTokens(
            0x9DD7aF507b64dCc08d22d5Bfc5ad682FA19FBe26,
            0xb160A2667E2A491aafc2C00E631ab54791d99b01,
            0xc5ddFEBfACE7EeDeff36666071ED84123c75D973
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.ZEROLEND][0xF9775085d726E782E83585033B58606f7731AB18] = LenderTokens(
            0xCC6485Fb5Fb3F939F59580091F290b432024b674,
            0x53a20A4150786c2e0E2645b42CDeAba0E6C45394,
            0xD235A0BEBbD42FEAF6146Ac41b39c0B423f2bdAA
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0x4200000000000000000000000000000000000006] = LenderTokens(
            0xE4D979A39AAf84757c06a6843F549aaF93921498,
            0xc669e9570014A8139504E300f7308F172AF06124,
            0xA7698fd08d5CF5A4E8113BF5F54CEE35FF70C035
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0x273c0d86c1a7f0F365D19B265210059C5Fb9b2e1,
            0xd431f76ad34D1bE98435661D9FE1755bA957e34f,
            0xa620Ab4B297fA515a7e9E1ab5fc747D44c1E7aD8
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0x3535DF6e1d776631D0cBA53FE9efD34bCbDcEeD4] = LenderTokens(
            0xa4E3a07Be0c49F84e3467f32824c1E075b0B7939,
            0x201BfbD89Fe6eD6813c81420E9628459009b6E9D,
            0x040c2F04058B80e0Bd978c1e6EeF4702Fb9e4457
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0x4b03831043082E3e5191218ad5331E99AaaC4A81] = LenderTokens(
            0xeaE490592cd82b7AC038565B1F55f8ffdA86b4B2,
            0xf30362AacD4C7e7B3c42C30f01BBd854A5A04b6e,
            0xd4FfDB36e220b1685710BE1d78AC7Ba4988A0314
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4] = LenderTokens(
            0x9262eaF2d85da1733Bf5DB1E847165E00FA6508C,
            0xAC5EE931538FA57D54aF226927e18229FD8e3f8f,
            0x13388b4Fb0367E64F8A2CE4e58B47edBACdB6feA
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0x4bcc7c793534246BC18acD3737aA4897FF23B458] = LenderTokens(
            0x8AfF6D7e9dBf66a23e10d6622d569683eCd58392,
            0x4C47E5F6f6C3C416CEB49De20a6f4D1f3FDb5A6B,
            0x15Ee531bdc57827f6349473e1B3FBf4d3eeCDD9C
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0x4186BFC76E2E237523CBC30FD220FE055156b41F] = LenderTokens(
            0x20bF3382a3d1bdE527B6f834fF872813B4A04F10,
            0x59B520efc1c6d4604451eBD357A21C09a09D4e1F,
            0x4e1dcfe916d299b21bb7DFC9B3b331f62b091264
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0x46dDa6a5a559d861c06EC9a95Fb395f5C3Db0742] = LenderTokens(
            0x0B1De50cB3238EC0cbD82cc6F80DEE27901e6809,
            0x203edD0F2dF99d47A15afe0D5B0856B92260b9a5,
            0x50E45Ab181e6A6813b4C49Fcf7f2b01c8057AA20
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0x3b952c8C9C44e8Fe201e2b26F6B2200203214cfF] = LenderTokens(
            0x0885A3a0ABB4a530815b8Da6Fb0Db88332b6DFA8,
            0xca4C0010C55acd28EEBa83c37F79De4bE56E56F1,
            0x9113DbaDfFF93920CaE164a2AE8cC751039F2074
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0x19df5689Cfce64bC2A55F7220B0Cd522659955EF] = LenderTokens(
            0x6F025bE4F5e80662D2925fcFFdEEd636507805Ea,
            0x565A46a9B9e1Bd26FB9B2EEBbC47Ea7E65AdF419,
            0x67EeFBbc80a860d73806808c274e047891E298eE
        );
        lendingTokens[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND][0xfd418e42783382E86Ae91e445406600Ba144D162] = LenderTokens(
            0xB22B4C8651aFbEe80d0e413FfE73AC6463D07Fc5,
            0xa3C3F2e326ba7253531718EFEAfa5Bb80067468e,
            0xEA8E96bFFcf8011C9e97951AbD769dFeaFb2da4D
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x176211869cA2b568f2A7D4EE941E073a821EE1ff] = LenderTokens(
            0x2E207ecA8B6Bf77a6ac82763EEEd2A94de4f081d,
            0xa2703Dc9FbACCD6eC2e4CBfa700989D0238133f6,
            0xd07e6A4da4e360ba6EdDE42ce7867051ea4BE024
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0xA219439258ca9da29E9Cc4cE5596924745e12B93] = LenderTokens(
            0x508C39Cd02736535d5cB85f3925218E5e0e8F07A,
            0x476F206511a18C9956fc79726108a03E647A1817,
            0x607f422f2e2de0FD1b084223ED16AE51c2453b06
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f] = LenderTokens(
            0xB4FFEf15daf4C02787bC5332580b838cE39805f5,
            0xCb2dA0F5aEce616e2Cbf29576CFc795fb15c6133,
            0x27C7733D7A0F142720Af777E70eBc33CA485d014
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0xf3B001D64C656e30a62fbaacA003B1336b4ce12A] = LenderTokens(
            0x759cb97fbc452BAFD49992BA88d3C5dA4Dd9B0e7,
            0xc1d9ca73f57930D4303D380C5DC668C40B38598B,
            0xB8E26F3C4AFb4f56f430a390Dc3f3b12f8A50B26
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x894134a25a5faC1c2C26F1d8fBf05111a3CB9487] = LenderTokens(
            0xE7e54ca3D6F8a5561f8cee361260E537BDc5bE48,
            0xe6B9b00d42fA5831ccE4E44D9d6D8C51ba17cd1E,
            0x7C2e57764eC33292fE098636AaA5D0357d814d16
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0x0684FC172a0B8e6A65cF4684eDb2082272fe9050,
            0xcC7b5Fd2F290a61587352343b7Cf77bB35cB6f00,
            0xFFa256Ad2487c4D989C3DFA6A6e9C13Fe33beba4
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x3aAB2285ddcDdaD8edf438C1bAB47e1a9D05a9b4] = LenderTokens(
            0x8B6E58eA81679EeCd63468c6D4EAefA48A45868D,
            0xF61a1d02103958b8603f1780702982E2ec9F9E68,
            0x60C28A4cb4E78E9FEe49BcaAE3f4DBCde77F412f
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0xD2671165570f41BBB3B0097893300b6EB6101E6C] = LenderTokens(
            0x8d8b70a576113FEEdd7E3810cE61f5E243B01264,
            0x3Da71Ad7E055ee9716bBA4DaC53E37cDDF60D509,
            0x7675AbDC6139dbF46D3BB5a3DCF79e6cAd936765
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x1Bf74C010E6320bab11e2e5A532b5AC15e0b8aA6] = LenderTokens(
            0x77E305B4D4D3b9DA4e82Cefd564F5b948366A44b,
            0x5F62aEa5549CdF5dc309255946D69E516a9C2042,
            0xBa832bC55AF97867170271F3AfEAB5ebA1405eBC
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x15EEfE5B297136b8712291B632404B66A8eF4D25] = LenderTokens(
            0x03114e4C29EA95BF26108c2c47338488555cEd1a,
            0x061ca6fDF24D586EE9a4e4B4A1D61f9090aB48e9,
            0x7101Ff22ea63464cc106e0A3274eF4A2d28cd292
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x529D26AaE1606910aB32E1aeB9dBEe8597618F28,
            0xAbE144177c341E30A35CDe436ee159CD7C1db77A,
            0x144285BCD4169B7dC2b8661CCd432608A2532ac5
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0x5c44C9E5182193CE4E24b8F85c9C914c59D57767,
            0x068B5441787B0b973E25D5DbDaCB7A7c2161Af51,
            0x0410Fb2330217120ED8E9590543E1c0ea9a00E70
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F] = LenderTokens(
            0x9Eb8879231c71BD739967628CA26b72810BEEaD8,
            0xa26982964E57E8cB5639e3a44C55f085695E0a26,
            0xA824332668C9f48aF566Cb248F9bCF70666cCCc7
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x93F4d0ab6a8B4271f4a28Db399b5E30612D21116] = LenderTokens(
            0xCCF76F25D5CC39DB7cd644A5A66eFf91b2cdcC25,
            0xD039544fca3D8Df85a0f4441FDF8B0836DB97871,
            0x2A43d971B2D4D3649bCA8d14D665c65D9E981345
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0xEcc68d0451E20292406967Fe7C04280E5238Ac7D] = LenderTokens(
            0x1820335EbA09B72CE46c0dE4650f71c7505b4824,
            0x06EcDfDe2D468aEd563D5765356b6DEF4901b6bC,
            0x9861087FE7F894C52eFC7b9E12BfabA57FD03961
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x4AF15ec2A0BD43Db75dd04E62FAA3B8EF36b00d5] = LenderTokens(
            0x0f87d0618b873Be947fF7d3620C51b832b71c4d0,
            0x0889B840f9285d790Ccd3d09703Af347e0299F42,
            0x0368CF2183dE1D0a8187e63caB2De9c53FfD4D8b
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x5A7a183B6B44Dc4EC2E3d2eF43F98C5152b1d76d] = LenderTokens(
            0x4585CBe390Df68CbAa36c0d0886e8528C31c7c11,
            0x53A44b6384C28c099dC168Fd1d9044105e23c632,
            0x705b5eE015F12Fc29066b1E5214A2CAC702211Fa
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0xb20116eE399f15647BB1eEf9A74f6ef3b58bc951] = LenderTokens(
            0x5BB96d49dE7f1049DabE055d37F1a32f05639756,
            0x35F01b5200165B5Cf67B09917452B0e434a63965,
            0x9C5800AB1B2A466FFfD69A891aAc7A54A616F48F
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0x5FFcE65A40f6d3de5332766ffF6A28BF491C868c] = LenderTokens(
            0x8FAB2E296934D9E930Aa6c3150059B0b4aDb06F5,
            0x46519Da582e2231E05613F0908ac991374905dB6,
            0x6Aa675f7c9a351A95bb3324bfd12B7BCc7cbECeB
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND][0xe4D584ae9b753e549cAE66200A6475d2f00705f7] = LenderTokens(
            0x537d6dD4E12C16eFA951591C66d0c1A14970A980,
            0x205e01ef33fCd660FF4A7caa6d12413f23d2Bace,
            0x9F8239F73f173C69576048918D06AAbd0d47A3F4
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x657e8C867D8B37dCC18fA4Caead9C45EB088C642] = LenderTokens(
            0xA1346360c5B5b05C379957329AD553a823040a9c,
            0xe70E300D0b06697606C5E733eB2d0Ceb9CDdA05c,
            0x802c1e2ec2960BC1a20B072684231849a8c37202
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590] = LenderTokens(
            0x893Dbf4E886488f85B0Ba4B5Ac8e45AC6f3a4f75,
            0x4ff3Fd28797C3bbd2BA4a13253623df756905dbb,
            0x047db0362fa8AfC275417Fb87aD4514ff6ADF9D7
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0xFCBD14DC51f0A4d49d5E53C2E0950e0bC26d0Dce] = LenderTokens(
            0x6C8362c4237717a6A1DA87DC933781d2fa002608,
            0xCa19a7D43fdB6f2Be9af3970d5E1393D094a5bb6,
            0x292f55e2e753260ac1D48Ea84b37587B2231b30B
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b] = LenderTokens(
            0x14a1Ec80053bae6469d97cb5B3fedfAa1d8a6789,
            0xc8f4FE78375515b6849BE367C411458f6c25A2D3,
            0x8805aC99517816B9336b63C701dF25CbFAA8dBF9
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0xecAc9C5F704e954931349Da37F60E39f515c11c1] = LenderTokens(
            0xB2B4A2886B9E790A6eB8068F544364c589B8205B,
            0x7E29E47989820477877Ee64F92f55C024A28B3F7,
            0x12ec8Cf95732D534CA3970fdd9cc25f178854757
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x1cE0a25D13CE4d52071aE7e02Cf1F6606F4C79d3] = LenderTokens(
            0xa494d58D9fF0165073B81D290c22F6B6f68e1D31,
            0x51C0a5BFf0b17a5D907B75dD2f61EC3B6BC42806,
            0x67321F550B41E9976D1B2a99a62269Fe11a07888
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x4186BFC76E2E237523CBC30FD220FE055156b41F] = LenderTokens(
            0x966473CCa4803725201CCB343fd6dfa027e53Cd3,
            0xe208B81F98E3264249050F2Ba8d21Adf1AF62454,
            0x2e9aC4523A9187Bf17b5B91e961C314bded4693A
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x850CDF416668210ED0c36bfFF5d21921C7adA3b8] = LenderTokens(
            0xf228DC73B2E2906e717365F8897B9fFafb6a8697,
            0x8f2f7B3637C52378806af676da2e42F4e7F32c99,
            0xCD6D03156e03933352B4B292d83165255dDad6A4
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0x385867d0742E4855F6391AA778CdC737fE773139,
            0xE479D88d5186D9F1FdBf7b89a7122D733c3EdE8E,
            0x621D217BD88ec06cb82F6Fb801e97FA4D63484b3
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x549943e04f40284185054145c6E4e9568C1D3241] = LenderTokens(
            0x89BEFE1253e6452aEA08Ae297DA9401816B39Cd4,
            0xee9635eC44699264C1074eE18156b22A0E73e76B,
            0x0c0e63a3A4877f6bf0e3Ce5e7DF7D7C0A896735b
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0x194e899DC8CD36c8BC19613d52130f6b08695773,
            0xda41c182029fb899B9Af1735D3ecCF5bef2F3750,
            0x62dC405C88794A82D546a0626Ae8b984EB2d785E
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x779Ded0c9e1022225f8E0630b35a9b54bE713736] = LenderTokens(
            0xCa47be2f687E1811a623593752994C74C190b52E,
            0x5d3Fb96A3707c52D2127342Ab6E73E50917B70cF,
            0x65aDc9081B68954Ae95763D0c0a7a285Bde68B1F
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x6969696969696969696969696969696969696969] = LenderTokens(
            0x710184c3639e0aBC94f4bd5a59a16B4F5BEDcec6,
            0x7e61e42202A835aa8968A3A5A75AC16b29b77944,
            0xaEcE9740584F0577D156d64402FD3580B1E6C039
        );
        lendingTokens[Chains.BERACHAIN][Lenders.ZEROLEND][0x7DCC39B4d1C53CB31e1aBc0e358b43987FEF80f7] = LenderTokens(
            0x6aD5726d6B151f95E1622cf3c1e895C4854aC9ba,
            0x574e5a73eA36b886b0B3b0A461a6dDdEee59C168,
            0x2eaA299c9bF59FF35e9B29bE8f9b8FC0A39Ec64a
        );
        lendingTokens[Chains.BLAST][Lenders.ZEROLEND][0x4300000000000000000000000000000000000003] = LenderTokens(
            0x23A58cbe25E36e26639bdD969B0531d3aD5F9c34,
            0x0e914b7669E97fd0c2644Af60E90EA7ddb4F91d1,
            0xBc83DcBc06876B463EFdE74a0539D78c586F90e8
        );
        lendingTokens[Chains.BLAST][Lenders.ZEROLEND][0x4300000000000000000000000000000000000004] = LenderTokens(
            0x53a3Aa617afE3C12550a93BA6262430010037B04,
            0x29c2Bc372728dacB472A7E90e5fc8Aa0F203C8CD,
            0x045D5602FAF1abB4c3f3c62FA70293450d9d5106
        );
        lendingTokens[Chains.BLAST][Lenders.ZEROLEND][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0xEaad75b283Ec8779B9C7b5b2cC245f4755eD4595,
            0x95241286314B57EBDcDfE7DAA0E0BEC651e8De61,
            0x74F2887Af800CbB688DF6ceEE5Ebb58E9491C063
        );
        lendingTokens[Chains.BLAST][Lenders.ZEROLEND][0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A] = LenderTokens(
            0x99b68C56e6C1aC19F52132c3023B5270AADadb07,
            0xeE09b82100481065bCED265bCB35eA4ecB240598,
            0x8FEab183E51439ddc7D73A24908389cCc214bAa2
        );
        lendingTokens[Chains.CORN][Lenders.ZEROLEND][0xda5dDd7270381A7C2717aD10D1c0ecB19e3CDFb2] = LenderTokens(
            0x126D09B159b8b07985F279f93A55c4c65Af9A1Cb,
            0x1624E9561DFB170EF48A5b6974c98Dcf35d63DD2,
            0x936e510D448054E4a05920d5e92436127f0E1bEa
        );
        lendingTokens[Chains.CORN][Lenders.ZEROLEND][0x657e8C867D8B37dCC18fA4Caead9C45EB088C642] = LenderTokens(
            0xfad13D1CDcFBB9042fBec263194D7F48f870e35A,
            0x967916D3B842944caFd0Ef4A03BFE3Fbeef87f09,
            0x37EAD94959A4f3a44a9a1086af4e364db0854412
        );
        lendingTokens[Chains.CORN][Lenders.ZEROLEND][0xecAc9C5F704e954931349Da37F60E39f515c11c1] = LenderTokens(
            0xBc596C5794C12ea9d41922a5d13Cc1FAdbE4B37f,
            0xc27Af31Dc029aBC7FE57cdD3f038335074bec2fE,
            0xd26710c7A18ea0E572aAceF285373fa1C4C9ce45
        );
        lendingTokens[Chains.CORN][Lenders.ZEROLEND][0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e] = LenderTokens(
            0xCE23e3b746d1425D01df06134680753166b3d02F,
            0x37744f56f31778dBBF5f61d137dB939F5A1e55c4,
            0xA4A0aED915e563bACcB54D2191cA677475236eD4
        );
        lendingControllers[Chains.MANTA_PACIFIC_MAINNET][Lenders.ZEROLEND] = 0x2f9bB73a8e98793e26Cb2F6C4ad037BDf1C6B269;
        lendingControllers[Chains.X_LAYER_MAINNET][Lenders.ZEROLEND] = 0xfFd79D05D5dc37E221ed7d3971E75ed5930c6580;
        lendingControllers[Chains.ZKSYNC_MAINNET][Lenders.ZEROLEND] = 0x4d9429246EA989C9CeE203B43F6d1C7D83e3B8F8;
        lendingControllers[Chains.ABSTRACT][Lenders.ZEROLEND] = 0xFC1ef22b9458F112Ef4EB6BF1c537776f0341185;
        lendingControllers[Chains.BASE][Lenders.ZEROLEND] = 0x766f21277087E18967c1b10bF602d8Fe56d0c671;
        lendingControllers[Chains.HEMI_NETWORK][Lenders.ZEROLEND] = 0xdB7e029394a7cdbE27aBdAAf4D15e78baC34d6E8;
        lendingControllers[Chains.ZIRCUIT_MAINNET][Lenders.ZEROLEND] = 0x2774C8B95CaB474D0d21943d83b9322Fb1cE9cF5;
        lendingControllers[Chains.LINEA][Lenders.ZEROLEND] = 0x2f9bB73a8e98793e26Cb2F6C4ad037BDf1C6B269;
        lendingControllers[Chains.BERACHAIN][Lenders.ZEROLEND] = 0xE96Feed449e1E5442937812f97dB63874Cd7aB84;
        lendingControllers[Chains.BLAST][Lenders.ZEROLEND] = 0xa70B0F3C2470AbBE104BdB3F3aaa9C7C54BEA7A8;
        lendingControllers[Chains.CORN][Lenders.ZEROLEND] = 0x927b3A8e5068840C9758b0b88207b28aeeb7a3fd;
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND_CROAK][0x176211869cA2b568f2A7D4EE941E073a821EE1ff] = LenderTokens(
            0x711449eA0f3c6d9E1626E72AA431597B9216F3D4,
            0x2b9881dDB5570ae9EbA081FA7fDF334e4195e3DE,
            0x8Cb14e515A98fc3ba7495867ef2e6450Cf12C2Aa
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND_CROAK][0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f] = LenderTokens(
            0x176e1E2Be1704bf5CF9c55d5ac2282355355B8d0,
            0x5C8957Af6341D824d615faBACB3dbaB75932695b,
            0x86453BD0075DC4B5f255a3679f0C9475107847d9
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND_CROAK][0xaCb54d07cA167934F57F829BeE2cC665e1A5ebEF] = LenderTokens(
            0xE59691dd4B38Ba4632A51d1F7596C431ad36907C,
            0xB1048e86A1A1FaF0eE53ce78CDD5E0180643DC46,
            0x5D30EFeE91787133EcAcF1Ca40808123382Adc8F
        );
        lendingControllers[Chains.LINEA][Lenders.ZEROLEND_CROAK] = 0xc6ff96AefD1cC757d56e1E8Dcc4633dD7AA5222D;
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND_FOXY][0x176211869cA2b568f2A7D4EE941E073a821EE1ff] = LenderTokens(
            0xDAe1f8cFD0293bd3eF2541Ccb4F265290181cac2,
            0x384A318215Aca36084Af3719f3c84aA2167de6bE,
            0x0Aa52B766999BD7570c5999f2e5e7c0989C5F79F
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND_FOXY][0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f] = LenderTokens(
            0x9CAB55d186a45bb29FABDBc0118855CF642d8012,
            0xFbb30e625Ba0AA35C13a86Ef49AB4F2bAfa21538,
            0xf6f54eB569dc28e68C35a640846f0Ce70c2aC86B
        );
        lendingTokens[Chains.LINEA][Lenders.ZEROLEND_FOXY][0x5FBDF89403270a1846F5ae7D113A989F850d1566] = LenderTokens(
            0xd84a3F1380Ec35ab4cDB16a95508a11F2F474356,
            0x613aC3930A5B2805e48Be151Bea8C29D394F8A86,
            0xb490091282A566d4B6D466C7cb5f0cc0A8c3d230
        );
        lendingControllers[Chains.LINEA][Lenders.ZEROLEND_FOXY] = 0xbDAa004A456E7f2dAff00FfcDCbEaD5da27B7966;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.GRANARY][0x6B175474E89094C44Da98b954EedeAC495271d0F] = LenderTokens(
            0xe7334Ad0e325139329E747cF2Fc24538dD564987,
            0xe5415Fa763489C813694D7A79d133F0A7363310C,
            0xC40709470139657E6D80249c5cC998eFb44898C9
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.GRANARY][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = LenderTokens(
            0x02CD18c03b5b3f250d2B29C87949CDAB4Ee11488,
            0xBcE07537DF8AD5519C1d65e902e10aA48AF83d88,
            0x73C177510cb7b5c6a7C770376Fc6EBD29eF9e1A7
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.GRANARY][0xdAC17F958D2ee523a2206206994597C13D831ec7] = LenderTokens(
            0x9c29a8eC901DBec4fFf165cD57D4f9E03D4838f7,
            0x06D38c309d1dC541a23b0025B35d163c25754288,
            0x6f66C5C5e2FF94929582EaBfc19051F19ed9EB70
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.GRANARY][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] = LenderTokens(
            0x272CfCceFbEFBe1518cd87002A8F9dfd8845A6c4,
            0x5eEA43129024eeE861481f32c2541b12DDD44c08,
            0x09AB5cA2d537b81520F78474d6ED43675451A7f8
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.GRANARY][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] = LenderTokens(
            0x58254000eE8127288387b04ce70292B56098D55C,
            0x05249f9Ba88F7d98fe21a8f3C460f4746689Aea5,
            0xc73AC4D26025622167a2BC67C93a855C1c6BDb24
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] = LenderTokens(
            0x18D2b18Af9A1f379025f46b8aeB4aF75f6642c9F,
            0xbaBDD3E2231990b1f47844536E19B2F1CC1D5077,
            0xf3F47cc1d683C3e8862EcCE239E6679C331499d3
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0x7F5c764cBc14f9669B88837ca1490cCa17c31607] = LenderTokens(
            0x7A0FDDBA78FF45D353B1630B77f4D175A00df0c0,
            0xb271973b367E50fcDE5Ee5e426944C37045Dd0bf,
            0xBd11f9AD2522447849C376B9cbBcdcFD80814f17
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0x94b008aA00579c1307B0EF2c499aD98a8ce58e58] = LenderTokens(
            0x4e7849f846f8cdDAF37c72065b65Ec22cecEE109,
            0x5c4Acfcba420F8A0E14b7aaDA3d8726452642FBb,
            0xD3d5Fd831C00c5cB54A925B8263508ccCaBf070E
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0x68f180fcCe6836688e9084f035309E29Bf0A2095] = LenderTokens(
            0xbd3dbf914f3e9c3133a815b04a4d0E5930957cB9,
            0x62BBFAEf552522Be2BDA7f69cc5B2C36c1879600,
            0x5b015f3e5535D972C47c303854cbc304743Aefcc
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0x4200000000000000000000000000000000000006] = LenderTokens(
            0xfF94cc8E2c4B17e3CC65d7B83c7e8c643030D936,
            0x0A05d3D77b66aF45233599fe4F5558326E4AD269,
            0x757aBEffEDe648f482e13C9A05cfC1879619e270
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0x4200000000000000000000000000000000000042] = LenderTokens(
            0x30091e843deb234EBb45c7E1Da4bBC4C33B3f0B4,
            0xB1AfE7c8D6d94e8EF04Ab3C99848a3B21A33d9eF,
            0x9C6EB7B564f1B81E9E8a41a6E8e5e34D0d9a570F
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9] = LenderTokens(
            0x8AaA9d29305D331aE67AD65495B9e22cf98f9035,
            0xc0031304549E494f1F48A9AC568242B1a6Ca1804,
            0xF0E94bdC2D589EaD059072aC1BF27c67ACf931B6
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0xFE8B128bA8C78aabC59d4c64cEE7fF28e9379921] = LenderTokens(
            0x7fB37AE8BE7F6177F265E3Ff6d6731672779eb0B,
            0x49e03c399F0f84083D6f6549383fc80D11701Bd4,
            0xb9131478Fb7d590948B2948Fca0b8c3C06fC053F
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4] = LenderTokens(
            0xa73b7C26eF3221BF9eA7E5981840519427f7dCaF,
            0x9dd559b1d7454979b1699d710885Ba5C658277E3,
            0xC539CA809d6d7C3B37759c4A4484202204AA1484
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb] = LenderTokens(
            0x1a7450AACc67d90afB9e2C056229973354cc8987,
            0xD0260eA91B263619a27EfeEF512A04fb482915E7,
            0x855Ee76BA443E36Aeb3775eE30b8f94947B0cDE9
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.GRANARY][0xadDb6A0412DE1BA0F936DCaeb8Aaa24578dcF3B2] = LenderTokens(
            0xc69ec3664687659dC541CD88EF9d52a470b93FbE,
            0xbED938b24e2432168CB1c09F10eC9609Bf5BAdb0,
            0x1ddaaB33e2B360F28C1E24F196D34Ce5d1e813D9
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GRANARY][0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3] = LenderTokens(
            0x6055558D88DDE78df51bF9E90Bdd225D525Cf80b,
            0xa0758Cd24cF68f486F3F6D96e833680d4971ccf8,
            0x6F4FDe7277E70483C344e3175b1262928FB52BAE
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GRANARY][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] = LenderTokens(
            0xe37BbfdD50b715d49df6e596f9248BFE6b967cd7,
            0x2f4e44316AF0CAc2154f95acca305082A2382e98,
            0xE56873b4886E4C08a07498a90D6Cdb2f0069c4B3
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GRANARY][0x55d398326f99059fF775485246999027B3197955] = LenderTokens(
            0x7E25119b5e52c32970161F1e0da3e66BBef100F1,
            0x573BcE236692b48f5Faa07947e78C1e282E16c28,
            0xaf8ED214adF8358D296a3135BfEf8167594D181D
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GRANARY][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] = LenderTokens(
            0x6c578574a5400C5E45F18Be65227cFc2A64D94f7,
            0x7F459f3C6d068168eF791746602ca29180B5d03F,
            0x60516165Bcee35870499AcD040ba8B586f280959
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GRANARY][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] = LenderTokens(
            0x2a050A0D74C9A12bA44bd2acA9D7D7d1bDF988E9,
            0xa7EDe8701D7dac898b04DDf27C781b4eB961443f,
            0x64F719B2A1668835337fff491e7c88402093fbB4
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GRANARY][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] = LenderTokens(
            0x70aD5E32e6ea548DcE7D331B447C2791cf695a98,
            0x839c8Ca0873De853c5F8DF1ef3e82e9da398abf6,
            0x24f515b64f1D5dc8D702dAa4e0cE0Ef9FcdcE589
        );
        lendingTokens[Chains.FANTOM_OPERA][Lenders.GRANARY][0x91a40C733c97a6e1BF876EaF9ed8c08102eB491f] = LenderTokens(
            0x74C79B7766Cdc565B96A5dC5dB3209095354A425,
            0x165c922F73D6f928F477aCe411Fa83Ce8BaF003D,
            0x103F51E07Dbd38802AFf8C9eB1D2BE0a15d26bEB
        );
        lendingTokens[Chains.FANTOM_OPERA][Lenders.GRANARY][0x28a92dde19D9989F39A49905d7C9C2FAc7799bDf] = LenderTokens(
            0x59c5c2cc79DEA0585d118e61236C162E63C68418,
            0x24FDDc9d15136D678fe2B9B474eEd18ce8c1531F,
            0xB3002ad5AC9C8E46f42276BffF2F107a4a2Fdada
        );
        lendingTokens[Chains.FANTOM_OPERA][Lenders.GRANARY][0xcc1b99dDAc1a33c201a742A1851662E87BC7f22C] = LenderTokens(
            0x2c5F206787e0960782498448e420C02855C2f3E6,
            0x577dCe25f4aA35e7DC11e37F550c1e0e179CC736,
            0xE0BBb7B04B293b4E622232488d0C85c34e1eEdbC
        );
        lendingTokens[Chains.FANTOM_OPERA][Lenders.GRANARY][0xf1648C50d2863f780c57849D812b4B7686031A3D] = LenderTokens(
            0x1EE82200C8fdC956f8fBC6ae9B0BB6C2d8f3e826,
            0xDdE6F2dce052716D9F9ff2d61DE3Dcd8CdB62def,
            0x1BaD4D2921E2fF87B3c4209A323434529D003205
        );
        lendingTokens[Chains.FANTOM_OPERA][Lenders.GRANARY][0x695921034f0387eAc4e11620EE91b1b15A6A09fE] = LenderTokens(
            0xb805310418dE7a41Eb65F8097bae43180196CC78,
            0x3c35E97CAcB269472b8bc2D483667c1eaF4a817e,
            0x99ee23E5440d537cf04698Fe33F0E00AC98fa896
        );
        lendingTokens[Chains.FANTOM_OPERA][Lenders.GRANARY][0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83] = LenderTokens(
            0xdc1e55c321f2DC8d95275cFc4E9bD1555526872a,
            0x703EA7dB0f2a5CCE716A110D45e64AD5905d15B7,
            0x4a4f7eFA2ea2AD2caFf8BAE75530F28403E8E135
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.GRANARY][0xEA32A96608495e54156Ae48931A7c20f0dcc1a21] = LenderTokens(
            0x37FA438EdfB7044E9444b4022b2516C4dAA4592F,
            0x1EeE9a7452C6E73E6FAE6B6f95BFcb3AFebEDDbD,
            0x9E398d935d3E9e02319124110AaB1B4646944f45
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.GRANARY][0xbB06DCA3AE6887fAbF931640f67cab3e3a16F4dC] = LenderTokens(
            0x18bA3e87876f4982810d321D447b81d01Cdf6668,
            0xeaF4cBd2622bF807a02091804dB775Cdce2169FB,
            0x179659d5E67C64b54B0DF4960389787FfA4db6c2
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.GRANARY][0xa5B55ab1dAF0F8e1EFc0eB1931a957fd89B918f4] = LenderTokens(
            0x826ED083724909196e6598452Be4fDFe0FA6C7CD,
            0x9aE05c138ebAa84c0e65eE63eDd5ad64A8b78AB6,
            0xcdCE2DE35069a192c74A44aDc94323bF80F8adcf
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.GRANARY][0x420000000000000000000000000000000000000A] = LenderTokens(
            0x73d49aC28C4Fea2B8e7C6BF45d64A2e68ed53bE0,
            0xE772Bf4d6f458552BC6A0E067eFD69B9C1acBCC3,
            0xcbd8930edDe3F64CFf1f1b1F079282d1377Db62b
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.GRANARY][0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000] = LenderTokens(
            0x7f5eC43a46dF54471DAe95d3C05BEBe7301b75Ff,
            0xaD7db4DF1454497ED1a972c0B699FB9267dAa6fe,
            0x3064632AC6D1442B1b1d5e37B28451463fc2Abd0
        );
        lendingTokens[Chains.METIS_ANDROMEDA_MAINNET][Lenders.GRANARY][0x433E43047B95cB83517abd7c9978Bdf7005E9938] = LenderTokens(
            0x475F3AB387157ebC645874aEA1836223B7cC5d19,
            0x019F9FCD645b673C75b57d112BB184C6B6696c01,
            0xd4A4E9211d9A780B84f306ddD65DFD954cD77Db7
        );
        lendingTokens[Chains.BASE][Lenders.GRANARY][0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb] = LenderTokens(
            0xe7334Ad0e325139329E747cF2Fc24538dD564987,
            0xe5415Fa763489C813694D7A79d133F0A7363310C,
            0xC40709470139657E6D80249c5cC998eFb44898C9
        );
        lendingTokens[Chains.BASE][Lenders.GRANARY][0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA] = LenderTokens(
            0x02CD18c03b5b3f250d2B29C87949CDAB4Ee11488,
            0xBcE07537DF8AD5519C1d65e902e10aA48AF83d88,
            0x73C177510cb7b5c6a7C770376Fc6EBD29eF9e1A7
        );
        lendingTokens[Chains.BASE][Lenders.GRANARY][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x9c29a8eC901DBec4fFf165cD57D4f9E03D4838f7,
            0x06D38c309d1dC541a23b0025B35d163c25754288,
            0x6f66C5C5e2FF94929582EaBfc19051F19ed9EB70
        );
        lendingTokens[Chains.BASE][Lenders.GRANARY][0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22] = LenderTokens(
            0x272CfCceFbEFBe1518cd87002A8F9dfd8845A6c4,
            0x5eEA43129024eeE861481f32c2541b12DDD44c08,
            0x09AB5cA2d537b81520F78474d6ED43675451A7f8
        );
        lendingTokens[Chains.BASE][Lenders.GRANARY][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0x58254000eE8127288387b04ce70292B56098D55C,
            0x05249f9Ba88F7d98fe21a8f3C460f4746689Aea5,
            0xc73AC4D26025622167a2BC67C93a855C1c6BDb24
        );
        lendingTokens[Chains.BASE][Lenders.GRANARY][0x940181a94A35A4569E4529A3CDfB74e38FD98631] = LenderTokens(
            0xe3f709397e87032E61f4248f53Ee5c9a9aBb6440,
            0x083E519E76fe7e68C15A6163279eAAf87E2addAE,
            0x383995FD2E86a2e067Ffb31674aa0d1B370B39bD
        );
        lendingTokens[Chains.BASE][Lenders.GRANARY][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = LenderTokens(
            0xC17312076F48764d6b4D263eFdd5A30833E311DC,
            0x3F332f38926b809670b3cac52Df67706856a1555,
            0x5183adca8472B7c999c310e4D5aAab04ad12E252
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.GRANARY][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] = LenderTokens(
            0xFC2eaC1AeB490d5ff727E659273C8AfC5dD2b0bb,
            0xFdF4EE30CEFF9a6253d4Eb43257abC361433bF04,
            0x75803D39dB1f2d3C84fd1B3AD74D5070283c0E39
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.GRANARY][0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8] = LenderTokens(
            0x6C4CB1115927D50E495E554d38b83f2973F05361,
            0xE2B1674f85c8a1729567f38CB502088c6E147938,
            0x3fc33103748cB94495Be26A35C6b77B2D7a71A61
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.GRANARY][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] = LenderTokens(
            0x66ddD8F3A0C4CEB6a324376EA6C00B4c8c1BB3d9,
            0x3E2deEDA33d8Ba579430F38868Db3ed0e2394576,
            0x03ADcEC5D760E50A2bed982cb5e6A6Ab2580D55E
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.GRANARY][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] = LenderTokens(
            0x731e2246A0c67b1B19188C7019094bA9F107404f,
            0x8DaEc4344A99f575B13DE9F16c53d5bf65e75a42,
            0x01C4dD26296E7A13418D0dc6822591810da8B989
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.GRANARY][0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] = LenderTokens(
            0x712F1955E5eD3F7A5Ac7B5E4c480db8edF9b3fD7,
            0xC5e029C1097D9585629aE4bDf74C37182EC8d1ba,
            0xC39b18F5E6F3338B787d10bb6c37058D29c1DA79
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.GRANARY][0x912CE59144191C1204E64559FE8253a0e49E6548] = LenderTokens(
            0x8B9a4ded05ad8C3AB959980538437b0562dBb129,
            0x5935530b52332D1030d98c1ce06F2943E06B75Ad,
            0xa05934ACb42768343035BCe74F72BFd6d2F61010
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.GRANARY][0xaf88d065e77c8cC2239327C5EDb3A432268e5831] = LenderTokens(
            0x2af47e1786C1aF2debeE2deDe590A0d00005129B,
            0x86547cB041c7a98576DA7fa87ACD6eaC66c51E0c,
            0x9E14E90C3912731531d8eE5B397526e3b2807452
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.GRANARY][0x5979D7b546E38E414F7E9822514be443A4800529] = LenderTokens(
            0x93e5E80029b36E5e5E75311cf50EBC60995F9EA6,
            0x5d13FfbC005a2bdd16F3c50e527D42C387759299,
            0x73B4cDF788aC8BF0B0104966Cdae4dc482FC3800
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.GRANARY][0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8] = LenderTokens(
            0x883b786504a2c6bfa2c9e578e5D1752ecbc24DEe,
            0x458D60c27B433A157462c7959e2a103389DE3fcE,
            0xE0B08f55697FeA5272604fC002B96b8379298f1A
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.GRANARY][0xd586E7F844cEa2F87f50152665BCbc2C279D8d70] = LenderTokens(
            0xe7334Ad0e325139329E747cF2Fc24538dD564987,
            0xe5415Fa763489C813694D7A79d133F0A7363310C,
            0xC40709470139657E6D80249c5cC998eFb44898C9
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.GRANARY][0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664] = LenderTokens(
            0x02CD18c03b5b3f250d2B29C87949CDAB4Ee11488,
            0xBcE07537DF8AD5519C1d65e902e10aA48AF83d88,
            0x73C177510cb7b5c6a7C770376Fc6EBD29eF9e1A7
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.GRANARY][0xc7198437980c041c805A1EDcbA50c1Ce5db95118] = LenderTokens(
            0x9c29a8eC901DBec4fFf165cD57D4f9E03D4838f7,
            0x06D38c309d1dC541a23b0025B35d163c25754288,
            0x6f66C5C5e2FF94929582EaBfc19051F19ed9EB70
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.GRANARY][0x50b7545627a5162F82A992c33b87aDc75187B218] = LenderTokens(
            0x272CfCceFbEFBe1518cd87002A8F9dfd8845A6c4,
            0x5eEA43129024eeE861481f32c2541b12DDD44c08,
            0x09AB5cA2d537b81520F78474d6ED43675451A7f8
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.GRANARY][0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB] = LenderTokens(
            0x58254000eE8127288387b04ce70292B56098D55C,
            0x05249f9Ba88F7d98fe21a8f3C460f4746689Aea5,
            0xc73AC4D26025622167a2BC67C93a855C1c6BDb24
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.GRANARY][0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7] = LenderTokens(
            0xe3f709397e87032E61f4248f53Ee5c9a9aBb6440,
            0x083E519E76fe7e68C15A6163279eAAf87E2addAE,
            0x383995FD2E86a2e067Ffb31674aa0d1B370B39bD
        );
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.GRANARY][0xd1c3f94DE7e5B45fa4eDBBA472491a9f4B166FC4] = LenderTokens(
            0xC17312076F48764d6b4D263eFdd5A30833E311DC,
            0x3F332f38926b809670b3cac52Df67706856a1555,
            0x5183adca8472B7c999c310e4D5aAab04ad12E252
        );
        lendingTokens[Chains.LINEA][Lenders.GRANARY][0x4AF15ec2A0BD43Db75dd04E62FAA3B8EF36b00d5] = LenderTokens(
            0x245B368d5a969179Df711774e7BdC5eC670e92EF,
            0xd4c3692B753302Ef0Ef1d50dd7928D60ef00B9ff,
            0x6F2783E0f6fDaCD7ce8E87b69CEfB5Fb6Be25791
        );
        lendingTokens[Chains.LINEA][Lenders.GRANARY][0x176211869cA2b568f2A7D4EE941E073a821EE1ff] = LenderTokens(
            0x5C4866349ff0Bf1e7C4b7f6d8bB2dBcbe76f8895,
            0x157903B7c6D759c9D3c65A675a15aA0723eea95B,
            0xAA36A2840a4a3666989C51751cE2D2F9dB658BA0
        );
        lendingTokens[Chains.LINEA][Lenders.GRANARY][0xA219439258ca9da29E9Cc4cE5596924745e12B93] = LenderTokens(
            0xa0f8323A84AdC89346eD3F7c5dcddf799916b51E,
            0x393a64Fc561D6c8f5D8D8c427005cAB66DfeCA9D,
            0x0B624a977087ED828560636bBe26FBD6df489696
        );
        lendingTokens[Chains.LINEA][Lenders.GRANARY][0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f] = LenderTokens(
            0xB36535765A7421B397Cfd9fEc03cF96aA99C8D08,
            0xd8A40a27dD36565cC2B17C8B937eE50B69209E22,
            0x9ff79431A180249B229341d8597BDC7f64a73c74
        );
        lendingTokens[Chains.LINEA][Lenders.GRANARY][0x3aAB2285ddcDdaD8edf438C1bAB47e1a9D05a9b4] = LenderTokens(
            0xdc66aC2336742E387b766B4c264c993ee6a3EF28,
            0x9576c6FDd82474177781330Fc47C38D89936E7c8,
            0x58DcB9517a9757710898000b31f54Db44E19d7e9
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.GRANARY] = 0xB702cE183b4E1Faa574834715E5D4a6378D0eEd3;
        lendingControllers[Chains.OP_MAINNET][Lenders.GRANARY] = 0x8FD4aF47E4E63d1D2D45582c3286b4BD9Bb95DfE;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GRANARY] = 0x7171054f8d148Fe1097948923C91A6596fC29032;
        lendingControllers[Chains.FANTOM_OPERA][Lenders.GRANARY] = 0x65FA36Fe0a7C0d346Dd02b7217Fdd6E6C5aaA269;
        lendingControllers[Chains.METIS_ANDROMEDA_MAINNET][Lenders.GRANARY] = 0x65dEc665ea1e96Ee5203DB321b5Cd413b81B2bd2;
        lendingControllers[Chains.BASE][Lenders.GRANARY] = 0xB702cE183b4E1Faa574834715E5D4a6378D0eEd3;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.GRANARY] = 0x102442A3BA1e441043154Bc0B8A2e2FB5E0F94A7;
        lendingControllers[Chains.AVALANCHE_C_CHAIN][Lenders.GRANARY] = 0xB702cE183b4E1Faa574834715E5D4a6378D0eEd3;
        lendingControllers[Chains.LINEA][Lenders.GRANARY] = 0x871AfF0013bE6218B61b28b274a6F53DB131795F;
        lendingTokens[Chains.SCROLL][Lenders.LORE][0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4] = LenderTokens(
            0x19624e5e4aD3F8de2ab516C67645Bb5B79EcfFE6,
            0x8eC1B2570809cb5C6b10a85d952D40B8cF0DeDDC,
            0xC852ee24d51EbD1cd9371ed2dADDB46feBc2b0FA
        );
        lendingTokens[Chains.SCROLL][Lenders.LORE][0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df] = LenderTokens(
            0xC5776416Ea3e88e04E95bCd3fF99b27902da7892,
            0x63591C6bDE1dEB1FcA7FCEA7b1AAeF96e8260f39,
            0x7Be4c4DEFB1c9Fe04a48150F0e5e416Ba3171F28
        );
        lendingTokens[Chains.SCROLL][Lenders.LORE][0x5300000000000000000000000000000000000004] = LenderTokens(
            0xF1792Ec678E2c90f44b8FcD137cc373280894927,
            0xb41aDc2a1189810989D45d92417cc558E8EEe66D,
            0xB6A1bf12b59D7009637AdD07d3e5002382Fe218D
        );
        lendingTokens[Chains.SCROLL][Lenders.LORE][0x80137510979822322193FC997d400D5A6C747bf7] = LenderTokens(
            0x4f908f7E51E5f03C937452F74c467Bf071858Aaf,
            0xF2A1fC52D4cFb59789faA7625C481984D44D6D21,
            0xA0ffE748e72507B89FDAB163241a9D76FE2B6456
        );
        lendingTokens[Chains.SCROLL][Lenders.LORE][0xf610A9dfB7C89644979b4A0f27063E9e7d7Cda32] = LenderTokens(
            0xa847eaa620c3ddd8E25909eaA0CC94659ABE8939,
            0xF38164575228DbC6EC4e38E460EDB4B8Ece86c33,
            0x5431D6a6CAbECBFA5f0bBf1b9529382D375eE919
        );
        lendingTokens[Chains.SCROLL][Lenders.LORE][0x01f0a31698C4d065659b9bdC21B3610292a1c506] = LenderTokens(
            0x80E0Fb6B416E1Ae9bBD02A9bC6A6D10C9E9D51B7,
            0x9d4725c7E14bFcaE7CfB03925cbc3c1C1dE6CDB0,
            0xdC80674646De58A89702301a14C5b0C435816D3e
        );
        lendingTokens[Chains.SCROLL][Lenders.LORE][0xa25b25548B4C98B0c7d3d27dcA5D5ca743d68b7F] = LenderTokens(
            0xc28A5a35e98bCaC257440A4759B0E7Da3b35Ed69,
            0xBD5e7Ae1dBF72FE0ea15207Fae21A4396246468c,
            0xa0ACB749F120Ab37bCBa371D2031B80C9f656421
        );
        lendingTokens[Chains.SCROLL][Lenders.LORE][0xd29687c813D741E2F938F4aC377128810E217b1b] = LenderTokens(
            0x34804222D65522ea542b711226008f7ef960784D,
            0xA738cc439c5220692B8a7D9D86F88A603e70B730,
            0x72c82Aed2eD2d4C8638F7990F5eF03DEdC2753D4
        );
        lendingControllers[Chains.SCROLL][Lenders.LORE] = 0x4cE1A1eC13DBd9084B1A741b036c061b2d58dABf;
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LENDOS][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x85b05b841438Cb63A11361EdE54982CD32D76fD7,
            0x2c06043c973e142D64441de596Fd8bB5b29BE1d8,
            0x01b552a06127B09AB738073cE0b9DAC6C42027a8
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LENDOS][0xad11a8BEb98bbf61dbb1aa0F6d6F2ECD87b35afA] = LenderTokens(
            0x417C0b97d9EF489BD828aD19cf79313E0D5f9294,
            0xE5716646f351A07437dEd137a189deb0Cb992F66,
            0xb24e9294e17D529140883C6305c0c5cF13e2A9F4
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LENDOS][0xbB0D083fb1be0A9f6157ec484b6C79E0A4e31C2e] = LenderTokens(
            0x45f80ae894FC102a2C1E40F7781dB621F554c075,
            0xE476506a7606E9c471e29cc2841e9fbF877139D3,
            0x2512cBB7E107abaf67B4710f8bD8Ea72003A1E75
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LENDOS][0xAA40c0c7644e0b2B224509571e10ad20d9C4ef28] = LenderTokens(
            0xE0073B0E72726C8e3A5921AF493f021f1AAD2AbA,
            0x016Cb26685D53E218727EF4d8052bBf96443592B,
            0xd12CBABF143621A4d24684b4209F56E31F0495C4
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LENDOS][0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3] = LenderTokens(
            0xd5C7F6aB4D9ccA88DcF5dCF7d330d5eBE6F79EEF,
            0x7433CE0fb3C01a9328332Db14D976AF6708f4219,
            0x21F08C0a227a9d5a06467B0d4bae9c879dcAF96b
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LENDOS][0x7A06C4AeF988e7925575C50261297a946aD204A8] = LenderTokens(
            0xc12A9D63e122d64247aB3D865e956b2b3EFF9639,
            0xFF0E853717Ab7C7c1fD7DD3db7c4296A95Fd8339,
            0xdE3f62f8ec0f027a59687ED771B9560903f5E37d
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LENDOS][0xaF6ED58980B5a0732423469Dd9f3f69D9Dc6DAB5] = LenderTokens(
            0x1f22aC506c90B410c726a5e7df278e3E85C3c6f3,
            0x9C0D3a1df756c6FF75A01192F5E20B69239a2B38,
            0x4a139CA502691d6EDF846eb5b6Cd2c37Cc216ad3
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LENDOS][0x0FFb62483517309AFd039B117D795521e8320a1b] = LenderTokens(
            0x046dbf4Aa7db014c41c9d69Ef3c3650dA806CA63,
            0xFF1f67992455617c1a1Bb38919B4B8513b6625B2,
            0x70FBE04cdFec844f350F9D0bAcE17F8ba8730126
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.LENDOS][0xf23eec60263dE9b0c8472c58BE10Feba28D9EB53] = LenderTokens(
            0x29fAf557315cbE130Dcb4EAddFdcF20BF130bE32,
            0x47250D28f0bdA904B7a7bcf3C80A4b4A9C3902fD,
            0x640aD49c294ab480A257154A78c80b41e6F53f36
        );
        lendingTokens[Chains.NEON_EVM_MAINNET][Lenders.LENDOS][0x202C35e517Fa803B537565c40F0a6965D7204609] = LenderTokens(
            0xE064D7CF9b0836EF27f0423F0e36f26Abe963e4e,
            0xf081cAF2c019E62D627f2B84BfB76900FE99d26F,
            0x3929156034B4Fd7e71BA07E4967e0D20D6d7f548
        );
        lendingTokens[Chains.NEON_EVM_MAINNET][Lenders.LENDOS][0x5f38248f339Bf4e84A2caf4e4c0552862dC9F82a] = LenderTokens(
            0x444CC2A0bEd1Bc91fF0096477cef52B3A5E08933,
            0xB6F5108e9794892330bC24AB6b0a603F1e85e551,
            0x23F49B9b68b5625c3FC435D4D9E5C1d4aC7018EA
        );
        lendingTokens[Chains.NEON_EVM_MAINNET][Lenders.LENDOS][0xEA6B04272f9f62F997F666F07D3a974134f7FFb9] = LenderTokens(
            0x8b35eAb3B8439aD09c52775954a6340AC5E24Dd3,
            0x9D1F74573d608493913733c64B29A01441F477e9,
            0x34E3917745572C2A574aBAd068CaEe7C2687941C
        );
        lendingTokens[Chains.NEON_EVM_MAINNET][Lenders.LENDOS][0xcFFd84d468220c11be64dc9dF64eaFE02AF60e8A] = LenderTokens(
            0x6c036cAadB5f88A50576992427179d643C9b453F,
            0x3fd6FacEa7B502D22fb610ABc306cAe5d7d64414,
            0x6057f03769155ECc5a64462056d59AEAdc6Ca9B3
        );
        lendingTokens[Chains.NEON_EVM_MAINNET][Lenders.LENDOS][0xFA8fB7e3bd299B2A9693B1BFDCf5DD13Ab57007E] = LenderTokens(
            0x55C37a9c9864E526cbf9C2EEb7161Ec0BF5FfA29,
            0x41C30d1ab57cdA334290E027B2d327f9Df2Ca2b5,
            0xce53FDC75e4208DB4ae370a890c7A098c9AB286a
        );
        lendingTokens[Chains.NEON_EVM_MAINNET][Lenders.LENDOS][0x5f0155d08eF4aaE2B500AefB64A3419dA8bB611a] = LenderTokens(
            0xb9B369aE5E285fD97F026a442d40D6f747bC9881,
            0xAba718DBBc8a497D04fbb462A1200B3BA07BF79B,
            0xd9d8c338A737A295d74Ea5a07271803d47DDF5A0
        );
        lendingControllers[Chains.HEMI_NETWORK][Lenders.LENDOS] = 0xaA397b29510a7219A0f3f7cE3eb53A09bc2A924c;
        lendingControllers[Chains.NEON_EVM_MAINNET][Lenders.LENDOS] = 0x3B2F6889bFac2B984754969116cD1D04447D012d;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.YLDR][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = LenderTokens(
            0xDdbE14A7cD032E58368cf9Db59b89D0Ba8663703,
            0x8ceE2c02Df3FF9DD9caB1762d86c04Dd6E7f9b22,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.YLDR][0xdAC17F958D2ee523a2206206994597C13D831ec7] = LenderTokens(
            0x6A03202ca61F6a756C97f23eDdFBf93D69d7baA1,
            0xBdB5610184C4F9855d04cE59EaaeF7386ff3827B,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.YLDR][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] = LenderTokens(
            0xb2DE9Be4B2Ac812B69974521Fb6a0F983aaDE16E,
            0x641f307e2527394E09B999FdC7726E93FaA725a0,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.YLDR][0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0] = LenderTokens(
            0x2BE2140B3692b150ABA5969dad174C7aF35714F4,
            0x9dA06f30b08126Eab91De119d9CA9E345A2d2eAe,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.YLDR][0xBe9895146f7AF43049ca1c1AE358B0541Ea49704] = LenderTokens(
            0xeC2E11a95fB96783CcBbaE27A04219738dCDe36b,
            0xfc992B5Ab3F938655fCb578dE8365F22EB79DE0A,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.YLDR][0xae78736Cd615f374D3085123A210448E74Fc6393] = LenderTokens(
            0xBab39Ac382396C6763dB5047f0B41175FEaE65ef,
            0x8AD492788CBC8F4B43768d7d8e1110367FA4A8Ce,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.YLDR][0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174] = LenderTokens(
            0xAFcc7719EdfCba9215749c8e399f4E20c9024Cf7,
            0x42037D996611eD4378A508F67470fBcED1436555,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.YLDR][0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359] = LenderTokens(
            0xd8aB1E396Cfc5d9D7922e2Ca0B9084aB64DD6Cee,
            0x477768d8230F2B914554491414d5e76C73314eD2,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.YLDR][0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619] = LenderTokens(
            0xD85552A6e8DF8dCe06B157d33B383CE9F5f9aDe2,
            0x2Cd174A79F40E67D390C12Ced441b17De70f9765,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.YLDR][0xc2132D05D31c914a87C6611C10748AEb04B58e8F] = LenderTokens(
            0xf309Ada8651891a99B251cAb253aD10895b3D028,
            0x9113F0D78bC64712e9560f58DC0749e6ac227fff,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.YLDR][0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270] = LenderTokens(
            0xf6535aa0cD4988855247cbEFa7fbe64E3E78e024,
            0x23219a2d278E99B0F170ad963d34373069159Ab1,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.YLDR][0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6] = LenderTokens(
            0x62B1bf965cc3051c73e0DB6b2025cBC371b6ea9c,
            0x87B98Ef3AE0488fe509a129025988956a8962EDA,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.YLDR][0x7b99506C8E89D5ba835e00E2bC48e118264d44ff] = LenderTokens(
            0x6e0bA5168eE1faDf18F483A96a10cE1e9bECCdc9,
            0x3Aa17FB2Ab6caAB7d294D71793a6261BA307c483,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.YLDR][0x3974FbDC22741A1632E024192111107b202F214f] = LenderTokens(
            0xa9876aAd44377291ec40cA8e61a98A4487F21e59,
            0xAe253124d0030125bC8F194e68954f9aE64A593E,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.YLDR][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = LenderTokens(
            0x8Fef557ECb4c1CaF2F35d73Ec4DCf989f02C85D2,
            0xa897CD83Fa02b4E83f2842194bB09c271Fa3225b,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.YLDR][0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA] = LenderTokens(
            0x4f96677d62C7e646538379e45FA2243b354a69A4,
            0x4a042a3F69620C152e23638acB981e99cBc8E988,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.YLDR][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x91d74D72df2D5Af2C04Fb00a5092E75e33ed6A8b,
            0x38B772a6F7AceCf6133B9DbE640d94517dbd4c9B,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.BASE][Lenders.YLDR][0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452] = LenderTokens(
            0xE2A3f0b559fB3f23426705a8c4E3fB56f61f9571,
            0xd42d82fc67fc9258816D1d2C33f943874251A412,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.YLDR][0xaf88d065e77c8cC2239327C5EDb3A432268e5831] = LenderTokens(
            0xAA40dcA2d69DED3Eb17991AA17D83653F1084091,
            0x7Bcc957F8f86Aa78762FCCC0bFeC6DbF8b1Ad987,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.YLDR][0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] = LenderTokens(
            0x6d7197fa1f2b9D01a25705b5558a748A2b5f0605,
            0xa350429bC896A95f1EF6936e4C4C5a2C62052ED1,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.YLDR][0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8] = LenderTokens(
            0x8F46fB23d1D7e1385809bC304f979651fD374DEb,
            0x57c2e352E867238A96C300ff6434f7C8D63b3C14,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.YLDR][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] = LenderTokens(
            0x172c9dCe43198154dc0DAcc843fd8103aD09145C,
            0xCdA3934B7dDA7Fc07ff09e669137c49782812f82,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.YLDR][0x5979D7b546E38E414F7E9822514be443A4800529] = LenderTokens(
            0x4107B60471eEf310fCe240e4dfad14b7e326a6E0,
            0x16359d6CF2ec7f9020707653D4758Ad8969752F0,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.YLDR][0x912CE59144191C1204E64559FE8253a0e49E6548] = LenderTokens(
            0x609772EEeDa6Dd1537177737823fFB3b3Bc9b6e4,
            0xDA27Be910cA3E205927Cc43088B5681D19DE05FA,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.YLDR][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] = LenderTokens(
            0xCB14E172f16Db1e8E3CBCA41a56281022633414d,
            0xD5C41944A760C23Caa11815c47e43b66719A213D,
            0x0000000000000000000000000000000000000000
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.YLDR][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] = LenderTokens(
            0x43274582edbc3d17ccB8c752da8aA9D471B5A093,
            0x23a12B967AC30E04e844af3017F5c80B115b476d,
            0x0000000000000000000000000000000000000000
        );
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.YLDR] = 0x6447c4390457CaD03Ec1BaA4254CEe1A3D9e1Bbd;
        lendingControllers[Chains.POLYGON_MAINNET][Lenders.YLDR] = 0x8183D4e0561cBdc6acC0Bdb963c352606A2Fa76F;
        lendingControllers[Chains.BASE][Lenders.YLDR] = 0x5425afD90Bd1AAD68d5bADCB80390101a2750bc5;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.YLDR] = 0x54aD657851b6Ae95bA3380704996CAAd4b7751A3;
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0xd988097fb8612cc24eeC14542bC03424c656005f] = LenderTokens(
            0xe7334Ad0e325139329E747cF2Fc24538dD564987,
            0xe5415Fa763489C813694D7A79d133F0A7363310C,
            0xC40709470139657E6D80249c5cC998eFb44898C9
        );
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0xf0F161fDA2712DB8b566946122a5af183995e2eD] = LenderTokens(
            0x02CD18c03b5b3f250d2B29C87949CDAB4Ee11488,
            0xBcE07537DF8AD5519C1d65e902e10aA48AF83d88,
            0x73C177510cb7b5c6a7C770376Fc6EBD29eF9e1A7
        );
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x9c29a8eC901DBec4fFf165cD57D4f9E03D4838f7,
            0x06D38c309d1dC541a23b0025B35d163c25754288,
            0x6f66C5C5e2FF94929582EaBfc19051F19ed9EB70
        );
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0x272CfCceFbEFBe1518cd87002A8F9dfd8845A6c4,
            0x5eEA43129024eeE861481f32c2541b12DDD44c08,
            0x09AB5cA2d537b81520F78474d6ED43675451A7f8
        );
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0x028227c4dd1e5419d11Bb6fa6e661920c519D4F5] = LenderTokens(
            0x58254000eE8127288387b04ce70292B56098D55C,
            0x05249f9Ba88F7d98fe21a8f3C460f4746689Aea5,
            0xc73AC4D26025622167a2BC67C93a855C1c6BDb24
        );
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0xe7903B1F75C534Dd8159b313d92cDCfbC62cB3Cd] = LenderTokens(
            0xe3f709397e87032E61f4248f53Ee5c9a9aBb6440,
            0x083E519E76fe7e68C15A6163279eAAf87E2addAE,
            0x383995FD2E86a2e067Ffb31674aa0d1B370B39bD
        );
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0x59889b7021243dB5B1e065385F918316cD90D46c] = LenderTokens(
            0xC17312076F48764d6b4D263eFdd5A30833E311DC,
            0x3F332f38926b809670b3cac52Df67706856a1555,
            0x5183adca8472B7c999c310e4D5aAab04ad12E252
        );
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A] = LenderTokens(
            0x4522DBc3b2cA81809Fa38FEE8C1fb11c78826268,
            0xF8D68E1d22FfC4f09aAA809B21C46560174afE9c,
            0xE6AD2c410c60ceD626Bc998bfcfEA934278538C5
        );
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0xDfc7C877a950e49D2610114102175A06C2e3167a] = LenderTokens(
            0x0F4f2805a6d15dC534d43635314444181A0e82CD,
            0xe57Bf381Fc0a7C5e6c2A3A38Cc09de37b29CC4C3,
            0x2E714eB72cD8f709993B9fAF4347E1072ab17c8A
        );
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0x0Eb9C75689d7dB53727723E42263B44d7A31618c,
            0xE6075A86F4517B1B8136498fe23640C73aa1b711,
            0x6b24CeD4a6628C207CD1eEAe4EF9a1eDC6eE864E
        );
        lendingTokens[Chains.MODE][Lenders.IRONCLAD][0x6B2a01A5f79dEb4c2f3c0eDa7b01DF456FbD726a] = LenderTokens(
            0x0F041cf2ae959f39215EFfB50d681Df55D4d90B1,
            0x80215c38DCb6ae91520F8251A077c124e7259688,
            0x8A468142b1199aB49AC6Dc915a1B9fBDE3D1b70e
        );
        lendingControllers[Chains.MODE][Lenders.IRONCLAD] = 0xB702cE183b4E1Faa574834715E5D4a6378D0eEd3;
        lendingTokens[Chains.MODE][Lenders.MOLEND][0xd988097fb8612cc24eeC14542bC03424c656005f] = LenderTokens(
            0xa509cbE0aCb9EB39c01Ef6A23073927a1F339Ba2,
            0xb84ec47ce839CA1CE21EA343B6f487983225f52C,
            0x1D5A5D03105F87493BcED94ff3A6853081c0c290
        );
        lendingTokens[Chains.MODE][Lenders.MOLEND][0xf0F161fDA2712DB8b566946122a5af183995e2eD] = LenderTokens(
            0x554Da9A2052f9a63d1f562FA49Aa150FdaB32120,
            0xb1bb70096E315213af4f992D8580271E71cEe620,
            0xD70345fA7A81f65f4e2BeA80a39AE63Ddc4caFd7
        );
        lendingTokens[Chains.MODE][Lenders.MOLEND][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x4080Ec9B7159FE74e5E4f25304a8aa8293815f16,
            0x014ff401E25ebDF12Faa6725F69b18535CceC51e,
            0x23ab9D4f992688468D026E7C5a6e88c1CaCf3b7f
        );
        lendingTokens[Chains.MODE][Lenders.MOLEND][0x80137510979822322193FC997d400D5A6C747bf7] = LenderTokens(
            0xacFf2A153Ba2110DbB04033984b1c2922e1b18Fd,
            0x9592d7287fC33B8592F089aD291e05976b4fba0C,
            0x16f5C14751F39DE4b9b367908074a721b107DbB4
        );
        lendingTokens[Chains.MODE][Lenders.MOLEND][0x2416092f143378750bb29b79eD961ab195CcEea5] = LenderTokens(
            0xB64085eBf44048515Be0A3C85413d28920BF3E55,
            0xCBa6a705B8FDd9A35D08F99DE10c99E9fA99517b,
            0x073c94559Ff3cb672a03035217ee75f3c2109742
        );
        lendingTokens[Chains.MODE][Lenders.MOLEND][0x59889b7021243dB5B1e065385F918316cD90D46c] = LenderTokens(
            0x8973514e70062E348aDd6F7A85A335210519Fd34,
            0x33136412e7612407d6CECE1d7a6DB5CfD0f217e2,
            0xDdb68Ec5499865CB744E8fD0a0Aa439b18b5C7BC
        );
        lendingTokens[Chains.MODE][Lenders.MOLEND][0xDfc7C877a950e49D2610114102175A06C2e3167a] = LenderTokens(
            0x7F75Dd85D8A9121F19071E36d01b5f919F03582F,
            0xEaA47ab1D0DCA209795804f95105227C9AcE6223,
            0x527c247d12B5C109E5479250696EFdd4B4Bc4d56
        );
        lendingControllers[Chains.MODE][Lenders.MOLEND] = 0x04c3F4C9B12b1041b2fD2e481452E7c861Fe1FF8;
        lendingTokens[Chains.BLAST][Lenders.SEISMIC][0x4300000000000000000000000000000000000003] = LenderTokens(
            0xd7484A50390a28F20e0B6c704A5B2ceB7a872D19,
            0x87BAc0208a2e354F0f0412A49FAba6b64632C988,
            0xf2D657952B244C97Da26D724bdA4373b0c1e742B
        );
        lendingTokens[Chains.BLAST][Lenders.SEISMIC][0x4300000000000000000000000000000000000004] = LenderTokens(
            0xE355Ef5252493971ab5a75e4d214dc324FBfAf5B,
            0x2D0D369C56bc0472330fF3BdDA781f14B5548377,
            0x92C355289D34557EB79A0EC7e449f539290000Ee
        );
        lendingTokens[Chains.BLAST][Lenders.SEISMIC][0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A] = LenderTokens(
            0x46A573f9B5b6a3495488Bc455dEecd3421fa2de3,
            0xE650d6862697Cf69EdA87C025c58E54840407469,
            0x44626D114873553EE56832ac8950c5cdA78decA8
        );
        lendingTokens[Chains.BLAST][Lenders.SEISMIC][0xb1a5700fA2358173Fe465e6eA4Ff52E36e88E2ad] = LenderTokens(
            0x0bEaDC7fA57Bc8477c2B4a629c4E7f40A78BFD9B,
            0x19Ff6e9bAD46D4fe735A45b61Edf1A0C5d83533E,
            0x3588D82d4dE95ce85cA112342D15dd81331D9cE9
        );
        lendingTokens[Chains.BLAST][Lenders.SEISMIC][0xe7903B1F75C534Dd8159b313d92cDCfbC62cB3Cd] = LenderTokens(
            0x9Ca33f4a9F85E6BFc3F9CCD46b09Ed37E1046C7C,
            0x3e9135c7014ff740271F8c89a549eeD4Ba62bCAa,
            0x9AeeA06995e97A47e05a0f24DE06c59372b0b9F3
        );
        lendingTokens[Chains.BLAST][Lenders.SEISMIC][0x1a49351bdB4BE48C0009b661765D01ed58E8C2d8] = LenderTokens(
            0x2cFEB8f6Cb68C35D13257418Eb7657575969341F,
            0x84dFC8C090355B4Dd507A5402681f2115299018C,
            0x3Afa4A8176CB594A6592853401CcA9666f8De04c
        );
        lendingControllers[Chains.BLAST][Lenders.SEISMIC] = 0x83d55e27b8033b6D5874CBb3c9252c4Bfdb2bC75;
        lendingTokens[Chains.SONIC_MAINNET][Lenders.POLTER][0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38] = LenderTokens(
            0x81faE0eF10f391450F9b59E21c8115485B9F73CF,
            0x1c5cb5C66E1E78577457893fb4df2A83F02647C2,
            0x557035151bb7066873a5c2b2615Fc0b01b0dA441
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.POLTER][0x50c42dEAcD8Fc9773493ED674b675bE577f2634b] = LenderTokens(
            0x07FE600220712d758F785F40474EcBEB81943Cd6,
            0xf1c6b54f5e550451Be6EC72b097453Fa5108c966,
            0xD96d3209dF12640c870D4CD83BE543Fdf6C94263
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.POLTER][0x29219dd400f2Bf60E5a23d13Be72B486D4038894] = LenderTokens(
            0x3e43aa6281C8341B06F502c4f204D3242f67599F,
            0xE8A00008369866c2aCE7b481C6E7CA34714D3248,
            0x15971487C0B7355B165dD155565103713e98135A
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.POLTER][0x6047828dc181963ba44974801FF68e538dA5eaF9] = LenderTokens(
            0x4227C901cA6Af2afB772dB7E93BB9Ab25dD8AdC5,
            0x1d93B8CF0361886ef50F49695b076c415ccfa5F1,
            0x73B8A8e2cB22052Bcf3122398d791f5156257f99
        );
        lendingTokens[Chains.BASE][Lenders.POLTER][0x4200000000000000000000000000000000000006] = LenderTokens(
            0xCA4e076c6D8a84a990986a3c405093087991A8fe,
            0xad5ba690D8996fF73b4d4d7242122618034D0667,
            0xC5EC7903Cb7d79ae8195FE544999BE5eeafd0A55
        );
        lendingTokens[Chains.BASE][Lenders.POLTER][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = LenderTokens(
            0x1DdaeeBBD69DCCC92F5cf76593104976B9C62434,
            0xeF18f2eEcD07143114D97D428bf5a7406e57C472,
            0xA6941f33420B77d12526Fc07a35E46468d59F64f
        );
        lendingTokens[Chains.BASE][Lenders.POLTER][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0x2a96E27E204EF366671232Df28F147Fa30E735ce,
            0x7C89dBD6Ac932142813edE9907eB345542C41A1a,
            0x9973aab27022aeF2dE1Aa6ce8200Bb15A82c039B
        );
        lendingTokens[Chains.BASE][Lenders.POLTER][0x940181a94A35A4569E4529A3CDfB74e38FD98631] = LenderTokens(
            0x6F78d5D203EE7F4f3821Ea7aE507E3e20b0930EF,
            0xF14cD6EC231944f6e2111CA9F96F38AC7888F025,
            0x475d0048A366D46f3bAa17175451e0A811C46609
        );
        lendingControllers[Chains.SONIC_MAINNET][Lenders.POLTER] = 0x4dE3E7E8bE48D6094cFA34323e6cC22308D56b52;
        lendingControllers[Chains.BASE][Lenders.POLTER] = 0x33CA62504cebAB919f0FCa94562413ee121A9798;
        lendingTokens[Chains.SONIC_MAINNET][Lenders.MAGSIN][0x29219dd400f2Bf60E5a23d13Be72B486D4038894] = LenderTokens(
            0xeF39dD51DB95c5a05d6D29c4694Fdd8F0eF260a1,
            0x367Aa8850A5662C5Ef707DCD2910D2306f9e66d1,
            0x9045844b77a83fFc73123fCf4904500478319c8d
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.MAGSIN][0x50c42dEAcD8Fc9773493ED674b675bE577f2634b] = LenderTokens(
            0x3D4b22c91e535b0Edcbba1B98e0c93844b7E379e,
            0xa4CAAc829762C9d59e03fF9C6585214DD9F7233b,
            0x3E25FcA694059a1f4f34a3F4e1D5FD7FFD854365
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.MAGSIN][0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38] = LenderTokens(
            0x27C6ABDd0B26ecB106AC4bD6a367a5983817527A,
            0x3ad4b747F61d8e1E603aEa0700596973AeB7E71e,
            0x0221fE85F46dfeAC7Ba559E35385d80ED1b157d6
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.MAGSIN][0xE5DA20F15420aD15DE0fa650600aFc998bbE3955] = LenderTokens(
            0xDC9B24006bdb858C2542df929DD45e6701A09Cd4,
            0x2364868684858817cc06a1cD3169331b217C16e8,
            0xaa9a1434FFD92db5C42CA4697A67deB729d24d7A
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.MAGSIN][0x0525Cb0064EfFf807fD0cd231544b9208fC215a9] = LenderTokens(
            0x08d786D81BbcED378780fFd0fb689FA8d4844238,
            0xEB1C31FD7e9016e6779fD49edA3529C60294A868,
            0x251F022a700F35C295DDB6c860cd3B34f47cB80A
        );
        lendingTokens[Chains.SONIC_MAINNET][Lenders.MAGSIN][0x5Ba1D96907b075C490F641bD30551e1af9C40721] = LenderTokens(
            0xAc985a2e3aE8128f79a89C5580D126f1E231F376,
            0x25b5924b03Bd27362b17B13Ed33CD014E9710e28,
            0x57D44438Ab63538cfEf7b6d7Fe9C8Ecec89Ebe30
        );
        lendingControllers[Chains.SONIC_MAINNET][Lenders.MAGSIN] = 0x73B635843352aF89278bDe2213866C457C94b271;
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83] = LenderTokens(
            0x291B5957c9CBe9Ca6f0b98281594b4eB495F4ec1,
            0xa728C8f1CF7fC4d8c6d5195945C3760c87532724,
            0x05c43e14d38bC5123F6408A57BE03714aB689F6e
        );
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d] = LenderTokens(
            0xd4e420bBf00b0F409188b338c5D87Df761d6C894,
            0xec72De30C3084023F7908002A2252a606CCe0B2c,
            0xF4401355B41c867edbF09C821FA7B4fffbed5C82
        );
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0xE2e73A1c69ecF83F464EFCE6A5be353a37cA09b2] = LenderTokens(
            0xa286Ce70FB3a6269676c8d99BD9860DE212252Ef,
            0x5b0568531322759EAB69269a86448b39B47e2AE8,
            0x4f9401Fb52fe53de977dcbF05A0F6237AaDC7Eb1
        );
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb] = LenderTokens(
            0xA26783eAd6C1f4744685c14079950622674ae8A8,
            0x99272C6E2Baa601cEA8212b8fBAA7920A9f916F0,
            0x0DfD401903bA960B2EED32A10f8aeB601Cd9A7A5
        );
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252] = LenderTokens(
            0x4863cfaF3392F20531aa72CE19E5783f489817d6,
            0x110C5A1494F0AB6C851abB72AA2efa3dA738aB72,
            0xca0f3B157165FE11692a047ea14963ffAdfB31fD
        );
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1] = LenderTokens(
            0x44932e3b1E662AdDE2F7bac6D5081C5adab908c6,
            0x73Ada33D706085d6B93350B5e6aED6178905Fb8A,
            0x43Ae4A9474eA23b0BC04C99F9fF2A9B4c2d5554c
        );
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0x21a42669643f45Bc0e086b8Fc2ed70c23D67509d] = LenderTokens(
            0xA916A4891D80494c6cB0B49b11FD68238AAaF617,
            0x7388cbdeb284902E1e07be616F92Adb3660Ed3a4,
            0x6Ca958336e7A1BDCDf7762aeb81613EaDdCc3110
        );
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0x4ECaBa5870353805a9F068101A40E0f32ed605C6] = LenderTokens(
            0x5b4Ef67c63d091083EC4d30CFc4ac685ef051046,
            0x474f83d77150bDDC6a6F34eEe4F5574EAfD05938,
            0xB067faD853d099EDd9c86483682e7D947B7983E5
        );
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0xcB444e90D8198415266c6a2724b7900fb12FC56E] = LenderTokens(
            0xEB20B07a9abE765252E6b45e8292b12CB553CcA6,
            0xA4a45B550897dD5d8a44c68DBD245C5934EbAcd9,
            0x78A69aFc50E7705Ad4588cB57cF8D27B29161e51
        );
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0x6C76971f98945AE98dD7d4DFcA8711ebea946eA6] = LenderTokens(
            0x606B2689ba4A9F798f449fa6495186021486dD9f,
            0xd0b168FD6a4e220f1a8FA99De97F8f428587e178,
            0xeC7f91f26E7fD42E90fFa53ca0B0b02095A6B450
        );
        lendingTokens[Chains.GNOSIS][Lenders.AGAVE][0xaf204776c7245bF4147c2612BF6e5972Ee483701] = LenderTokens(
            0xe1cF0d5A56c993c3C2a0442dd645386aEFF1fC9a,
            0xAd15FeC0026e28DFB10588FA35a383B07014e0c6,
            0x6927a7cDA946910126008Af78EbA50DB6415284f
        );
        lendingControllers[Chains.GNOSIS][Lenders.AGAVE] = 0x5E15d5E33d318dCEd84Bfe3F4EACe07909bE6d9c;
        lendingTokens[Chains.CELO_MAINNET][Lenders.MOOLA][0x471EcE3750Da237f93B8E339c536989b8978a438] = LenderTokens(
            0x7D00cd74FF385c955EA3d79e47BF06bD7386387D,
            0xAF451D23d6f0FA680113CE2D27a891Aa3587f0C3,
            0x02661dd90c6243Fe5cdF88De3E8cb74BcC3bD25E
        );
        lendingTokens[Chains.CELO_MAINNET][Lenders.MOOLA][0x765DE816845861e75A25fCA122bb6898B8B1282a] = LenderTokens(
            0x918146359264C492BD6934071c6Bd31C854EDBc3,
            0xf602D9617564C07f1e128687798D8C699cED3961,
            0xa9F50D9F7c03E8B48b2415218008822Ea3334adb
        );
        lendingTokens[Chains.CELO_MAINNET][Lenders.MOOLA][0xD8763CBa276a3738E6DE85b4b3bF5FDed6D6cA73] = LenderTokens(
            0xE273Ad7ee11dCfAA87383aD5977EE1504aC07568,
            0xfb6c830c13D8322b31b282Ef1Fe85cbb669d9aE8,
            0x612599D8421F36b7dA4dDBA201a3854FF55e3d03
        );
        lendingTokens[Chains.CELO_MAINNET][Lenders.MOOLA][0xe8537a3d056DA446677B9E9d6c5dB704EaAb4787] = LenderTokens(
            0x9802d866fdE4563d088a6619F7CeF82C0B991A55,
            0xbd408042909351B649DC50353532dEeF6De9fAA9,
            0x0D00d9A02b85E9274f60A082609f44f7C57F373d
        );
        lendingTokens[Chains.CELO_MAINNET][Lenders.MOOLA][0x17700282592D6917F6A73D0bF8AcCf4D578c131e] = LenderTokens(
            0x3A5024E3AAB31A1d3184127B52b0e4B4E9ADcC34,
            0x3d6d8A1562ff973aD89887C0a5c001f42Ad66CB8,
            0x0bb14E95a4FF117F7f536D605E2B506e937619C4
        );
        lendingControllers[Chains.CELO_MAINNET][Lenders.MOOLA] = 0x970b12522CA9b4054807a2c5B736149a5BE6f670;
        lendingTokens[Chains.OP_MAINNET][Lenders.XLEND][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] = LenderTokens(
            0x80F7084272D861f5c5F5f60648c085B1F7a2FE41,
            0x01b7435E33844fbBaF948a8C88FBfB8C67A4e663,
            0xb29e1Dab375A2247C2972707884149a78F956f43
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.XLEND][0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85] = LenderTokens(
            0xbA2111F1498627E66f930cC539b7fbBdd5044F6D,
            0x60C85491232E553B5D8121d41ecd41CEFdB034B9,
            0x445E23254D207a9eb9E4D8B1c67e6418Fc95b745
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.XLEND][0x4200000000000000000000000000000000000006] = LenderTokens(
            0xf58BEc4C57F8A459dB9840236613082aE17eb23F,
            0x3663d302ce1294d182BAfeC89b4B28345fa99db3,
            0x767b87aC92612Ec7F26dfDab82C4c99E92efEa53
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.XLEND][0x94b008aA00579c1307B0EF2c499aD98a8ce58e58] = LenderTokens(
            0xea299346c31a13f85CCf70Ca337d83e93EA6BdF3,
            0x49C7B5dd887e4fF60416b420e110a6f09F5A9702,
            0xAa790Dc3d7a83d53b5673e63F0550285f587C5fA
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.XLEND][0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb] = LenderTokens(
            0xe40EC46C8554eDAf61829AC68c0AE8183B0b23B5,
            0xC71dC31bF7989E78f9E6Cc167Ede9141b83535D7,
            0x860d4AC5DbD3e4bD1201F008821D8A5d01967Ed3
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.XLEND][0x4200000000000000000000000000000000000042] = LenderTokens(
            0xb4F8a17E9917a7dd45C3726041bCD3848C5c2e94,
            0x7C47c84C57a9237ed8164E30db7e7b7F4bba5d59,
            0x9197F86e017a631204643Ba22057EE241151248E
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.XLEND][0x68f180fcCe6836688e9084f035309E29Bf0A2095] = LenderTokens(
            0x920f4A7510f138b1FcD90a8a7DdedB7b4Cb0a04F,
            0x2f48c271a55c3CBD3514c51D343E72d681284326,
            0x7E20eB4C24C2cbD200a01141cc59d6A998A35617
        );
        lendingTokens[Chains.OP_MAINNET][Lenders.XLEND][0x9Bcef72be871e61ED4fBbc7630889beE758eb81D] = LenderTokens(
            0x15e24124E93892EdCDbb835Fe82C00Ff2eb0e766,
            0x856A83D43243871924B9214201CB1e2BC250Bf9C,
            0x051fd6Cc4aE259bB8bc8555d218D52D6A5A094A4
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = LenderTokens(
            0xf17182f6f28Ded63B77A2Bb774c58aDe44612bE4,
            0x26CeD5493511cAB401C64a58a5F29D55Dbe494c5,
            0xEd72525251946b960494a07217B36091Fe242F7C
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x9Ef15597B0B900bfceE4A77204F72bd20C85d7c8,
            0xe99Ec9b8EA5322D8B5BDC66dad3D2294dC61b740,
            0x14124Fc9f01978bc64a82ABF72D22430F6b1ee16
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452] = LenderTokens(
            0x749Fc8D298A41A55AB305164602a185dB29f8F2B,
            0x28bBF6ca0762e9Ba99d0745F079f71BfD8A7D0D6,
            0xE58e662C2CFcaD5947c913BC35Faf75b2D14d064
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22] = LenderTokens(
            0x2308Fc7785597cC40aB53f302b491294b8d8d8bE,
            0x3d54e017E1902c055a1FDCee85B0117A52dFcFf1,
            0x6aDDA94f5576b8490BA58F0046021162353426cd
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0xdf2730830c77780A11248945C342c002DB73A8Be,
            0x2AF3a2518d0a33907b0647E0654b75939dCA4D8A,
            0xF01E3b5653fcCb1ECf1344BC739C39b0fee5D043
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A] = LenderTokens(
            0x951092b1eD953D0879E3840489bE6Fbfc4Ad363D,
            0xa47f8E51DF05131A9330795c2f67f555710b1b97,
            0x96d1B6cf9C825eDb3abC852a26176E94B8530bF0
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0xB6fe221Fe9EeF5aBa221c348bA20A1Bf5e73624c] = LenderTokens(
            0x2Bc746DCa46776B34a065A5b2F675104368a491E,
            0x36D7ad88CD411300CfA0fBB2114f8ef803E26e3c,
            0x0f51Ae264c08f67F031372BBB700587db077FfA7
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x940181a94A35A4569E4529A3CDfB74e38FD98631] = LenderTokens(
            0x227545F1d9cDf944f0badFCf91c5EfE90E7c068f,
            0xC3aB85875aF5Ba1eb38F33FeAEE3758521CdBcF8,
            0x09FB5be9E15161be6Ad72353854cE79d0aB5C56f
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42] = LenderTokens(
            0x43488361941170d3470A0bE38df85A1f5C5D7229,
            0x3F2dDb6C5E99Afcf00bAcb4544Caa12c87cBF356,
            0xE5e37f4E199425c73e4f37781c5aaf648DC6D687
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0xecAc9C5F704e954931349Da37F60E39f515c11c1] = LenderTokens(
            0x2e326563baC9A17B3e12dB45d2A2a86f9f734F6f,
            0x628194170111B7DEA9B4F8DA882CD9797d6a865f,
            0x12E0563befC020088c1F695C37127DD981D2FAEB
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x820C137fa70C8691f0e44Dc420a5e53c168921Dc] = LenderTokens(
            0x08809a8073b2F3BaA24faaF1Bf52B812C4bb4920,
            0x739A059864d13B5b6c056907346db15837256E5F,
            0x02Cb15B49EeC8a7a0dCd06A059b72A8d7eF11545
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0xEDfa23602D0EC14714057867A78d01e94176BEA0] = LenderTokens(
            0xa6d1c5419Ac814240A75935d094131A37B8616D2,
            0x8bAfC99f2Bf1DbD85b447D8D291E4C63aE9dEFE8,
            0x89C71EdE3033Ea0B6914F8F2C7d3B245e9f59904
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x5875eEE11Cf8398102FdAd704C9E96607675467a] = LenderTokens(
            0x1647D5950dee7332f748b5D02ff4aBE7ddcAff6b,
            0x1a8cB4f5B3cdA4DFB070708F9AA26B729d1AC839,
            0x2EaaA3D1Cb6b744c701534858f2cCa5baa004567
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x35E5dB674D8e93a03d814FA0ADa70731efe8a4b9] = LenderTokens(
            0x30beadAff3780Ea468bfAe86703801dC20de3aeB,
            0x279a58f518b90D610428637C6455E0f57af8EceD,
            0xB24848A13461e9c588027998d7BCB404d16234BE
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x236aa50979D5f3De3Bd1Eeb40E81137F22ab794b] = LenderTokens(
            0x45D1255D1d35eDd2AE964503b69b2f65c7ebd25C,
            0xf51BdABa60b61dAB625f1bf756C3FB804e3eB91D,
            0xb24ebabe7595619D82468D209678D00F49F96D35
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0xa6F0A4D18B6f6DdD408936e81b7b3A8BEFA18e77] = LenderTokens(
            0x51269F9Bd237a2d84EE89a4a458Ff42f2b68A812,
            0x0f34D091375772d1dD624F9242fE24C6a51d1501,
            0x95D202A5c90383879B0403028DE2c98A5BDd412D
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b] = LenderTokens(
            0x49b33982d24E51B6aE23b87D9CcB57102F8Dc704,
            0x071F2b2d3208587EF0eb01ABB3F0A790fAb6893A,
            0x3F51b02746436979B3AD96ffD77FAEb9501d692c
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7] = LenderTokens(
            0xf24E8514803C2a7265b90094Ce1291686Ace8f26,
            0xC4094b1b5d7F27b1bFD2E7d3e1657E7568B7cCcf,
            0xd127b6665e1Cd2f1Ed73ab3E0c86a727e6F31e30
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x0000000f2eB9f69274678c76222B35eEc7588a65] = LenderTokens(
            0x5039d331C7586AAc1AE18C01d5fB7f1555788CBE,
            0x0c9F4874c8B08447c703FD433D4e8C2136aBA95b,
            0x41C73A1d1141115f3bF42d847Dd1138dDd4A6412
        );
        lendingTokens[Chains.BASE][Lenders.XLEND][0x194b8FeD256C02eF1036Ed812Cae0c659ee6F7FD] = LenderTokens(
            0x33e30D2342a2378fC7c0846f529f4d83703574dd,
            0xf51559325a1C9f787004431C86f450BdFE92F3Be,
            0xA4dedf8744D970778eddA37B2d3ef8Ed909F69B6
        );
        lendingControllers[Chains.OP_MAINNET][Lenders.XLEND] = 0x345D2827f36621b02B783f7D5004B4a2fec00186;
        lendingControllers[Chains.BASE][Lenders.XLEND] = 0x09b11746DFD1b5a8325e30943F8B3D5000922E03;
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAYBANK][0xceE8FAF64bB97a73bb51E115Aa89C17FfA8dD167] = LenderTokens(
            0x241758b187714f6763787D01E365B2eF9aA71370,
            0x38738669D04C676789a3543Be05A55386141B3b6,
            0xA66d1F342bDF4178a999Eed4c83208B7bF37e4b3
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAYBANK][0x754288077D0fF82AF7a5317C7CB8c444D421d103] = LenderTokens(
            0xa01612922312BB88c4da63821f1eCcA933e7d01d,
            0x756c71A4684CdcE82FAaFce957A1F8b45Bed3932,
            0x52ed398830bE89a2e5ccf00EADb4dCfAe1c0B489
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAYBANK][0x34d21b1e550D73cee41151c77F3c73359527a396] = LenderTokens(
            0x3d0950E0D1aFE341E6c99b60eA4041e2e4E99409,
            0x5f4d46a30445cF75f3Cd8Df1a2FD1F3044629A48,
            0x835c57163ad0A4D700600Ea1bC692AAea21D2040
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAYBANK][0x16D0e1fBD024c600Ca0380A4C5D57Ee7a2eCBf9c] = LenderTokens(
            0xfa281A109c495964855e4d9F5A11ec18e99C1d43,
            0xc2fC9Dc198136B10FAE757AAE0189741A71958AB,
            0x78AaEe24ceF190b25499DfE5279FC847313A2FC5
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAYBANK][0x5c74070FDeA071359b86082bd9f9b3dEaafbe32b] = LenderTokens(
            0x744dd1b4e3744dB00C50D06EDC7F171d08Bf25B5,
            0x3800cd0547e3cfa66ed8D7fF818C8B1c3F5d6ec5,
            0x9f2B70ed02EAe67f71D829BEFF743b38f686aAE5
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAYBANK][0xe4f05A66Ec68B54A58B17c22107b02e0232cC817] = LenderTokens(
            0x2F72278d8f8c4840A4D9E20D609Fb0b6EF622904,
            0xC477949fE177070e12a4CfAB7875D9E7A2eE7539,
            0x790a35517B11D04b25f40A01ba92C4dFfB3ee5F5
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAYBANK][0x4Fa62F1f404188CE860c8f0041d6Ac3765a72E67] = LenderTokens(
            0xc5A99c150Fd125933a626d08e9B8E165143D0EC7,
            0x00efc7bA96f924A0A0136E3D5bC56c38c15e3e2f,
            0xf7372297058097246b552F4F8Df7a1D8e8999683
        );
        lendingTokens[Chains.KAIA_MAINNET][Lenders.KLAYBANK][0x5096dB80B21Ef45230C9E423C373f1FC9C0198dd] = LenderTokens(
            0xC71D18628e5aFE942912f5Fa794c6175A94B2443,
            0x3E2A75d621482FfFde985AE1fF14f29346AD8bCF,
            0xE6D6a57b6a762e30911c557b7CD8Ad013FFa6662
        );
        lendingControllers[Chains.KAIA_MAINNET][Lenders.KLAYBANK] = 0x4B6Ece52D0EF60aE054f45c45D6bA4F7a0C2cC67;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] = LenderTokens(
            0xB11A912CD93DcffA8b609b4C021E89723ceb7FE8,
            0xE7CDC4e53915D50B74496847EeBa7233caE85CE5,
            0x2Adc0c94A055f1FF64A35672D30Eb523ec647816
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS][0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56] = LenderTokens(
            0xaeD19DAB3cd68E4267aec7B2479b1eD2144Ad77f,
            0x24758d41e5Aa89f79048076254A3d22927b2E0D4,
            0x576efee43A35e8adf9FaaC6f9DDC5f8AAc77768F
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] = LenderTokens(
            0xA6fDEa1655910C504E974f7F1B520B74be21857B,
            0x8Ef780a3e1C266aF586315a9aDA19dBfC3a1E45c,
            0xd67dF5a99512697305F121E669Dd10a1A5E6081c
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS][0x55d398326f99059fF775485246999027B3197955] = LenderTokens(
            0x5f7f6cB266737B89f7aF86b30F03Ae94334b83e9,
            0x256B441313e10b7210A6239070C085446a507bD8,
            0x0DBE974029970fFA1e298e1C1B723100c8f3B7b5
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS][0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3] = LenderTokens(
            0x2c85EBAE81b7078Cd656b2C6e2d58411cB41D91A,
            0x1CF681fc1Df8aEF478A675DF40E62091B93E0Aac,
            0x68cc1E4d949C41eDBB2b0A7498635E70c610072B
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS][0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82] = LenderTokens(
            0xC37079A50611a742A018c39ba1C5EbDd89896334,
            0xC7C7bF1F28d29cEa48F4AAAefb7E8C1FB43DB200,
            0x0978AFdb6787779B4Eac6fEFE7E43e948F6cD6b8
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] = LenderTokens(
            0x831F42c8A0892C1a5b7Fa3E972B3CE3AA40D676e,
            0x9e06035740ab5eD9F48D8fF8B588056693b83e3a,
            0x27fE030832A8F01BCcBc0aAFBcb1C07da241D16c
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] = LenderTokens(
            0x204992f7fCBC4c0455d7Fec5f712BeDd98E7d6d6,
            0x5651565e4F544911F16f9a717d3aCEccD29d1BdA,
            0x07a1375a55C43fc8A02a051A3194cA400b30a890
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS][0x14016E85a25aeb13065688cAFB43044C2ef86784] = LenderTokens(
            0xBB5DDE96BAD874e4FFe000B41Fa5E98F0665a4BC,
            0xaEB0AE2B4CF427E6E3ebe14b6B92f8bF2D68dfD4,
            0x8B0bFa69062315cD2063944d4d6723022B9c6E67
        );
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS][0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9] = LenderTokens(
            0xE1Ee815B5DA785e4dEF8247f3E11fd241c5be042,
            0xd455B2784bf9e019767c14068dEa7b954971dF89,
            0xd1aB922bC3F4F8D332044e9dC2f42d6cFb9d2e63
        );
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VALAS] = 0xE29A55A6AEFf5C8B1beedE5bCF2F0Cb3AF8F91f5;
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0xA1077a294dDE1B09bB078844df40758a5D0f9a27] = LenderTokens(
            0x074E0878648DE80359e1C07772A617899dD7b42a,
            0x24ACB8c0d86126EF0Bd1E3454Cf52c042b6e830A,
            0xd3C78458cda9ce4e84F9FedaFE5E05feEa5539Cb
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39] = LenderTokens(
            0xb2B9ef896d5F3e519C18771F0EE4F62F188d89d4,
            0x7Ef0fdf765bc8CDDa6878c5b14e62AcfAA155E98,
            0x89284cCfe82E68bA70a7c7Ee7eaf93B464482855
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0x95B303987A60C71504D99Aa1b13B4DA07b0790ab] = LenderTokens(
            0x2242e5Fa475b07Cc6D8E88cbE237F3cA3BfA9Be0,
            0x0d29B861cFA52f24Dda9d3aE4637cE3C1179D453,
            0xda4c54B15849d6d2847a2B77773B0FB8774421F3
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0x15D38573d2feeb82e7ad5187aB8c1D52810B1f07] = LenderTokens(
            0x82ef9a75218A2bb3fA8f428dD07D813c935970c9,
            0xc6794Cdf9143cC571ed48a3f354496C95ffd74F4,
            0x6d99Bd8F2Ff05589E3F9669D436b5D5E2B2620D1
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0x02DcdD04e3F455D838cd1249292C58f3B79e3C3C] = LenderTokens(
            0x97e15bA1f6aBAEc1209F4895aAA09A73AC71Bf59,
            0xBfa7d0eF04119b8C3B4D6794BAed7ec6bc682E06,
            0xB335839B34190981877861773b91B84363023770
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0xb17D901469B9208B17d916112988A3FeD19b5cA1] = LenderTokens(
            0xB33B68d77b431227017206705671DdaF567D366e,
            0xAED4849Ec13f83c91f570A9d7749692E5E93a624,
            0x3564A89F73E9AF98a13cFCdc0B5fe62A9A184172
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0xefD766cCb38EaF1dfd701853BFCe31359239F305] = LenderTokens(
            0x781Ab98d69CEa221aBBB73F615b31632173b64fb,
            0x3C81E9e18fbE4b1af7bB6eD249b92F905f6F9d7c,
            0x04DedB70D2CD1ecAd12EdB17752c8aa65FeE0CDb
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0x0Cb6F5a34ad42ec934882A05265A7d5F59b51A2f] = LenderTokens(
            0xB802659175De510D04F6d945970EAFA68141feD6,
            0xEF66B290bEc401CB04FfEc06C101c47Dbae8beca,
            0x4C0241c8683836E021796cEAB2347758e0d27f7d
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0x2fa878Ab3F87CC1C9737Fc071108F904c0B0C95d] = LenderTokens(
            0xa6233896B1297440b89189b5349E7510fA0Ee095,
            0x5d70147D7f3d823CcED17a0d93410f1af776E686,
            0x1cEa4DD45363BE30d31f7BDEA9A172790a24526B
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0x0dEEd1486bc52aA0d3E6f8849cEC5adD6598A162] = LenderTokens(
            0x88DD843bF70F173ED549ED39f35222045592536A,
            0x74581B2d6BFd4a680756EA31c9ed7A4E1e53F649,
            0x47D7c65Af8fdd255317d4DEC79Fae632D8c14764
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0x1FE0319440A672526916C232EAEe4808254Bdb00] = LenderTokens(
            0x65856baf0244fd163A5400cC4832D713474fc9f9,
            0xBe6d1f03E60b2701C1E3A5AB706515bA4F30aB1B,
            0x091518d78e363a783fD1B3e42A8470f9656a38ac
        );
        lendingTokens[Chains.PULSECHAIN][Lenders.PHIAT][0xeB6b7932Da20c6D7B3a899D5887d86dfB09A6408] = LenderTokens(
            0x7f78774e8a42E3d50bCaf1605d6ddDE9572f9570,
            0x20d5Aa297b20f24F10cB7145a0Cf6878eFE8352a,
            0x622f167E627bC64754a0296248b813387e8b9E46
        );
        lendingControllers[Chains.PULSECHAIN][Lenders.PHIAT] = 0xC14B5DE7fbdFF428f64AA9E7E240EA342EE9a3A3;
        lendingTokens[Chains.XDC_NETWORK][Lenders.FATHOM][0x49d3f7543335cf38Fa10889CCFF10207e22110B5] = LenderTokens(
            0xEC826980367dABBAA28F614B8D0e14548dCca37b,
            0xcF5b5C4DfeA09a0Ad129717BfbbCA750c362E795,
            0xe82b0F5CDf092Bf01Ae56898bB35b1E77fc60aC2
        );
        lendingTokens[Chains.XDC_NETWORK][Lenders.FATHOM][0x951857744785E80e2De051c32EE7b25f9c458C42] = LenderTokens(
            0xDAEf7d4000fb0e511C9f2dEEAE602d9c8fcb28f7,
            0x10eB945e14131Fb55B2F432d826F4e09d718276D,
            0xcbf718E6802E646D6d016912453E1ECb1BdB0DcA
        );
        lendingTokens[Chains.XDC_NETWORK][Lenders.FATHOM][0xD4B5f10D61916Bd6E0860144a91Ac658dE8a1437] = LenderTokens(
            0x1C3bBc4FA17128711c238Bc50Bd0AE85D35C2515,
            0x98dC1115ADdcdD2eF67c87D35fAF0b835b3F746D,
            0x2F6C3d501cfD528D78c7C1Da3B8Ea37Ba85BDB93
        );
        lendingTokens[Chains.XDC_NETWORK][Lenders.FATHOM][0x8f9920283470F52128bF11B0c14E798bE704fD15] = LenderTokens(
            0x0947617c830307957FAc8d51b1a9488e756Cf2Cf,
            0xa8aFc7a05E54F3027Eb77727d77cc5D3Fe7Bf4Af,
            0x474C64774703f8e5132cc8400d77FA854cA6e219
        );
        lendingTokens[Chains.XDC_NETWORK][Lenders.FATHOM][0x3279dBEfABF3C6ac29d7ff24A6c46645f3F4403c] = LenderTokens(
            0x103Df67779bf7F1C5cfa2374049E5666D9686b98,
            0x31D83E0cae604F6Ce0a06800DAFe0959449b1947,
            0x2b0B493CB20C9efAb5b316618D86fe8a790D81dE
        );
        lendingTokens[Chains.XDC_NETWORK][Lenders.FATHOM][0xfA2958CB79b0491CC627c1557F441eF849Ca8eb1] = LenderTokens(
            0xfc751eef339555950A8cb443bb1e3FdD6a3A77eC,
            0x2c58F972225598dd945fdb2D11a998D63e189509,
            0xa2c3C5b95413F486A07897D288B2a7aA10Db1Cc6
        );
        lendingControllers[Chains.XDC_NETWORK][Lenders.FATHOM] = 0x70d8005E3c8C7e383FE35Fa40156042F3393449F;
        lendingTokens[Chains.XDC_NETWORK][Lenders.PRIME_FI][0xfA2958CB79b0491CC627c1557F441eF849Ca8eb1] = LenderTokens(
            0xB9a14B24C6E669D24E76dab65f7c4dc52f68741C,
            0xDBEd51F298901987651FaF1dAed8Bb575942d406,
            0xa679A608Bddd118Ff4da4A8BD1C67877dc0E97bc
        );
        lendingTokens[Chains.XDC_NETWORK][Lenders.PRIME_FI][0xcdA5b77E2E2268D9E09c874c1b9A4c3F07b37555] = LenderTokens(
            0x2a50Be4Df06202A239384e828D6e67F9F2fA954e,
            0xaaE0D3C0b4aa454cEb5b5346ba1E95a86395D656,
            0x1811D261c05De6c7470D9De6A56b895427151127
        );
        lendingTokens[Chains.XDC_NETWORK][Lenders.PRIME_FI][0x951857744785E80e2De051c32EE7b25f9c458C42] = LenderTokens(
            0x1fF5E0037B478547715a4CE337d9fcFF86A30401,
            0xC12bdD620A54149Df6B73Fad9726d387402a9066,
            0x4481F22A369B1A7272026d5892a4BeEC505De5Fb
        );
        lendingTokens[Chains.XDC_NETWORK][Lenders.PRIME_FI][0x9B8e12b0BAC165B86967E771d98B520Ec3F665A6] = LenderTokens(
            0x834695A5d33967f8cC27E6d15684c0aA36cA4375,
            0x47C4d740016411Bb8f5c9D9bDb3f866c9b46e0A4,
            0x42C48209F2899fFed336c67E04EE21121f12b681
        );
        lendingTokens[Chains.XDC_NETWORK][Lenders.PRIME_FI][0x81B244d0be055EF3BEF1b09B7826Cc2b108B2cBD] = LenderTokens(
            0x3A577f9789FC81C2Ea0B81B9e02B6Dbc67158A37,
            0xD9bA32E8a4955E4fbbbDD61F121b2f81ca7bBFE8,
            0xdE4aC0D2CAEe918F215Fa60122067833254bd0e2
        );
        lendingTokens[Chains.HYPEREVM][Lenders.PRIME_FI][0xb88339CB7199b77E23DB6E890353E22632Ba630f] = LenderTokens(
            0x386f40C2A8485d6572Cb74a736A0763c0521095B,
            0x009A18797c9C7eB06811D4cDc44881F3C5fA748a,
            0x485F14382C920885f9DA1aab0e15e7D92D20Bfcc
        );
        lendingTokens[Chains.HYPEREVM][Lenders.PRIME_FI][0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb] = LenderTokens(
            0x5Fc1737115eCB6850be0A4F0CE25B7F98231cAB9,
            0xd00fe535B82F215989178609286610fe666E5365,
            0xe870b24cAB6621b588958f8A625ab38100CF5260
        );
        lendingTokens[Chains.HYPEREVM][Lenders.PRIME_FI][0x5555555555555555555555555555555555555555] = LenderTokens(
            0xCF4642EF89683D0299B59738b1Cc3AC0177348Ba,
            0x9601C465c3c404465d968a2dda10FD807f2B2d5C,
            0x78dbff862d2b61141595Cae61F861AA4B8f8DF97
        );
        lendingTokens[Chains.HYPEREVM][Lenders.PRIME_FI][0xBe6727B535545C67d5cAa73dEa54865B92CF7907] = LenderTokens(
            0x6E811Aa146F961c918d14BE9Ed9C0Cd68F447a6e,
            0x71f719166c403aC15F55567BABdd19b7dA1E8817,
            0x37c48afFE87857a0fcBfc32742101036B56046EE
        );
        lendingTokens[Chains.HYPEREVM][Lenders.PRIME_FI][0x9FDBdA0A5e284c32744D2f17Ee5c74B284993463] = LenderTokens(
            0x98b7056E0e0521b7bA32F4Ac8af8e1249789d2d6,
            0xD218a5F74aF42d9b1a879e2349e751DEaFe3114C,
            0xE73997E0E71C6B7CE920222d4ABd21b3B26fdB80
        );
        lendingTokens[Chains.HYPEREVM][Lenders.PRIME_FI][0x7BBCf1B600565AE023a1806ef637Af4739dE3255] = LenderTokens(
            0x07CB5Aa0c467Df9b3A38dF3fBfd465c454905690,
            0x182CFb49ad159F8C770ef7ad9Ff56F3E61b9A9fa,
            0x575e9e2fFAbe88F7896A246735905949F95F6B83
        );
        lendingTokens[Chains.BASE][Lenders.PRIME_FI][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = LenderTokens(
            0xB9a14B24C6E669D24E76dab65f7c4dc52f68741C,
            0xDBEd51F298901987651FaF1dAed8Bb575942d406,
            0xa679A608Bddd118Ff4da4A8BD1C67877dc0E97bc
        );
        lendingTokens[Chains.BASE][Lenders.PRIME_FI][0x4200000000000000000000000000000000000006] = LenderTokens(
            0x2a50Be4Df06202A239384e828D6e67F9F2fA954e,
            0xaaE0D3C0b4aa454cEb5b5346ba1E95a86395D656,
            0x1811D261c05De6c7470D9De6A56b895427151127
        );
        lendingTokens[Chains.BASE][Lenders.PRIME_FI][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0x1fF5E0037B478547715a4CE337d9fcFF86A30401,
            0xC12bdD620A54149Df6B73Fad9726d387402a9066,
            0x4481F22A369B1A7272026d5892a4BeEC505De5Fb
        );
        lendingTokens[Chains.BASE][Lenders.PRIME_FI][0x7BBCf1B600565AE023a1806ef637Af4739dE3255] = LenderTokens(
            0x834695A5d33967f8cC27E6d15684c0aA36cA4375,
            0x47C4d740016411Bb8f5c9D9bDb3f866c9b46e0A4,
            0x42C48209F2899fFed336c67E04EE21121f12b681
        );
        lendingControllers[Chains.XDC_NETWORK][Lenders.PRIME_FI] = 0x8a619D8E3BfAb54F7C30Ef39Ce16c53429c739C3;
        lendingControllers[Chains.HYPEREVM][Lenders.PRIME_FI] = 0xb339448E13E273f6F46e3390e0932Ab7fF9F113F;
        lendingControllers[Chains.BASE][Lenders.PRIME_FI] = 0x8a619D8E3BfAb54F7C30Ef39Ce16c53429c739C3;
        lendingTokens[Chains.SCROLL][Lenders.U235][0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df] = LenderTokens(
            0xF489DAb7D2792C0759C7Ae54A9b22D569dA5997D,
            0x304A58cb9d099B40a728C3d91d20D03427F976F3,
            0x3C025DA2F354Fd84c8423b2c092be80343f6f3C4
        );
        lendingTokens[Chains.SCROLL][Lenders.U235][0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4] = LenderTokens(
            0x2A91c96035d36e45316685ae5E4B204BF531c750,
            0xC6EF9d7935044bab04B7780862e67b2E22747840,
            0xaC76D602548068c4566ef52b4D9A951E153092AC
        );
        lendingTokens[Chains.SCROLL][Lenders.U235][0x5300000000000000000000000000000000000004] = LenderTokens(
            0x1E0e73C24225058582715bf26E754AfBa52eFac2,
            0xB3a544da8dF244aA044f51a6F3cCc1fb6c2Bd11e,
            0xFE861bccf1a1dAE03C4325ae35638FD2bd5C9669
        );
        lendingTokens[Chains.SCROLL][Lenders.U235][0xf610A9dfB7C89644979b4A0f27063E9e7d7Cda32] = LenderTokens(
            0x94CDd8D8d58D81f1F3CfCdd7119a4917Aac21907,
            0xA24a9244537af197025222226E55e8a2149B5Be7,
            0xFfDe715c93061Ef090134DB5df34Bf53f3A543de
        );
        lendingControllers[Chains.SCROLL][Lenders.U235] = 0xeb787d93fD7C6f5995977Ec89303B5CFE6668682;
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.PLUTOS][0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6] = LenderTokens(
            0xD65E02984196BF99efd3Ea4C158cBF7FFA1Dba5f,
            0x95565E858eE7016d5358eE797Ae64B3447353197,
            0x32C0c5267A1b483f8af755bFA0abcCC9D1b4B459
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.PLUTOS][0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619] = LenderTokens(
            0x5b7eCB01212740A1714283bf2b0Be7Cf90efE34b,
            0xe5Cb6eaE13C2e56ba44651394B9F200aa6d0b65C,
            0x269088DF53513512105855Ac238D33044060344c
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.PLUTOS][0xc2132D05D31c914a87C6611C10748AEb04B58e8F] = LenderTokens(
            0x227b2c1F2751B0CC38751dc06F59162d6E7Fd766,
            0x7dC6a31a859301E4F5A9f56A65B232631e58012f,
            0xba1aDC4B11Aaf7c31D1Fe6D4a8cC7CF48511AFe7
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.PLUTOS][0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359] = LenderTokens(
            0xE647db0B418929436f961AAcEbfFCfcfC8629bc4,
            0x331541B6bEA34732176C028f2ebf0d37cF0858BC,
            0x187206a28164a406238eecD5719B4Cfe298dC3C8
        );
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.PLUTOS][0x03b54A6e9a984069379fae1a4fC4dBAE93B3bCCD] = LenderTokens(
            0x35830718Fa70E6e94A55c64EB566fA14FC0fA194,
            0x074bfeD0727C51C01Be8AEcF632592E865472DCf,
            0x97553c2aF2a5b3486fb11C4428E5cEF542d2BDD6
        );
        lendingTokens[Chains.BASE][Lenders.PLUTOS][0x4200000000000000000000000000000000000006] = LenderTokens(
            0xb556905C758c737daef32f8fFE25CE5896733d6A,
            0xF933866DcB0C4782E1fDCea7872aCbf05Aa9000B,
            0x718Ac969a5fDD068d210B21BAEe6CB753d366909
        );
        lendingTokens[Chains.BASE][Lenders.PLUTOS][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = LenderTokens(
            0x918c4Cb4D7bC7015dD36fFECAe05A4e53266B6b5,
            0x9fA5dAb651f9D3dd3B46a7204eB03F82E72A8e15,
            0x9308c036fA57d2bAE609E30320E716E65bDa5180
        );
        lendingTokens[Chains.BASE][Lenders.PLUTOS][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] = LenderTokens(
            0xF0069393EC4bB369518b95aBa985035d6b01FB1D,
            0xcc6565D90012874bdeF467cd562a3b1F2f03D98C,
            0xE6b4269524Ead5275841C0976CE94D550BD20cda
        );
        lendingTokens[Chains.BASE][Lenders.PLUTOS][0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452] = LenderTokens(
            0x252d5479bc6F7D93F5186106c7dEE4A58842d25a,
            0x427f14dC64Fb92E8a4Df78676E636D2b3F72eAdD,
            0x25b775fD8b0c2b0AECA224568813E7F6f879f49e
        );
        lendingTokens[Chains.BASE][Lenders.PLUTOS][0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22] = LenderTokens(
            0x5E24C18180f0105720995E0651F136054E0B95e4,
            0x9F452e3A8aA72984fBAb7401ac2069950Ad6EC18,
            0xF72783283f6Dc7CdcE753fDBb5bD46D81cBE98b6
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.PLUTOS][0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb] = LenderTokens(
            0x701134eb340fd5fCd5C66EB3546793E84F85b09B,
            0xc90Fc572EE2Bc1dC0daf4E614222120727DB3b54,
            0xE97Beba74Cacb725fFB38D249682a118391fE128
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.PLUTOS][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] = LenderTokens(
            0xD8Fbd5093c9e4DaC2772482D3118A770A02D231e,
            0x813Dd3f67835c31d48966184829145a5866b4A7a,
            0xC5E1A911cD0DbEdFDAE62eDaDc9B5AaDF9Fe25AF
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.PLUTOS][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] = LenderTokens(
            0xb3c32055431219139364922430734289dfE3433c,
            0xd7bE76d002fD5ee9a0A99062ceD9cAA0Df1E4157,
            0xD285dEfBB64fEB7C7807175e48293A4Ea34B8798
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.PLUTOS][0x9895D81bB462A195b4922ED7De0e3ACD007c32CB] = LenderTokens(
            0x3b77Bc04fA1184dbD1F8FD3A79a81605D0fa733E,
            0x03669A121d912252a2C5c46F31F5Ae19A3D674C4,
            0xD39B5B63d671574bECC5CD142284180f46A3aDFf
        );
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.PLUTOS][0xA3D68b74bF0528fdD07263c60d6488749044914b] = LenderTokens(
            0x848a08CC63ED992505B512eE3eBd86f1aE412a70,
            0x30C863EFfa6E4eC3caa97B5a005a4b23F37c784b,
            0x7a6645E22d89C7c531B80415C13D884a2aF3125f
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.PLUTOS][0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] = LenderTokens(
            0x3FaA464dE86ca69863FF0ae029A7A0F0466B8fD9,
            0x3C35Dc6a7e6D05178FcE82F6dB7094FADed76400,
            0x361161C34F8232E5E25C1a6f403DFeD4B2CC94df
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.PLUTOS][0xaf88d065e77c8cC2239327C5EDb3A432268e5831] = LenderTokens(
            0xa9b9cCE44fe4150e87965bb31FB2b55D009812B1,
            0x22c80225456491ab9ac0e4E3fBEcf783D887038f,
            0x60307d2E6A76D1CEabc1adF74120EcBD24a1b0e4
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.PLUTOS][0x5979D7b546E38E414F7E9822514be443A4800529] = LenderTokens(
            0x01d65Ded4C3c4F76Acd5EAE730320eBb4aF0E156,
            0xe0641e6F42fE3945DEadcb7A413E66beEe127839,
            0xE996E51328368B98f29bbc490B8464F22C190566
        );
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.PLUTOS][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] = LenderTokens(
            0xB75a86dEedb9b4c95543D2dD0cc41CB641a28C24,
            0xe1A82829bC672A5c336E48EC6898496466c80Ae3,
            0x511Abf07b0c3C8D3c5a9B56088d709d7789F48dD
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.PLUTOS][0xad11a8BEb98bbf61dbb1aa0F6d6F2ECD87b35afA] = LenderTokens(
            0x3FaA464dE86ca69863FF0ae029A7A0F0466B8fD9,
            0x3C35Dc6a7e6D05178FcE82F6dB7094FADed76400,
            0x361161C34F8232E5E25C1a6f403DFeD4B2CC94df
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.PLUTOS][0xbB0D083fb1be0A9f6157ec484b6C79E0A4e31C2e] = LenderTokens(
            0xa9b9cCE44fe4150e87965bb31FB2b55D009812B1,
            0x22c80225456491ab9ac0e4E3fBEcf783D887038f,
            0x60307d2E6A76D1CEabc1adF74120EcBD24a1b0e4
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.PLUTOS][0x7A06C4AeF988e7925575C50261297a946aD204A8] = LenderTokens(
            0x01d65Ded4C3c4F76Acd5EAE730320eBb4aF0E156,
            0xe0641e6F42fE3945DEadcb7A413E66beEe127839,
            0xE996E51328368B98f29bbc490B8464F22C190566
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.PLUTOS][0xAA40c0c7644e0b2B224509571e10ad20d9C4ef28] = LenderTokens(
            0xB75a86dEedb9b4c95543D2dD0cc41CB641a28C24,
            0xe1A82829bC672A5c336E48EC6898496466c80Ae3,
            0x511Abf07b0c3C8D3c5a9B56088d709d7789F48dD
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.PLUTOS][0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3] = LenderTokens(
            0x9D7a3590cA6621893bC6B908B8Bce925d9407bB9,
            0x32c2D2AFfD456a638c10D835808518bEd80d1409,
            0xe0d578EF3A957e18c58De324309E04e3D4C12A78
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.PLUTOS][0x623F2774d9f27B59bc6b954544487532CE79d9DF] = LenderTokens(
            0xD6203b39b1e57301fd10CB946436Dda71D933F4D,
            0xDD2dc9aD713F9e3A7830F62e4951B47Eb1496905,
            0xDcd8FB50AEcA157f9f2e5070B2dD9455c7966629
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.PLUTOS][0x4200000000000000000000000000000000000006] = LenderTokens(
            0xA8F2DcaEE054809017FDF6EFbacdD5387a065Bc9,
            0x2deE738d94aD501BAdF909fd6c83375A129430de,
            0xfeCb9D33544544D9667C1635EeC04FaE616ea2fA
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.PLUTOS][0x99e3dE3817F6081B2568208337ef83295b7f591D] = LenderTokens(
            0x9DF7B63fD5295944038E061cb2e4637618227f85,
            0x28E148a76973ca7ea6d5D2fFbab06cB2a5660C88,
            0x5ceA6a01fBF68a7BcA73C349F1d1b269550e5aea
        );
        lendingTokens[Chains.HEMI_NETWORK][Lenders.PLUTOS][0xb4818BB69478730EF4e33Cc068dD94278e2766cB] = LenderTokens(
            0x682f12e6DD63495E31c24572F9997B3Bc7A99442,
            0x36257DB714A10DfC3a97C319564c96471c3657e2,
            0x255C3595ab9cF3Ea10559DD636868b759C32fBE5
        );
        lendingTokens[Chains.KATANA][Lenders.PLUTOS][0x9893989433e7a383Cb313953e4c2365107dc19a7] = LenderTokens(
            0xa34059252aCadF182613f7B8D5B41fabA503612A,
            0x8e4b17ADB65D153bb8009134b2B2f5264b87d264,
            0x86a486E587D8BD98320985337AecFCEfF7dDbD97
        );
        lendingTokens[Chains.KATANA][Lenders.PLUTOS][0x0913DA6Da4b42f538B445599b46Bb4622342Cf52] = LenderTokens(
            0xFe8cfF2418b859f1348577c01D7FaA3cCb8d9E03,
            0x2621c10591197099d79D3f88e7D3E9Ccd8072c9D,
            0xCcFe3e06fd54a1c3e41dA7e98675EB5aB35ea681
        );
        lendingTokens[Chains.KATANA][Lenders.PLUTOS][0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62] = LenderTokens(
            0x49f71B4d0Dd206ba7638D7F73e088CD11866b93B,
            0xB665B78b2033985A1d51522bEEc38ee56954e473,
            0x3b5D53D66bA25a76C8641a523F0d36410D82330D
        );
        lendingTokens[Chains.KATANA][Lenders.PLUTOS][0x80c34BD3A3569E126e7055831036aa7b212cB159] = LenderTokens(
            0xA79e55079BCC75730102220959753610D29026Ca,
            0x1c92ee4227cE9Cd17a2290B8Fc4cF4D7Db719E68,
            0xf800a256439720D2B0A9a77AD078Ed160b0e6173
        );
        lendingTokens[Chains.KATANA][Lenders.PLUTOS][0x9A6bd7B6Fd5C4F87eb66356441502fc7dCdd185B] = LenderTokens(
            0xfD3a3B0bC4CD1DD151b429574139c8c9CFB71d59,
            0x28B5bae43371669F41F5564832281a2ebdF6432C,
            0xbA62293a3F88218C2B9232D0D2fb80f5FbB85A01
        );
        lendingTokens[Chains.KATANA][Lenders.PLUTOS][0xE007CA01894c863d7898045ed5A3B4Abf0b18f37] = LenderTokens(
            0xFF38C9893cbd126CD094D8A34E73f2F94B20cdbF,
            0x68BC21510716E733c7d7C9192D98EFCa915B92d7,
            0x83d6136d0DC8D199d63a5C31e01083a820B5479B
        );
        lendingTokens[Chains.KATANA][Lenders.PLUTOS][0xAa0362eCC584B985056E47812931270b99C91f9d] = LenderTokens(
            0xcC2CD62C675412D18626532D2eA89ed174335aeB,
            0x10588056c20ce21d879d7bEEE0ae91fFcAE1BAb2,
            0x1e541B38De430A354d495596Eec7b35eE045087C
        );
        lendingControllers[Chains.POLYGON_MAINNET][Lenders.PLUTOS] = 0x93BEF731821B2E534cCFBD330734d35de34fa418;
        lendingControllers[Chains.BASE][Lenders.PLUTOS] = 0xf072795653316fd7Fb15b2e4fF4e273385986ac2;
        lendingControllers[Chains.PLASMA_MAINNET][Lenders.PLUTOS] = 0x3775Df2Ac7fbf5ED636595aeFEd4544B9fA14C0a;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.PLUTOS] = 0xDdc98fF53945e334Ecca339b4DD8847b3769e8f0;
        lendingControllers[Chains.HEMI_NETWORK][Lenders.PLUTOS] = 0xDdc98fF53945e334Ecca339b4DD8847b3769e8f0;
        lendingControllers[Chains.KATANA][Lenders.PLUTOS] = 0x56f543bFF654193EcFb8fB9D5e7D1C30eDB69288;
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1] = LenderTokens(
            0xc1a6F27a4CcbABB1C2b1F8E98478e52d3D3cB935,
            0x5Bfc2d187e8c7F51BE6d547B43A1b3160D72a142,
            0xe8348837A3be3212E50F030DFf935Ae0A0eA4B54
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0xB75D0B03c06A926e488e2659DF1A861F860bD3d1] = LenderTokens(
            0x945C042a18A90Dd7adb88922387D12EfE32F4171,
            0x25eA70DC3332b9960E1284D57ED2f6A90d4a8373,
            0x04Ba7e1387dcBE7e1fC43Dc8dE5dE8A73a77b1ee
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7] = LenderTokens(
            0x809FF4801aA5bDb33045d1fEC810D082490D63a4,
            0x648e683aaE7C18132564F8B48C625aE5038A9607,
            0x4dE99D1f91A1d731966fa250b432fF17C9C234d9
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x160345fC359604fC6e70E3c5fAcbdE5F7A9342d8] = LenderTokens(
            0x093066736E6762210de13F92b39Cf862eee32819,
            0xCBaD33e1233fc415be5D98E3CFB6AF1f074e67AD,
            0x005396dAC4b565eb3CD50fCe5DBC6D7A8d2c3d42
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x5Cf6826140C1C56Ff49C808A1A75407Cd1DF9423] = LenderTokens(
            0xa524c4a280f3641743eBa56e955a1c58e300712b,
            0x13Cfe1e14379F67f2188120DeCb6a15dA1F3e861,
            0x367662a736aa68e34F9EfA42c8fDd69a3a3F2faa
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x80Eede496655FB9047dd39d9f418d5483ED600df] = LenderTokens(
            0xC15dce4e1BfABbe0897845d7f7Ee56bc37113E08,
            0x5BC80c7975221A1e81F4c2fa4c23f29fd067564A,
            0xaC6fA5CD80e4097B7dA7da462d932d839640AbC5
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0] = LenderTokens(
            0x7090D5fdCEfB496651B55c20D56282CbcdDC2EE2,
            0x43d095F50366acB0cA2FeAb68eBE2C90383CFa19,
            0xe89dbCBeAD2bc81d2E25B279b39306d593023DF5
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050] = LenderTokens(
            0x2a662eF26556a7d8795BF7a678E3Dd4b36FDec1e,
            0x768a2f5e5397Ff911BDbe488f59b24FE838f529B,
            0xd54F8dd8a838d346D209d5cb6cBA20C72233C73E
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45] = LenderTokens(
            0x1C4b5c523f859c0F1f14A722a1EAFDe10348F995,
            0xb2308aB4Ce77A6c73991766Cb76159614115A8e9,
            0xE9fFbB3cF12DF4B3d82432993B7e01c4c67F3ebD
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x37a4dD9CED2b19Cfe8FAC251cd727b5787E45269] = LenderTokens(
            0x04295E6912F95f2690993473E6CCAAE438Cf3f06,
            0xF546E9A1e0F60ec8b89F50A23Bbdd81b0D94Fe3c,
            0x60Df82796Cc55d7E5e06427399A15bA1ce0DFDb7
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x0555E30da8f98308EdB960aa94C0Db47230d2B9c] = LenderTokens(
            0xB6298BCD7EC6CA2A6EaBdD84A88969091b2c3291,
            0xC7054BC3a42d51c06FF26e0C455a5799183C6A28,
            0xCA1DDb6fca85e0247F03346D1EFF5A85326a31f7
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0xdf77686D99667Ae56BC18f539B777DBc2BBE3E9F] = LenderTokens(
            0xf8FEb964A1D02F61BcD4B8429c82cb8f5ee58993,
            0x42BccB9F752F89B27791D43aa7314E52A3CF401a,
            0x5A9B3fFF0c2C3Fe8A087c31daEEB68b9bB183Aba
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] = LenderTokens(
            0x92e59Fb4c379381926494880F94DbC3635207f89,
            0xbaB321e4437E3c9d903e3253C81Ddf3333C12927,
            0x66E2b655E88CebD30B923B1a553c375a5579E686
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0xBE574b6219C6D985d08712e90C21A88fd55f1ae8] = LenderTokens(
            0x56eCcE7c130dc9F0D3Af1DD2e31e5C9319b61bb7,
            0xC054A292Bf6183b8dEA3E059cBF61a6f9ABf8E47,
            0x3a9EB04EE78eBB719E65Fd523e9A4aE97C219939
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x9151434b16b9763660705744891fA906F660EcC5] = LenderTokens(
            0x368A466cD8679197a08a3F6318B6a5b67df81fb0,
            0x6953c1564ff90Ae639f571E774f2c300e49daAFb,
            0x83FBA0A0657ABA840dE142013eadAa6958575BCd
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392] = LenderTokens(
            0x817B3C191092694C65f25B4d38D4935a8aB65616,
            0x492205148fb5BA1507a62BC3b7C522f3b62250d5,
            0x7924716677c66Ca21aB8D776A6326B6E33b9797E
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x81D3A238b02827F62B9f390f947D36d4A5bf89D2] = LenderTokens(
            0xCb01169aF52e0edEb9aA792FEB210eCB81108222,
            0xFb559A5ee999aD9ad4b840A6d17a9A177Bcd4Ed2,
            0x14613e47DDC82fe0330e165a9E74316f1917cecb
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0xCC0966D8418d412c599A6421b760a847eB169A8c] = LenderTokens(
            0xF2C899CddC4dE26400241544EB3Ce0E7D29e26bA,
            0x663A059f43B97f00b39F28C11602DbddFa545822,
            0x1B38525457df102fcba787A0a6716890308323Eb
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI][0x54cD901491AeF397084453F4372B93c33260e2A6] = LenderTokens(
            0x9922D01107eAA714146C5235528A6fDE99C746DB,
            0xa2803208A7237568012eee07a52AD0f9bddED8c3,
            0x74AF98050cD94Bad3f4e8cB006E260282eFcD156
        );
        lendingControllers[Chains.SEI_NETWORK][Lenders.YEI] = 0x4a4d9abD36F923cBA0Af62A39C01dEC2944fb638;
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI_SOLV][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] = LenderTokens(
            0x7A2B7109ca4D1557993EBaFA00FA93Af4c636F2E,
            0x9f273bA2A559190a6A6f712699ac8Ca30B2E1A6A,
            0xc0161A696e96bE47BA6a1455A9aE6987CDBde774
        );
        lendingTokens[Chains.SEI_NETWORK][Lenders.YEI_SOLV][0xCC0966D8418d412c599A6421b760a847eB169A8c] = LenderTokens(
            0xD36ceD499E83c778b3c79b2cB76DED61108E301b,
            0x29e59fba0458F4e8BcD59E992C6fa140e30FA245,
            0xD7CCB441ed9Ff189fDE16E86BfD842d39a725B3B
        );
        lendingControllers[Chains.SEI_NETWORK][Lenders.YEI_SOLV] = 0x7b5b1A719d54664657451db7600FD5C3ca0fa136;
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0x754704Bc059F8C67012fEd69BC8A327a5aafb603] = LenderTokens(
            0x38648958836eA88b368b4ac23b86Ad44B0fe7508,
            0xb26FB5e35f6527d6f878F7784EA71774595B249C,
            0x7491E87eed26418ff67422169a7608E67d691978
        );
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A] = LenderTokens(
            0xD0fd2Cf7F6CEff4F96B1161F5E995D5843326154,
            0x3acA285b9F57832fF55f1e6835966890845c1526,
            0x81b19837295a2b4b1f6E0B2eaA239999294374E4
        );
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0xe7cd86e13AC4309349F30B3435a9d337750fC82D] = LenderTokens(
            0x39F901c32b2E0d25AE8DEaa1ee115C748f8f6bDf,
            0xa2d753458946612376ce6e5704Ab1cc79153d272,
            0xc76A07FAc2bb9b1C43E7702b0F96B2d15fD037E1
        );
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0x0555E30da8f98308EdB960aa94C0Db47230d2B9c] = LenderTokens(
            0x34c43684293963c546b0aB6841008A4d3393B9ab,
            0x544a5fF071090F4eE3AD879435f4dC1C1eeC1873,
            0xF5512227759C963b03ac1bDcAF176F3A68880192
        );
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242] = LenderTokens(
            0x31f63Ae5a96566b93477191778606BeBDC4CA66f,
            0xdE6C157e43c5d9B713C635f439a93CA3BE2156B6,
            0xD22e72BA1356c4aDE09EA0b6463617A6e4349778
        );
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0xA3227C5969757783154C60bF0bC1944180ed81B9] = LenderTokens(
            0xdFC14d336aea9E49113b1356333FD374e646Bf85,
            0x26A823b286B5dE1185EF0D90F77b7f04e6E24306,
            0xcde3986864Bd06ace8726B65b9fd5b9cBB4EA47d
        );
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c] = LenderTokens(
            0xC64d73Bb8748C6fA7487ace2D0d945B6fBb2EcDe,
            0xbb64E46e995bE16eEF3Ec009442ABC0f2c8381B1,
            0x1b1947ecaA12E644d09165F3c43Ce059f6E24274
        );
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a] = LenderTokens(
            0x784999fc2Dd132a41D1Cc0F1aE9805854BaD1f2D,
            0x54fC077EAe1006FE3C5d01f1614802eAFCbEe57E,
            0xe004483d67B06f5B002098DB51217A7cCaFeD403
        );
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081] = LenderTokens(
            0x7f81779736968836582D31D36274Ed82053aD1AE,
            0x905999CC7B7e26c1Cb2761F6C00909B65C862b78,
            0xd8842741B71e01aee846AbEc07Cf26c52302d010
        );
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0x103222f020e98Bba0AD9809A011FDF8e6F067496] = LenderTokens(
            0xaCaaA891b30E13D024AB67b6EcA9c2EcBD8cf52b,
            0xcb6F3477fDFe996bf418cd9F26146Ba2370706D1,
            0x697a55E3d63FC07838ba1C8768146a98016c6201
        );
        lendingTokens[Chains.MONAD_MAINNET][Lenders.NEVERLAND][0x9c82eB49B51F7Dc61e22Ff347931CA32aDc6cd90] = LenderTokens(
            0x293e2f01a38Fe690Eb8E570AB952b24b225113a7,
            0x457354dB2142A61188166699E0b65b2699092585,
            0x11D5b3585775D3E10D53E5283201010c4622c9ad
        );
        lendingControllers[Chains.MONAD_MAINNET][Lenders.NEVERLAND] = 0x80F00661b13CC5F6ccd3885bE7b4C9c67545D585;

        // Initialize Compound V3 protocol data
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_USDC] = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_WETH] = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_USDT] = 0x3Afdc9BCA9213A35503b077a6072F3D0d5AB0840;
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_WSTETH] = 0x3D0bb1ccaB520A66e607822fC55BC921738fAFE3;
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_USDS] = 0x5D409e56D886231aDAf00c8775665AD0f9897b56;
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_WBTC] = 0xe85Dc543813B8c2CFEaAc371517b925a166a9293;
        lendingControllers[Chains.OP_MAINNET][Lenders.COMPOUND_V3_USDC] = 0x2e44e174f7D53F0212823acC11C01A11d58c5bCB;
        lendingControllers[Chains.OP_MAINNET][Lenders.COMPOUND_V3_USDT] = 0x995E394b8B2437aC8Ce61Ee0bC610D617962B214;
        lendingControllers[Chains.OP_MAINNET][Lenders.COMPOUND_V3_WETH] = 0xE36A30D249f7761327fd973001A32010b521b6Fd;
        lendingControllers[Chains.UNICHAIN][Lenders.COMPOUND_V3_USDC] = 0x2c7118c4C88B9841FCF839074c26Ae8f035f2921;
        lendingControllers[Chains.UNICHAIN][Lenders.COMPOUND_V3_WETH] = 0x6C987dDE50dB1dcDd32Cd4175778C2a291978E2a;
        lendingControllers[Chains.POLYGON_MAINNET][Lenders.COMPOUND_V3_USDCE] = 0xF25212E676D1F7F89Cd72fFEe66158f541246445;
        lendingControllers[Chains.POLYGON_MAINNET][Lenders.COMPOUND_V3_USDT] = 0xaeB318360f27748Acb200CE616E389A6C9409a07;
        lendingControllers[Chains.RONIN_MAINNET][Lenders.COMPOUND_V3_WETH] = 0x4006eD4097Ee51c09A04c3B0951D28CCf19e6DFE;
        lendingControllers[Chains.RONIN_MAINNET][Lenders.COMPOUND_V3_WRON] = 0xc0Afdbd1cEB621Ef576BA969ce9D4ceF78Dbc0c0;
        lendingControllers[Chains.MANTLE][Lenders.COMPOUND_V3_USDE] = 0x606174f62cd968d8e684c645080fa694c1D7786E;
        lendingControllers[Chains.BASE][Lenders.COMPOUND_V3_USDC] = 0xb125E6687d4313864e53df431d5425969c15Eb2F;
        lendingControllers[Chains.BASE][Lenders.COMPOUND_V3_USDBC] = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;
        lendingControllers[Chains.BASE][Lenders.COMPOUND_V3_WETH] = 0x46e6b214b524310239732D51387075E0e70970bf;
        lendingControllers[Chains.BASE][Lenders.COMPOUND_V3_AERO] = 0x784efeB622244d2348d4F2522f8860B96fbEcE89;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.COMPOUND_V3_USDCE] = 0xA5EDBDD9646f8dFF606d7448e414884C7d905dCA;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.COMPOUND_V3_USDC] = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.COMPOUND_V3_WETH] = 0x6f7D514bbD4aFf3BcD1140B7344b32f063dEe486;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.COMPOUND_V3_USDT] = 0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07;
        lendingControllers[Chains.LINEA][Lenders.COMPOUND_V3_USDC] = 0x8D38A3d6B3c3B7d96D6536DA7Eef94A9d7dbC991;
        lendingControllers[Chains.LINEA][Lenders.COMPOUND_V3_WETH] = 0x60F2058379716A64a7A5d29219397e79bC552194;
        lendingControllers[Chains.SCROLL][Lenders.COMPOUND_V3_USDC] = 0xB2f97c1Bd3bf02f5e74d13f02E3e26F93D77CE44;
        cometToBase[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_USDC] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        cometToBase[Chains.OP_MAINNET][Lenders.COMPOUND_V3_USDC] = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
        cometToBase[Chains.UNICHAIN][Lenders.COMPOUND_V3_USDC] = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
        cometToBase[Chains.BASE][Lenders.COMPOUND_V3_USDC] = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        cometToBase[Chains.ARBITRUM_ONE][Lenders.COMPOUND_V3_USDC] = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        cometToBase[Chains.LINEA][Lenders.COMPOUND_V3_USDC] = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
        cometToBase[Chains.SCROLL][Lenders.COMPOUND_V3_USDC] = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
        cometToBase[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_WETH] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        cometToBase[Chains.OP_MAINNET][Lenders.COMPOUND_V3_WETH] = 0x4200000000000000000000000000000000000006;
        cometToBase[Chains.UNICHAIN][Lenders.COMPOUND_V3_WETH] = 0x4200000000000000000000000000000000000006;
        cometToBase[Chains.RONIN_MAINNET][Lenders.COMPOUND_V3_WETH] = 0xc99a6A985eD2Cac1ef41640596C5A5f9F4E19Ef5;
        cometToBase[Chains.BASE][Lenders.COMPOUND_V3_WETH] = 0x4200000000000000000000000000000000000006;
        cometToBase[Chains.ARBITRUM_ONE][Lenders.COMPOUND_V3_WETH] = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        cometToBase[Chains.LINEA][Lenders.COMPOUND_V3_WETH] = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
        cometToBase[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_USDT] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        cometToBase[Chains.OP_MAINNET][Lenders.COMPOUND_V3_USDT] = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
        cometToBase[Chains.POLYGON_MAINNET][Lenders.COMPOUND_V3_USDT] = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
        cometToBase[Chains.ARBITRUM_ONE][Lenders.COMPOUND_V3_USDT] = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
        cometToBase[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_WSTETH] = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        cometToBase[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_USDS] = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
        cometToBase[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V3_WBTC] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        cometToBase[Chains.POLYGON_MAINNET][Lenders.COMPOUND_V3_USDCE] = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
        cometToBase[Chains.ARBITRUM_ONE][Lenders.COMPOUND_V3_USDCE] = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
        cometToBase[Chains.RONIN_MAINNET][Lenders.COMPOUND_V3_WRON] = 0xe514d9DEB7966c8BE0ca922de8a064264eA6bcd4;
        cometToBase[Chains.MANTLE][Lenders.COMPOUND_V3_USDE] = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
        cometToBase[Chains.BASE][Lenders.COMPOUND_V3_USDBC] = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
        cometToBase[Chains.BASE][Lenders.COMPOUND_V3_AERO] = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

        // Initialize Compound V2 protocol data
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] =
            LenderTokens(0x8716554364f20BCA783cb2BAA744d39361fd1D8d, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] =
            LenderTokens(0x7c8ff7d2A1372433726f879BD945fFb250B94c65, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(0x17C07e0c232f2f80DfDbd7a95b942D893A4C5ACb, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xdAC17F958D2ee523a2206206994597C13D831ec7] =
            LenderTokens(0x8C3e3821259B82fFb32B2450A95d2dcbf161C24E, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E] =
            LenderTokens(0x672208C10aaAA2F9A6719F449C4C8227bc0BC202, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x6B175474E89094C44Da98b954EedeAC495271d0F] =
            LenderTokens(0xd8AdD9B41D4E1cd64Edad8722AB0bA8D35536657, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x0000000000085d4780B73119b644AE5ecd22b376] =
            LenderTokens(0x13eB80FDBe5C5f4a7039728E258A6f05fb3B912b, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x853d955aCEf822Db058eb8505911ED77F175b99e] =
            LenderTokens(0x4fAfbDc4F2a9876Bd1764827b26fb8dc4FD1dB95, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32] =
            LenderTokens(0x17142a05fe678e9584FA1d88EfAC1bF181bF7ABe, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83] =
            LenderTokens(0x256AdDBe0a387c98f487e44b85c29eb983413c5e, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x657e8C867D8B37dCC18fA4Caead9C45EB088C642] =
            LenderTokens(0x325cEB02fe1C2fF816A83a5770eA0E88e2faEcF2, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x8236a87084f8B84306f72007F36F2618A5634494] =
            LenderTokens(0x25C20e6e110A1cE3FEbaCC8b7E48368c7b2F0C91, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xdC035D45d973E3EC169d2276DDab16f1e407384F] =
            LenderTokens(0x0c6B19287999f1e31a5c0a44393b24B62D2C0468, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD] =
            LenderTokens(0xE36Ae842DbbD7aE372ebA02C8239cd431cC063d6, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xba100000625a3754423978a60c9317c58a424e3D] =
            LenderTokens(0x0Ec5488e4F8f319213a14cab188E01fB8517Faa8, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xBe53A109B494E5c9f97b9Cd39Fe969BE68BF6204] =
            LenderTokens(0xf87c0a64dc3a8622D6c63265FA29137788163879, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x310B7Ea7475A0B449Cfd73bE81522F1B88eFAFaa] =
            LenderTokens(0x475d0C68a8CD275c15D1F01F4f291804E445F677, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x182863131F9a4630fF9E27830d945B1413e347E8] =
            LenderTokens(0x520d67226Bc904aC122dcE66ed2f8f61AA1ED764, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0xc56413869c6CDf96496f2b1eF801fEDBdFA7dDB0] =
            LenderTokens(0xba3916302cBA4aBcB51a01e706fC6051AaF272A0, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x917ceE801a67f933F2e6b33fC0cD1ED2d5909D88] =
            LenderTokens(0xc42E4bfb996ED35235bda505430cBE404Eb49F77, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x9D39A5DE30e57443BfF2A8307A4256c8797A3497] =
            LenderTokens(0xa836ce315b7A6Bb19397Ee996551659B1D92298e, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x4c9EDD5852cd905f086C759E8383e09bff1E68B3] =
            LenderTokens(0xa0EE2bAA024cC3AA1BC9395522D07B7970Ca75b3, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS][0x18084fbA666a33d37592fA2633fD49a74DD93a88] =
            LenderTokens(0x5e35C312862d53FD566737892aDCf010cb4928F7, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.VENUS][0x68f180fcCe6836688e9084f035309E29Bf0A2095] =
            LenderTokens(0x9EfdCfC2373f81D3DF24647B1c46e15268884c46, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.VENUS][0x4200000000000000000000000000000000000006] =
            LenderTokens(0x66d5AE25731Ce99D46770745385e662C8e0B4025, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.VENUS][0x94b008aA00579c1307B0EF2c499aD98a8ce58e58] =
            LenderTokens(0x37ac9731B0B02df54975cd0c7240e0977a051721, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.VENUS][0x4200000000000000000000000000000000000042] =
            LenderTokens(0x6b846E3418455804C1920fA4CC7a31A51C659A2D, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.VENUS][0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85] =
            LenderTokens(0x1C9406ee95B7af55F005996947b19F91B6D55b15, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0xfD5840Cd36d94D7229439859C0112a4185BC0255, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56] =
            LenderTokens(0x95c78222B3D6e262426483D42CfA53685A67Ab9D, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x47BEAd2563dCBf3bF2c9407fEa4dC236fAbA485A] =
            LenderTokens(0x2fF3d0F6990a40261c66E1ff2017aCBc282EB6d0, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63] =
            LenderTokens(0x151B1e2635A717bcDc836ECd6FbB62B674FE3E1D, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xA07c5b74C9B40447a954e1466938b865b6BBea36, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(0xf508fCD89b8bd15579dc79A6827cB4686A3592c8, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x4338665CBB7B2485A8855A139b75D5e34AB0DB94] =
            LenderTokens(0x57A5297F2cB2c0AaC9D554660acd6D385Ab50c6B, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE] =
            LenderTokens(0xB248a295732e0225acd3337607cc01068e3b9c10, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf] =
            LenderTokens(0x5F0388EBc2B94FA8E123F404b79cCF5f40b29176, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402] =
            LenderTokens(0x1610bc33319e9398de5f57B33a5b184c806aD217, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD] =
            LenderTokens(0x650b940a1033B8A1b1873f78730FcFC73ec11f1f, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3] =
            LenderTokens(0x334b3eCB4DCa3593BCCC3c7EBD1A1C1d1780FBF1, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153] =
            LenderTokens(0xf91d58b5aE142DAcC749f58A49FCBac340Cb0343, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x250632378E573c6Be1AC2f97Fcdf00515d0Aa91B] =
            LenderTokens(0x972207A639CC1B374B893cc33Fa251b55CEB7c07, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x20bff4bbEDa07536FF00e073bd8359E5D80D733d] =
            LenderTokens(0xeBD0070237a0713E8D94fEf1B728d3d993d290ef, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47] =
            LenderTokens(0x9A0AF7FDb2065Ce470D72664DE73cAE409dA28Ec, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xbA2aE424d960c26247Dd6c32edC70B295c744C43] =
            LenderTokens(0xec3422Ef92B2fb59e84c8B02Ba73F1fE84Ed8D71, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xCC42724C6683B7E57334c4E856f4c9965ED682bD] =
            LenderTokens(0x5c9476FcD6a4F9a3654139721c949c2233bBbBc8, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82] =
            LenderTokens(0x86aC3974e2BD0d60825230fa6F355fF11409df5c, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xfb6115445Bff7b52FeB98650C87f44907E58f802] =
            LenderTokens(0x26DA28954763B92139ED49283625ceCAf52C6f94, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x14016E85a25aeb13065688cAFB43044C2ef86784] =
            LenderTokens(0x08CEB3F4a7ed3500cA0982bcd0FC7816688084c3, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x85EAC5Ac2F758618dFa09bDbe0cf174e7d574D5B] =
            LenderTokens(0x61eDcFe8Dd6bA3c891CB9bEc2dc7657B3B422E93, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x3d4350cD54aeF9f9b2C29435e0fa809957B3F30a] =
            LenderTokens(0x78366446547D062f45b4C0f320cDaa6d710D87bb, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x156ab3346823B651294766e23e6Cf87254d68962] =
            LenderTokens(0xb91A659E88B51474767CD97EF3196A3e7cEDD2c8, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3] =
            LenderTokens(0xC5D3466aA484B040eE977073fcF337f2c00071c1, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xa2E3356610840701BDf5611a53974510Ae27E2e1] =
            LenderTokens(0x6CFdEc747f37DAf3b87a35a1D9c8AD3063A1A8A0, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9] =
            LenderTokens(0xBf762cd5991cA1DCdDaC9ae5C638F5B5Dc3Bee6E, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xBf5140A22578168FD562DCcF235E5D43A02ce9B1] =
            LenderTokens(0x27FF564707786720C71A2e5c1490A63266683612, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409] =
            LenderTokens(0xC4eF4229FEc74Ccfe17B2bdeF7715fAC740BA0ba, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x4B0F1812e5Df2A09796481Ff14017e6005508003] =
            LenderTokens(0x4d41a36D04D97785bcEA57b057C412b278e6Edcc, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7] =
            LenderTokens(0xf841cb62c19fCd4fF5CD0AaB5939f3140BaaC3Ea, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xF4C8E32EaDEC4BFe97E0F595AdD0f4450a863a11] =
            LenderTokens(0x86e06EAfa6A1eA631Eab51DE500E3D474933739f, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x570A5D26f7765Ecb712C0924E4De545B89fD43dF] =
            LenderTokens(0xBf515bA4D1b52FFdCeaBF20d31D705Ce789F2cEC, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5] =
            LenderTokens(0x689E0daB47Ab16bcae87Ec18491692BF621Dc6Ab, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xDD809435ba6c9d6903730f923038801781cA66ce] =
            LenderTokens(0x9e4E5fed5Ac5B9F732d0D850A615206330Bf1866, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] =
            LenderTokens(0x699658323d58eE25c69F1a29d476946ab011bD18, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] =
            LenderTokens(0x74ca6930108F775CC667894EEa33843e691680d7, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d] =
            LenderTokens(0x0C1DA220D301155b87318B90692Da8dc43B67340, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x1346b618dC92810EC74163e4c27004c921D446a5] =
            LenderTokens(0xd804dE60aFD05EE6B89aab5D152258fD461B07D5, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x77734e70b6E88b4d82fE632a168EDf6e700912b6] =
            LenderTokens(0xCC1dB43a06d97f736C7B045AedD03C6707c09BDF, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] =
            LenderTokens(0x6bCa74586218dB34cdB402295796b79663d816e9, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0x607C834cfb7FCBbb341Cbe23f77A6E83bCf3F55c] =
            LenderTokens(0x6D0cDb3355c93A0cD20071aBbb3622731a95c73E, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B] =
            LenderTokens(0x89c910Eb8c90df818b4649b508Ba22130Dc73Adc, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xcE24439F2D9C6a2289F741120FE202248B666666] =
            LenderTokens(0x3d5E269787d562b74aCC55F18Bd26C5D09Fa245E, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS][0xe052823b4aefc6e230FAf46231A57d0905E30AE0] =
            LenderTokens(0x6d3BD68E90B42615cb5abF4B8DE92b154ADc435e, address(0), address(0));
        lendingTokens[Chains.UNICHAIN][Lenders.VENUS][0x4200000000000000000000000000000000000006] =
            LenderTokens(0xc219BC179C7cDb37eACB03f993f9fDc2495e3374, address(0), address(0));
        lendingTokens[Chains.UNICHAIN][Lenders.VENUS][0x078D782b760474a361dDA0AF3839290b0EF57AD6] =
            LenderTokens(0xB953f92B9f759d97d2F2Dec10A8A3cf75fcE3A95, address(0), address(0));
        lendingTokens[Chains.UNICHAIN][Lenders.VENUS][0x8f187aA05619a017077f5308904739877ce9eA21] =
            LenderTokens(0x67716D6Bf76170Af816F5735e14c4d44D0B05eD2, address(0), address(0));
        lendingTokens[Chains.UNICHAIN][Lenders.VENUS][0x7DCC39B4d1C53CB31e1aBc0e358b43987FEF80f7] =
            LenderTokens(0x0170398083eb0D0387709523baFCA6426146C218, address(0), address(0));
        lendingTokens[Chains.UNICHAIN][Lenders.VENUS][0xc02fE7317D4eb8753a02c35fe019786854A92001] =
            LenderTokens(0xbEC19Bef402C697a7be315d3e59E5F65b89Fa1BB, address(0), address(0));
        lendingTokens[Chains.UNICHAIN][Lenders.VENUS][0x0555E30da8f98308EdB960aa94C0Db47230d2B9c] =
            LenderTokens(0x68e2A6F7257FAc2F5a557b9E83E1fE6D5B408CE5, address(0), address(0));
        lendingTokens[Chains.UNICHAIN][Lenders.VENUS][0x9151434b16b9763660705744891fA906F660EcC5] =
            LenderTokens(0xDa7Ce7Ba016d266645712e2e4Ebc6cC75eA8E4CD, address(0), address(0));
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.VENUS][0x7c6b91D9Be155A6Db01f749217d76fF02A7227F2] =
            LenderTokens(0xED827b80Bd838192EA95002C01B5c6dA8354219a, address(0), address(0));
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.VENUS][0xE7798f023fC62146e8Aa1b36Da45fb70855a77Ea] =
            LenderTokens(0x509e81eF638D489936FA85BC58F52Df01190d26C, address(0), address(0));
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.VENUS][0x9e5AAC1Ba1a2e6aEd6b32689DFcF62A509Ca96f3] =
            LenderTokens(0xb7a01Ba126830692238521a1aA7E7A7509410b8e, address(0), address(0));
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.VENUS][0x4200000000000000000000000000000000000006] =
            LenderTokens(0x53d11cB8A0e5320Cd7229C3acc80d1A0707F2672, address(0), address(0));
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.VENUS][0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb] =
            LenderTokens(0x13B492B8A03d072Bab5C54AC91Dba5b830a50917, address(0), address(0));
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.VENUS][0xBBeB516fb02a01611cBBE0453Fe3c580D7281011] =
            LenderTokens(0xAF8fD83cFCbe963211FAaf1847F0F217F80B4719, address(0), address(0));
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.VENUS][0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91] =
            LenderTokens(0x1Fa916C27c7C2c4602124A14C77Dbb40a5FF1BE8, address(0), address(0));
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.VENUS][0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4] =
            LenderTokens(0x1aF23bD57c62A99C59aD48236553D0Dd11e49D2D, address(0), address(0));
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.VENUS][0x493257fD37EDB34451f62EDf8D2a0C418852bA4C] =
            LenderTokens(0x69cDA960E3b20DFD480866fFfd377Ebe40bd0A46, address(0), address(0));
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.VENUS][0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E] =
            LenderTokens(0x697a70779C1A03Ba2BD28b7627a902BFf831b616, address(0), address(0));
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.VENUS][0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4] =
            LenderTokens(0x84064c058F2EFea4AB648bB6Bd7e40f83fFDe39a, address(0), address(0));
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.VENUS][0xA900cbE7739c96D2B153a273953620A701d5442b] =
            LenderTokens(0x183dE3C349fCf546aAe925E1c7F364EA6FB4033c, address(0), address(0));
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.VENUS][0x703b52F2b28fEbcB60E1372858AF5b18849FE867] =
            LenderTokens(0x03CAd66259f7F34EE075f8B62D133563D249eDa4, address(0), address(0));
        lendingTokens[Chains.ZKSYNC_MAINNET][Lenders.VENUS][0xb72207E1FB50f341415999732A20B6D25d8127aa] =
            LenderTokens(0xCEb7Da150d16aCE58F090754feF2775C23C8b631, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.VENUS][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] =
            LenderTokens(0x7bBd1005bB24Ec84705b04e1f2DfcCad533b6D72, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.VENUS][0x4200000000000000000000000000000000000006] =
            LenderTokens(0xEB8A79bD44cF4500943bf94a2b4434c95C008599, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.VENUS][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] =
            LenderTokens(0x3cb752d175740043Ec463673094e06ACDa2F9a2e, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.VENUS][0x7FcD174E80f264448ebeE8c88a7C4476AAF58Ea6] =
            LenderTokens(0x75201D81B3B0b9D17b179118837Be37f64fc4930, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.VENUS][0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452] =
            LenderTokens(0x133d3BCD77158D125B75A17Cb517fFD4B4BE64C5, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.VENUS][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] =
            LenderTokens(0xaDa57840B372D4c28623E87FC175dE8490792811, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.VENUS][0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] =
            LenderTokens(0x68a34332983f4Bf866768DD6D6E638b02eF5e1f0, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.VENUS][0xaf88d065e77c8cC2239327C5EDb3A432268e5831] =
            LenderTokens(0x7D8609f8da70fF9027E9bc5229Af4F6727662707, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.VENUS][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] =
            LenderTokens(0xB9F9117d4200dC296F9AcD1e8bE1937df834a2fD, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.VENUS][0x912CE59144191C1204E64559FE8253a0e49E6548] =
            LenderTokens(0xAeB0FEd69354f34831fe1D16475D9A83ddaCaDA6, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.VENUS] = 0x687a01ecF6d3907658f7A7c714749fAC32336D1B;
        lendingControllers[Chains.OP_MAINNET][Lenders.VENUS] = 0x5593FF68bE84C966821eEf5F0a988C285D5B7CeC;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS] = 0xfD36E2c2a6789Db23113685031d7F16329158384;
        lendingControllers[Chains.UNICHAIN][Lenders.VENUS] = 0xe22af1e6b78318e1Fe1053Edbd7209b8Fc62c4Fe;
        lendingControllers[Chains.OPBNB_MAINNET][Lenders.VENUS] = 0xD6e3E2A1d8d95caE355D15b3b9f8E5c2511874dd;
        lendingControllers[Chains.ZKSYNC_MAINNET][Lenders.VENUS] = 0xddE4D098D9995B659724ae6d5E3FB9681Ac941B1;
        lendingControllers[Chains.BASE][Lenders.VENUS] = 0x0C7973F9598AA62f9e03B94E92C967fD5437426C;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.VENUS] = 0x317c1A5739F39046E20b08ac9BeEa3f10fD43326;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETH][0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0] =
            LenderTokens(0x4a240F0ee138697726C8a3E43eFE6Ac3593432CB, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETH][0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] =
            LenderTokens(0xc82780Db1257C788F262FBbDA960B3706Dfdcaf2, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETH][0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee] =
            LenderTokens(0xb4933AF59868986316Ed37fa865C829Eba2df0C7, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETH][0x6ee2b5E19ECBa773a352E5B21415Dc419A700d1d] =
            LenderTokens(0x76697f8eaeA4bE01C678376aAb97498Ee8f80D5C, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETH][0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7] =
            LenderTokens(0xDB6C345f864883a8F4cae87852Ac342589E76D1B, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETH][0xac3E018457B222d93114458476f3E3416Abbe38F] =
            LenderTokens(0xF9E9Fe17C00a8B96a8ac20c4E344C8688D7b947E, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETH][0xbf5495Efe5DB9ce00f80364C8B423567e58d2110] =
            LenderTokens(0xA854D35664c658280fFf27B6eDC6C4195c3229B3, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETH][0x917ceE801a67f933F2e6b33fC0cD1ED2d5909D88] =
            LenderTokens(0xEF26C64bC06A8dE4CA5D31f119835f9A1d9433b9, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETH][0xD9A442856C234a39a81a089C06451EBAa4306a72] =
            LenderTokens(0xE0ee5dDeBFe0abe0a4Af50299D68b74Cec31668e, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.VENUS_ETH][0x5979D7b546E38E414F7E9822514be443A4800529] =
            LenderTokens(0x9df6B5132135f14719696bBAe3C54BAb272fDb16, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.VENUS_ETH][0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe] =
            LenderTokens(0x246a35E79a3a0618535A469aDaF5091cAA9f7E88, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.VENUS_ETH][0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] =
            LenderTokens(0x39D6d13Ea59548637104E40e729E4aABE27FE106, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETH] = 0xF522cd0360EF8c2FF48B648d53EA1717Ec0F3Ac3;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.VENUS_ETH] = 0x52bAB1aF7Ff770551BD05b9FC2329a0Bf5E23F16;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BTC][0x541B5eEAC7D4434C8f87e2d32019d67611179606] =
            LenderTokens(0x02243F036897E3bE1cce1E540FA362fd58749149, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BTC][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(0x8F2AE20b25c327714248C95dFD3b02815cC82302, address(0), address(0));
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BTC] = 0x9DF11376Cf28867E2B0741348044780FbB7cb1d6;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BNB][0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827] =
            LenderTokens(0xBfe25459BA784e70E2D7a718Be99a1f3521cA17f, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BNB][0x1bdd3Cf7F79cfB8EdbB955f20ad99211551BA275] =
            LenderTokens(0x5E21bF67a6af41c74C1773E4b473ca5ce8fd3791, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BNB][0xc2E9d07F66A89c44062459A47a0D2Dc038E4fb16] =
            LenderTokens(0xcc5D9e502574cda17215E70bC0B4546663785227, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BNB][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] =
            LenderTokens(0xe10E80B7FD3a29fE46E16C30CC8F4dd938B742e2, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BNB][0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B] =
            LenderTokens(0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BNB][0xE8F1C9804770e11Ab73395bE54686Ad656601E9e] =
            LenderTokens(0xA537ACf381b12Bbb91C58398b66D1D220f1C77c8, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BNB][0x77734e70b6E88b4d82fE632a168EDf6e700912b6] =
            LenderTokens(0x4A50a0a1c832190362e1491D5bB464b1bc2Bd288, address(0), address(0));
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_BNB] = 0xd933909A4a2b7A4638903028f44D1d38ce27c352;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_GAMEFI][0x12BB890508c125661E03b09EC06E404bc9289040] =
            LenderTokens(0xE5FE5527A5b76C75eedE77FdFA6B80D52444A465, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_GAMEFI][0xfb5B838b6cfEEdC2873aB27866079AC55363D37E] =
            LenderTokens(0xc353B7a1E13dDba393B5E120D4169Da7185aA2cb, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_GAMEFI][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0x4978591f17670A846137d9d613e333C38dc68A37, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_GAMEFI][0xd17479997F34dd9156Deef8F95A52D81D265be9c] =
            LenderTokens(0x9f2FD23bd0A5E08C5f2b9DD6CF9C96Bfb5fA515C, address(0), address(0));
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_GAMEFI] = 0x1b43ea8622e76627B81665B1eCeBB4867566B963;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_MEME][0xc748673057861a797275CD8A068AbB95A902e8de] =
            LenderTokens(0x52eD99Cd0a56d60451dD4314058854bc0845bbB5, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_MEME][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0x4a9613D06a241B76b81d3777FCe3DDd1F61D4Bd0, address(0), address(0));
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_MEME] = 0x33B6fa34cd23e5aeeD1B112d5988B026b8A5567d;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_STABLE][0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5] =
            LenderTokens(0xCa2D81AA7C09A1a025De797600A7081146dceEd9, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_STABLE][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0x5e3072305F9caE1c7A82F6Fe9E38811c74922c3B, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_STABLE][0xd17479997F34dd9156Deef8F95A52D81D265be9c] =
            LenderTokens(0xc3a45ad8812189cAb659aD99E64B1376f6aCD035, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_STABLE][0x12f31B73D812C6Bb0d735a218c086d44D5fe5f89] =
            LenderTokens(0x795DE779Be00Ea46eA97a28BDD38d9ED570BCF0F, address(0), address(0));
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_STABLE] = 0x94c1495cD4c557f1560Cbd68EAB0d197e6291571;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_TRON][0x352Cb5E19b12FC216548a2677bD0fce83BaE434B] =
            LenderTokens(0x49c26e12959345472E2Fd95E5f79F8381058d3Ee, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_TRON][0xaeF0d72a118ce24feE3cD1d43d383897D05B4e99] =
            LenderTokens(0xb114cfA615c828D88021a41bFc524B800E64a9D5, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_TRON][0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3] =
            LenderTokens(0x836beb2cB723C498136e1119248436A645845F4E, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_TRON][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0x281E5378f99A4bc55b295ABc0A3E7eD32Deba059, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_TRON][0xd17479997F34dd9156Deef8F95A52D81D265be9c] =
            LenderTokens(0xf1da185CCe5BeD1BeBbb3007Ef738Ea4224025F7, address(0), address(0));
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_TRON] = 0x23b4404E4E5eC5FF5a6FFb70B7d14E3FabF237B0;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETHENA][0x8A47b431A7D947c6a3ED6E42d501803615a97EAa] =
            LenderTokens(0x62D9E2010Cff87Bae05B91d5E04605ef864ABc3B, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETHENA][0xE00bd3Df25fb187d6ABBB620b3dfd19839947b81] =
            LenderTokens(0xCca202a95E8096315E3F19E46e19E1b326634889, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETHENA][0x9D39A5DE30e57443BfF2A8307A4256c8797A3497] =
            LenderTokens(0x0792b9c60C728C1D2Fd6665b3D7A08762a9b28e0, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETHENA][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(0xa8e7f9473635a5CB79646f14356a9Fc394CA111A, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.VENUS_ETHENA] = 0x562d2b6FF1dbf5f63E233662416782318cC081E4;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_DEFI][0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827] =
            LenderTokens(0x53728FD51060a85ac41974C6C3Eb1DaE42776723, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_DEFI][0x965F527D9159dCe6288a2219DB51fc6Eef120dD1] =
            LenderTokens(0x8f657dFD3a1354DEB4545765fE6840cc54AFd379, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_DEFI][0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F] =
            LenderTokens(0x02c5Fb0F26761093D297165e902e96D08576D344, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_DEFI][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0x1D8bBDE12B6b34140604E18e9f9c6e14deC16854, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_DEFI][0xd17479997F34dd9156Deef8F95A52D81D265be9c] =
            LenderTokens(0xA615467caE6B9E0bb98BC04B4411d9296fd1dFa0, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_DEFI][0xf307910A4c7bbc79691fD374889b36d8531B08e3] =
            LenderTokens(0x19CE11C8817a1828D1d357DFBF62dCf5b0B2A362, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_DEFI][0x4B0F1812e5Df2A09796481Ff14017e6005508003] =
            LenderTokens(0x736bf1D21A28b5DC19A1aC8cA71Fc2856C23c03F, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_DEFI][0xCa6d678e74f553f0E59cccC03ae644a3c2c5EE7d] =
            LenderTokens(0xFf1112ba7f88a53D4D23ED4e14A117A2aE17C6be, address(0), address(0));
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.VENUS_DEFI] = 0x3344417c9360b963ca93A4e8305361AEde340Ab9;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_CURVE][0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E] =
            LenderTokens(0x2d499800239C4CD3012473Cb1EAE33562F0A6933, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.VENUS_CURVE][0xD533a949740bb3306d119CC777fa900bA034cd52] =
            LenderTokens(0x30aD10Bd5Be62CAb37863C2BfcC6E8fb4fD85BDa, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.VENUS_CURVE] = 0x67aA3eCc5831a65A5Ba7be76BED3B5dc7DB60796;
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0x50c42dEAcD8Fc9773493ED674b675bE577f2634b] =
            LenderTokens(0x52260aD4cb690c6b22629166f4D181477a9c157C, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0x29219dd400f2Bf60E5a23d13Be72B486D4038894] =
            LenderTokens(0x87C69a8fB7F04b7890F48A1577a83788683A2036, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38] =
            LenderTokens(0xc96a4cd13C8fCB9886DE0CdF7152B9F930D67E96, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0xE5DA20F15420aD15DE0fa650600aFc998bbE3955] =
            LenderTokens(0xe544e51bF20AB186B6b7b1A9095C8BC1E3f203f5, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0xd3DCe716f3eF535C5Ff8d041c1A41C3bd89b97aE] =
            LenderTokens(0x6770aF27FC5233A70B85BFf631061400a09d2e1c, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0x3bcE5CB273F0F148010BbEa2470e7b5df84C7812] =
            LenderTokens(0x04568dB12221D60C93e1db9Cb7933aD6b7c4280C, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0xBe27993204Ec64238F71A527B4c4D5F4949034C3] =
            LenderTokens(0x2df4dC7cf362E56e128816BE0f1F4CEb07904Bb0, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0xd2901D474b351bC6eE7b119f9c920863B0F781b2] =
            LenderTokens(0xAb1fbEE94D9ba79269B3e479cE5D78C60F148716, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0x6202B9f02E30E5e1c62Cc01E4305450E5d83b926] =
            LenderTokens(0x13d79435F306D155CA2b9Af77234c84f80506045, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0xe715cbA7B5cCb33790ceBFF1436809d36cb17E57] =
            LenderTokens(0x6fFD0B54E2B74FdaFBceC853145372066FE98fC1, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0xAaAaaAAac311D0572Bffb4772fe985A750E88805] =
            LenderTokens(0x1D801dC616C79c499C5d38c998Ef2D0D6Cf868e8, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0x57203A8AeC5C03Dd48050CD599DeB24Ba669aD95] =
            LenderTokens(0x3f0c9dcCa72058950327b5D4a5783fB0CbA520Ce, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0xd02962DC00A058a00Fc07A8AA9F760ab6D9Bd163] =
            LenderTokens(0x44D5602E26c1C1fD5F284036023e2750F3d855a0, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0xB9EA44D1aa76D5Cfd475C2800E186d3Dea2141a4] =
            LenderTokens(0x14515De791C58C430b85D837df3E3ac455B88fEd, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0x3D75F2BB8aBcDBd1e27443cB5CBCE8A668046C81] =
            LenderTokens(0x05C132E75D2775Ca4257FCf824169d99d593eBF1, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS][0xC326D1505ce0492276f646B03FE460c43A892185] =
            LenderTokens(0x0e528ae2376Bf60B5c6e4c62aE461F422052b457, address(0), address(0));
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.ENCLABS][0x9895D81bB462A195b4922ED7De0e3ACD007c32CB] =
            LenderTokens(0x87C69a8fB7F04b7890F48A1577a83788683A2036, address(0), address(0));
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.ENCLABS][0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb] =
            LenderTokens(0xc96a4cd13C8fCB9886DE0CdF7152B9F930D67E96, address(0), address(0));
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.ENCLABS][0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34] =
            LenderTokens(0x172bC36d3f092453cE6F3F9B30F1d6Ac365C4FfD, address(0), address(0));
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.ENCLABS][0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2] =
            LenderTokens(0x4cB42eA31c959618Bf8Fe50E1a10f768EF1A5A36, address(0), address(0));
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.ENCLABS][0x6100E367285b01F48D07953803A2d8dCA5D19873] =
            LenderTokens(0xF690a1e115F7A290D228D58a8c0e22b3Aa7Efd48, address(0), address(0));
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.ENCLABS][0x6eAf19b2FC24552925dB245F9Ff613157a7dbb4C] =
            LenderTokens(0xbaD1e57EbF56baCb7c39E3ddcD8Fe4DCC2fd4198, address(0), address(0));
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.ENCLABS][0xf91c31299E998C5127Bc5F11e4a657FC0cF358CD] =
            LenderTokens(0xa82846aEFCC2DE156b61F7f5c35C5a4680D5D297, address(0), address(0));
        lendingTokens[Chains.PLASMA_MAINNET][Lenders.ENCLABS][0x616185600989Bf8339b58aC9e539d49536598343] =
            LenderTokens(0x213824b154458Edb345921bB864d741e285b99F4, address(0), address(0));
        lendingControllers[Chains.SONIC_MAINNET][Lenders.ENCLABS] = 0xccAdFCFaa71407707fb3dC93D7d83950171aA2c9;
        lendingControllers[Chains.PLASMA_MAINNET][Lenders.ENCLABS] = 0xA3F48548562A30A33257A752d396A20B4413E8E3;
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_LST][0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38] =
            LenderTokens(0x876e062420fB9a4861968EC2E0FF91be88142343, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_LST][0x29219dd400f2Bf60E5a23d13Be72B486D4038894] =
            LenderTokens(0xb64b8585CeCe0E314d344c7f6437D97bF1eB0FE7, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_LST][0x9F0dF7799f6FDAd409300080cfF680f5A23df4b1] =
            LenderTokens(0x7FD79432cC704582235DF11b92b783f07ED40e13, address(0), address(0));
        lendingControllers[Chains.SONIC_MAINNET][Lenders.ENCLABS_LST] = 0x1dB5134Ee31278809b2d85Fab2796141DBe0d041;
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_PT_ETH][0xd3DCe716f3eF535C5Ff8d041c1A41C3bd89b97aE] =
            LenderTokens(0x7D47cBf5FE9cCF2F99D0C2E8a3c59FB3498bc21b, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_PT_ETH][0x7002383d2305B8f3b2b7786F50C13D132A22076d] =
            LenderTokens(0xD1e8eC6EaeD325006731F816f41fd5483373A8f2, address(0), address(0));
        lendingControllers[Chains.SONIC_MAINNET][Lenders.ENCLABS_PT_ETH] = 0x26190C71c27e089533186338d16abB2ba9528969;
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_PT_USD][0x3bcE5CB273F0F148010BbEa2470e7b5df84C7812] =
            LenderTokens(0x8bC35Aee955E2D05C13e4Ff503294676508668B5, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_PT_USD][0x3A7Ba84bBe869eD318e654DD9B6fF3cF6d531E91] =
            LenderTokens(0xBFF8cf17b04A057D9A8Ce5796a85c60D1F614eaB, address(0), address(0));
        lendingControllers[Chains.SONIC_MAINNET][Lenders.ENCLABS_PT_USD] = 0x62C627E08F996D7d7563E135E527f422Fee34786;
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_SONIC_ECO][0x3a516e01f82c1e18916ED69a81Dd498eF64bB157] =
            LenderTokens(0xdDe5262d257BB26DCd6Ea482f489078eD020CD7C, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_SONIC_ECO][0x9fDbC3f8Abc05Fa8f3Ad3C17D2F806c1230c4564] =
            LenderTokens(0xf50466320de462627f929f7F631206653c10C0b7, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_SONIC_ECO][0x29219dd400f2Bf60E5a23d13Be72B486D4038894] =
            LenderTokens(0x76463494e39e259470301aA1c2B48E2Ca4Ac9b13, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_SONIC_ECO][0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38] =
            LenderTokens(0x730935e4F45610Ca07DBA1B5f3649Fa34464d5eD, address(0), address(0));
        lendingTokens[Chains.SONIC_MAINNET][Lenders.ENCLABS_SONIC_ECO][0xA04BC7140c26fc9BB1F36B1A604C7A5a88fb0E70] =
            LenderTokens(0x0Cd08016673592244B9c3d4A2d71F5E973Dd3380, address(0), address(0));
        lendingControllers[Chains.SONIC_MAINNET][Lenders.ENCLABS_SONIC_ECO] = 0x0c9425eCFbd64a96D306f36e8281EE5308446d31;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SEGMENT][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(0x8969b89D5f38359fBE95Bbe392f5ad82dd93e226, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SEGMENT][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0x44B1E0f4533FD155B9859a9DB292C90E5B300119, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SEGMENT][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(0x3821175E59CD0acDa6c5Fd3eBB618b204e5D7eed, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SEGMENT][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(0x12CD46B96fe0D86E396248a623B81fD84dD0F61d, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SEGMENT][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x5fceA94B96858048433359BB5278a402363328C3, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SEGMENT][0x80137510979822322193FC997d400D5A6C747bf7] =
            LenderTokens(0x24a8117Bf6F4a5BE6759918f7C111f279a999ef3, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SEGMENT][0xb4818BB69478730EF4e33Cc068dD94278e2766cB] =
            LenderTokens(0xF8adF750633b8f95aA00BDbe2ED2924b6c386004, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SEGMENT][0x64274835D88F5c0215da8AADd9A5f2D2A2569381] =
            LenderTokens(0x07B4fbc9B123AC8eEd171372969dD55410946d75, address(0), address(0));
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.SEGMENT][0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb] =
            LenderTokens(0xfe62ba7400d902A9773dA9F7469dA457cF54a565, address(0), address(0));
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.SEGMENT][0x9e5AAC1Ba1a2e6aEd6b32689DFcF62A509Ca96f3] =
            LenderTokens(0x7ADd376cF7b33B7d09B0F0f4Ef0a741C3cB95102, address(0), address(0));
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.SEGMENT][0xE7798f023fC62146e8Aa1b36Da45fb70855a77Ea] =
            LenderTokens(0x81b98b2896f1F262714F12Be36264AA8E02A08D2, address(0), address(0));
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.SEGMENT][0x7c6b91D9Be155A6Db01f749217d76fF02A7227F2] =
            LenderTokens(0x567558167F102BB45c0437F1Fd5a527c5c534c3C, address(0), address(0));
        lendingTokens[Chains.OPBNB_MAINNET][Lenders.SEGMENT][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x7e844423510A5081DE839e600F7960C7cE84eb82, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xb57A4b3ccE8d999A1e6B0357c0a31C3808401B42, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0x900101d06A7426441Ae63e9AB3B9b0F63Be145F1] =
            LenderTokens(0x21a75630d3D01183D94413994352deFD22D598Dc, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0xb3A8F0f0da9ffC65318aA39E55079796093029AD] =
            LenderTokens(0x0Db32EBAE3daFE7325a3F22b971895C6693437d0, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0x8034aB88C3512246Bf7894f57C834DdDBd1De01F] =
            LenderTokens(0xe14EEb2f56733F86e183a446e60608a3c33F1fb4, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0x5B1Fb849f1F76217246B8AAAC053b5C7b15b7dc3] =
            LenderTokens(0x2a8731e84Aa080BAcb5A9AC56109bC7baA4a47e0, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0xe04d21d999FaEDf1e72AdE6629e20A11a1ed14FA] =
            LenderTokens(0xDD80DDA3A7B1f462FBf7089EB24332727ef9E00B, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0xeAB3aC417c4d6dF6b143346a46fEe1B847B50296] =
            LenderTokens(0x831854CeBe84cfC6abFd603503Bf591A5e41d998, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0x7A6888c85eDBA8E38F6C7E0485212da602761C08] =
            LenderTokens(0x4FB6D66bA7b10bF6b34c7056F745Ef7415777A7D, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0x2297aEbD383787A160DD0d9F71508148769342E3] =
            LenderTokens(0x92B609B64258Dd92D1D47EC9BdC3C800fE4F6c96, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0xa4151B2B3e269645181dCcF2D426cE75fcbDeca9] =
            LenderTokens(0x2f98ceC447ECE713eF166BD5f76139d66C141bf3, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0x5832f53d147b3d6Cd4578B9CBD62425C7ea9d0Bd] =
            LenderTokens(0x96ea658f324a0797A3978F5000fe5BB53428536A, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0x70727228DB8C7491bF0aD42C180dbf8D95B257e2] =
            LenderTokens(0x8Da899Be4E67C847163e5D91B76eb3130d6c8A38, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT][0x9410e8052Bc661041e5cB27fDf7d9e9e842af2aa] =
            LenderTokens(0xCBe44f06A270688371780Ce4f78e644e17F3426B, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xd7C6CC5AEf7396182c5D7EbdAc66fF674F3DdcF4, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x05D032ac25d322df992303dCa074EE7392C117b9] =
            LenderTokens(0x7414f14497be308e30ee345A0dcfC43623C179c2, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3] =
            LenderTokens(0x6265C05158f672016B771D6Fb7422823ed2CbcDd, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0xe75D0fB2C24A55cA1e3F96781a2bCC7bdba058F0] =
            LenderTokens(0xc344000a28F00E879c566f1Ec259da24D6279592, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0xBBa2eF945D523C4e2608C9E1214C2Cc64D4fc2e2] =
            LenderTokens(0xD30288EA9873f376016A0250433b7eA375676077, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0xba20a5e63eeEFfFA6fD365E7e540628F8fC61474] =
            LenderTokens(0x2136EbC7Be1E65fDB4A407Ac2874b3d6850A64c2, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x96147A9Ae9a42d7Da551fD2322ca15B71032F342] =
            LenderTokens(0xfB71992Ed470632105F16C331a0C9365C8A4f613, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x85008aE6198BC91aC0735CB5497CF125ddAAc528] =
            LenderTokens(0xfDc94f6018C5764dD6BFCD003EE910D7F3907A1D, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0xB5686c4f60904Ec2BDA6277d6FE1F7cAa8D1b41a] =
            LenderTokens(0xA005eb8730db1E26650C84fE31e95a8aA3aCcF93, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x6c851F501a3F24E29A8E39a29591cddf09369080] =
            LenderTokens(0x83493AE23ceC5DFeC03052FF5CdEd648DefC3336, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x59889b7021243dB5B1e065385F918316cD90D46c] =
            LenderTokens(0x0997f9c07DBDa641DDCc9713d3e63Aa6649aBD98, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x78Fea795cBFcC5fFD6Fb5B845a4f53d25C283bDB] =
            LenderTokens(0x4A98BF3BCDb5324223FB7Ac2F22a460e70Ef2046, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] =
            LenderTokens(0x26e68188d7C6Ed30E194652aad1cC1e65434288c, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0xCC0966D8418d412c599A6421b760a847eB169A8c] =
            LenderTokens(0x5EF2B8fbCc8aea2A9Dbe2729F0acf33E073Fa43e, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x236f8c0a61dA474dB21B693fB2ea7AAB0c803894] =
            LenderTokens(0x7848F0775EebaBbF55cB74490ce6D3673E68773A, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0xC96dE26018A54D51c097160568752c4E3BD6C364] =
            LenderTokens(0x049a96cb83F77BD4165d8A9a033B9d4c41Eff0F4, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0xf7EF136751D7496021858c048FFA4f978C27831A] =
            LenderTokens(0xc2808727f0C8366DAB63f83074D890Dea60C5d99, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0xA45d4121b3D47719FF57a947A9d961539Ba33204] =
            LenderTokens(0xaC431aCa682aea40dA9954568Ea779B43AcC6A39, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x1fCca65fb6Ae3b2758b9b2B394CB227eAE404e1E] =
            LenderTokens(0x811Bb0cC1800e35770495FFe1A6ACB5650A6E83c, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0x2FecE49b79292c2CF6218b2bc657fDDFd2941e18] =
            LenderTokens(0x740Bc032f9c2F7850D4490A6ed34c5c1bBFAf8fA, address(0), address(0));
        lendingTokens[Chains.BOB][Lenders.SEGMENT][0xecf21b335B41f9d5A89f6186A99c19a3c467871f] =
            LenderTokens(0x39E5946DA0AfD4Ee792273e68935C0C9510307a5, address(0), address(0));
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SEGMENT] = 0x57E09c96DAEE58B77dc771B017de015C38060173;
        lendingControllers[Chains.OPBNB_MAINNET][Lenders.SEGMENT] = 0x71ac0e9A7113130280040d0189d0556f45a8CBB5;
        lendingControllers[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SEGMENT] = 0xaba65b87eBEdB2D753b37AeCECD1E168341eE0DD;
        lendingControllers[Chains.BOB][Lenders.SEGMENT] = 0xcD7C4F508652f33295F0aEd075936Cd95A4D2911;
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x5C0401e81Bc07Ca70fAD469b451682c0d747Ef1c, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0x50b7545627a5162F82A992c33b87aDc75187B218] =
            LenderTokens(0xe194c4c5aC32a3C9ffDb358d9Bfd523a0B6d1568, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB] =
            LenderTokens(0x334AD834Cd4481BB02d09615E7c11a00579A7909, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0xc7198437980c041c805A1EDcbA50c1Ce5db95118] =
            LenderTokens(0xc9e5999b8e75C3fEB117F6f73E664b9f3C8ca65C, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0x5947BB275c521040051D82396192181b413227A3] =
            LenderTokens(0x4e9f683A27a6BdAD3FC2764003759277e93696e6, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0xd586E7F844cEa2F87f50152665BCbc2C279D8d70] =
            LenderTokens(0x835866d37AFB8CB8F8334dCCdaf66cf01832Ff5D, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664] =
            LenderTokens(0xBEb5d47A3f720Ec0a390d04b4d41ED7d9688bC7F, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5] =
            LenderTokens(0x35Bd6aedA81a7E5FC7A7832490e71F757b0cD9Ce, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E] =
            LenderTokens(0xB715808a78F6041E46d61Cb123C9B4A27056AE9C, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7] =
            LenderTokens(0xd8fcDa6ec4Bdc547C0827B8804e89aCd817d56EF, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE] =
            LenderTokens(0xF362feA9659cf036792c9cb02f8ff8198E21B4cB, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0x152b9d0FdC40C096757F570A51E494bd4b943E50] =
            LenderTokens(0x89a415b3D20098E6A6C8f7a59001C67BD3129821, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0x9C9e5fD8bbc25984B178FdCE6117Defa39d2db39] =
            LenderTokens(0x872670CcAe8C19557cC9443Eff587D7086b8043A, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a] =
            LenderTokens(0x190D94613A09ad7931FcD17CD6A8F9B6B47ad414, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI][0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD] =
            LenderTokens(0x7FA9442f28948E948e86C0258E361F1208699b41, address(0), address(0));
        lendingControllers[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI] = 0x486Af39519B4Dc9a7fCcd318217352830E8AD9b4;
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI_AVALANCE_ECOSYSTEM][0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E] =
            LenderTokens(0x6B35Eb18BCA06bD7d66a428eeb45aC7d200C1e4E, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI_AVALANCE_ECOSYSTEM][0x420FcA0121DC28039145009570975747295f2329] =
            LenderTokens(0x0eBfebD41e1eA83Be5e911cDCd2730a0CCEE344d, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI_AVALANCE_ECOSYSTEM][0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd] =
            LenderTokens(0x4036cb0D6BF6b5F17Aa4e05191F86D4b1655b0d9, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI_AVALANCE_ECOSYSTEM][0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5] =
            LenderTokens(0x545356e396350D40cDEa888ad73534517399BF96, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI_AVALANCE_ECOSYSTEM][0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a] =
            LenderTokens(0xb7CfB8Ae67E20059021A0D20fc30311a6c67C734, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI_AVALANCE_ECOSYSTEM][0xbc78D84Ba0c46dFe32cf2895a19939c86b81a777] =
            LenderTokens(0x0fFAc5aae14E28E79C5CCc7a335D8C70Ee458A3A, address(0), address(0));
        lendingTokens[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI_AVALANCE_ECOSYSTEM][0x5E0E90E268BC247Cc850c789A0DB0d5c7621fb59] =
            LenderTokens(0x51758d811696aCB994aa993bd3DD088b6C3320F3, address(0), address(0));
        lendingControllers[Chains.AVALANCHE_C_CHAIN][Lenders.BENQI_AVALANCE_ECOSYSTEM] =
        0xD7c4006d33DA2A0A8525791ed212bbCD7Aca763F;
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85] =
            LenderTokens(0x8E08617b0d66359D73Aa11E11017834C29155525, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x94b008aA00579c1307B0EF2c499aD98a8ce58e58] =
            LenderTokens(0xa3A53899EE8f9f6E963437C5B3f805FEc538BF84, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] =
            LenderTokens(0x3FE782C2Fe7668C2F1Eb313ACf3022a31feaD6B2, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x68f180fcCe6836688e9084f035309E29Bf0A2095] =
            LenderTokens(0x6e6CA598A06E609c913551B729a228B023f06fDB, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x4200000000000000000000000000000000000006] =
            LenderTokens(0xb4104C02BBf4E9be85AAa41a62974E4e28D59A33, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb] =
            LenderTokens(0xbb3b1aB66eFB43B10923b87460c0106643B83f9d, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0xadDb6A0412DE1BA0F936DCaeb8Aaa24578dcF3B2] =
            LenderTokens(0x95C84F369bd0251ca903052600A3C96838D78bA1, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x9Bcef72be871e61ED4fBbc7630889beE758eb81D] =
            LenderTokens(0x4c2E35E3eC4A0C82849637BC04A4609Dbe53d321, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x3c8B650257cFb5f272f799F5e2b4e65093a11a05] =
            LenderTokens(0x21d851585840942B0eF9f20d842C00C5f3735eaF, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x4200000000000000000000000000000000000042] =
            LenderTokens(0x9fc345a20541Bf8773988515c5950eD69aF01847, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF] =
            LenderTokens(0xb8051464C8c92209C92F3a4CD9C73746C4c3CFb3, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db] =
            LenderTokens(0x866b838b97Ee43F2c818B3cb5Cc77A0dc22003Fc, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x87eEE96D50Fb761AD85B1c982d28A042169d61b1] =
            LenderTokens(0x181bA797ccF779D8aB339721ED6ee827E758668e, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.MOONWELL][0x01bFF41798a0BcF287b996046Ca68b395DbC1071] =
            LenderTokens(0xed37cD7872c6fe4020982d35104bE7919b8f8b33, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x091608f4e4a15335145be0A279483C0f8E4c7955, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0xFfFFfFff1FcaCBd218EDc0EbA20Fc2308C778080] =
            LenderTokens(0xD22Da948c0aB3A27f5570b604f3ADef5F68211C3, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0x30D2a9F5FDf90ACe8c17952cbb4eE48a55D916A7] =
            LenderTokens(0xc3090f41Eb54A7f18587FD6651d4D3ab477b07a4, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0x1DC78Acda13a8BC4408B207c9E48CDBc096D95e0] =
            LenderTokens(0x24A9d8f1f350d59cB0368D3d52A77dB29c833D1D, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0x8f552a71EFE5eeFc207Bf75485b356A0b3f01eC9] =
            LenderTokens(0x02e9081DfadD37A852F9a73C4d7d69e615E61334, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0x322E86852e492a7Ee17f28a78c663da38FB33bfb] =
            LenderTokens(0x1C55649f73CDA2f72CEf3DD6C5CA3d49EFcF484C, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0xab3f0245B83feB11d15AAffeFD7AD465a59817eD] =
            LenderTokens(0xb6c94b3A378537300387B57ab1cC0d2083f9AeaC, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0xE57eBd2d67B462E9926e04a8e33f01cD0D64346D] =
            LenderTokens(0xaaa20c5a584a9fECdFEDD71E46DA7858B774A9ce, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0x931715FEE2d06333043d11F658C8CE934aC61D0c] =
            LenderTokens(0x744b1756e7651c6D57f5311767EAFE5E931D615b, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0x692C57641fc054c2Ad6551Ccc6566EbA599de1BA] =
            LenderTokens(0x298f2E346b82D69a473BF25f329BDF869e17dEc8, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0xFFFFFFfFea09FB06d082fd1275CD48b191cbCD1d] =
            LenderTokens(0x42A96C0681B74838eC525AdbD13c37f66388f289, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.MOONWELL][0xFFfffffF7D2B0B761Af01Ca8e25242976ac0aD7D] =
            LenderTokens(0x22b1a40e3178fe7C7109eFCc247C5bB2B34ABe32, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA] =
            LenderTokens(0x703843C3379b52F9FF486c9f5892218d2a065cC8, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x4200000000000000000000000000000000000006] =
            LenderTokens(0x628ff693426583D9a7FB391E54366292F509D457, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22] =
            LenderTokens(0x3bf93770f2d4a794c3d9EBEfBAeBAE2a8f09A5E5, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb] =
            LenderTokens(0x73b06D8d18De422E269645eaCe15400DE7462417, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] =
            LenderTokens(0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452] =
            LenderTokens(0x627Fe393Bc6EdDA28e99AE648fD6fF362514304b, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0xB6fe221Fe9EeF5aBa221c348bA20A1Bf5e73624c] =
            LenderTokens(0xCB1DaCd30638ae38F2B94eA64F066045B7D45f44, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x940181a94A35A4569E4529A3CDfB74e38FD98631] =
            LenderTokens(0x73902f619CEB9B31FD8EFecf435CbDf89E369Ba6, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A] =
            LenderTokens(0xb8051464C8c92209C92F3a4CD9C73746C4c3CFb3, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] =
            LenderTokens(0xF877ACaFA28c19b96727966690b2f44d35aD5976, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42] =
            LenderTokens(0xb682c840B5F4FC58B20769E691A6fa1305A501a2, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0xEDfa23602D0EC14714057867A78d01e94176BEA0] =
            LenderTokens(0xfC41B49d064Ac646015b459C522820DB9472F4B5, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0xA88594D404727625A9437C3f886C7643872296AE] =
            LenderTokens(0xdC7810B47eAAb250De623F0eE07764afa5F71ED1, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x820C137fa70C8691f0e44Dc420a5e53c168921Dc] =
            LenderTokens(0xb6419c6C2e60c4025D6D06eE4F913ce89425a357, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x236aa50979D5f3De3Bd1Eeb40E81137F22ab794b] =
            LenderTokens(0x9A858ebfF1bEb0D3495BB0e2897c1528eD84A218, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0xecAc9C5F704e954931349Da37F60E39f515c11c1] =
            LenderTokens(0x10fF57877b79e9bd949B3815220eC87B9fc5D2ee, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b] =
            LenderTokens(0xdE8Df9d942D78edE3Ca06e60712582F79CFfFC64, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842] =
            LenderTokens(0x6308204872BdB7432dF97b04B42443c714904F3E, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0xcb585250f852C6c6bf90434AB21A00f02833a4af] =
            LenderTokens(0xb4fb8fed5b3AaA8434f0B19b1b623d977e07e86d, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.MOONWELL][0x7300B37DfdfAb110d83290A29DfB31B1740219fE] =
            LenderTokens(0x2F90Bb22eB3979f5FfAd31EA6C3F0792ca66dA32, address(0), address(0));
        lendingControllers[Chains.OP_MAINNET][Lenders.MOONWELL] = 0xCa889f40aae37FFf165BccF69aeF1E82b5C511B9;
        lendingControllers[Chains.MOONBEAM][Lenders.MOONWELL] = 0x8E00D5e02E65A19337Cdba98bbA9F84d4186a180;
        lendingControllers[Chains.BASE][Lenders.MOONWELL] = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;
        lendingTokens[Chains.MOONBEAM][Lenders.ORBITER_ONE][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xCc444ca6bba3764Fc55BeEFe4FFA27435cF6c259, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.ORBITER_ONE][0xFfFFfFff1FcaCBd218EDc0EbA20Fc2308C778080] =
            LenderTokens(0x5693227b49d79C294dBFC6DF76399013a860d947, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.ORBITER_ONE][0xFFFFFFfFea09FB06d082fd1275CD48b191cbCD1d] =
            LenderTokens(0xDf2B90E2eD9a77054bE91aA00bD52F78A86886B7, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.ORBITER_ONE][0x322E86852e492a7Ee17f28a78c663da38FB33bfb] =
            LenderTokens(0x168525d35D61ce3C9cf17b91C98755f2197DCf57, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.ORBITER_ONE][0x931715FEE2d06333043d11F658C8CE934aC61D0c] =
            LenderTokens(0x0bD102515503F1bD2B37bc723Ba5EE7Cfb198419, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.ORBITER_ONE][0xab3f0245B83feB11d15AAffeFD7AD465a59817eD] =
            LenderTokens(0xe48451B26E140b9B2f1A55f2879fe0cA66a43Efe, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.ORBITER_ONE][0xc806B0600cbAfA0B197562a9F7e3B9856866E9bF] =
            LenderTokens(0x64Cff24763227511475B345498f71b987EbdB693, address(0), address(0));
        lendingTokens[Chains.MOONBEAM][Lenders.ORBITER_ONE][0xFFFFFfFf5AC1f9A51A93F5C527385edF7Fe98A52] =
            LenderTokens(0x13C61b2920250ba023C29a6531B8Afc45a4555bF, address(0), address(0));
        lendingControllers[Chains.MOONBEAM][Lenders.ORBITER_ONE] = 0x27DC3DAdBfb40ADc677A2D5ef192d40aD7c4c97D;
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0x5326E71Ff593Ecc2CF7AcaE5Fe57582D6e74CFF1] =
            LenderTokens(0xeA0a73c17323d1a9457D722F10E7baB22dc0cB83, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0xaf88d065e77c8cC2239327C5EDb3A432268e5831] =
            LenderTokens(0x4C9aAed3b8c443b4b634D1A189a5e25C604768dE, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x2193c45244AF12C280941281c8aa67dD08be0a64, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0x6C2C06790b3E3E3c38e12Ee22F8183b37a13EE55] =
            LenderTokens(0x5d27cFf80dF09f28534bb37d386D43aA60f88e25, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F] =
            LenderTokens(0xD12d43Cdf498e377D3bfa2c6217f05B466E14228, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0x539bdE0d7Dbd336b79148AA742883198BBF60342] =
            LenderTokens(0xf21Ef887CB667f84B8eC5934C1713A7Ade8c38Cf, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] =
            LenderTokens(0xC37896BF3EE5a2c62Cdbd674035069776f721668, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] =
            LenderTokens(0x4987782da9a63bC3ABace48648B15546D821c720, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0x912CE59144191C1204E64559FE8253a0e49E6548] =
            LenderTokens(0x8991d64fe388fA79A4f7Aa7826E8dA09F0c3C96a, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0x5979D7b546E38E414F7E9822514be443A4800529] =
            LenderTokens(0xfECe754D92bd956F681A941Cef4632AB65710495, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a] =
            LenderTokens(0x79B6c5e1A7C0aD507E1dB81eC7cF269062BAb4Eb, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] =
            LenderTokens(0x9365181A7df82a1cC578eAE443EFd89f00dbb643, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8] =
            LenderTokens(0x1ca530f02DD0487cef4943c674342c5aEa08922F, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0xFEa7a6a0B346362BF88A9e4A88416B77a57D6c2A] =
            LenderTokens(0x929cC7EBa600CcB3FAf5494210206C93219CcB28, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.LODESTAR][0x0c880f6761F1af8d9Aa9C466984b80DAb9a8c9e8] =
            LenderTokens(0x39c27DfdC9364a976926a820c8CAA8Fd035D0727, address(0), address(0));
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.LODESTAR] = 0xa86DD95c210dd186Fa7639F93E4177E97d057576;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x42778d0962884510b85d4D1B30DFe9e9Dd270446, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(0x3d592e26050e132Ee3D1504aca74f0F4Ed75e5cC, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xdAC17F958D2ee523a2206206994597C13D831ec7] =
            LenderTokens(0xe3502f1c2450Ed1Bb87B87a84AF6742F60f41368, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x6B175474E89094C44Da98b954EedeAC495271d0F] =
            LenderTokens(0x5096E5cf4f151052ACD615b2635E7FdB6Db0763C, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x4c9EDD5852cd905f086C759E8383e09bff1E68B3] =
            LenderTokens(0xF5d682D42e16550Cc5D8f48193243103D2CeAF0a, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x9D39A5DE30e57443BfF2A8307A4256c8797A3497] =
            LenderTokens(0x549D0CdC753601fbE29f9DE186868429a8558E07, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0] =
            LenderTokens(0x15B5220024c3242F7D61177D6ff715cfac4909eD, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xae78736Cd615f374D3085123A210448E74Fc6393] =
            LenderTokens(0x1FF86e97b273dE2b1D42F0FDD5Ea7350A66c4857, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xD9A442856C234a39a81a089C06451EBAa4306a72] =
            LenderTokens(0x23811C17BAc40500deCD5FB92d4FEb972aE1E607, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7] =
            LenderTokens(0x61561B2E01C69C2906735866C94Cc4a33bB71c85, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee] =
            LenderTokens(0xBc6590A7b15513e4D649b158393175a839F27ED8, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x1c085195437738d73d75DC64bC5A3E098b7f93b1] =
            LenderTokens(0xE550a6f792a8B6C07555378EA74063021885A33e, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xd4e75971eAF78a8d93D96df530f1FFf5f9F53288] =
            LenderTokens(0xf7BB299dc8e627eaEc4282FFc236E085aef8FAF3, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x7bAf258049cc8B9A78097723dc19a8b103D4098F] =
            LenderTokens(0x86208Af42580823401B504B341150c92CC99C69A, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] =
            LenderTokens(0xdCA98947c3c9cf0B3CF448b6A03f991598Fb9460, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8] =
            LenderTokens(0x2509bd3B69440D39238b464d09f9F04A61fd62C6, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x1c22531AA9747d76fFF8F0A43b37954ca67d28e0] =
            LenderTokens(0x4342e9bf67F89dea0Cf3c906F5113Dd8b588aC6F, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xe85411C030fB32A9D8b14Bbbc6CB19417391F711] =
            LenderTokens(0x77CcA710E21A94B94a26A98eA23027D64e36B9d4, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x6c9f097e044506712B58EAC670c9a5fd4BCceF13] =
            LenderTokens(0xa46D0328Dfa5822d3E9B4423E2A0A73467c2d2d5, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xd9D920AA40f578ab794426F5C90F6C731D159DEf] =
            LenderTokens(0x5573Fc3650d2a38D1C83faDf682bC379CFAcCFA1, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x7A56E1C57C7475CCf742a1832B028F0456652F97] =
            LenderTokens(0xA9Ea90899fA648b4Ce49f6aE28174AEAda660118, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x18084fbA666a33d37592fA2633fD49a74DD93a88] =
            LenderTokens(0x1bC39d2E227481087f21de67Bae32BC5bc36C70b, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xC96dE26018A54D51c097160568752c4E3BD6C364] =
            LenderTokens(0x91942b802439f2169C36441eF3b250AF6bAc15bD, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x657e8C867D8B37dCC18fA4Caead9C45EB088C642] =
            LenderTokens(0x83db38Aa8d165340012bb734bdd408C46a39d6dD, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xB07b9fDd62DC478E521E8bDe3630a777725B0eB4] =
            LenderTokens(0x09Ec28782a71627b61Dce160Fc0FBbC1edBd2A6D, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0x6ee2b5E19ECBa773a352E5B21415Dc419A700d1d] =
            LenderTokens(0x3d9b5399059d36644B8b67860439Af221C67B273, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SUMER][0xF6fd7Ceb095BfD54130359Cc9366a1493944213A] =
            LenderTokens(0x29688DdC25ecd3307Aa4A83CA3AbB18F6AD70738, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SUMER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x23811C17BAc40500deCD5FB92d4FEb972aE1E607, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SUMER][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(0xBc6590A7b15513e4D649b158393175a839F27ED8, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SUMER][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0xE550a6f792a8B6C07555378EA74063021885A33e, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SUMER][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(0xf7BB299dc8e627eaEc4282FFc236E085aef8FAF3, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SUMER][0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7] =
            LenderTokens(0x86208Af42580823401B504B341150c92CC99C69A, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SUMER][0x1346b618dC92810EC74163e4c27004c921D446a5] =
            LenderTokens(0xdCA98947c3c9cf0B3CF448b6A03f991598Fb9460, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SUMER][0x53E63a31fD1077f949204b94F431bCaB98F72BCE] =
            LenderTokens(0x218C9349E8522466bD57FB878a1a479AeAEF02a4, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SUMER][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(0x2509bd3B69440D39238b464d09f9F04A61fd62C6, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SUMER][0xf9C4FF105803A77eCB5DAE300871Ad76c2794fa4] =
            LenderTokens(0x35C840655D3a2E77d79f179C34e547726B963314, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x9aa55bCf3E41D0d98FCe816C4eC6E791B0f6d154, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0xa4151B2B3e269645181dCcF2D426cE75fcbDeca9] =
            LenderTokens(0xb1FdC3f660b0953253141B2509c43014d5d3d733, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0x900101d06A7426441Ae63e9AB3B9b0F63Be145F1] =
            LenderTokens(0xc7fFEAa5949d50A408bD92DdB0D1EAcef3F8a3Bc, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0x5B1Fb849f1F76217246B8AAAC053b5C7b15b7dc3] =
            LenderTokens(0x10A2e256Bed7b3c49C151Ad1Bad01F4936FC9276, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0xe04d21d999FaEDf1e72AdE6629e20A11a1ed14FA] =
            LenderTokens(0xf902e1925B50ac70285b73FD065af971487c2E4d, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0x9410e8052Bc661041e5cB27fDf7d9e9e842af2aa] =
            LenderTokens(0xdb4d020A58e0A1A67823d75437A61044dC02AE4C, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0xb3A8F0f0da9ffC65318aA39E55079796093029AD] =
            LenderTokens(0x58235d9C8c9f136c0A4e9761186dB0329243bbB8, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8] =
            LenderTokens(0xaAC83D5E45A2f67f2bFd1B804776EFa7DAF6cbF6, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0xe85411C030fB32A9D8b14Bbbc6CB19417391F711] =
            LenderTokens(0xaE6388F58b5b35D5B2eEC828C9633E7D245FEf62, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0x7A6888c85eDBA8E38F6C7E0485212da602761C08] =
            LenderTokens(0xddab3eb6028a44Fb31F9Da92eA1608809248B6b3, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0xc5555eA27e63cd89f8b227deCe2a3916800c0f4F] =
            LenderTokens(0x45f7a835c5b490288ABE36CF3d25a1119135d60F, address(0), address(0));
        lendingTokens[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER][0x5832f53d147b3d6Cd4578B9CBD62425C7ea9d0Bd] =
            LenderTokens(0x8B2da7D9242E631C6f3E1d40Db3407b2F15FFa84, address(0), address(0));
        lendingTokens[Chains.GOAT_NETWORK][Lenders.SUMER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x60B8067Cf3640bCc7c3b2CfbE6Eac3c2CA40934e, address(0), address(0));
        lendingTokens[Chains.GOAT_NETWORK][Lenders.SUMER][0xfe41e7e5cB3460c483AB2A38eb605Cda9e2d248E] =
            LenderTokens(0x3d592e26050e132Ee3D1504aca74f0F4Ed75e5cC, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] =
            LenderTokens(0x142017b52c99d3dFe55E49d79Df0bAF7F4478c0c, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA] =
            LenderTokens(0x3389eD4dd777b03B95deb2994ACaF6807cf24c2E, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb] =
            LenderTokens(0xA4578AB5CDA88AaE7603aFAB24b4c0d24a7858D1, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452] =
            LenderTokens(0x238d804Cb1F4c0c7495e7b7773c54D75E4C99cdd, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22] =
            LenderTokens(0x6345aF6dA3EBd9DF468e37B473128Fd3079C4a4b, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8] =
            LenderTokens(0xa1aD8481e83a5b279D97ab371bCcd5AE3b446EA6, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0x1c22531AA9747d76fFF8F0A43b37954ca67d28e0] =
            LenderTokens(0x56048C88309CAF13A942d688bfB9654432910d6e, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x2AA93D3142d7327307b770Dba2e87C97b86B95Bc, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A] =
            LenderTokens(0xb330cae9C6207dF60C2785b29F775DEC0FE20026, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] =
            LenderTokens(0x0BAd894e6c094Ee78924982b09eE54B6e24Af7F1, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42] =
            LenderTokens(0x6f06a771104F22B006037313954Ef289a1f26Ddd, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0x0022228a2cc5E7eF0274A7Baa600d44da5aB5776] =
            LenderTokens(0x7b1D6dda0cB59c0c87a3d07e97a66e23aE3aF969, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.SUMER][0x004626A008B1aCdC4c74ab51644093b155e59A23] =
            LenderTokens(0xdf1d98A8A1439D348949c72Abf3f678e8B0BF87b, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x3C752d0D78BbFddA6BF4b6000a01228B732441aE, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0xaf88d065e77c8cC2239327C5EDb3A432268e5831] =
            LenderTokens(0x4DE3741E1676ed14d661b1398196dC221cA4D37A, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] =
            LenderTokens(0xDb7Fe9c415281E383595c262e49568DDc18e8Bd4, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] =
            LenderTokens(0x873449359d2d99691436E724C6C219a39b159B4a, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x5979D7b546E38E414F7E9822514be443A4800529] =
            LenderTokens(0x1167e762541374fEBeeA0f6Ed2AD4473AFa1CcEa, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8] =
            LenderTokens(0x1a9CFA6c676ebBEd450dB3cef03e399465F1202C, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] =
            LenderTokens(0x59aC82d3EfB5dc6c4389ccfF7AB7ab6C72C6AC05, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x912CE59144191C1204E64559FE8253a0e49E6548] =
            LenderTokens(0x142017b52c99d3dFe55E49d79Df0bAF7F4478c0c, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8] =
            LenderTokens(0xe4B55045ed14815c7c42eeeF8EE431b89422c389, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x1c22531AA9747d76fFF8F0A43b37954ca67d28e0] =
            LenderTokens(0x9C93423939C4e3D48d99baD147AD808BE89B2043, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0xe85411C030fB32A9D8b14Bbbc6CB19417391F711] =
            LenderTokens(0xAc6bAF36B28d19EA10959102158Beb3d933C1fbf, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe] =
            LenderTokens(0xd5BDa72030d9531fb311ddFE09aF5502C3492E0c, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0xb8b0a120F6A68Dd06209619F62429fB1a8e92feC] =
            LenderTokens(0x7eCaC6929fdC7f98395857FC8B460f14C6898609, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x4186BFC76E2E237523CBC30FD220FE055156b41F] =
            LenderTokens(0xEe67DB245248BDC84a6634e9A3e30FF78Eeb6179, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x3647c54c4c2C65bC7a2D63c0Da2809B399DBBDC0] =
            LenderTokens(0x32be989F762470473878456aB3fB8f6a5bb0205c, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x30c98c0139B62290E26aC2a2158AC341Dcaf1333] =
            LenderTokens(0xaec7D67D07e1f5833a8587fDcb0b7FE50347a8F5, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0xE2B2D203577c7cb3D043E89cCf90b5E24d19b66f] =
            LenderTokens(0x6C6E01110563305537d303e468B23A453BED2197, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.SUMER][0x355ec27c9d4530dE01A103FA27F884a2F3dA65ef] =
            LenderTokens(0x54525258ba4f089e72f062b0cc66774639B2e259, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x8c1ad24cA39FE45E97CD9862364128406E3B03F3, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0xad11a8BEb98bbf61dbb1aa0F6d6F2ECD87b35afA] =
            LenderTokens(0xA6ae238D9CaF65DFA67670FDE3156EFeE9334488, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0xbB0D083fb1be0A9f6157ec484b6C79E0A4e31C2e] =
            LenderTokens(0x7f5a7aE2688A7ba6a9B36141335044c058a08b3E, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0xc3eACf0612346366Db554C991D7858716db09f58] =
            LenderTokens(0x7465fedB29023d11effe8C74E82A7ecEBf15E947, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8] =
            LenderTokens(0x8C38b023Afe895296e2598AE111752223185b35c, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0x1c22531AA9747d76fFF8F0A43b37954ca67d28e0] =
            LenderTokens(0xb1FdC3f660b0953253141B2509c43014d5d3d733, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0xe85411C030fB32A9D8b14Bbbc6CB19417391F711] =
            LenderTokens(0xc7fFEAa5949d50A408bD92DdB0D1EAcef3F8a3Bc, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0xAA40c0c7644e0b2B224509571e10ad20d9C4ef28] =
            LenderTokens(0xdb4d020A58e0A1A67823d75437A61044dC02AE4C, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3] =
            LenderTokens(0x58235d9C8c9f136c0A4e9761186dB0329243bbB8, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0x99e3dE3817F6081B2568208337ef83295b7f591D] =
            LenderTokens(0xaE6388F58b5b35D5B2eEC828C9633E7D245FEf62, address(0), address(0));
        lendingTokens[Chains.HEMI_NETWORK][Lenders.SUMER][0x93919784C523f39CACaa98Ee0a9d96c3F32b593e] =
            LenderTokens(0xF08a6547B142a9b2Aa2586F83f545383A220D372, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0x549943e04f40284185054145c6E4e9568C1D3241] =
            LenderTokens(0xe19FD48C972E2dB074C4B0B29Ff2f0d3E1aefe52, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0xFCBD14DC51f0A4d49d5E53C2E0950e0bC26d0Dce] =
            LenderTokens(0xB2fF02eEF85DC4eaE95Ab32AA887E0cC69DF8d8E, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0x1cE0a25D13CE4d52071aE7e02Cf1F6606F4C79d3] =
            LenderTokens(0x10A2e256Bed7b3c49C151Ad1Bad01F4936FC9276, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590] =
            LenderTokens(0xb1FdC3f660b0953253141B2509c43014d5d3d733, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8] =
            LenderTokens(0x163cEbBD83A4e2821fF06C9b0707A8A64FEc0AbC, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0xe85411C030fB32A9D8b14Bbbc6CB19417391F711] =
            LenderTokens(0xA6ae238D9CaF65DFA67670FDE3156EFeE9334488, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x6116438fD4abDd902dcA8e0335144F700B1a5147, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0xEc901DA9c68E90798BbBb74c11406A32A70652C3] =
            LenderTokens(0x2CB37855fb2Dc0b4C204E242b6A5f731c22AD4bc, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0x0555E30da8f98308EdB960aa94C0Db47230d2B9c] =
            LenderTokens(0xf70B2473e7808eDAeA4A5Cea95996A9B1843D96C, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b] =
            LenderTokens(0xE123F60140F5ace0a76577299cBEC4Bf93CE10aa, address(0), address(0));
        lendingTokens[Chains.BERACHAIN][Lenders.SUMER][0x7DCC39B4d1C53CB31e1aBc0e358b43987FEF80f7] =
            LenderTokens(0x7b5969bB51fa3B002579D7ee41A454AC691716DC, address(0), address(0));
        lendingTokens[Chains.BITLAYER_MAINNET][Lenders.SUMER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x2d9b96648C784906253c7FA94817437EF59Cf226, address(0), address(0));
        lendingTokens[Chains.ZKLINK_NOVA_MAINNET][Lenders.SUMER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x54Dfae480e33dC2BEfd42CAA26A432b11b5a27Bd, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.SUMER] = 0x60A4570bE892fb41280eDFE9DB75e1a62C70456F;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.SUMER] = 0x15B5220024c3242F7D61177D6ff715cfac4909eD;
        lendingControllers[Chains.METER_MAINNET][Lenders.SUMER] = 0xcB4cdDA50C1B6B0E33F544c98420722093B7Aa88;
        lendingControllers[Chains.CORE_BLOCKCHAIN_MAINNET][Lenders.SUMER] = 0x7f5a7aE2688A7ba6a9B36141335044c058a08b3E;
        lendingControllers[Chains.GOAT_NETWORK][Lenders.SUMER] = 0xdD9C863197df28f47721107f94eb031b548B5e48;
        lendingControllers[Chains.BASE][Lenders.SUMER] = 0x3F2B7C60A7bb8f2dbb779Ad14aA0A5614f008d3b;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.SUMER] = 0xBfb69860C91A22A2287df1Ff3Cdf0476c5aab24A;
        lendingControllers[Chains.HEMI_NETWORK][Lenders.SUMER] = 0xB2fF02eEF85DC4eaE95Ab32AA887E0cC69DF8d8E;
        lendingControllers[Chains.BERACHAIN][Lenders.SUMER] = 0x16C7d1F9EA48F7DE5E8bc3165A04E8340Da574fA;
        lendingControllers[Chains.BITLAYER_MAINNET][Lenders.SUMER] = 0xAbcdc5827f92525F56004540459045Ec3e432ebF;
        lendingControllers[Chains.ZKLINK_NOVA_MAINNET][Lenders.SUMER] = 0xe6099D924efEf37845867D45E3362731EaF8A98D;
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0xB75D0B03c06A926e488e2659DF1A861F860bD3d1] =
            LenderTokens(0xc68351B9B3638A6f4A3Ae100Bd251e227BbD7479, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1] =
            LenderTokens(0xC3c9e322F4aAe352ace79D0E62ADe3563fB86e87, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7] =
            LenderTokens(0xA26b9BFe606d29F16B5Aecf30F9233934452c4E2, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x37a4dD9CED2b19Cfe8FAC251cd727b5787E45269] =
            LenderTokens(0x92e51466482146E71b692ced2265284968E8B3d6, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x5Cf6826140C1C56Ff49C808A1A75407Cd1DF9423] =
            LenderTokens(0xda642A7821E91eD285262fead162E5fd17200429, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x78E26E8b953C7c78A58d69d8B9A91745C2BbB258] =
            LenderTokens(0xabFb7A392a6DaaC50f99c5D14B5f27EFfd08Fe03, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x9151434b16b9763660705744891fA906F660EcC5] =
            LenderTokens(0xA82a40324DBf7B57E87bD07C9e1D722E9754be9B, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x5fabd1D440a90eE57Dd698ea096B91F994B6DF56] =
            LenderTokens(0x51Be1bAde695f7aDb37ecf597EC2F97ebD99FbFE, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x095957CEB9f317ac1328f0aB3123622401766D71] =
            LenderTokens(0x413498E8eD8608053DE3f407DBEDd29F19f80c04, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x541FD749419CA806a8bc7da8ac23D346f2dF8B77] =
            LenderTokens(0xA54a39D8d2126C2aaE1622443B30F19414C74f3B, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x9BFA177621119e64CecbEabE184ab9993E2ef727] =
            LenderTokens(0x963Db326b734FD58a9396C020BBb52C14acaFb02, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0xC257361320F4514D91c05F461006CE6a0300E2d2] =
            LenderTokens(0x0C5596DFf747B5EEAb703beB0Ee21dA7Bda0B392, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392] =
            LenderTokens(0xd1E6a6F58A29F64ab2365947ACb53EfEB6Cc05e0, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x6A9A65B84843F5fD4aC9a0471C4fc11AFfFBce4a] =
            LenderTokens(0x7F3C2A5bCA48150c7Ce07DcEAb9B73336a7e592a, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x60C230c38aF6d86b0277a98a1CAeAA345a7B061F] =
            LenderTokens(0xE8E69C45DF3888A8DF6B81FB068F63593cda2aFe, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x160345fC359604fC6e70E3c5fAcbdE5F7A9342d8] =
            LenderTokens(0xe6EACaF0888eF15928bdD057716074A679fad49d, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0xBE574b6219C6D985d08712e90C21A88fd55f1ae8] =
            LenderTokens(0x372B1B8bA8438AdbB06BDe2894EE1D27996fE2a8, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x0555E30da8f98308EdB960aa94C0Db47230d2B9c] =
            LenderTokens(0xf2954e2875dF36914dA0346F648a0b04e8122199, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0xdf77686D99667Ae56BC18f539B777DBc2BBE3E9F] =
            LenderTokens(0xf1a90d0EDfbB98E37F46626ac717fAb9437272F3, address(0), address(0));
        lendingTokens[Chains.SEI_NETWORK][Lenders.TAKARA][0x54cD901491AeF397084453F4372B93c33260e2A6] =
            LenderTokens(0xadEB3aFf3cdB149bD35820698FB7c8B8E52f4B84, address(0), address(0));
        lendingControllers[Chains.SEI_NETWORK][Lenders.TAKARA] = 0x71034bf5eC0FAd7aEE81a213403c8892F3d8CAeE;
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0xc21223249CA28397B4B6541dfFaEcC539BfF0c59] =
            LenderTokens(0xB3bbf1bE947b245Aef26e3B6a9D777d7703F4c8e, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0x062E66477Faf219F25D27dCED647BF57C3107d52] =
            LenderTokens(0x67fD498E94d95972a4A2a44AccE00a000AF7Fe00, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0xe44Fd7fCb2b1581822D0c862B68222998a0c299a] =
            LenderTokens(0x543F4Db9BD26C9Eb6aD4DD1C33522c966C625774, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xeAdf7c01DA7E93FdB5f16B0aa9ee85f978e89E95, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0xF2001B145b43032AAF5Ee2884e456CCd805F677D] =
            LenderTokens(0xE1c4c56f772686909c28C319079D41adFD6ec89b, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0x66e428c3f67a68878562e79A0234c1F83c208770] =
            LenderTokens(0xA683fdfD9286eeDfeA81CF6dA14703DA683c44E5, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0xDD73dEa10ABC2Bff99c60882EC5b2B81Bb1Dc5B2] =
            LenderTokens(0xfe6934FDf050854749945921fAA83191Bccf20Ad, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0x87EFB3ec1576Dec8ED47e58B832bEdCd86eE186e] =
            LenderTokens(0x4bD41f188f6A05F02b46BB2a1f8ba776e528F9D2, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0xB888d8Dd1733d72681b30c00ee76BDE93ae7aa93] =
            LenderTokens(0x0D9706531B517d24623118934De69108968ba266, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0x0e517979C2c1c1522ddB0c73905e0D39b3F990c0] =
            LenderTokens(0x29984c47B0bAc5a59290ef082E1f651A7019EC4A, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0x2D03bECE6747ADC00E1a131BBA1469C15fD11e03] =
            LenderTokens(0xB075A3590c9FFc8332c47Db49f5c6Ee1dBcDF804, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0xb9Ce0dd29C91E02d4620F57a66700Fc5e41d6D15] =
            LenderTokens(0x53B4112cba389302B065d2A92bB249d27f51c680, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0x9d97Be214b68C7051215BB61059B4e299Cd792c3] =
            LenderTokens(0xE3E2ceA8DFFa592EADaB7D9c7f1E0cC6700490aa, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0x9Fae23A2700FEeCd5b93e43fDBc03c76AA7C08A6] =
            LenderTokens(0xf4F21A4990ACD891d05dface12A2b8F57e61d1Ee, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0x2e53c5586e12a99d4CAE366E9Fc5C14fE9c6495d] =
            LenderTokens(0xecD4bea6ed20a4a820ae2C4900E5501a985A3fe3, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0x7a7c9db510aB29A2FC362a4c34260BEcB5cE3446] =
            LenderTokens(0xBffcD14ED8cB224B26B692d7Eb4118FFEDFAbDbd, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC][0xD42E078ceA2bE8D03cd9dFEcC1f0d28915Edea78] =
            LenderTokens(0x6D1861C723F2eC35d5aE13f470bF197A8258dE3E, address(0), address(0));
        lendingControllers[Chains.CRONOS_MAINNET][Lenders.TECTONIC] = 0xb3831584acb95ED9cCb0C11f677B5AD01DeaeEc0;
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_DEFI][0xc21223249CA28397B4B6541dfFaEcC539BfF0c59] =
            LenderTokens(0x498BD0Cbdf3ba43c02fE768F8E993d4bF21d011d, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_DEFI][0x66e428c3f67a68878562e79A0234c1F83c208770] =
            LenderTokens(0x3C920600e049A128b01D2Ef0b932108687196502, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_DEFI][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x972173AfB7Eefb80a0815831B318A643442ad0C1, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_DEFI][0x9Fae23A2700FEeCd5b93e43fDBc03c76AA7C08A6] =
            LenderTokens(0xCd8F4147A4F9452e027f5203bfc5B7A786055138, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_DEFI][0xB888d8Dd1733d72681b30c00ee76BDE93ae7aa93] =
            LenderTokens(0x56B6000f7AA338D77Ba834F6F70A1774d0248517, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_DEFI][0xAC974ee7fc5d083112c809cCb3FCe4a4F385750D] =
            LenderTokens(0x0a927384CC7ff3D250ac276ae2158D837e42f667, address(0), address(0));
        lendingControllers[Chains.CRONOS_MAINNET][Lenders.TECTONIC_DEFI] = 0x7E0067CEf1e7558daFbaB3B1F8F6Fa75Ff64725f;
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_VENO][0xc21223249CA28397B4B6541dfFaEcC539BfF0c59] =
            LenderTokens(0xf2A4C7595A64A18158D205148A975509d969cB8d, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_VENO][0x66e428c3f67a68878562e79A0234c1F83c208770] =
            LenderTokens(0x0bA8683fB1d8F66d9EBBE3634b67Da623188AC84, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_VENO][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xf4Ff4B8Ee660D4276EdA17e79094A7CC519e9606, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_VENO][0x39bC1e38c842C60775Ce37566D03B41A7A66C782] =
            LenderTokens(0x2C5515bE5bb123b8088843e85789e3e294670caD, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_VENO][0xdb7d0A1eC37dE1dE924F8e8adac6Ed338D4404E9] =
            LenderTokens(0x5F2E412392A317b8b80234B8a6941e0282161A25, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_VENO][0x83aFB1C32E5637ACd0a452D87c3249f4a9F0013A] =
            LenderTokens(0x6B0eF5f3E00D7aF1459879079d3Df76afbBAf865, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_VENO][0xeBAceB7F193955b946cC5dd8f8724a80671a1F2F] =
            LenderTokens(0x47e5229d46A11A25FF5dCa210DF57d62345dEcf1, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_VENO][0x7a7c9db510aB29A2FC362a4c34260BEcB5cE3446] =
            LenderTokens(0xd6D56B6024B298E69c8171aAf969aDAe5a48B83e, address(0), address(0));
        lendingTokens[Chains.CRONOS_MAINNET][Lenders.TECTONIC_VENO][0xD42E078ceA2bE8D03cd9dFEcC1f0d28915Edea78] =
            LenderTokens(0x0aE5EF1fb98beED3bddF2be5c841D2b2becF92da, address(0), address(0));
        lendingControllers[Chains.CRONOS_MAINNET][Lenders.TECTONIC_VENO] = 0x8312A8d5d1deC499D00eb28e1a2723b13aA53C1e;
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x0706905b2b21574DEFcF00B5fc48068995FCdCdf, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] =
            LenderTokens(0x0A2f8B6223EB7DE26c810932CCA488A4936cF391, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F] =
            LenderTokens(0x27846A0f11EDC3D59EA227bAeBdFa1330a69B9ab, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] =
            LenderTokens(0x4A5806A3c4fBB32F027240F80B18b26E40BF7E31, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8] =
            LenderTokens(0x068485a0f964B4c3D395059a19A05a8741c48B4E, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] =
            LenderTokens(0xB287180147EF1A97cbfb07e2F1788B75df2f6299, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0xf97f4df75117a78c1A5a0DBb814Af92458539FB4] =
            LenderTokens(0x87D06b55e122a0d0217d9a4f85E983AC3d7a1C35, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0] =
            LenderTokens(0x8b44D3D286C64C8aAA5d445cFAbF7a6F4e2B3A71, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a] =
            LenderTokens(0x20a6768F6AABF66B787985EC6CE0EBEa6D7Ad497, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0x912CE59144191C1204E64559FE8253a0e49E6548] =
            LenderTokens(0xC6121d58E01B3F5C88EB8a661770DB0046523539, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0x539bdE0d7Dbd336b79148AA742883198BBF60342] =
            LenderTokens(0x4180f39294c94F046362c2DBC89f2DF7786842c3, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] =
            LenderTokens(0x242f91207184FCc220beA3c9E5f22b6d80F3faC5, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.TENDER][0x3DB4B7DA67dd5aF61Cb9b3C70501B1BdB24b2C22] =
            LenderTokens(0xe4843e44342617024F6b9d615dFfBe8858F8Ea16, address(0), address(0));
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.TENDER] = 0xeed247Ba513A8D6f78BE9318399f5eD1a4808F8e;
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x24664791B015659fcb71aB2c9C0d56996462082F, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(0xcfa5b884689dc09e4503e84f7877d3A583fcceef, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(0x66fD9D390De6172691EC0ddF0ac7F231c1f9a434, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56] =
            LenderTokens(0x928fa017eBf781947102690c9b176996B2E00f22, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(0x854a534cEFAf8fD20A70C9DC976C4f65324D7B42, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0x4c2bddc208B58534EdDC1fba7B2828CAb70797b5, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x23396cF899Ca06c4472205fC903bDB4de249D6fC] =
            LenderTokens(0xa5ae8459e710F95ca0C93d73F63a66d9996F1ACE, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3] =
            LenderTokens(0x8B2f098411Ce4B32c9D2110FeF257Cf01D006bA5, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0xb3Cb6d2f8f2FDe203a022201C81a96c167607F15] =
            LenderTokens(0x0c6dd143F4b86567d6c21E8ccfD0300f00896442, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x72B7D61E8fC8cF971960DD9cfA59B8C829D91991] =
            LenderTokens(0xb7eD4A5AF620B52022fb26035C565277035d4FD7, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x14016E85a25aeb13065688cAFB43044C2ef86784] =
            LenderTokens(0x939e98eeC2Aa37baB8c5d94BC90C6E00911d27B4, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82] =
            LenderTokens(0x7a9cB040e4DdD5271C36A8C8DeAdD3BA1b5A5949, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40] =
            LenderTokens(0x6022bA7e5A70E1bAA98d47a566F3495A26511b25, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402] =
            LenderTokens(0x84a785E400c43D341D5cbCDC7f0dceb49Cae7d00, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47] =
            LenderTokens(0x9B81d1df15fD9C07007d9a9b8fF75D40A5a80D94, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x0Eb3a705fc54725037CC9e008bDede697f62F335] =
            LenderTokens(0x820cDE110D5f17b9F985FBb80f10D4f7158F130f, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0xCC42724C6683B7E57334c4E856f4c9965ED682bD] =
            LenderTokens(0xeb23D803Ec8D598662441807456620cF96eb0470, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x570A5D26f7765Ecb712C0924E4De545B89fD43dF] =
            LenderTokens(0x45646b30c3Bb8c02bCfE10314308a8055E705ebF, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x156ab3346823B651294766e23e6Cf87254d68962] =
            LenderTokens(0x88FD42E447d39C3259b53623f2536bd855e47C48, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x3d4350cD54aeF9f9b2C29435e0fa809957B3F30a] =
            LenderTokens(0xAF7602Fb6A83f04886032467B487101B80ebccC0, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x1CE0c2827e2eF14D5C4f29a091d735A204794041] =
            LenderTokens(0x2a29572b771a8D8057A046fe80C45a77DBB6E804, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0xAD29AbB318791D579433D831ed122aFeAf29dcfe] =
            LenderTokens(0xb3A350f549113c60d074587dC40cD25c83d4D3b0, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD] =
            LenderTokens(0x5e11eC8Ec1a57A93E5ddc8AD950cea60EAd9014b, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA][0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE] =
            LenderTokens(0x2aCAf66E67876d18CC5a27EB90Aa32b06Ab4785B, address(0), address(0));
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.GAMMA] = 0xF54f9e7070A1584532572A6F640F09c606bb9A83;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.FLUX_FINANCE][0x1B19C19393e2d034D8Ff31ff34c81252FcBbee92] =
            LenderTokens(0x1dD7950c266fB1be96180a8FDb0591F70200E018, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.FLUX_FINANCE][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(0x465a5a630482f3abD6d3b84B39B29b07214d19e5, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.FLUX_FINANCE][0x6B175474E89094C44Da98b954EedeAC495271d0F] =
            LenderTokens(0xe2bA8693cE7474900A045757fe0efCa900F6530b, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.FLUX_FINANCE][0xdAC17F958D2ee523a2206206994597C13D831ec7] =
            LenderTokens(0x81994b9607e06ab3d5cF3AffF9a67374f05F27d7, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.FLUX_FINANCE][0x853d955aCEf822Db058eb8505911ED77F175b99e] =
            LenderTokens(0x1C9A2d6b33B4826757273D47ebEe0e2DddcD978B, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.FLUX_FINANCE] = 0x95Af143a021DF745bc78e845b54591C53a8B3A51;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x0D8775F648430679A709E98d2b0Cb6250d2887EF] =
            LenderTokens(0x6C8c6b02E7b2BE14d4fA6022Dfd6d75921D90E4E, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x6B175474E89094C44Da98b954EedeAC495271d0F] =
            LenderTokens(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x1985365e9f78359a9B6AD760e32412f4a445E862] =
            LenderTokens(0x158079Ee67Fce2f58472A96584A73C7Ab9AC95c1, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(0x39AA39c021dfbaE8faC545936693aC917d5E7563, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0xdAC17F958D2ee523a2206206994597C13D831ec7] =
            LenderTokens(0xf650C3d88D12dB855b8bf7D11Be6C55A4e07dCC9, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] =
            LenderTokens(0xccF4429DB6322D5C611ee964527D42E5d685DD6a, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0xE41d2489571d322189246DaFA5ebDe1F4699F498] =
            LenderTokens(0xB3319f5D18Bc0D84dD1b4825Dcde5d5f7266d407, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x89d24A6b4CcB1B6fAA2625fE562bDD9a23260359] =
            LenderTokens(0xF5DCe57282A584D2746FaF1593d3121Fcac444dC, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984] =
            LenderTokens(0x35A18000230DA775CAc24873d00Ff85BccdeD550, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0xc00e94Cb662C3520282E6f5717214004A7f26888] =
            LenderTokens(0x70e36f6BF80a52b3B46b3aF8e106CC0ed743E8e4, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x514910771AF9Ca656af840dff83E8264EcF986CA] =
            LenderTokens(0xFAce851a4921ce59e912d19329929CE6da6EB0c7, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2] =
            LenderTokens(0x95b4eF2869eBD94BEb4eEE400a99824BF5DC325b, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x6B3595068778DD592e39A122f4f5a5cF09C90fE2] =
            LenderTokens(0x4B0181102A0112A2ef11AbEE5563bb4a3176c9d7, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9] =
            LenderTokens(0xe65cdB6479BaC1e22340E4E755fAE7E509EcD06c, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e] =
            LenderTokens(0x80a2AE356fc9ef4305676f7a3E2Ed04e12C33946, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x956F47F50A910163D8BF957Cf5846D573E7f87CA] =
            LenderTokens(0x041171993284df560249B57358F931D9eB7b925D, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2][0x8E870D67F660D95d5be530380D0eC0bd388289E1] =
            LenderTokens(0x7713DD9Ca933848F6819F38B8352D9A15EA73F67, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.COMPOUND_V2] = 0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x27A94869341838D5783368a8503FdA5fbCd7987c, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY][0x6B175474E89094C44Da98b954EedeAC495271d0F] =
            LenderTokens(0x85166b72c87697a6acfF24101B43Fd54fE28a179, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY][0xdAC17F958D2ee523a2206206994597C13D831ec7] =
            LenderTokens(0x5cFad792C4Df1323188180778AeC58E00eAcE32a, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(0xf8E5b9738BF63ADFFf36a849F9b9C9617c8D8c1f, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] =
            LenderTokens(0xc12B9D620bFCB48be3e0CCbf0ea80C717333b46F, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY][0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984] =
            LenderTokens(0x82413f75f0DA101e0FE7F6FF6cBa3461F7e04f29, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY][0xa1d0E215a23d7030842FC67cE582a6aFa3CCaB83] =
            LenderTokens(0x82dE3959c09f665a82C794fAfC1eb34CFCb555Ee, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY][0xBBbbCA6A901c926F240b89EacB641d8Aec7AEafD] =
            LenderTokens(0x690Aa2591e57180cBA5A6123e9D462907A5e1c95, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY][0xf88506B0F1d30056B9e5580668D5875b9cd30F23] =
            LenderTokens(0xEf86384Cf696929C3227428f539e740EE12fcdc7, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY][0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919] =
            LenderTokens(0x959F30F765a44273EcCaA0FAc094160aa7c238E2, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x33A32f0ad4AA704e28C93eD8Ffa61d50d51622a7, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(0x849C37A029B38D3826562697Ccc40c34477C6293, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(0x311aEA58Ca127B955890647413846E351df32554, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3] =
            LenderTokens(0x12D803497D1e58dD4D4A4F455D754f1d0F937C8b, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0x2a8Cd78bFb91ACF53f589961D213d87c956e0d7f, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(0x2B7F68170a598E507B19Bca41ED745eABc936B3F, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56] =
            LenderTokens(0x2dd8FFA7923a17739F70C34759Af7650e44EA3BE, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402] =
            LenderTokens(0x811Cd5CB4cC43F44600Cfa5eE3F37a402C82aec2, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0xBf5140A22578168FD562DCcF235E5D43A02ce9B1] =
            LenderTokens(0x17933112E9780aBd0F27f2B7d9ddA9E840D43159, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82] =
            LenderTokens(0x417FDfC74503d8008AeEB53248E5C0f1960c2C1d, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x4338665CBB7B2485A8855A139b75D5e34AB0DB94] =
            LenderTokens(0x6a05BD123d780055c38526cC05d3c9B90D0E471c, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD] =
            LenderTokens(0x00FF07204C3b27D72cF83Ef521Adb7066167561a, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47] =
            LenderTokens(0xBc52BCE2C73Fec358ABBf047c50377183B9EAd0d, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153] =
            LenderTokens(0xDF21D42a0fC6746718F2CFe2798F91C9d7277F32, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x8CD6e29d3686d24d3C2018CEe54621eA0f89313B] =
            LenderTokens(0x23cf81eeAA61C1C7607Ee1a3Bfcff1f99AC26c85, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY][0x2eD9a5C8C13b93955103B9a7C167B67Ef4d568a3] =
            LenderTokens(0x33d295Aaa719fD756310eB42DE2847d0E7Be294E, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.WE_PIGGY] = 0x0C8c1ab017c3C0c8A48dD9F1DB2F59022D190f0b;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.WE_PIGGY] = 0x8c925623708A94c7DE98a8e83e8200259fF716E0;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xD06527D5e56A3495252A528C4987003b712860eE, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xa47c8bf37f92aBed4A126BDA807A7b7498661acD] =
            LenderTokens(0x51F48b638F82e8765F7a26373A2Cb4CcB10C07af, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(0x44fbeBd2F576670a6C33f6Fc0B00aA8c5753b322, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e] =
            LenderTokens(0xCbaE0A83f4f9926997c8339545fb8eE32eDc6b76, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xba100000625a3754423978a60c9317c58a424e3D] =
            LenderTokens(0xcE4Fe9b4b8Ff61949DCfeB7e03bc9FAca59D2Eb3, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xc00e94Cb662C3520282E6f5717214004A7f26888] =
            LenderTokens(0x19D1666f543D42ef17F66E376944A22aEa1a8E46, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xdF5e0e81Dff6FAF3A7e52BA697820c5e32D806A8] =
            LenderTokens(0x9baF8a5236d44AC410c0186Fe39178d5AAD0Bb87, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xdAC17F958D2ee523a2206206994597C13D831ec7] =
            LenderTokens(0x797AAB1ce7c01eB727ab980762bA88e7133d2157, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x2ba592F78dB6436527729929AAf6c908497cB200] =
            LenderTokens(0x892B14321a4FCba80669aE30Bd0cd99a7ECF6aC0, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x514910771AF9Ca656af840dff83E8264EcF986CA] =
            LenderTokens(0x697256CAA3cCaFD62BB6d3Aa1C7C5671786A5fD9, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x80fB784B7eD66730e8b1DBd9820aFD29931aab03] =
            LenderTokens(0x8B86e0598616a8d4F1fdAE8b59E55FB5Bc33D0d6, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xD533a949740bb3306d119CC777fa900bA034cd52] =
            LenderTokens(0xc7Fd8Dcee4697ceef5a2fd4608a7BD6A94C77480, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xEB4C2781e4ebA804CE9a9803C67d0893436bB27D] =
            LenderTokens(0x17107f40d70f4470d20CB3f138a052cAE8EbD4bE, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x4Fabb145d64652a948d72533023f6E7A623C7C53] =
            LenderTokens(0x1FF8CDB51219a8838b52E9cAc09b71e591BC998e, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xa3BeD4E1c75D00fa6f4E5E6922DB7261B5E9AcD2] =
            LenderTokens(0x3623387773010d9214B10C551d6e7fc375D31F58, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x5dbcF33D8c2E976c6b560249878e6F1491Bca25c] =
            LenderTokens(0x4EE15f44c6F0d8d1136c83EfD2e8E4AC768954c6, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x6B3595068778DD592e39A122f4f5a5cF09C90fE2] =
            LenderTokens(0x338286C0BC081891A4Bda39C7667ae150bf5D206, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x50D1c9771902476076eCFc8B2A83Ad6b9355a4c9] =
            LenderTokens(0x10FDBD1e48eE2fD9336a482D746138AE19e649Db, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x476c5E26a75bd202a9683ffD34359C0CC15be0fF] =
            LenderTokens(0xef58b2d5A1b8D3cDE67b8aB054dC5C831E9Bc025, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984] =
            LenderTokens(0xe89a6D0509faF730BD707bf868d9A2A744a363C7, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x0d438F3b5175Bebc262bF23753C1E53d03432bDE] =
            LenderTokens(0xeFF039C3c1D668f408d09dD7B63008622a77532C, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x87eDfFDe3E14c7a66c9b9724747a1C5696b742e6] =
            LenderTokens(0x22B243B96495C547598D9042B6f94B01C22B2e9E, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xaaAEBE6Fe48E54f431b0C390CfaF0b017d09D42d] =
            LenderTokens(0x8b3FF1ed4F36C2c2be675AFb13CC3AA5d73685a5, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x1494CA1F11D487c2bBe4543E90080AeBa4BA3C2b] =
            LenderTokens(0x2A537Fa9FFaea8C1A41D3C2B68a9cb791529366D, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x9BE89D2a4cd102D8Fecc6BF9dA793be995C22541] =
            LenderTokens(0x7ea9C63E216D5565c3940A2B3d150e59C2907Db3, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9] =
            LenderTokens(0x3225E3C669B39C7c8B3e204a8614bB218c5e31BC, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x0391D2021f89DC339F60Fff84546EA23E337750f] =
            LenderTokens(0xf55BbE0255f7f4E70f63837Ff72A577fbDDbE924, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x1cEB5cB57C4D4E2b2433641b95Dd330A33185A44] =
            LenderTokens(0x903560b1CcE601794C584F58898dA8a8b789Fc5d, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x0316EB71485b0Ab14103307bf65a021042c6d380] =
            LenderTokens(0x054B7ed3F45714d3091e82aAd64A1588dC4096Ed, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xcBc1065255cBc3aB41a6868c22d1f1C573AB89fd] =
            LenderTokens(0xfd609a03B393F1A1cFcAcEdaBf068CAD09a924E2, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xdF574c24545E5FfEcb9a659c229253D4111d87e1] =
            LenderTokens(0xD692ac3245bb82319A31068D6B8412796eE85d2c, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x6B175474E89094C44Da98b954EedeAC495271d0F] =
            LenderTokens(0x92B767185fB3B04F881e3aC8e5B0662a027A1D9f, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x584bC13c7D411c00c01A62e8019472dE68768430] =
            LenderTokens(0x10a3da2BB0Fae4D591476fd97D6636fd172923a8, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x36F3FD68E7325a35EB768F1AedaAe9EA0689d723] =
            LenderTokens(0x3C6C553A95910F9FC81c98784736bd628636D296, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x4688a8b1F292FDaB17E9a90c8Bc379dC1DBd8713] =
            LenderTokens(0x21011BC93d9E515B9511A817A1eD1D6d468f49Fc, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x111111111117dC0aa78b770fA6A738034120C302] =
            LenderTokens(0x85759961b116f1D36fD697855c57A6ae40793D9B, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x967da4048cD07aB37855c090aAF366e4ce1b9F48] =
            LenderTokens(0x7C3297cFB4c4bbd5f44b450c0872E0ADA5203112, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xd26114cd6EE289AccF82350c8d8487fedB8A0C07] =
            LenderTokens(0x7Aaa323D7e398be4128c7042d197a2545f0f1fea, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xBb2b8038a1640196FbE3e38816F3e67Cba72D940] =
            LenderTokens(0x011a014d5e8Eb4771E575bB1000318D509230Afa, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852] =
            LenderTokens(0xE6C3120F38F56deb38B69b65cC7dcAF916373963, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc] =
            LenderTokens(0x4Fe11BC316B6d7A345493127fBE298b95AdaAd85, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11] =
            LenderTokens(0xcD22C4110c12AC41aCEfA0091c432ef44efaAFA0, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x8798249c2E607446EfB7Ad49eC89dD1865Ff4272] =
            LenderTokens(0x228619CCa194Fbe3Ebeb2f835eC1eA5080DaFbb2, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] =
            LenderTokens(0x197070723CE0D3810a0E47F06E935c30a480D4Fc, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F] =
            LenderTokens(0xC25EAE724f189Ba9030B2556a1533E7c8A732E14, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x57Ab1ec28D129707052df4dF418D58a2D46d5f51] =
            LenderTokens(0x25555933a8246Ab67cbf907CE3d1949884E82B55, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x429881672B9AE42b8EbA0E26cD9C73711b891Ca5] =
            LenderTokens(0xc68251421eDDa00a10815E273fA4b1191fAC651b, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x8Ab7404063Ec4DBcfd4598215992DC3F8EC853d7] =
            LenderTokens(0x65883978aDA0e707c3b2BE2A6825b1C4BDF76A90, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x19D97D8fA813EE2f51aD4B4e04EA08bAf4DFfC28] =
            LenderTokens(0x8B950f43fCAc4931D408F1fcdA55C6CB6cbF3096, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x8207c1FfC5B6804F6024322CcF34F29c3541Ae26] =
            LenderTokens(0x59089279987DD76fC65Bf94Cb40E186b96e03cB3, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xfF20817765cB7f73d4bde2e66e067E58D11095C2] =
            LenderTokens(0x2Db6c82CE72C8d7D770ba1b5F5Ed0b6E075066d6, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x853d955aCEf822Db058eb8505911ED77F175b99e] =
            LenderTokens(0xb092b4601850E23903A42EaCBc9D8A0EeC26A4d5, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xFca59Cd816aB1eaD66534D82bc21E7515cE441CF] =
            LenderTokens(0x081FE64df6dc6fc70043aedF3713a3ce6F190a21, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xa1faa113cbE53436Df28FF0aEe54275c13B40975] =
            LenderTokens(0x1d0986Fb43985c88Ffa9aD959CC24e6a087C7e35, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x4E15361FD6b4BB609Fa63C81A2be19d873717870] =
            LenderTokens(0xc36080892c64821fa8e396bc1bD8678fA3b82b17, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x3155BA85D5F96b2d030a4966AF206230e46849cb] =
            LenderTokens(0x8379BAA817c5c5aB929b03ee8E3c48e45018Ae41, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xbC396689893D065F41bc2C6EcbeE5e0085233447] =
            LenderTokens(0x299e254A8a165bBeB76D9D69305013329Eea3a3B, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919] =
            LenderTokens(0xf8445C529D363cE114148662387eba5E62016e20, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xb753428af26E81097e7fD17f40c88aaA3E04902c] =
            LenderTokens(0x28526Bb33d7230E65E735dB64296413731C5402e, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x1337DEF16F9B486fAEd0293eb623Dc8395dFE46a] =
            LenderTokens(0xab10586C918612BA440482db77549d26B7ABF8f7, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x1337DEF18C680aF1f9f45cBcab6309562975b1dD] =
            LenderTokens(0xdFFf11DFe6436e42a17B86e7F419Ac8292990393, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xec67005c4E498Ec7f55E092bd1d35cbC47C91892] =
            LenderTokens(0xDbb5e3081dEf4b6cdD8864aC2aeDA4cBf778feCf, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x1b40183EFB4Dd766f11bDa7A7c3AD8982e998421] =
            LenderTokens(0x71cEFCd324B732d4E058AfAcBA040d908c441847, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xbA4cFE5741b357FA371b506e5db0774aBFeCf8Fc] =
            LenderTokens(0x1A122348B73B58eA39F822A89e6ec67950c2bBD0, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x6810e776880C02933D47DB1b9fc05908e5386b96] =
            LenderTokens(0x523EFFC8bFEfC2948211A05A905F761CBA5E8e9E, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xCC4304A31d09258b0029eA7FE63d032f52e44EFe] =
            LenderTokens(0x98E329eB5aae2125af273102f3440DE19094b77c, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x956F47F50A910163D8BF957Cf5846D573E7f87CA] =
            LenderTokens(0x8C3B7a4320ba70f8239F83770c4015B5bc4e6F91, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x4691937a7508860F876c9c0a2a617E7d9E945D4B] =
            LenderTokens(0xE585c76573D7593ABF21537B607091F76c996E73, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x1F573D6Fb3F13d689FF844B4cE37794d79a7FF1C] =
            LenderTokens(0x81E346729723C4D15d0FB1c5679b9f2926Ff13C6, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xC581b735A1688071A1746c968e0798D642EDE491] =
            LenderTokens(0x766175eaC1A99C969dDd1EBDBe7e270D508d8FFF, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x8E870D67F660D95d5be530380D0eC0bd388289E1] =
            LenderTokens(0xD7394428536F63d5659cc869EF69d10f9E66314B, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x45804880De22913dAFE09f4980848ECE6EcbAf78] =
            LenderTokens(0x1241B10E7EA55b22f5b2d007e8fECDF73DCff999, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xc4E15973E6fF2A35cC804c2CF9D2a1b817a8b40F] =
            LenderTokens(0x2A867fd776B83e1bd4e13C6611AFd2F6af07EA6D, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x0000000000095413afC295d19EDeb1Ad7B71c952] =
            LenderTokens(0x250Fb308199FE8C5220509C1bf83D21d60b7f74A, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x25f8087EAD173b73D6e8B84329989A8eEA16CF73] =
            LenderTokens(0x4112a717edD051F77d834A6703a1eF5e3d73387F, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0xBB0E17EF65F82Ab018d8EDd776e8DD940327B28b] =
            LenderTokens(0xF04ce2e71D32D789a259428ddcD02D3C9F97fb4E, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x3845badAde8e6dFF049820680d1F14bD3903a5d0] =
            LenderTokens(0x89e42987c39f72e2EAd95a8a5bC92114323d5828, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x0F5D2fB29fb7d3CFeE444a200298f468908cC942] =
            LenderTokens(0x58DA9c9fC3eb30AbBcbBAb5DDabb1E6e2eF3d2EF, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE][0x99D8a9C45b2ecA8864373A26D1459e3Dff1e17F3] =
            LenderTokens(0xd37295796C8B885783bD0A4a6C890e3ddeAE6705, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x1Ffe17B99b439bE0aFC831239dDECda2A790fF3A, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(0x11883Cdea6bAb720092791cc89affa54428Ce069, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56] =
            LenderTokens(0x2Bc4eb013DDee29D37920938B96d353171289B7C, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE] =
            LenderTokens(0xAa46e2c21B7763a73DB48e9b318899253E66e20C, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf] =
            LenderTokens(0xCb87Cee8c77CdFD310fb3C58ff72e688d46f90b1, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(0xb31f5d117541825D6692c10e4357008EDF3E2BCD, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x4338665CBB7B2485A8855A139b75D5e34AB0DB94] =
            LenderTokens(0x8cc7E2a6de999758499658bB702143FD025E09B2, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0xEF6d459FE81C3Ed53d292c936b2df5a8084975De, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD] =
            LenderTokens(0x3942936782d788ce69155F776A51A5F1C9dd9B22, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402] =
            LenderTokens(0x53D88d2ffDBE71E81D95b08AE0cA49D0C4A8515f, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47] =
            LenderTokens(0x81C15D3E956e55e77E1f3F257f0A65Bd2725fC55, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0xd4CB328A82bDf5f03eB737f37Fa6B370aef3e888] =
            LenderTokens(0x426D6D53187be3288fe37f214e3F6901D8145b62, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0xAD6cAEb32CD2c308980a548bD0Bc5AA4306c6c18] =
            LenderTokens(0x738f3810b3dA0F3e6dC8C689D0d72f3b4992c43b, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x56b6fB708fC5732DEC1Afc8D8556423A2EDcCbD6] =
            LenderTokens(0x19eE64850862cFd234e20c0db4edA286f12ec907, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3] =
            LenderTokens(0x9095e8d707E40982aFFce41C61c10895157A1B22, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x16939ef78684453bfDFb47825F8a5F714f12623a] =
            LenderTokens(0xE692714717a89E4F2ab89dd17d8DDdD7bb52De8e, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153] =
            LenderTokens(0x1aF8c1C3AD36A041cb6678feD86B1E095004fd16, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x88f1A5ae2A3BF98AEAF342D26B30a79438c9142e] =
            LenderTokens(0xEA466cd2583A0290b9E7b987a769a7Eb468FB0A5, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0xBf5140A22578168FD562DCcF235E5D43A02ce9B1] =
            LenderTokens(0x3B0Be453a4008EBc2eDd457e7Bd355f1C5469d68, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x0Eb3a705fc54725037CC9e008bDede697f62F335] =
            LenderTokens(0x0E9d900C884964dC4B26db96Ba113825B1a09Baa, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(0xD83C88DB3A6cA4a32FFf1603b0f7DDce01F5f727, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0xa1faa113cbE53436Df28FF0aEe54275c13B40975] =
            LenderTokens(0x264Bc4Ea2F45cF6331AD6C3aC8d7257Cf487FcbC, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x4B0F1812e5Df2A09796481Ff14017e6005508003] =
            LenderTokens(0x2d3bfaDF9BC94E3Ab796029A030e863F1898aA06, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82] =
            LenderTokens(0xBf9B95b78bc42F6CF53FF2A0ce19D607cFe1ff82, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63] =
            LenderTokens(0x4EBdeF163fF08ac1D56A89bAfeFd6C01cc28a48f, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x101d82428437127bF1608F699CD651e6Abf9766E] =
            LenderTokens(0x4cB7F1f4aD7a6b53802589Af3B90612C1674Fec4, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7] =
            LenderTokens(0x84902bd5ccef97648Bf69C5096729A9367043bEb, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0xa184088a740c695E156F91f5cC086a06bb78b827] =
            LenderTokens(0xF77DF34F4Bf632Fb5CA928592a73a29A42BCf0B1, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0xfCe146bF3146100cfe5dB4129cf6C82b0eF4Ad8c] =
            LenderTokens(0x7F746A80506a4cafA39938f7C08Ad59cFa6dE418, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x250632378E573c6Be1AC2f97Fcdf00515d0Aa91B] =
            LenderTokens(0xDCf60E349a5AAeeEcdd2fb6772931FBF3486eD1C, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x9678E42ceBEb63F23197D726B29b1CB20d0064E5] =
            LenderTokens(0xc17C8C5b8bB9456c624f8534FdE6cBda2451488C, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x47BEAd2563dCBf3bF2c9407fEa4dC236fAbA485A] =
            LenderTokens(0xa8D75A0D17D2f4F2f4673975Ab8470269D019c96, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x947950BcC74888a40Ffa2593C5798F11Fc9124C4] =
            LenderTokens(0x9B53e7D5e3F6Cc8694840eD6C9f7fee79e7Bcee5, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] =
            LenderTokens(0x15CC701370cb8ADA2a2B6f4226eC5CF6AA93bC67, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d] =
            LenderTokens(0x7e545CAa813b102D2c6Bfb7d6b07A0ea699CcAc2, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE][0x000Ae314E2A2172a039B26378814C252734f556A] =
            LenderTokens(0x8166974222577F9ef674c1633f0742256f5A06cf, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174] =
            LenderTokens(0x73CF8c5D14Aa0EbC89f18272A568319F5BAB6cBD, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0xc2132D05D31c914a87C6611C10748AEb04B58e8F] =
            LenderTokens(0xf976C9bc0E16B250E0B1523CffAa9E4c07Bc5C8a, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063] =
            LenderTokens(0x4eCEDdF62277eD78623f9A94995c680f8fd6C00e, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270] =
            LenderTokens(0x3FaE5e5722C51cdb5B0afD8c7082e8a6AF336Ee8, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619] =
            LenderTokens(0x7ef18d0a9C3Fb1A716FF6c3ED0Edf52a2427F716, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6] =
            LenderTokens(0x5Dc3A30d8c5937f1529C3c93507C16d86A17072A, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x53E0bca35eC356BD5ddDFebbD1Fc0fD03FaBad39] =
            LenderTokens(0x20d5d319C2964ecb52e1B006a4C059b7f6d6ad0a, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x0b3F868E0BE5597D5DB7fEB59E1CADBb0fdDa50a] =
            LenderTokens(0x468a7BF78f11Da82c90b17a93adb7B14999aF5AB, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x172370d5Cd63279eFa6d502DAB29171933a610AF] =
            LenderTokens(0xE82225bA6BeD28406912522F01C7102DD9f07e78, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x831753DD7087CaC61aB5644b308642cc1c33Dc13] =
            LenderTokens(0x2eE80614Ccbc5e28654324a66A396458Fa5cD7Cc, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0xD6DF932A45C0f255f85145f286eA0b292B21C90B] =
            LenderTokens(0x4486835e0C567A320C0636d8F6e6e6679A46a271, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x85955046DF4668e1DD369D2DE9f3AEB98DD2A369] =
            LenderTokens(0xfBbfa5fd64246046e683c423aa2AB0470fbD328D, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x3e121107F6F22DA4911079845a470757aF4e1A1b] =
            LenderTokens(0x9B21EB2E30D8320c3c1b8d8465284D78E58cB971, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x50B728D8D964fd00C2d0AAD81718b71311feF68a] =
            LenderTokens(0xd4409B8D17d5d49a7ed9Ae734B0E8EdBa29b9FFA, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0xb33EaAd8d922B1083446DC23f610c2567fB5180f] =
            LenderTokens(0x7ea7174dD0CB4Ab84f42177F01e9a8a79475d381, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE][0x4EaC4c4e9050464067D673102F8E24b2FccEB350] =
            LenderTokens(0x98182BF525A4252C436ac349a4b79c7E6cd0EB7A, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.CREAM_FINANCE][0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8] =
            LenderTokens(0xd5794ea7b269dB3a0CCB396774Cc2D0936FFBD86, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.CREAM_FINANCE][0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] =
            LenderTokens(0x5441090C0401EE256b09DEb35679Ad175d1a0c97, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.CREAM_FINANCE][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] =
            LenderTokens(0x5eb35dAF9EF97E9e8cc33C486Bad884a62CAe9Ce, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.CREAM_FINANCE] = 0x3d5BC3c8d13dcB8bF317092d84783c2697AE9258;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.CREAM_FINANCE] = 0x589DE0F0Ccf905477646599bb3E5C622C84cC0BA;
        lendingControllers[Chains.POLYGON_MAINNET][Lenders.CREAM_FINANCE] = 0x20CA53E2395FA571798623F1cFBD11Fe2C114c24;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.CREAM_FINANCE] = 0xbadaC56c9aca307079e8B8FC699987AAc89813ee;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CAPY_FI][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x37DE57183491Fa9745d8Fa5DCd950f0c3a4645c9, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CAPY_FI][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] =
            LenderTokens(0xDa5928d59ECE82808Af2cbBE4f2872FeA8E12CD6, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CAPY_FI][0xdAC17F958D2ee523a2206206994597C13D831ec7] =
            LenderTokens(0x0f864A3e50D1070adDE5100fd848446C0567362B, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CAPY_FI][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(0xc3aD34De18B59A24BD0877e454Fb924181F09C8f, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CAPY_FI][0xEd025A9Fe4b30bcd68460BCA42583090c2266468] =
            LenderTokens(0xF61159B4a0EE5b1615c9Afb3dA38111043344c32, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.CAPY_FI][0x0DC4F92879B7670e5f4e4e6e3c801D229129D90D] =
            LenderTokens(0xf80eeec09f417Fa7FCc4A848Ef03af9dF2658d7B, address(0), address(0));
        lendingTokens[Chains.WORLD_CHAIN][Lenders.CAPY_FI][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xaAd91abe333c4536FFbF02b83daBaB49C9Aa23ed, address(0), address(0));
        lendingTokens[Chains.WORLD_CHAIN][Lenders.CAPY_FI][0x79A02482A880bCE3F13e09Da970dC34db4CD24d1] =
            LenderTokens(0x05350F1FC5d396917A73FCE318524551e287D1Df, address(0), address(0));
        lendingTokens[Chains.WORLD_CHAIN][Lenders.CAPY_FI][0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3] =
            LenderTokens(0xCdA6e3bF6e6529cdEF7D6BE0B133bEd79390796D, address(0), address(0));
        lendingTokens[Chains.WORLD_CHAIN][Lenders.CAPY_FI][0x2cFc85d8E48F8EAB294be644d9E25C3030863003] =
            LenderTokens(0x57Dd2468FA18023978804240b503D3Ea315eFc95, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.CAPY_FI] = 0x0b9af1fd73885aD52680A1aeAa7A3f17AC702afA;
        lendingControllers[Chains.WORLD_CHAIN][Lenders.CAPY_FI] = 0x589d63300976759a0fc74ea6fA7D951f581252D7;
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599] =
            LenderTokens(0x5812fCF91adc502a765E5707eBB3F36a07f63c02, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x5ACD75f21659a59fFaB9AEBAf350351a8bfaAbc0, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0xdAC17F958D2ee523a2206206994597C13D831ec7] =
            LenderTokens(0x1180c114f7fAdCB6957670432a3Cf8Ef08Ab5354, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] =
            LenderTokens(0x2f956b2f801c6dad74E87E7f45c94f6283BF0f45, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x6B175474E89094C44Da98b954EedeAC495271d0F] =
            LenderTokens(0x298f243aD592b6027d4717fBe9DeCda668E3c3A8, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x4Fabb145d64652a948d72533023f6E7A623C7C53] =
            LenderTokens(0x24677e213DeC0Ea53a430404cF4A11a6dc889FCe, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x0316EB71485b0Ab14103307bf65a021042c6d380] =
            LenderTokens(0x47566acD7af49D2a192132314826ed3c3c5f3698, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x431ad2ff6a9C365805eBaD47Ee021148d6f7DBe0] =
            LenderTokens(0xb3dc7425e63E1855Eb41107134D471DD34d7b239, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984] =
            LenderTokens(0xbeC9A824D6dA8d0F923FD9fbec4FAA949d396320, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x0a5E677a6A24b2F1A2Bf4F3bFfC443231d2fDEc8] =
            LenderTokens(0xd1254d280e7504836e1B0E36535eBFf248483cEE, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0xb986F3a2d91d3704Dc974A24FB735dCc5E3C1E70] =
            LenderTokens(0x591595Bfae3f5d51A820ECd20A1e3FBb6638f34B, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x514910771AF9Ca656af840dff83E8264EcF986CA] =
            LenderTokens(0xA3068AA78611eD29d381E640bb2c02abcf3ca7DE, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2] =
            LenderTokens(0x039E7Ef6a674f3EC1D88829B8215ED45385c24bc, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x0000000000085d4780B73119b644AE5ecd22b376] =
            LenderTokens(0x6E6a689a5964083dFf9FD7A0f788BAF620ea2DBe, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0] =
            LenderTokens(0xbfD291DA8A403DAAF7e5E9DC1ec0aCEaCd4848B9, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x853d955aCEf822Db058eb8505911ED77F175b99e] =
            LenderTokens(0x71173e3c6999c2C72ccf363f4Ae7b67BCc7E8F63, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x956F47F50A910163D8BF957Cf5846D573E7f87CA] =
            LenderTokens(0x47C19A2ab52DA26551A22e2b2aEED5d19eF4022F, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9] =
            LenderTokens(0x3e5CB932D7A1c0ca096b71Cc486b2aD7e0DC3D0e, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0xD533a949740bb3306d119CC777fa900bA034cd52] =
            LenderTokens(0xe39672DFa87C824BcB3b38aA480ef684687CBC09, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0xD5147bc8e386d91Cc5DBE72099DAC6C9b99276F5] =
            LenderTokens(0x59055220e00da46C891283EA1d79363c769158b9, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x83F20F44975D03b1b09e64809B757c47f942BEeA] =
            LenderTokens(0x5f02fb5f1203a502c701a12Fd409548993F795ba, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0xae78736Cd615f374D3085123A210448E74Fc6393] =
            LenderTokens(0x33b5EdC15E05D3daC27fCCAd77cf550C5f3f02AA, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0xbC404429558292eE2D769E57d57D6E74bbd2792d] =
            LenderTokens(0x041D2c9250dc0cA2962BE94cF7c4D05abB1d5820, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] =
            LenderTokens(0x6D9Ce334C2cc6b80a4cddf9aEA6D3F4683cf4a50, address(0), address(0));
        lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.UNITUS][0x68749665FF8D2d112Fa859AA293F07A622782F38] =
            LenderTokens(0x7b37231059358931eE81df1F26291270C93f13B2, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x68f180fcCe6836688e9084f035309E29Bf0A2095] =
            LenderTokens(0x24d30216c07Df791750081c8D77C83cc8b06eB27, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] =
            LenderTokens(0x5bedE655e2386AbC49E2Cc8303Da6036bF78564c, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xA7A084538DE04d808f20C785762934Dd5dA7b3B4, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6] =
            LenderTokens(0xDd40BBa0faD6810A7A09e8Ccca9bCe1E48B28Ece, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x7F5c764cBc14f9669B88837ca1490cCa17c31607] =
            LenderTokens(0xB344795f0e7cf65a55cB0DDe1E866D46041A2cc2, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x94b008aA00579c1307B0EF2c499aD98a8ce58e58] =
            LenderTokens(0x5d05c14D71909F4Fe03E13d486CCA2011148FC44, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0xbfD291DA8A403DAAF7e5E9DC1ec0aCEaCd4848B9] =
            LenderTokens(0x94a14Ba6E59f4BE36a77041Ef5590Fe24445876A, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x76FB31fb4af56892A25e32cFC43De717950c9278] =
            LenderTokens(0xD65a18dAE68C846297F3038C93deea0B181288d5, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x0994206dfE8De6Ec6920FF4D779B0d950605Fb53] =
            LenderTokens(0xED3c20d047D2c57C3C6DD862C9FDd1b353Aff36f, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x9e5AAC1Ba1a2e6aEd6b32689DFcF62A509Ca96f3] =
            LenderTokens(0x6832364e9538Db15655FA84A497f2927F74A6cE6, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x4200000000000000000000000000000000000042] =
            LenderTokens(0x7702dC73e8f8D9aE95CF50933aDbEE68e9F1D725, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9] =
            LenderTokens(0x1f144cD63d7007945292EBCDE14a6Df8628e2Ed7, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb] =
            LenderTokens(0x4B3488123649E8A671097071A02DA8537fE09A16, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85] =
            LenderTokens(0x0fD11B5ED5B82Ef454BEe2516D1b23d1b07b6c46, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0x9Bcef72be871e61ED4fBbc7630889beE758eb81D] =
            LenderTokens(0x107d8661C2617B498941AfE8c2FbEa6b6976F71e, address(0), address(0));
        lendingTokens[Chains.OP_MAINNET][Lenders.UNITUS][0xbC404429558292eE2D769E57d57D6E74bbd2792d] =
            LenderTokens(0xc0BD38f08CDb278d0ff39E5c1996e4dc5062309C, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56] =
            LenderTokens(0x5511b64Ae77452C7130670C79298DEC978204a47, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d] =
            LenderTokens(0xAF9c10b341f55465E8785F0F81DBB52a9Bfe005d, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x55d398326f99059fF775485246999027B3197955] =
            LenderTokens(0x0BF8C72d618B5d46b055165e21d661400008fa0F, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3] =
            LenderTokens(0xAD5Ec11426970c32dA48f58c92b1039bC50e5492, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x4A9A2b2b04549C3927dd2c9668A5eF3fCA473623] =
            LenderTokens(0xeC3FD540A2dEE6F479bE539D64da593a59e12D08, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c] =
            LenderTokens(0x0b66A250Dadf3237DdB38d485082a7BfE400356e, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x2170Ed0880ac9A755fd29B2688956BD959F933F8] =
            LenderTokens(0x390bf37355e9dF6Ea2e16eEd5686886Da6F47669, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0xBf5140A22578168FD562DCcF235E5D43A02ce9B1] =
            LenderTokens(0xee9099C1318cf960651b3196747640EB84B8806b, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x0Eb3a705fc54725037CC9e008bDede697f62F335] =
            LenderTokens(0x55012aD2f0A50195aEF44f403536DF2465009Ef7, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402] =
            LenderTokens(0x9ab060ba568B86848bF19577226184db6192725b, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153] =
            LenderTokens(0xD739A569Ec254d6a20eCF029F024816bE58Fb810, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47] =
            LenderTokens(0xFc5Bb1E8C29B100Ef8F12773f972477BCab68862, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xd57E1425837567F74A35d07669B23Bfb67aA4A93, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0xB5102CeE1528Ce2C760893034A4603663495fD72] =
            LenderTokens(0x36f4C36D1F6e8418Ecb2402F896B2A8fEDdE0991, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x367c17D19fCd0f7746764455497D63c8e8b2BbA3] =
            LenderTokens(0xb22eF996C0A2D262a19db2a66A256067f51511Eb, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE] =
            LenderTokens(0x6D64eFfe3af8697336Fc57efD5A7517Ad526Dd6d, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x4338665CBB7B2485A8855A139b75D5e34AB0DB94] =
            LenderTokens(0xd957BEa67aaDb8a72061ce94D033C631D1C1E6aC, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD] =
            LenderTokens(0x50E894894809F642de1E11B4076451734c963087, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82] =
            LenderTokens(0xeFae8F7AF4BaDa590d4E707D900258fc72194d73, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf] =
            LenderTokens(0x9747e26c5Ad01D3594eA49ccF00790F564193c15, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0x16939ef78684453bfDFb47825F8a5F714f12623a] =
            LenderTokens(0x8be8cd81737b282C909F1911f3f0AdE630c335AA, address(0), address(0));
        lendingTokens[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS][0xbC404429558292eE2D769E57d57D6E74bbd2792d] =
            LenderTokens(0xc0BD38f08CDb278d0ff39E5c1996e4dc5062309C, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.UNITUS][0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174] =
            LenderTokens(0x5268b3c4afb0860D365a093C184985FCFcb65234, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.UNITUS][0xc2132D05D31c914a87C6611C10748AEb04B58e8F] =
            LenderTokens(0xb3ab7148cCCAf66686AD6C1bE24D83e58E6a504e, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.UNITUS][0xCf66EB3D546F0415b368d98A95EAF56DeD7aA752] =
            LenderTokens(0xc171EBE1A2873F042F1dDdd9327D00527CA29882, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.UNITUS][0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063] =
            LenderTokens(0xec85F77104Ffa35a5411750d70eDFf8f1496d95b, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.UNITUS][0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619] =
            LenderTokens(0x0c92617dF0753Af1CaB2d9Cc6A56173970d81740, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.UNITUS][0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6] =
            LenderTokens(0x94a14Ba6E59f4BE36a77041Ef5590Fe24445876A, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.UNITUS][0xD6DF932A45C0f255f85145f286eA0b292B21C90B] =
            LenderTokens(0x38D0c498698A35fc52a6EB943E47e4A5471Cd6f9, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.UNITUS][0x172370d5Cd63279eFa6d502DAB29171933a610AF] =
            LenderTokens(0x7D86eE431fbAf60E86b5D3133233E478aF691B68, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.UNITUS][0x08C15FA26E519A78a666D19CE5C646D55047e0a3] =
            LenderTokens(0xcB5D9b6A9BA8eA6FA82660fAA9cC130586F939B2, address(0), address(0));
        lendingTokens[Chains.POLYGON_MAINNET][Lenders.UNITUS][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x6A3fE5342a4Bd09efcd44AC5B9387475A0678c74, address(0), address(0));
        lendingTokens[Chains.CONFLUX_ESPACE][Lenders.UNITUS][0x1F545487c62e5ACfEa45dcAdd9c627361d1616D8] =
            LenderTokens(0xE08020a6517c1AD321D47c45Efbe1d76F5035d75, address(0), address(0));
        lendingTokens[Chains.CONFLUX_ESPACE][Lenders.UNITUS][0xa47f43DE2f9623aCb395CA4905746496D2014d57] =
            LenderTokens(0x620e8Ed48945d97CBea0B794F50E5e51950EbA24, address(0), address(0));
        lendingTokens[Chains.CONFLUX_ESPACE][Lenders.UNITUS][0xfe97E85d13ABD9c1c33384E796F10B73905637cE] =
            LenderTokens(0xC80aD49191113d31fe52427c01A197106ef5EB5b, address(0), address(0));
        lendingTokens[Chains.CONFLUX_ESPACE][Lenders.UNITUS][0x6963EfED0aB40F6C3d7BdA44A05dcf1437C44372] =
            LenderTokens(0xb88DC5AaE0C26903230ebc9a6fBAb8D511AF9897, address(0), address(0));
        lendingTokens[Chains.CONFLUX_ESPACE][Lenders.UNITUS][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x25CCd7E60550EF32266fA90441BcE2BA742d88bc, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.UNITUS][0x0000000000000000000000000000000000000000] =
            LenderTokens(0x76B5f31A3A6048A437AfD86be6E1a40888Dc8Bba, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.UNITUS][0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452] =
            LenderTokens(0xf8fBD6202FBcfC607E31A99300e6c84C2645902f, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.UNITUS][0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22] =
            LenderTokens(0x6D9Ce334C2cc6b80a4cddf9aEA6D3F4683cf4a50, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.UNITUS][0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] =
            LenderTokens(0xBb81632e9e1Fb675dB5e5a5ff66f16E822c9a2FD, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.UNITUS][0xc142171B138DB17a1B7Cb999C44526094a4dae05] =
            LenderTokens(0x82AFc965E4E18009DD8d5AF05cfAa99bF0E605df, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.UNITUS][0xbC404429558292eE2D769E57d57D6E74bbd2792d] =
            LenderTokens(0x03cD2CfdC2DAB4949F46b2E4B7D1544302731398, address(0), address(0));
        lendingTokens[Chains.BASE][Lenders.UNITUS][0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf] =
            LenderTokens(0x7a2F91Ab4D5E97dE41c1df46d4A923D40CE224Dd, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] =
            LenderTokens(0xD3204E4189BEcD9cD957046A8e4A643437eE0aCC, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0x0000000000000000000000000000000000000000] =
            LenderTokens(0xEe338313f022caee84034253174FA562495dcC15, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8] =
            LenderTokens(0x8dc3312c68125a94916d62B97bb5D925f84d4aE0, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0x641441c631e2F909700d2f41FD87F0aA6A6b4EDb] =
            LenderTokens(0xe8c85B60Cb3bA32369c699015621813fb2fEA56c, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] =
            LenderTokens(0xf52f079Af080C9FB5AFCA57DDE0f8B83d49692a9, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0] =
            LenderTokens(0x46Eca1482fffb61934C4abCA62AbEB0b12FEb17A, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0xf97f4df75117a78c1A5a0DBb814Af92458539FB4] =
            LenderTokens(0x013ee4934ecbFA5723933c4B08EA5E47449802C8, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0xaE6aab43C4f3E0cea4Ab83752C278f8dEbabA689] =
            LenderTokens(0xaEa8e2e7C97C5B7Cd545d3b152F669bAE29C4a63, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1] =
            LenderTokens(0xf6995955e4B0E5b287693c221f456951D612b628, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F] =
            LenderTokens(0xb3ab7148cCCAf66686AD6C1bE24D83e58E6a504e, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0xba5DdD1f9d7F570dc94a51479a000E3BCE967196] =
            LenderTokens(0x7702dC73e8f8D9aE95CF50933aDbEE68e9F1D725, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978] =
            LenderTokens(0x662da37F0B992F58eF0d9b482dA313a3AB639C0D, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0x5979D7b546E38E414F7E9822514be443A4800529] =
            LenderTokens(0xa8bAd6CE1937F8e047bcA239Cff1f2224B899b23, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0x912CE59144191C1204E64559FE8253a0e49E6548] =
            LenderTokens(0xD037c36dbc81a8890728D850E080e38F6EeB95EF, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0xaf88d065e77c8cC2239327C5EDb3A432268e5831] =
            LenderTokens(0x70284c0C2dFa98a972c5c8cbE32a0b7f90b3B578, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8] =
            LenderTokens(0xFD7e2EACAB5Fd983a2189eB6A38c3ee2aD9F69Df, address(0), address(0));
        lendingTokens[Chains.ARBITRUM_ONE][Lenders.UNITUS][0xbC404429558292eE2D769E57d57D6E74bbd2792d] =
            LenderTokens(0xB276FB21e29E8055044d31d093F8f1A4a88CA0BC, address(0), address(0));
        lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.UNITUS] = 0x8B53Ab2c0Df3230EA327017C91Eb909f815Ad113;
        lendingControllers[Chains.OP_MAINNET][Lenders.UNITUS] = 0xA300A84D8970718Dac32f54F61Bd568142d8BCF4;
        lendingControllers[Chains.BNB_SMART_CHAIN_MAINNET][Lenders.UNITUS] = 0x0b53E608bD058Bb54748C35148484fD627E6dc0A;
        lendingControllers[Chains.POLYGON_MAINNET][Lenders.UNITUS] = 0x52eaCd19E38D501D006D2023C813d7E37F025f37;
        lendingControllers[Chains.CONFLUX_ESPACE][Lenders.UNITUS] = 0xA377eCF53253275125D0a150aF195186271f6a56;
        lendingControllers[Chains.BASE][Lenders.UNITUS] = 0xBae8d153331129EB40E390A7Dd485363135fcE22;
        lendingControllers[Chains.ARBITRUM_ONE][Lenders.UNITUS] = 0x8E7e9eA9023B81457Ae7E6D2a51b003D421E5408;

        // Initialize token addresses
        tokens[Chains.ETHEREUM_MAINNET][Tokens.WETH] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH] = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.WBTC] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USDC] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.DAI] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.LINK] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.AAVE] = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.CBETH] = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USDT] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RETH] = 0xae78736Cd615f374D3085123A210448E74Fc6393;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.LUSD] = 0x5f98805A4E8be255a32880FDeC7F6728C6568bA0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.CRV] = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.MKR] = 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SNX] = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.BAL] = 0xba100000625a3754423978a60c9317c58a424e3D;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.UNI] = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.LDO] = 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ENS] = 0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ONE_INCH] = 0x111111111117dC0aa78b770fA6A738034120C302;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.FRAX] = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.GHO] = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RPL] = 0xD33526068D116cE69F19A9ee46F0bd304F21A51f;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SDAI] = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.STG] = 0xAf5191B0De278C7286d6C7CC6ab6BB8A73bA2Cd6;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.KNC] = 0xdeFA4e8a7bcBA345F687a2f1456F5Edd9CE97202;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.FXS] = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.CRVUSD] = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PYUSD] = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.WEETH] = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.OSETH] = 0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USDE] = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ETHX] = 0xA35b1B31Ce002FBF2058D22F30f95D405200A15b;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SUSDE] = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.TBTC] = 0x18084fbA666a33d37592fA2633fD49a74DD93a88;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.CBBTC] = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USDS] = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RSETH] = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.LBTC] = 0x8236a87084f8B84306f72007F36F2618A5634494;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.EBTC] = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RLUSD] = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_EUSDE_29MAY2025] = 0x50D2C7992b802Eef16c04FeADAB310f31866a545;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_SUSDE_31JUL2025] = 0x3b3fB9C57858EF816833dC91565EFcd85D96f634;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USDTB] = 0xC139190F447e929f090Edeb554D95AbB8b18aC1C;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_USDE_31JUL2025] = 0x917459337CaAC939D41d7493B3999f571D20D667;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_EUSDE_14AUG2025] = 0x14Bdc3A3AE09f5518b923b69489CBcAfB238e617;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.EUSDE] = 0x90D2af7d622ca3141efA4d8f1F24d86E5974Cc8F;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.FBTC] = 0xC96dE26018A54D51c097160568752c4E3BD6C364;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.EURC] = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_SUSDE_25SEP2025] = 0x9F56094C450763769BA0EA9Fe2876070c0fD5F77;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_USDE_25SEP2025] = 0xBC6736d346a5eBC0dEbc997397912CD9b8FAe10a;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.TETH] = 0xD11c452fc99cF405034ee446803b6F6c1F6d5ED8;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.EZETH] = 0xbf5495Efe5DB9ce00f80364C8B423567e58d2110;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.XAUT] = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_SUSDE_27NOV2025] = 0xe6A934089BBEe34F832060CE98848359883749B3;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_USDE_27NOV2025] = 0x62C6E813b9589C3631Ba0Cdb013acdB8544038B7;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_USDE_5FEB2026] = 0x1F84a51296691320478c98b8d77f2Bbd17D34350;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_SUSDE_5FEB2026] = 0xE8483517077afa11A9B07f849cee2552f040d7b2;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.MUSD] = 0xacA92E438df0B2401fF60dA7E4337B687a2435DA;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SYRUPUSDT] = 0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USDG] = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_USDE_7MAY2026] = 0xAeBf0Bb9f57E89260d57f31AF34eB58657d96Ce0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_SUSDE_7MAY2026] = 0x3de0ff76E8b528C092d47b9DaC775931cef80F49;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_SRUSDE_2APR2026] = 0x9Bf45ab47747F4B4dD09B3C2c73953484b4eB375;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USTB] = 0x43415eB6ff9DB7E26A15b704e7A3eDCe97d31C4e;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USCC] = 0x14d60E7FDC0D71d8611742720E4C50E7a974020c;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USYC] = 0x136471a34f6ef19fE571EFFC1CA711fdb8E49f2b;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.JTRSY] = 0x8c213ee79581Ff4984583C6a801e5263418C4b86;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.JAAA] = 0x5a0F93D040De44e78F251b03c43be9CF317Dcf64;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.VBILL] = 0x2255718832bC9fD3bE1CaF75084F4803DA14FF01;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.YFI] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ZRX] = 0xE41d2489571d322189246DaFA5ebDe1F4699F498;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.BAT] = 0x0D8775F648430679A709E98d2b0Cb6250d2887EF;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.BUSD] = 0x4Fabb145d64652a948d72533023f6E7A623C7C53;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ENJ] = 0xF629cBd94d3791C9250152BD8dfBDF380E2a3B9c;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.KNC] = 0xdd974D5C2e2928deA5F71b9825b8b646686BD200;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.MANA] = 0x0F5D2fB29fb7d3CFeE444a200298f468908cC942;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.REN] = 0x408e41876cCCDC0F92210600ef50372656052a38;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SUSD] = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.TUSD] = 0x0000000000085d4780B73119b644AE5ecd22b376;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.GUSD] = 0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.XSUSHI] = 0x8798249c2E607446EfB7Ad49eC89dD1865Ff4272;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RENFIL] = 0xD5147bc8e386d91Cc5DBE72099DAC6C9b99276F5;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RAI] = 0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.AMPL] = 0xD46bA6D942050d489DBd938a2C909A5d5039A161;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USDP] = 0x8E870D67F660D95d5be530380D0eC0bd388289E1;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.DPI] = 0x1494CA1F11D487c2bBe4543E90080AeBa4BA3C2b;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.FEI] = 0x956F47F50A910163D8BF957Cf5846D573E7f87CA;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.STETH] = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.UST] = 0xa693B19d2931d498c5B318dF961919BB4aee87a5;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.CVX] = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.GNO] = 0x6810e776880C02933D47DB1b9fc05908e5386b96;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SUSDS] = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PAXG] = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SOLVBTC] = 0x7A56E1C57C7475CCf742a1832B028F0456652F97;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.XSOLVBTC] = 0xd9D920AA40f578ab794426F5C90F6C731D159DEf;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_CORN_SOLVBTC_BBN_26DEC2024] = 0x23e479ddcda990E8523494895759bD98cD2fDBF6;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PUMPBTC] = 0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SWBTC] = 0x8DB2350D78aBc13f5673A411D4700BCF87864dDE;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_CORNLBTC_26DEC2024] = 0x332A8ee60EdFf0a11CF3994b1b846BBC27d3DcD6;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_EBTC_26DEC2024] = 0xB997B3418935A1Df0F914Ee901ec83927c1509A0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_LBTC_27MAR2025] = 0xEc5a52C685CC3Ad79a6a347aBACe330d69e0b1eD;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PUFETH] = 0xD9A442856C234a39a81a089C06451EBAa4306a72;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USD0] = 0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USDZ] = 0x69000405f9DcE69BD4Cbf4f2865b79144A69BFE0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.EUSD] = 0x939778D83b46B456224A33Fb59630B11DEC56663;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USD0_PLUS_PLUS_] = 0x35D8949372D46B7a3D5A56006AE77B215fc69bC0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_USD0_PLUS_PLUS__31OCT2024] = 0x270d664d2Fc7D962012a787Aec8661CA83DF24EB;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.STUSD] = 0x0022228a2cc5E7eF0274A7Baa600d44da5aB5776;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_USD0_PLUS_PLUS__27MAR2025] = 0x5BaE9a5D67d1CA5b09B14c91935f635CFBF3b685;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SYRUPUSDC] = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.STKGHO] = 0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_SUSDE_27MAR2025] = 0xE00bd3Df25fb187d6ABBB620b3dfd19839947b81;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_USDE_27MAR2025] = 0x8A47b431A7D947c6a3ED6E42d501803615a97EAa;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ZAI] = 0x69000dFD5025E82f48Eb28325A2B88a241182CEd;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SZAI] = 0x69000195D5e3201Cf73C9Ae4a1559244DF38D47C;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SUSD] = 0x4F8E1426A9d10bddc11d26042ad270F16cCb95F2;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.YUSD] = 0x1CE7D9942ff78c328A4181b9F3826fEE6D845A97;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SWETH] = 0xf951E335afb289353dc249e82926178EaC7DEd78;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PZETH] = 0x8c9532a60E0E7C6BbD2B2c1303F63aCE1c3E9811;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_RSETH_26SEP2024] = 0x7bAf258049cc8B9A78097723dc19a8b103D4098F;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_EZETH_26DEC2024] = 0xf7906F274c174A52d444175729E3fa98f9bde285;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.M_BTC] = 0x2F913C820ed3bEb3a67391a6eFF64E70c4B20b19;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_CORN_EBTC_27MAR2025] = 0x44A7876cA99460ef3218bf08b5f52E2dbE199566;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.COMP] = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.DEUSD] = 0x15700B564Ca08D9439C58cA5053166E8317aa138;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SDEUSD] = 0x5C5b196aBE0d54485975D1Ec29617D42D9198326;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RSWETH] = 0xFAe103DC9cf190eD75350761e95403b7b8aFa6c0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.WOETH] = 0xDcEe70654261AF21C44c093C300eD3Bb97b78192;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.WUSDM] = 0x57F5E098CaD7A3D1Eed53991D4d66C45C9AF7812;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SFRAX] = 0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.METH] = 0xd5F7838F5C461fefF7FE49ea5ebaF7728bB0ADfa;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SKY] = 0x56072C95FAA701256059aa122697B133aDEd9279;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.EIGEN] = 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.YVUSDC_1] = 0xBe53A109B494E5c9f97b9Cd39Fe969BE68BF6204;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.YVUSDT_1] = 0x310B7Ea7475A0B449Cfd73bE81522F1B88eFAFaa;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.YVUSDS_1] = 0x182863131F9a4630fF9E27830d945B1413e347E8;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.YVWETH_1] = 0xc56413869c6CDf96496f2b1eF801fEDBdFA7dDB0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.WEETHS] = 0x917ceE801a67f933F2e6b33fC0cD1ED2d5909D88;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_WEETH_26DEC2024] = 0x6ee2b5E19ECBa773a352E5B21415Dc419A700d1d;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SFRXETH] = 0xac3E018457B222d93114458476f3E3416Abbe38F;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ETH] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_WEETH_26SEP2024] = 0x1c085195437738d73d75DC64bC5A3E098b7f93b1;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_PUFETH_26SEP2024] = 0xd4e75971eAF78a8d93D96df530f1FFf5f9F53288;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SUUSD] = 0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SUETH] = 0x1c22531AA9747d76fFF8F0A43b37954ca67d28e0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SUBTC] = 0xe85411C030fB32A9D8b14Bbbc6CB19417391F711;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_SUSDE_26SEP2024] = 0x6c9f097e044506712B58EAC670c9a5fd4BCceF13;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_RSETH_26DEC2024] = 0xB07b9fDd62DC478E521E8bDe3630a777725B0eB4;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PT_PUFETH_26DEC2024] = 0xF6fd7Ceb095BfD54130359Cc9366a1493944213A;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.OUSG] = 0x1B19C19393e2d034D8Ff31ff34c81252FcBbee92;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.REP] = 0x1985365e9f78359a9B6AD760e32412f4a445E862;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SAI] = 0x89d24A6b4CcB1B6fAA2625fE562bDD9a23260359;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SUSHI] = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.YFII] = 0xa1d0E215a23d7030842FC67cE582a6aFa3CCaB83;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.LRC] = 0xBBbbCA6A901c926F240b89EacB641d8Aec7AEafD;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.XLON] = 0xf88506B0F1d30056B9e5580668D5875b9cd30F23;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USTC] = 0xa47c8bf37f92aBed4A126BDA807A7b7498661acD;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.YCURVE] = 0xdF5e0e81Dff6FAF3A7e52BA697820c5e32D806A8;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.CREAM] = 0x2ba592F78dB6436527729929AAf6c908497cB200;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.LEND] = 0x80fB784B7eD66730e8b1DBd9820aFD29931aab03;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RENBTC] = 0xEB4C2781e4ebA804CE9a9803C67d0893436bB27D;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.MTA] = 0xa3BeD4E1c75D00fa6f4E5E6922DB7261B5E9AcD2;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.YUSD] = 0x5dbcF33D8c2E976c6b560249878e6F1491Bca25c;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.FTT] = 0x50D1c9771902476076eCFc8B2A83Ad6b9355a4c9;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SRM] = 0x476c5E26a75bd202a9683ffD34359C0CC15be0fF;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.WNXM] = 0x0d438F3b5175Bebc262bF23753C1E53d03432bDE;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SWAG] = 0x87eDfFDe3E14c7a66c9b9724747a1C5696b742e6;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.CEL] = 0xaaAEBE6Fe48E54f431b0C390CfaF0b017d09D42d;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.BBTC] = 0x9BE89D2a4cd102D8Fecc6BF9dA793be995C22541;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.BOND] = 0x0391D2021f89DC339F60Fff84546EA23E337750f;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.KP3R] = 0x1cEB5cB57C4D4E2b2433641b95Dd330A33185A44;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.HBTC] = 0x0316EB71485b0Ab14103307bf65a021042c6d380;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.CRETH2] = 0xcBc1065255cBc3aB41a6868c22d1f1C573AB89fd;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.HUSD] = 0xdF574c24545E5FfEcb9a659c229253D4111d87e1;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.HEGIC] = 0x584bC13c7D411c00c01A62e8019472dE68768430;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ESD] = 0x36F3FD68E7325a35EB768F1AedaAe9EA0689d723;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.COVER] = 0x4688a8b1F292FDaB17E9a90c8Bc379dC1DBd8713;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.OCEAN] = 0x967da4048cD07aB37855c090aAF366e4ce1b9F48;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.OMG] = 0xd26114cd6EE289AccF82350c8d8487fedB8A0C07;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.UNIV2WBTCETH] = 0xBb2b8038a1640196FbE3e38816F3e67Cba72D940;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.UNIV2ETHUSDT] = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.UNIV2USDCETH] = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.UNIV2DAIETH] = 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PICKLE] = 0x429881672B9AE42b8EbA0E26cD9C73711b891Ca5;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.AKRO] = 0x8Ab7404063Ec4DBcfd4598215992DC3F8EC853d7;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.BBADGER] = 0x19D97D8fA813EE2f51aD4B4e04EA08bAf4DFfC28;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.OGN] = 0x8207c1FfC5B6804F6024322CcF34F29c3541Ae26;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.AMP] = 0xfF20817765cB7f73d4bde2e66e067E58D11095C2;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RARI] = 0xFca59Cd816aB1eaD66534D82bc21E7515cE441CF;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ALPHA] = 0xa1faa113cbE53436Df28FF0aEe54275c13B40975;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.FTM] = 0x4E15361FD6b4BB609Fa63C81A2be19d873717870;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RUNE] = 0x3155BA85D5F96b2d030a4966AF206230e46849cb;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.PERP] = 0xbC396689893D065F41bc2C6EcbeE5e0085233447;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SFI] = 0xb753428af26E81097e7fD17f40c88aaA3E04902c;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ARMOR] = 0x1337DEF16F9B486fAEd0293eb623Dc8395dFE46a;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.ARNXM] = 0x1337DEF18C680aF1f9f45cBcab6309562975b1dD;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.MLN] = 0xec67005c4E498Ec7f55E092bd1d35cbC47C91892;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.VSP] = 0x1b40183EFB4Dd766f11bDa7A7c3AD8982e998421;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.VVSP] = 0xbA4cFE5741b357FA371b506e5db0774aBFeCf8Fc;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SWAP] = 0xCC4304A31d09258b0029eA7FE63d032f52e44EFe;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.WOO] = 0x4691937a7508860F876c9c0a2a617E7d9E945D4B;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.BNT] = 0x1F573D6Fb3F13d689FF844B4cE37794d79a7FF1C;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.EURT] = 0xC581b735A1688071A1746c968e0798D642EDE491;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.IBBTC] = 0xc4E15973E6fF2A35cC804c2CF9D2a1b817a8b40F;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.LON] = 0x0000000000095413afC295d19EDeb1Ad7B71c952;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.YGG] = 0x25f8087EAD173b73D6e8B84329989A8eEA16CF73;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.AXS] = 0xBB0E17EF65F82Ab018d8EDd776e8DD940327B28b;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SAND] = 0x3845badAde8e6dFF049820680d1F14bD3903a5d0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.MIM] = 0x99D8a9C45b2ecA8864373A26D1459e3Dff1e17F3;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.RPC] = 0xEd025A9Fe4b30bcd68460BCA42583090c2266468;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.WARS] = 0x0DC4F92879B7670e5f4e4e6e3c801D229129D90D;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.DF] = 0x431ad2ff6a9C365805eBaD47Ee021148d6f7DBe0;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.USX] = 0x0a5E677a6A24b2F1A2Bf4F3bFfC443231d2fDEc8;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.EUX] = 0xb986F3a2d91d3704Dc974A24FB735dCc5E3C1E70;
        tokens[Chains.ETHEREUM_MAINNET][Tokens.SUSX] = 0xbC404429558292eE2D769E57d57D6E74bbd2792d;
        tokens[Chains.OP_MAINNET][Tokens.DAI] = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        tokens[Chains.OP_MAINNET][Tokens.LINK] = 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6;
        tokens[Chains.OP_MAINNET][Tokens.USDC_E] = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
        tokens[Chains.OP_MAINNET][Tokens.WBTC] = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;
        tokens[Chains.OP_MAINNET][Tokens.WETH] = 0x4200000000000000000000000000000000000006;
        tokens[Chains.OP_MAINNET][Tokens.USDT] = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
        tokens[Chains.OP_MAINNET][Tokens.AAVE] = 0x76FB31fb4af56892A25e32cFC43De717950c9278;
        tokens[Chains.OP_MAINNET][Tokens.SUSD] = 0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9;
        tokens[Chains.OP_MAINNET][Tokens.OP] = 0x4200000000000000000000000000000000000042;
        tokens[Chains.OP_MAINNET][Tokens.WSTETH] = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
        tokens[Chains.OP_MAINNET][Tokens.LUSD] = 0xc40F949F8a4e094D1b49a23ea9241D289B7b2819;
        tokens[Chains.OP_MAINNET][Tokens.MIMATIC] = 0xdFA46478F9e5EA86d57387849598dbFB2e964b02;
        tokens[Chains.OP_MAINNET][Tokens.RETH] = 0x9Bcef72be871e61ED4fBbc7630889beE758eb81D;
        tokens[Chains.OP_MAINNET][Tokens.USDC] = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
        tokens[Chains.OP_MAINNET][Tokens.BAL] = 0xFE8B128bA8C78aabC59d4c64cEE7fF28e9379921;
        tokens[Chains.OP_MAINNET][Tokens.SNX] = 0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4;
        tokens[Chains.OP_MAINNET][Tokens.CBETH] = 0xadDb6A0412DE1BA0F936DCaeb8Aaa24578dcF3B2;
        tokens[Chains.OP_MAINNET][Tokens.WUSDM] = 0x57F5E098CaD7A3D1Eed53991D4d66C45C9AF7812;
        tokens[Chains.OP_MAINNET][Tokens.EZETH] = 0x2416092f143378750bb29b79eD961ab195CcEea5;
        tokens[Chains.OP_MAINNET][Tokens.WEETH] = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
        tokens[Chains.OP_MAINNET][Tokens.WRSETH] = 0x87eEE96D50Fb761AD85B1c982d28A042169d61b1;
        tokens[Chains.OP_MAINNET][Tokens.VELO] = 0x3c8B650257cFb5f272f799F5e2b4e65093a11a05;
        tokens[Chains.OP_MAINNET][Tokens.VELO] = 0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
        tokens[Chains.OP_MAINNET][Tokens.USDT0] = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;
        tokens[Chains.OP_MAINNET][Tokens.ETH] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.OP_MAINNET][Tokens.USX] = 0xbfD291DA8A403DAAF7e5E9DC1ec0aCEaCd4848B9;
        tokens[Chains.OP_MAINNET][Tokens.CRV] = 0x0994206dfE8De6Ec6920FF4D779B0d950605Fb53;
        tokens[Chains.OP_MAINNET][Tokens.DF] = 0x9e5AAC1Ba1a2e6aEd6b32689DFcF62A509Ca96f3;
        tokens[Chains.OP_MAINNET][Tokens.SUSX] = 0xbC404429558292eE2D769E57d57D6E74bbd2792d;
        tokens[Chains.CRONOS_MAINNET][Tokens.USDC] = 0xc21223249CA28397B4B6541dfFaEcC539BfF0c59;
        tokens[Chains.CRONOS_MAINNET][Tokens.WBTC] = 0x062E66477Faf219F25D27dCED647BF57C3107d52;
        tokens[Chains.CRONOS_MAINNET][Tokens.ETH] = 0xe44Fd7fCb2b1581822D0c862B68222998a0c299a;
        tokens[Chains.CRONOS_MAINNET][Tokens.CRO] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.CRONOS_MAINNET][Tokens.DAI] = 0xF2001B145b43032AAF5Ee2884e456CCd805F677D;
        tokens[Chains.CRONOS_MAINNET][Tokens.USDT] = 0x66e428c3f67a68878562e79A0234c1F83c208770;
        tokens[Chains.CRONOS_MAINNET][Tokens.TONIC] = 0xDD73dEa10ABC2Bff99c60882EC5b2B81Bb1Dc5B2;
        tokens[Chains.CRONOS_MAINNET][Tokens.TUSD] = 0x87EFB3ec1576Dec8ED47e58B832bEdCd86eE186e;
        tokens[Chains.CRONOS_MAINNET][Tokens.ATOM] = 0xB888d8Dd1733d72681b30c00ee76BDE93ae7aa93;
        tokens[Chains.CRONOS_MAINNET][Tokens.ADA] = 0x0e517979C2c1c1522ddB0c73905e0D39b3F990c0;
        tokens[Chains.CRONOS_MAINNET][Tokens.VVS] = 0x2D03bECE6747ADC00E1a131BBA1469C15fD11e03;
        tokens[Chains.CRONOS_MAINNET][Tokens.XRP] = 0xb9Ce0dd29C91E02d4620F57a66700Fc5e41d6D15;
        tokens[Chains.CRONOS_MAINNET][Tokens.LTC] = 0x9d97Be214b68C7051215BB61059B4e299Cd792c3;
        tokens[Chains.CRONOS_MAINNET][Tokens.LCRO] = 0x9Fae23A2700FEeCd5b93e43fDBc03c76AA7C08A6;
        tokens[Chains.CRONOS_MAINNET][Tokens.CDCBTC] = 0x2e53c5586e12a99d4CAE366E9Fc5C14fE9c6495d;
        tokens[Chains.CRONOS_MAINNET][Tokens.CDCETH] = 0x7a7c9db510aB29A2FC362a4c34260BEcB5cE3446;
        tokens[Chains.CRONOS_MAINNET][Tokens.USC] = 0xD42E078ceA2bE8D03cd9dFEcC1f0d28915Edea78;
        tokens[Chains.CRONOS_MAINNET][Tokens.LATOM] = 0xAC974ee7fc5d083112c809cCb3FCe4a4F385750D;
        tokens[Chains.CRONOS_MAINNET][Tokens.FER] = 0x39bC1e38c842C60775Ce37566D03B41A7A66C782;
        tokens[Chains.CRONOS_MAINNET][Tokens.VNO] = 0xdb7d0A1eC37dE1dE924F8e8adac6Ed338D4404E9;
        tokens[Chains.CRONOS_MAINNET][Tokens.FUL] = 0x83aFB1C32E5637ACd0a452D87c3249f4a9F0013A;
        tokens[Chains.CRONOS_MAINNET][Tokens.BCRO] = 0xeBAceB7F193955b946cC5dd8f8724a80671a1F2F;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.ETH] = 0xA0fB8cd450c8Fd3a11901876cD5f17eB47C6bc50;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.USDT] = 0x975Ed13fa16857E83e7C493C7741D556eaaD4A3f;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.USDM] = 0x8f7D64ea96D729EF24a0F30b4526D47b80d877B9;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.USDC] = 0x8D97Cea50351Fb4329d591682b148D43a0C3611b;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.STLOS] = 0xB4B01216a5Bc8F1C8A33CD990A1239030E60C905;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.BTC_B] = 0x7627b27594bc71e6Ab0fCE755aE8931EB1E12DAC;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.WTLOS] = 0xD102cE6A4dB07D247fcc28F366A623Df0938CA9E;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.USDC_E] = 0xF1815bd50389c46847f0Bda824eC8da914045D14;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.USDT] = 0x674843C06FF83502ddb4D37c2E09C01cdA38cbc8;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.WETH] = 0xBAb93B7ad7fE8692A878B95a8e689423437cc500;
        tokens[Chains.TELOS_EVM_MAINNET][Tokens.WBTC] = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
        tokens[Chains.XDC_NETWORK][Tokens.FXD] = 0x49d3f7543335cf38Fa10889CCFF10207e22110B5;
        tokens[Chains.XDC_NETWORK][Tokens.WXDC] = 0x951857744785E80e2De051c32EE7b25f9c458C42;
        tokens[Chains.XDC_NETWORK][Tokens.XUSDT] = 0xD4B5f10D61916Bd6E0860144a91Ac658dE8a1437;
        tokens[Chains.XDC_NETWORK][Tokens.CGO] = 0x8f9920283470F52128bF11B0c14E798bE704fD15;
        tokens[Chains.XDC_NETWORK][Tokens.FTHM] = 0x3279dBEfABF3C6ac29d7ff24A6c46645f3F4403c;
        tokens[Chains.XDC_NETWORK][Tokens.USDC] = 0xfA2958CB79b0491CC627c1557F441eF849Ca8eb1;
        tokens[Chains.XDC_NETWORK][Tokens.USDT] = 0xcdA5b77E2E2268D9E09c874c1b9A4c3F07b37555;
        tokens[Chains.XDC_NETWORK][Tokens.PSXDC] = 0x9B8e12b0BAC165B86967E771d98B520Ec3F665A6;
        tokens[Chains.XDC_NETWORK][Tokens.PRFI] = 0x81B244d0be055EF3BEF1b09B7826Cc2b108B2cBD;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.CAKE] = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.WBNB] = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BTCB] = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.ETH] = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.USDC] = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.USDT] = 0x55d398326f99059fF775485246999027B3197955;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.FDUSD] = 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.WSTETH] = 0x26c5e01524d2E6280A48F2c50fF6De7e52E9611C;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.WBETH] = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.SOLVBTC] = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.SOLVBTC_ENA] = 0x53E63a31fD1077f949204b94F431bCaB98F72BCE;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.XSOLVBTC] = 0x1346b618dC92810EC74163e4c27004c921D446a5;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PT_SOLVBTC_BBN_27MAR2025] = 0x541B5eEAC7D4434C8f87e2d32019d67611179606;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PUMPBTC] = 0xf9C4FF105803A77eCB5DAE300871Ad76c2794fa4;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.UNIBTC] = 0x6B2a01A5f79dEb4c2f3c0eDa7b01DF456FbD726a;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.SUSDX] = 0x7788A3538C5fc7F9c7C8A74EAC4c898fC8d87d92;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.USDX] = 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.XAUM] = 0x23AE4fd8E7844cdBc97775496eBd0E8248656028;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.LBTC] = 0xecAc9C5F704e954931349Da37F60E39f515c11c1;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.WBTC] = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.LISTA] = 0xFceB31A79F71AC9CBDCF853519c1b12D379EdC46;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.SLISBNB] = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.LISUSD] = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.STBTC] = 0xf6718b2701D4a6498eF77D7c152b2137Ab28b8A3;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BUSD] = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.TUSD] = 0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PUSDT] = 0xEeaA03ed0aa69fCb6e340d47FFa91A0B3426e1CD;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PUSDC] = 0x45b817B36cadBA2c3B6c2427db5b22e2e65400dD;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PWBNB] = 0xCee8c9cCd07ac0981ef42F80Fb63df3CC36F196e;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PBTCB] = 0x2DD73dCc565761b684c56908fa01Ac270A03F70F;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PETH] = 0xF0DaF89F387D9D4Ac5E3326EADb20E7bEC0Ffc7C;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.EZETH] = 0x2416092f143378750bb29b79eD961ab195CcEea5;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.STONE] = 0x80137510979822322193FC997d400D5A6C747bf7;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.XPUFETH] = 0x64274835D88F5c0215da8AADd9A5f2D2A2569381;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.USD1] = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.DAI] = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.TUSD] = 0x14016E85a25aeb13065688cAFB43044C2ef86784;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.SXP] = 0x47BEAd2563dCBf3bF2c9407fEa4dC236fAbA485A;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.XVS] = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BNB] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.LTC] = 0x4338665CBB7B2485A8855A139b75D5e34AB0DB94;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.XRP] = 0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BCH] = 0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.DOT] = 0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.LINK] = 0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.FIL] = 0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BETH] = 0x250632378E573c6Be1AC2f97Fcdf00515d0Aa91B;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.CAN] = 0x20bff4bbEDa07536FF00e073bd8359E5D80D733d;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.ADA] = 0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.DOGE] = 0xbA2aE424d960c26247Dd6c32edC70B295c744C43;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.MATIC] = 0xCC42724C6683B7E57334c4E856f4c9965ED682bD;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.AAVE] = 0xfb6115445Bff7b52FeB98650C87f44907E58f802;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.TRX] = 0x85EAC5Ac2F758618dFa09bDbe0cf174e7d574D5B;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.UST] = 0x3d4350cD54aeF9f9b2C29435e0fa809957B3F30a;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.LUNA] = 0x156ab3346823B651294766e23e6Cf87254d68962;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.TRX] = 0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.UNI] = 0xBf5140A22578168FD562DCcF235E5D43A02ce9B1;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.TWT] = 0x4B0F1812e5Df2A09796481Ff14017e6005508003;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.THE] = 0xF4C8E32EaDEC4BFe97E0F595AdD0f4450a863a11;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.SOL] = 0x570A5D26f7765Ecb712C0924E4De545B89fD43dF;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PT_SUSDE_26JUN2025] = 0xDD809435ba6c9d6903730f923038801781cA66ce;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.SUSDE] = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.USDE] = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.ASBNB] = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PT_USDE_30OCT2025] = 0x607C834cfb7FCBbb341Cbe23f77A6E83bCf3F55c;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.U] = 0xcE24439F2D9C6a2289F741120FE202248B666666;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PT_CLISBNB_25JUN2026] = 0xe052823b4aefc6e230FAf46231A57d0905E30AE0;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.ANKRBNB] = 0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BNBX] = 0x1bdd3Cf7F79cfB8EdbB955f20ad99211551BA275;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.STKBNB] = 0xc2E9d07F66A89c44062459A47a0D2Dc038E4fb16;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PT_CLISBNB_24APR2025] = 0xE8F1C9804770e11Ab73395bE54686Ad656601E9e;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.RACA] = 0x12BB890508c125661E03b09EC06E404bc9289040;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.FLOKI] = 0xfb5B838b6cfEEdC2873aB27866079AC55363D37E;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.USDD] = 0xd17479997F34dd9156Deef8F95A52D81D265be9c;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BABYDOGE] = 0xc748673057861a797275CD8A068AbB95A902e8de;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.EURA] = 0x12f31B73D812C6Bb0d735a218c086d44D5fe5f89;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BTT] = 0x352Cb5E19b12FC216548a2677bD0fce83BaE434B;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.WIN] = 0xaeF0d72a118ce24feE3cD1d43d383897D05B4e99;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BSW] = 0x965F527D9159dCe6288a2219DB51fc6Eef120dD1;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.ALPACA] = 0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.ANKR] = 0xf307910A4c7bbc79691fD374889b36d8531B08e3;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.PLANET] = 0xCa6d678e74f553f0E59cccC03ae644a3c2c5EE7d;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.SATUSD] = 0xb4818BB69478730EF4e33Cc068dD94278e2766cB;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.UST] = 0x23396cF899Ca06c4472205fC903bDB4de249D6fC;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.GAMMA] = 0xb3Cb6d2f8f2FDe203a022201C81a96c167607F15;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.AQUA] = 0x72B7D61E8fC8cF971960DD9cfA59B8C829D91991;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.FRAX] = 0x90C97F71E18723b0Cf0dfa30ee176Ab653E89F40;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.ATOM] = 0x0Eb3a705fc54725037CC9e008bDede697f62F335;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.AVAX] = 0x1CE0c2827e2eF14D5C4f29a091d735A204794041;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.FTM] = 0xAD29AbB318791D579433D831ed122aFeAf29dcfe;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.NULS] = 0x8CD6e29d3686d24d3C2018CEe54621eA0f89313B;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.MASK] = 0x2eD9a5C8C13b93955103B9a7C167B67Ef4d568a3;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.CREAM] = 0xd4CB328A82bDf5f03eB737f37Fa6B370aef3e888;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BAND] = 0xAD6cAEb32CD2c308980a548bD0Bc5AA4306c6c18;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.EOS] = 0x56b6fB708fC5732DEC1Afc8D8556423A2EDcCbD6;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.XTZ] = 0x16939ef78684453bfDFb47825F8a5F714f12623a;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.YFI] = 0x88f1A5ae2A3BF98AEAF342D26B30a79438c9142e;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.ALPHA] = 0xa1faa113cbE53436Df28FF0aEe54275c13B40975;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.BAT] = 0x101d82428437127bF1608F699CD651e6Abf9766E;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.VAI] = 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.AUTO] = 0xa184088a740c695E156F91f5cC086a06bb78b827;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.RENBTC] = 0xfCe146bF3146100cfe5dB4129cf6C82b0eF4Ad8c;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.IOTX] = 0x9678E42ceBEb63F23197D726B29b1CB20d0064E5;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.SUSHI] = 0x947950BcC74888a40Ffa2593C5798F11Fc9124C4;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.ASTER] = 0x000Ae314E2A2172a039B26378814C252734f556A;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.DF] = 0x4A9A2b2b04549C3927dd2c9668A5eF3fCA473623;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.USX] = 0xB5102CeE1528Ce2C760893034A4603663495fD72;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.EUX] = 0x367c17D19fCd0f7746764455497D63c8e8b2BbA3;
        tokens[Chains.BNB_SMART_CHAIN_MAINNET][Tokens.SUSX] = 0xbC404429558292eE2D769E57d57D6E74bbd2792d;
        tokens[Chains.GNOSIS][Tokens.WETH] = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
        tokens[Chains.GNOSIS][Tokens.WSTETH] = 0x6C76971f98945AE98dD7d4DFcA8711ebea946eA6;
        tokens[Chains.GNOSIS][Tokens.GNO] = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
        tokens[Chains.GNOSIS][Tokens.USDC] = 0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83;
        tokens[Chains.GNOSIS][Tokens.WXDAI] = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
        tokens[Chains.GNOSIS][Tokens.EURE] = 0xcB444e90D8198415266c6a2724b7900fb12FC56E;
        tokens[Chains.GNOSIS][Tokens.SDAI] = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;
        tokens[Chains.GNOSIS][Tokens.USDC_E] = 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0;
        tokens[Chains.GNOSIS][Tokens.GHO] = 0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73;
        tokens[Chains.GNOSIS][Tokens.USDT] = 0x4ECaBa5870353805a9F068101A40E0f32ed605C6;
        tokens[Chains.GNOSIS][Tokens.RTW_USD_01] = 0xd3DFf217818b4F33eB38a243158FBeD2BBB029D3;
        tokens[Chains.GNOSIS][Tokens.LINK] = 0xE2e73A1c69ecF83F464EFCE6A5be353a37cA09b2;
        tokens[Chains.GNOSIS][Tokens.WBTC] = 0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252;
        tokens[Chains.GNOSIS][Tokens.FOX] = 0x21a42669643f45Bc0e086b8Fc2ed70c23D67509d;
        tokens[Chains.FUSE_MAINNET][Tokens.WETH] = 0x5622F6dC93e08a8b717B149677930C38d5d50682;
        tokens[Chains.FUSE_MAINNET][Tokens.USDT] = 0x68c9736781E9316ebf5c3d49FE0C1f45D2D104Cd;
        tokens[Chains.FUSE_MAINNET][Tokens.USDC] = 0x28C3d1cD466Ba22f6cae51b1a4692a831696391A;
        tokens[Chains.FUSE_MAINNET][Tokens.WFUSE] = 0x0BE9e53fd7EDaC9F859882AfdDa116645287C629;
        tokens[Chains.FUSE_MAINNET][Tokens.WSTETH] = 0x2931B47c2cEE4fEBAd348ba3d322cb4A17662C34;
        tokens[Chains.FUSE_MAINNET][Tokens.USDT] = 0x3695Dd1D1D43B794C0B13eb8be8419Eb3ac22bf7;
        tokens[Chains.FUSE_MAINNET][Tokens.USDC_E] = 0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9;
        tokens[Chains.FUSE_MAINNET][Tokens.WETH] = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
        tokens[Chains.UNICHAIN][Tokens.USDC] = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
        tokens[Chains.UNICHAIN][Tokens.UNI] = 0x8f187aA05619a017077f5308904739877ce9eA21;
        tokens[Chains.UNICHAIN][Tokens.WETH] = 0x4200000000000000000000000000000000000006;
        tokens[Chains.UNICHAIN][Tokens.WSTETH] = 0xc02fE7317D4eb8753a02c35fe019786854A92001;
        tokens[Chains.UNICHAIN][Tokens.WEETH] = 0x7DCC39B4d1C53CB31e1aBc0e358b43987FEF80f7;
        tokens[Chains.UNICHAIN][Tokens.EZETH] = 0x2416092f143378750bb29b79eD961ab195CcEea5;
        tokens[Chains.UNICHAIN][Tokens.WBTC] = 0x927B51f251480a681271180DA4de28D44EC4AfB8;
        tokens[Chains.UNICHAIN][Tokens.RSETH] = 0xc3eACf0612346366Db554C991D7858716db09f58;
        tokens[Chains.UNICHAIN][Tokens.WBTC] = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
        tokens[Chains.UNICHAIN][Tokens.USDT0] = 0x9151434b16b9763660705744891fA906F660EcC5;
        tokens[Chains.POLYGON_MAINNET][Tokens.DAI] = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
        tokens[Chains.POLYGON_MAINNET][Tokens.LINK] = 0x53E0bca35eC356BD5ddDFebbD1Fc0fD03FaBad39;
        tokens[Chains.POLYGON_MAINNET][Tokens.USDC_E] = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
        tokens[Chains.POLYGON_MAINNET][Tokens.WBTC] = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;
        tokens[Chains.POLYGON_MAINNET][Tokens.WETH] = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
        tokens[Chains.POLYGON_MAINNET][Tokens.USDT] = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
        tokens[Chains.POLYGON_MAINNET][Tokens.AAVE] = 0xD6DF932A45C0f255f85145f286eA0b292B21C90B;
        tokens[Chains.POLYGON_MAINNET][Tokens.WPOL] = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
        tokens[Chains.POLYGON_MAINNET][Tokens.CRV] = 0x172370d5Cd63279eFa6d502DAB29171933a610AF;
        tokens[Chains.POLYGON_MAINNET][Tokens.SUSHI] = 0x0b3F868E0BE5597D5DB7fEB59E1CADBb0fdDa50a;
        tokens[Chains.POLYGON_MAINNET][Tokens.GHST] = 0x385Eeac5cB85A38A9a07A70c73e0a3271CfB54A7;
        tokens[Chains.POLYGON_MAINNET][Tokens.BAL] = 0x9a71012B13CA4d3D0Cdc72A177DF3ef03b0E76A3;
        tokens[Chains.POLYGON_MAINNET][Tokens.DPI] = 0x85955046DF4668e1DD369D2DE9f3AEB98DD2A369;
        tokens[Chains.POLYGON_MAINNET][Tokens.EURS] = 0xE111178A87A3BFf0c8d18DECBa5798827539Ae99;
        tokens[Chains.POLYGON_MAINNET][Tokens.JEUR] = 0x4e3Decbb3645551B8A19f0eA1678079FCB33fB4c;
        tokens[Chains.POLYGON_MAINNET][Tokens.EURA] = 0xE0B52e49357Fd4DAf2c15e02058DCE6BC0057db4;
        tokens[Chains.POLYGON_MAINNET][Tokens.MIMATIC] = 0xa3Fa99A148fA48D14Ed51d610c367C61876997F1;
        tokens[Chains.POLYGON_MAINNET][Tokens.STMATIC] = 0x3A58a54C066FdC0f2D55FC9C89F0415C92eBf3C4;
        tokens[Chains.POLYGON_MAINNET][Tokens.MATICX] = 0xfa68FB4628DFF1028CFEc22b4162FCcd0d45efb6;
        tokens[Chains.POLYGON_MAINNET][Tokens.WSTETH] = 0x03b54A6e9a984069379fae1a4fC4dBAE93B3bCCD;
        tokens[Chains.POLYGON_MAINNET][Tokens.USDC] = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
        tokens[Chains.POLYGON_MAINNET][Tokens.STEERQV536] = 0x7b99506C8E89D5ba835e00E2bC48e118264d44ff;
        tokens[Chains.POLYGON_MAINNET][Tokens.AUSDC_WETH] = 0x3974FbDC22741A1632E024192111107b202F214f;
        tokens[Chains.POLYGON_MAINNET][Tokens.QUICK] = 0x831753DD7087CaC61aB5644b308642cc1c33Dc13;
        tokens[Chains.POLYGON_MAINNET][Tokens.FXS] = 0x3e121107F6F22DA4911079845a470757aF4e1A1b;
        tokens[Chains.POLYGON_MAINNET][Tokens.SNX] = 0x50B728D8D964fd00C2d0AAD81718b71311feF68a;
        tokens[Chains.POLYGON_MAINNET][Tokens.UNI] = 0xb33EaAd8d922B1083446DC23f610c2567fB5180f;
        tokens[Chains.POLYGON_MAINNET][Tokens.IBBTC] = 0x4EaC4c4e9050464067D673102F8E24b2FccEB350;
        tokens[Chains.POLYGON_MAINNET][Tokens.USX] = 0xCf66EB3D546F0415b368d98A95EAF56DeD7aA752;
        tokens[Chains.POLYGON_MAINNET][Tokens.DF] = 0x08C15FA26E519A78a666D19CE5C646D55047e0a3;
        tokens[Chains.POLYGON_MAINNET][Tokens.POL] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.MONAD_MAINNET][Tokens.USDC] = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
        tokens[Chains.MONAD_MAINNET][Tokens.WMON] = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
        tokens[Chains.MONAD_MAINNET][Tokens.USDT] = 0xe7cd86e13AC4309349F30B3435a9d337750fC82D;
        tokens[Chains.MONAD_MAINNET][Tokens.WBTC] = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
        tokens[Chains.MONAD_MAINNET][Tokens.WETH] = 0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242;
        tokens[Chains.MONAD_MAINNET][Tokens.SMON] = 0xA3227C5969757783154C60bF0bC1944180ed81B9;
        tokens[Chains.MONAD_MAINNET][Tokens.SHMON] = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c;
        tokens[Chains.MONAD_MAINNET][Tokens.AUSD] = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
        tokens[Chains.MONAD_MAINNET][Tokens.GMON] = 0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081;
        tokens[Chains.MONAD_MAINNET][Tokens.EARNAUSD] = 0x103222f020e98Bba0AD9809A011FDF8e6F067496;
        tokens[Chains.MONAD_MAINNET][Tokens.LOAZND] = 0x9c82eB49B51F7Dc61e22Ff347931CA32aDc6cd90;
        tokens[Chains.SONIC_MAINNET][Tokens.WETH] = 0x50c42dEAcD8Fc9773493ED674b675bE577f2634b;
        tokens[Chains.SONIC_MAINNET][Tokens.USDC_E] = 0x29219dd400f2Bf60E5a23d13Be72B486D4038894;
        tokens[Chains.SONIC_MAINNET][Tokens.WS] = 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38;
        tokens[Chains.SONIC_MAINNET][Tokens.STS] = 0xE5DA20F15420aD15DE0fa650600aFc998bbE3955;
        tokens[Chains.SONIC_MAINNET][Tokens.SOLVBTC] = 0x541FD749419CA806a8bc7da8ac23D346f2dF8B77;
        tokens[Chains.SONIC_MAINNET][Tokens.XSOLVBTC] = 0xCC0966D8418d412c599A6421b760a847eB169A8c;
        tokens[Chains.SONIC_MAINNET][Tokens.SUSDA] = 0x2840F9d9f96321435Ab0f977E7FDBf32EA8b304f;
        tokens[Chains.SONIC_MAINNET][Tokens.USDA] = 0xff12470a969Dd362EB6595FFB44C82c959Fe9ACc;
        tokens[Chains.SONIC_MAINNET][Tokens.USDT] = 0x6047828dc181963ba44974801FF68e538dA5eaF9;
        tokens[Chains.SONIC_MAINNET][Tokens.CUSD] = 0x0525Cb0064EfFf807fD0cd231544b9208fC215a9;
        tokens[Chains.SONIC_MAINNET][Tokens.CUSD] = 0x5Ba1D96907b075C490F641bD30551e1af9C40721;
        tokens[Chains.SONIC_MAINNET][Tokens.SCUSD] = 0xd3DCe716f3eF535C5Ff8d041c1A41C3bd89b97aE;
        tokens[Chains.SONIC_MAINNET][Tokens.SCETH] = 0x3bcE5CB273F0F148010BbEa2470e7b5df84C7812;
        tokens[Chains.SONIC_MAINNET][Tokens.PT_WSTKSCUSD_29MAY2025] = 0xBe27993204Ec64238F71A527B4c4D5F4949034C3;
        tokens[Chains.SONIC_MAINNET][Tokens.YT_SCUSD] = 0xd2901D474b351bC6eE7b119f9c920863B0F781b2;
        tokens[Chains.SONIC_MAINNET][Tokens.XUSD] = 0x6202B9f02E30E5e1c62Cc01E4305450E5d83b926;
        tokens[Chains.SONIC_MAINNET][Tokens.EURC_E] = 0xe715cbA7B5cCb33790ceBFF1436809d36cb17E57;
        tokens[Chains.SONIC_MAINNET][Tokens.WMETAUSD] = 0xAaAaaAAac311D0572Bffb4772fe985A750E88805;
        tokens[Chains.SONIC_MAINNET][Tokens.ENCLABSVEUSD] = 0x57203A8AeC5C03Dd48050CD599DeB24Ba669aD95;
        tokens[Chains.SONIC_MAINNET][Tokens.ENCLABSVEUSD] = 0xd02962DC00A058a00Fc07A8AA9F760ab6D9Bd163;
        tokens[Chains.SONIC_MAINNET][Tokens.ENCLABSVEETH] = 0xB9EA44D1aa76D5Cfd475C2800E186d3Dea2141a4;
        tokens[Chains.SONIC_MAINNET][Tokens.HLP0] = 0x3D75F2BB8aBcDBd1e27443cB5CBCE8A668046C81;
        tokens[Chains.SONIC_MAINNET][Tokens.U$D] = 0xC326D1505ce0492276f646B03FE460c43A892185;
        tokens[Chains.SONIC_MAINNET][Tokens.WOS] = 0x9F0dF7799f6FDAd409300080cfF680f5A23df4b1;
        tokens[Chains.SONIC_MAINNET][Tokens.PT_SW_WSTKSCUSD_1751241607] = 0x7002383d2305B8f3b2b7786F50C13D132A22076d;
        tokens[Chains.SONIC_MAINNET][Tokens.PT_SW_WSTKSCETH_1751241605] = 0x3A7Ba84bBe869eD318e654DD9B6fF3cF6d531E91;
        tokens[Chains.SONIC_MAINNET][Tokens.SNAKE] = 0x3a516e01f82c1e18916ED69a81Dd498eF64bB157;
        tokens[Chains.SONIC_MAINNET][Tokens.GOGLZ] = 0x9fDbC3f8Abc05Fa8f3Ad3C17D2F806c1230c4564;
        tokens[Chains.SONIC_MAINNET][Tokens.SWPX] = 0xA04BC7140c26fc9BB1F36B1A604C7A5a88fb0E70;
        tokens[Chains.MANTA_PACIFIC_MAINNET][Tokens.TIA] = 0x6Fae4D9935E2fcb11fC79a64e917fb2BF14DaFaa;
        tokens[Chains.MANTA_PACIFIC_MAINNET][Tokens.STONE] = 0xEc901DA9c68E90798BbBb74c11406A32A70652C3;
        tokens[Chains.MANTA_PACIFIC_MAINNET][Tokens.USDC] = 0xb73603C5d87fA094B7314C74ACE2e64D165016fb;
        tokens[Chains.MANTA_PACIFIC_MAINNET][Tokens.USDT] = 0xf417F5A458eC102B90352F697D6e2Ac3A3d2851f;
        tokens[Chains.MANTA_PACIFIC_MAINNET][Tokens.WBTC] = 0x305E88d809c9DC03179554BFbf85Ac05Ce8F18d6;
        tokens[Chains.MANTA_PACIFIC_MAINNET][Tokens.WETH] = 0x0Dc808adcE2099A9F62AA87D9670745AbA741746;
        tokens[Chains.MANTA_PACIFIC_MAINNET][Tokens.WSTETH] = 0x2FE3AD97a60EB7c79A976FC18Bb5fFD07Dd94BA5;
        tokens[Chains.MANTA_PACIFIC_MAINNET][Tokens.WUSDM] = 0xbdAd407F77f44F7Da6684B416b1951ECa461FB07;
        tokens[Chains.MANTA_PACIFIC_MAINNET][Tokens.MANTA] = 0x95CeF13441Be50d20cA4558CC0a27B601aC544E5;
        tokens[Chains.X_LAYER_MAINNET][Tokens.DAI] = 0xC5015b9d9161Dca7e18e32f6f25C4aD850731Fd4;
        tokens[Chains.X_LAYER_MAINNET][Tokens.USDC] = 0x74b7F16337b8972027F6196A17a631aC6dE26d22;
        tokens[Chains.X_LAYER_MAINNET][Tokens.USDT] = 0x1E4a5963aBFD975d8c9021ce480b42188849D41d;
        tokens[Chains.X_LAYER_MAINNET][Tokens.WBTC] = 0xEA034fb02eB1808C2cc3adbC15f447B93CbE08e1;
        tokens[Chains.X_LAYER_MAINNET][Tokens.WETH] = 0x5A77f1443D16ee5761d310e38b62f77f726bC71c;
        tokens[Chains.X_LAYER_MAINNET][Tokens.WOKB] = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
        tokens[Chains.X_LAYER_MAINNET][Tokens.ZAI] = 0xd077ABE1663166c0920d41Fd37ea2D9A00faBd40;
        tokens[Chains.X_LAYER_MAINNET][Tokens.INETH] = 0x5A7a183B6B44Dc4EC2E3d2eF43F98C5152b1d76d;
        tokens[Chains.X_LAYER_MAINNET][Tokens.STONE] = 0x80137510979822322193FC997d400D5A6C747bf7;
        tokens[Chains.X_LAYER_MAINNET][Tokens.WRSETH] = 0x5A71f5888EE05B36Ded9149e6D32eE93812EE5e9;
        tokens[Chains.OPBNB_MAINNET][Tokens.WBNB] = 0x4200000000000000000000000000000000000006;
        tokens[Chains.OPBNB_MAINNET][Tokens.USDT] = 0x9e5AAC1Ba1a2e6aEd6b32689DFcF62A509Ca96f3;
        tokens[Chains.OPBNB_MAINNET][Tokens.BTCB] = 0x7c6b91D9Be155A6Db01f749217d76fF02A7227F2;
        tokens[Chains.OPBNB_MAINNET][Tokens.ETH] = 0xE7798f023fC62146e8Aa1b36Da45fb70855a77Ea;
        tokens[Chains.OPBNB_MAINNET][Tokens.FDUSD] = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
        tokens[Chains.OPBNB_MAINNET][Tokens.BNB] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.B2_MAINNET][Tokens.UBTC] = 0x796e4D53067FF374B89b2Ac101ce0c1f72ccaAc2;
        tokens[Chains.B2_MAINNET][Tokens.STBTC] = 0xf6718b2701D4a6498eF77D7c152b2137Ab28b8A3;
        tokens[Chains.FANTOM_OPERA][Tokens.LZDAI] = 0x91a40C733c97a6e1BF876EaF9ed8c08102eB491f;
        tokens[Chains.FANTOM_OPERA][Tokens.LZUSDC] = 0x28a92dde19D9989F39A49905d7C9C2FAc7799bDf;
        tokens[Chains.FANTOM_OPERA][Tokens.USDT_E] = 0xcc1b99dDAc1a33c201a742A1851662E87BC7f22C;
        tokens[Chains.FANTOM_OPERA][Tokens.WBTC] = 0xf1648C50d2863f780c57849D812b4B7686031A3D;
        tokens[Chains.FANTOM_OPERA][Tokens.WETH] = 0x695921034f0387eAc4e11620EE91b1b15A6A09fE;
        tokens[Chains.FANTOM_OPERA][Tokens.WFTM] = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.USDC] = 0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.USDT] = 0x493257fD37EDB34451f62EDf8D2a0C418852bA4C;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.WETH] = 0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.WSTETH] = 0x703b52F2b28fEbcB60E1372858AF5b18849FE867;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.ZK] = 0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.WEETH] = 0xc1Fa6E2E8667d9bE0Ca938a54c7E0285E9Df924a;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.SUSDE] = 0xAD17Da2f6Ac76746EF261E835C50b2651ce36DA8;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.WRSETH] = 0xd4169E045bcF9a86cC00101225d9ED61D2F51af2;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.USDC_E] = 0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.ONEZ] = 0x90059C32Eeeb1A2aa1351a58860d98855f3655aD;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.LUSD] = 0x503234F203fC7Eb888EEC8513210612a43Cf6115;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.WBTC] = 0xBBeB516fb02a01611cBBE0453Fe3c580D7281011;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.PEPE] = 0xFD282F16a64c6D304aC05d1A58Da15bed0467c71;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.BUSD] = 0x2039bb4116B4EFc145Ec4f0e2eA75012D6C0f181;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.KS_LP_USDC_E_USDT] = 0x4d321cd88c5680Ce4f85bb58c578dFE9C2Cc1eF6;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.SWORD] = 0x240f765Af2273B0CAb6cAff2880D6d8F8B285fa4;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.VC] = 0x99bBE51be7cCe6C8b84883148fD3D12aCe5787F2;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.MUTE] = 0x0e97C7a0F8B2C9885C8ac9fC6136e829CbC21d42;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.DAI] = 0x4B9eb6c0b6ea15176BBF62841C6B2A8a398cb656;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.CAKE] = 0x3A287a06c66f9E95a56327185cA2BDF5f031cEcD;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.M_BTC] = 0xE757355edba7ced7B8c0271BBA4eFDa184aD75Ab;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.WUSDM] = 0xA900cbE7739c96D2B153a273953620A701d5442b;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.USN] = 0x0469d9d1dE0ee58fA1153ef00836B9BbCb84c0B6;
        tokens[Chains.ZKSYNC_MAINNET][Tokens.ZKETH] = 0xb72207E1FB50f341415999732A20B6D25d8127aa;
        tokens[Chains.PULSECHAIN][Tokens.WPLS] = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
        tokens[Chains.PULSECHAIN][Tokens.HEX] = 0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39;
        tokens[Chains.PULSECHAIN][Tokens.PLSX] = 0x95B303987A60C71504D99Aa1b13B4DA07b0790ab;
        tokens[Chains.PULSECHAIN][Tokens.USDC] = 0x15D38573d2feeb82e7ad5187aB8c1D52810B1f07;
        tokens[Chains.PULSECHAIN][Tokens.WETH] = 0x02DcdD04e3F455D838cd1249292C58f3B79e3C3C;
        tokens[Chains.PULSECHAIN][Tokens.WBTC] = 0xb17D901469B9208B17d916112988A3FeD19b5cA1;
        tokens[Chains.PULSECHAIN][Tokens.DAI] = 0xefD766cCb38EaF1dfd701853BFCe31359239F305;
        tokens[Chains.PULSECHAIN][Tokens.USDT] = 0x0Cb6F5a34ad42ec934882A05265A7d5F59b51A2f;
        tokens[Chains.PULSECHAIN][Tokens.INC] = 0x2fa878Ab3F87CC1C9737Fc071108F904c0B0C95d;
        tokens[Chains.PULSECHAIN][Tokens.USDL] = 0x0dEEd1486bc52aA0d3E6f8849cEC5adD6598A162;
        tokens[Chains.PULSECHAIN][Tokens.HEXDC] = 0x1FE0319440A672526916C232EAEe4808254Bdb00;
        tokens[Chains.PULSECHAIN][Tokens.PXDC] = 0xeB6b7932Da20c6D7B3a899D5887d86dfB09A6408;
        tokens[Chains.WORLD_CHAIN][Tokens.ETH] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.WORLD_CHAIN][Tokens.USDC_E] = 0x79A02482A880bCE3F13e09Da970dC34db4CD24d1;
        tokens[Chains.WORLD_CHAIN][Tokens.WBTC] = 0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3;
        tokens[Chains.WORLD_CHAIN][Tokens.WLD] = 0x2cFc85d8E48F8EAB294be644d9E25C3030863003;
        tokens[Chains.HYPEREVM][Tokens.WHYPE] = 0x5555555555555555555555555555555555555555;
        tokens[Chains.HYPEREVM][Tokens.WSTHYPE] = 0x94e8396e0869c9F2200760aF0621aFd240E1CF38;
        tokens[Chains.HYPEREVM][Tokens.UBTC] = 0x9FDBdA0A5e284c32744D2f17Ee5c74B284993463;
        tokens[Chains.HYPEREVM][Tokens.UETH] = 0xBe6727B535545C67d5cAa73dEa54865B92CF7907;
        tokens[Chains.HYPEREVM][Tokens.USDE] = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
        tokens[Chains.HYPEREVM][Tokens.USDT0] = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
        tokens[Chains.HYPEREVM][Tokens.SUSDE] = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;
        tokens[Chains.HYPEREVM][Tokens.USDHL] = 0xb50A96253aBDF803D85efcDce07Ad8becBc52BD5;
        tokens[Chains.HYPEREVM][Tokens.KHYPE] = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
        tokens[Chains.HYPEREVM][Tokens.USR] = 0x0aD339d66BF4AeD5ce31c64Bc37B3244b6394A77;
        tokens[Chains.HYPEREVM][Tokens.PT_KHYPE_13NOV2025] = 0x311dB0FDe558689550c68355783c95eFDfe25329;
        tokens[Chains.HYPEREVM][Tokens.PT_SUSDE_25SEP2025] = 0xb7379d395F3c83952ad794896205f7E33E358735;
        tokens[Chains.HYPEREVM][Tokens.USOL] = 0x068f321Fa8Fb9f0D135f290Ef6a3e2813e1c8A29;
        tokens[Chains.HYPEREVM][Tokens.BEHYPE] = 0xd8FC8F0b03eBA61F64D08B0bef69d80916E5DdA9;
        tokens[Chains.HYPEREVM][Tokens.USDC] = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
        tokens[Chains.HYPEREVM][Tokens.USDH] = 0x111111a1a0667d36bD57c0A9f569b98057111111;
        tokens[Chains.HYPEREVM][Tokens.PT_KHYPE_19MAR2026] = 0xea84ca9849D9e76a78B91F221F84e9Ca065FC9f5;
        tokens[Chains.HYPEREVM][Tokens.USDXL] = 0xca79db4B49f608eF54a5CB813FbEd3a6387bC645;
        tokens[Chains.HYPEREVM][Tokens.FEUSD] = 0x02c6a2fA58cC01A18B8D9E00eA48d65E4dF26c70;
        tokens[Chains.HYPEREVM][Tokens.XAUT0] = 0xf4D9235269a96aaDaFc9aDAe454a0618eBE37949;
        tokens[Chains.HYPEREVM][Tokens.THBILL] = 0xfDD22Ce6D1F66bc0Ec89b20BF16CcB6670F55A5a;
        tokens[Chains.HYPEREVM][Tokens.PURR] = 0x9b498C3c8A0b8CD8BA1D9851d40D186F1872b44E;
        tokens[Chains.HYPEREVM][Tokens.PRFI] = 0x7BBCf1B600565AE023a1806ef637Af4739dE3255;
        tokens[Chains.CONFLUX_ESPACE][Tokens.WBTC] = 0x1F545487c62e5ACfEa45dcAdd9c627361d1616D8;
        tokens[Chains.CONFLUX_ESPACE][Tokens.WETH] = 0xa47f43DE2f9623aCb395CA4905746496D2014d57;
        tokens[Chains.CONFLUX_ESPACE][Tokens.USDT] = 0xfe97E85d13ABD9c1c33384E796F10B73905637cE;
        tokens[Chains.CONFLUX_ESPACE][Tokens.USDC] = 0x6963EfED0aB40F6C3d7BdA44A05dcf1437C44372;
        tokens[Chains.CONFLUX_ESPACE][Tokens.CFX] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.METIS_ANDROMEDA_MAINNET][Tokens.DAI] = 0x4c078361FC9BbB78DF910800A991C7c3DD2F6ce0;
        tokens[Chains.METIS_ANDROMEDA_MAINNET][Tokens.METIS] = 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000;
        tokens[Chains.METIS_ANDROMEDA_MAINNET][Tokens.M_USDC] = 0xEA32A96608495e54156Ae48931A7c20f0dcc1a21;
        tokens[Chains.METIS_ANDROMEDA_MAINNET][Tokens.M_USDT] = 0xbB06DCA3AE6887fAbF931640f67cab3e3a16F4dC;
        tokens[Chains.METIS_ANDROMEDA_MAINNET][Tokens.WETH] = 0x420000000000000000000000000000000000000A;
        tokens[Chains.METIS_ANDROMEDA_MAINNET][Tokens.WBTC] = 0xa5B55ab1dAF0F8e1EFc0eB1931a957fd89B918f4;
        tokens[Chains.METIS_ANDROMEDA_MAINNET][Tokens.M_WBTC] = 0x433E43047B95cB83517abd7c9978Bdf7005E9938;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.USDT] = 0x900101d06A7426441Ae63e9AB3B9b0F63Be145F1;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.USDC] = 0xa4151B2B3e269645181dCcF2D426cE75fcbDeca9;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.COREBTC] = 0x8034aB88C3512246Bf7894f57C834DdDBd1De01F;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.WCORE] = 0x40375C92d9FAf44d2f9db9Bd9ba41a3317a2404f;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.WBTC] = 0x5832f53d147b3d6Cd4578B9CBD62425C7ea9d0Bd;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.SOLVBTC_B] = 0x5B1Fb849f1F76217246B8AAAC053b5C7b15b7dc3;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.BTCB] = 0x7A6888c85eDBA8E38F6C7E0485212da602761C08;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.ABTC] = 0x70727228DB8C7491bF0aD42C180dbf8D95B257e2;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.SOLVBTC_M] = 0xe04d21d999FaEDf1e72AdE6629e20A11a1ed14FA;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.STCORE] = 0xb3A8F0f0da9ffC65318aA39E55079796093029AD;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.CLND] = 0x30A540B05468A250fCc17Da2D9D4aaa84B358eA7;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.AUSD] = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.WETH] = 0xeAB3aC417c4d6dF6b143346a46fEe1B847B50296;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.WBITS] = 0x6120725CFa1062B0596C48D356E4beC6A44fEece;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.SOLVBTC_CORE] = 0x9410e8052Bc661041e5cB27fDf7d9e9e842af2aa;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.PUMPBTC] = 0x5a2aa871954eBdf89b1547e75d032598356caad5;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.OBTC] = 0x000734cF9E469BAd78c8EC1b0dEeD83D0A03C1F8;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.UBTC] = 0xbB4A26A053B217bb28766a4eD4b062c3B4De58ce;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.CORE] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.BTC_B] = 0x2297aEbD383787A160DD0d9F71508148769342E3;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.SUUSD] = 0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.SUBTC] = 0xe85411C030fB32A9D8b14Bbbc6CB19417391F711;
        tokens[Chains.CORE_BLOCKCHAIN_MAINNET][Tokens.DUALCORE] = 0xc5555eA27e63cd89f8b227deCe2a3916800c0f4F;
        tokens[Chains.MOONBEAM][Tokens.GLMR] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.MOONBEAM][Tokens.DOT] = 0xFfFFfFff1FcaCBd218EDc0EbA20Fc2308C778080;
        tokens[Chains.MOONBEAM][Tokens.WETH] = 0x30D2a9F5FDf90ACe8c17952cbb4eE48a55D916A7;
        tokens[Chains.MOONBEAM][Tokens.WBTC] = 0x1DC78Acda13a8BC4408B207c9E48CDBc096D95e0;
        tokens[Chains.MOONBEAM][Tokens.USDC] = 0x8f552a71EFE5eeFc207Bf75485b356A0b3f01eC9;
        tokens[Chains.MOONBEAM][Tokens.FRAX] = 0x322E86852e492a7Ee17f28a78c663da38FB33bfb;
        tokens[Chains.MOONBEAM][Tokens.WETH] = 0xab3f0245B83feB11d15AAffeFD7AD465a59817eD;
        tokens[Chains.MOONBEAM][Tokens.WH_WBTC] = 0xE57eBd2d67B462E9926e04a8e33f01cD0D64346D;
        tokens[Chains.MOONBEAM][Tokens.WH_USDC] = 0x931715FEE2d06333043d11F658C8CE934aC61D0c;
        tokens[Chains.MOONBEAM][Tokens.BUSD] = 0x692C57641fc054c2Ad6551Ccc6566EbA599de1BA;
        tokens[Chains.MOONBEAM][Tokens.XCUSDT] = 0xFFFFFFfFea09FB06d082fd1275CD48b191cbCD1d;
        tokens[Chains.MOONBEAM][Tokens.XCUSDC] = 0xFFfffffF7D2B0B761Af01Ca8e25242976ac0aD7D;
        tokens[Chains.MOONBEAM][Tokens.D2O] = 0xc806B0600cbAfA0B197562a9F7e3B9856866E9bF;
        tokens[Chains.MOONBEAM][Tokens.IBTC] = 0xFFFFFfFf5AC1f9A51A93F5C527385edF7Fe98A52;
        tokens[Chains.SEI_NETWORK][Tokens.SOLVBTC] = 0x541FD749419CA806a8bc7da8ac23D346f2dF8B77;
        tokens[Chains.SEI_NETWORK][Tokens.XSOLVBTC] = 0xCC0966D8418d412c599A6421b760a847eB169A8c;
        tokens[Chains.SEI_NETWORK][Tokens.SUSDA] = 0x6aB5d5E96aC59f66baB57450275cc16961219796;
        tokens[Chains.SEI_NETWORK][Tokens.USDA] = 0xff12470a969Dd362EB6595FFB44C82c959Fe9ACc;
        tokens[Chains.SEI_NETWORK][Tokens.USDC] = 0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1;
        tokens[Chains.SEI_NETWORK][Tokens.USDT] = 0xB75D0B03c06A926e488e2659DF1A861F860bD3d1;
        tokens[Chains.SEI_NETWORK][Tokens.WSEI] = 0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7;
        tokens[Chains.SEI_NETWORK][Tokens.WETH] = 0x160345fC359604fC6e70E3c5fAcbdE5F7A9342d8;
        tokens[Chains.SEI_NETWORK][Tokens.ISEI] = 0x5Cf6826140C1C56Ff49C808A1A75407Cd1DF9423;
        tokens[Chains.SEI_NETWORK][Tokens.FRXUSD] = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        tokens[Chains.SEI_NETWORK][Tokens.SFRXUSD] = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;
        tokens[Chains.SEI_NETWORK][Tokens.FRXETH] = 0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050;
        tokens[Chains.SEI_NETWORK][Tokens.SFRXETH] = 0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45;
        tokens[Chains.SEI_NETWORK][Tokens.FASTUSD] = 0x37a4dD9CED2b19Cfe8FAC251cd727b5787E45269;
        tokens[Chains.SEI_NETWORK][Tokens.WBTC] = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
        tokens[Chains.SEI_NETWORK][Tokens.SFASTUSD] = 0xdf77686D99667Ae56BC18f539B777DBc2BBE3E9F;
        tokens[Chains.SEI_NETWORK][Tokens.WSTETH] = 0xBE574b6219C6D985d08712e90C21A88fd55f1ae8;
        tokens[Chains.SEI_NETWORK][Tokens.USDT0] = 0x9151434b16b9763660705744891fA906F660EcC5;
        tokens[Chains.SEI_NETWORK][Tokens.USDC] = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
        tokens[Chains.SEI_NETWORK][Tokens.CLO] = 0x81D3A238b02827F62B9f390f947D36d4A5bf89D2;
        tokens[Chains.SEI_NETWORK][Tokens.USDY] = 0x54cD901491AeF397084453F4372B93c33260e2A6;
        tokens[Chains.SEI_NETWORK][Tokens.UBTC] = 0x78E26E8b953C7c78A58d69d8B9A91745C2BbB258;
        tokens[Chains.SEI_NETWORK][Tokens.FBTC] = 0x5fabd1D440a90eE57Dd698ea096B91F994B6DF56;
        tokens[Chains.SEI_NETWORK][Tokens.SBTC] = 0x095957CEB9f317ac1328f0aB3123622401766D71;
        tokens[Chains.SEI_NETWORK][Tokens.M_BTC] = 0x9BFA177621119e64CecbEabE184ab9993E2ef727;
        tokens[Chains.SEI_NETWORK][Tokens.SPSEI] = 0xC257361320F4514D91c05F461006CE6a0300E2d2;
        tokens[Chains.SEI_NETWORK][Tokens.ENZOBTC] = 0x6A9A65B84843F5fD4aC9a0471C4fc11AFfFBce4a;
        tokens[Chains.SEI_NETWORK][Tokens.FIABTC] = 0x60C230c38aF6d86b0277a98a1CAeAA345a7B061F;
        tokens[Chains.SONEIUM][Tokens.WETH] = 0x4200000000000000000000000000000000000006;
        tokens[Chains.SONEIUM][Tokens.USDC] = 0xbA9986D2381edf1DA03B0B9c1f8b00dc4AacC369;
        tokens[Chains.SONEIUM][Tokens.USDT] = 0x3A337a6adA9d885b6Ad95ec48F9b75f197b5AE35;
        tokens[Chains.SONEIUM][Tokens.ASTR] = 0x2CAE934a1e84F693fbb78CA5ED3B0A6893259441;
        tokens[Chains.SONEIUM][Tokens.SONE] = 0xf24e57b1cb00d98C31F04f86328e22E8fcA457fb;
        tokens[Chains.SONEIUM][Tokens.SOLVBTC] = 0x541FD749419CA806a8bc7da8ac23D346f2dF8B77;
        tokens[Chains.SONEIUM][Tokens.XSOLVBTC] = 0xCC0966D8418d412c599A6421b760a847eB169A8c;
        tokens[Chains.SONEIUM][Tokens.PUFETH] = 0x6c460b2c6D6719562D5dA43E5152B375e79B9A8B;
        tokens[Chains.SONEIUM][Tokens.USDT0] = 0x102d758f688a4C1C5a80b116bD945d4455460282;
        tokens[Chains.SONEIUM][Tokens.SOLVBTC_JUP] = 0xAffEb8576b927050f5a3B6fbA43F360D2883A118;
        tokens[Chains.SONEIUM][Tokens.SSUPERUSD] = 0x139450C2dCeF827C9A2a0Bb1CB5506260940c9fd;
        tokens[Chains.SONEIUM][Tokens.WSTUSR] = 0x2a52B289bA68bBd02676640aA9F605700c9e5699;
        tokens[Chains.SONEIUM][Tokens.NSASTR] = 0xc67476893C166c537afd9bc6bc87b3f228b44337;
        tokens[Chains.SONEIUM][Tokens.WSTASTR] = 0x3b0DC2daC9498A024003609031D973B1171dE09E;
        tokens[Chains.RONIN_MAINNET][Tokens.WETH] = 0xc99a6A985eD2Cac1ef41640596C5A5f9F4E19Ef5;
        tokens[Chains.RONIN_MAINNET][Tokens.WRON] = 0xe514d9DEB7966c8BE0ca922de8a064264eA6bcd4;
        tokens[Chains.RONIN_MAINNET][Tokens.USDC] = 0x0B7007c13325C48911F73A2daD5FA5dCBf808aDc;
        tokens[Chains.RONIN_MAINNET][Tokens.AXS] = 0x97a9107C1793BC407d6F527b77e7fff4D812bece;
        tokens[Chains.GOAT_NETWORK][Tokens.USDT] = 0xE1AD845D93853fff44990aE0DcecD8575293681e;
        tokens[Chains.GOAT_NETWORK][Tokens.USDC_E] = 0x3022b87ac063DE95b1570F46f5e470F8B53112D8;
        tokens[Chains.GOAT_NETWORK][Tokens.WGBTC] = 0xbC10000000000000000000000000000000000000;
        tokens[Chains.GOAT_NETWORK][Tokens.BTCB] = 0xfe41e7e5cB3460c483AB2A38eb605Cda9e2d248E;
        tokens[Chains.GOAT_NETWORK][Tokens.DOGEB] = 0x1E0d0303a8c4aD428953f5ACB1477dB42bb838cf;
        tokens[Chains.GOAT_NETWORK][Tokens.WETH] = 0x3a1293Bdb83bBbDd5Ebf4fAc96605aD2021BbC0f;
        tokens[Chains.MORPH][Tokens.USDC] = 0xe34c91815d7fc18A9e2148bcD4241d0a5848b693;
        tokens[Chains.MORPH][Tokens.USDT] = 0xc7D67A9cBB121b3b0b9c053DD9f469523243379A;
        tokens[Chains.MORPH][Tokens.USDE] = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
        tokens[Chains.MORPH][Tokens.WETH] = 0x5300000000000000000000000000000000000011;
        tokens[Chains.MORPH][Tokens.WEETH] = 0x7DCC39B4d1C53CB31e1aBc0e358b43987FEF80f7;
        tokens[Chains.MORPH][Tokens.WBTC] = 0x803DcE4D3f4Ae2e17AF6C51343040dEe320C149D;
        tokens[Chains.MORPH][Tokens.BGB] = 0x55d1f1879969bdbB9960d269974564C58DBc3238;
        tokens[Chains.MORPH][Tokens.MPHBTC] = 0x950e7FB62398C3CcaBaBc0e3e0de3137fb0daCd2;
        tokens[Chains.MERLIN_MAINNET][Tokens.WBTC] = 0xF6D226f9Dc15d9bB51182815b320D3fBE324e1bA;
        tokens[Chains.MERLIN_MAINNET][Tokens.M_BTC] = 0xB880fd278198bd590252621d4CD071b1842E9Bcd;
        tokens[Chains.MERLIN_MAINNET][Tokens.UNIBTC] = 0x93919784C523f39CACaa98Ee0a9d96c3F32b593e;
        tokens[Chains.MERLIN_MAINNET][Tokens.M_USDT] = 0x967aEC3276b63c5E2262da9641DB9dbeBB07dC0d;
        tokens[Chains.MERLIN_MAINNET][Tokens.M_USDC] = 0x6b4eCAdA640F1B30dBdB68f77821A03A5f282EbE;
        tokens[Chains.MERLIN_MAINNET][Tokens.SOLVBTC] = 0x41D9036454BE47d3745A823C4aaCD0e29cFB0f71;
        tokens[Chains.MERLIN_MAINNET][Tokens.M_ORDI] = 0x0726523Eba12EdaD467c55a962842Ef358865559;
        tokens[Chains.MERLIN_MAINNET][Tokens.MERL] = 0x5c46bFF4B38dc1EAE09C5BAc65872a1D8bc87378;
        tokens[Chains.MERLIN_MAINNET][Tokens.STONE] = 0xB5d8b1e73c79483d7750C5b8DF8db45A0d24e2cf;
        tokens[Chains.MERLIN_MAINNET][Tokens.ORDI] = 0x7dcb50b2180BC896Da1200D2726a88AF5D2cBB5A;
        tokens[Chains.MERLIN_MAINNET][Tokens.SOLVBTC_ENA] = 0x88c618B2396C1A11A6Aabd1bf89228a08462f2d2;
        tokens[Chains.MERLIN_MAINNET][Tokens.XSOLVBTC] = 0x1760900aCA15B90Fa2ECa70CE4b4EC441c2CF6c5;
        tokens[Chains.MERLIN_MAINNET][Tokens.VOYA] = 0x480E158395cC5b41e5584347c495584cA2cAf78d;
        tokens[Chains.MERLIN_MAINNET][Tokens.HUHU] = 0x7a677e59dC2C8a42d6aF3a62748c5595034A008b;
        tokens[Chains.MERLIN_MAINNET][Tokens.M_SATS] = 0x4DCb91Cc19AaDFE5a6672781EB09abAd00C19E4c;
        tokens[Chains.MERLIN_MAINNET][Tokens.M_RATS] = 0x69181A1f082ea83A152621e4FA527C936abFa501;
        tokens[Chains.MERLIN_MAINNET][Tokens.MP] = 0xbd40c74cb5cf9f9252B3298230Cb916d80430bBa;
        tokens[Chains.MERLIN_MAINNET][Tokens.ESMP] = 0x7126bd63713A7212792B08FA2c39d39190A4cF5b;
        tokens[Chains.MERLIN_MAINNET][Tokens.MNER] = 0x27622B326Ff3ffa7dc10AE291800c3073b55AA39;
        tokens[Chains.MERLIN_MAINNET][Tokens.BNBS] = 0x33c70a08D0D427eE916576a7594b50d7F8f3FbE1;
        tokens[Chains.MERLIN_MAINNET][Tokens.MSTAR] = 0x09401c470a76Ec07512EEDDEF5477BE74bac2338;
        tokens[Chains.MERLIN_MAINNET][Tokens.SOLVBTCSLP] = 0x4920FB03F3Ea1C189dd216751f8d073dd680A136;
        tokens[Chains.MERLIN_MAINNET][Tokens.WBTCSLP] = 0xb00db5fAAe7682d80cA3CE5019E710ca08Bfbd66;
        tokens[Chains.MERLIN_MAINNET][Tokens.MBTCSLP] = 0xa41a8C64a324cD00CB70C2448697E248EA0b1ff2;
        tokens[Chains.MERLIN_MAINNET][Tokens.DOGGOTOTHEMOON] = 0x32A4b8b10222F85301874837F27F4c416117B811;
        tokens[Chains.IOTEX_NETWORK_MAINNET][Tokens.UNIBTC] = 0x93919784C523f39CACaa98Ee0a9d96c3F32b593e;
        tokens[Chains.IOTEX_NETWORK_MAINNET][Tokens.IOUSDT] = 0x6fbCdc1169B5130C59E72E51Ed68A84841C98cd1;
        tokens[Chains.IOTEX_NETWORK_MAINNET][Tokens.WIOTX] = 0xA00744882684C3e4747faEFD68D283eA44099D03;
        tokens[Chains.IOTEX_NETWORK_MAINNET][Tokens.IOUSDC] = 0x3B2bf2b523f54C4E454F08Aa286D03115aFF326c;
        tokens[Chains.IOTEX_NETWORK_MAINNET][Tokens.USDC_E] = 0xcDf79194C6C285077A58da47641D4dBe51F63542;
        tokens[Chains.IOTEX_NETWORK_MAINNET][Tokens.USDA] = 0x2d9526e2cABD30c6E8f89ea60D230503C59C6603;
        tokens[Chains.IOTEX_NETWORK_MAINNET][Tokens.UNIIOTX] = 0x236f8c0a61dA474dB21B693fB2ea7AAB0c803894;
        tokens[Chains.MANTLE][Tokens.WETH] = 0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111;
        tokens[Chains.MANTLE][Tokens.WMNT] = 0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8;
        tokens[Chains.MANTLE][Tokens.USDT0] = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
        tokens[Chains.MANTLE][Tokens.USDC] = 0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9;
        tokens[Chains.MANTLE][Tokens.USDE] = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
        tokens[Chains.MANTLE][Tokens.SUSDE] = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;
        tokens[Chains.MANTLE][Tokens.FBTC] = 0xC96dE26018A54D51c097160568752c4E3BD6C364;
        tokens[Chains.MANTLE][Tokens.SYRUPUSDT] = 0x051665f2455116e929b9972c36d23070F5054Ce0;
        tokens[Chains.MANTLE][Tokens.WRSETH] = 0x93e855643e940D025bE2e529272e4Dbd15a2Cf74;
        tokens[Chains.MANTLE][Tokens.GHO] = 0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73;
        tokens[Chains.MANTLE][Tokens.USDT] = 0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE;
        tokens[Chains.MANTLE][Tokens.WBTC] = 0xCAbAE6f6Ea1ecaB08Ad02fE02ce9A44F09aebfA2;
        tokens[Chains.MANTLE][Tokens.METH] = 0xcDA86A272531e8640cD7F1a92c01839911B90bb0;
        tokens[Chains.MANTLE][Tokens.CMETH] = 0xE6829d9a7eE3040e1276Fa75293Bde931859e8fA;
        tokens[Chains.MANTLE][Tokens.AUSD] = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
        tokens[Chains.MANTLE][Tokens.PT_CMETH_18SEP2025] = 0x698eB002A4Ec013A33286f7F2ba0bE3970E66455;
        tokens[Chains.MANTLE][Tokens.USDY] = 0x5bE26527e817998A7206475496fDE1E68957c5A6;
        tokens[Chains.ZETACHAIN_MAINNET][Tokens.PUMPBTC] = 0x1fCca65fb6Ae3b2758b9b2B394CB227eAE404e1E;
        tokens[Chains.ZETACHAIN_MAINNET][Tokens.BTC_BTC] = 0x13A0c5930C028511Dc02665E7285134B6d11A5f4;
        tokens[Chains.ZETACHAIN_MAINNET][Tokens.WZETA] = 0x5F0b1a82749cb4E2278EC87F8BF6B618dC71a8bf;
        tokens[Chains.ZETACHAIN_MAINNET][Tokens.USDT_ETH] = 0x7c8dDa80bbBE1254a7aACf3219EBe1481c6E01d7;
        tokens[Chains.ZETACHAIN_MAINNET][Tokens.ETH_ETH] = 0xd97B1de3619ed2c6BEb3860147E30cA8A7dC9891;
        tokens[Chains.ZETACHAIN_MAINNET][Tokens.USDT_BSC] = 0x91d4F0D54090Df2D81e834c3c8CE71C6c865e79F;
        tokens[Chains.ZETACHAIN_MAINNET][Tokens.USDC_BSC] = 0x05BA149A7bd6dC1F937fA9046A9e05C05f3b18b0;
        tokens[Chains.ZETACHAIN_MAINNET][Tokens.USDC_ETH] = 0x0cbe0dF132a6c6B4a2974Fa1b7Fb953CF0Cc798a;
        tokens[Chains.ZETACHAIN_MAINNET][Tokens.BNB_BSC] = 0x48f80608B672DC30DC7e3dbBd0343c5F02C738Eb;
        tokens[Chains.KAIA_MAINNET][Tokens.WKAIA] = 0x19Aac5f612f524B754CA7e7c41cbFa2E981A4432;
        tokens[Chains.KAIA_MAINNET][Tokens.USDT] = 0x5C13E303a62Fc5DEdf5B52D66873f2E59fEdADC2;
        tokens[Chains.KAIA_MAINNET][Tokens.USDC] = 0x608792Deb376CCE1c9FA4D0E6B7b44f507CfFa6A;
        tokens[Chains.KAIA_MAINNET][Tokens.WETH] = 0x98A8345bB9D3DDa9D808Ca1c9142a28F6b0430E1;
        tokens[Chains.KAIA_MAINNET][Tokens.STKAIA] = 0x42952B873ed6f7f0A7E4992E2a9818E3A9001995;
        tokens[Chains.KAIA_MAINNET][Tokens.WGCKAIA] = 0xa9999999c3D05Fb75cE7230e0D22F5625527d583;
        tokens[Chains.KAIA_MAINNET][Tokens.GRND] = 0x84F8C3C8d6eE30a559D73Ec570d574f671E82647;
        tokens[Chains.KAIA_MAINNET][Tokens.XGRND] = 0x9bcb2EFC545f89986CF70d3aDC39079a1B730D63;
        tokens[Chains.KAIA_MAINNET][Tokens.KRWO] = 0x7FC692699f2216647a0E06225d8bdF8cDeE40e7F;
        tokens[Chains.KAIA_MAINNET][Tokens.BORA] = 0x02cbE46fB8A1F579254a9B485788f2D86Cad51aa;
        tokens[Chains.KAIA_MAINNET][Tokens.DAI] = 0x078dB7827a5531359f6CB63f62CFA20183c4F10c;
        tokens[Chains.KAIA_MAINNET][Tokens.USDC] = 0x6270B58BE569a7c0b8f47594F191631Ae5b2C86C;
        tokens[Chains.KAIA_MAINNET][Tokens.USDT] = 0xd6dAb4CfF47dF175349e6e7eE2BF7c40Bb8C05A3;
        tokens[Chains.KAIA_MAINNET][Tokens.WBTC] = 0xDCbacF3f7a069922E677912998c8d57423C37dfA;
        tokens[Chains.KAIA_MAINNET][Tokens.WETH] = 0xCD6f29dC9Ca217d0973d3D21bF58eDd3CA871a86;
        tokens[Chains.KAIA_MAINNET][Tokens.WKLAY] = 0xe4f05A66Ec68B54A58B17c22107b02e0232cC817;
        tokens[Chains.KAIA_MAINNET][Tokens.WBTC] = 0x981846bE8d2d697f4dfeF6689a161A25FfbAb8F9;
        tokens[Chains.KAIA_MAINNET][Tokens.DAI] = 0xCB2C7998696Ef7a582dFD0aAFadCd008D03E791A;
        tokens[Chains.KAIA_MAINNET][Tokens.WBNB] = 0xaC9C1E4787139aF4c751B1C0fadfb513C44Ed833;
        tokens[Chains.KAIA_MAINNET][Tokens.BUSD] = 0xE2765F3721dab5f080Cf14ACe661529e1ab9adE7;
        tokens[Chains.KAIA_MAINNET][Tokens.WAVAX] = 0x45830b92443a8f750247da2A76C85c70d0f1EBF3;
        tokens[Chains.KAIA_MAINNET][Tokens.SOL] = 0xfAA03A2AC2d1B8481Ec3fF44A0152eA818340e6d;
        tokens[Chains.KAIA_MAINNET][Tokens.OUSDT] = 0xceE8FAF64bB97a73bb51E115Aa89C17FfA8dD167;
        tokens[Chains.KAIA_MAINNET][Tokens.KSD] = 0x4Fa62F1f404188CE860c8f0041d6Ac3765a72E67;
        tokens[Chains.KAIA_MAINNET][Tokens.BTCB] = 0x15D9f3AB1982B0e5a415451259994Ff40369f584;
        tokens[Chains.KAIA_MAINNET][Tokens.SUSDA] = 0x585e26627c3B630B3c45b4f0E007dB5d90Fae9b2;
        tokens[Chains.KAIA_MAINNET][Tokens.USDA] = 0xdC3Cf1961B08da169b078F7DF6F26676Bf6a4FF6;
        tokens[Chains.KAIA_MAINNET][Tokens.OUSDC] = 0x754288077D0fF82AF7a5317C7CB8c444D421d103;
        tokens[Chains.KAIA_MAINNET][Tokens.OETH] = 0x34d21b1e550D73cee41151c77F3c73359527a396;
        tokens[Chains.KAIA_MAINNET][Tokens.OWBTC] = 0x16D0e1fBD024c600Ca0380A4C5D57Ee7a2eCBf9c;
        tokens[Chains.KAIA_MAINNET][Tokens.KDAI] = 0x5c74070FDeA071359b86082bd9f9b3dEaafbe32b;
        tokens[Chains.KAIA_MAINNET][Tokens.WEMIX] = 0x5096dB80B21Ef45230C9E423C373f1FC9C0198dd;
        tokens[Chains.BASE][Tokens.WETH] = 0x4200000000000000000000000000000000000006;
        tokens[Chains.BASE][Tokens.CBETH] = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
        tokens[Chains.BASE][Tokens.USDBC] = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
        tokens[Chains.BASE][Tokens.WSTETH] = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
        tokens[Chains.BASE][Tokens.USDC] = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        tokens[Chains.BASE][Tokens.WEETH] = 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A;
        tokens[Chains.BASE][Tokens.CBBTC] = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
        tokens[Chains.BASE][Tokens.EZETH] = 0x2416092f143378750bb29b79eD961ab195CcEea5;
        tokens[Chains.BASE][Tokens.GHO] = 0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee;
        tokens[Chains.BASE][Tokens.WRSETH] = 0xEDfa23602D0EC14714057867A78d01e94176BEA0;
        tokens[Chains.BASE][Tokens.LBTC] = 0xecAc9C5F704e954931349Da37F60E39f515c11c1;
        tokens[Chains.BASE][Tokens.EURC] = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
        tokens[Chains.BASE][Tokens.AAVE] = 0x63706e401c06ac8513145b7687A14804d17f814b;
        tokens[Chains.BASE][Tokens.TBTC] = 0x236aa50979D5f3De3Bd1Eeb40E81137F22ab794b;
        tokens[Chains.BASE][Tokens.SYRUPUSDC] = 0x660975730059246A68521a3e2FBD4740173100f5;
        tokens[Chains.BASE][Tokens.SOLVBTC] = 0x3B86Ad95859b6AB773f55f8d94B4b9d443EE931f;
        tokens[Chains.BASE][Tokens.XSOLVBTC] = 0xC26C9099BD3789107888c35bb41178079B282561;
        tokens[Chains.BASE][Tokens.DAI] = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
        tokens[Chains.BASE][Tokens.AERO] = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
        tokens[Chains.BASE][Tokens.XUSDZ] = 0x0A27E060C0406f8Ab7B64e3BEE036a37e5a62853;
        tokens[Chains.BASE][Tokens.VAMM_USDCAERO] = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d;
        tokens[Chains.BASE][Tokens.SUSDZUSDC] = 0x1097dFe9539350cb466dF9CA89A5e61195A520B0;
        tokens[Chains.BASE][Tokens.USDZ] = 0x04D5ddf5f3a8939889F11E97f8c4BB48317F1938;
        tokens[Chains.BASE][Tokens.SUSDZ] = 0xe31eE12bDFDD0573D634124611e85338e2cBF0cF;
        tokens[Chains.BASE][Tokens.SUPEROETHB] = 0xDBFeFD2e8460a6Ee4955A68582F85708BAEA60A3;
        tokens[Chains.BASE][Tokens.PUMPBTC] = 0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e;
        tokens[Chains.BASE][Tokens.WSUPEROETHB] = 0x7FcD174E80f264448ebeE8c88a7C4476AAF58Ea6;
        tokens[Chains.BASE][Tokens.PT_CBETH_25DEC2025] = 0xE46c8bA948f8071b425a1f7Ba45c0a65CBAcea2e;
        tokens[Chains.BASE][Tokens.PT_LBTC_29MAY2025] = 0x5d746848005507DA0b1717C137A10C30AD9ee307;
        tokens[Chains.BASE][Tokens.ZAI] = 0x69000dFD5025E82f48Eb28325A2B88a241182CEd;
        tokens[Chains.BASE][Tokens.USR] = 0x35E5dB674D8e93a03d814FA0ADa70731efe8a4b9;
        tokens[Chains.BASE][Tokens.RETH] = 0xB6fe221Fe9EeF5aBa221c348bA20A1Bf5e73624c;
        tokens[Chains.BASE][Tokens.USDS] = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
        tokens[Chains.BASE][Tokens.SUSDS] = 0x5875eEE11Cf8398102FdAd704C9E96607675467a;
        tokens[Chains.BASE][Tokens.PT_USR_25SEP2025] = 0xa6F0A4D18B6f6DdD408936e81b7b3A8BEFA18e77;
        tokens[Chains.BASE][Tokens.VIRTUAL] = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
        tokens[Chains.BASE][Tokens.YOETH] = 0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7;
        tokens[Chains.BASE][Tokens.YOUSD] = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
        tokens[Chains.BASE][Tokens.PT_USDE_11DEC2025] = 0x194b8FeD256C02eF1036Ed812Cae0c659ee6F7FD;
        tokens[Chains.BASE][Tokens.PRFI] = 0x7BBCf1B600565AE023a1806ef637Af4739dE3255;
        tokens[Chains.BASE][Tokens.WELL] = 0xA88594D404727625A9437C3f886C7643872296AE;
        tokens[Chains.BASE][Tokens.MORPHO] = 0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842;
        tokens[Chains.BASE][Tokens.CBXRP] = 0xcb585250f852C6c6bf90434AB21A00f02833a4af;
        tokens[Chains.BASE][Tokens.MAMO] = 0x7300B37DfdfAb110d83290A29DfB31B1740219fE;
        tokens[Chains.BASE][Tokens.SUUSD] = 0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8;
        tokens[Chains.BASE][Tokens.SUETH] = 0x1c22531AA9747d76fFF8F0A43b37954ca67d28e0;
        tokens[Chains.BASE][Tokens.ETH] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.BASE][Tokens.STUSD] = 0x0022228a2cc5E7eF0274A7Baa600d44da5aB5776;
        tokens[Chains.BASE][Tokens.STEUR] = 0x004626A008B1aCdC4c74ab51644093b155e59A23;
        tokens[Chains.BASE][Tokens.USX] = 0xc142171B138DB17a1B7Cb999C44526094a4dae05;
        tokens[Chains.BASE][Tokens.SUSX] = 0xbC404429558292eE2D769E57d57D6E74bbd2792d;
        tokens[Chains.PLASMA_MAINNET][Tokens.USDT0] = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
        tokens[Chains.PLASMA_MAINNET][Tokens.USDE] = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
        tokens[Chains.PLASMA_MAINNET][Tokens.SUSDE] = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;
        tokens[Chains.PLASMA_MAINNET][Tokens.XAUT0] = 0x1B64B9025EEbb9A6239575dF9Ea4b9Ac46D4d193;
        tokens[Chains.PLASMA_MAINNET][Tokens.WEETH] = 0xA3D68b74bF0528fdD07263c60d6488749044914b;
        tokens[Chains.PLASMA_MAINNET][Tokens.WETH] = 0x9895D81bB462A195b4922ED7De0e3ACD007c32CB;
        tokens[Chains.PLASMA_MAINNET][Tokens.PT_USDE_15JAN2026] = 0x93B544c330F60A2aa05ceD87aEEffB8D38FD8c9a;
        tokens[Chains.PLASMA_MAINNET][Tokens.PT_SUSDE_15JAN2026] = 0x02FCC4989B4C9D435b7ceD3fE1Ba4CF77BBb5Dd8;
        tokens[Chains.PLASMA_MAINNET][Tokens.WSTETH] = 0xe48D935e6C9e735463ccCf29a7F11e32bC09136E;
        tokens[Chains.PLASMA_MAINNET][Tokens.WRSETH] = 0xe561FE05C39075312Aa9Bc6af79DdaE981461359;
        tokens[Chains.PLASMA_MAINNET][Tokens.SYRUPUSDT] = 0xC4374775489CB9C56003BF2C9b12495fC64F0771;
        tokens[Chains.PLASMA_MAINNET][Tokens.WXPL] = 0x6100E367285b01F48D07953803A2d8dCA5D19873;
        tokens[Chains.PLASMA_MAINNET][Tokens.PT_SUSDE_9APR2026] = 0xab509448ad489e2E1341e25CC500f2596464Cc82;
        tokens[Chains.PLASMA_MAINNET][Tokens.PT_USDE_9APR2026] = 0x54Dc267be2839303ff1e323584A16e86CeC4Aa44;
        tokens[Chains.PLASMA_MAINNET][Tokens.XUSD] = 0x6eAf19b2FC24552925dB245F9Ff613157a7dbb4C;
        tokens[Chains.PLASMA_MAINNET][Tokens.PLUSD] = 0xf91c31299E998C5127Bc5F11e4a657FC0cF358CD;
        tokens[Chains.PLASMA_MAINNET][Tokens.SPLUSD] = 0x616185600989Bf8339b58aC9e539d49536598343;
        tokens[Chains.MODE][Tokens.SOLVBTC] = 0x541FD749419CA806a8bc7da8ac23D346f2dF8B77;
        tokens[Chains.MODE][Tokens.M_BTC] = 0x59889b7021243dB5B1e065385F918316cD90D46c;
        tokens[Chains.MODE][Tokens.UNIBTC] = 0x6B2a01A5f79dEb4c2f3c0eDa7b01DF456FbD726a;
        tokens[Chains.MODE][Tokens.USDC] = 0xd988097fb8612cc24eeC14542bC03424c656005f;
        tokens[Chains.MODE][Tokens.USDT] = 0xf0F161fDA2712DB8b566946122a5af183995e2eD;
        tokens[Chains.MODE][Tokens.WETH] = 0x4200000000000000000000000000000000000006;
        tokens[Chains.MODE][Tokens.EZETH] = 0x2416092f143378750bb29b79eD961ab195CcEea5;
        tokens[Chains.MODE][Tokens.WEETH] = 0x028227c4dd1e5419d11Bb6fa6e661920c519D4F5;
        tokens[Chains.MODE][Tokens.WRSETH] = 0xe7903B1F75C534Dd8159b313d92cDCfbC62cB3Cd;
        tokens[Chains.MODE][Tokens.WEETH_MODE] = 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A;
        tokens[Chains.MODE][Tokens.MODE] = 0xDfc7C877a950e49D2610114102175A06C2e3167a;
        tokens[Chains.MODE][Tokens.SUSDE] = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;
        tokens[Chains.MODE][Tokens.STONE] = 0x80137510979822322193FC997d400D5A6C747bf7;
        tokens[Chains.ARBITRUM_ONE][Tokens.DAI] = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        tokens[Chains.ARBITRUM_ONE][Tokens.LINK] = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
        tokens[Chains.ARBITRUM_ONE][Tokens.USDC_E] = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
        tokens[Chains.ARBITRUM_ONE][Tokens.WBTC] = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
        tokens[Chains.ARBITRUM_ONE][Tokens.WETH] = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        tokens[Chains.ARBITRUM_ONE][Tokens.USDT] = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
        tokens[Chains.ARBITRUM_ONE][Tokens.AAVE] = 0xba5DdD1f9d7F570dc94a51479a000E3BCE967196;
        tokens[Chains.ARBITRUM_ONE][Tokens.EURS] = 0xD22a58f79e9481D1a88e00c343885A588b34b68B;
        tokens[Chains.ARBITRUM_ONE][Tokens.WSTETH] = 0x5979D7b546E38E414F7E9822514be443A4800529;
        tokens[Chains.ARBITRUM_ONE][Tokens.MIMATIC] = 0x3F56e0c36d275367b8C502090EDF38289b3dEa0d;
        tokens[Chains.ARBITRUM_ONE][Tokens.RETH] = 0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8;
        tokens[Chains.ARBITRUM_ONE][Tokens.LUSD] = 0x93b346b6BC2548dA6A1E7d98E9a421B42541425b;
        tokens[Chains.ARBITRUM_ONE][Tokens.USDC] = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        tokens[Chains.ARBITRUM_ONE][Tokens.FRAX] = 0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F;
        tokens[Chains.ARBITRUM_ONE][Tokens.ARB] = 0x912CE59144191C1204E64559FE8253a0e49E6548;
        tokens[Chains.ARBITRUM_ONE][Tokens.WEETH] = 0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe;
        tokens[Chains.ARBITRUM_ONE][Tokens.GHO] = 0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33;
        tokens[Chains.ARBITRUM_ONE][Tokens.EZETH] = 0x2416092f143378750bb29b79eD961ab195CcEea5;
        tokens[Chains.ARBITRUM_ONE][Tokens.RSETH] = 0x4186BFC76E2E237523CBC30FD220FE055156b41F;
        tokens[Chains.ARBITRUM_ONE][Tokens.TBTC] = 0x6c84a8f1c29108F47a79964b5Fe888D4f4D0dE40;
        tokens[Chains.ARBITRUM_ONE][Tokens.PUMPBTC] = 0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e;
        tokens[Chains.ARBITRUM_ONE][Tokens.SOLVBTC] = 0x3647c54c4c2C65bC7a2D63c0Da2809B399DBBDC0;
        tokens[Chains.ARBITRUM_ONE][Tokens.SOLVBTC_ENA] = 0xaFAfd68AFe3fe65d376eEC9Eab1802616cFacCb8;
        tokens[Chains.ARBITRUM_ONE][Tokens.XSOLVBTC] = 0x346c574C56e1A4aAa8dc88Cda8F7EB12b39947aB;
        tokens[Chains.ARBITRUM_ONE][Tokens.GMX] = 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a;
        tokens[Chains.ARBITRUM_ONE][Tokens.WUSDM] = 0x57F5E098CaD7A3D1Eed53991D4d66C45C9AF7812;
        tokens[Chains.ARBITRUM_ONE][Tokens.TETH] = 0xd09ACb80C1E8f2291862c4978A008791c9167003;
        tokens[Chains.ARBITRUM_ONE][Tokens.PLVGLP] = 0x5326E71Ff593Ecc2CF7AcaE5Fe57582D6e74CFF1;
        tokens[Chains.ARBITRUM_ONE][Tokens.ETH] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.ARBITRUM_ONE][Tokens.DPX] = 0x6C2C06790b3E3E3c38e12Ee22F8183b37a13EE55;
        tokens[Chains.ARBITRUM_ONE][Tokens.MAGIC] = 0x539bdE0d7Dbd336b79148AA742883198BBF60342;
        tokens[Chains.ARBITRUM_ONE][Tokens.MIM] = 0xFEa7a6a0B346362BF88A9e4A88416B77a57D6c2A;
        tokens[Chains.ARBITRUM_ONE][Tokens.PENDLE] = 0x0c880f6761F1af8d9Aa9C466984b80DAb9a8c9e8;
        tokens[Chains.ARBITRUM_ONE][Tokens.SUUSD] = 0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8;
        tokens[Chains.ARBITRUM_ONE][Tokens.SUETH] = 0x1c22531AA9747d76fFF8F0A43b37954ca67d28e0;
        tokens[Chains.ARBITRUM_ONE][Tokens.SUBTC] = 0xe85411C030fB32A9D8b14Bbbc6CB19417391F711;
        tokens[Chains.ARBITRUM_ONE][Tokens.PT_WEETH_26SEP2024] = 0xb8b0a120F6A68Dd06209619F62429fB1a8e92feC;
        tokens[Chains.ARBITRUM_ONE][Tokens.PT_RSETH_26SEP2024] = 0x30c98c0139B62290E26aC2a2158AC341Dcaf1333;
        tokens[Chains.ARBITRUM_ONE][Tokens.PT_WEETH_26DEC2024] = 0xE2B2D203577c7cb3D043E89cCf90b5E24d19b66f;
        tokens[Chains.ARBITRUM_ONE][Tokens.PT_RSETH_26DEC2024] = 0x355ec27c9d4530dE01A103FA27F884a2F3dA65ef;
        tokens[Chains.ARBITRUM_ONE][Tokens.UNI] = 0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0;
        tokens[Chains.ARBITRUM_ONE][Tokens.GMDUSDC] = 0x3DB4B7DA67dd5aF61Cb9b3C70501B1BdB24b2C22;
        tokens[Chains.ARBITRUM_ONE][Tokens.USX] = 0x641441c631e2F909700d2f41FD87F0aA6A6b4EDb;
        tokens[Chains.ARBITRUM_ONE][Tokens.DF] = 0xaE6aab43C4f3E0cea4Ab83752C278f8dEbabA689;
        tokens[Chains.ARBITRUM_ONE][Tokens.CRV] = 0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978;
        tokens[Chains.ARBITRUM_ONE][Tokens.SUSX] = 0xbC404429558292eE2D769E57d57D6E74bbd2792d;
        tokens[Chains.CELO_MAINNET][Tokens.USDC] = 0xcebA9300f2b948710d2653dD7B07f33A8B32118C;
        tokens[Chains.CELO_MAINNET][Tokens.USDT] = 0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e;
        tokens[Chains.CELO_MAINNET][Tokens.CEUR] = 0xD8763CBa276a3738E6DE85b4b3bF5FDed6D6cA73;
        tokens[Chains.CELO_MAINNET][Tokens.CUSD] = 0x765DE816845861e75A25fCA122bb6898B8B1282a;
        tokens[Chains.CELO_MAINNET][Tokens.CELO] = 0x471EcE3750Da237f93B8E339c536989b8978a438;
        tokens[Chains.CELO_MAINNET][Tokens.WETH] = 0xD221812de1BD094f35587EE8E174B07B6167D9Af;
        tokens[Chains.CELO_MAINNET][Tokens.CREAL] = 0xe8537a3d056DA446677B9E9d6c5dB704EaAb4787;
        tokens[Chains.CELO_MAINNET][Tokens.MOO] = 0x17700282592D6917F6A73D0bF8AcCf4D578c131e;
        tokens[Chains.HEMI_NETWORK][Tokens.UNIBTC] = 0xF9775085d726E782E83585033B58606f7731AB18;
        tokens[Chains.HEMI_NETWORK][Tokens.USDT] = 0xbB0D083fb1be0A9f6157ec484b6C79E0A4e31C2e;
        tokens[Chains.HEMI_NETWORK][Tokens.VUSD] = 0x7A06C4AeF988e7925575C50261297a946aD204A8;
        tokens[Chains.HEMI_NETWORK][Tokens.USDC_E] = 0xad11a8BEb98bbf61dbb1aa0F6d6F2ECD87b35afA;
        tokens[Chains.HEMI_NETWORK][Tokens.WETH] = 0x4200000000000000000000000000000000000006;
        tokens[Chains.HEMI_NETWORK][Tokens.WBTC] = 0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3;
        tokens[Chains.HEMI_NETWORK][Tokens.BRBTC] = 0x93919784C523f39CACaa98Ee0a9d96c3F32b593e;
        tokens[Chains.HEMI_NETWORK][Tokens.UBTC] = 0x78E26E8b953C7c78A58d69d8B9A91745C2BbB258;
        tokens[Chains.HEMI_NETWORK][Tokens.IBTC] = 0x8154Aaf094c2f03Ad550B6890E1d4264B5DdaD9A;
        tokens[Chains.HEMI_NETWORK][Tokens.M_BTC] = 0x9BFA177621119e64CecbEabE184ab9993E2ef727;
        tokens[Chains.HEMI_NETWORK][Tokens.ENZOBTC] = 0x6A9A65B84843F5fD4aC9a0471C4fc11AFfFBce4a;
        tokens[Chains.HEMI_NETWORK][Tokens.HEMIBTC] = 0xAA40c0c7644e0b2B224509571e10ad20d9C4ef28;
        tokens[Chains.HEMI_NETWORK][Tokens.HEMI] = 0x99e3dE3817F6081B2568208337ef83295b7f591D;
        tokens[Chains.HEMI_NETWORK][Tokens.PUMPBTC] = 0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e;
        tokens[Chains.HEMI_NETWORK][Tokens.RSETH] = 0xc3eACf0612346366Db554C991D7858716db09f58;
        tokens[Chains.HEMI_NETWORK][Tokens.SLP] = 0xaF6ED58980B5a0732423469Dd9f3f69D9Dc6DAB5;
        tokens[Chains.HEMI_NETWORK][Tokens.SLP] = 0x0FFb62483517309AFd039B117D795521e8320a1b;
        tokens[Chains.HEMI_NETWORK][Tokens.SLP] = 0xf23eec60263dE9b0c8472c58BE10Feba28D9EB53;
        tokens[Chains.HEMI_NETWORK][Tokens.BFBTC] = 0x623F2774d9f27B59bc6b954544487532CE79d9DF;
        tokens[Chains.HEMI_NETWORK][Tokens.SATUSD] = 0xb4818BB69478730EF4e33Cc068dD94278e2766cB;
        tokens[Chains.HEMI_NETWORK][Tokens.ETH] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.HEMI_NETWORK][Tokens.SUUSD] = 0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8;
        tokens[Chains.HEMI_NETWORK][Tokens.SUETH] = 0x1c22531AA9747d76fFF8F0A43b37954ca67d28e0;
        tokens[Chains.HEMI_NETWORK][Tokens.SUBTC] = 0xe85411C030fB32A9D8b14Bbbc6CB19417391F711;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.DAI] = 0xd586E7F844cEa2F87f50152665BCbc2C279D8d70;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.LINK] = 0x5947BB275c521040051D82396192181b413227A3;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.USDC] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.WBTC] = 0x50b7545627a5162F82A992c33b87aDc75187B218;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.WETH] = 0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.USDT] = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.AAVE] = 0x63a72806098Bd3D9520cC43356dD78afe5D386D9;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.WAVAX] = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.SAVAX] = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.FRAX] = 0xD24C2Ad096400B6FBcd2ad8B24E7acBc21A1da64;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.MIMATIC] = 0x5c49b268c9841AFF1Cc3B0a418ff5c3442eE3F3b;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.BTC_B] = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.AUSD] = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.GHO] = 0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.EURC] = 0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.USDE] = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.SUSDE] = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.WRSETH] = 0x7bFd4CA2a6Cf3A3fDDd645D10B323031afe47FF0;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.USDT_E] = 0xc7198437980c041c805A1EDcbA50c1Ce5db95118;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.USDC_E] = 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.CRV_E] = 0x249848BeCA43aC405b8102Ec90Dd5F22CA513c06;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.JOE] = 0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.UST] = 0xb599c3590F42f8F995ECfa0f85D2980B76862fc1;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.CRV] = 0x47536F17F4fF30e64A96a7555826b8f9e66ec468;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.WXT] = 0xfcDe4A87b8b6FA58326BB462882f1778158B02F1;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.XAVA] = 0xd1c3f94DE7e5B45fa4eDBBA472491a9f4B166FC4;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.AVAX] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.QI] = 0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.BUSD] = 0x9C9e5fD8bbc25984B178FdCE6117Defa39d2db39;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.COQ] = 0x420FcA0121DC28039145009570975747295f2329;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.SOLVBTC] = 0xbc78D84Ba0c46dFe32cf2895a19939c86b81a777;
        tokens[Chains.AVALANCHE_C_CHAIN][Tokens.NXPC] = 0x5E0E90E268BC247Cc850c789A0DB0d5c7621fb59;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.WETH] = 0x4200000000000000000000000000000000000006;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.EZETH] = 0x2416092f143378750bb29b79eD961ab195CcEea5;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.WEETH] = 0x3535DF6e1d776631D0cBA53FE9efD34bCbDcEeD4;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.WEETHS] = 0x4b03831043082E3e5191218ad5331E99AaaC4A81;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.BRIDGED_MSTETH] = 0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.BRIDGED_EGETH] = 0x4bcc7c793534246BC18acD3737aA4897FF23B458;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.RSETH] = 0x4186BFC76E2E237523CBC30FD220FE055156b41F;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.USDT] = 0x46dDa6a5a559d861c06EC9a95Fb395f5C3Db0742;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.USDC] = 0x3b952c8C9C44e8Fe201e2b26F6B2200203214cfF;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.WBTC] = 0x19df5689Cfce64bC2A55F7220B0Cd522659955EF;
        tokens[Chains.ZIRCUIT_MAINNET][Tokens.ZRC] = 0xfd418e42783382E86Ae91e445406600Ba144D162;
        tokens[Chains.LINEA][Tokens.WETH] = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
        tokens[Chains.LINEA][Tokens.WBTC] = 0x3aAB2285ddcDdaD8edf438C1bAB47e1a9D05a9b4;
        tokens[Chains.LINEA][Tokens.USDC] = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
        tokens[Chains.LINEA][Tokens.USDT] = 0xA219439258ca9da29E9Cc4cE5596924745e12B93;
        tokens[Chains.LINEA][Tokens.WSTETH] = 0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F;
        tokens[Chains.LINEA][Tokens.EZETH] = 0x2416092f143378750bb29b79eD961ab195CcEea5;
        tokens[Chains.LINEA][Tokens.WEETH] = 0x1Bf74C010E6320bab11e2e5A532b5AC15e0b8aA6;
        tokens[Chains.LINEA][Tokens.WRSETH] = 0xD2671165570f41BBB3B0097893300b6EB6101E6C;
        tokens[Chains.LINEA][Tokens.MUSD] = 0xacA92E438df0B2401fF60dA7E4337B687a2435DA;
        tokens[Chains.LINEA][Tokens.BUSD] = 0x7d43AABC515C356145049227CeE54B608342c0ad;
        tokens[Chains.LINEA][Tokens.MIMATIC] = 0xf3B001D64C656e30a62fbaacA003B1336b4ce12A;
        tokens[Chains.LINEA][Tokens.GRAI] = 0x894134a25a5faC1c2C26F1d8fBf05111a3CB9487;
        tokens[Chains.LINEA][Tokens.UNIETH] = 0x15EEfE5B297136b8712291B632404B66A8eF4D25;
        tokens[Chains.LINEA][Tokens.USDE] = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
        tokens[Chains.LINEA][Tokens.SUSDE] = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;
        tokens[Chains.LINEA][Tokens.STONE] = 0x93F4d0ab6a8B4271f4a28Db399b5E30612D21116;
        tokens[Chains.LINEA][Tokens.AXLFRXETH] = 0xEcc68d0451E20292406967Fe7C04280E5238Ac7D;
        tokens[Chains.LINEA][Tokens.DAI] = 0x4AF15ec2A0BD43Db75dd04E62FAA3B8EF36b00d5;
        tokens[Chains.LINEA][Tokens.INETH] = 0x5A7a183B6B44Dc4EC2E3d2eF43F98C5152b1d76d;
        tokens[Chains.LINEA][Tokens.LYU] = 0xb20116eE399f15647BB1eEf9A74f6ef3b58bc951;
        tokens[Chains.LINEA][Tokens.SOLVBTC_M] = 0x5FFcE65A40f6d3de5332766ffF6A28BF491C868c;
        tokens[Chains.LINEA][Tokens.M_BTC] = 0xe4D584ae9b753e549cAE66200A6475d2f00705f7;
        tokens[Chains.LINEA][Tokens.CROAK] = 0xaCb54d07cA167934F57F829BeE2cC665e1A5ebEF;
        tokens[Chains.LINEA][Tokens.FOXY] = 0x5FBDF89403270a1846F5ae7D113A989F850d1566;
        tokens[Chains.BOB][Tokens.UNIBTC] = 0x236f8c0a61dA474dB21B693fB2ea7AAB0c803894;
        tokens[Chains.BOB][Tokens.WBTC] = 0x03C7054BCB39f7b2e5B2c7AcB37583e32D70Cfa3;
        tokens[Chains.BOB][Tokens.TBTC] = 0xBBa2eF945D523C4e2608C9E1214C2Cc64D4fc2e2;
        tokens[Chains.BOB][Tokens.SOLVBTC] = 0x541FD749419CA806a8bc7da8ac23D346f2dF8B77;
        tokens[Chains.BOB][Tokens.SOLVBTC_BABYLON] = 0xCC0966D8418d412c599A6421b760a847eB169A8c;
        tokens[Chains.BOB][Tokens.WBTC] = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
        tokens[Chains.BOB][Tokens.ETH] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.BOB][Tokens.USDT] = 0x05D032ac25d322df992303dCa074EE7392C117b9;
        tokens[Chains.BOB][Tokens.USDC_E] = 0xe75D0fB2C24A55cA1e3F96781a2bCC7bdba058F0;
        tokens[Chains.BOB][Tokens.SOV] = 0xba20a5e63eeEFfFA6fD365E7e540628F8fC61474;
        tokens[Chains.BOB][Tokens.STONE] = 0x96147A9Ae9a42d7Da551fD2322ca15B71032F342;
        tokens[Chains.BOB][Tokens.WSTETH] = 0x85008aE6198BC91aC0735CB5497CF125ddAAc528;
        tokens[Chains.BOB][Tokens.RETH] = 0xB5686c4f60904Ec2BDA6277d6FE1F7cAa8D1b41a;
        tokens[Chains.BOB][Tokens.DAI] = 0x6c851F501a3F24E29A8E39a29591cddf09369080;
        tokens[Chains.BOB][Tokens.SOLVBTC_B] = 0x59889b7021243dB5B1e065385F918316cD90D46c;
        tokens[Chains.BOB][Tokens.SATUSD] = 0x78Fea795cBFcC5fFD6Fb5B845a4f53d25C283bDB;
        tokens[Chains.BOB][Tokens.FBTC] = 0xC96dE26018A54D51c097160568752c4E3BD6C364;
        tokens[Chains.BOB][Tokens.THUSD] = 0xf7EF136751D7496021858c048FFA4f978C27831A;
        tokens[Chains.BOB][Tokens.LBTC] = 0xA45d4121b3D47719FF57a947A9d961539Ba33204;
        tokens[Chains.BOB][Tokens.PUMPBTC] = 0x1fCca65fb6Ae3b2758b9b2B394CB227eAE404e1E;
        tokens[Chains.BOB][Tokens.S1] = 0x2FecE49b79292c2CF6218b2bc657fDDFd2941e18;
        tokens[Chains.BOB][Tokens.SATOSHI_STABLECOIN_V2] = 0xecf21b335B41f9d5A89f6186A99c19a3c467871f;
        tokens[Chains.BERACHAIN][Tokens.EBTC] = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
        tokens[Chains.BERACHAIN][Tokens.WETH] = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
        tokens[Chains.BERACHAIN][Tokens.HONEY] = 0xFCBD14DC51f0A4d49d5E53C2E0950e0bC26d0Dce;
        tokens[Chains.BERACHAIN][Tokens.IBGT] = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b;
        tokens[Chains.BERACHAIN][Tokens.LBTC] = 0xecAc9C5F704e954931349Da37F60E39f515c11c1;
        tokens[Chains.BERACHAIN][Tokens.NECT] = 0x1cE0a25D13CE4d52071aE7e02Cf1F6606F4C79d3;
        tokens[Chains.BERACHAIN][Tokens.RSETH] = 0x4186BFC76E2E237523CBC30FD220FE055156b41F;
        tokens[Chains.BERACHAIN][Tokens.RSWETH] = 0x850CDF416668210ED0c36bfFF5d21921C7adA3b8;
        tokens[Chains.BERACHAIN][Tokens.SUSDE] = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;
        tokens[Chains.BERACHAIN][Tokens.USDC_E] = 0x549943e04f40284185054145c6E4e9568C1D3241;
        tokens[Chains.BERACHAIN][Tokens.USDE] = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
        tokens[Chains.BERACHAIN][Tokens.USDT] = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
        tokens[Chains.BERACHAIN][Tokens.WBERA] = 0x6969696969696969696969696969696969696969;
        tokens[Chains.BERACHAIN][Tokens.WEETH] = 0x7DCC39B4d1C53CB31e1aBc0e358b43987FEF80f7;
        tokens[Chains.BERACHAIN][Tokens.SUUSD] = 0x8BF591Eae535f93a242D5A954d3Cde648b48A5A8;
        tokens[Chains.BERACHAIN][Tokens.SUBTC] = 0xe85411C030fB32A9D8b14Bbbc6CB19417391F711;
        tokens[Chains.BERACHAIN][Tokens.BERA] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.BERACHAIN][Tokens.STONE] = 0xEc901DA9c68E90798BbBb74c11406A32A70652C3;
        tokens[Chains.BERACHAIN][Tokens.WBTC] = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
        tokens[Chains.BLAST][Tokens.WETH] = 0x4300000000000000000000000000000000000004;
        tokens[Chains.BLAST][Tokens.USDB] = 0x4300000000000000000000000000000000000003;
        tokens[Chains.BLAST][Tokens.FWWETH] = 0x66714DB8F3397c767d0A602458B5b4E3C0FE7dd1;
        tokens[Chains.BLAST][Tokens.FWUSDB] = 0x866f2C06B83Df2ed7Ca9C2D044940E7CD55a06d6;
        tokens[Chains.BLAST][Tokens.RING_V2] = 0x9BE8a40C9cf00fe33fd84EAeDaA5C4fe3f04CbC3;
        tokens[Chains.BLAST][Tokens.OETH] = 0x0872b71EFC37CB8DdE22B2118De3d800427fdba0;
        tokens[Chains.BLAST][Tokens.OUSDB] = 0x9aECEdCD6A82d26F2f86D331B17a1C1676442A87;
        tokens[Chains.BLAST][Tokens.EZETH] = 0x2416092f143378750bb29b79eD961ab195CcEea5;
        tokens[Chains.BLAST][Tokens.SLP_USDB] = 0x56e0f6DF03883611C9762e78d4091E39aD9c420E;
        tokens[Chains.BLAST][Tokens.SLP_WETH] = 0x3D4621fa5ff784dfB2fcDFd5B293224167F239db;
        tokens[Chains.BLAST][Tokens.T_LP] = 0x12c69BFA3fb3CbA75a1DEFA6e976B87E233fc7df;
        tokens[Chains.BLAST][Tokens.WBTC] = 0xF7bc58b8D8f97ADC129cfC4c9f45Ce3C0E1D2692;
        tokens[Chains.BLAST][Tokens.WRSETH] = 0xe7903B1F75C534Dd8159b313d92cDCfbC62cB3Cd;
        tokens[Chains.BLAST][Tokens.DETH] = 0x1Da40C742F32bBEe81694051c0eE07485fC630f6;
        tokens[Chains.BLAST][Tokens.DUSD] = 0x1A3D9B2fa5c6522c8c071dC07125cE55dF90b253;
        tokens[Chains.BLAST][Tokens.WEETH] = 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A;
        tokens[Chains.BLAST][Tokens.BLAST] = 0xb1a5700fA2358173Fe465e6eA4Ff52E36e88E2ad;
        tokens[Chains.BLAST][Tokens.YES] = 0x1a49351bdB4BE48C0009b661765D01ed58E8C2d8;
        tokens[Chains.TAIKO_ALETHIA][Tokens.USDC] = 0x07d83526730c7438048D55A4fc0b850e2aaB6f0b;
        tokens[Chains.TAIKO_ALETHIA][Tokens.WETH] = 0xA51894664A773981C6C112C43ce576f315d5b1B6;
        tokens[Chains.TAIKO_ALETHIA][Tokens.TAIKO] = 0xA9d23408b9bA935c230493c40C73824Df71A0975;
        tokens[Chains.TAIKO_ALETHIA][Tokens.USDC_E] = 0x19e26B0638bf63aa9fa4d14c6baF8D52eBE86C5C;
        tokens[Chains.TAIKO_ALETHIA][Tokens.USDT] = 0x9c2dc7377717603eB92b2655c5f2E7997a4945BD;
        tokens[Chains.TAIKO_ALETHIA][Tokens.USDT] = 0x2DEF195713CF4a606B49D07E520e22C17899a736;
        tokens[Chains.TAIKO_ALETHIA][Tokens.M_BTC] = 0xf7fB2DF9280eB0a76427Dc3b34761DB8b1441a49;
        tokens[Chains.TAIKO_ALETHIA][Tokens.WEETH] = 0x756B6574b3162077A630895995B443aA68cD2015;
        tokens[Chains.TAIKO_ALETHIA][Tokens.SOLVBTC] = 0x541FD749419CA806a8bc7da8ac23D346f2dF8B77;
        tokens[Chains.TAIKO_ALETHIA][Tokens.XSOLVBTC] = 0xCC0966D8418d412c599A6421b760a847eB169A8c;
        tokens[Chains.TAIKO_ALETHIA][Tokens.SUSDA] = 0x5d5c8Aec46661f029A5136a4411C73647a5714a7;
        tokens[Chains.TAIKO_ALETHIA][Tokens.USDA] = 0xff12470a969Dd362EB6595FFB44C82c959Fe9ACc;
        tokens[Chains.BITLAYER_MAINNET][Tokens.WBTC] = 0xfF204e2681A6fA0e2C3FaDe68a1B28fb90E4Fc5F;
        tokens[Chains.BITLAYER_MAINNET][Tokens.UNIBTC] = 0x93919784C523f39CACaa98Ee0a9d96c3F32b593e;
        tokens[Chains.BITLAYER_MAINNET][Tokens.ETH] = 0xEf63d4E178b3180BeEc9B0E143e0f37F4c93f4C2;
        tokens[Chains.BITLAYER_MAINNET][Tokens.USDC] = 0x9827431e8b77E87C9894BD50B055D6BE56bE0030;
        tokens[Chains.BITLAYER_MAINNET][Tokens.USDT] = 0xfe9f969faf8Ad72a83b761138bF25dE87eFF9DD2;
        tokens[Chains.BITLAYER_MAINNET][Tokens.BITUSD] = 0x07373d112EDc4570B46996Ad1187bc4ac9Fb5Ed0;
        tokens[Chains.BITLAYER_MAINNET][Tokens.STBTC] = 0xf6718b2701D4a6498eF77D7c152b2137Ab28b8A3;
        tokens[Chains.BITLAYER_MAINNET][Tokens.SOLVBTC_M] = 0xe04d21d999FaEDf1e72AdE6629e20A11a1ed14FA;
        tokens[Chains.BITLAYER_MAINNET][Tokens.BCLP_STBTC_WBTC] = 0xb88A54EBBdA8EdbC1c2816aCE1DC2B7C6715972d;
        tokens[Chains.BITLAYER_MAINNET][Tokens.STABLE_LP] = 0xb750f79Cf4768597F4D05d8009FCc7cEe2704824;
        tokens[Chains.BITLAYER_MAINNET][Tokens.USDC] = 0xf8C374CE88A3BE3d374e8888349C7768B607c755;
        tokens[Chains.BITLAYER_MAINNET][Tokens.SUSDA] = 0xE8cfc9F5C3Ad6EeeceD88534aA641355451DB326;
        tokens[Chains.BITLAYER_MAINNET][Tokens.USDA] = 0x91BD7F5E328AEcd1024E4118ADE0Ccb786f55DB1;
        tokens[Chains.BITLAYER_MAINNET][Tokens.BTC] = 0x0000000000000000000000000000000000000000;
        tokens[Chains.SCROLL][Tokens.WETH] = 0x5300000000000000000000000000000000000004;
        tokens[Chains.SCROLL][Tokens.USDC] = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
        tokens[Chains.SCROLL][Tokens.WSTETH] = 0xf610A9dfB7C89644979b4A0f27063E9e7d7Cda32;
        tokens[Chains.SCROLL][Tokens.WEETH] = 0x01f0a31698C4d065659b9bdC21B3610292a1c506;
        tokens[Chains.SCROLL][Tokens.SCR] = 0xd29687c813D741E2F938F4aC377128810E217b1b;
        tokens[Chains.SCROLL][Tokens.USDT] = 0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df;
        tokens[Chains.SCROLL][Tokens.STONE] = 0x80137510979822322193FC997d400D5A6C747bf7;
        tokens[Chains.SCROLL][Tokens.WRSETH] = 0xa25b25548B4C98B0c7d3d27dcA5D5ca743d68b7F;
        tokens[Chains.KATANA][Tokens.WEETH] = 0x9893989433e7a383Cb313953e4c2365107dc19a7;
        tokens[Chains.KATANA][Tokens.VBWBTC] = 0x0913DA6Da4b42f538B445599b46Bb4622342Cf52;
        tokens[Chains.KATANA][Tokens.VBETH] = 0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62;
        tokens[Chains.KATANA][Tokens.YVVBUSDC] = 0x80c34BD3A3569E126e7055831036aa7b212cB159;
        tokens[Chains.KATANA][Tokens.YVVBUSDT] = 0x9A6bd7B6Fd5C4F87eb66356441502fc7dCdd185B;
        tokens[Chains.KATANA][Tokens.YVVBETH] = 0xE007CA01894c863d7898045ed5A3B4Abf0b18f37;
        tokens[Chains.KATANA][Tokens.YVVBWBTC] = 0xAa0362eCC584B985056E47812931270b99C91f9d;
        tokens[Chains.CORN][Tokens.WBTCN] = 0xda5dDd7270381A7C2717aD10D1c0ecB19e3CDFb2;
        tokens[Chains.CORN][Tokens.XSOLVBTC] = 0xCC0966D8418d412c599A6421b760a847eB169A8c;
        tokens[Chains.CORN][Tokens.SOLVBTC] = 0x541FD749419CA806a8bc7da8ac23D346f2dF8B77;
        tokens[Chains.CORN][Tokens.PUMPBTC] = 0xF469fBD2abcd6B9de8E169d128226C0Fc90a012e;
        tokens[Chains.CORN][Tokens.USDC_E] = 0xDF0B24095e15044538866576754F3C964e902Ee6;
        tokens[Chains.CORN][Tokens.SUSDA] = 0x2840F9d9f96321435Ab0f977E7FDBf32EA8b304f;
        tokens[Chains.CORN][Tokens.USDA] = 0xff12470a969Dd362EB6595FFB44C82c959Fe9ACc;
        tokens[Chains.CORN][Tokens.LBTC] = 0xecAc9C5F704e954931349Da37F60E39f515c11c1;
        tokens[Chains.CORN][Tokens.EBTC] = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
        tokens[Chains.NEON_EVM_MAINNET][Tokens.WNEON] = 0x202C35e517Fa803B537565c40F0a6965D7204609;
        tokens[Chains.NEON_EVM_MAINNET][Tokens.SOL] = 0x5f38248f339Bf4e84A2caf4e4c0552862dC9F82a;
        tokens[Chains.NEON_EVM_MAINNET][Tokens.USDC] = 0xEA6B04272f9f62F997F666F07D3a974134f7FFb9;
        tokens[Chains.NEON_EVM_MAINNET][Tokens.WETH] = 0xcFFd84d468220c11be64dc9dF64eaFE02AF60e8A;
        tokens[Chains.NEON_EVM_MAINNET][Tokens.JITOSOL] = 0xFA8fB7e3bd299B2A9693B1BFDCf5DD13Ab57007E;
        tokens[Chains.NEON_EVM_MAINNET][Tokens.USDT] = 0x5f0155d08eF4aaE2B500AefB64A3419dA8bB611a;
        tokens[Chains.HARMONY_MAINNET_SHARD_0][Tokens.ONE_DAI] = 0xEf977d2f931C1978Db5F6747666fa1eACB0d0339;
        tokens[Chains.HARMONY_MAINNET_SHARD_0][Tokens.LINK] = 0x218532a12a389a4a92fC0C5Fb22901D1c19198aA;
        tokens[Chains.HARMONY_MAINNET_SHARD_0][Tokens.USDC] = 0x985458E523dB3d53125813eD68c274899e9DfAb4;
        tokens[Chains.HARMONY_MAINNET_SHARD_0][Tokens.ONE_WBTC] = 0x3095c7557bCb296ccc6e363DE01b760bA031F2d9;
        tokens[Chains.HARMONY_MAINNET_SHARD_0][Tokens.ONE_ETH] = 0x6983D1E6DEf3690C4d616b13597A09e6193EA013;
        tokens[Chains.HARMONY_MAINNET_SHARD_0][Tokens.ONE_USDT] = 0x3C2B8Be99c50593081EAA2A724F0B8285F5aba8f;
        tokens[Chains.HARMONY_MAINNET_SHARD_0][Tokens.ONE_AAVE] = 0xcF323Aad9E522B93F11c352CaA519Ad0E14eB40F;
        tokens[Chains.HARMONY_MAINNET_SHARD_0][Tokens.WONE] = 0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a;
    }

    function _getChainRpc(string memory chainName) internal view returns (string memory) {
        return chainInfo[chainName].rpcUrl;
    }

    function _getChainId(string memory chainName) internal view returns (uint256) {
        return chainInfo[chainName].chainId;
    }
}

library Chains {
    string internal constant MOONBEAM = "MOONBEAM";
    string internal constant CRONOS_MAINNET = "CRONOS_MAINNET";
    string internal constant MONAD_MAINNET = "MONAD_MAINNET";
    string internal constant ETHEREUM_MAINNET = "ETHEREUM_MAINNET";
    string internal constant OP_MAINNET = "OP_MAINNET";
    string internal constant BNB_SMART_CHAIN_MAINNET = "BNB_SMART_CHAIN_MAINNET";
    string internal constant GNOSIS = "GNOSIS";
    string internal constant POLYGON_MAINNET = "POLYGON_MAINNET";
    string internal constant SONIC_MAINNET = "SONIC_MAINNET";
    string internal constant ZKSYNC_MAINNET = "ZKSYNC_MAINNET";
    string internal constant METIS_ANDROMEDA_MAINNET = "METIS_ANDROMEDA_MAINNET";
    string internal constant SONEIUM = "SONEIUM";
    string internal constant MANTLE = "MANTLE";
    string internal constant BASE = "BASE";
    string internal constant PLASMA_MAINNET = "PLASMA_MAINNET";
    string internal constant ARBITRUM_ONE = "ARBITRUM_ONE";
    string internal constant CELO_MAINNET = "CELO_MAINNET";
    string internal constant AVALANCHE_C_CHAIN = "AVALANCHE_C_CHAIN";
    string internal constant LINEA = "LINEA";
    string internal constant SCROLL = "SCROLL";
    string internal constant HARMONY_MAINNET_SHARD_0 = "HARMONY_MAINNET_SHARD_0";
    string internal constant TAIKO_ALETHIA = "TAIKO_ALETHIA";
    string internal constant MORPH = "MORPH";
    string internal constant TELOS_EVM_MAINNET = "TELOS_EVM_MAINNET";
    string internal constant METER_MAINNET = "METER_MAINNET";
    string internal constant FUSE_MAINNET = "FUSE_MAINNET";
    string internal constant TARAXA_MAINNET = "TARAXA_MAINNET";
    string internal constant ARTELA_MAINNET = "ARTELA_MAINNET";
    string internal constant KAIA_MAINNET = "KAIA_MAINNET";
    string internal constant HEMI_NETWORK = "HEMI_NETWORK";
    string internal constant CORE_BLOCKCHAIN_MAINNET = "CORE_BLOCKCHAIN_MAINNET";
    string internal constant BLAST = "BLAST";
    string internal constant HYPEREVM = "HYPEREVM";
    string internal constant MODE = "MODE";
    string internal constant CORN = "CORN";
    string internal constant ZETACHAIN_MAINNET = "ZETACHAIN_MAINNET";
    string internal constant MERLIN_MAINNET = "MERLIN_MAINNET";
    string internal constant IOTEX_NETWORK_MAINNET = "IOTEX_NETWORK_MAINNET";
    string internal constant BOB = "BOB";
    string internal constant BITLAYER_MAINNET = "BITLAYER_MAINNET";
    string internal constant B2_MAINNET = "B2_MAINNET";
    string internal constant SEI_NETWORK = "SEI_NETWORK";
    string internal constant GOAT_NETWORK = "GOAT_NETWORK";
    string internal constant OPBNB_MAINNET = "OPBNB_MAINNET";
    string internal constant MANTA_PACIFIC_MAINNET = "MANTA_PACIFIC_MAINNET";
    string internal constant X_LAYER_MAINNET = "X_LAYER_MAINNET";
    string internal constant ABSTRACT = "ABSTRACT";
    string internal constant ZIRCUIT_MAINNET = "ZIRCUIT_MAINNET";
    string internal constant BERACHAIN = "BERACHAIN";
    string internal constant FANTOM_OPERA = "FANTOM_OPERA";
    string internal constant NEON_EVM_MAINNET = "NEON_EVM_MAINNET";
    string internal constant PULSECHAIN = "PULSECHAIN";
    string internal constant XDC_NETWORK = "XDC_NETWORK";
    string internal constant KATANA = "KATANA";
    string internal constant UNICHAIN = "UNICHAIN";
    string internal constant TAC_MAINNET = "TAC_MAINNET";
    string internal constant FRAXTAL = "FRAXTAL";
    string internal constant WORLD_CHAIN = "WORLD_CHAIN";
    string internal constant LISK = "LISK";
    string internal constant BOTANIX_MAINNET = "BOTANIX_MAINNET";
    string internal constant ETHERLINK_MAINNET = "ETHERLINK_MAINNET";
    string internal constant INK = "INK";
    string internal constant PLUME_MAINNET = "PLUME_MAINNET";
    string internal constant FLAME = "FLAME";
    string internal constant BASECAMP = "BASECAMP";
    string internal constant RONIN_MAINNET = "RONIN_MAINNET";
    string internal constant ZKLINK_NOVA_MAINNET = "ZKLINK_NOVA_MAINNET";
    string internal constant CONFLUX_ESPACE = "CONFLUX_ESPACE";
}

library Tokens {
    string internal constant WETH = "WETH";
    string internal constant WSTETH = "WSTETH";
    string internal constant WBTC = "WBTC";
    string internal constant USDC = "USDC";
    string internal constant DAI = "DAI";
    string internal constant LINK = "LINK";
    string internal constant AAVE = "AAVE";
    string internal constant CBETH = "CBETH";
    string internal constant USDT = "USDT";
    string internal constant RETH = "RETH";
    string internal constant LUSD = "LUSD";
    string internal constant CRV = "CRV";
    string internal constant MKR = "MKR";
    string internal constant SNX = "SNX";
    string internal constant BAL = "BAL";
    string internal constant UNI = "UNI";
    string internal constant LDO = "LDO";
    string internal constant ENS = "ENS";
    string internal constant ONE_INCH = "ONE_INCH";
    string internal constant FRAX = "FRAX";
    string internal constant GHO = "GHO";
    string internal constant RPL = "RPL";
    string internal constant SDAI = "SDAI";
    string internal constant STG = "STG";
    string internal constant KNC = "KNC";
    string internal constant FXS = "FXS";
    string internal constant CRVUSD = "CRVUSD";
    string internal constant PYUSD = "PYUSD";
    string internal constant WEETH = "WEETH";
    string internal constant OSETH = "OSETH";
    string internal constant USDE = "USDE";
    string internal constant ETHX = "ETHX";
    string internal constant SUSDE = "SUSDE";
    string internal constant TBTC = "TBTC";
    string internal constant CBBTC = "CBBTC";
    string internal constant USDS = "USDS";
    string internal constant RSETH = "RSETH";
    string internal constant LBTC = "LBTC";
    string internal constant EBTC = "EBTC";
    string internal constant RLUSD = "RLUSD";
    string internal constant PT_EUSDE_29MAY2025 = "PT_EUSDE_29MAY2025";
    string internal constant PT_SUSDE_31JUL2025 = "PT_SUSDE_31JUL2025";
    string internal constant USDTB = "USDTB";
    string internal constant PT_USDE_31JUL2025 = "PT_USDE_31JUL2025";
    string internal constant PT_EUSDE_14AUG2025 = "PT_EUSDE_14AUG2025";
    string internal constant EUSDE = "EUSDE";
    string internal constant FBTC = "FBTC";
    string internal constant EURC = "EURC";
    string internal constant PT_SUSDE_25SEP2025 = "PT_SUSDE_25SEP2025";
    string internal constant PT_USDE_25SEP2025 = "PT_USDE_25SEP2025";
    string internal constant TETH = "TETH";
    string internal constant EZETH = "EZETH";
    string internal constant XAUT = "XAUT";
    string internal constant PT_SUSDE_27NOV2025 = "PT_SUSDE_27NOV2025";
    string internal constant PT_USDE_27NOV2025 = "PT_USDE_27NOV2025";
    string internal constant PT_USDE_5FEB2026 = "PT_USDE_5FEB2026";
    string internal constant PT_SUSDE_5FEB2026 = "PT_SUSDE_5FEB2026";
    string internal constant MUSD = "MUSD";
    string internal constant SYRUPUSDT = "SYRUPUSDT";
    string internal constant USDG = "USDG";
    string internal constant PT_USDE_7MAY2026 = "PT_USDE_7MAY2026";
    string internal constant PT_SUSDE_7MAY2026 = "PT_SUSDE_7MAY2026";
    string internal constant PT_SRUSDE_2APR2026 = "PT_SRUSDE_2APR2026";
    string internal constant USTB = "USTB";
    string internal constant USCC = "USCC";
    string internal constant USYC = "USYC";
    string internal constant JTRSY = "JTRSY";
    string internal constant JAAA = "JAAA";
    string internal constant VBILL = "VBILL";
    string internal constant YFI = "YFI";
    string internal constant ZRX = "ZRX";
    string internal constant BAT = "BAT";
    string internal constant BUSD = "BUSD";
    string internal constant ENJ = "ENJ";
    string internal constant MANA = "MANA";
    string internal constant REN = "REN";
    string internal constant SUSD = "SUSD";
    string internal constant TUSD = "TUSD";
    string internal constant GUSD = "GUSD";
    string internal constant XSUSHI = "XSUSHI";
    string internal constant RENFIL = "RENFIL";
    string internal constant RAI = "RAI";
    string internal constant AMPL = "AMPL";
    string internal constant USDP = "USDP";
    string internal constant DPI = "DPI";
    string internal constant FEI = "FEI";
    string internal constant STETH = "STETH";
    string internal constant UST = "UST";
    string internal constant CVX = "CVX";
    string internal constant GNO = "GNO";
    string internal constant SUSDS = "SUSDS";
    string internal constant PAXG = "PAXG";
    string internal constant SOLVBTC = "SOLVBTC";
    string internal constant XSOLVBTC = "XSOLVBTC";
    string internal constant PT_CORN_SOLVBTC_BBN_26DEC2024 = "PT_CORN_SOLVBTC_BBN_26DEC2024";
    string internal constant PUMPBTC = "PUMPBTC";
    string internal constant SWBTC = "SWBTC";
    string internal constant PT_CORNLBTC_26DEC2024 = "PT_CORNLBTC_26DEC2024";
    string internal constant PT_EBTC_26DEC2024 = "PT_EBTC_26DEC2024";
    string internal constant PT_LBTC_27MAR2025 = "PT_LBTC_27MAR2025";
    string internal constant PUFETH = "PUFETH";
    string internal constant USD0 = "USD0";
    string internal constant USDZ = "USDZ";
    string internal constant EUSD = "EUSD";
    string internal constant USD0_PLUS_PLUS_ = "USD0_PLUS_PLUS_";
    string internal constant PT_USD0_PLUS_PLUS__31OCT2024 = "PT_USD0_PLUS_PLUS__31OCT2024";
    string internal constant STUSD = "STUSD";
    string internal constant PT_USD0_PLUS_PLUS__27MAR2025 = "PT_USD0_PLUS_PLUS__27MAR2025";
    string internal constant SYRUPUSDC = "SYRUPUSDC";
    string internal constant STKGHO = "STKGHO";
    string internal constant PT_SUSDE_27MAR2025 = "PT_SUSDE_27MAR2025";
    string internal constant PT_USDE_27MAR2025 = "PT_USDE_27MAR2025";
    string internal constant ZAI = "ZAI";
    string internal constant SZAI = "SZAI";
    string internal constant YUSD = "YUSD";
    string internal constant SWETH = "SWETH";
    string internal constant PZETH = "PZETH";
    string internal constant PT_RSETH_26SEP2024 = "PT_RSETH_26SEP2024";
    string internal constant PT_EZETH_26DEC2024 = "PT_EZETH_26DEC2024";
    string internal constant M_BTC = "M_BTC";
    string internal constant PT_CORN_EBTC_27MAR2025 = "PT_CORN_EBTC_27MAR2025";
    string internal constant COMP = "COMP";
    string internal constant DEUSD = "DEUSD";
    string internal constant SDEUSD = "SDEUSD";
    string internal constant RSWETH = "RSWETH";
    string internal constant WOETH = "WOETH";
    string internal constant WUSDM = "WUSDM";
    string internal constant SFRAX = "SFRAX";
    string internal constant METH = "METH";
    string internal constant SKY = "SKY";
    string internal constant EIGEN = "EIGEN";
    string internal constant YVUSDC_1 = "YVUSDC_1";
    string internal constant YVUSDT_1 = "YVUSDT_1";
    string internal constant YVUSDS_1 = "YVUSDS_1";
    string internal constant YVWETH_1 = "YVWETH_1";
    string internal constant WEETHS = "WEETHS";
    string internal constant PT_WEETH_26DEC2024 = "PT_WEETH_26DEC2024";
    string internal constant SFRXETH = "SFRXETH";
    string internal constant ETH = "ETH";
    string internal constant PT_WEETH_26SEP2024 = "PT_WEETH_26SEP2024";
    string internal constant PT_PUFETH_26SEP2024 = "PT_PUFETH_26SEP2024";
    string internal constant SUUSD = "SUUSD";
    string internal constant SUETH = "SUETH";
    string internal constant SUBTC = "SUBTC";
    string internal constant PT_SUSDE_26SEP2024 = "PT_SUSDE_26SEP2024";
    string internal constant PT_RSETH_26DEC2024 = "PT_RSETH_26DEC2024";
    string internal constant PT_PUFETH_26DEC2024 = "PT_PUFETH_26DEC2024";
    string internal constant OUSG = "OUSG";
    string internal constant REP = "REP";
    string internal constant SAI = "SAI";
    string internal constant SUSHI = "SUSHI";
    string internal constant YFII = "YFII";
    string internal constant LRC = "LRC";
    string internal constant XLON = "XLON";
    string internal constant USTC = "USTC";
    string internal constant YCURVE = "YCURVE";
    string internal constant CREAM = "CREAM";
    string internal constant LEND = "LEND";
    string internal constant RENBTC = "RENBTC";
    string internal constant MTA = "MTA";
    string internal constant FTT = "FTT";
    string internal constant SRM = "SRM";
    string internal constant WNXM = "WNXM";
    string internal constant SWAG = "SWAG";
    string internal constant CEL = "CEL";
    string internal constant BBTC = "BBTC";
    string internal constant BOND = "BOND";
    string internal constant KP3R = "KP3R";
    string internal constant HBTC = "HBTC";
    string internal constant CRETH2 = "CRETH2";
    string internal constant HUSD = "HUSD";
    string internal constant HEGIC = "HEGIC";
    string internal constant ESD = "ESD";
    string internal constant COVER = "COVER";
    string internal constant OCEAN = "OCEAN";
    string internal constant OMG = "OMG";
    string internal constant UNIV2WBTCETH = "UNIV2WBTCETH";
    string internal constant UNIV2ETHUSDT = "UNIV2ETHUSDT";
    string internal constant UNIV2USDCETH = "UNIV2USDCETH";
    string internal constant UNIV2DAIETH = "UNIV2DAIETH";
    string internal constant PICKLE = "PICKLE";
    string internal constant AKRO = "AKRO";
    string internal constant BBADGER = "BBADGER";
    string internal constant OGN = "OGN";
    string internal constant AMP = "AMP";
    string internal constant RARI = "RARI";
    string internal constant ALPHA = "ALPHA";
    string internal constant FTM = "FTM";
    string internal constant RUNE = "RUNE";
    string internal constant PERP = "PERP";
    string internal constant SFI = "SFI";
    string internal constant ARMOR = "ARMOR";
    string internal constant ARNXM = "ARNXM";
    string internal constant MLN = "MLN";
    string internal constant VSP = "VSP";
    string internal constant VVSP = "VVSP";
    string internal constant SWAP = "SWAP";
    string internal constant WOO = "WOO";
    string internal constant BNT = "BNT";
    string internal constant EURT = "EURT";
    string internal constant IBBTC = "IBBTC";
    string internal constant LON = "LON";
    string internal constant YGG = "YGG";
    string internal constant AXS = "AXS";
    string internal constant SAND = "SAND";
    string internal constant MIM = "MIM";
    string internal constant RPC = "RPC";
    string internal constant WARS = "WARS";
    string internal constant DF = "DF";
    string internal constant USX = "USX";
    string internal constant EUX = "EUX";
    string internal constant SUSX = "SUSX";
    string internal constant USDC_E = "USDC_E";
    string internal constant OP = "OP";
    string internal constant MIMATIC = "MIMATIC";
    string internal constant WRSETH = "WRSETH";
    string internal constant VELO = "VELO";
    string internal constant USDT0 = "USDT0";
    string internal constant CRO = "CRO";
    string internal constant TONIC = "TONIC";
    string internal constant ATOM = "ATOM";
    string internal constant ADA = "ADA";
    string internal constant VVS = "VVS";
    string internal constant XRP = "XRP";
    string internal constant LTC = "LTC";
    string internal constant LCRO = "LCRO";
    string internal constant CDCBTC = "CDCBTC";
    string internal constant CDCETH = "CDCETH";
    string internal constant USC = "USC";
    string internal constant LATOM = "LATOM";
    string internal constant FER = "FER";
    string internal constant VNO = "VNO";
    string internal constant FUL = "FUL";
    string internal constant BCRO = "BCRO";
    string internal constant USDM = "USDM";
    string internal constant STLOS = "STLOS";
    string internal constant BTC_B = "BTC_B";
    string internal constant WTLOS = "WTLOS";
    string internal constant FXD = "FXD";
    string internal constant WXDC = "WXDC";
    string internal constant XUSDT = "XUSDT";
    string internal constant CGO = "CGO";
    string internal constant FTHM = "FTHM";
    string internal constant PSXDC = "PSXDC";
    string internal constant PRFI = "PRFI";
    string internal constant CAKE = "CAKE";
    string internal constant WBNB = "WBNB";
    string internal constant BTCB = "BTCB";
    string internal constant FDUSD = "FDUSD";
    string internal constant WBETH = "WBETH";
    string internal constant SOLVBTC_ENA = "SOLVBTC_ENA";
    string internal constant PT_SOLVBTC_BBN_27MAR2025 = "PT_SOLVBTC_BBN_27MAR2025";
    string internal constant UNIBTC = "UNIBTC";
    string internal constant SUSDX = "SUSDX";
    string internal constant USDX = "USDX";
    string internal constant XAUM = "XAUM";
    string internal constant LISTA = "LISTA";
    string internal constant SLISBNB = "SLISBNB";
    string internal constant LISUSD = "LISUSD";
    string internal constant STBTC = "STBTC";
    string internal constant PUSDT = "PUSDT";
    string internal constant PUSDC = "PUSDC";
    string internal constant PWBNB = "PWBNB";
    string internal constant PBTCB = "PBTCB";
    string internal constant PETH = "PETH";
    string internal constant STONE = "STONE";
    string internal constant XPUFETH = "XPUFETH";
    string internal constant USD1 = "USD1";
    string internal constant SXP = "SXP";
    string internal constant XVS = "XVS";
    string internal constant BNB = "BNB";
    string internal constant BCH = "BCH";
    string internal constant DOT = "DOT";
    string internal constant FIL = "FIL";
    string internal constant BETH = "BETH";
    string internal constant CAN = "CAN";
    string internal constant DOGE = "DOGE";
    string internal constant MATIC = "MATIC";
    string internal constant TRX = "TRX";
    string internal constant LUNA = "LUNA";
    string internal constant TWT = "TWT";
    string internal constant THE = "THE";
    string internal constant SOL = "SOL";
    string internal constant PT_SUSDE_26JUN2025 = "PT_SUSDE_26JUN2025";
    string internal constant ASBNB = "ASBNB";
    string internal constant PT_USDE_30OCT2025 = "PT_USDE_30OCT2025";
    string internal constant U = "U";
    string internal constant PT_CLISBNB_25JUN2026 = "PT_CLISBNB_25JUN2026";
    string internal constant ANKRBNB = "ANKRBNB";
    string internal constant BNBX = "BNBX";
    string internal constant STKBNB = "STKBNB";
    string internal constant PT_CLISBNB_24APR2025 = "PT_CLISBNB_24APR2025";
    string internal constant RACA = "RACA";
    string internal constant FLOKI = "FLOKI";
    string internal constant USDD = "USDD";
    string internal constant BABYDOGE = "BABYDOGE";
    string internal constant EURA = "EURA";
    string internal constant BTT = "BTT";
    string internal constant WIN = "WIN";
    string internal constant BSW = "BSW";
    string internal constant ALPACA = "ALPACA";
    string internal constant ANKR = "ANKR";
    string internal constant PLANET = "PLANET";
    string internal constant SATUSD = "SATUSD";
    string internal constant GAMMA = "GAMMA";
    string internal constant AQUA = "AQUA";
    string internal constant AVAX = "AVAX";
    string internal constant NULS = "NULS";
    string internal constant MASK = "MASK";
    string internal constant BAND = "BAND";
    string internal constant EOS = "EOS";
    string internal constant XTZ = "XTZ";
    string internal constant VAI = "VAI";
    string internal constant AUTO = "AUTO";
    string internal constant IOTX = "IOTX";
    string internal constant ASTER = "ASTER";
    string internal constant WXDAI = "WXDAI";
    string internal constant EURE = "EURE";
    string internal constant RTW_USD_01 = "RTW_USD_01";
    string internal constant FOX = "FOX";
    string internal constant WFUSE = "WFUSE";
    string internal constant WPOL = "WPOL";
    string internal constant GHST = "GHST";
    string internal constant EURS = "EURS";
    string internal constant JEUR = "JEUR";
    string internal constant STMATIC = "STMATIC";
    string internal constant MATICX = "MATICX";
    string internal constant STEERQV536 = "STEERQV536";
    string internal constant AUSDC_WETH = "AUSDC_WETH";
    string internal constant QUICK = "QUICK";
    string internal constant POL = "POL";
    string internal constant WMON = "WMON";
    string internal constant SMON = "SMON";
    string internal constant SHMON = "SHMON";
    string internal constant AUSD = "AUSD";
    string internal constant GMON = "GMON";
    string internal constant EARNAUSD = "EARNAUSD";
    string internal constant LOAZND = "LOAZND";
    string internal constant WS = "WS";
    string internal constant STS = "STS";
    string internal constant SUSDA = "SUSDA";
    string internal constant USDA = "USDA";
    string internal constant CUSD = "CUSD";
    string internal constant SCUSD = "SCUSD";
    string internal constant SCETH = "SCETH";
    string internal constant PT_WSTKSCUSD_29MAY2025 = "PT_WSTKSCUSD_29MAY2025";
    string internal constant YT_SCUSD = "YT_SCUSD";
    string internal constant XUSD = "XUSD";
    string internal constant EURC_E = "EURC_E";
    string internal constant WMETAUSD = "WMETAUSD";
    string internal constant ENCLABSVEUSD = "ENCLABSVEUSD";
    string internal constant ENCLABSVEETH = "ENCLABSVEETH";
    string internal constant HLP0 = "HLP0";
    string internal constant U$D = "U$D";
    string internal constant WOS = "WOS";
    string internal constant PT_SW_WSTKSCUSD_1751241607 = "PT_SW_WSTKSCUSD_1751241607";
    string internal constant PT_SW_WSTKSCETH_1751241605 = "PT_SW_WSTKSCETH_1751241605";
    string internal constant SNAKE = "SNAKE";
    string internal constant GOGLZ = "GOGLZ";
    string internal constant SWPX = "SWPX";
    string internal constant TIA = "TIA";
    string internal constant MANTA = "MANTA";
    string internal constant WOKB = "WOKB";
    string internal constant INETH = "INETH";
    string internal constant UBTC = "UBTC";
    string internal constant LZDAI = "LZDAI";
    string internal constant LZUSDC = "LZUSDC";
    string internal constant USDT_E = "USDT_E";
    string internal constant WFTM = "WFTM";
    string internal constant ZK = "ZK";
    string internal constant ONEZ = "ONEZ";
    string internal constant PEPE = "PEPE";
    string internal constant KS_LP_USDC_E_USDT = "KS_LP_USDC_E_USDT";
    string internal constant SWORD = "SWORD";
    string internal constant VC = "VC";
    string internal constant MUTE = "MUTE";
    string internal constant USN = "USN";
    string internal constant ZKETH = "ZKETH";
    string internal constant WPLS = "WPLS";
    string internal constant HEX = "HEX";
    string internal constant PLSX = "PLSX";
    string internal constant INC = "INC";
    string internal constant USDL = "USDL";
    string internal constant HEXDC = "HEXDC";
    string internal constant PXDC = "PXDC";
    string internal constant WLD = "WLD";
    string internal constant WHYPE = "WHYPE";
    string internal constant WSTHYPE = "WSTHYPE";
    string internal constant UETH = "UETH";
    string internal constant USDHL = "USDHL";
    string internal constant KHYPE = "KHYPE";
    string internal constant USR = "USR";
    string internal constant PT_KHYPE_13NOV2025 = "PT_KHYPE_13NOV2025";
    string internal constant USOL = "USOL";
    string internal constant BEHYPE = "BEHYPE";
    string internal constant USDH = "USDH";
    string internal constant PT_KHYPE_19MAR2026 = "PT_KHYPE_19MAR2026";
    string internal constant USDXL = "USDXL";
    string internal constant FEUSD = "FEUSD";
    string internal constant XAUT0 = "XAUT0";
    string internal constant THBILL = "THBILL";
    string internal constant PURR = "PURR";
    string internal constant CFX = "CFX";
    string internal constant METIS = "METIS";
    string internal constant M_USDC = "M_USDC";
    string internal constant M_USDT = "M_USDT";
    string internal constant M_WBTC = "M_WBTC";
    string internal constant COREBTC = "COREBTC";
    string internal constant WCORE = "WCORE";
    string internal constant SOLVBTC_B = "SOLVBTC_B";
    string internal constant ABTC = "ABTC";
    string internal constant SOLVBTC_M = "SOLVBTC_M";
    string internal constant STCORE = "STCORE";
    string internal constant CLND = "CLND";
    string internal constant WBITS = "WBITS";
    string internal constant SOLVBTC_CORE = "SOLVBTC_CORE";
    string internal constant OBTC = "OBTC";
    string internal constant CORE = "CORE";
    string internal constant DUALCORE = "DUALCORE";
    string internal constant GLMR = "GLMR";
    string internal constant WH_WBTC = "WH_WBTC";
    string internal constant WH_USDC = "WH_USDC";
    string internal constant XCUSDT = "XCUSDT";
    string internal constant XCUSDC = "XCUSDC";
    string internal constant D2O = "D2O";
    string internal constant IBTC = "IBTC";
    string internal constant WSEI = "WSEI";
    string internal constant ISEI = "ISEI";
    string internal constant FRXUSD = "FRXUSD";
    string internal constant SFRXUSD = "SFRXUSD";
    string internal constant FRXETH = "FRXETH";
    string internal constant FASTUSD = "FASTUSD";
    string internal constant SFASTUSD = "SFASTUSD";
    string internal constant CLO = "CLO";
    string internal constant USDY = "USDY";
    string internal constant SBTC = "SBTC";
    string internal constant SPSEI = "SPSEI";
    string internal constant ENZOBTC = "ENZOBTC";
    string internal constant FIABTC = "FIABTC";
    string internal constant ASTR = "ASTR";
    string internal constant SONE = "SONE";
    string internal constant SOLVBTC_JUP = "SOLVBTC_JUP";
    string internal constant SSUPERUSD = "SSUPERUSD";
    string internal constant WSTUSR = "WSTUSR";
    string internal constant NSASTR = "NSASTR";
    string internal constant WSTASTR = "WSTASTR";
    string internal constant WRON = "WRON";
    string internal constant WGBTC = "WGBTC";
    string internal constant DOGEB = "DOGEB";
    string internal constant BGB = "BGB";
    string internal constant MPHBTC = "MPHBTC";
    string internal constant M_ORDI = "M_ORDI";
    string internal constant MERL = "MERL";
    string internal constant ORDI = "ORDI";
    string internal constant VOYA = "VOYA";
    string internal constant HUHU = "HUHU";
    string internal constant M_SATS = "M_SATS";
    string internal constant M_RATS = "M_RATS";
    string internal constant MP = "MP";
    string internal constant ESMP = "ESMP";
    string internal constant MNER = "MNER";
    string internal constant BNBS = "BNBS";
    string internal constant MSTAR = "MSTAR";
    string internal constant SOLVBTCSLP = "SOLVBTCSLP";
    string internal constant WBTCSLP = "WBTCSLP";
    string internal constant MBTCSLP = "MBTCSLP";
    string internal constant DOGGOTOTHEMOON = "DOGGOTOTHEMOON";
    string internal constant IOUSDT = "IOUSDT";
    string internal constant WIOTX = "WIOTX";
    string internal constant IOUSDC = "IOUSDC";
    string internal constant UNIIOTX = "UNIIOTX";
    string internal constant WMNT = "WMNT";
    string internal constant CMETH = "CMETH";
    string internal constant PT_CMETH_18SEP2025 = "PT_CMETH_18SEP2025";
    string internal constant BTC_BTC = "BTC_BTC";
    string internal constant WZETA = "WZETA";
    string internal constant USDT_ETH = "USDT_ETH";
    string internal constant ETH_ETH = "ETH_ETH";
    string internal constant USDT_BSC = "USDT_BSC";
    string internal constant USDC_BSC = "USDC_BSC";
    string internal constant USDC_ETH = "USDC_ETH";
    string internal constant BNB_BSC = "BNB_BSC";
    string internal constant WKAIA = "WKAIA";
    string internal constant STKAIA = "STKAIA";
    string internal constant WGCKAIA = "WGCKAIA";
    string internal constant GRND = "GRND";
    string internal constant XGRND = "XGRND";
    string internal constant KRWO = "KRWO";
    string internal constant BORA = "BORA";
    string internal constant WKLAY = "WKLAY";
    string internal constant WAVAX = "WAVAX";
    string internal constant OUSDT = "OUSDT";
    string internal constant KSD = "KSD";
    string internal constant OUSDC = "OUSDC";
    string internal constant OETH = "OETH";
    string internal constant OWBTC = "OWBTC";
    string internal constant KDAI = "KDAI";
    string internal constant WEMIX = "WEMIX";
    string internal constant USDBC = "USDBC";
    string internal constant AERO = "AERO";
    string internal constant XUSDZ = "XUSDZ";
    string internal constant VAMM_USDCAERO = "VAMM_USDCAERO";
    string internal constant SUSDZUSDC = "SUSDZUSDC";
    string internal constant SUSDZ = "SUSDZ";
    string internal constant SUPEROETHB = "SUPEROETHB";
    string internal constant WSUPEROETHB = "WSUPEROETHB";
    string internal constant PT_CBETH_25DEC2025 = "PT_CBETH_25DEC2025";
    string internal constant PT_LBTC_29MAY2025 = "PT_LBTC_29MAY2025";
    string internal constant PT_USR_25SEP2025 = "PT_USR_25SEP2025";
    string internal constant VIRTUAL = "VIRTUAL";
    string internal constant YOETH = "YOETH";
    string internal constant YOUSD = "YOUSD";
    string internal constant PT_USDE_11DEC2025 = "PT_USDE_11DEC2025";
    string internal constant WELL = "WELL";
    string internal constant MORPHO = "MORPHO";
    string internal constant CBXRP = "CBXRP";
    string internal constant MAMO = "MAMO";
    string internal constant STEUR = "STEUR";
    string internal constant PT_USDE_15JAN2026 = "PT_USDE_15JAN2026";
    string internal constant PT_SUSDE_15JAN2026 = "PT_SUSDE_15JAN2026";
    string internal constant WXPL = "WXPL";
    string internal constant PT_SUSDE_9APR2026 = "PT_SUSDE_9APR2026";
    string internal constant PT_USDE_9APR2026 = "PT_USDE_9APR2026";
    string internal constant PLUSD = "PLUSD";
    string internal constant SPLUSD = "SPLUSD";
    string internal constant WEETH_MODE = "WEETH_MODE";
    string internal constant MODE = "MODE";
    string internal constant ARB = "ARB";
    string internal constant GMX = "GMX";
    string internal constant PLVGLP = "PLVGLP";
    string internal constant DPX = "DPX";
    string internal constant MAGIC = "MAGIC";
    string internal constant PENDLE = "PENDLE";
    string internal constant GMDUSDC = "GMDUSDC";
    string internal constant CEUR = "CEUR";
    string internal constant CELO = "CELO";
    string internal constant CREAL = "CREAL";
    string internal constant MOO = "MOO";
    string internal constant VUSD = "VUSD";
    string internal constant BRBTC = "BRBTC";
    string internal constant HEMIBTC = "HEMIBTC";
    string internal constant HEMI = "HEMI";
    string internal constant SLP = "SLP";
    string internal constant BFBTC = "BFBTC";
    string internal constant SAVAX = "SAVAX";
    string internal constant CRV_E = "CRV_E";
    string internal constant JOE = "JOE";
    string internal constant WXT = "WXT";
    string internal constant XAVA = "XAVA";
    string internal constant QI = "QI";
    string internal constant COQ = "COQ";
    string internal constant NXPC = "NXPC";
    string internal constant BRIDGED_MSTETH = "BRIDGED_MSTETH";
    string internal constant BRIDGED_EGETH = "BRIDGED_EGETH";
    string internal constant ZRC = "ZRC";
    string internal constant GRAI = "GRAI";
    string internal constant UNIETH = "UNIETH";
    string internal constant AXLFRXETH = "AXLFRXETH";
    string internal constant LYU = "LYU";
    string internal constant CROAK = "CROAK";
    string internal constant FOXY = "FOXY";
    string internal constant SOLVBTC_BABYLON = "SOLVBTC_BABYLON";
    string internal constant SOV = "SOV";
    string internal constant THUSD = "THUSD";
    string internal constant S1 = "S1";
    string internal constant SATOSHI_STABLECOIN_V2 = "SATOSHI_STABLECOIN_V2";
    string internal constant HONEY = "HONEY";
    string internal constant IBGT = "IBGT";
    string internal constant NECT = "NECT";
    string internal constant WBERA = "WBERA";
    string internal constant BERA = "BERA";
    string internal constant USDB = "USDB";
    string internal constant FWWETH = "FWWETH";
    string internal constant FWUSDB = "FWUSDB";
    string internal constant RING_V2 = "RING_V2";
    string internal constant OUSDB = "OUSDB";
    string internal constant SLP_USDB = "SLP_USDB";
    string internal constant SLP_WETH = "SLP_WETH";
    string internal constant T_LP = "T_LP";
    string internal constant DETH = "DETH";
    string internal constant DUSD = "DUSD";
    string internal constant BLAST = "BLAST";
    string internal constant YES = "YES";
    string internal constant TAIKO = "TAIKO";
    string internal constant BITUSD = "BITUSD";
    string internal constant BCLP_STBTC_WBTC = "BCLP_STBTC_WBTC";
    string internal constant STABLE_LP = "STABLE_LP";
    string internal constant BTC = "BTC";
    string internal constant SCR = "SCR";
    string internal constant VBWBTC = "VBWBTC";
    string internal constant VBETH = "VBETH";
    string internal constant YVVBUSDC = "YVVBUSDC";
    string internal constant YVVBUSDT = "YVVBUSDT";
    string internal constant YVVBETH = "YVVBETH";
    string internal constant YVVBWBTC = "YVVBWBTC";
    string internal constant WBTCN = "WBTCN";
    string internal constant WNEON = "WNEON";
    string internal constant JITOSOL = "JITOSOL";
    string internal constant ONE_DAI = "ONE_DAI";
    string internal constant ONE_WBTC = "ONE_WBTC";
    string internal constant ONE_ETH = "ONE_ETH";
    string internal constant ONE_USDT = "ONE_USDT";
    string internal constant ONE_AAVE = "ONE_AAVE";
    string internal constant WONE = "WONE";
}

library Lenders {
    string internal constant AAVE_V3 = "AAVE_V3";
    string internal constant AAVE_V3_PRIME = "AAVE_V3_PRIME";
    string internal constant AAVE_V3_ETHER_FI = "AAVE_V3_ETHER_FI";
    string internal constant AAVE_V3_HORIZON = "AAVE_V3_HORIZON";
    string internal constant AAVE_V2 = "AAVE_V2";
    string internal constant LENDLE = "LENDLE";
    string internal constant LENDLE_CMETH = "LENDLE_CMETH";
    string internal constant LENDLE_SUSDE = "LENDLE_SUSDE";
    string internal constant LENDLE_SUSDE_USDT = "LENDLE_SUSDE_USDT";
    string internal constant LENDLE_METH_WETH = "LENDLE_METH_WETH";
    string internal constant LENDLE_METH_USDE = "LENDLE_METH_USDE";
    string internal constant LENDLE_CMETH_WETH = "LENDLE_CMETH_WETH";
    string internal constant LENDLE_CMETH_USDE = "LENDLE_CMETH_USDE";
    string internal constant LENDLE_CMETH_WMNT = "LENDLE_CMETH_WMNT";
    string internal constant LENDLE_FBTC_WETH = "LENDLE_FBTC_WETH";
    string internal constant LENDLE_FBTC_USDE = "LENDLE_FBTC_USDE";
    string internal constant LENDLE_FBTC_WMNT = "LENDLE_FBTC_WMNT";
    string internal constant LENDLE_WMNT_WETH = "LENDLE_WMNT_WETH";
    string internal constant LENDLE_WMNT_USDE = "LENDLE_WMNT_USDE";
    string internal constant LENDLE_PT_CMETH = "LENDLE_PT_CMETH";
    string internal constant HANA = "HANA";
    string internal constant AURELIUS = "AURELIUS";
    string internal constant TAKOTAKO = "TAKOTAKO";
    string internal constant TAKOTAKO_ETH = "TAKOTAKO_ETH";
    string internal constant QUOKKA_LEND = "QUOKKA_LEND";
    string internal constant MERIDIAN = "MERIDIAN";
    string internal constant SPARK = "SPARK";
    string internal constant RHOMBUS = "RHOMBUS";
    string internal constant KLAP = "KLAP";
    string internal constant RMM = "RMM";
    string internal constant SAKE = "SAKE";
    string internal constant SAKE_ASTAR = "SAKE_ASTAR";
    string internal constant LAYERBANK_V3 = "LAYERBANK_V3";
    string internal constant COLEND = "COLEND";
    string internal constant COLEND_LSTBTC = "COLEND_LSTBTC";
    string internal constant PAC = "PAC";
    string internal constant HYPERLEND = "HYPERLEND";
    string internal constant HYPURRFI = "HYPURRFI";
    string internal constant HYPERYIELD = "HYPERYIELD";
    string internal constant RADIANT_V2 = "RADIANT_V2";
    string internal constant AVALON_SOLVBTC = "AVALON_SOLVBTC";
    string internal constant AVALON_PUMPBTC = "AVALON_PUMPBTC";
    string internal constant AVALON_SWELLBTC = "AVALON_SWELLBTC";
    string internal constant AVALON_EBTC_LBTC = "AVALON_EBTC_LBTC";
    string internal constant AVALON_UNIBTC = "AVALON_UNIBTC";
    string internal constant AVALON = "AVALON";
    string internal constant AVALON_USDA = "AVALON_USDA";
    string internal constant AVALON_SKAIA = "AVALON_SKAIA";
    string internal constant AVALON_USDX = "AVALON_USDX";
    string internal constant AVALON_XAUM = "AVALON_XAUM";
    string internal constant AVALON_LBTC = "AVALON_LBTC";
    string internal constant AVALON_WBTC = "AVALON_WBTC";
    string internal constant AVALON_LISTA = "AVALON_LISTA";
    string internal constant AVALON_STBTC = "AVALON_STBTC";
    string internal constant AVALON_UNIIOTX = "AVALON_UNIIOTX";
    string internal constant AVALON_BOB = "AVALON_BOB";
    string internal constant AVALON_OBTC = "AVALON_OBTC";
    string internal constant AVALON_UBTC = "AVALON_UBTC";
    string internal constant AVALON_LORENZO = "AVALON_LORENZO";
    string internal constant AVALON_BEETS = "AVALON_BEETS";
    string internal constant AVALON_INNOVATION = "AVALON_INNOVATION";
    string internal constant MOONCAKE = "MOONCAKE";
    string internal constant NEREUS = "NEREUS";
    string internal constant KINZA = "KINZA";
    string internal constant ZEROLEND_STABLECOINS_RWA = "ZEROLEND_STABLECOINS_RWA";
    string internal constant ZEROLEND_ETH_LRTS = "ZEROLEND_ETH_LRTS";
    string internal constant ZEROLEND_BTC_LRTS = "ZEROLEND_BTC_LRTS";
    string internal constant ZEROLEND = "ZEROLEND";
    string internal constant ZEROLEND_CROAK = "ZEROLEND_CROAK";
    string internal constant ZEROLEND_FOXY = "ZEROLEND_FOXY";
    string internal constant GRANARY = "GRANARY";
    string internal constant LORE = "LORE";
    string internal constant LENDOS = "LENDOS";
    string internal constant YLDR = "YLDR";
    string internal constant IRONCLAD = "IRONCLAD";
    string internal constant MOLEND = "MOLEND";
    string internal constant SEISMIC = "SEISMIC";
    string internal constant POLTER = "POLTER";
    string internal constant MAGSIN = "MAGSIN";
    string internal constant AGAVE = "AGAVE";
    string internal constant MOOLA = "MOOLA";
    string internal constant XLEND = "XLEND";
    string internal constant KLAYBANK = "KLAYBANK";
    string internal constant VALAS = "VALAS";
    string internal constant PHIAT = "PHIAT";
    string internal constant FATHOM = "FATHOM";
    string internal constant PRIME_FI = "PRIME_FI";
    string internal constant U235 = "U235";
    string internal constant PLUTOS = "PLUTOS";
    string internal constant YEI = "YEI";
    string internal constant YEI_SOLV = "YEI_SOLV";
    string internal constant NEVERLAND = "NEVERLAND";
    string internal constant COMPOUND_V3_USDC = "COMPOUND_V3_USDC";
    string internal constant COMPOUND_V3_WETH = "COMPOUND_V3_WETH";
    string internal constant COMPOUND_V3_USDT = "COMPOUND_V3_USDT";
    string internal constant COMPOUND_V3_WSTETH = "COMPOUND_V3_WSTETH";
    string internal constant COMPOUND_V3_USDS = "COMPOUND_V3_USDS";
    string internal constant COMPOUND_V3_WBTC = "COMPOUND_V3_WBTC";
    string internal constant COMPOUND_V3_USDCE = "COMPOUND_V3_USDCE";
    string internal constant COMPOUND_V3_WRON = "COMPOUND_V3_WRON";
    string internal constant COMPOUND_V3_USDE = "COMPOUND_V3_USDE";
    string internal constant COMPOUND_V3_USDBC = "COMPOUND_V3_USDBC";
    string internal constant COMPOUND_V3_AERO = "COMPOUND_V3_AERO";
    string internal constant VENUS = "VENUS";
    string internal constant VENUS_ETH = "VENUS_ETH";
    string internal constant VENUS_BTC = "VENUS_BTC";
    string internal constant VENUS_BNB = "VENUS_BNB";
    string internal constant VENUS_GAMEFI = "VENUS_GAMEFI";
    string internal constant VENUS_MEME = "VENUS_MEME";
    string internal constant VENUS_STABLE = "VENUS_STABLE";
    string internal constant VENUS_TRON = "VENUS_TRON";
    string internal constant VENUS_ETHENA = "VENUS_ETHENA";
    string internal constant VENUS_DEFI = "VENUS_DEFI";
    string internal constant VENUS_CURVE = "VENUS_CURVE";
    string internal constant ENCLABS = "ENCLABS";
    string internal constant ENCLABS_LST = "ENCLABS_LST";
    string internal constant ENCLABS_PT_ETH = "ENCLABS_PT_ETH";
    string internal constant ENCLABS_PT_USD = "ENCLABS_PT_USD";
    string internal constant ENCLABS_SONIC_ECO = "ENCLABS_SONIC_ECO";
    string internal constant SEGMENT = "SEGMENT";
    string internal constant BENQI = "BENQI";
    string internal constant BENQI_AVALANCE_ECOSYSTEM = "BENQI_AVALANCE_ECOSYSTEM";
    string internal constant MOONWELL = "MOONWELL";
    string internal constant ORBITER_ONE = "ORBITER_ONE";
    string internal constant LODESTAR = "LODESTAR";
    string internal constant SUMER = "SUMER";
    string internal constant TAKARA = "TAKARA";
    string internal constant TECTONIC = "TECTONIC";
    string internal constant TECTONIC_DEFI = "TECTONIC_DEFI";
    string internal constant TECTONIC_VENO = "TECTONIC_VENO";
    string internal constant TENDER = "TENDER";
    string internal constant GAMMA = "GAMMA";
    string internal constant FLUX_FINANCE = "FLUX_FINANCE";
    string internal constant COMPOUND_V2 = "COMPOUND_V2";
    string internal constant WE_PIGGY = "WE_PIGGY";
    string internal constant CREAM_FINANCE = "CREAM_FINANCE";
    string internal constant CAPY_FI = "CAPY_FI";
    string internal constant UNITUS = "UNITUS";

    function isAave(string memory lender) internal pure returns (bool isAaveFlag) {
        bytes32 _lender = keccak256(abi.encodePacked((lender)));
        isAaveFlag = _lender == keccak256(abi.encodePacked((AAVE_V3))) || _lender == keccak256(abi.encodePacked((AAVE_V3_PRIME)))
            || _lender == keccak256(abi.encodePacked((AAVE_V3_ETHER_FI)))
            || _lender == keccak256(abi.encodePacked((AAVE_V3_HORIZON))) || _lender == keccak256(abi.encodePacked((AAVE_V2)))
            || _lender == keccak256(abi.encodePacked((LENDLE))) || _lender == keccak256(abi.encodePacked((LENDLE_CMETH)))
            || _lender == keccak256(abi.encodePacked((LENDLE_SUSDE)))
            || _lender == keccak256(abi.encodePacked((LENDLE_SUSDE_USDT)))
            || _lender == keccak256(abi.encodePacked((LENDLE_METH_WETH)))
            || _lender == keccak256(abi.encodePacked((LENDLE_METH_USDE)))
            || _lender == keccak256(abi.encodePacked((LENDLE_CMETH_WETH)))
            || _lender == keccak256(abi.encodePacked((LENDLE_CMETH_USDE)))
            || _lender == keccak256(abi.encodePacked((LENDLE_CMETH_WMNT)))
            || _lender == keccak256(abi.encodePacked((LENDLE_FBTC_WETH)))
            || _lender == keccak256(abi.encodePacked((LENDLE_FBTC_USDE)))
            || _lender == keccak256(abi.encodePacked((LENDLE_FBTC_WMNT)))
            || _lender == keccak256(abi.encodePacked((LENDLE_WMNT_WETH)))
            || _lender == keccak256(abi.encodePacked((LENDLE_WMNT_USDE)))
            || _lender == keccak256(abi.encodePacked((LENDLE_PT_CMETH))) || _lender == keccak256(abi.encodePacked((HANA)))
            || _lender == keccak256(abi.encodePacked((AURELIUS))) || _lender == keccak256(abi.encodePacked((TAKOTAKO)))
            || _lender == keccak256(abi.encodePacked((TAKOTAKO_ETH))) || _lender == keccak256(abi.encodePacked((QUOKKA_LEND)))
            || _lender == keccak256(abi.encodePacked((MERIDIAN))) || _lender == keccak256(abi.encodePacked((SPARK)))
            || _lender == keccak256(abi.encodePacked((RHOMBUS))) || _lender == keccak256(abi.encodePacked((KLAP)))
            || _lender == keccak256(abi.encodePacked((RMM))) || _lender == keccak256(abi.encodePacked((SAKE)))
            || _lender == keccak256(abi.encodePacked((SAKE_ASTAR))) || _lender == keccak256(abi.encodePacked((LAYERBANK_V3)))
            || _lender == keccak256(abi.encodePacked((COLEND))) || _lender == keccak256(abi.encodePacked((COLEND_LSTBTC)))
            || _lender == keccak256(abi.encodePacked((PAC))) || _lender == keccak256(abi.encodePacked((HYPERLEND)))
            || _lender == keccak256(abi.encodePacked((HYPURRFI))) || _lender == keccak256(abi.encodePacked((HYPERYIELD)))
            || _lender == keccak256(abi.encodePacked((RADIANT_V2))) || _lender == keccak256(abi.encodePacked((AVALON_SOLVBTC)))
            || _lender == keccak256(abi.encodePacked((AVALON_PUMPBTC)))
            || _lender == keccak256(abi.encodePacked((AVALON_SWELLBTC)))
            || _lender == keccak256(abi.encodePacked((AVALON_EBTC_LBTC)))
            || _lender == keccak256(abi.encodePacked((AVALON_UNIBTC))) || _lender == keccak256(abi.encodePacked((AVALON)))
            || _lender == keccak256(abi.encodePacked((AVALON_USDA))) || _lender == keccak256(abi.encodePacked((AVALON_SKAIA)))
            || _lender == keccak256(abi.encodePacked((AVALON_USDX))) || _lender == keccak256(abi.encodePacked((AVALON_XAUM)))
            || _lender == keccak256(abi.encodePacked((AVALON_LBTC))) || _lender == keccak256(abi.encodePacked((AVALON_WBTC)))
            || _lender == keccak256(abi.encodePacked((AVALON_LISTA))) || _lender == keccak256(abi.encodePacked((AVALON_STBTC)))
            || _lender == keccak256(abi.encodePacked((AVALON_UNIIOTX))) || _lender == keccak256(abi.encodePacked((AVALON_BOB)))
            || _lender == keccak256(abi.encodePacked((AVALON_OBTC))) || _lender == keccak256(abi.encodePacked((AVALON_UBTC)))
            || _lender == keccak256(abi.encodePacked((AVALON_LORENZO))) || _lender == keccak256(abi.encodePacked((AVALON_BEETS)))
            || _lender == keccak256(abi.encodePacked((AVALON_INNOVATION))) || _lender == keccak256(abi.encodePacked((MOONCAKE)))
            || _lender == keccak256(abi.encodePacked((NEREUS))) || _lender == keccak256(abi.encodePacked((KINZA)))
            || _lender == keccak256(abi.encodePacked((ZEROLEND_STABLECOINS_RWA)))
            || _lender == keccak256(abi.encodePacked((ZEROLEND_ETH_LRTS)))
            || _lender == keccak256(abi.encodePacked((ZEROLEND_BTC_LRTS))) || _lender == keccak256(abi.encodePacked((ZEROLEND)))
            || _lender == keccak256(abi.encodePacked((ZEROLEND_CROAK))) || _lender == keccak256(abi.encodePacked((ZEROLEND_FOXY)))
            || _lender == keccak256(abi.encodePacked((GRANARY))) || _lender == keccak256(abi.encodePacked((LORE)))
            || _lender == keccak256(abi.encodePacked((LENDOS))) || _lender == keccak256(abi.encodePacked((YLDR)))
            || _lender == keccak256(abi.encodePacked((IRONCLAD))) || _lender == keccak256(abi.encodePacked((MOLEND)))
            || _lender == keccak256(abi.encodePacked((SEISMIC))) || _lender == keccak256(abi.encodePacked((POLTER)))
            || _lender == keccak256(abi.encodePacked((MAGSIN))) || _lender == keccak256(abi.encodePacked((AGAVE)))
            || _lender == keccak256(abi.encodePacked((MOOLA))) || _lender == keccak256(abi.encodePacked((XLEND)))
            || _lender == keccak256(abi.encodePacked((KLAYBANK))) || _lender == keccak256(abi.encodePacked((VALAS)))
            || _lender == keccak256(abi.encodePacked((PHIAT))) || _lender == keccak256(abi.encodePacked((FATHOM)))
            || _lender == keccak256(abi.encodePacked((PRIME_FI))) || _lender == keccak256(abi.encodePacked((U235)))
            || _lender == keccak256(abi.encodePacked((PLUTOS))) || _lender == keccak256(abi.encodePacked((YEI)))
            || _lender == keccak256(abi.encodePacked((YEI_SOLV))) || _lender == keccak256(abi.encodePacked((NEVERLAND)));
    }

    function isCompoundV3(string memory lender) internal pure returns (bool isCompoundV3Flag) {
        bytes32 _lender = keccak256(abi.encodePacked((lender)));
        isCompoundV3Flag = _lender == keccak256(abi.encodePacked((COMPOUND_V3_USDC)))
            || _lender == keccak256(abi.encodePacked((COMPOUND_V3_WETH)))
            || _lender == keccak256(abi.encodePacked((COMPOUND_V3_USDT)))
            || _lender == keccak256(abi.encodePacked((COMPOUND_V3_WSTETH)))
            || _lender == keccak256(abi.encodePacked((COMPOUND_V3_USDS)))
            || _lender == keccak256(abi.encodePacked((COMPOUND_V3_WBTC)))
            || _lender == keccak256(abi.encodePacked((COMPOUND_V3_USDCE)))
            || _lender == keccak256(abi.encodePacked((COMPOUND_V3_WRON)))
            || _lender == keccak256(abi.encodePacked((COMPOUND_V3_USDE)))
            || _lender == keccak256(abi.encodePacked((COMPOUND_V3_USDBC)))
            || _lender == keccak256(abi.encodePacked((COMPOUND_V3_AERO)));
    }

    function isCompoundV2(string memory lender) internal pure returns (bool isCompoundV2Flag) {
        bytes32 _lender = keccak256(abi.encodePacked((lender)));
        isCompoundV2Flag = _lender == keccak256(abi.encodePacked((VENUS))) || _lender == keccak256(abi.encodePacked((VENUS_ETH)))
            || _lender == keccak256(abi.encodePacked((VENUS_BTC))) || _lender == keccak256(abi.encodePacked((VENUS_BNB)))
            || _lender == keccak256(abi.encodePacked((VENUS_GAMEFI))) || _lender == keccak256(abi.encodePacked((VENUS_MEME)))
            || _lender == keccak256(abi.encodePacked((VENUS_STABLE))) || _lender == keccak256(abi.encodePacked((VENUS_TRON)))
            || _lender == keccak256(abi.encodePacked((VENUS_ETHENA))) || _lender == keccak256(abi.encodePacked((VENUS_DEFI)))
            || _lender == keccak256(abi.encodePacked((VENUS_CURVE))) || _lender == keccak256(abi.encodePacked((ENCLABS)))
            || _lender == keccak256(abi.encodePacked((ENCLABS_LST))) || _lender == keccak256(abi.encodePacked((ENCLABS_PT_ETH)))
            || _lender == keccak256(abi.encodePacked((ENCLABS_PT_USD)))
            || _lender == keccak256(abi.encodePacked((ENCLABS_SONIC_ECO))) || _lender == keccak256(abi.encodePacked((SEGMENT)))
            || _lender == keccak256(abi.encodePacked((BENQI)))
            || _lender == keccak256(abi.encodePacked((BENQI_AVALANCE_ECOSYSTEM)))
            || _lender == keccak256(abi.encodePacked((MOONWELL))) || _lender == keccak256(abi.encodePacked((ORBITER_ONE)))
            || _lender == keccak256(abi.encodePacked((LODESTAR))) || _lender == keccak256(abi.encodePacked((SUMER)))
            || _lender == keccak256(abi.encodePacked((TAKARA))) || _lender == keccak256(abi.encodePacked((TECTONIC)))
            || _lender == keccak256(abi.encodePacked((TECTONIC_DEFI))) || _lender == keccak256(abi.encodePacked((TECTONIC_VENO)))
            || _lender == keccak256(abi.encodePacked((TENDER))) || _lender == keccak256(abi.encodePacked((GAMMA)))
            || _lender == keccak256(abi.encodePacked((FLUX_FINANCE))) || _lender == keccak256(abi.encodePacked((COMPOUND_V2)))
            || _lender == keccak256(abi.encodePacked((WE_PIGGY))) || _lender == keccak256(abi.encodePacked((CREAM_FINANCE)))
            || _lender == keccak256(abi.encodePacked((CAPY_FI))) || _lender == keccak256(abi.encodePacked((UNITUS)));
    }
}
