import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";

import { ORDERBOOK_URL } from "../backend/book";
import { chainLabel } from "../config/chains";
import { PROMOTION, promotionRunsOn } from "../config/promotion";
import { fetchRaffleStatus, fetchRaffleSummary, participateView, type RaffleStatus, type TypedDataSigner } from "../lib/raffle";
import { GasZipLink, OnrampLink, UsdtLink } from "./Onramp";
import { ParticipateSheet } from "./Participate";
import { TermsLink } from "./TermsLink";

/** Re-read the desk this often while the page is open — a first fill unlocks Participate. */
const STATUS_REFRESH_MS = 30_000;

/**
 * What the promotion is, said plainly — and the one way into it.
 *
 * The distinction the copy has to hold is between a draw and a reward. Trading
 * qualifies an address for a random selection; it does not earn anything, and
 * no volume makes a prize more likely to land on you than on anyone else in the
 * same draw. Interfaces that blur this describe a rewards programme the terms
 * do not create — so "draw", "qualify" and "at random" are load-bearing words
 * here, not decoration.
 *
 * ENTRY (2026-10-20): the Participate control appears once the connected address
 * has a fill as maker (the orderbook's `/raffle/status`); it opens the feedback form,
 * whose signature is the entry. The worker enforces the same gate.
 */
export function RaffleNotice({
  chainId,
  address,
  signer,
  onConnect,
}: {
  chainId: number;
  address: Address | null;
  /** Null while the wallet is off the draw's chain. */
  signer: TypedDataSigner | null;
  onConnect: () => void;
}) {
  const runs = promotionRunsOn(chainId) && !!ORDERBOOK_URL;
  const [status, setStatus] = useState<RaffleStatus | null>(null);
  const [entrants, setEntrants] = useState<number | null>(null);
  const [open, setOpen] = useState(false);
  const [tick, setTick] = useState(0);
  const refresh = useCallback(() => setTick((n) => n + 1), []);

  useEffect(() => {
    if (!runs) return;
    const ctl = new AbortController();
    const read = () => {
      const base = ORDERBOOK_URL!;
      void fetchRaffleSummary(base, { signal: ctl.signal })
        .then((s) => {
          setEntrants(typeof s.feedback === "number" ? s.feedback : null);
          if (!address) setStatus(s as RaffleStatus);
        })
        .catch(() => {});
      if (address) void fetchRaffleStatus(base, address, { signal: ctl.signal }).then(setStatus).catch(() => {});
    };
    read();
    const id = setInterval(read, STATUS_REFRESH_MS);
    return () => {
      ctl.abort();
      clearInterval(id);
    };
  }, [runs, address, tick]);

  // The notice is fixed copy, switched by `VITE_PROMOTION` (`{"live":false}` hides it);
  // the orderbook only adds the optional feedback form.
  if (!promotionRunsOn(chainId)) return <OnrampLink />;
  const view = participateView(status, address);

  return (
    <aside className="raffle">
      <span className="pill pill-violet">Prize draw</span>
      <div className="rfbody">
        <p className="rflead">
          Trading on {chainLabel(PROMOTION.chainId)} puts your address in a <b>daily prize draw</b>, no sign-up needed.
          Roughly <b>{PROMOTION.qualifier}</b> of trading in a day counts; a draw is held on days with more than three
          participating addresses, and <b>{PROMOTION.pool}</b> is paid out over {PROMOTION.cadence}. After your first swap
          you can also <b>rate the app</b>: a minute of feedback, optional.
        </p>
        <div className="rfactions">
          {view.kind === "connect" && (
            <button type="button" className="cta line rfbtn" onClick={onConnect}>
              Connect wallet
            </button>
          )}
          {view.kind === "locked" && (
            <span className="rfstate">
              Trade once and you are in; the feedback form unlocks after that first swap.{" "}
              No funds on Rootstock? <UsdtLink>Bridge USD₮0 on usdt0.to</UsdtLink> (no RBTC needed) or <GasZipLink />.
            </span>
          )}
          {view.kind === "open" && (
            <button type="button" className="cta line rfbtn" onClick={() => setOpen(true)}>
              Rate the app
            </button>
          )}
          {view.kind === "entered" && (
            <span className="rfstate">
              <span className="good">✓ Thanks for the feedback.</span>{" "}
              <button type="button" className="linkbtn" onClick={() => setOpen(true)}>
                Update it
              </button>
            </span>
          )}
          {view.kind !== "locked" && (
            <span className="rfsupport">
              No funds on Rootstock? <UsdtLink>Bridge USD₮0</UsdtLink> · <GasZipLink>RBTC via Gas.zip</GasZipLink>
            </span>
          )}
          {entrants !== null && entrants > 0 && <span className="rfstate m">{entrants} rated the app</span>}
          {PROMOTION.support && (
            <a className="linkbtn rfsupport" href={PROMOTION.support} target="_blank" rel="noreferrer">
              Stuck? Report a problem
            </a>
          )}
        </div>
        <p className="rffine">
          Winners are picked <b>at random</b> from the day&rsquo;s qualifying addresses and announced by wallet address on
          the official channels. Trading qualifies you for a draw, it does not earn a prize, and no amount of volume
          guarantees one. Figures are approximate and the criteria,
          schedule and pool can change. Not open to U.S. Persons or persons in sanctioned jurisdictions, and USDRIF
          carries its own transfer restrictions. Winning addresses may be published.{" "}
          <TermsLink>Full Terms</TermsLink>
        </p>
      </div>
      {open && address && status?.promotion && ORDERBOOK_URL && (
        <ParticipateSheet
          base={ORDERBOOK_URL}
          signer={signer}
          chainId={PROMOTION.chainId}
          participant={address}
          promotion={status.promotion}
          updating={view.kind === "entered"}
          onClose={() => setOpen(false)}
          onEntered={refresh}
        />
      )}
    </aside>
  );
}
