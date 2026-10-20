import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createPublicClient, createWalletClient, custom, erc20Abi, formatUnits, http, numberToHex, parseUnits, type Address, type Hex } from "viem";
import { rootstock } from "viem/chains";

import { BRIDGE_ETA_MINUTES, BRIDGE_SOURCES, layerZeroScanTx, NATIVE_USD_REF, ROOTSTOCK_USDT0, sourceRpc, SUGGESTED_MAX_USD, USDT0_APP_URL, type BridgeSource } from "../config/bridge";
import { approveForBridge, arrived, nativeNeeded, quoteBridge, sendToRootstock, type BridgeClient, type BridgeQuote } from "../lib/bridge";
import { fetchUsdTable, fmtUsd } from "../lib/usdPrices";
import type { EIP1193Provider } from "../wallet/eip6963";

/** Rootstock is polled this often for the USD₮0 to land (the wallet is on the source chain meanwhile). */
const ARRIVAL_POLL_MS = 15_000;
/** Past twice the usual time, the panel says it is slow and points at LayerZero Scan. */
const SLOW_AFTER_MS = 2 * BRIDGE_ETA_MINUTES * 60_000;
/** A quote older than this is refreshed before the send (fees and gas move). */
const QUOTE_TTL_MS = 60_000;
/** Above this share of the amount, the summary warns that fees eat the transfer. */
const FEE_WARN_SHARE = 0.05;

type Phase =
  | { kind: "pick" }
  | { kind: "quoting" }
  | { kind: "ready"; quote: BridgeQuote; at: number }
  | { kind: "approving"; quote: BridgeQuote }
  | { kind: "sending"; quote: BridgeQuote }
  | { kind: "sent"; quote: BridgeQuote; tx: Hex; before: bigint; at: number }
  | { kind: "arrived"; tx: Hex; amount: bigint };

const rsk = createPublicClient({ chain: rootstock, transport: http(undefined, { retryCount: 1, timeout: 15_000 }) });

/**
 * One public client per source chain, on its pinned RPC (every origin is in the CSP's
 * connect-src). Balances and quotes read through these, so the panel can show what the
 * user holds everywhere, and price a bridge, before the wallet switches chains.
 */
const readers = new Map(
  BRIDGE_SOURCES.map((s) => [s.key, createPublicClient({ chain: s.chain, transport: http(sourceRpc(s), { batch: true, retryCount: 1, timeout: 10_000 }) })]),
);
const reader = (src: BridgeSource) => readers.get(src.key)!;

interface Holding {
  token: bigint;
  native: bigint;
}

async function holdingOn(src: BridgeSource, owner: Address): Promise<Holding> {
  const pub = reader(src);
  const [token, native] = await Promise.all([
    pub.readContract({ address: src.token, abi: erc20Abi, functionName: "balanceOf", args: [owner] }),
    pub.getBalance({ address: owner }),
  ]);
  return { token, native };
}

/** USD per one native coin of `src`, display only; undefined where no price is listed. */
const nativeUsdCache = new Map<string, Promise<number | undefined>>();
function nativeUsd(src: BridgeSource): Promise<number | undefined> {
  const sym = src.chain.nativeCurrency.symbol;
  const ref = NATIVE_USD_REF[sym];
  if (!ref) return Promise.resolve(undefined);
  let p = nativeUsdCache.get(sym);
  if (!p) {
    p = fetchUsdTable(ref.chainId)
      .then((t) => t[ref.token])
      .catch(() => {
        nativeUsdCache.delete(sym);
        return undefined;
      });
    nativeUsdCache.set(sym, p);
  }
  return p;
}

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

/** Reads, gas and quotes from the public RPC; writes and receipts through the wallet. */
function clientFor(provider: EIP1193Provider, src: BridgeSource, owner: Address): BridgeClient {
  const pub = reader(src);
  const viaWallet = createPublicClient({ chain: src.chain, transport: custom(provider) });
  const wal = createWalletClient({ account: owner, chain: src.chain, transport: custom(provider) });
  return {
    read: (a) => pub.readContract(a as never) as never,
    estimateGas: (a) => pub.estimateContractGas(a as never),
    gasPrice: () => pub.getGasPrice(),
    nativeBalance: (o) => pub.getBalance({ address: o }),
    write: (a) => wal.writeContract({ ...(a as object), account: owner, chain: src.chain } as never),
    waitForReceipt: (hash) => viaWallet.waitForTransactionReceipt({ hash }),
  };
}

const fmt = (wei: bigint, decimals: number, max = 6) => Number(formatUnits(wei, decimals)).toLocaleString("en-US", { maximumFractionDigits: max });
/** A native amount to 4 significant digits ("0.0004512"), so small fees do not read as 0. */
const fmtNative = (wei: bigint, decimals: number) => {
  const v = Number(formatUnits(wei, decimals));
  return v === 0 ? "0" : v.toLocaleString("en-US", { maximumSignificantDigits: 4 });
};

function message(e: unknown): string {
  const m = e instanceof Error ? e.message : String(e);
  if (/rejected|denied/i.test(m)) return "You declined in your wallet — nothing was sent.";
  return m.split("\n")[0]!;
}

