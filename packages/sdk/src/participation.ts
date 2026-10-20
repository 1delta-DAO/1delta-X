import { keccak256, toBytes, type Address, type Hex } from "viem";

/**
 * THE PRIZE-DRAW PARTICIPATION FORM (2026-10-20).
 *
 * Entering the trading promotion is one gasless EIP-712 signature over a feedback
 * form: the signer states the eligibility confirmations in {@link PARTICIPATION_STATEMENT}
 * (shown verbatim by the wallet), names the Terms version it accepts by hash, and
 * commits to its answers by hash. The app builds the message from
 * {@link PARTICIPATION_QUESTIONS}; the orderbook worker re-derives the same hash from
 * the posted answers and verifies the signature. Both import this one module, so the
 * form the user filled in and the form the server checks cannot drift apart.
 *
 * Not an order: the domain carries no `verifyingContract`, and no contract ever reads
 * this signature. It is evidence that this address made these statements.
 */

/** The confirmations an entrant makes. Changing a word means bumping {@link PARTICIPATION_DOMAIN_VERSION}. */
export const PARTICIPATION_STATEMENT =
  "I confirm that I am not a U.S. Person, that I am not located in, resident in or a national of a sanctioned jurisdiction, " +
  "and that I am of legal age where I live. I accept the Promotion Terms identified by `terms`. " +
  "I agree that my wallet address may be published if I am selected. My answers are identified by `answers`.";

export const PARTICIPATION_DOMAIN_NAME = "1delta Prize Draw";
export const PARTICIPATION_DOMAIN_VERSION = "1";

export const PARTICIPATION_TYPES = {
  Participation: [
    { name: "participant", type: "address" },
    { name: "promotion", type: "string" },
    { name: "terms", type: "bytes32" },
    { name: "answers", type: "bytes32" },
    { name: "statement", type: "string" },
    { name: "issuedAt", type: "uint64" },
  ],
} as const;

export interface ParticipationMessage {
  participant: Address;
  /** The promotion id the operator configured (e.g. "rootstock-beta-1"). */
  promotion: string;
  /** keccak256 of the Terms text the entrant was shown. */
  terms: Hex;
  /** {@link answersHash} of the answers. */
  answers: Hex;
  statement: string;
  /** Unix seconds. */
  issuedAt: bigint;
}

/** The typed data to hand to `signTypedData` / `verifyTypedData`. */
export function participationTypedData(chainId: number, m: Omit<ParticipationMessage, "statement">) {
  return {
    domain: { name: PARTICIPATION_DOMAIN_NAME, version: PARTICIPATION_DOMAIN_VERSION, chainId },
    types: PARTICIPATION_TYPES,
    primaryType: "Participation" as const,
    message: { ...m, statement: PARTICIPATION_STATEMENT },
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
 * safe a pending order felt, the fill), then optional detail. Nothing the chain
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
