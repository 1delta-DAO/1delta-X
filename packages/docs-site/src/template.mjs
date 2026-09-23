/** The page shell. One template for every page; the only variable parts are the
 *  nav's current entry, the on-this-page list, and the body. */

import { escapeHtml } from "./markdown.mjs";

const SITE = "1delta x";

function navHtml(pages, current) {
  return pages
    .map((p) => {
      const here = p.slug === current.slug;
      const href = p.slug === "index" ? "/" : `/${p.slug}/`;
      const subs = here
        ? `<ul class="sub">${p.headings
            .filter((h) => h.depth === 2)
            .map((h) => `<li><a href="#${h.id}">${escapeHtml(h.text)}</a></li>`)
            .join("")}</ul>`
        : "";
      return `<li${here ? ' class="here"' : ""}><a href="${href}">${escapeHtml(p.title)}</a>${subs}</li>`;
    })
    .join("");
}

function tocHtml(headings) {
  const items = headings.filter((h) => h.depth === 2 || h.depth === 3);
  if (items.length < 2) return "";
  return `<nav class="toc" aria-label="On this page">
  <p class="toc-title">On this page</p>
  <ul>${items
    .map((h) => `<li class="d${h.depth}"><a href="#${h.id}">${escapeHtml(h.text)}</a></li>`)
    .join("")}</ul>
</nav>`;
}

export function renderPage({ page, pages, css, js, indexPath }) {
  const prev = pages[pages.indexOf(page) - 1];
  const next = pages[pages.indexOf(page) + 1];
  const link = (p, rel) =>
    p
      ? `<a class="pager ${rel}" href="${p.slug === "index" ? "/" : `/${p.slug}/`}">
           <span>${rel === "prev" ? "Previous" : "Next"}</span><strong>${escapeHtml(p.title)}</strong></a>`
      : "";
  const canonical = page.slug === "index" ? "/" : `/${page.slug}/`;

  return `<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(page.title)} · ${SITE}</title>
<meta name="description" content="${escapeHtml(page.description)}">
<meta name="color-scheme" content="dark light">
<link rel="canonical" href="${canonical}">
<meta property="og:title" content="${escapeHtml(page.title)} · ${SITE}">
<meta property="og:description" content="${escapeHtml(page.description)}">
<meta property="og:type" content="article">
<link rel="stylesheet" href="/assets/${css}">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='7' fill='%23C8FF2E'/%3E%3Cpath d='M9 22V10h5.6c3.7 0 6 2.3 6 6s-2.3 6-6 6H9Zm3.2-2.7h2.2c2 0 3-1.2 3-3.3s-1-3.3-3-3.3h-2.2v6.6Z' fill='%23000'/%3E%3C/svg%3E">
<script>(function(){try{var t=localStorage.getItem('1dx-docs-theme');if(t)document.documentElement.dataset.theme=t}catch(e){}})()</script>
</head>
<body>
<a class="skip" href="#content">Skip to content</a>
<header class="topbar">
  <a class="brand" href="/"><span class="mark">1</span>delta x <span class="brand-sub">docs</span></a>
  <div class="search">
    <input id="q" type="search" placeholder="Search the docs…  /" autocomplete="off" spellcheck="false"
           aria-label="Search documentation" data-index="${indexPath}">
    <div id="results" class="results" hidden></div>
  </div>
  <div class="topbar-actions">
    <button id="theme" class="ghost" type="button" aria-label="Toggle colour theme">◐</button>
    <button id="menu" class="ghost only-narrow" type="button" aria-label="Toggle navigation">☰</button>
  </div>
</header>
<div class="layout">
  <nav class="sidebar" id="sidebar" aria-label="Documentation">
    <ul class="nav">${navHtml(pages, page)}</ul>
    <p class="sidebar-foot">
      <a href="https://github.com/1delta-DAO" target="_blank" rel="noopener">Source</a> ·
      <a href="mailto:security@1delta.io">security@1delta.io</a>
    </p>
  </nav>
  <main id="content">
    <article class="prose">
      <p class="eyebrow">${escapeHtml(page.eyebrow || "Documentation")}</p>
      <h1>${escapeHtml(page.title)}</h1>
      <p class="lede">${escapeHtml(page.description)}</p>
      ${page.html}
    </article>
    <nav class="pagers">${link(prev, "prev")}${link(next, "next")}</nav>
  </main>
  ${tocHtml(page.headings)}
</div>
<script src="/assets/${js}" defer></script>
</body>
</html>
`;
}