/**
 * THE USD₮0 ON-RAMP: bridge USDT0 from another chain to your own address on Rootstock.
 * Balances on every source chain, and the quote (amount on arrival, LayerZero fee, gas),
 * are read from each chain's public RPC, so the user sees where their USD₮0 is and what
 * the bridge costs before switching networks. The approval and the send go through the
 * wallet on the SOURCE chain; the arrival check reads Rootstock's public node. The
 * recipient is always the connected address — there is no field for another one.
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
  const [holdings, setHoldings] = useState<Record<string, Holding | "error">>({});
  const [onRootstock, setOnRootstock] = useState<bigint | null>(null);
  const [usd, setUsd] = useState<number | undefined>(undefined);
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

  // Balances on every source chain and on Rootstock, from the public RPCs — refreshed
  // when a bridge is sent or lands.
  const refreshKey = phase.kind === "sent" || phase.kind === "arrived" ? phase.kind : "idle";
  useEffect(() => {
    if (!address) return;
    for (const s of BRIDGE_SOURCES) {
      void holdingOn(s, address)
        .then((h) => alive.current && setHoldings((m) => ({ ...m, [s.key]: h })))
        .catch(() => alive.current && setHoldings((m) => (m[s.key] ? m : { ...m, [s.key]: "error" })));
    }
    void rootstockUsdt0(address).then((b) => alive.current && setOnRootstock(b)).catch(() => {});
  }, [address, refreshKey]);

  useEffect(() => {
    setUsd(undefined);
    let live = true;
    void nativeUsd(src).then((p) => live && alive.current && setUsd(p));
    return () => void (live = false);
  }, [src]);

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
      if (alive.current) setPhase({ kind: "ready", quote, at: Date.now() });
    } catch (e) {
      if (alive.current) {
        setError(message(e));
        setPhase({ kind: "pick" });
      }
    }
  }, [provider, address, amountLD, src]);

  const doSend = useCallback(async () => {
    if (!provider || !address || phase.kind !== "ready") return;
    const c = clientFor(provider, src, address);
    let quote = phase.quote;
    setError(null);
    try {
      if (Date.now() - phase.at > QUOTE_TTL_MS) {
        // Fees and gas move: send on a fresh quote, and stop if it no longer fits.
        setPhase({ kind: "quoting" });
        quote = await quoteBridge(c, src, address, quote.amountLD);
        if (alive.current) setPhase({ kind: "ready", quote, at: Date.now() });
        if (quote.nativeBalance < nativeNeeded(quote)) throw new Error(`the bridge now costs more ${src.chain.nativeCurrency.symbol} than you hold on ${src.label} — review the new fee`);
        if (quote.balance < quote.amountLD) throw new Error(`you hold ${fmt(quote.balance, src.decimals)} ${src.symbol} on ${src.label}`);
      }
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
  const nativeDec = src.chain.nativeCurrency.decimals;
  const held = holdings[src.key];
  const toUsd = (wei: bigint) => (usd === undefined ? undefined : Number(formatUnits(wei, nativeDec)) * usd);
  const withUsd = (wei: bigint) => {
    const v = toUsd(wei);
    return `${fmtNative(wei, nativeDec)} ${nativeSym}${v !== undefined ? ` (≈ ${fmtUsd(v)})` : ""}`;
  };
  const q = phase.kind === "ready" || phase.kind === "approving" || phase.kind === "sending" ? phase.quote : null;
  const feeShort = phase.kind === "ready" && phase.quote.nativeBalance < nativeNeeded(phase.quote);
  const totalUsd = q ? toUsd(nativeNeeded(q)) : undefined;
  const feeShare = q && totalUsd !== undefined ? totalUsd / Number(formatUnits(q.amountLD, src.decimals)) : undefined;

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
                USDT0&rsquo;s own LayerZero bridge moves it to <b>your address</b> on Rootstock in about{" "}
                {BRIDGE_ETA_MINUTES} minutes. You pay the bridge fee and gas in {nativeSym} on the source chain. On
                Rootstock, USD₮0 trades gaslessly.
              </p>
              <div className="pq">
                <span className="pqlabel">From</span>
                <div className="pqopts">
                  {BRIDGE_SOURCES.map((s) => {
                    const h = holdings[s.key];
                    return (
                      <button key={s.key} type="button" className={`pqopt${s.key === srcKey ? " on" : ""}`} aria-pressed={s.key === srcKey} disabled={busy || phase.kind === "sent"} onClick={() => setSrcKey(s.key)}>
                        {s.label}
                        {h && h !== "error" && h.token > 0n && <span className="pqopt-tag m"> {fmt(h.token, s.decimals, 2)}</span>}
                      </button>
                    );
                  })}
                </div>
                {address && (
                  <span className="pqfine">
                    {held === undefined ? (
                      `Reading your balances on ${src.label}…`
                    ) : held === "error" ? (
                      `Could not read your balances on ${src.label}.`
                    ) : (
                      <>
                        On {src.label}: <b className="m">{fmt(held.token, src.decimals, 2)} {src.symbol}</b> · <span className="m">{withUsd(held.native)}</span>
                        {held.native === 0n && <span className="warn"> — you need some {nativeSym} there to pay the bridge fee.</span>}
                      </>
                    )}
                    {onRootstock !== null && (
                      <>
                        <br />
                        On Rootstock: <span className="m">{fmt(onRootstock, ROOTSTOCK_USDT0.decimals, 2)} USD₮0</span>
                      </>
                    )}
                  </span>
                )}
                <span className="pqfine">
                  Tron, TON or another chain? Use <a className="linkbtn" href={USDT0_APP_URL} target="_blank" rel="noreferrer">usdt0.to</a> and send to
                  Rootstock.
                </span>
              </div>
              <label className="pq">
                <span className="pqlabel">
                  Amount ({src.symbol})
                  {held && held !== "error" && held.token > 0n && (
                    <button type="button" className="linkbtn pqopt-tag" disabled={busy || phase.kind === "sent"} onClick={() => setAmount(formatUnits(held.token, src.decimals))}>
                      {" "}
                      · max {fmt(held.token, src.decimals, 2)}
                    </button>
                  )}
                </span>
                <input className="pqtext m" inputMode="decimal" placeholder="25" value={amount} disabled={busy || phase.kind === "sent"} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} />
                <span className="pqfine">
                  Pre-audit beta: start small — we suggest at most ${SUGGESTED_MAX_USD}. {src.key === "ethereum" && "From Ethereum you send USDT, and gas there can be expensive."}
                </span>
              </label>
              {q && (
                <dl className="sum">
                  <div className="pqrow">
                    <dt>You receive on Rootstock (at least)</dt>
                    <dd className="m">{fmt(q.minAmountLD, ROOTSTOCK_USDT0.decimals, 2)} USD₮0</dd>
                  </div>
                  <div className="pqrow">
                    <dt>LayerZero fee (unused part refunded)</dt>
                    <dd className="m">{withUsd(q.nativeFee)}</dd>
                  </div>
                  <div className="pqrow">
                    <dt>
                      Gas on {src.label}
                      {q.approvals > 0 ? `, incl. ${q.approvals === 2 ? "an allowance reset and " : ""}an approval of exactly this amount` : ""}
                      {q.gasEstimated ? "" : " (approx.)"}
                    </dt>
                    <dd className="m">≈ {withUsd(q.gasCost)}</dd>
                  </div>
                  <div className="pqrow">
                    <dt>Total cost, in {nativeSym}</dt>
                    <dd className="m">
                      ≈ {withUsd(nativeNeeded(q))}
                      {feeShare !== undefined && ` · ${(feeShare * 100).toFixed(feeShare < 0.1 ? 1 : 0)} % of the amount`}
                    </dd>
                  </div>
                  <div className="pqrow">
                    <dt>Arrival on Rootstock</dt>
                    <dd className="m">~{BRIDGE_ETA_MINUTES} min</dd>
                  </div>
                </dl>
              )}
              {feeShort && phase.kind === "ready" && (
                <p className="warn pqfine">
                  You hold {withUsd(phase.quote.nativeBalance)} on {src.label}; the bridge needs about {withUsd(nativeNeeded(phase.quote))} (fee plus gas).
                </p>
              )}
              {!feeShort && feeShare !== undefined && feeShare > FEE_WARN_SHARE && (
                <p className="warn pqfine">Fees are a large share of this amount — a bigger transfer, or a cheaper chain, wastes less.</p>
              )}
              {phase.kind === "sent" && (
                <p className="pqnote">
                  Sent. Waiting for it to land on Rootstock
                  {slow ? " — this is taking longer than usual" : ` (usually about ${BRIDGE_ETA_MINUTES} minutes)`}. You can close this panel: it
                  arrives at your address either way.{" "}
                  <a className="linkbtn" href={layerZeroScanTx(phase.tx)} target="_blank" rel="noreferrer">
                    Track on LayerZero Scan
                  </a>
                </p>
              )}
              {error && <p className="signerr">{error}</p>}
              {!provider || !address ? (
                <p className="pqfine">Connect a wallet first.</p>
              ) : phase.kind === "pick" || phase.kind === "quoting" ? (
                <button type="button" className="cta" disabled={!amountLD || phase.kind === "quoting"} onClick={doQuote}>
                  {phase.kind === "quoting" ? "Quoting…" : "Review bridge"}
                </button>
              ) : phase.kind === "ready" && !onSource ? (
                <button type="button" className="cta" disabled={feeShort} onClick={doSwitch}>
                  Switch wallet to {src.label} to bridge
                </button>
              ) : phase.kind === "ready" || phase.kind === "approving" || phase.kind === "sending" ? (
                <button type="button" className="cta" disabled={phase.kind !== "ready" || feeShort} onClick={doSend}>
                  {phase.kind === "approving"
                    ? "Approving…"
                    : phase.kind === "sending"
                      ? "Confirm in your wallet…"
                      : phase.quote.approvals > 0
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
