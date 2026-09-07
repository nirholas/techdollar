import {
  createPublicClient,
  http,
  type Address,
  type PublicClient,
  type WalletClient,
} from "viem";

import { liquidationauctionAbi, stockTokenAbi, vaultengineAbi } from "./abis.js";
import { PUBLIC_RPC_URLS, robinhoodChain } from "./chain.js";
import { auctionPrice, borrowCapacity, debtAt, healthFactor, liquidationPrice } from "./math.js";

/** Why a price is or is not usable, in the order `IPriceSource` declares them. */
export const PRICE_STATUS = [
  "OK",
  "NoConfig",
  "NoQuote",
  "QuoteStale",
  "TokenPaused",
  "IssuerOraclePaused",
  "TwapUnavailable",
  "TwapDeviation",
  "MultiplierTransition",
  "BasketDegraded",
] as const;
export type PriceStatusName = (typeof PRICE_STATUS)[number];

export interface Deployment {
  chainId: number;
  techd: Address;
  engine: Address;
  auction: Address;
  psm: Address;
  savings: Address;
  priceSource: Address;
}

export interface IlkConfig {
  rate: bigint;
  normalizedDebt: bigint;
  debtCeiling: bigint;
  dust: bigint;
  feePerSecondRay: bigint;
  lastAccrual: bigint;
  liquidationRatioBps: number;
  haltBufferBps: number;
  liquidationPenaltyBps: number;
  flagRewardBps: number;
  decimals: number;
  enabled: boolean;
  frozen: boolean;
}

export interface PositionView {
  collateral: Address;
  owner: Address;
  collateralAmount: bigint;
  debt: bigint;
  valueWad: bigint;
  priceOk: boolean;
  status: PriceStatusName;
  safe: boolean;
  halted: boolean;
  flaggedAt: bigint;
  healthFactor: bigint;
  /** USD per whole collateral unit at which this position becomes liquidatable. */
  liquidationPriceWad: bigint | null;
}

export interface AuctionView {
  id: bigint;
  collateral: Address;
  lot: bigint;
  tab: bigint;
  price: bigint;
  expired: boolean;
  halted: boolean;
  endsAt: bigint;
}

/**
 * Everything a borrower, a keeper or a dashboard needs to read.
 *
 * Reads go through the engine's own `inspect`, which never reverts on an unusable price: a keeper
 * has to be able to tell "this position is fine" from "I cannot see this position", and a view
 * that throws tells it neither.
 */
export class TechDollarClient {
  readonly publicClient: PublicClient;

  constructor(
    readonly deployment: Deployment,
    publicClient?: PublicClient,
  ) {
    this.publicClient =
      publicClient ??
      (createPublicClient({
        chain: robinhoodChain,
        transport: http(PUBLIC_RPC_URLS[0]),
        batch: { multicall: true },
      }) as PublicClient);
  }

  async collaterals(): Promise<Address[]> {
    const count = await this.publicClient.readContract({
      address: this.deployment.engine,
      abi: vaultengineAbi,
      functionName: "collateralCount",
    });
    const list: Address[] = [];
    for (let i = 0n; i < (count as bigint); i += 1n) {
      list.push(
        (await this.publicClient.readContract({
          address: this.deployment.engine,
          abi: vaultengineAbi,
          functionName: "collateralList",
          args: [i],
        })) as Address,
      );
    }
    return list;
  }

  async ilk(collateral: Address): Promise<IlkConfig> {
    const raw = (await this.publicClient.readContract({
      address: this.deployment.engine,
      abi: vaultengineAbi,
      functionName: "ilks",
      args: [collateral],
    })) as readonly unknown[];
    return {
      rate: raw[0] as bigint,
      normalizedDebt: raw[1] as bigint,
      debtCeiling: raw[2] as bigint,
      dust: raw[3] as bigint,
      feePerSecondRay: raw[4] as bigint,
      lastAccrual: BigInt(raw[5] as number | bigint),
      liquidationRatioBps: Number(raw[6]),
      haltBufferBps: Number(raw[7]),
      liquidationPenaltyBps: Number(raw[8]),
      flagRewardBps: Number(raw[9]),
      decimals: Number(raw[10]),
      enabled: Boolean(raw[11]),
      frozen: Boolean(raw[12]),
    };
  }

