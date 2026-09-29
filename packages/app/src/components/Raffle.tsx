import { chainLabel } from "../config/chains";
import { PROMOTION, promotionRunsOn } from "../config/promotion";
import { TermsLink } from "./TermsLink";

/**
 * What the promotion is, said plainly.
 *
 * The distinction the copy has to hold is between a draw and a reward. Trading
 * qualifies an address for a random selection; it does not earn anything, and
 * no volume makes a prize more likely to land on you than on anyone else in the
 * same draw. Interfaces that blur this describe a rewards programme the terms
 * do not create — so "draw", "qualify" and "at random" are load-bearing words
 * here, not decoration.
 */
export function RaffleNotice({ chainId }: { chainId: number }) {
  if (!promotionRunsOn(chainId)) return null;

  return (
    <aside className="raffle">
      <span className="pill pill-violet">Prize draw</span>
      <div className="rfbody">
        <p className="rflead">
          Trading on {chainLabel(PROMOTION.chainId)} can qualify your address for a daily prize draw. Addresses
          that trade at least <b>{PROMOTION.qualifier}</b> in a day go into that day&rsquo;s draw, and{" "}
          <b>{PROMOTION.pool}</b> is paid out over {PROMOTION.cadence}.
        </p>
        <p className="rffine">
          Winners are picked <b>at random</b> from the qualifying addresses — trading qualifies you for a draw, it
          does not earn a prize, and no amount of volume guarantees one. Figures are approximate and the criteria,
          schedule and pool can change. Not open to U.S. Persons or persons in sanctioned jurisdictions, and USDRIF
          carries its own transfer restrictions. Winning addresses may be published.{" "}
          <TermsLink>Full Terms</TermsLink>
        </p>
      </div>
    </aside>
  );
}
