#!/usr/bin/env node
/**
 * Build the static docs site into `dist/`.
 *
 * Zero dependencies on purpose: the site is four long pages and a search index,
 * and a generator with a lockfile of its own would be more machinery than the
 * thing it generates. `node build.mjs` is the whole build — which is also the
 * Cloudflare Pages build command.
 *
 *   node build.mjs            build into dist/
 *   node build.mjs --serve    build, then serve dist/ on :4173 for a local read
 */

import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { readdir, readFile, mkdir, writeFile, rm, stat } from "node:fs/promises";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { render, stripTags, slugify } from "./src/markdown.mjs";
import { renderPage } from "./src/template.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const CONTENT = join(here, "content");
const ASSETS = join(here, "assets");
const DIST = join(here, "dist");

/** `---\nkey: value\n---` at the top of a content file. */
function frontmatter(source) {
  const m = source.match(/^---\n([\s\S]*?)\n---\n/);
  if (!m) return { meta: {}, body: source };
  const meta = {};
  for (const line of m[1].split("\n")) {
    const at = line.indexOf(":");
    if (at > 0) meta[line.slice(0, at).trim()] = line.slice(at + 1).trim();
  }
  return { meta, body: source.slice(m[0].length) };
}

/**
 * Slice a page into searchable sections at its `##` / `###` headings.
 *
 * Search results point at a heading rather than a page, because these pages are
 * long: "where is the answer" is the question, and a page-level hit does not
 * answer it. Fences are tracked so a `# comment` line inside a code block never
 * starts a section.
 */
function sections(body, page) {
  const out = [];
  let current = { heading: page.title, id: "", lines: [] };
  let fenced = false;

  for (const line of body.split("\n")) {
    if (/^```/.test(line)) fenced = !fenced;
    const h = !fenced && line.match(/^(#{2,3})\s+(.*)$/);
    if (h) {
      out.push(current);
      const text = h[2].trim();
      current = { heading: text.replace(/`/g, ""), id: slugify(text), lines: [] };
      continue;
    }
    current.lines.push(line);
  }
  out.push(current);

  return out
    .map((s) => ({
      p: page.slug,
      pt: page.title,
      h: s.heading,
      a: s.id,
      t: stripTags(render(s.lines.join("\n")).html).slice(0, 2400),
    }))
    .filter((s) => s.t.length > 0 || s.a === "");
}

/**
 * Fail the build on an internal link that points at a page or an anchor this
 * site does not have. Cross-page anchors are the ones that rot — a heading is
 * renamed on one page and the three links to it from elsewhere go quiet — and a
 * 404 nobody notices is worse than a build that stops.
 */
function checkLinks(pages) {
  const anchors = new Map(pages.map((p) => [p.slug, new Set(p.headings.map((h) => h.id))]));
  const broken = [];
  for (const page of pages) {
    for (const m of page.html.matchAll(/href="([/#][^"]*)"/g)) {
      if (m[1].startsWith("#")) {
        // Same-page anchor: the heading-permalinks the renderer emits, plus any
        // in-page cross-reference in the prose.
        if (!anchors.get(page.slug).has(m[1].slice(1))) broken.push(`${page.slug}: no such anchor ${m[1]}`);
        continue;
      }
      const [path, hash] = m[1].split("#");
      const slug = path === "/" ? "index" : path.replace(/^\/|\/$/g, "");
      if (!anchors.has(slug)) broken.push(`${page.slug}: no such page ${path}`);
      else if (hash && !anchors.get(slug).has(hash)) broken.push(`${page.slug}: no such anchor ${m[1]}`);
    }
  }
  if (broken.length) {
    console.error("broken internal links:\n  " + broken.join("\n  "));
    process.exit(1);
  }
}

async function copyAsset(name) {
  const source = await readFile(join(ASSETS, name), "utf8");
  const hash = createHash("sha256").update(source).digest("hex").slice(0, 8);
  const hashed = name.replace(/\.(\w+)$/, `.${hash}.$1`);
  await writeFile(join(DIST, "assets", hashed), source);
  return hashed;
}

