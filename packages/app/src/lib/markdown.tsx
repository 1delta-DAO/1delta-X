import { Fragment, type ReactNode } from "react";

/**
 * A markdown subset, rendered without a dependency.
 *
 * Deliberately not a general parser: it covers exactly the syntax `TC.md` uses
 * — two heading levels, a blockquote, bullet lists, `**bold**` and bare email
 * addresses. Anything else renders as the literal text it is, which for a legal
 * document is the right failure: a paragraph that shows its own asterisks is
 * readable, one silently dropped by a parser is not.
 */

const BOLD = /\*\*([^*]+)\*\*/g;
const EMAIL = /([\w.+-]+@[\w-]+\.[\w.]+)/g;

/** `**bold**` and bare emails — the only inline syntax the document uses. */
function inline(text: string, keyBase: string): ReactNode {
  const out: ReactNode[] = [];
  let last = 0;
  let i = 0;

  for (const match of text.matchAll(BOLD)) {
    const at = match.index ?? last;
    if (at > last) out.push(...linkEmails(text.slice(last, at), `${keyBase}-t${i++}`));
    out.push(<strong key={`${keyBase}-b${i++}`}>{linkEmails(match[1]!, `${keyBase}-bi${i}`)}</strong>);
    last = at + match[0].length;
  }
  if (last < text.length) out.push(...linkEmails(text.slice(last), `${keyBase}-t${i++}`));
  return out;
}

function linkEmails(text: string, keyBase: string): ReactNode[] {
  // `split` on a capturing pattern puts the captures at the odd indices, so the
  // position is the test — re-running a /g regex here would carry `lastIndex`.
  const parts = text.split(EMAIL);
  return parts.map((part, n) =>
    n % 2 === 1 ? (
      <a key={`${keyBase}-m${n}`} href={`mailto:${part}`}>
        {part}
      </a>
    ) : (
      <Fragment key={`${keyBase}-s${n}`}>{part}</Fragment>
    ),
  );
}

/** Render the supported block set. Unknown syntax falls through as a paragraph. */
export function renderMarkdown(source: string): ReactNode[] {
  const blocks: ReactNode[] = [];
  const lines = source.replace(/\r\n/g, "\n").split("\n");

  let paragraph: string[] = [];
  let bullets: string[] = [];
  let key = 0;

  const flushParagraph = () => {
    if (!paragraph.length) return;
    const text = paragraph.join(" ");
    blocks.push(<p key={`p${key++}`}>{inline(text, `p${key}`)}</p>);
    paragraph = [];
  };
  const flushBullets = () => {
    if (!bullets.length) return;
    const items = bullets;
    blocks.push(
      <ul key={`u${key++}`}>
        {items.map((item, n) => (
          <li key={n}>{inline(item, `u${key}-${n}`)}</li>
        ))}
      </ul>,
    );
    bullets = [];
  };
  const flush = () => {
    flushParagraph();
    flushBullets();
  };

  for (const raw of lines) {
    const line = raw.trim();

    if (!line) {
      flush();
      continue;
    }
    if (line.startsWith("## ")) {
      flush();
      blocks.push(<h3 key={`h${key++}`}>{inline(line.slice(3), `h${key}`)}</h3>);
      continue;
    }
    if (line.startsWith("# ")) {
      flush();
      blocks.push(<h2 key={`h${key++}`}>{inline(line.slice(2), `h${key}`)}</h2>);
      continue;
    }
    if (line.startsWith("> ")) {
      flush();
      blocks.push(
        <blockquote key={`q${key++}`} className="mdquote">
          {inline(line.slice(2), `q${key}`)}
        </blockquote>,
      );
      continue;
    }
    if (line.startsWith("* ") || line.startsWith("- ")) {
      flushParagraph();
      bullets.push(line.slice(2));
      continue;
    }
    flushBullets();
    paragraph.push(line);
  }
  flush();

  return blocks;
}
