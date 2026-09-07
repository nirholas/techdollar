import { defineChain } from "viem";

/**
 * Robinhood Chain, where the collateral lives.
 *
 * An Arbitrum Orbit rollup that settles in ETH, with 254 tokenized equities behind one shared
 * `Stock` implementation. Verified against the live chain rather than copied from a directory.
 */
export const robinhoodChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.chain.robinhood.com"] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" },
  },
  contracts: {
    multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" },
  },
});

export const robinhoodChainTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain Testnet",
  testnet: true,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.testnet.chain.robinhood.com"] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://robinhoodchain-testnet.blockscout.com" },
  },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

/**
 * Public endpoints, official first. Every one of them rate-limits, and a keeper that polls should
 * rotate rather than hammer one.
 */
export const PUBLIC_RPC_URLS: readonly string[] = [
  "https://rpc.mainnet.chain.robinhood.com",
  "https://robinhood.drpc.org",
  "https://robinhood-rpc.publicnode.com",
];

/** USDG, the dollar the peg module holds in reserve. Six decimals, verified on chain. */
export const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168" as const;
export const USDG_DECIMALS = 6;
