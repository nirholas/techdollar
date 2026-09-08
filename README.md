# TECHDOLLAR

**Lock NVDA. Mint TECHDOLLAR. Keep the NVDA.**

MakerDAO proved you can build a dollar onchain: lock ETH, mint DAI, repay, unlock. TECHDOLLAR
applies the same machine to Robinhood's tokenized real-world assets. Dollar liquidity against your
equities, without selling them, without a broker, and without giving up the upside.

Maker proved it with crypto collateral. Robinhood Chain lets it be proved with the world's assets.

```
deposit   ──→  lock a tokenized equity in a vault only you can withdraw from
mint      ──→  draw TECHDOLLAR against it, inside a ratio and a ceiling
repay     ──→  burn the dollars, unlock the shares, keep every dollar the shares gained
liquidate ──→  if you fall below the line, a public Dutch auction retires your debt
```

## The part that is not MakerDAO

A Robinhood equity can be **halted by its issuer**, and while it is, every transfer reverts. That
means liquidation is not slow or expensive, it is impossible: the seizure is the transaction that
reverts. A keeper with unlimited capital and a 100% discount cannot act, for an interval nobody can
bound in advance.

No mainnet collateral has ever had that property, so three mechanisms price it:

- **A halt buffer** on every collateral, on top of the liquidation ratio. NVDA at 150% + 25% means
  $17,000 of collateral supports $9,714 rather than $11,333. The difference is the price of an
  option the issuer holds and the borrower sold.
- **Flagging.** Any keeper can mark a position unsafe the moment before a halt and is paid a share
  of the penalty when it is finally liquidated. A halt is not an escape from the penalty, and
  keepers are paid to watch rather than only to act.
- **Ceilings sized to on-chain depth**, not to conviction. A debt ceiling is 15% of measured pool
  liquidity, because what a liquidator could actually sell on this chain is the only thing that
  makes a liquidation solvent.

[docs/halts.md](docs/halts.md) has the full table of what works and what does not during a halt.
Every row of it is a test.

## What is in here

```
contracts/          Foundry. Six contracts, 51 tests, four of them against live Robinhood Chain
  src/VaultEngine.sol          the CDP: ratios, ceilings, per-second fees, flagging, liquidation
  src/LiquidationAuction.sol   a falling-price auction that burns the dollars it raises
  src/PegStabilityModule.sol   USDG in and out, one for one, so the peg is arbitrageable on day one
  src/SavingsTechDollar.sol    sTECHD, paid only out of fees the protocol actually collected
  src/SherwoodPriceSource.sol  the adapter onto the only equity oracle this chain has
packages/sdk/       @techdollar/sdk: positions, health, liquidation prices, auctions, halt state
apps/keeper/        flags, liquidates, bids, and knows to do none of those during a halt
docs/               architecture, halts, risk parameters, operating
```

## Run it

```bash
pnpm install
cd contracts && forge test                                  # 47 local tests
RHC_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test   # plus 4 against the live chain
cd .. && pnpm abis && pnpm -r build && pnpm -r test
```

The fork tests are the ones worth reading. They check that the deployed NVDA token still looks the
way this protocol assumes (18 decimals, a `uiMultiplier` of 1e18, a readable halt surface), run a
full borrow and repay against it at the real pool price, and run a **complete liquidation**: a real
seizure moving real NVDA into the auction, a bidder taking it as the price decays, and the leftover
shares going back to the borrower. Mocks cannot prove that path, because the thing being proved is
the token's own transfer behaviour. If Robinhood upgrades the beacon behind all 254 equities, these
go red.

## Design decisions worth arguing with

**The manager of a vault is its owner, and nobody else can move the collateral.** There is no
instruction anywhere that lets governance, the deployer, or a keeper take a position's collateral
except through a liquidation that pays for it or a withdrawal by its owner.

**Repayment always works.** Not while paused, not while frozen, not while the oracle is dark:
always. A borrower whose collateral has been halted by its issuer still has one lever, and it is the
one that reduces risk.

**An unusable price is not a licence to liquidate.** The engine refuses to seize a position it
cannot value, and says which of the ten price statuses stopped it. An oracle outage that liquidated
the book would be a far worse failure than one that paused it.

**Bad debt is visible.** There is no MKR-style debt auction that dilutes a token to paper over a
loss. Shortfalls net against the surplus buffer and whatever remains sits on the books as `badDebt`
for anyone to read.

## Status

Unaudited and deployed nowhere. `deployments/` is empty for exactly that reason, and every app reads
its addresses from a file the deploy script writes rather than from a constant nobody can verify.

Related work on the same chain: [Sherwood](https://github.com/nirholas/sherwood) (the equity oracle
and halt-aware lending this depends on), [Quiver](https://github.com/nirholas/quiver) (intent-based
swaps), [Loxley](https://github.com/nirholas/loxley) (x402 payments).

MIT.
