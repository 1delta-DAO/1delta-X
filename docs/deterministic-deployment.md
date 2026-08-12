# Deterministic Multi-Chain Deployment

How to land Permit3, the settlement core, and the bridge package on **identical
addresses on every EVM chain**, and what actually threatens that.

For the bridge package this is not a convenience. Funds are bridged to funnel
addresses that may not be deployed yet; a funnel address is derived from the
`PositionFunnelFactory` address, so if the factory lands somewhere else on one
chain, every funnel address the *source* chain predicted is wrong and tokens
already sent there are unreachable. Determinism is a fund-safety property. See
the header of [`bridge/script/Deploy.s.sol`](../packages/modules/bridge/script/Deploy.s.sol).

---

> **The decision, up front:** compile everything with **`evm_version = "cancun"`**.
> Of 43 chains probed (§4), 39 are Cancun-capable and 38 of those can share one
> address family — Abstract is excluded for unrelated reasons. Only four —
> **Metis, Taiko, PulseChain, Telos** — fall short, and none is worth dropping
> the whole set a tier for. See §4.1: the version is a *global* choice, not a
> per-chain one.

---

## 1. The factory

`DeployFactory` is deployed at `0x16c4Dc0f662E2bEceC91fC5E7aeeC6a25684698A` on
**every** chain surveyed in §4. It is a minimal CREATE2 wrapper:

```solidity
function deploy(bytes32 salt, bytes memory bytecode) external returns (address addr);
function computeAddress(bytes32 salt, bytes32 bytecodeHash) external view returns (address);
```

Three properties to keep in mind:

- **The salt is not sender-scoped**, and `deploy` has no access control — anyone
  may call it with any salt. This does *not* let a stranger plant hostile code at
  an address you predicted: the CREATE2 address binds `keccak256(init_code)`, and
  constructor arguments are part of init code, so different code (or different
  args) lands at a *different* address. What it does allow, once your constructor
  inputs are public, is someone deploying your **byte-identical** contract at your
  address on a chain you have not reached yet. The contract is then the one you
  wanted — but your own run reverts on collision, and you must verify the deployed
  code rather than assume it. Two consequences:
  - **Keep every deployed contract's configuration inside its constructor.** The
    guarantee above holds only because nothing here is configured by a
    post-deployment initializer. An initializer-configured contract (any proxy
    pattern) has an address that does *not* bind its config, and that address is
    genuinely squattable by whoever calls first.
  - **Still derive salts from a preimage you do not publish until the rollout is
    complete** — defence in depth, and it keeps predicted addresses out of reach
    of griefers before you are ready to use them. The salt in
    [`bridge/script/Deploy.s.sol`](../packages/modules/bridge/script/Deploy.s.sol)
    is a placeholder for exactly this reason.
- **No value forwarding** — `deploy` is not payable. None of our constructors
  need ETH, so this is fine, but it rules out funding at construction.
- **No event** — the deployment registry has to be maintained off-chain.

Deploying the factory itself onto a *new* chain must reproduce whatever put it
at `0x16c4Dc…` elsewhere (same EOA at the same nonce). If that key/nonce is no
longer available, that chain can never join the matched set.

### 1.1 The factory code is *not* identical across chains

Four distinct runtime bytecodes live at `0x16c4Dc…`:

| Variant (sha256, 16 hex) | Size | Chains |
|---|---|---|
| `ea814fa7fe74d90a` | 826 B | Ethereum, Unichain, Berachain, Monad, Soneium, HyperEVM, Katana, Cronos, Moonbeam, Manta, Morph, Sei, XDC, Kaia |
| `561d3752a38926ac` | 844 B | Arbitrum, Optimism, Base, Polygon, BNB, Avalanche, Gnosis, Linea, Scroll, Mantle, Sonic, Blast, Mode, Metis, Taiko, Hemi, Core |
| `3402ffcbd4d6bce8` | 826 B | Rootstock, Abstract, Flare, Ink, Lisk, BOB, Plume, PulseChain, X Layer |
| `200319a354b4be46` | 826 B | MegaETH |

This is **not** a determinism problem, but it must be verified rather than
assumed — CREATE2 children depend on the factory *address*, not its code, only
so long as every variant derives addresses identically. Verified behaviourally:
for the same `(salt, initCodeHash)` all four return the same `computeAddress`,
and a simulated `deploy` returns that same address from two different senders
(so no variant salts with `msg.sender`):

