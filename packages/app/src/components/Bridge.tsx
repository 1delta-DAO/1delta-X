import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createPublicClient, createWalletClient, custom, erc20Abi, formatUnits, http, numberToHex, parseUnits, type Address, type Hex } from "viem";
import { rootstock } from "viem/chains";

import { BRIDGE_SOURCES, layerZeroScanTx, ROOTSTOCK_USDT0, sourceRpc, SUGGESTED_MAX_USD, USDT0_APP_URL, type BridgeSource } from "../config/bridge";
import { approveForBridge, arrived, quoteBridge, sendToRootstock, type BridgeClient, type BridgeQuote } from "../lib/bridge";
import type { EIP1193Provider } from "../wallet/eip6963";

/** Rootstock is polled this often for the USD₮0 to land (the wallet is on the source chain meanwhile). */
const ARRIVAL_POLL_MS = 10_000;
/** Past this, the panel stops saying "usually under 3 minutes" and points at LayerZero Scan. */
const SLOW_AFTER_MS = 10 * 60_000;

type Phase =
  | { kind: "pick" }
  | { kind: "quoting" }
  | { kind: "ready"; quote: BridgeQuote }
  | { kind: "approving"; quote: BridgeQuote }
  | { kind: "sending"; quote: BridgeQuote }
  | { kind: "sent"; quote: BridgeQuote; tx: Hex; before: bigint; at: number }
  | { kind: "arrived"; tx: Hex; amount: bigint };

const rsk = createPublicClient({ chain: rootstock, transport: http(undefined, { retryCount: 1, timeout: 15_000 }) });

function rootstockUsdt0(owner: Address): Promise<bigint> {
  return rsk.readContract({ address: ROOTSTOCK_USDT0.token, abi: erc20Abi, functionName: "balanceOf", args: [owner] });
}

async function switchTo(provider: EIP1193Provider, src: BridgeSource): Promise<void> {
  const chainId = numberToHex(src.chain.id);
  try {
    await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] });
  } catch (e) {
    const code = (e as { code?: number }).code;
    if (code !== 4902 && code !== -32603) throw e;
    await provider.request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId,
          chainName: src.chain.name,
          nativeCurrency: src.chain.nativeCurrency,
          rpcUrls: [sourceRpc(src)],
          blockExplorerUrls: src.chain.blockExplorers ? [src.chain.blockExplorers.default.url] : undefined,
        },
      ],
    });
  }
}

function clientFor(provider: EIP1193Provider, src: BridgeSource, owner: Address): BridgeClient & { native(): Promise<bigint> } {
  const pub = createPublicClient({ chain: src.chain, transport: custom(provider) });
  const wal = createWalletClient({ account: owner, chain: src.chain, transport: custom(provider) });
  return {
    read: (a) => pub.readContract(a as never) as never,
    write: (a) => wal.writeContract({ ...(a as object), account: owner, chain: src.chain } as never),
    waitForReceipt: (hash) => pub.waitForTransactionReceipt({ hash }),
    native: () => pub.getBalance({ address: owner }),
  };
}

const fmt = (wei: bigint, decimals: number, max = 6) => Number(formatUnits(wei, decimals)).toLocaleString("en-US", { maximumFractionDigits: max });

function message(e: unknown): string {
  const m = e instanceof Error ? e.message : String(e);
  if (/rejected|denied/i.test(m)) return "You declined in your wallet — nothing was sent.";
  return m.split("\n")[0]!;
}

/**
 * THE USD₮0 ON-RAMP: bridge USDT0 from another chain to your own address on Rootstock.
 * Every step goes through the wallet's provider on the SOURCE chain (balance, quote,
 * approval where the OFT needs one, send); only the arrival check reads Rootstock's
 * public node. The recipient is always the connected address — there is no field for
 * another one.
 */
