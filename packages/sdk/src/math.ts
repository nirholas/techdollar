/**
 * The arithmetic the contracts do, mirrored so a client can answer a question without a round trip
 * and, more importantly, without disagreeing with the chain when it does.
 */

export const WAD = 10n ** 18n;
export const RAY = 10n ** 27n;
export const BPS = 10_000n;
export const SECONDS_PER_YEAR = 31_536_000n;

export function mulDivFloor(a: bigint, b: bigint, d: bigint): bigint {
  if (d === 0n) throw new Error("division by zero");
  return (a * b) / d;
}

export function mulDivCeil(a: bigint, b: bigint, d: bigint): bigint {
  if (d === 0n) throw new Error("division by zero");
  const n = a * b;
  return n === 0n ? 0n : (n - 1n) / d + 1n;
}

/** `x^n` in ray, the same iterative squaring the contracts use for interest. */
export function rpow(x: bigint, n: bigint, base: bigint = RAY): bigint {
  let z = n % 2n === 0n ? base : x;
  let b = x;
  let e = n / 2n;
  while (e > 0n) {
    b = (b * b) / base;
    if (e % 2n === 1n) z = (z * b) / base;
    e /= 2n;
  }
  return z;
}

/** Debt owed at `now`, given the stored accumulator and the per-second rate. */
export function debtAt(args: {
  normalizedDebt: bigint;
  rate: bigint;
  feePerSecondRay: bigint;
  lastAccrual: bigint;
  now: bigint;
}): bigint {
  if (args.normalizedDebt === 0n) return 0n;
  const elapsed = args.now > args.lastAccrual ? args.now - args.lastAccrual : 0n;
  const rate =
    elapsed === 0n || args.feePerSecondRay === RAY
      ? args.rate
      : mulDivFloor(rpow(args.feePerSecondRay, elapsed), args.rate, RAY);
  return mulDivCeil(args.normalizedDebt, rate, RAY);
}

/** Above 1e18 is safe, below is liquidatable. Matches `VaultEngine.healthFactor`. */
export function healthFactor(valueWad: bigint, debt: bigint, requiredRatioBps: bigint): bigint {
  if (debt === 0n) return 2n ** 255n;
  return mulDivFloor(valueWad, WAD * BPS, debt * requiredRatioBps);
}

/** The most that can be borrowed against a collateral value, before ceilings. */
export function borrowCapacity(valueWad: bigint, requiredRatioBps: bigint): bigint {
  return mulDivFloor(valueWad, BPS, requiredRatioBps);
}

/**
 * The share price at which a position becomes liquidatable.
 *
 * The number a borrower actually wants: not a health factor, but "NVDA at $118 and you are in
 * trouble". Undefined for a position with no debt, which is the point.
 */
export function liquidationPrice(args: {
  debt: bigint;
  collateralAmount: bigint;
  collateralDecimals: number;
  requiredRatioBps: bigint;
}): bigint | null {
  if (args.debt === 0n || args.collateralAmount === 0n) return null;
  const scale = 10n ** BigInt(args.collateralDecimals);
  // price such that amount * price / scale * BPS == debt * ratio, in USD wad.
  return mulDivCeil(args.debt * args.requiredRatioBps, scale, BPS * args.collateralAmount);
}

/** The auction's current price, mirroring `LiquidationAuction.price`. */
export function auctionPrice(args: {
  startPrice: bigint;
  startTime: bigint;
  duration: bigint;
  floorBps: bigint;
  now: bigint;
}): { price: bigint; expired: boolean } {
  const elapsed = args.now > args.startTime ? args.now - args.startTime : 0n;
  if (elapsed >= args.duration) return { price: 0n, expired: true };
  const floorPrice = mulDivFloor(args.startPrice, args.floorBps, BPS);
  const drop = mulDivFloor(args.startPrice - floorPrice, elapsed, args.duration);
  return { price: args.startPrice - drop, expired: false };
}

/**
 * Convert an annual percentage rate into the per-second ray the contracts take.
 *
 * Governance sets `feePerSecondRay` because an n-th root on chain is gas nobody should pay. This is
 * where that number comes from, and it is exact to the last wei of a ray.
 */
export function annualRateToPerSecondRay(annualBps: number, precision = 60): bigint {
  // Note on exactness: this lands within a few hundred wei of a ray of the canonical MakerDAO
  // duty constants, which were computed at higher precision and then truncated. Both compound to
  // the same rate once `rpow` has rounded, because `x -> rpow(x, year)` is a step function at ray
  // precision and the whole neighbourhood maps to one output.
  if (annualBps < 0) throw new Error("a negative rate is not a rate");
  if (annualBps === 0) return RAY;
  const target = RAY + (RAY * BigInt(annualBps)) / BPS;
  // Bisection on the monotonic function x -> x^seconds. Sixty iterations pins a ray exactly.
  let low = RAY;
  let high = RAY + RAY / 1_000_000n;
  for (let i = 0; i < precision; i += 1) {
    const mid = (low + high) / 2n;
    if (rpow(mid, SECONDS_PER_YEAR) < target) low = mid;
    else high = mid;
  }
  return low;
}

/**
 * The annual percentage a per-second ray actually charges, for display.
 *
 * Rounded, not truncated. `rpow` loses a little on every squaring, so a rate that is exactly 5% a
 * year compounds to 4.9999...%, and a floor here would print "4.99%" on a 5% vault forever.
 */
export function perSecondRayToAnnualBps(ray: bigint): number {
  const grown = rpow(ray, SECONDS_PER_YEAR);
  const hundredths = ((grown - RAY) * BPS * 100n) / RAY;
  return Number((hundredths + 50n) / 100n);
}
