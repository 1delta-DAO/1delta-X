/**
 * EIP-6963 wallet discovery.
 *
 * The standard replaces the `window.ethereum` scramble: every installed wallet
 * announces itself, so several can coexist and the user picks. There is no
 * connector library here on purpose — discovery is an event listener, and a
 * connection is `eth_requestAccounts` on the provider that announced.
 */

export interface EIP1193Provider {
  request(args: { method: string; params?: unknown[] | object }): Promise<unknown>;
  on?(event: string, listener: (...args: never[]) => void): void;
  removeListener?(event: string, listener: (...args: never[]) => void): void;
}

export interface ProviderInfo {
  uuid: string;
  name: string;
  icon: string;
  rdns: string;
}

export interface ProviderDetail {
  info: ProviderInfo;
  provider: EIP1193Provider;
}

const detected = new Map<string, ProviderDetail>();
const listeners = new Set<() => void>();
let snapshot: ProviderDetail[] = [];

function announce(event: Event): void {
  const detail = (event as CustomEvent<ProviderDetail>).detail;
  if (!detail?.info?.rdns || detected.has(detail.info.rdns)) return;
  detected.set(detail.info.rdns, detail);
  snapshot = [...detected.values()];
  for (const l of listeners) l();
}

if (typeof window !== "undefined") {
  window.addEventListener("eip6963:announceProvider", announce);
  window.dispatchEvent(new Event("eip6963:requestProvider"));
}

export function subscribeProviders(listener: () => void): () => void {
  listeners.add(listener);
  // Wallets injected after first paint only announce on request, so ask again.
  if (typeof window !== "undefined") window.dispatchEvent(new Event("eip6963:requestProvider"));
  return () => listeners.delete(listener);
}

export function getProviders(): ProviderDetail[] {
  return snapshot;
}

export function providerByRdns(rdns: string): ProviderDetail | undefined {
  return detected.get(rdns);
}
