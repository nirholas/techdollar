# Halts

The one risk that makes this protocol different from every CDP that came before it.

## What a halt is

Every Robinhood tokenized equity is a beacon proxy onto one shared `Stock` implementation, and that
implementation has a `paused()` flag. While it is true, **every transfer, approve and permit
reverts**. There is a per-token pause and a registry-wide pause that stops all 254 equities at once,
and a separate `oraclePaused()` where the issuer disavows the price without freezing transfers.

Halts are normal market structure for equities. Trading stops for news, for volatility, for
corporate actions, for a regulator. A protocol that panicked at every one of them would be unusable.

## Why it matters more here than anywhere else

On mainnet, a CDP's worst case is that the price falls faster than keepers can act. Liquidation is
slow, or expensive, but possible.

Here, the worst case is different in kind: **the seizure is the transaction that reverts**. A keeper
with unlimited capital and a 100% discount cannot liquidate a halted position, because the transfer
of the collateral out of the vault is itself blocked. Not slow. Not expensive. Impossible, for an
interval the issuer chooses and nobody can bound in advance.

Meanwhile interest keeps accruing and the underlying keeps moving, off chain, where the price will
be waiting when trading resumes.

## What this protocol does about it

**1. The halt buffer.** Every collateral carries `liquidationRatioBps + haltBufferBps`. NVDA at 150%
plus 25% means $17,000 of collateral supports $9,714 rather than $11,333. The difference is the
price of an option the issuer holds and the borrower sold. It is charged up front, because it cannot
be charged during the halt.

**2. Flagging.** A keeper may flag a position the moment it is unsafe **and the price is readable**,
and is paid a share of the liquidation penalty when it is eventually liquidated. A borrower who goes
unsafe an hour before a halt cannot use the halt to escape the penalty, and keepers are paid to
watch rather than only to act. During a halt no new flags can be made: unsafety has to be proved,
and proving it needs a price.

**3. Ceilings sized to depth.** See [risk-parameters.md](risk-parameters.md). The less of an asset a
liquidator could sell on this chain, the less TECHDOLLAR can be minted against it, halt or no halt.

## Exactly what works during a halt

| Action | During a halt | Why |
|---|---|---|
| Repay debt | **Yes** | Repayment moves dollars, not equity. This is the borrower's one lever and it always works. |
| Accrue interest | Yes | A halt is the issuer's decision, not the lender's. The loan does not pause with it. |
| Deposit more collateral | No | The transfer reverts. Collateral cannot be added to cure a position. |
| Withdraw collateral | No | Same transfer, same revert. |
| Mint new debt | No | The price is unusable, and the engine refuses `PriceUnusable(TokenPaused)`. |
| Flag a position | No | Unsafety cannot be proved without a price. |
| Liquidate | No | The seizure reverts. The engine says `PriceUnusable(TokenPaused)` rather than failing three calls deep in an ERC-20. |
| Bid in a running auction | No | The collateral cannot move to the bidder. |

Every one of these is covered by a test in `contracts/test/Halt.t.sol`.

## What is deliberately not done

**Nothing auto-freezes on a halt.** Halts are routine, and a protocol that froze itself on each one
would be closed more often than open.

**No mechanism pretends a halted asset can be liquidated.** There is no delayed seizure, no
synthetic settlement, no insurance fund that buys the position. Those either do not work or move the
loss somewhere less honest. The buffer is charged up front and the loss, if it comes, lands on the
surplus buffer where it can be seen.

## What a keeper should do

Watch and report. `@techdollar/keeper` treats an unpriceable position as a `watch` action rather
than a liquidation attempt, because a keeper that fires liquidations at halted collateral only burns
gas and fills the logs with reverts that hide the real ones.

The moment the halt lifts, flagged positions are liquidatable in the same block, and whoever flagged
first is paid out of the penalty.
