import { parseDeployments, type DeploymentConfig } from "./deploymentConfig";

export { PULL_MODE, isPullMarket, parseDeployments, solverForMarket, type DeploymentConfig } from "./deploymentConfig";

const CONFIGURED = parseDeployments(import.meta.env.VITE_DEPLOYMENTS);

/**
 * The deployment for a chain, or `null` when none is configured.
 *
 * `null` is a first-class state, not an error: the order can still be built,
 * hashed and inspected — {@link hashOrderStruct} is domain-independent — it just
 * cannot be signed into anything a filler could use.
 */
export function deploymentFor(chainId: number): DeploymentConfig | null {
  return CONFIGURED[chainId] ?? null;
}

/** Every chain an address has been configured for — shown in the domain panel. */
export function configuredChains(): number[] {
  return Object.keys(CONFIGURED)
    .map(Number)
    .filter((id) => Number.isFinite(id) && deploymentFor(id) !== null);
}
