/**
 * Where the terms live, and the link to them.
 *
 * Deliberately its own module, importing nothing: the trading app needs the
 * address of the document, not the document. Exporting this from the page that
 * holds the text would pull the whole of `TC.md` into the trading bundle for
 * the sake of an href.
 *
 * The path is relative so it resolves the same served from a domain root or a
 * sub-path — the reason `base` is `./` in the first place. Cloudflare Pages
 * also serves it at `/terms`, so either form can be announced.
 */
export const TERMS_HREF = "terms.html";

/** Always a new tab: reading the terms never interrupts a half-built order. */
export function TermsLink({ children }: { children: React.ReactNode }) {
  return (
    <a className="linkbtn" href={TERMS_HREF} target="_blank" rel="noreferrer">
      {children}
    </a>
  );
}
