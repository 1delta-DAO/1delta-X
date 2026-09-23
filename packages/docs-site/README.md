# @1delta-x/docs-site

The public documentation site: what 1delta x does, how it works, its security
model and its optimization work. Four long pages plus a reference, with
client-side search over every section heading.

```bash
node build.mjs            # build into dist/
node build.mjs --serve    # build, then read it on http://localhost:4173
```

## Why there is no framework here

The site is five content files and a search index. A static-site generator would
add a dependency tree, a lockfile and an upgrade treadmill to a thing whose whole
build is one `node build.mjs` — which is also the Cloudflare Pages build command,
so the deployed artifact is produced by the same code path a local build is.

- `content/*.md` — the pages. Frontmatter sets `title`, `slug`, `eyebrow` and the
  `description` used for the page lede and the `<meta>` tag. File order (`00-`,
  `10-`, …) sets nav order.
- `src/markdown.mjs` — the markdown subset the content uses: four heading levels,
  paragraphs, fenced code, lists, pipe tables, blockquotes, rules, and inline
  `code` / `**bold**` / `[link](target)`. Unsupported syntax renders as the
  literal text it is.
- `src/template.mjs` — the page shell: top bar, search, nav, prose, on-this-page.
- `assets/docs.css`, `assets/docs.js` — copied to `dist/assets/` with a content
  hash in the filename, so they can be cached immutably.

## Search

`build.mjs` slices every page at its `##` / `###` headings and writes one JSON
index of `{page, heading, anchor, text}` records. The client fetches it on the
first focus of the search box, then scores sections per keystroke: heading
matches outrank body matches, and every query term must appear somewhere in a
section for it to be a hit. Results link to the heading anchor, not the page,
because these pages are long enough that "which page" is not an answer.

Keyboard: `/` or `⌘K` focuses the box, arrows move, Enter opens, Escape closes.
`?q=…` on any URL prefills and runs a search, so a search result is shareable.

The index is a few tens of KB and is fetched lazily, so it costs nothing on a
page view that does not search. If the content ever grows past a few hundred KB,
that is the point to reach for a prefix index rather than a linear scan — not
before.

## The build fails on a broken link

Every internal `href` — page and anchor, same-page and cross-page — is checked
against the headings the build just rendered, and a miss exits non-zero. Renaming
a heading therefore breaks the build rather than leaving a quiet 404 behind, which
is the failure mode a documentation site accumulates fastest.

## Deploying to Cloudflare Pages

Either connect the repository in the Cloudflare dashboard:

| Setting | Value |
|---|---|
| Build command | `node build.mjs` |
| Build output directory | `dist` |
| Root directory | `packages/docs-site` |
| Node version | 20 or newer |

…or deploy the built directory directly:

```bash
node build.mjs
npx wrangler pages deploy dist        # project name comes from wrangler.toml
```

The build also writes `_headers` (immutable caching for hashed assets, plus
`nosniff`, a referrer policy and a content-security policy), `404.html` (the full
shell, so a mistyped URL still has the nav and the search box), `robots.txt` and
`sitemap.txt`.

## Editing

Add a page by dropping a numbered file into `content/`; it appears in the nav and
the search index on the next build. Keep headings specific — they are the search
result titles, and a heading that says "Details" is a result nobody can read.
