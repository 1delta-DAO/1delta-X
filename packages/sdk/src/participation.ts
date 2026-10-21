import { keccak256, toBytes, type Address, type Hex } from "viem";

/**
 * THE PRIZE DRAW'S TWO SIGNATURES (2026-10-21).
 *
 * The Promotion Terms (TC.md §4.1, reviewed and frozen) say there is NO registration:
 * every wallet that trades is considered automatically. So nothing here is an entry.
 *
 *   • FEEDBACK — optional. After a first swap, a user may rate the app; the signature
 *     (gasless EIP-712) proves the wallet gave these answers and commits to them by
 *     hash. It changes nothing about the draw.
 *   • CLAIM — a drawn winner confirms eligibility before payout (TC §3, §7.5): not a
 *     U.S. Person, not in a sanctioned jurisdiction, of legal age, accepts the Terms
 *     (by hash), agrees to the address being published. The orderbook stores it; the
 *     operator pays only claimed prizes.
 *
 * The app builds both messages from this module and the orderbook worker re-derives
 * them, so what a user signed and what the server checks cannot drift apart. Neither
 * is an order: the domain carries no `verifyingContract`, and no contract reads them.
 */

export const PARTICIPATION_DOMAIN_NAME = "1delta Prize Draw";
export const PARTICIPATION_DOMAIN_VERSION = "2";

/** Shown verbatim by the wallet. Changing a word means bumping {@link PARTICIPATION_DOMAIN_VERSION}. */
export const FEEDBACK_STATEMENT = "I am giving 1delta feedback about its app. My answers are identified by `answers`. This is not an entry and changes nothing about the prize draw.";

export const FEEDBACK_TYPES = {
  Feedback: [
    { name: "participant", type: "address" },
    { name: "promotion", type: "string" },
    { name: "answers", type: "bytes32" },
    { name: "statement", type: "string" },
    { name: "issuedAt", type: "uint64" },
  ],
} as const;

export interface FeedbackMessage {
  participant: Address;
  /** The promotion id the operator configured (e.g. "rootstock-beta-1"). */
  promotion: string;
  /** {@link answersHash} of the answers. */
  answers: Hex;
  /** Unix seconds. */
  issuedAt: bigint;
}

/** The typed data to hand to `signTypedData` / `verifyTypedData`. */
export function feedbackTypedData(chainId: number, m: FeedbackMessage) {
  return {
    domain: { name: PARTICIPATION_DOMAIN_NAME, version: PARTICIPATION_DOMAIN_VERSION, chainId },
    types: FEEDBACK_TYPES,
    primaryType: "Feedback" as const,
    message: { ...m, statement: FEEDBACK_STATEMENT },
  };
}

/** The eligibility confirmations a winner makes before payout (TC §3.1, §3.2, §7.5, §8). */
export const CLAIM_STATEMENT =
  "I claim the prize drawn for my wallet address in the draw identified by `draw`. I confirm that I am not a U.S. Person, " +
  "that I am not located in, resident in or a national of a sanctioned jurisdiction, that I am of legal age and have legal capacity, " +
  "that I control this wallet address, and that I am permitted to receive the prize. I accept the Promotion Terms identified by `terms`. " +
  "I agree that my wallet address may be published.";

export const CLAIM_TYPES = {
  Claim: [
    { name: "participant", type: "address" },
    { name: "promotion", type: "string" },
    { name: "draw", type: "string" },
    { name: "terms", type: "bytes32" },
    { name: "statement", type: "string" },
    { name: "issuedAt", type: "uint64" },
  ],
} as const;

export interface ClaimMessage {
  participant: Address;
  promotion: string;
  /** The draw record's key ("YYYY-MM-DD", the period's first day). */
  draw: string;
  /** keccak256 of the Terms text the winner was shown. */
  terms: Hex;
  issuedAt: bigint;
}

export function claimTypedData(chainId: number, m: ClaimMessage) {
  return {
    domain: { name: PARTICIPATION_DOMAIN_NAME, version: PARTICIPATION_DOMAIN_VERSION, chainId },
    types: CLAIM_TYPES,
    primaryType: "Claim" as const,
    message: { ...m, statement: CLAIM_STATEMENT },
  };
}

// ──────────────────── the questions ────────────────────

export type Question =
  | { id: string; kind: "choice"; label: string; options: readonly string[]; required: boolean }
  | { id: string; kind: "multi"; label: string; options: readonly string[]; required: boolean }
  | { id: string; kind: "scale"; label: string; low: string; high: string; required: boolean }
  | { id: string; kind: "text"; label: string; max: number; required: boolean };

