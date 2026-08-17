import { useState } from "react";

import { symbolHue } from "../lib/format";

export interface TokenIconProps {
  symbol: string;
  logoURI?: string;
  small?: boolean;
}

/**
 * The token's own logo from the 1delta token lists, with a generated mark
 * underneath it. The fallback is not just for missing logos: it renders on the
 * first frame, before the list has loaded, and when a logo host 404s — so a
 * market never appears without an icon.
 */
export function TokenIcon({ symbol, logoURI, small }: TokenIconProps) {
  const [broken, setBroken] = useState(false);
  const className = `tok-ico${small ? " sm" : ""}`;

  if (logoURI && !broken) {
    return (
      <img
        className={`${className} img`}
        src={logoURI}
        alt=""
        loading="lazy"
        aria-hidden="true"
        onError={() => setBroken(true)}
      />
    );
  }

  return (
    <span
      className={className}
      style={{ background: `hsl(${symbolHue(symbol)} 72% 62%)` }}
      aria-hidden="true"
    >
      {symbol.slice(0, small ? 1 : 2).toUpperCase()}
    </span>
  );
}

export function PairIcon({
  base,
  quote,
  small,
}: {
  base: TokenIconProps;
  quote: TokenIconProps;
  small?: boolean;
}) {
  return (
    <span className="pair-ico">
      <TokenIcon {...base} small={small} />
      <TokenIcon {...quote} small={small} />
    </span>
  );
}
