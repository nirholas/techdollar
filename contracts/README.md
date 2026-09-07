# TECHDOLLAR contracts

Foundry. Six contracts, no proxies, no upgrades.

```bash
forge build
forge test                                                      # 47 local tests
RHC_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test   # plus the fork suite
```

| File | What it is |
|---|---|
| `src/TechDollar.sol` | The ERC-20, with permit. Knows only which contracts may mint and burn. |
| `src/VaultEngine.sol` | Collateral types, positions, per-second fees, flagging, liquidation, surplus |
| `src/LiquidationAuction.sol` | A Dutch auction that burns the dollars it raises and returns the rest |
| `src/PegStabilityModule.sol` | USDG in and out, one for one, fully reserved |
| `src/SavingsTechDollar.sol` | sTECHD, an ERC-4626 vault funded only from realised surplus |
| `src/SherwoodPriceSource.sol` | Adapter onto the Sherwood oracle |

## Tests

| Suite | What it proves |
|---|---|
| `VaultEngine.t.sol` | The product: lock, mint, keep the upside, repay, unlock. Plus ratios, dust, ceilings, interest, frozen collateral, and that repayment survives an unusable price |
| `Liquidation.t.sol` | Seizure, the decaying price, the tab, the collateral that goes back to the borrower, bad debt, restarting a dead auction, and who gets paid |
| `Halt.t.sol` | Every row of the halt table in `docs/halts.md` |
| `Peg.t.sol` | The six-to-eighteen decimals boundary, fee accounting, and that the module is always fully reserved |
| `Savings.t.sol` | That the savings rate is never paid out of thin air, and that a lean period is paid out of a fat one |
| `Fork.t.sol` | The live NVDA token, its halt surface, and a full borrow and repay at the real pool price |

## Two things to know before editing

**Advance time with `skip(n)`, never `vm.warp(block.timestamp + n)`.** Under `via_ir` solc treats
`block.timestamp` as invariant for the transaction and caches it, which is true of a real
transaction and false of a cheatcode. The second such warp in a test silently does nothing, and an
interest test then passes while measuring nothing. The tell is gas: the call that should have done
work shows about a thousand.

**Every width reduction goes through `SafeCastLib`.** A silent truncation in a debt or a collateral
figure is not a rounding error, it is free money.
