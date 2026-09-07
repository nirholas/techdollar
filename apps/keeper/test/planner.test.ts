import { describe, expect, it } from "vitest";
import { WAD } from "@techdollar/sdk";
import type { AuctionView, PositionView } from "@techdollar/sdk";

import { DEFAULT_POLICY, plan } from "../src/planner.js";

const NVDA = "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC";
const OWNER = "0x1111111111111111111111111111111111111111";

function position(overrides: Partial<PositionView> = {}): PositionView {
  return {
    collateral: NVDA,
    owner: OWNER,
    collateralAmount: 100n * WAD,
    debt: 9_000n * WAD,
    valueWad: 17_000n * WAD,
    priceOk: true,
    status: "OK",
    safe: true,
    halted: false,
    flaggedAt: 0n,
    healthFactor: (17_000n * WAD * 10_000n) / (9_000n * 17_500n),
    liquidationPriceWad: 157n * WAD,
    ...overrides,
  };
}

function auction(overrides: Partial<AuctionView> = {}): AuctionView {
  return {
    id: 1n,
    collateral: NVDA,
    lot: 100n * WAD,
    tab: 10_170n * WAD,
    price: 172n * WAD,
    expired: false,
    halted: false,
    endsAt: 4_600n,
    ...overrides,
  };
}

const params = { duration: 3_600n, floorBps: 5_000n };
const market = { [NVDA.toLowerCase()]: 150n * WAD };

describe("positions", () => {
  it("leaves a healthy position alone", () => {
    const { actions } = plan({
      positions: [position()],
      auctions: [],
      marketPrices: market,
      dollarBalance: 0n,
      auctionParams: params,
      now: 1_000n,
      policy: DEFAULT_POLICY,
    });
    expect(actions).toHaveLength(0);
  });

  it("flags and then liquidates one that has gone unsafe", () => {
    const { actions } = plan({
      positions: [position({ safe: false })],
      auctions: [],
      marketPrices: market,
      dollarBalance: 0n,
      auctionParams: params,
      now: 1_000n,
      policy: DEFAULT_POLICY,
    });
    expect(actions.map((a) => a.kind)).toEqual(["flag", "liquidate"]);
  });

  it("does not flag twice", () => {
    const { actions } = plan({
      positions: [position({ safe: false, flaggedAt: 900n })],
      auctions: [],
      marketPrices: market,
      dollarBalance: 0n,
      auctionParams: params,
      now: 1_000n,
      policy: DEFAULT_POLICY,
    });
    expect(actions.map((a) => a.kind)).toEqual(["liquidate"]);
  });

  it("watches rather than acts when the collateral is halted", () => {
    // The whole point. An unpriceable position is not an unsafe one, and a keeper that treats them
    // the same turns every halt into a wave of failed liquidation transactions.
    const { actions, notes } = plan({
      positions: [position({ priceOk: false, status: "TokenPaused", halted: true, safe: false })],
      auctions: [],
      marketPrices: market,
      dollarBalance: 0n,
      auctionParams: params,
      now: 1_000n,
      policy: DEFAULT_POLICY,
    });
    expect(actions).toEqual([{ kind: "watch", subject: `${NVDA}:${OWNER}`, reason: "halted, TokenPaused" }]);
    expect(notes.join(" ")).toMatch(/collateral is halted/);
  });

  it("clears a flag once the position is safe again", () => {
    const { actions } = plan({
      positions: [position({ flaggedAt: 900n })],
      auctions: [],
      marketPrices: market,
      dollarBalance: 0n,
      auctionParams: params,
      now: 1_000n,
      policy: DEFAULT_POLICY,
    });
    expect(actions.map((a) => a.kind)).toEqual(["unflag"]);
  });
});

describe("auctions", () => {
  it("waits while the auction is above market", () => {
    const { actions, notes } = plan({
      positions: [],
      auctions: [auction()],
      marketPrices: market,
      dollarBalance: 100_000n * WAD,
      auctionParams: params,
      now: 1_000n,
      policy: DEFAULT_POLICY,
    });
    expect(actions).toHaveLength(0);
    expect(notes.join(" ")).toMatch(/under the 100 bps floor/);
  });

  it("bids once the decay puts it under market by enough", () => {
    const { actions } = plan({
      positions: [],
      auctions: [auction()],
      marketPrices: market,
      dollarBalance: 100_000n * WAD,
      auctionParams: params,
      now: 3_000n,
      policy: DEFAULT_POLICY,
    });
    const take = actions.find((a) => a.kind === "take");
    expect(take).toBeDefined();
    if (take?.kind !== "take") throw new Error("no bid");
    expect(take.profitBps).toBeGreaterThanOrEqual(100);
    expect(take.spend).toBeLessThanOrEqual(DEFAULT_POLICY.maxBidSize);
  });

  it("never spends more than it holds", () => {
    const { actions } = plan({
      positions: [],
      auctions: [auction(), auction({ id: 2n })],
      marketPrices: market,
      dollarBalance: 1_000n * WAD,
      auctionParams: params,
      now: 3_400n,
      policy: DEFAULT_POLICY,
    });
    const spent = actions
      .filter((a): a is Extract<typeof a, { kind: "take" }> => a.kind === "take")
      .reduce((sum, a) => sum + a.spend, 0n);
    expect(spent).toBeLessThanOrEqual(1_000n * WAD);
  });

  it("restarts an expired auction instead of leaving it dead", () => {
    const { actions } = plan({
      positions: [],
      auctions: [auction({ expired: true })],
      marketPrices: market,
      dollarBalance: 100_000n * WAD,
      auctionParams: params,
      now: 5_000n,
      policy: DEFAULT_POLICY,
    });
    expect(actions).toEqual([{ kind: "redo", auctionId: 1n }]);
  });

  it("does not try to bid on a halted auction, because no bid can settle", () => {
    const { actions, notes } = plan({
      positions: [],
      auctions: [auction({ halted: true })],
      marketPrices: market,
      dollarBalance: 100_000n * WAD,
      auctionParams: params,
      now: 3_400n,
      policy: DEFAULT_POLICY,
    });
    expect(actions).toEqual([{ kind: "watch", subject: "auction:1", reason: "halted" }]);
    expect(notes.join(" ")).toMatch(/no bid can settle/);
  });
});
