# Risk parameters

Every number a collateral carries, where it comes from, and what happens when it is wrong.

## The parameters

| Parameter | What it does | Set from |
|---|---|---|
| `liquidationRatioBps` | Collateral a position must keep against its debt | Volatility of the underlying equity |
| `haltBufferBps` | Added to the ratio, for the issuer's option to freeze the token | How halt-prone the listing is |
| `debtCeiling` | Most TECHDOLLAR outstanding against this collateral | **Measured on-chain pool depth** |
| `dust` | Smallest position worth liquidating | Gas cost of a liquidation |
| `feePerSecondRay` | Stability fee, compounded per second | Demand for the dollar, and the savings rate |
| `liquidationPenaltyBps` | Charged on liquidation, funds the auction's incentives | Cost of getting a keeper to act |
| `flagRewardBps` | Share of the penalty to whoever flagged first | Cost of getting keepers to watch |

## Debt ceilings are a liquidity measurement, not an opinion

A debt ceiling is not a statement of confidence in NVDA. It is a statement about how much NVDA a
liquidator could actually sell into the pools that exist on Robinhood Chain, because that is the
only thing that makes a liquidation solvent.

The rule this protocol uses: **ceiling = 15% of measured on-chain liquidity**. At a 150% ratio, the
collateral behind a full book is about 1.5x the ceiling, so a complete liquidation sells roughly 22%
of the pool's depth. That is inside what a 13% liquidation penalty can absorb at the auction's
starting premium.

On-chain liquidity as measured on Robinhood Chain (2026-09-04, from the pool discovery in the
sibling [Sherwood](https://github.com/nirholas/sherwood) repository):

| Equity | On-chain liquidity | Ceiling at 15% | Holders |
|---|---|---|---|
| SPY | $8.46M | $1.27M | 51,254 |
| NVDA | $7.14M | $1.07M | 92,177 |
| SPCX | $3.93M | $590k | 71,501 |
| MU | $2.56M | $384k | 30,917 |
| AAPL | $2.38M | $357k | 25,891 |
| QQQ | $1.94M | $291k | - |
| TSLA | $1.66M | $249k | - |

These are small numbers, and they should be. The chain is young and the pools are thin; a protocol
that set a $50M ceiling against a $7M pool would be writing a promise the market cannot keep. The
ceilings rise as the pools do, and nothing else about the design has to change for that.

## Halt buffers

The buffer is the price of an option the issuer holds and the borrower sold: the right to stop the
market for an interval nobody can bound in advance. It is not a volatility margin, and it should not
be reasoned about as one.

| Class | Ratio | Halt buffer | Effective |
|---|---|---|---|
| Broad index (SPY, QQQ) | 130% | 15% | 145% |
| Mega-cap, deep pool (NVDA, AAPL, MSFT) | 150% | 25% | 175% |
| Single name, thinner pool | 175% | 35% | 210% |
| Anything with a scheduled corporate action inside a week | onboarding deferred | | |

A halt in SPY and a halt in a thin single listing are not the same risk: the index halts rarely and
resumes quickly, and its pool is the deepest on the chain. The buffer reflects that.

## Stability fees

Governance sets the **per-second** rate in ray, because computing an n-th root on chain is gas
nobody should pay. Convert with `annualRateToPerSecondRay` from `@techdollar/sdk`, or use the table:

| Annual | Per second, ray |
|---|---|
| 0% | `1000000000000000000000000000` |
| 2% | `1000000000627937192491029810` |
| 5% | `1000000001547125957863212448` |
| 8% | `1000000002440418608258400030` |

The constraint that matters is that the weighted stability fee has to exceed the savings rate. It is
not enforced on chain, because a rate change and a fee change cannot be atomic across every
collateral; it is enforced by the savings vault only ever paying out of surplus that was actually
collected. Set the rates wrong and savers earn less than the target, which is the correct failure.

## What happens when a parameter is wrong

| Wrong | Consequence | Recovery |
|---|---|---|
| Ratio too low | Liquidations end in bad debt when the price gaps | Raise it; existing positions become liquidatable |
| Halt buffer too low | A halt strands positions that were only just safe | Raise it, and freeze the collateral if the halt is live |
| Ceiling too high | Liquidations move the pool more than the penalty covers | Lower it; existing debt is unaffected and only new debt stops |
| Dust too low | Positions that cost more to liquidate than they recover | Raise it; small positions must repay or grow |
| Fee too high | Borrowers leave | Lower it; the clock is settled first, so nobody is billed retroactively |

Every one of these is a governance call with no upgrade, no migration, and no effect on a position
that is already safe.
