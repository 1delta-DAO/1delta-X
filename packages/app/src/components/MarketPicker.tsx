import { marketsOn } from "../config/markets";
import type { TokenIndex } from "../hooks/useTokenIndex";
import { PairIcon } from "./TokenIcon";

interface MarketPickerProps {
  chainId: number;
  selected: string;
  tokens: TokenIndex;
  onSelect: (id: string) => void;
}

export function MarketPicker({ chainId, selected, tokens, onSelect }: MarketPickerProps) {
  return (
    <div className="markets" role="tablist" aria-label="Markets">
      {marketsOn(chainId).map((m) => (
        <button
          key={m.id}
          type="button"
          role="tab"
          className="mkt"
          aria-selected={m.id === selected}
          onClick={() => onSelect(m.id)}
        >
          <PairIcon base={tokens.view(m.base)} quote={tokens.view(m.quote)} />
          <span>
            <span className="nm">
              {m.base} / {m.quote}
            </span>
            <br />
            <span className="sub">{m.venue}</span>
          </span>
        </button>
      ))}
    </div>
  );
}
