/** C0, DEL, C1, the Unicode line/paragraph separators and the bidi controls. */
const UNSAFE = new RegExp("[\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029\\u202a-\\u202e\\u2066-\\u2069]", "g");

/**
 * Make an untrusted string (an API status, a revert reason, an RPC error) safe
 * to embed in a log line: every control / line-separator character becomes a
 * space and the result is truncated, so a remote party cannot forge extra log
 * lines ("...\n✓ [route] filled ...") or flood the log.
 */
export function sanitize(s: unknown, max = 200): string {
  const clean = String(s).replace(UNSAFE, " ");
  return clean.length > max ? `${clean.slice(0, max)}...` : clean;
}
