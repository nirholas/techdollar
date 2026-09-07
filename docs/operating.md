# Operating

## Deploy

```bash
cd contracts
forge build

SHERWOOD_ORACLE=0x... PRIVATE_KEY=0x... GOVERNANCE=0x... \
forge script script/Deploy.s.sol --rpc-url $RHC_RPC_URL --broadcast
```

The script deploys all six contracts, wires them, and then **asserts every link** before printing an
address: the engine can mint, the auction can burn, the engine knows its auction house and surplus
receiver, the peg module is authorised. Wiring is what goes wrong in a deploy, and it goes wrong
silently.

Nothing is borrowable until a collateral is onboarded.

## Onboard a collateral

```bash
ENGINE=0x... COLLATERAL=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC \
CEILING=1070000 RATIO_BPS=15000 HALT_BUFFER_BPS=2500 PRIVATE_KEY=0x... \
forge script script/AddCollateral.s.sol --rpc-url $RHC_RPC_URL --broadcast
```

The script prints the token's live halt state, its multiplier and any **scheduled corporate action**
before it broadcasts, and warns if one lands within a day. Onboarding into a split means the price
feed blacks out mid-onboarding, and it is much easier to read that warning than to debug it as an
oracle failure afterwards.

See [risk-parameters.md](risk-parameters.md) for where the ceiling comes from. It is not a
judgement about the asset; it is 15% of measured pool depth.

## Run a keeper

```bash
pnpm install
pnpm --filter @techdollar/sdk build
pnpm --filter @techdollar/keeper start -- --deployment deployments/robinhood.json --once
```

Reports by default. Add `--execute` and a key to send transactions. Without `--execute` it prints
every action it would take and, just as usefully, why it skipped the rest: an auction 40 bps below
market against a 100 bps floor, a position whose collateral is halted, a bid it cannot fund.

| Flag | Default | Meaning |
|---|---|---|
| `--min-profit-bps` | 100 | Do not bid unless the auction is this far under market |
| `--max-bid` | 250000 | Most TECHDOLLAR to commit to a single bid |
| `--interval` | 30 | Seconds between passes |
| `--from-block` | 0 | Where to start discovering positions from `Mint` events |

## Day-to-day governance

| Action | Call | When |
|---|---|---|
| Change a fee or a ratio | `engine.setIlk` | The clock is settled first, so nothing is billed retroactively |
| Stop new debt on a collateral | `engine.freezeIlk` | A halt that looks structural, a broken feed, a listing under review |
| Change the auction shape | `auction.setParams` | Auctions clearing too fast (premium too generous) or not at all |
| Change the savings rate | `savings.setRate` | Keep it under the weighted stability fee |
| Take the peg module's fees | `psm.sweepFees` | Only the surplus above full reserve can move |

Freezing a collateral stops new debt and nothing else. Repaying and withdrawing always work, which
is the property that keeps a governance mistake from becoming a trap.

## When something looks wrong

1. **Is the collateral halted?** `client.isHalted(collateral)`. It explains most failures.
2. **Is a corporate action scheduled?** `client.corporateAction(collateral)`. The oracle blacks out
   across one, which reads like an outage and is not.
3. **What does the engine think?** `engine.inspect(collateral, owner)` never reverts and returns the
   price status alongside the position.
4. **Is there bad debt?** `engine.badDebt()` against `engine.surplus()`. `settle()` is permissionless
   and only ever makes the books more honest.
