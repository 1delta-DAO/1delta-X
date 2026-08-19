import type { Deployment } from "@1delta-x/sdk";
import { zeroAddress, type Address } from "viem";

/**
 * Where UniversalSettlement lives, per chain.
 *
 * An order signature is bound to the EIP-712 domain — `chainId` plus the
 * Settlement address — so this is not cosmetic: sign against the wrong
 * `verifyingContract` and the signature is valid, verifiable, and useless.
 * Nothing is deployed yet, so addresses come from one environment variable and
 * default to unset rather than to a plausible-looking constant.
 *
 *   VITE_DEPLOYMENTS='{"31":{"settlement":"0x…","permit3":"0x…","lens":"0x…"}}'
 */
export interface DeploymentConfig extends Deployment {
  /** Read-only companion — `getOrderRelevantStates` is the orderbook's Layer 2. */
  lens: Address;
}

type RawDeployments = Record<string, Partial<Omit<DeploymentConfig, "chainId">>>;

function parse(): RawDeployments {
  const raw = import.meta.env.VITE_DEPLOYMENTS;
  if (!raw) return {};
  try {
    return JSON.parse(raw) as RawDeployments;
  } catch {
    // A malformed override must not take the app down; it degrades to "not
    // deployed", which the UI already has an honest state for.
    console.warn("VITE_DEPLOYMENTS is not valid JSON — ignoring");
    return {};
  }
}

const CONFIGURED = parse();

/**
 * The deployment for a chain, or `null` when none is configured.
 *
 * `null` is a first-class state, not an error: the order can still be built,
 * hashed and inspected — {@link hashOrderStruct} is domain-independent — it just
 * cannot be signed into anything a filler could use.
 */
export function deploymentFor(chainId: number): DeploymentConfig | null {
  const entry = CONFIGURED[String(chainId)];
  if (!entry?.settlement) return null;
  return {
    chainId,
    settlement: entry.settlement,
    permit3: entry.permit3 ?? zeroAddress,
    lens: entry.lens ?? zeroAddress,
  };
}

/** Every chain an address has been configured for — shown in the domain panel. */
export function configuredChains(): number[] {
  return Object.keys(CONFIGURED)
    .map(Number)
    .filter((id) => Number.isFinite(id) && deploymentFor(id) !== null);
}
