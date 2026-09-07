import { BPS, WAD, auctionPrice } from "@techdollar/sdk";
import type { AuctionView, PositionView } from "@techdollar/sdk";

/**
 * Every decision the keeper makes, as pure functions over a snapshot.
 *
 * The cases worth getting right are the ones that are painful to stage against a live chain: a
 * position that is unsafe but unpriceable, an auction whose collateral is halted mid-sale, a bid
 * that is profitable on paper and not after the spread. All of them are one function call here.
 */

export interface KeeperPolicy {
  /** Do not bid unless the auction is this far below the market price of the collateral. */
  minProfitBps: number;
  /** Most TECHDOLLAR to commit to a single bid. */
  maxBidSize: bigint;
  /** Flag positions this close to the line, before they cross it. */
  flagAtHealthBps: number;
}

export const DEFAULT_POLICY: KeeperPolicy = {
  minProfitBps: 100,
  maxBidSize: 250_000n * WAD,
  flagAtHealthBps: 10_000,
};

export type Action =
  | { kind: "flag"; collateral: string; owner: string; reason: string }
  | { kind: "unflag"; collateral: string; owner: string }
  | { kind: "liquidate"; collateral: string; owner: string; debt: bigint }
  | { kind: "take"; auctionId: bigint; collateral: string; spend: bigint; maxPrice: bigint; profitBps: number }
  | { kind: "redo"; auctionId: bigint }
  | { kind: "watch"; subject: string; reason: string };

export interface PlanInput {
  positions: PositionView[];
  auctions: AuctionView[];
  /** Market price per whole collateral unit, in USD wad, keyed by collateral address. */
  marketPrices: Record<string, bigint>;
  /** What the keeper can spend on bids. */
  dollarBalance: bigint;
  auctionParams: { duration: bigint; floorBps: bigint };
  now: bigint;
  policy: KeeperPolicy;
}

export function plan(input: PlanInput): { actions: Action[]; notes: string[] } {
  const actions: Action[] = [];
  const notes: string[] = [];

  for (const position of input.positions) {
    if (position.debt === 0n) continue;

    if (!position.priceOk) {
      // The most important line in this file. A position with no price is not a position in
      // trouble; it is a position nobody can assess, and acting on it is how an oracle outage
      // becomes a wave of wrongful liquidations. The keeper reports and waits.
      notes.push(
        `${position.owner} on ${position.collateral}: price unusable (${position.status})` +
          (position.halted ? ", collateral is halted" : ""),
      );
      actions.push({
        kind: "watch",
        subject: `${position.collateral}:${position.owner}`,
        reason: position.halted ? `halted, ${position.status}` : position.status,
      });
      continue;
    }

    if (!position.safe) {
      if (position.flaggedAt === 0n) {
        actions.push({
          kind: "flag",
          collateral: position.collateral,
          owner: position.owner,
          reason: "unsafe",
        });
      }
      actions.push({
        kind: "liquidate",
        collateral: position.collateral,
        owner: position.owner,
        debt: position.debt,
      });
      continue;
    }

    // Safe, but close enough to the line that it is worth being the keeper who flagged it first if
    // the collateral halts before anyone can act.
    const health = position.healthFactor;
    if (health < (WAD * BigInt(input.policy.flagAtHealthBps + 500)) / BPS && position.flaggedAt === 0n) {
      notes.push(`${position.owner} on ${position.collateral}: health ${health}, close to the line`);
    }
    if (position.flaggedAt !== 0n) {
      actions.push({ kind: "unflag", collateral: position.collateral, owner: position.owner });
    }
  }

  let budget = input.dollarBalance;
  for (const auction of input.auctions) {
    if (auction.tab === 0n || auction.lot === 0n) continue;

    if (auction.halted) {
      // The collateral cannot move, so no bid can settle. Nothing to do but say so.
      notes.push(`auction ${auction.id}: collateral halted, no bid can settle`);
      actions.push({ kind: "watch", subject: `auction:${auction.id}`, reason: "halted" });
      continue;
    }
    if (auction.expired) {
      actions.push({ kind: "redo", auctionId: auction.id });
      continue;
    }

    const market = input.marketPrices[auction.collateral.toLowerCase()];
    if (!market || market === 0n) {
      notes.push(`auction ${auction.id}: no market price for ${auction.collateral}`);
      continue;
    }
    const { price } = auctionPrice({
      startPrice: auction.price,
      startTime: auction.endsAt - input.auctionParams.duration,
      duration: input.auctionParams.duration,
      floorBps: input.auctionParams.floorBps,
      now: input.now,
    });
    if (price === 0n) continue;

    const profitBps = Number(((market - price) * BPS) / price);
    if (profitBps < input.policy.minProfitBps) {
      notes.push(
        `auction ${auction.id}: ${profitBps} bps below market, under the ${input.policy.minProfitBps} bps floor`,
      );
      continue;
    }

    const lotCost = (auction.lot * price) / WAD;
    const cap = input.policy.maxBidSize < budget ? input.policy.maxBidSize : budget;
    const spend = [lotCost, auction.tab, cap].reduce((a, b) => (a < b ? a : b));
    if (spend === 0n) {
      notes.push(`auction ${auction.id}: nothing left to spend`);
      continue;
    }
    budget -= spend;
    actions.push({
      kind: "take",
      auctionId: auction.id,
      collateral: auction.collateral,
      spend,
      maxPrice: price,
      profitBps,
    });
  }

  return { actions, notes };
}
