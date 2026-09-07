# @techdollar/sdk

Read and operate TECHDOLLAR on Robinhood Chain.

```ts
import { TechDollarClient } from "@techdollar/sdk";

const client = new TechDollarClient(deployment);
const position = await client.position(NVDA, borrower);

position.debt;                 // owed right now, interest included
position.healthFactor;         // above 1e18 is safe
position.liquidationPriceWad;  // "NVDA at $157.50 and you are in trouble"
position.halted;               // the issuer has frozen the collateral
position.status;               // why the price is unusable, if it is
```

Reads go through the engine's `inspect`, which never reverts on an unusable price. A keeper has to
tell "this position is fine" from "I cannot see this position", and a view that throws tells it
neither.

## Beyond positions

```ts
await client.isHalted(NVDA);          // paused, tokenPaused, oraclePaused
await client.corporateAction(NVDA);   // the next multiplier and when it lands, or null
await client.auction(1n);             // lot, tab, current price, expiry, halt state
```

`corporateAction` is worth calling before you conclude anything is broken: Robinhood publishes the
next `uiMultiplier` and its effective second in advance, and the oracle blacks out across it. That
blackout reads exactly like an outage and is not one.

## Math

`annualRateToPerSecondRay`, `debtAt`, `healthFactor`, `liquidationPrice`, `auctionPrice` all mirror
the contracts, in the same rounding direction, and are tested against the same numbers the Solidity
suite asserts. A client that computes a different answer than the chain quotes a borrower a
liquidation price the protocol does not agree with, which is worse than quoting none.

## Regenerating the ABIs

```bash
forge build --root contracts && pnpm abis
```

`src/abis.ts` is generated from the forge build, so the TypeScript can never be compiled against an
interface the contracts no longer have.
