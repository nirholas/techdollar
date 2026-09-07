# Architecture

Six contracts. Each one does a job that the others do not.

```
                 TechDollar (TECHD)
                   mint / burn
                        ▲
         ┌──────────────┼───────────────┐
         │              │               │
   VaultEngine   PegStabilityModule  LiquidationAuction
   equity CDPs      USDG 1:1            Dutch sale
         │                                  ▲
         ├── SherwoodPriceSource ────────────┘
         │      (IPriceSource)
         └── SavingsTechDollar (sTECHD)
                 pays out of surplus
```

## VaultEngine

The CDP. One `Ilk` per collateral (rate accumulator, ceiling, dust, fee, ratios, penalty) and one
`Position` per owner per collateral (collateral, normalized debt, flag).

Debt is stored normalized and multiplied by a per-collateral rate accumulator that compounds per
second, which is MakerDAO's design and is why interest costs one multiplication rather than a loop.
Fees accrue into `surplus`, which is a claim on repayments rather than minted dollars: the dollars
come into existence only when the surplus is drawn, and the borrowers' obligation to repay them
already exists.

Rounding is directional everywhere. What a borrower owes rounds up; what a borrower receives rounds
down.

## LiquidationAuction

A falling-price auction. It opens above the oracle (nobody should buy seized collateral at fair
value the instant it is seized), decays linearly to a floor, and settles in one transaction whenever
a bidder thinks the price is right.

The alternative, an English auction with a bidding window, would leave the protocol holding equity
for the length of the window, and that window is exactly when the issuer might halt the token. A
Dutch auction measures the protocol's exposure in blocks.

Dollars paid in are **burned**, not banked: a liquidation retires the debt it is liquidating.
Collateral the tab did not need goes back to the borrower.

## SherwoodPriceSource

An adapter, and deliberately nothing more. Robinhood Chain has **no price oracle of any kind**: no
Chainlink, no Pyth. [Sherwood](https://github.com/nirholas/sherwood) is the one built for it, and it
combines a pool TWAP with an attested equity quote, serves nothing unless the two agree, and goes
dark across a corporate action rather than averaging two incompatible prices.

This protocol consumes `IPriceSource`, which asks two questions: what is this worth, and if you
cannot say, why not. Everything else lives behind that line.

## PegStabilityModule

USDG in, TECHDOLLAR out, one for one inside a ceiling, and back again. A CDP stablecoin's peg comes
from somebody being able to arbitrage it, and on day one nobody can: there is no deep TECHDOLLAR
market to arbitrage against. This module is the arbitrage.

It is fully reserved by construction: minting is the only thing that raises `outstanding`, and every
mint takes the USDG first. Fees accumulate as reserves above that line, and `sweepFees` can take
only the difference.

## SavingsTechDollar

An ERC-4626 vault over TECHDOLLAR whose assets grow at the savings rate. `drip` is permissionless
and draws from the engine's realised surplus, capped by that surplus. If borrowers have not paid
enough, savers earn less than the target and the shortfall is carried forward.

That cap is the whole point. Minting unbacked dollars to pay a rate the protocol did not earn is how
a stablecoin stops being one.

## What is not here

**No governance token.** Parameters are owned by whatever address governance is; there is no
protocol token, no vote-escrow, and no emissions.

**No upgradeability.** No proxies. A parameter change is a parameter change; a code change is a new
deployment and a migration people can choose to take.

**No debt auction.** MakerDAO covers bad debt by minting and selling MKR. Here, bad debt nets against
the surplus buffer and anything left sits on the books as `badDebt`, visible to anyone. Covering it
is a governance decision with real money, not an automatic dilution.
