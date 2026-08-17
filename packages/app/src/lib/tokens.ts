/**
 * Token identity from the 1delta token lists.
 *
 * https://github.com/1delta-DAO/token-lists ships one `{chainId}.json` per
 * chain, keyed by lowercase address. It is the source for display symbol,
 * decimals and logo — Oku knows the pool's tokens but labels wrapped assets
 * loosely (WETH comes back as "ETH"), and it carries no icons at all.
 *
 * The lists are large (Ethereum is ~6 MB raw). They are therefore fetched
 * lazily, off the render path, and only the handful of tokens the app actually
 * references is kept — persisted so a reload does not re-download megabytes to
 * learn the same six symbols.
 */

export interface TokenMeta {
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  logoURI?: string;
  native?: boolean;
}

interface ListEntry {
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  logoURI?: string;
  props?: { isNative?: boolean };
}

interface TokenList {
  chainId: string;
  version: string;
  list: Record<string, ListEntry>;
}

const CDN = "https://cdn.jsdelivr.net/gh/1delta-DAO/token-lists@main";
const CACHE_KEY = "1delta-x.tokens.v1";

const resolved = new Map<string, TokenMeta>();
const listeners = new Set<() => void>();
const inFlight = new Map<number, Promise<void>>();
/**
 * Addresses already looked up in a chain's list, so a token the list genuinely
 * does not carry is not re-fetched on every render. Tracked per address rather
 * than per chain: a later call naming an address this chain has never been
 * asked about is a real miss and deserves one more attempt.
 */
const attempted = new Map<number, Set<string>>();

function attemptedOn(chainId: number): Set<string> {
  let set = attempted.get(chainId);
  if (!set) {
    set = new Set();
    attempted.set(chainId, set);
  }
  return set;
}

function key(chainId: number, address: string): string {
  return `${chainId}:${address.toLowerCase()}`;
}

function hydrate(): void {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (!raw) return;
    for (const [k, v] of Object.entries(JSON.parse(raw) as Record<string, TokenMeta>)) {
      resolved.set(k, v);
    }
  } catch {
    // A corrupt cache is not worth a broken app; the lists will repopulate it.
  }
}
hydrate();

function persist(): void {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify(Object.fromEntries(resolved)));
  } catch {
    // Quota or private mode — the in-memory map still serves this session.
  }
}

function emit(): void {
  for (const l of listeners) l();
}

export function subscribeTokens(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function tokenMeta(chainId: number, address: string): TokenMeta | undefined {
  return resolved.get(key(chainId, address));
}

async function loadList(chainId: number, addresses: string[]): Promise<void> {
  const res = await fetch(`${CDN}/${chainId}.json`);
  if (!res.ok) throw new Error(`token list ${chainId}: HTTP ${res.status}`);
  const list = (await res.json()) as TokenList;
  const seen = attemptedOn(chainId);

  let added = false;
  for (const address of addresses) {
    seen.add(address.toLowerCase());
    const entry = list.list?.[address.toLowerCase()];
    if (!entry) continue;
    resolved.set(key(chainId, address), {
      address: address.toLowerCase(),
      symbol: entry.symbol,
      name: entry.name,
      decimals: entry.decimals,
      logoURI: entry.logoURI,
      native: entry.props?.isNative,
    });
    added = true;
  }
  if (added) {
    persist();
    emit();
  }
}

/**
 * Make sure these addresses are resolved. Failure is silent by design: the UI
 * falls back to a generated mark and the symbol Oku reported, which is
 * worse-looking but never broken.
 */
export function ensureTokens(chainId: number, addresses: string[]): void {
  if (inFlight.has(chainId)) return;
  const seen = attemptedOn(chainId);
  const wanted = addresses.filter(
    (a) => a && !resolved.has(key(chainId, a)) && !seen.has(a.toLowerCase()),
  );
  if (!wanted.length) return;

  const task = loadList(chainId, addresses)
    .catch(() => {
      // Allow a later attempt — a failed fetch must not poison these addresses
      // forever, so nothing about them is remembered.
      for (const a of addresses) seen.delete(a.toLowerCase());
    })
    .finally(() => {
      inFlight.delete(chainId);
    });
  inFlight.set(chainId, task);
}
