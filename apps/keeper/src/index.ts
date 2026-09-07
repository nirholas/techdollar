#!/usr/bin/env node
import { parseArgs } from "node:util";
import { readFileSync, existsSync } from "node:fs";
import { createPublicClient, createWalletClient, http, parseAbiItem, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  PUBLIC_RPC_URLS,
  TechDollarClient,
  WAD,
  liquidationauctionAbi,
  robinhoodChain,
  vaultengineAbi,
  type Deployment,
} from "@techdollar/sdk";

import { DEFAULT_POLICY, plan, type Action, type KeeperPolicy } from "./planner.js";

/**
 * The keeper.
 *
 * It flags positions that go unsafe, liquidates the ones it can, bids into auctions that pay, and
 * restarts auctions that fell to their floor. It reports and does nothing else when a collateral is
 * halted, because during a halt there is nothing else that can be done: the collateral cannot move.
 *
 * Reports by default. `--execute` is what makes it send transactions.
 */

const USAGE = `techdollar-keeper - watch positions and auctions

  techdollar-keeper --deployment deployments/robinhood.json [--once] [--execute]

  --deployment <file>   addresses written by the deploy script
  --owners <file>       newline separated addresses to watch, in addition to discovered ones
  --from-block <n>      block to discover positions from (default: 0)
  --interval <seconds>  poll interval, default 30
  --once                one pass and exit
  --execute             send transactions; without it the keeper only reports
  --min-profit-bps <n>  do not bid under this discount to market, default 100
  --max-bid <techd>     most to spend on one bid, default 250000
  --rpc <url>           RPC endpoint (default: the public Robinhood Chain endpoints)
  --key <hex>           private key (or TECHDOLLAR_KEEPER_KEY)
`;

function log(event: string, fields: Record<string, unknown> = {}): void {
  const parts = Object.entries(fields).map(([k, v]) => `${k}=${typeof v === "bigint" ? v.toString() : v}`);
  console.log(`${new Date().toISOString()} ${event} ${parts.join(" ")}`.trimEnd());
}

/**
 * Positions are discovered from the engine's own events. There is no registry of borrowers on
 * chain, and there should not be: a keeper that needs one is a keeper that misses whoever is not
 * in it.
 */
