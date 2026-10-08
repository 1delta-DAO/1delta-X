import { useEffect, useMemo, useState } from "react";
import { createPublicClient, custom } from "viem";

import { chainById } from "../config/chains";
import type { DeploymentConfig } from "../config/deploymentConfig";
import { marketById } from "../config/markets";
import { readGasPrice } from "../lib/chain";
import { FILLER_GAS_PRICE_MIN_MULT_BPS, FLOOR_PROFILES, floorInputsFor, type FloorInputs } from "../lib/marketFloor";
import { fetchPoolBook } from "../lib/poolbook";
import type { Side } from "../lib/types";
import type { EIP1193Provider } from "../wallet/eip6963";

/** Gas price moves slowly on Rootstock; once per block is plenty. */
const GAS_POLL_MS = 30_000;
/** The native's USD price only converts ~$0.60 of gas; a minute-old mid is fine. */
const NATIVE_POLL_MS = 60_000;

/**
 * The filler's live send gas price (latest block `minimumGasPrice` × 1.03, see
 * lib/chain.ts `readGasPrice`) over the wallet's provider — the app's only chain
 * client — while the wallet is on `chainId`. `null` otherwise or on failure (the floor
 * then uses the chain's fallback price).
 */
function useGasPrice(provider: EIP1193Provider | null | undefined, chainId: number, onChain: boolean): bigint | null {
  const [wei, setWei] = useState<{ chainId: number; wei: bigint | null }>({ chainId, wei: null });
  useEffect(() => {
    const config = chainById(chainId);
    if (!provider || !onChain || !config || !FLOOR_PROFILES[chainId]) return;
    let alive = true;
    const client = createPublicClient({ chain: config.chain, transport: custom(provider) });
    const load = async () => {
      const v = await readGasPrice(client, FILLER_GAS_PRICE_MIN_MULT_BPS);
      if (alive) setWei({ chainId, wei: v });
    };
    void load();
    const t = setInterval(() => void load(), GAS_POLL_MS);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [provider, chainId, onChain]);
  return onChain && wei.chainId === chainId ? wei.wei : null;
}

/**
 * USD per native: the mid of the chain's native/USD market. When that market is
 * the one on screen its live mid is reused; otherwise the app fetches that market's
 * book once a minute (the same Oku/Sushi path the ladder uses).
 */
function useNativeUsd(chainId: number, marketId: string, mid: number | null): number | null {
  const ref = FLOOR_PROFILES[chainId]?.nativeUsdMarket;
  const onRef = ref === marketId;
  const [fetched, setFetched] = useState<{ ref: string; mid: number } | null>(null);
  useEffect(() => {
    if (!ref || onRef) return;
    const config = chainById(chainId);
    if (!config) return;
    const controller = new AbortController();
    const load = async () => {
      try {
        const { book } = await fetchPoolBook({ market: marketById(ref), chain: config, signal: controller.signal });
        if (!controller.signal.aborted) setFetched({ ref, mid: book.mid });
      } catch {
        // Keep the last good mid; with none, the floor waits (refuses) rather than guesses.
      }
    };
    void load();
    const t = setInterval(() => void load(), NATIVE_POLL_MS);
    return () => {
      controller.abort();
      clearInterval(t);
    };
  }, [chainId, ref, onRef]);
  if (onRef) return mid;
  return fetched && fetched.ref === ref ? fetched.mid : null;
}

/**
 * The gas-sizing inputs of the current market ticket's floor (lib/marketFloor.ts),
 * or `undefined` on a chain no filler runs on (the flat MARKET_SLIPPAGE_BPS floor).
 */
export function useMarketFloorInputs(a: {
  provider: EIP1193Provider | null | undefined;
  chainId: number;
  onChain: boolean;
  marketId: string;
  side: Side;
  deployment: DeploymentConfig | null;
  mid: number | null;
}): FloorInputs | undefined {
  const gasPriceWei = useGasPrice(a.provider, a.chainId, a.onChain);
  const nativeUsd = useNativeUsd(a.chainId, a.marketId, a.mid);
  const { chainId, marketId, side, deployment, mid } = a;
  return useMemo(
    () => floorInputsFor({ chainId, marketId, side, deployment, gasPriceWei, mid, nativeUsd }),
    [chainId, marketId, side, deployment, gasPriceWei, mid, nativeUsd],
  );
}
