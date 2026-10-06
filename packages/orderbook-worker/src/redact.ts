/**
 * Strip a (possibly secret, API-key-bearing) RPC URL from text that leaves the
 * worker (`/health`'s `lastError`). The exact URL, its origin + path and its host
 * are replaced — a provider error can quote any of them.
 */
export function redactRpcUrl(text: string, rpcUrl: string): string {
  if (!rpcUrl) return text;
  let out = text.split(rpcUrl).join("<RPC_URL>");
  try {
    const u = new URL(rpcUrl);
    if (u.pathname.length > 1 || u.search) out = out.split(`${u.origin}${u.pathname}`).join("<RPC_URL>");
    out = out.split(u.host).join("<rpc-host>");
  } catch {
    // not a URL: the exact-string replacement above is all we can do
  }
  return out;
}

/** JSON-RPC "method not found" (-32601) / "method not supported" (-32004), anywhere in an error's cause chain. */
export function isMethodNotFound(err: unknown): boolean {
  let cur = err as { code?: unknown; cause?: unknown; message?: unknown; details?: unknown } | undefined;
  for (let i = 0; cur && i < 8; i++) {
    if (cur.code === -32601 || cur.code === -32004) return true;
    const text = `${typeof cur.message === "string" ? cur.message : ""} ${typeof cur.details === "string" ? cur.details : ""}`;
    if (/does not exist\s*\/\s*is not available|method not found|method [^ ]* ?(is )?not supported/i.test(text)) return true;
    cur = cur.cause as typeof cur;
  }
  return false;
}
