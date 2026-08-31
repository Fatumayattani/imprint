import { http } from "wagmi";
import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { defineChain, type Address } from "viem";

export const unichainSepolia = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: {
    name: "Unichain Sepolia Ether",
    symbol: "ETH",
    decimals: 18,
  },
  rpcUrls: {
    default: {
      http: ["https://sepolia.unichain.org"],
    },
  },
  blockExplorers: {
    default: {
      name: "Blockscout",
      url: "https://unichain-sepolia.blockscout.com",
    },
  },
  testnet: true,
});

export const contracts = {
  poolManager:
    "0x00B036B58a818B1BC34d502D3fE730Db729e62AC" as Address,
  positionManager:
    "0xf969Aee60879C54bAAed9F3eD26147Db216Fd664" as Address,
  stateView:
    "0xc199f1072a74d4e905aba1a84d9a45e2546b6222" as Address,
  protectedRouter:
    "0xA00B6237abE4606F9b20b57B67A82B5591F0667c" as Address,
  hook: "0x58e9eB947696c4EA9A80E65e901162E9BE3E00C0" as Address,
  usdc: "0x31d0220469e10c4E71834a79b1f276d740d3768F" as Address,
  weth: "0x4200000000000000000000000000000000000006" as Address,
} as const;

export const imprintPoolKey = {
  currency0: contracts.usdc,
  currency1: contracts.weth,
  fee: 3000,
  tickSpacing: 60,
  hooks: contracts.hook,
} as const;

export const deployment = {
  poolId:
    "0xd5519a432b0a3bbb56ddf4b80b11488a7c49966138cad8618bed527d74af9a76",
  positionTokenId: 7867n,
  liquidity: 189736659610n,
  initialTick: 193379,
} as const;

const reownProjectId = import.meta.env.VITE_REOWN_PROJECT_ID;

if (!reownProjectId) {
  throw new Error("Missing VITE_REOWN_PROJECT_ID");
}

export const wagmiConfig = getDefaultConfig({
  appName: "Imprint",
  projectId: reownProjectId,
  chains: [unichainSepolia],
  transports: {
    [unichainSepolia.id]: http(),
  },
});