  async position(collateral: Address, owner: Address): Promise<PositionView> {
    const [inspect, ilk] = await Promise.all([
      this.publicClient.readContract({
        address: this.deployment.engine,
        abi: vaultengineAbi,
        functionName: "inspect",
        args: [collateral, owner],
      }) as Promise<readonly unknown[]>,
      this.ilk(collateral),
    ]);
    const requiredRatioBps = BigInt(ilk.liquidationRatioBps + ilk.haltBufferBps);
    const collateralAmount = inspect[0] as bigint;
    const debt = inspect[1] as bigint;
    const valueWad = inspect[2] as bigint;
    return {
      collateral,
      owner,
      collateralAmount,
      debt,
      valueWad,
      priceOk: inspect[3] as boolean,
      status: PRICE_STATUS[Number(inspect[4])] ?? "OK",
      safe: inspect[5] as boolean,
      halted: inspect[6] as boolean,
      flaggedAt: BigInt(inspect[7] as number | bigint),
      healthFactor: healthFactor(valueWad, debt, requiredRatioBps),
      liquidationPriceWad: liquidationPrice({
        debt,
        collateralAmount,
        collateralDecimals: ilk.decimals,
        requiredRatioBps,
      }),
    };
  }

  /** What a position could still borrow, after the ratio and both ceilings. */
  async maxMintable(collateral: Address, owner: Address): Promise<bigint> {
    return (await this.publicClient.readContract({
      address: this.deployment.engine,
      abi: vaultengineAbi,
      functionName: "maxMintable",
      args: [collateral, owner],
    })) as bigint;
  }

  /** Whether the issuer has frozen this equity right now. The first thing to check on any failure. */
  async isHalted(collateral: Address): Promise<{ paused: boolean; tokenPaused: boolean; oraclePaused: boolean }> {
    const [paused, tokenPaused, oraclePaused] = await Promise.all([
      this.publicClient.readContract({ address: collateral, abi: stockTokenAbi, functionName: "paused" }),
      this.publicClient.readContract({ address: collateral, abi: stockTokenAbi, functionName: "tokenPaused" }),
      this.publicClient.readContract({ address: collateral, abi: stockTokenAbi, functionName: "oraclePaused" }),
    ]);
    return {
      paused: paused as boolean,
      tokenPaused: tokenPaused as boolean,
      oraclePaused: oraclePaused as boolean,
    };
  }

  /**
   * A scheduled corporate action on this collateral, if there is one.
   *
   * Robinhood publishes the next multiplier and the second it takes effect, which means a split is
   * readable before it lands. The oracle blacks out across it, so a keeper that does not know one
   * is coming will read the blackout as an outage.
   */
  async corporateAction(collateral: Address): Promise<{ nextMultiplier: bigint; effectiveAt: bigint } | null> {
    const [nextMultiplier, effectiveAt] = await Promise.all([
      this.publicClient.readContract({ address: collateral, abi: stockTokenAbi, functionName: "newUIMultiplier" }),
      this.publicClient.readContract({ address: collateral, abi: stockTokenAbi, functionName: "effectiveAt" }),
    ]);
    if ((effectiveAt as bigint) === 0n) return null;
    return { nextMultiplier: nextMultiplier as bigint, effectiveAt: effectiveAt as bigint };
  }

  async auction(id: bigint, now = BigInt(Math.floor(Date.now() / 1000))): Promise<AuctionView> {
    const [raw, floorBps, duration] = await Promise.all([
      this.publicClient.readContract({
        address: this.deployment.auction,
        abi: liquidationauctionAbi,
        functionName: "inspect",
        args: [id],
      }) as Promise<readonly unknown[]>,
      this.publicClient.readContract({
        address: this.deployment.auction,
        abi: liquidationauctionAbi,
        functionName: "floorBps",
      }) as Promise<number>,
      this.publicClient.readContract({
        address: this.deployment.auction,
        abi: liquidationauctionAbi,
        functionName: "duration",
      }) as Promise<number>,
    ]);
    const endsAt = raw[6] as bigint;
    const startTime = endsAt - BigInt(duration);
    const { price, expired } = auctionPrice({
      startPrice: raw[3] as bigint,
      startTime,
      duration: BigInt(duration),
      floorBps: BigInt(floorBps),
      now,
    });
    return {
      id,
      collateral: raw[0] as Address,
      lot: raw[1] as bigint,
      tab: raw[2] as bigint,
      price: expired ? 0n : (raw[3] as bigint) === 0n ? price : (raw[3] as bigint),
      expired: raw[4] as boolean,
      halted: raw[5] as boolean,
      endsAt,
    };
  }

  async auctionCount(): Promise<bigint> {
    return (await this.publicClient.readContract({
      address: this.deployment.auction,
      abi: liquidationauctionAbi,
      functionName: "auctionCount",
    })) as bigint;
  }

  /** Debt a position will owe at `at`, without waiting for anyone to poke the accumulator. */
  projectDebt(position: { debt: bigint }, ilk: IlkConfig, at: bigint): bigint {
    return debtAt({
      normalizedDebt: position.debt,
      rate: ilk.rate,
      feePerSecondRay: ilk.feePerSecondRay,
      lastAccrual: ilk.lastAccrual,
      now: at,
    });
  }

  capacity(valueWad: bigint, ilk: IlkConfig): bigint {
    return borrowCapacity(valueWad, BigInt(ilk.liquidationRatioBps + ilk.haltBufferBps));
  }
}

export type { WalletClient };
