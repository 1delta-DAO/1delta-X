import type { ReactNode } from "react";

/**
 * THE ON-RAMP (2026-10-20): links out, nothing built in. USD₮0 is bridged on USDT0's
 * own app (usdt0.to, LayerZero, ~23 min to Rootstock), and RBTC for gas comes from
 * Gas.zip, which delivers native RBTC on Rootstock. Neither is needed together: USD₮0 on
 * Rootstock carries an ERC-2612 permit and the filler relays it, so a wallet with no
 * RBTC can already trade it — Gas.zip is for users who want gas of their own.
 *
 * Both are third-party sites; the app reads nothing from them (no CSP entry needed).
 */
export const USDT0_TRANSFER_URL = "https://usdt0.to/transfer";
export const GAS_ZIP_URL = "https://www.gas.zip/";

export function UsdtLink({ children = "Bring USD₮0 on usdt0.to" }: { children?: ReactNode }) {
  return (
    <a className="linkbtn" href={USDT0_TRANSFER_URL} target="_blank" rel="noreferrer">
      {children}
    </a>
  );
}

export function GasZipLink({ children = "get RBTC for gas on Gas.zip" }: { children?: ReactNode }) {
  return (
    <a className="linkbtn" href={GAS_ZIP_URL} target="_blank" rel="noreferrer">
      {children}
    </a>
  );
}

/** The on-ramp line shown when no prize-draw notice carries it. */
export function OnrampLink() {
  return (
    <p className="onramp">
      No funds on Rootstock? <UsdtLink>Bridge USD₮0 from Arbitrum, Ethereum, Polygon and more on usdt0.to</UsdtLink> (it
      trades with no RBTC needed) or <GasZipLink />.
    </p>
  );
}
