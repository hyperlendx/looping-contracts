require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-foundry");

const mnemonic = process.env.MNEMONIC;

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: {
        version:"0.8.24",
        settings: {
            viaIR: true,
        },
    },
    networks: {
        hardhat: {
            gas: "auto",
            accounts: {
                mnemonic,
            },
            chainId: 1337,
        },
        hyperEvmTestnet: {
            accounts: {
                mnemonic,
            },
            chainId: 998,
            url: 'https://rpc.hyperliquid-testnet.xyz/evm',
        },
        hyperEvm: {
            accounts: [process.env.PRIVATE_KEY_MAINNET || process.env.PRIVATE_KEY],
            chainId: 999,
            url: 'https://rpc.hyperliquid.xyz/evm',
        }
    },
    etherscan: {
        apiKey: {
            hyperEvmTestnet: "empty",
            hyperEvm: "empty"
        },
        customChains: [
            {
                network: "hyperEvmTestnet",
                chainId: 998,
                urls: {
                    apiURL: "https://explorer.hyperlend.finance/api",
                    browserURL: "https://explorer.hyperlend.finance"
                }
            },
            {
                network: "hyperEvm",
                chainId: 999,
                urls: {
                    apiURL: "https://hyperliquid.cloud.blockscout.com/api",
                    browserURL: "https://hyperliquid.cloud.blockscout.com"
                }
            }
        ]
    },
    sourcify: {
        enabled: true,
        apiUrl: "https://sourcify.parsec.finance",
        browserUrl: "https://purrsec.com/",
    }
};