export function BridgeSheet({
  provider,
  address,
  walletChainId,
  onSwitchHome,
  onClose,
}: {
  provider: EIP1193Provider | null;
  address: Address | null;
  walletChainId: number | null;
  /** Switch the wallet back to Rootstock (App's `wallet.switchChain(30)`). */
  onSwitchHome: () => void;
  onClose: () => void;
}) {
  const [srcKey, setSrcKey] = useState(BRIDGE_SOURCES[0]!.key);
  const src = useMemo(() => BRIDGE_SOURCES.find((s) => s.key === srcKey)!, [srcKey]);
  const [amount, setAmount] = useState("");
  const [phase, setPhase] = useState<Phase>({ kind: "pick" });
  const [error, setError] = useState<string | null>(null);
  const [balance, setBalance] = useState<bigint | null>(null);
  const [native, setNative] = useState<bigint | null>(null);
  const [slow, setSlow] = useState(false);
  const alive = useRef(true);
  useEffect(() => () => void (alive.current = false), []);

  const onSource = walletChainId === src.chain.id;
  const busy = phase.kind === "quoting" || phase.kind === "approving" || phase.kind === "sending";

  useEffect(() => {
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && !busy && onClose();
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = previous;
    };
  }, [busy, onClose]);

  // A new source chain or amount invalidates any quote.
  useEffect(() => {
    if (phase.kind === "ready") setPhase({ kind: "pick" });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [srcKey, amount]);

  // Balances on the source chain, once the wallet is there.
  useEffect(() => {
    setBalance(null);
    setNative(null);
    if (!provider || !address || !onSource) return;
    const c = clientFor(provider, src, address);
    void c.read<bigint>({ address: src.token, abi: erc20Abi, functionName: "balanceOf", args: [address] }).then((b) => alive.current && setBalance(b)).catch(() => {});
    void c.native().then((b) => alive.current && setNative(b)).catch(() => {});
  }, [provider, address, onSource, src, phase.kind]);

  // Arrival: poll Rootstock until the balance rose by the minimum.
  useEffect(() => {
    if (phase.kind !== "sent" || !address) return;
    const p = phase;
    const id = setInterval(() => {
      if (Date.now() - p.at > SLOW_AFTER_MS) setSlow(true);
      void rootstockUsdt0(address)
        .then((now) => {
          if (alive.current && arrived(p.before, now, p.quote.minAmountLD)) setPhase({ kind: "arrived", tx: p.tx, amount: now - p.before });
        })
        .catch(() => {});
    }, ARRIVAL_POLL_MS);
    return () => clearInterval(id);
  }, [phase, address]);

  const amountLD = useMemo(() => {
    try {
      const v = parseUnits(amount.trim() || "0", src.decimals);
      return v > 0n ? v : null;
    } catch {
      return null;
    }
  }, [amount, src.decimals]);

  const doSwitch = useCallback(async () => {
    if (!provider) return;
    setError(null);
    try {
      await switchTo(provider, src);
    } catch (e) {
      setError(message(e));
    }
  }, [provider, src]);

  const doQuote = useCallback(async () => {
    if (!provider || !address || !amountLD) return;
    setError(null);
    setPhase({ kind: "quoting" });
    try {
      const quote = await quoteBridge(clientFor(provider, src, address), src, address, amountLD);
      if (quote.balance < amountLD) throw new Error(`you hold ${fmt(quote.balance, src.decimals)} ${src.symbol} on ${src.label}`);
      if (alive.current) setPhase({ kind: "ready", quote });
    } catch (e) {
      if (alive.current) {
        setError(message(e));
        setPhase({ kind: "pick" });
      }
    }
  }, [provider, address, amountLD, src]);

  const doSend = useCallback(async () => {
    if (!provider || !address || phase.kind !== "ready") return;
    const quote = phase.quote;
    const c = clientFor(provider, src, address);
    setError(null);
    try {
      if (quote.approvalRequired && quote.allowance < quote.amountLD) {
        setPhase({ kind: "approving", quote });
        await approveForBridge(c, src, quote);
      }
      setPhase({ kind: "sending", quote });
      const before = await rootstockUsdt0(address).catch(() => null);
      if (before === null) throw new Error("could not read your Rootstock balance — try again in a moment");
      const tx = await sendToRootstock(c, src, address, quote);
      if (alive.current) setPhase({ kind: "sent", quote, tx, before, at: Date.now() });
      const r = await c.waitForReceipt(tx);
      if (r.status !== "success" && alive.current) {
        setError("the bridge transaction reverted on the source chain — nothing was sent");
        setPhase({ kind: "pick" });
      }
    } catch (e) {
      if (alive.current) {
        setError(message(e));
        setPhase({ kind: "pick" });
      }
    }
  }, [provider, address, phase, src]);

  const nativeSym = src.chain.nativeCurrency.symbol;
  const feeShort = phase.kind === "ready" && native !== null && native < phase.quote.nativeFee;

  return (
    <div className="scrim" onMouseDown={(e) => !busy && e.target === e.currentTarget && onClose()}>
      <div className="sheet narrow" role="dialog" aria-modal="true" aria-labelledby="bridge-title">
        <div className="sheethead">
          <span className="lbl">Bring USD₮0 to Rootstock</span>
          <button type="button" className="iconbtn" onClick={onClose} aria-label="Close" disabled={busy}>
            ✕
          </button>
        </div>
        <div className="sheetbody">
          {phase.kind === "arrived" ? (
            <>
              <h2 id="bridge-title" className="gatetitle">
                <span className="hl hl-lime">{fmt(phase.amount, ROOTSTOCK_USDT0.decimals, 2)} USD₮0</span> arrived on Rootstock.
              </h2>
              <p className="pqnote">
                You need no RBTC to trade it: sign a gasless approval and an order — the filler pays the gas. Sell
                USD₮0 for RBTC first if you want gas for later.
              </p>
              <button type="button" className="cta" onClick={() => (onSwitchHome(), onClose())}>
                Switch back to Rootstock and trade
              </button>
            </>
          ) : (
            <>
              <h2 id="bridge-title" className="gatetitle">
                No funds on Rootstock? <span className="hl hl-violet">Bridge USD₮0</span>, no RBTC needed.
              </h2>
              <p className="pqnote">
                USDT0&rsquo;s own LayerZero bridge moves it to <b>your address</b> on Rootstock, usually in under
                three minutes. You pay the bridge fee in {nativeSym} on the source chain. On Rootstock, USD₮0 trades
                gaslessly.
              </p>
              <div className="pq">
                <span className="pqlabel">From</span>
                <div className="pqopts">
                  {BRIDGE_SOURCES.map((s) => (
                    <button key={s.key} type="button" className={`pqopt${s.key === srcKey ? " on" : ""}`} aria-pressed={s.key === srcKey} disabled={busy || phase.kind === "sent"} onClick={() => setSrcKey(s.key)}>
                      {s.label}
                    </button>
                  ))}
                </div>
                <span className="pqfine">
                  Tron, TON or another chain? Use <a className="linkbtn" href={USDT0_APP_URL} target="_blank" rel="noreferrer">usdt0.to</a> and send to
                  Rootstock.
                </span>
              </div>
              <label className="pq">
                <span className="pqlabel">
                  Amount ({src.symbol}){balance !== null && <span className="pqopt-tag"> · balance {fmt(balance, src.decimals, 2)}</span>}
                </span>
                <input className="pqtext m" inputMode="decimal" placeholder="25" value={amount} disabled={busy || phase.kind === "sent"} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} />
                <span className="pqfine">
                  Pre-audit beta: start small — we suggest at most ${SUGGESTED_MAX_USD}. {src.key === "ethereum" && "From Ethereum you send USDT; the bridge fee there is a few dollars."}
                </span>
              </label>
              {phase.kind === "ready" && (
                <dl className="sum">
                  <div className="pqrow">
                    <dt>You receive on Rootstock (at least)</dt>
                    <dd className="m">{fmt(phase.quote.minAmountLD, ROOTSTOCK_USDT0.decimals, 2)} USD₮0</dd>
                  </div>
                  <div className="pqrow">
                    <dt>Bridge fee (unused part refunded)</dt>
                    <dd className="m">
                      {fmt(phase.quote.nativeFee, src.chain.nativeCurrency.decimals)} {nativeSym}
                    </dd>
                  </div>
                  {phase.quote.approvalRequired && phase.quote.allowance < phase.quote.amountLD && (
                    <div className="pqrow">
                      <dt>First an approval of exactly this amount</dt>
                      <dd className="m">1 extra tx</dd>
                    </div>
                  )}
                </dl>
              )}
              {feeShort && <p className="warn pqfine">Your {nativeSym} balance does not cover the bridge fee plus gas.</p>}
              {phase.kind === "sent" && (
                <p className="pqnote">
                  Sent. Waiting for it to land on Rootstock{slow ? " — this is taking longer than usual" : " (usually under 3 minutes)"}.{" "}
                  <a className="linkbtn" href={layerZeroScanTx(phase.tx)} target="_blank" rel="noreferrer">
                    Track on LayerZero Scan
                  </a>
                </p>
              )}
              {error && <p className="signerr">{error}</p>}
              {!provider || !address ? (
                <p className="pqfine">Connect a wallet first.</p>
              ) : !onSource ? (
                <button type="button" className="cta" onClick={doSwitch}>
                  Switch wallet to {src.label}
                </button>
              ) : phase.kind === "pick" || phase.kind === "quoting" ? (
                <button type="button" className="cta" disabled={!amountLD || phase.kind === "quoting"} onClick={doQuote}>
                  {phase.kind === "quoting" ? "Quoting…" : "Review bridge"}
                </button>
              ) : phase.kind === "ready" || phase.kind === "approving" || phase.kind === "sending" ? (
                <button type="button" className="cta" disabled={phase.kind !== "ready" || feeShort} onClick={doSend}>
                  {phase.kind === "approving"
                    ? "Approving…"
                    : phase.kind === "sending"
                      ? "Confirm in your wallet…"
                      : phase.quote.approvalRequired && phase.quote.allowance < phase.quote.amountLD
                        ? `Approve & bridge ${amount} ${src.symbol}`
                        : `Bridge ${amount} ${src.symbol}`}
                </button>
              ) : null}
            </>
          )}
        </div>
      </div>
    </div>
  );
}

/** The on-ramp's entry when no prize-draw notice carries it. */
export function OnrampLink({ onOpen }: { onOpen: () => void }) {
  return (
    <p className="onramp">
      No funds on Rootstock?{" "}
      <button type="button" className="linkbtn" onClick={onOpen}>
        Bring USD₮0 from Arbitrum, Ethereum, Polygon and more — no RBTC needed
      </button>
    </p>
  );
}
