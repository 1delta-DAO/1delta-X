/**
 * A markdown subset, rendered without a dependency.
 *
 * Covers exactly what `content/*.md` uses: four heading levels, paragraphs,
 * fenced code, bullet and numbered lists, pipe tables, blockquotes, rules, and
 * the inline set `code` / **bold** / [link](target). Anything else renders as
 * the literal text it is — a paragraph showing its own asterisks is readable, a
 * paragraph a parser silently dropped is not.
 *
 * Headings are collected as they are rendered, so the caller gets the page's
 * anchor list and the search index's section boundaries from the same pass.
 */

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };

export function escapeHtml(text) {
  return text.replace(/[&<>"]/g, (c) => ESCAPES[c]);
}

/** Stable, readable heading ids: `Why the fallback is not a kill switch` → `why-the-fallback-is-not-a-kill-switch`. */
export function slugify(text) {
  return text
    .toLowerCase()
    .replace(/`/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
}

// One alternation, so the scanner never re-enters a span it already consumed:
// code first (its contents are literal), then links, then bold, then italic.
// Bold precedes italic, so `**x**` never reads as an empty emphasis; italic
// requires a non-space after the opener, so `a * b` stays arithmetic.
const INLINE = /(`[^`]+`)|(\[[^\]]*\]\([^)\s]+\))|(\*\*[^*]+\*\*)|(\*[^*\s][^*]*\*)/g;

export function inline(text) {
  let out = "";
  let last = 0;
  for (const m of text.matchAll(INLINE)) {
    const at = m.index;
    out += escapeHtml(text.slice(last, at));
    if (m[1]) {
      out += `<code>${escapeHtml(m[1].slice(1, -1))}</code>`;
    } else if (m[2]) {
      const cut = m[2].lastIndexOf("](");
      const label = m[2].slice(1, cut);
      const href = m[2].slice(cut + 2, -1);
      const external = /^https?:/.test(href);
      const attrs = external ? ' target="_blank" rel="noopener"' : "";
      out += `<a href="${escapeHtml(href)}"${attrs}>${inline(label)}</a>`;
    } else if (m[3]) {
      out += `<strong>${inline(m[3].slice(2, -2))}</strong>`;
    } else {
      out += `<em>${inline(m[4].slice(1, -1))}</em>`;
    }
    last = at + m[0].length;
  }
  return out + escapeHtml(text.slice(last));
}

/** `| a | b |` → cells, with the leading/trailing pipes dropped. */
function cells(row) {
  return row
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((c) => c.trim());
}

const isTableRow = (line) => /^\s*\|/.test(line);
const isTableRule = (line) => /^\s*\|[\s:|-]+\|\s*$/.test(line) && line.includes("-");

/**
 * Render `source` to HTML.
 *
 * Returns the html plus the heading list (`{ depth, text, id }`), which the
 * build uses for the on-this-page nav and to slice the page into search
 * sections.
 */
export function render(source) {
  const lines = source.replace(/\r\n/g, "\n").split("\n");
  const headings = [];
  const out = [];

  let paragraph = [];
  let quote = [];

  const flushParagraph = () => {
    if (paragraph.length) out.push(`<p>${inline(paragraph.join(" "))}</p>`);
    paragraph = [];
  };
  const flushQuote = () => {
    if (quote.length) out.push(`<blockquote><p>${inline(quote.join(" "))}</p></blockquote>`);
    quote = [];
  };
  const flush = () => {
    flushParagraph();
    flushQuote();
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (!line.trim()) {
      flush();
      continue;
    }

    // Fenced code — copied verbatim to the closing fence (or to EOF).
    const fence = line.match(/^```(\w*)\s*$/);
    if (fence) {
      flush();
      const body = [];
      i++;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) body.push(lines[i++]);
      const lang = fence[1] ? ` data-lang="${escapeHtml(fence[1])}"` : "";
      out.push(`<pre${lang}><code>${escapeHtml(body.join("\n"))}</code></pre>`);
      continue;
    }

    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    if (heading) {
      flush();
      const depth = heading[1].length;
      const text = heading[2].trim();
      const id = slugify(text);
      headings.push({ depth, text: text.replace(/`/g, ""), id });
      out.push(
        `<h${depth} id="${id}">${inline(text)}` +
          `<a class="anchor" href="#${id}" aria-label="Link to this section">#</a></h${depth}>`,
      );
      continue;
    }

    if (/^(---|\*\*\*)\s*$/.test(line)) {
      flush();
      out.push("<hr>");
      continue;
    }

    // Table: a row followed by a `|---|` rule. Without the rule it is prose
    // that happens to start with a pipe, and falls through to a paragraph.
    if (isTableRow(line) && i + 1 < lines.length && isTableRule(lines[i + 1])) {
      flush();
      const head = cells(line);
      i += 2;
      const body = [];
      while (i < lines.length && isTableRow(lines[i])) body.push(cells(lines[i++]));
      i--;
      const th = head.map((c) => `<th>${inline(c)}</th>`).join("");
      const rows = body
        .map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`)
        .join("");
      out.push(`<div class="table-wrap"><table><thead><tr>${th}</tr></thead><tbody>${rows}</tbody></table></div>`);
      continue;
    }

    const bullet = line.match(/^\s*[-*]\s+(.*)$/);
    const numbered = line.match(/^\s*(\d+)\.\s+(.*)$/);
    if (bullet || numbered) {
      flush();
      const ordered = Boolean(numbered);
      const items = [];
      while (i < lines.length) {
        const item = lines[i].match(ordered ? /^\s*\d+\.\s+(.*)$/ : /^\s*[-*]\s+(.*)$/);
        if (item) {
          items.push([item[item.length - 1]]);
          i++;
          continue;
        }
        // A non-empty, non-item line indented under the bullet continues it.
        if (items.length && /^\s+\S/.test(lines[i]) && !/^\s*```/.test(lines[i])) {
          items[items.length - 1].push(lines[i].trim());
          i++;
          continue;
        }
        break;
      }
      i--;
      const tag = ordered ? "ol" : "ul";
      const start = ordered ? ` start="${numbered[1]}"` : "";
      out.push(`<${tag}${start}>${items.map((p) => `<li>${inline(p.join(" "))}</li>`).join("")}</${tag}>`);
      continue;
    }

    const quoted = line.match(/^>\s?(.*)$/);
    if (quoted) {
      flushParagraph();
      quote.push(quoted[1]);
      continue;
    }

    flushQuote();
    paragraph.push(line.trim());
  }

  flush();
  return { html: out.join("\n"), headings };
}

/** Plain text of a rendered fragment — what the search index matches against. */
export function stripTags(html) {
  return html
    .replace(/<pre[\s\S]*?<\/pre>/g, (block) => " " + block.replace(/<[^>]+>/g, " ") + " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/\s+/g, " ")
    // Tags became spaces, so an inline code span left a gap before the comma
    // that followed it. Snippets are read as prose — close those gaps.
    .replace(/\s+([,.;:)\]])/g, "$1")
    .replace(/([(\[])\s+/g, "$1")
    .trim();
}
