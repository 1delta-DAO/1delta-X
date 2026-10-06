/**
 * Constant-time comparison of a presented secret with the expected one. Both are
 * hashed with SHA-256 first, so the comparison always runs over 32 bytes — it
 * leaks neither the position of the first difference nor the secret's length —
 * and the 32-byte compare itself is `crypto.subtle.timingSafeEqual` (workerd)
 * with an XOR-accumulate fallback.
 */
export async function safeEqual(presented: string, expected: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(presented)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
  const subtle = crypto.subtle as SubtleCrypto & { timingSafeEqual?: (x: ArrayBuffer, y: ArrayBuffer) => boolean };
  if (typeof subtle.timingSafeEqual === "function") return subtle.timingSafeEqual(a, b);
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i]! ^ y[i]!;
  return diff === 0;
}

/**
 * Whether `request` carries `Authorization: Bearer <token>` for the configured
 * ADMIN_TOKEN. No token configured = every admin request is refused.
 */
export async function isAdmin(request: Request, token: string | undefined): Promise<boolean> {
  const expected = token?.trim();
  if (!expected) return false;
  const header = request.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(header.trim());
  // Always run the compare (even on a malformed header) so the timing does not
  // tell a missing header from a wrong token.
  const ok = await safeEqual(m?.[1]?.trim() ?? "", expected);
  return ok && !!m;
}
