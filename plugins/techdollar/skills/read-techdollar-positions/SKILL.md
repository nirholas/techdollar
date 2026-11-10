---
name: read-techdollar-positions
description: Read TECHDOLLAR vault positions, health, liquidation prices, halt state and auctions on Robinhood Chain with the SDK, and run the keeper in report-only mode. Use when the user asks whether a TECHDOLLAR position is safe, what price liquidates it, or what the keeper would do.
---

# Read TECHDOLLAR positions

TECHDOLLAR is a dollar minted against tokenized equities on Robinhood Chain (`eip155:4663`). Monorepo (pnpm): `contracts/` (Foundry), `packages/sdk` (`@techdollar/sdk`), `apps/keeper`. Nothing is published to npm: clone, then `pnpm install && pnpm --filter @techdollar/sdk build`. This skill reads and reports. Never pass `--execute` or a key, and never send a deposit, mint, repay or bid, without showing the exact action and getting an explicit yes.

## SDK

A `Deployment` is `{ chainId, techd, engine, auction, psm, savings, priceSource }` (addresses of the deployed contracts; the keeper reads it from a JSON file).

```ts
import { TechDollarClient } from "@techdollar/sdk";
const client = new TechDollarClient(deployment); // defaults to a public Robinhood Chain RPC; pass a viem PublicClient to override
```

| Method | Returns |
|---|---|
| `collaterals()` | Listed collateral token addresses. |
| `ilk(collateral)` | Ratios, halt buffer, ceiling and fee config for one collateral. |
| `position(collateral, owner)` | `debt`, `collateralAmount`, `valueWad`, `safe`, `halted`, `healthFactor` (above 1e18 is safe), `liquidationPriceWad` (USD per unit at which it becomes liquidatable), `flaggedAt`, `status`. |
| `maxMintable(collateral, owner)` | How much more can be minted now. |
| `isHalted(collateral)` | `{ paused, tokenPaused, oraclePaused }`. |
| `corporateAction(collateral)` | Pending multiplier change, or null. |
| `auction(id)` / `auctionCount()` | Liquidation auction state and count. |

Math helpers: `debtAt`, `healthFactor`, `borrowCapacity`, `liquidationPrice`, `auctionPrice`, `annualRateToPerSecondRay`, `perSecondRayToAnnualBps`. Constants: `USDG`, `PUBLIC_RPC_URLS`, `robinhoodChain`.

A halted collateral means transfers revert and liquidation is impossible for an unknown interval (see `docs/halts.md`). When `halted` is true, say so instead of calling the position safe.

## Keeper in report mode

```bash
pnpm --filter @techdollar/keeper start -- --deployment path/to/deployment.json --once
```

Flags: `--deployment` (required), `--owners`, `--from-block`, `--interval` (seconds, default 30), `--once`, `--min-profit-bps` (default 100), `--max-bid` (default 250000), `--rpc`, `--execute`, `--key` (or env `TECHDOLLAR_KEEPER_KEY`). Without `--execute` it only prints what it would do and why it skipped the rest.

## Worked example

1. `client.collaterals()` to list assets, then `client.ilk(c)` for the terms of one.
2. `client.position(c, owner)`: report `healthFactor`, `liquidationPriceWad` (divide by 1e18 for dollars) and `halted`.
3. `client.auctionCount()` and `client.auction(id)` for open liquidations.
