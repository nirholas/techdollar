import { describe, expect, it } from "vitest";

import {
  BPS,
  RAY,
  WAD,
  annualRateToPerSecondRay,
  auctionPrice,
  borrowCapacity,
  debtAt,
  healthFactor,
  liquidationPrice,
  perSecondRayToAnnualBps,
  rpow,
} from "../src/math.js";

/**
 * The numbers here are the ones `contracts/test` asserts on chain. A client that computes a
 * different answer than the contract quotes a borrower a liquidation price the protocol does not
 * agree with, which is worse than not quoting one.
 */

const NVDA_DECIMALS = 18;
const RATIO_WITH_BUFFER = 17_500n; // 150% liquidation ratio plus a 25% halt buffer

describe("interest", () => {
  it("reproduces the per-second rate governance actually sets", () => {
    // The constant the contracts' tests use for 5% a year, which is MakerDAO's own duty figure.
    const fivePercent = 1_000_000_001_547_125_957_863_212_448n;
    const derived = annualRateToPerSecondRay(500);

    // Within a few hundred wei of a ray: `rpow` is a step function at this precision, so the whole
    // neighbourhood compounds to the same annual rate. What matters is the round trip.
    const gap = derived > fivePercent ? derived - fivePercent : fivePercent - derived;
    expect(gap).toBeLessThan(1_000n);
    expect(perSecondRayToAnnualBps(derived)).toBe(500);
    expect(perSecondRayToAnnualBps(fivePercent)).toBe(500);
    expect(annualRateToPerSecondRay(0)).toBe(RAY);
    expect(perSecondRayToAnnualBps(RAY)).toBe(0);
  });

  it("compounds a year of 5% onto a debt", () => {
    const debt = debtAt({
      normalizedDebt: 5_000n * WAD,
      rate: RAY,
      feePerSecondRay: annualRateToPerSecondRay(500),
      lastAccrual: 0n,
      now: 31_536_000n,
    });
    // 5,250 to within the rounding of a per-second rate, matching the on-chain assertion.
    expect(debt).toBeGreaterThan(5_249n * WAD);
    expect(debt).toBeLessThan(5_251n * WAD);
  });

  it("charges nothing when no time has passed", () => {
    expect(
      debtAt({
        normalizedDebt: 5_000n * WAD,
        rate: RAY,
        feePerSecondRay: annualRateToPerSecondRay(500),
        lastAccrual: 1_000n,
        now: 1_000n,
      }),
    ).toBe(5_000n * WAD);
  });

  it("raises a ray to a power the way the contracts do", () => {
    expect(rpow(RAY, 1_000n)).toBe(RAY);
    expect(rpow(2n * RAY, 3n)).toBe(8n * RAY);
  });
});

describe("position health", () => {
  it("matches the engine's own arithmetic on the worked example", () => {
    // 100 NVDA at $170 is $17,000; the ratio plus buffer allows $9,714.
    const valueWad = 17_000n * WAD;
    expect(borrowCapacity(valueWad, RATIO_WITH_BUFFER)).toBe((valueWad * BPS) / RATIO_WITH_BUFFER);
    expect(healthFactor(valueWad, 9_000n * WAD, RATIO_WITH_BUFFER)).toBeGreaterThan(WAD);
    expect(healthFactor(valueWad, 10_000n * WAD, RATIO_WITH_BUFFER)).toBeLessThan(WAD);
  });

  it("answers the question a borrower actually asks", () => {
    // "At what NVDA price am I liquidated?" for 100 shares against $9,000.
    const price = liquidationPrice({
      debt: 9_000n * WAD,
      collateralAmount: 100n * WAD,
      collateralDecimals: NVDA_DECIMALS,
      requiredRatioBps: RATIO_WITH_BUFFER,
    });
    expect(price).toBe(157n * WAD + 500_000_000_000_000_000n); // $157.50
  });

  it("has no liquidation price for a position with no debt", () => {
    expect(
      liquidationPrice({
        debt: 0n,
        collateralAmount: 100n * WAD,
        collateralDecimals: NVDA_DECIMALS,
        requiredRatioBps: RATIO_WITH_BUFFER,
      }),
    ).toBeNull();
  });
});

describe("auction price", () => {
  const args = { startPrice: 172n * WAD + WAD / 2n, startTime: 1_000n, duration: 3_600n, floorBps: 5_000n };

  it("opens at the top and halves by the end", () => {
    expect(auctionPrice({ ...args, now: 1_000n }).price).toBe(args.startPrice);
    const nearEnd = auctionPrice({ ...args, now: 4_599n }).price;
    expect(nearEnd).toBeGreaterThan(args.startPrice / 2n);
    expect(nearEnd).toBeLessThan((args.startPrice * 5_010n) / BPS);
  });

  it("decays linearly through the middle", () => {
    const half = auctionPrice({ ...args, now: 2_800n }).price;
    expect(half).toBe(args.startPrice - (args.startPrice - args.startPrice / 2n) / 2n);
  });

  it("reports an expired pass rather than a stale price", () => {
    expect(auctionPrice({ ...args, now: 4_600n })).toEqual({ price: 0n, expired: true });
  });
});
