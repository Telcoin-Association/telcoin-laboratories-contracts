import * as dotenv from "dotenv";

import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

dotenv.config();

/** @type import('hardhat/config').HardhatUserConfig */
const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {},
    ethereum: {
      url: "https://eth-mainnet.alchemyapi.io/v2/" + process.env.ALCHEMY_API_KEY,
      accounts: [process.env.CONTROL_KEY!]
    },
    polygon: {
      url: "https://polygon-mainnet.g.alchemy.com/v2/" + process.env.ALCHEMY_API_KEY,
      // url: "https://polygon-rpc.com",
      accounts: [process.env.GOVERNANCE_KEY!]
    },
    base: {
      url: "https://base-mainnet.g.alchemy.com/v2/" + process.env.ALCHEMY_API_KEY,
      accounts: [process.env.GOVERNANCE_KEY!]
    },
    sepolia: {
      url: "https://eth-sepolia.g.alchemy.com/v2/" + process.env.SEPOLIA_API_KEY,
      accounts: [process.env.CONTROL_KEY!]
    },
    amoy: {
      url: "https://polygon-amoy.g.alchemy.com/v2/" + process.env.AMOY_API_KEY,
      accounts: [process.env.CONTROL_KEY!]
    },
    telcoin: {
      url: "http://35.188.45.1:8544/",
      accounts: [process.env.CONTROL_KEY!]
    },
    research: {
      url: process.env.RESEARCH_API_URL,
      accounts: [process.env.RESEARCH_KEY_A!, process.env.RESEARCH_KEY_B!]
    },
    tenderly: {
      // chainId: 1,
      chainId: 137,
      // chainId: 11155111,
      url: process.env.TENDERLY_FORK_ID,
      accounts: [process.env.GOVERNANCE_KEY!]
    }
  },
  solidity: {
    compilers: [
      {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.6.6",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      }
    ]
  },
  paths: {
    artifacts: "./artifacts",
    cache: "./cache",
    sources: "./contracts",
    tests: "./test",
  },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY || "",
      polygon: process.env.POLYGONSCAN_API_KEY || "",
      sepolia: process.env.ETHERSCAN_API_KEY || "",
      amoy: process.env.POLYGONSCAN_API_KEY || ""
    }
  },
  sourcify: {
    enabled: false
  }
};

export default config;


// import type { HardhatUserConfig } from "hardhat/config";
// import "@nomicfoundation/hardhat-toolbox";

// /** @type import('hardhat/config').HardhatUserConfig */
// const config: HardhatUserConfig = {
//   defaultNetwork: "hardhat",
//   networks: {
//     hardhat: {}
//   },
//   solidity: {
//     version: "0.8.24",
//     settings: {
//       optimizer: {
//         enabled: true,
//         runs: 200
//       }
//     }
//   },
//   paths: {
//     artifacts: "./artifacts",
//     cache: "./cache",
//     sources: "./contracts",
//     tests: "./test",
//   }
// };

// export default config;