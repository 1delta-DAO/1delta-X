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
/**
 * v2: entries carry the time they were saved and age out. The v1 cache never
 * expired, so one poisoned list response outlived any upstream fix for as long
 * as the browser kept its storage (G-TS_SIGN-1). Bumping the key also drops
 * every v1 entry on the next load.
 */
const CACHE_KEY = "1delta-x.tokens.v2";
/** How long a cached list entry is trusted before it is fetched again. */
export const TOKEN_CACHE_TTL_MS = 3 * 24 * 3600_000;

interface CacheFile {
  savedAt: number;
  entries: Record<string, TokenMeta>;
}

/**
 * The entries of a persisted cache that are still fresh, or none.
 *
 * Exposed for tests. Anything malformed, from the old unversioned format, or
 * older than {@link TOKEN_CACHE_TTL_MS} reads as empty — the list is then
 * fetched again, which costs a download and never a wrong logo.
 */
export function parseTokenCache(raw: string | null, now: number): Record<string, TokenMeta> {
  if (!raw) return {};
  try {
    const file = JSON.parse(raw) as Partial<CacheFile>;
    if (typeof file.savedAt !== "number" || !file.entries || typeof file.entries !== "object") return {};
    if (now - file.savedAt > TOKEN_CACHE_TTL_MS || file.savedAt > now) return {};
    return file.entries;
  } catch {
    return {};
  }
}

const resolved = new Map<string, TokenMeta>();
const listeners = new Set<() => void>();
/** One in-flight download per chain, shared by every request that arrives while it runs. */
const inFlight = new Map<number, Promise<Record<string, ListEntry> | null>>();
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

/**
 * When the persisted entries were first fetched this session. Kept fixed while
 * the tab lives, so re-persisting does not keep refreshing the age of entries
 * that were hydrated from an older save.
 */
let savedAt: number | undefined;

function hydrate(): void {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    const entries = Object.entries(parseTokenCache(raw, Date.now()));
    for (const [k, v] of entries) resolved.set(k, v);
    // Hydrated entries keep their ORIGINAL age: re-saving them must not reset it.
    if (entries.length) savedAt = (JSON.parse(raw!) as CacheFile).savedAt;
  } catch {
    // A corrupt cache is not worth a broken app; the lists will repopulate it.
  }
}
hydrate();

function persist(): void {
  try {
    const file: CacheFile = { savedAt: savedAt ?? (savedAt = Date.now()), entries: Object.fromEntries(resolved) };
    localStorage.setItem(CACHE_KEY, JSON.stringify(file));
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

/** Download and parse a chain's list. Resolves nothing on its own. */
async function loadList(chainId: number): Promise<Record<string, ListEntry>> {
  const res = await fetch(`${CDN}/${chainId}.json`);
  if (!res.ok) throw new Error(`token list ${chainId}: HTTP ${res.status}`);
  const list = (await res.json()) as TokenList;
  return list.list ?? {};
}

/** Pull the requested addresses out of an already-fetched list. */
function apply(chainId: number, list: Record<string, ListEntry>, addresses: string[]): void {
  const seen = attemptedOn(chainId);
  let added = false;
  for (const address of addresses) {
    const lower = address.toLowerCase();
    seen.add(lower);
    const entry = list[lower];
    if (!entry) continue;
    resolved.set(key(chainId, address), {
      address: lower,
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
 * Make sure these addresses are resolved.
 *
 * Callers arrive in waves — the chain's markets resolve one at a time, each
 * naming a few more tokens — so a request that lands while the list is already
 * downloading JOINS that download instead of being dropped. Dropping it was a
 * real bug: the first market's two tokens got logos and every later one was
 * silently abandoned, because the in-flight guard returned early and nothing
 * ever retried.
 *
 * Failure is silent by design: the UI falls back to a generated mark and the
 * symbol the indexer reported, which is worse-looking but never broken.
 */
export function ensureTokens(chainId: number, addresses: string[]): void {
  const seen = attemptedOn(chainId);
  const wanted = addresses.filter((a) => a && !resolved.has(key(chainId, a)) && !seen.has(a.toLowerCase()));
  if (!wanted.length) return;

  let task = inFlight.get(chainId);
  if (!task) {
    task = loadList(chainId)
      .catch(() => null)
      .finally(() => inFlight.delete(chainId));
    inFlight.set(chainId, task);
  }
  // Whether this call started the download or joined one, it resolves ITS OWN
  // addresses when the list lands.
  void task.then((list) => {
    if (list) apply(chainId, list, wanted);
    // A failed fetch remembers nothing, so a later attempt can still succeed.
  });
}
