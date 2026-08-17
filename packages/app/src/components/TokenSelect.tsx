import { useEffect, useRef, useState } from "react";

import { fmtAmt } from "../lib/format";
import type { TokenIndex } from "../hooks/useTokenIndex";
import { TokenIcon } from "./TokenIcon";

interface TokenSelectProps {
  value: string;
  options: string[];
  tokens: TokenIndex;
  /** Balance per config symbol; missing means "not known", not zero. */
  balances: Record<string, number | undefined>;
  onChange: (symbol: string) => void;
  label: string;
}

export function TokenSelect({ value, options, tokens, balances, onChange, label }: TokenSelectProps) {
  const [open, setOpen] = useState(false);
  const wrap = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => {
      if (!wrap.current?.contains(e.target as Node)) setOpen(false);
    };
    const esc = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", esc);
    return () => {
      document.removeEventListener("mousedown", close);
      document.removeEventListener("keydown", esc);
    };
  }, [open]);

  return (
    <span className="tkwrap" ref={wrap}>
      <button
        type="button"
        className="tkbtn"
        aria-haspopup="true"
        aria-expanded={open}
        aria-label={label}
        onClick={() => setOpen((o) => !o)}
      >
        <TokenIcon {...tokens.view(value)} small />
        {value}
        <span className="car">▼</span>
      </button>
      {open && (
        <span className="tkmenu" role="menu">
          {options.map((symbol) => {
            const balance = balances[symbol];
            return (
              <button
                key={symbol}
                type="button"
                role="menuitem"
                disabled={symbol === value}
                onClick={() => {
                  setOpen(false);
                  onChange(symbol);
                }}
              >
                <TokenIcon {...tokens.view(symbol)} small />
                {symbol}
                <span className="b2">{balance === undefined ? "—" : fmtAmt(balance)}</span>
              </button>
            );
          })}
        </span>
      )}
    </span>
  );
}