/**
 * About a minute, and about the product: four 1–5 ratings (overall, ease, how
 * safe a pending order felt, the fill), then optional detail. Optional, and never a
 * condition of the draw (TC §4.1: no registration). Nothing the chain
 * already says (what was traded, how much, when) is asked, and nothing about where
 * a user's funds come from — a question crypto users read as a reason not to answer.
 * No personal data either: a winner is known by the wallet address the draw picked
 * and is paid to it, so a contact field would only be data that could leak.
 */
export const PARTICIPATION_QUESTIONS: readonly Question[] = [
  { id: "rating", kind: "scale", label: "Overall, how would you rate the app?", low: "Poor", high: "Excellent", required: true },
  { id: "ease", kind: "scale", label: "How easy was placing your order?", low: "Very hard", high: "Very easy", required: true },
  {
    id: "safety",
    kind: "scale",
    label: "How safe did you feel while your order was pending?",
    low: "Very uneasy",
    high: "Completely safe",
    required: true,
  },
  {
    id: "fill",
    kind: "scale",
    label: "Fill speed and price, compared with what you expected",
    low: "Much worse",
    high: "Much better",
    required: true,
  },
  {
    id: "purpose",
    kind: "multi",
    label: "What did you trade for?",
    options: ["Exit USDRIF", "Get RBTC", "Buy or sell RIF", "Try the app", "Other"],
    required: false,
  },
  { id: "friction", kind: "text", label: "What confused you or nearly stopped you?", max: 1000, required: false },
  {
    id: "next",
    kind: "multi",
    label: "Which order types would you use next?",
    options: ["Limit orders", "Scheduled / TWAP", "Take-profit / stop-loss", "Orders on lending positions", "None of these"],
    required: false,
  },
];

/** An answer per question id: a choice / text string, a multi-select list, a 1–5 scale. */
export type ParticipationAnswers = Record<string, string | readonly string[] | number>;

const SCALE_MIN = 1;
const SCALE_MAX = 5;

function isBlank(v: unknown): boolean {
  return v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0);
}

/** `null` when the answers fit the form; else the first problem, phrased for the user. */
export function validateAnswers(answers: unknown, questions: readonly Question[] = PARTICIPATION_QUESTIONS): string | null {
  if (typeof answers !== "object" || answers === null || Array.isArray(answers)) return "answers must be an object";
  const a = answers as Record<string, unknown>;
  const known = new Set(questions.map((q) => q.id));
  for (const k of Object.keys(a)) if (!known.has(k)) return `unknown question "${k}"`;
  for (const q of questions) {
    const v = a[q.id];
    if (isBlank(v)) {
      if (q.required) return `"${q.label}" is required`;
      continue;
    }
    switch (q.kind) {
      case "choice":
        if (typeof v !== "string" || !q.options.includes(v)) return `"${q.label}": pick one of the options`;
        break;
      case "multi":
        if (!Array.isArray(v) || v.some((x) => typeof x !== "string" || !q.options.includes(x))) return `"${q.label}": pick from the options`;
        if (new Set(v).size !== v.length) return `"${q.label}": an option is repeated`;
        break;
      case "scale":
        if (typeof v !== "number" || !Number.isInteger(v) || v < SCALE_MIN || v > SCALE_MAX) return `"${q.label}": pick 1 to 5`;
        break;
      case "text":
        if (typeof v !== "string") return `"${q.label}" must be text`;
        if (v.trim() !== v) return `"${q.label}": remove leading or trailing spaces`;
        if ([...v].length > q.max) return `"${q.label}": at most ${q.max} characters`;
        break;
    }
  }
  return null;
}

/**
 * The canonical JSON the answers hash is taken over: question order, blanks
 * dropped, a multi-select in option order. Two forms filled in the same way
 * always hash the same, whatever order the user clicked in.
 * Call it on answers {@link validateAnswers} accepted.
 */
export function canonicalAnswers(answers: ParticipationAnswers, questions: readonly Question[] = PARTICIPATION_QUESTIONS): string {
  const out: Record<string, string | string[] | number> = {};
  for (const q of questions) {
    const v = answers[q.id];
    if (isBlank(v)) continue;
    if (q.kind === "multi") out[q.id] = q.options.filter((o) => (v as readonly string[]).includes(o));
    else out[q.id] = v as string | number;
  }
  return JSON.stringify(out);
}

export function answersHash(answers: ParticipationAnswers, questions: readonly Question[] = PARTICIPATION_QUESTIONS): Hex {
  return keccak256(toBytes(canonicalAnswers(answers, questions)));
}

/** keccak256 of a Terms text, as the `terms` field carries it. */
export function termsHash(text: string): Hex {
  return keccak256(toBytes(text));
}
