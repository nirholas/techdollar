# @techdollar/keeper

Watches positions and auctions. Flags what is unsafe, liquidates what it can, bids what pays, and
restarts auctions that fell to their floor.

```bash
pnpm start -- --deployment deployments/robinhood.json --once      # report only
pnpm start -- --deployment deployments/robinhood.json --execute   # send transactions
```

Reports by default, and the reports are the useful part: every action it would take, and every one
it skipped with the reason. An auction 40 bps below market against a 100 bps floor. A position whose
collateral is halted. A bid it cannot fund.

## It does nothing during a halt, on purpose

An unpriceable position is not an unsafe one. A keeper that treats them the same fires liquidations
at halted collateral, burns gas on guaranteed reverts, and fills its logs with failures that hide
the real ones. This one emits a `watch` action and waits, then acts in the first block after the
halt lifts, where the flag it placed earlier pays it.

## Policy

| Flag | Default | Meaning |
|---|---|---|
| `--min-profit-bps` | 100 | Do not bid unless the auction is this far under market |
| `--max-bid` | 250000 | Most TECHDOLLAR to commit to one bid |
| `--interval` | 30 | Seconds between passes |
| `--from-block` | 0 | Where to discover positions from `Mint` events |

## Why the decisions are pure functions

`src/planner.ts` decides everything from positions, auctions, prices, a balance and a clock, with no
network of its own. The cases that matter, an unpriceable position, a halted auction, a bid that has
to shrink to the balance on hand, are exactly the ones that are painful to stage against a live
chain, and `test/planner.test.ts` runs all of them in milliseconds.
