import { useMemo } from "react";
import { createWalletClient, custom, type Address } from "viem";

import { chainById } from "../config/chains";
import type { EIP1193Provider } from "./eip6963";

/** The SDK's `TypedDataSigner` surface — `signTypedData(params) => Promise<Hex>`. */
export interface Signer {
  signTypedData(parameters: never): Promise<`0x${string}`>;
}

/**
 * A viem wallet client over the connected EIP-6963 provider, ready to hand to
 * the SDK's `signOrder` / `signSoftCancel`.
 *
 * Null unless the wallet is on the market's chain. An EIP-712 signature carries
 * the chain id inside its domain, so signing while the wallet points elsewhere
 * produces a signature for a different deployment — valid, verifiable, and
 * unusable. Better to have no signer than a misaddressed one.
 */
export function useSigner(
  provider: EIP1193Provider | null,
  address: Address | null,
  chainId: number,
  onChain: boolean,
): Signer | null {
  return useMemo(() => {
    if (!provider || !address || !onChain) return null;
    const config = chainById(chainId);
    if (!config) return null;
    const client = createWalletClient({ account: address, chain: config.chain, transport: custom(provider) });
    return client as unknown as Signer;
  }, [provider, address, chainId, onChain]);
}
