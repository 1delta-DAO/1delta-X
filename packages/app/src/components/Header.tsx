import { useEffect, useRef, useState } from "react";

import { CHAINS, chainLabel } from "../config/chains";
import { tradableChains } from "../config/markets";
import { shortHex } from "../lib/format";
import type { WalletState } from "../wallet/useWallet";

interface HeaderProps {
  chainId: number;
  onChainChange: (chainId: number) => void;
  wallet: WalletState;
  block: number | null;
  live: "live" | "stale" | "down";
  theme: "dark" | "light";
  onToggleTheme: () => void;
  /** Counter bumped elsewhere in the app to pop the wallet menu open. */
  requestConnect: number;
}

function useDismiss(open: boolean, close: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) close();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open, close]);
  return ref;
}

function ChainSelect({ chainId, onChange }: { chainId: number; onChange: (id: number) => void }) {
  const [open, setOpen] = useState(false);
  const ref = useDismiss(open, () => setOpen(false));
  const options = tradableChains();

  return (
    <div className="menu" ref={ref}>
      <button type="button" className="netpill" aria-haspopup="true" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        <i className="dot" />
        {chainLabel(chainId)}
        <span className="car">▼</span>
      </button>
      {open && (
        <div className="dropdown" role="menu">
          {options.map((id) => (
            <button
              key={id}
              type="button"
              role="menuitem"
              aria-selected={id === chainId}
              onClick={() => {
                setOpen(false);
                onChange(id);
              }}
            >
              {chainLabel(id)}
              <span className="b2">{CHAINS.find((c) => c.chainId === id)?.oku}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function Connect({
  wallet,
  chainId,
  requestOpen,
}: {
  wallet: WalletState;
  chainId: number;
  /** Bumped by the order form's "Connect wallet" gate to open this menu. */
  requestOpen: number;
}) {
  const [open, setOpen] = useState(false);
  const ref = useDismiss(open, () => setOpen(false));

  useEffect(() => {
    if (requestOpen > 0 && !wallet.address) setOpen(true);
  }, [requestOpen, wallet.address]);

  if (wallet.address) {
    const wrongChain = wallet.chainId !== chainId;
    return (
      <div className="menu" ref={ref}>
        <button
          type="button"
          className={`netpill${wrongChain ? " warnpill" : ""}`}
          aria-haspopup="true"
          aria-expanded={open}
          onClick={() => setOpen((o) => !o)}
        >
          <i className="dot" data-live={wrongChain ? "stale" : "live"} />
          {wrongChain ? `Wrong network · ${shortHex(wallet.address, 6, 4)}` : shortHex(wallet.address, 6, 4)}
          <span className="car">▼</span>
        </button>
        {open && (
          <div className="dropdown" role="menu">
            {wrongChain && (
              <button
                type="button"
                role="menuitem"
                onClick={() => {
                  setOpen(false);
                  void wallet.switchChain(chainId);
                }}
              >
                Switch to {chainLabel(chainId)}
              </button>
            )}
            <button
              type="button"
              role="menuitem"
              onClick={() => {
                setOpen(false);
                wallet.disconnect();
              }}
            >
              Disconnect
            </button>
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="menu" ref={ref}>
      <button
        type="button"
        className="netpill accent"
        aria-haspopup="true"
        aria-expanded={open}
        disabled={wallet.connecting}
        onClick={() => setOpen((o) => !o)}
      >
        {wallet.connecting ? "Connecting…" : "Connect wallet"}
      </button>
      {open && (
        <div className="dropdown" role="menu">
          {wallet.providers.length === 0 ? (
            // EIP-6963 discovery only sees wallets that announce themselves;
            // saying so beats an empty menu that looks broken.
            <p className="dropnote">No EIP-6963 wallet detected in this browser.</p>
          ) : (
            wallet.providers.map((p) => (
              <button
                key={p.info.uuid}
                type="button"
                role="menuitem"
                onClick={() => {
                  setOpen(false);
                  void wallet.connect(p.info.rdns);
                }}
              >
                <img className="tok-ico sm img" src={p.info.icon} alt="" aria-hidden="true" />
                {p.info.name}
              </button>
            ))
          )}
          {wallet.error && <p className="dropnote err">{wallet.error}</p>}
        </div>
      )}
    </div>
  );
}

export function Header(props: HeaderProps) {
  const { chainId, onChainChange, wallet, block, live, theme, onToggleTheme, requestConnect } = props;
  return (
    <div className="nav">
      <div className="brand">
        1delta X <em>Intents</em>
      </div>
      <span className="blockpill m" title="Latest block the depth feed has seen">
        <i className="dot" data-live={live} />
        {block === null ? "syncing" : block.toLocaleString("en-US")}
      </span>
      <div className="navspace" />
      <ChainSelect chainId={chainId} onChange={onChainChange} />
      <Connect wallet={wallet} chainId={chainId} requestOpen={requestConnect} />
      <button
        type="button"
        className="iconbtn"
        onClick={onToggleTheme}
        aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}
      >
        {theme === "dark" ? "☀" : "☾"}
      </button>
    </div>
  );
}