async function build() {
  await rm(DIST, { recursive: true, force: true });
  await mkdir(join(DIST, "assets"), { recursive: true });

  const files = (await readdir(CONTENT)).filter((f) => f.endsWith(".md")).sort();
  const pages = [];
  for (const file of files) {
    const { meta, body } = frontmatter(await readFile(join(CONTENT, file), "utf8"));
    const { html, headings } = render(body);
    pages.push({
      slug: meta.slug || file.replace(/^\d+-/, "").replace(/\.md$/, ""),
      title: meta.title || file,
      description: meta.description || "",
      eyebrow: meta.eyebrow,
      html,
      headings,
      body,
    });
  }

  checkLinks(pages);

  const index = pages.flatMap((page) => sections(page.body, page));
  const indexJson = JSON.stringify(index);
  const indexHash = createHash("sha256").update(indexJson).digest("hex").slice(0, 8);
  const indexPath = `/assets/search-${indexHash}.json`;
  await writeFile(join(DIST, "assets", `search-${indexHash}.json`), indexJson);

  const css = await copyAsset("docs.css");
  const js = await copyAsset("docs.js");

  for (const page of pages) {
    const html = renderPage({ page, pages, css, js, indexPath });
    const dir = page.slug === "index" ? DIST : join(DIST, page.slug);
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "index.html"), html);
  }

  // 404 reuses the first page's shell so a mistyped URL still carries the nav
  // and the search box — which is the fastest way back to the right page.
  const notFound = {
    slug: "404",
    title: "Not found",
    description: "That page does not exist. Search, or pick a section from the nav.",
    eyebrow: "404",
    html: "",
    headings: [],
  };
  await writeFile(join(DIST, "404.html"), renderPage({ page: notFound, pages, css, js, indexPath }));

  await writeFile(
    join(DIST, "_headers"),
    `/assets/*\n  Cache-Control: public, max-age=31536000, immutable\n` +
      `/*\n  X-Content-Type-Options: nosniff\n  Referrer-Policy: strict-origin-when-cross-origin\n` +
      `  Content-Security-Policy: default-src 'self'; style-src 'self'; img-src 'self' data:; script-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\n`,
  );
  await writeFile(
    join(DIST, "sitemap.txt"),
    pages.map((p) => (p.slug === "index" ? "/" : `/${p.slug}/`)).join("\n") + "\n",
  );
  await writeFile(join(DIST, "robots.txt"), "User-agent: *\nAllow: /\n");

  const bytes = indexJson.length;
  console.log(
    `built ${pages.length} pages, ${index.length} search sections (${(bytes / 1024).toFixed(1)} KB index) → dist/`,
  );
}

const TYPES = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".json": "application/json", ".txt": "text/plain" };

/** Local preview that mirrors Pages' directory-index behaviour. */
async function serve(port) {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, "http://localhost");
    let path = resolve(DIST, "." + decodeURIComponent(url.pathname));
    if (!path.startsWith(DIST)) return res.writeHead(403).end();
    try {
      if ((await stat(path)).isDirectory()) path = join(path, "index.html");
    } catch {
      path = join(DIST, "404.html");
    }
    try {
      const body = await readFile(path);
      res.writeHead(path.endsWith("404.html") ? 404 : 200, {
        "content-type": TYPES[extname(path)] || "application/octet-stream",
      });
      res.end(body);
    } catch {
      res.writeHead(404).end("not found");
    }
  });
  // A busy port is the normal case on a machine already running the app's dev
  // server, so walk up rather than dying on it.
  server.on("error", (err) => {
    if (err.code === "EADDRINUSE" && port < 4183) server.listen(++port);
    else throw err;
  });
  server.on("listening", () => console.log(`serving dist/ on http://localhost:${port}`));
  server.listen(port);
}

await build();
const serveArg = process.argv.find((a) => a.startsWith("--serve"));
if (serveArg) await serve(Number(serveArg.split("=")[1] || process.env.PORT || 4173));