async function discoverOwners(
  client: TechDollarClient,
  engine: Address,
  fromBlock: bigint,
): Promise<Map<string, Set<string>>> {
  const logs = await client.publicClient.getLogs({
    address: engine,
    event: parseAbiItem("event Mint(address indexed collateral, address indexed owner, address to, uint256 amount)"),
    fromBlock,
    toBlock: "latest",
  });
  const byCollateral = new Map<string, Set<string>>();
  for (const entry of logs) {
    const collateral = (entry.args.collateral as Address).toLowerCase();
    const owner = (entry.args.owner as Address).toLowerCase();
    if (!byCollateral.has(collateral)) byCollateral.set(collateral, new Set());
    byCollateral.get(collateral)!.add(owner);
  }
  return byCollateral;
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      deployment: { type: "string" },
      owners: { type: "string" },
      "from-block": { type: "string" },
      interval: { type: "string" },
      once: { type: "boolean" },
      execute: { type: "boolean" },
      "min-profit-bps": { type: "string" },
      "max-bid": { type: "string" },
      rpc: { type: "string" },
      key: { type: "string" },
      help: { type: "boolean" },
    },
  });
  if (values.help || !values.deployment) {
    console.log(USAGE);
    if (!values.deployment) process.exitCode = 1;
    return;
  }
  if (!existsSync(values.deployment)) throw new Error(`No deployment file at ${values.deployment}`);
  const deployment = JSON.parse(readFileSync(values.deployment, "utf8")) as Deployment;

  const transport = http(values.rpc ?? PUBLIC_RPC_URLS[0]);
  const publicClient = createPublicClient({ chain: robinhoodChain, transport, batch: { multicall: true } });
  const client = new TechDollarClient(deployment, publicClient);

  const keyRaw = values.key ?? process.env.TECHDOLLAR_KEEPER_KEY;
  const account = keyRaw ? privateKeyToAccount(keyRaw as `0x${string}`) : null;
  const wallet = account ? createWalletClient({ account, chain: robinhoodChain, transport }) : null;
  const execute = values.execute === true;
  if (execute && !wallet) throw new Error("--execute needs a key: pass --key or set TECHDOLLAR_KEEPER_KEY");

  const policy: KeeperPolicy = {
    ...DEFAULT_POLICY,
    minProfitBps: Number(values["min-profit-bps"] ?? DEFAULT_POLICY.minProfitBps),
    maxBidSize: BigInt(values["max-bid"] ?? "250000") * WAD,
  };
  const fromBlock = BigInt(values["from-block"] ?? "0");
  const extraOwners = values.owners
    ? readFileSync(values.owners, "utf8").split("\n").map((line) => line.trim()).filter(Boolean)
    : [];

  log("keeper.start", {
    engine: deployment.engine,
    execute,
    signer: account?.address ?? "none",
    minProfitBps: policy.minProfitBps,
  });

  for (;;) {
    try {
      await pass();
    } catch (error) {
      log("pass.failed", { error: error instanceof Error ? error.message : String(error) });
    }
    if (values.once) return;
    await new Promise((resolve) => setTimeout(resolve, Number(values.interval ?? 30) * 1_000));
  }

  async function pass(): Promise<void> {
    const collaterals = await client.collaterals();
    const discovered = await discoverOwners(client, deployment.engine, fromBlock);
    const now = BigInt(Math.floor(Date.now() / 1000));

    const positions = [];
    for (const collateral of collaterals) {
      const owners = new Set([...(discovered.get(collateral.toLowerCase()) ?? []), ...extraOwners]);
      for (const owner of owners) {
        positions.push(await client.position(collateral, owner as Address));
      }
    }

    const auctionCount = await client.auctionCount();
    const auctions = [];
    for (let id = 1n; id <= auctionCount; id += 1n) {
      const view = await client.auction(id, now);
      if (view.tab > 0n && view.lot > 0n) auctions.push(view);
    }

    // The market reference for a bid is the protocol's own price source: it is the number the
    // auction was struck against, and the only one both sides can check.
    const marketPrices: Record<string, bigint> = {};
    for (const collateral of collaterals) {
      const position = positions.find((p) => p.collateral === collateral && p.collateralAmount > 0n);
      if (position?.priceOk && position.collateralAmount > 0n) {
        marketPrices[collateral.toLowerCase()] = (position.valueWad * WAD) / position.collateralAmount;
      }
    }

    const [duration, floorBps] = await Promise.all([
      publicClient.readContract({ address: deployment.auction, abi: liquidationauctionAbi, functionName: "duration" }),
      publicClient.readContract({ address: deployment.auction, abi: liquidationauctionAbi, functionName: "floorBps" }),
    ]);

    const dollarBalance = account
      ? ((await publicClient.readContract({
          address: deployment.techd,
          abi: [parseAbiItem("function balanceOf(address) view returns (uint256)")],
          functionName: "balanceOf",
          args: [account.address],
        })) as bigint)
      : 0n;

    const { actions, notes } = plan({
      positions,
      auctions,
      marketPrices,
      dollarBalance,
      auctionParams: { duration: BigInt(duration as number), floorBps: BigInt(floorBps as number) },
      now,
      policy,
    });

    log("pass", { positions: positions.length, auctions: auctions.length, actions: actions.length });
    for (const note of notes) log("note", { detail: note });

    for (const action of actions) {
      log(`plan.${action.kind}`, action as unknown as Record<string, unknown>);
      if (!execute || !wallet || !account || action.kind === "watch") continue;
      try {
        const hash = await send(action);
        log(`sent.${action.kind}`, { hash });
      } catch (error) {
        log(`failed.${action.kind}`, { error: error instanceof Error ? error.message.split("\n")[0] : String(error) });
      }
    }
  }

  async function send(action: Action): Promise<string> {
    if (!wallet || !account) throw new Error("no signer");
    const base = { account, chain: robinhoodChain } as const;
    switch (action.kind) {
      case "flag":
        return wallet.writeContract({
          ...base,
          address: deployment.engine,
          abi: vaultengineAbi,
          functionName: "flag",
          args: [action.collateral as Address, action.owner as Address],
        });
      case "unflag":
        return wallet.writeContract({
          ...base,
          address: deployment.engine,
          abi: vaultengineAbi,
          functionName: "unflag",
          args: [action.collateral as Address, action.owner as Address],
        });
      case "liquidate":
        return wallet.writeContract({
          ...base,
          address: deployment.engine,
          abi: vaultengineAbi,
          functionName: "liquidate",
          args: [action.collateral as Address, action.owner as Address],
        });
      case "redo":
        return wallet.writeContract({
          ...base,
          address: deployment.auction,
          abi: liquidationauctionAbi,
          functionName: "redo",
          args: [action.auctionId],
        });
      case "take": {
        const collateralWanted = (action.spend * WAD) / action.maxPrice;
        return wallet.writeContract({
          ...base,
          address: deployment.auction,
          abi: liquidationauctionAbi,
          functionName: "take",
          args: [action.auctionId, collateralWanted, action.maxPrice, account.address],
        });
      }
      default:
        throw new Error(`nothing to send for ${action.kind}`);
    }
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