```
              computeAddress / deploy(0x…dEaD) / deploy(0x…BeefBeef)
ethereum      0xE2Eb8037241d1Ec56D16e6Ab957Aa925Da07e3dd   all equal
base          0xE2Eb8037241d1Ec56D16e6Ab957Aa925Da07e3dd   all equal
rootstock     0xE2Eb8037241d1Ec56D16e6Ab957Aa925Da07e3dd   all equal
arbitrum      0xE2Eb8037241d1Ec56D16e6Ab957Aa925Da07e3dd   all equal
linea         0xE2Eb8037241d1Ec56D16e6Ab957Aa925Da07e3dd   all equal
megaeth       0xE2Eb8037241d1Ec56D16e6Ab957Aa925Da07e3dd   all equal
```

Re-run this check before adding any chain whose factory hash is not one of the
four above — MegaETH's variant was found this way, and a fifth is likely.

## 2. The dependency chain

Init code = creation bytecode **+ ABI-encoded constructor args**, so determinism
propagates down the chain: every argument must itself already be deterministic.

| Contract | Constructor args | Deterministic? |
|---|---|---|
| `Permit3` | none — [`EIP712`](../packages/core/src/permit3/EIP712.sol) takes nothing; `block.chainid` is only *read* into an immutable | ✅ root of the chain |
| `Settlement` | `(permit3)` — [Settlement.sol:48](../packages/core/src/settlement/Settlement.sol#L48) | ✅ if Permit3 matches |
| `SolverCallbackExecutor` | none; deployed by Settlement's constructor via plain CREATE — [Base.sol:139](../packages/core/src/settlement/Base.sol#L139) | ✅ nonce-1 child of a deterministic parent |
| `SettlementLens` | `(settlement)` | ✅ |
| `FunnelGrantModule` | `(settlement)` | ✅ |
| `PositionFunnelFactory` | `(permit3, settlement, lens, grantModule)`; deploys `IMPLEMENTATION` in-constructor | ✅ — **this is the fund-safety-critical one** |
| `LzOftBridgeOutModule` | `(permit3, settlement)` | ✅ |
| `AcrossBridgeOutModule` | `(permit3, settlement, spokePool)` | ❌ chain-specific arg |
| `BridgedOrderInbox` | `(permit3, settlement, spokePool, lzEndpoint, owner)` | ❌ chain-specific args |

The two ❌ rows are a design choice, not an accident. The Across out-module
probably does not care — nothing on a remote chain predicts its address. The
**inbox does**, because a source chain must name the destination inbox as the
maker. To bring it into the matched set, move `spokePool`/`lzEndpoint` out of
the constructor into owner-set storage.

Note that Permit3 caching its domain separator is *not* a determinism problem:
the chain id is read at construction into an immutable, which changes the
runtime code's immutable slot but not the init code, and the address derives
from init code alone.

## 3. Bytecode identity: only three families exist

Address = f(factory, salt, init code). Init code changes if *anything* about the
compile changes. Measured on `packages/core/src` with `solc 0.8.28`,
`optimizer_runs = 200`, profile `core`, **metadata stripped**
(`bytecode_hash = "none"`, `cbor_metadata = false`):

| `evm_version` | Permit3 init code (sha256, 12 hex) | Settlement init code |
|---|---|---|
| `london`, `paris` | `d65060094296` | `fe88129fe0af` |
| `shanghai` | `f4af250d0a9e` | `5f82f43b9c72` |
| **`cancun`, `prague`, `osaka`** | `6ce16340ba2b` | `aea317a8a733` |

Reproduce with:

```bash
for v in london paris shanghai cancun prague osaka; do
  FOUNDRY_PROFILE=core FOUNDRY_EVM_VERSION=$v \
  FOUNDRY_BYTECODE_HASH=none FOUNDRY_CBOR_METADATA=false \
  FOUNDRY_OUT=/tmp/ev-$v forge build --skip '*.t.sol' --skip '*.s.sol' >/dev/null
  echo "$v $(jq -r .bytecode.object /tmp/ev-$v/Permit3.sol/Permit3.json | sha256sum | cut -c1-12)"
done
```

The whole portability question therefore collapses to **two opcodes**:

- **PUSH0** (`0x5f`, Shanghai)
- **MCOPY** (`0x5e`, Cancun)

Prague adds no opcode solc emits, and 0.8.28 does not emit `CLZ` at osaka. A
chain needs Cancun *opcodes*, not the Cancun fork. Our current setting of
`evm_version = "prague"` ([foundry.toml](../foundry.toml)) is byte-identical to
`cancun`, so it costs nothing today.

**Without** stripping metadata all six versions produce different bytecode,
because the CBOR trailer hashes the compiler settings. That also means any
comment change moves every address — hence `bytecode_hash = "none"`.

### Compiler settings that must be pinned before the first deploy

| Setting | Value | Why |
|---|---|---|
| `solc` | `0.8.28` | already pinned in `[profile.default]` |
| `optimizer_runs` | `200` | changes codegen |
| `via_ir` | **`true` for the core package only** | Settlement exceeds EIP-170 under legacy codegen; only `[profile.core-deploy]` artifacts fit. Different codegen ⇒ different address, silently. |
| `bytecode_hash` | `none` | otherwise source/settings churn moves addresses |
| `evm_version` | **`cancun`**, explicitly — see §4.1 | the chain-coverage decision |

Pinning `evm_version` matters more than it looks. Bump solc past 0.8.28 without
it and the compiler's *default* moves to a newer fork; at `osaka` a newer solc
emits `CLZ`, which (a) moves every address in the chain including the funnel
factory and (b) fails outright on the 18 surveyed chains that lack it (§4).

## 4. Chain survey

Probed **2026-08-06** with the method in §6. `max evm_version` is the highest
setting that produces *working* bytecode on that chain — not necessarily the one
to compile with (see §4.1). CLZ is tracked only as the early-warning signal for
the solc-bump hazard in §3.

### Cancun-capable — 39 chains, the default family

| Chain | PUSH0 | MCOPY | CLZ | max `evm_version` | Factory |
|---|---|---|---|---|---|
| Ethereum | ✅ | ✅ | ✅ | cancun | present |
| Arbitrum One | ✅ | ✅ | ✅ | cancun | present |
| Optimism | ✅ | ✅ | ✅ | cancun | present |
| Base | ✅ | ✅ | ✅ | cancun | present |
| Polygon PoS | ✅ | ✅ | ✅ | cancun | present |
| BNB Chain | ✅ | ✅ | ✅ | cancun | present |
| Gnosis (xDai) | ✅ | ✅ | ✅ | cancun | present |
| Linea | ✅ | ✅ | ✅ | cancun | present |
| Scroll | ✅ | ✅ | ✅ | cancun | present |
| Mantle | ✅ | ✅ | ✅ | cancun | present |
| Mode | ✅ | ✅ | ✅ | cancun | present |
| Unichain | ✅ | ✅ | ✅ | cancun | present |
| Soneium | ✅ | ✅ | ✅ | cancun | present |
| Ink | ✅ | ✅ | ✅ | cancun | present |
| Lisk | ✅ | ✅ | ✅ | cancun | present |
| Morph | ✅ | ✅ | ✅ | cancun | present |
| Berachain | ✅ | ✅ | ✅ | cancun | present |
| Monad | ✅ | ✅ | ✅ | cancun | present |
| Moonbeam | ✅ | ✅ | ✅ | cancun | present |
| Kaia | ✅ | ✅ | ✅ | cancun | present |
| Plume | ✅ | ✅ | ✅ | cancun | present |
| Avalanche C-Chain | ✅ | ✅ | ❌ | cancun | present |
| Sonic | ✅ | ✅ | ❌ | cancun | present |
| Blast | ✅ | ✅ | ❌ | cancun | present |
| Hemi | ✅ | ✅ | ❌ | cancun | present |
| Core | ✅ | ✅ | ❌ | cancun | present |
| Cronos | ✅ | ✅ | ❌ | cancun | present |
| HyperEVM | ✅ | ✅ | ❌ | cancun | present |
| Katana | ✅ | ✅ | ❌ | cancun | present |
| Manta Pacific | ✅ | ✅ | ❌ | cancun | present |
| Sei | ✅ | ✅ | ❌ | cancun | present |
| XDC | ✅ | ✅ | ❌ | cancun | present |
| X Layer | ✅ | ✅ | ❌ | cancun | present |
| Flare | ✅ | ✅ | ❌ | cancun | present |
| BOB | ✅ | ✅ | ❌ | cancun | present |
| Rootstock | ✅ | ✅ | ❌ | cancun | present |
| Abstract † | ✅ | ✅ | ❌ | cancun | present |
| Stable (chain 988) | ✅ | ✅ | ❌ | cancun | present |
| MegaETH (chain 4326) | ✅ | ✅ | ❌ | cancun | present |

† Abstract is a ZKsync-stack chain and answers the opcode probe via its EVM
interpreter. Do **not** infer address compatibility from that — see "Excluded".

⚠ **Probe mainnet, not testnet.** MegaETH mainnet is chain **4326**
(`https://mainnet.megaeth.com/rpc`); `carrot.megaeth.com` is chain **6343**,
the testnet, where the factory is genuinely absent. Confirm the chain id
alongside every probe — a testnet endpoint yields a plausible-looking row that
is simply about a different chain.

### Below Cancun — cannot join the default family

| Chain | PUSH0 | MCOPY | max `evm_version` | Factory | Confirmed on |
|---|---|---|---|---|---|
| Metis Andromeda | ✅ | ❌ | **shanghai** | present | 2 RPCs |
| Taiko | ✅ | ❌ | **shanghai** | present | 2 RPCs |
| PulseChain | ✅ | ❌ | **shanghai** | present | 2 RPCs |
| Telos EVM | ✅ | ❌ | **shanghai** | present | 1 RPC |

### Deprecated — not targeted

**Fantom Opera** (chain 250) rejects **PUSH0** outright
(`invalid opcode: opcode 0x5f not defined`) on three independent RPCs, putting
it two tiers down at `london`. It is **not a deployment target** — the network
is deprecated in favour of Sonic, which is Cancun-capable and already in the
default family. Recorded here only so the result is not re-derived later.

### Not probed — endpoint unavailable

Corn, Pharos, Robinhood Chain. These failed on access (403/404/DNS) or refused
`to`-less `eth_call`, not on capability. They need a keyed RPC before a verdict.

### Permanently excluded

ZKsync-stack chains — Era, **Abstract**, Lens, Sophon — derive CREATE2
differently and use a different native bytecode format. Abstract passing the
opcode probe above does not change this: the probe exercises its EVM
interpreter, not address derivation. They can never share addresses with this
set, regardless of compiler settings.

## 4.1 Which `evm_version` to pick

**The version is a global choice, not a per-chain one.** A contract compiled at
`cancun` and the same contract compiled at `shanghai` are different bytecode, so
they land on *different addresses*. Compiling per-chain to "use the best each
chain supports" defeats the entire purpose.

So the target set determines the version:

| If the matched set must include… | Compile at | Cost |
|---|---|---|
| the 38 deployable Cancun chains in §4 (**recommended**) | **`cancun`** | none |
| …+ Metis, Taiko, PulseChain, Telos | `shanghai` | +21 B Settlement, +22 B Permit3 |
| …+ Fantom Opera (deprecated, not a target) | `london` | +578 B Settlement, +175 B Permit3 |

Sizes measured on profile `core` (legacy codegen), runtime bytecode, relative to
`cancun`. The `shanghai` penalty is negligible in bytes — 21 — and costs only
MCOPY on memory copies.

**Recommendation: `cancun`.** Treat Metis, Taiko, PulseChain and Telos as a
separate `shanghai` address family, or skip them; none carries enough volume to
justify moving the other 38 chains down a tier. The `london` row is retained
only to document the measurement: it would consume roughly 45% of the ~1.3KB
EIP-170 margin Settlement has under via-IR, so were it ever needed, `make
size-check` must be re-run on a `london` build first.

## 5. Rootstock: status

Rootstock is **ready** — this corrects an earlier assessment in this document's
history that reported the factory as missing there.

- **Opcodes:** fine. MCOPY landed in [Lovell](https://rootstock.io/blog/lovell-network-upgrade-proposal/)
  (RSKIP-445, March 2025); PUSH0 ([RSKIP-398](https://ips.rootstock.io/IPs/RSKIP398.html))
  came in an earlier fork. Verified on three RPCs.
- **Factory:** present at `0x16c4Dc…` (variant `3402ffcb…`), confirmed on three
  RPCs across three attempts each. The earlier "MISSING" reading was a
  transient `cast code` failure that the probe wrongly treated as empty code —
  the script now retries and distinguishes an error from an actual `0x`.
- **Open item — contract size.** Lovell's RSKIP-438 caps contract code size at
  creation. Settlement fits EIP-170 with roughly 1.3KB of margin under via-IR
  (`make size-check`). Confirm Rootstock's limit is not tighter than 24576.

## 6. How to probe a chain

Do not trust docs; they lag and they disagree. Probe the RPC.

The obvious method — `eth_call` with a state override injecting test bytecode —
**is wrong**, and wrong in the dangerous direction. RSKj rejects overrides
outright (`"State override is not allowed"`), which reads as "opcode missing"
and produced a confident, false `push0=no mcopy=no` for Rootstock.

The working method is `eth_call` with **no `to` field**: the payload executes as
init code and the call returns the runtime it would deploy. No override, no
deployment, no key.

Two controls are mandatory, because failure looks different per client:

- **Positive** (ancient opcodes only) must pass, else the node is not executing.
- **Negative** (`0xfe INVALID`) must fail, else the node reports success blindly.

The negative control is not optional paranoia. Geth raises
`invalid opcode`, but **RSKj returns `"0x"` with no error** — so a probe that
only watches for RPC errors would report every opcode as supported on Rootstock.

```bash
#!/usr/bin/env bash
# ./probe-evm.sh --list chains.txt    # lines of "name<TAB>rpc"
FACTORY=0x16c4Dc0f662E2bEceC91fC5E7aeeC6a25684698A

POS_CONTROL=0x60016000f3                # PUSH1 01, PUSH1 00, RETURN
NEG_CONTROL=0xfe5060016000f3            # INVALID
PUSH0_CODE=0x5f5060016000f3             # PUSH0              (Shanghai)
MCOPY_CODE=0x6020600060405e60016000f3   # MCOPY len/src/dst  (Cancun)
CLZ_CODE=0x60011e5060016000f3           # CLZ                (Osaka)

run() { # $1=rpc $2=initcode -> ok|no
  case "$(cast rpc --rpc-url "$1" eth_call "{\"data\":\"$2\"}" 'latest' 2>&1)" in
    *0x00*) echo ok ;; *) echo no ;;
  esac
}

check() { # $1=name $2=rpc
  [ "$(run "$2" "$POS_CONTROL")" = no ] && { echo "$1 INCONCLUSIVE (no execution)"; return; }
  [ "$(run "$2" "$NEG_CONTROL")" = ok ] && { echo "$1 INCONCLUSIVE (accepts INVALID)"; return; }
  p=$(run "$2" "$PUSH0_CODE"); m=$(run "$2" "$MCOPY_CODE"); c=$(run "$2" "$CLZ_CODE")
  if   [ "$m" = ok ]; then t=cancun
  elif [ "$p" = ok ]; then t=shanghai
  else                    t=london; fi
  # Retry, and distinguish "no code" from "the call failed" -- treating an
  # errored cast as MISSING produced a false negative on Rootstock (§5).
  f=UNKNOWN
  for _ in 1 2 3; do
    case "$(cast code --rpc-url "$2" "$FACTORY" 2>/dev/null)" in
      0x)    f=MISSING; break ;;
      0x??*) f=present; break ;;
    esac
  done
  printf "%-14s push0=%-3s mcopy=%-3s clz=%-3s -> %-9s factory=%s\n" "$1" "$p" "$m" "$c" "$t" "$f"
}

if [ "$1" = "--list" ]; then
  while IFS=$'\t' read -r n r; do case "$n" in ''|\#*) continue;; esac; check "$n" "$r"; done < "$2"
else check "$1" "$2"; fi
```

## 7. Deploy checklist

Per chain, in order. Refuse to enable a chain as a bridging destination until
every line passes.

1. Probe: PUSH0 ✅, MCOPY ✅, both controls behaving (§6). A chain that fails
   MCOPY belongs to a *different address family* — it is not a deploy-time
   workaround (§4.1).
2. Contract size limit ≥ 24576 (only Rootstock is known to cap this explicitly).
3. `DeployFactory` present at `0x16c4Dc…`, **and** its `computeAddress` agrees
   with the other chains for a fixed `(salt, initCodeHash)` (§1.1).
4. Build from the pinned profile — `FOUNDRY_PROFILE=core-deploy` for the core
   package — with `evm_version` and `bytecode_hash` pinned per §3.
5. Deploy in dependency order: Permit3 → Settlement → SettlementLens →
   FunnelGrantModule → PositionFunnelFactory → out-modules → inbox.
6. **Assert each deployed address equals the precomputed one and revert on
   mismatch.** A silent divergence on `PositionFunnelFactory` strands funds; it
   must fail loudly rather than log and continue.
7. Record salt, init-code hash and resulting address per contract in the
   deployment registry.

Anything that changes an init-code hash — a solc bump, an optimizer-run change,
a comment in a constructor path — starts a **new address family**. It is not a
patch; it is a migration.
