/* Client behaviour: search, theme, nav toggle, scrollspy.
   No framework, no build step — the whole file is what ships. */

(function () {
  "use strict";

  /* ── theme ─────────────────────────────────────────────────────────────── */
  var root = document.documentElement;
  var themeButton = document.getElementById("theme");
  if (themeButton) {
    themeButton.addEventListener("click", function () {
      var next = root.dataset.theme === "light" ? "dark" : "light";
      root.dataset.theme = next;
      try { localStorage.setItem("1dx-docs-theme", next); } catch (e) {}
    });
  }

  /* ── narrow-screen nav ─────────────────────────────────────────────────── */
  var menu = document.getElementById("menu");
  var sidebar = document.getElementById("sidebar");
  if (menu && sidebar) {
    menu.addEventListener("click", function () { sidebar.classList.toggle("open"); });
  }

  /* ── search ────────────────────────────────────────────────────────────── */
  var input = document.getElementById("q");
  var panel = document.getElementById("results");
  if (!input || !panel) return;

  var index = null;
  var loading = null;
  var selected = -1;

  function load() {
    if (index) return Promise.resolve(index);
    if (!loading) {
      loading = fetch(input.dataset.index)
        .then(function (r) { return r.json(); })
        .then(function (data) {
          // Pre-lower once: every keystroke scans the whole index, and
          // lowercasing per query is what makes that scan feel slow.
          index = data.map(function (s) {
            return {
              p: s.p, pt: s.pt, h: s.h, a: s.a, t: s.t,
              hl: s.h.toLowerCase(), ptl: s.pt.toLowerCase(), tl: s.t.toLowerCase(),
            };
          });
          return index;
        });
    }
    return loading;
  }

  input.addEventListener("focus", load);

  function terms(query) {
    return query.toLowerCase().split(/[^a-z0-9_.]+/).filter(function (t) { return t.length > 1; });
  }

  function count(haystack, needle, cap) {
    var n = 0, at = haystack.indexOf(needle);
    while (at !== -1 && n < cap) { n++; at = haystack.indexOf(needle, at + needle.length); }
    return n;
  }

  /** Heading hits outrank body hits: on pages this long, the heading is the
      answer's address and the body is only evidence that it is there. */
  function score(section, ts) {
    var total = 0;
    for (var i = 0; i < ts.length; i++) {
      var t = ts[i], s = 0;
      if (section.hl.indexOf(t) !== -1) s += 24;
      if (section.ptl.indexOf(t) !== -1) s += 6;
      s += 3 * count(section.tl, t, 6);
      if (s === 0) return 0;          // AND: every term must appear somewhere
      total += s;
    }
    return total;
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function highlight(text, ts) {
    var html = escapeHtml(text);
    ts.forEach(function (t) {
      var safe = t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      html = html.replace(new RegExp("(" + safe + ")", "ig"), "<mark>$1</mark>");
    });
    return html;
  }

  function snippet(section, ts) {
    var at = -1;
    for (var i = 0; i < ts.length && at === -1; i++) at = section.tl.indexOf(ts[i]);
    if (at === -1) at = 0;
    var from = Math.max(0, at - 90);
    if (from > 0) {                       // snap to a word start, never mid-token
      var space = section.t.indexOf(" ", from);
      if (space !== -1 && space < at) from = space + 1;
    }
    var to = Math.min(section.t.length, from + 230);
    if (to < section.t.length) {
      var back = section.t.lastIndexOf(" ", to);
      if (back > from + 120) to = back;
    }
    return (from > 0 ? "… " : "") + section.t.slice(from, to) + (to < section.t.length ? " …" : "");
  }

  function href(section) {
    var base = section.p === "index" ? "/" : "/" + section.p + "/";
    return section.a ? base + "#" + section.a : base;
  }

  function run(query) {
    var ts = terms(query);
    if (!ts.length) { panel.hidden = true; panel.innerHTML = ""; return; }

    load().then(function (sections) {
      var hits = [];
      for (var i = 0; i < sections.length; i++) {
        var s = score(sections[i], ts);
        if (s > 0) hits.push({ s: s, section: sections[i] });
      }
      hits.sort(function (a, b) { return b.s - a.s; });
      hits = hits.slice(0, 12);

      selected = -1;
      panel.hidden = false;
      if (!hits.length) {
        panel.innerHTML = '<p class="empty">No match for <strong>' + escapeHtml(query) + "</strong>.</p>";
        return;
      }
      panel.innerHTML = hits
        .map(function (hit) {
          var s = hit.section;
          return (
            '<a class="hit" href="' + href(s) + '">' +
            '<span class="hit-top"><span class="hit-page">' + escapeHtml(s.pt) + "</span>" +
            '<span class="hit-head">' + highlight(s.h, ts) + "</span></span>" +
            '<span class="hit-text">' + highlight(snippet(s, ts), ts) + "</span></a>"
          );
        })
        .join("");
    });
  }

  var timer = null;
  input.addEventListener("input", function () {
    clearTimeout(timer);
    var value = input.value;
    timer = setTimeout(function () { run(value); }, 80);
  });

  function move(delta) {
    var hits = panel.querySelectorAll(".hit");
    if (!hits.length) return;
    if (selected >= 0) hits[selected].classList.remove("sel");
    selected = (selected + delta + hits.length) % hits.length;
    hits[selected].classList.add("sel");
    hits[selected].scrollIntoView({ block: "nearest" });
  }

  input.addEventListener("keydown", function (event) {
    if (event.key === "ArrowDown") { event.preventDefault(); move(1); }
    else if (event.key === "ArrowUp") { event.preventDefault(); move(-1); }
    else if (event.key === "Enter") {
      var hits = panel.querySelectorAll(".hit");
      var target = hits[selected >= 0 ? selected : 0];
      if (target) { event.preventDefault(); window.location.href = target.getAttribute("href"); }
    } else if (event.key === "Escape") { input.blur(); panel.hidden = true; }
  });

  document.addEventListener("click", function (event) {
    if (!panel.contains(event.target) && event.target !== input) panel.hidden = true;
  });

  document.addEventListener("keydown", function (event) {
    var typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
    if (event.key === "/" && !typing) { event.preventDefault(); input.focus(); input.select(); }
    if (event.key === "k" && (event.metaKey || event.ctrlKey)) { event.preventDefault(); input.focus(); input.select(); }
  });

  // `?q=` makes a search shareable — and is what the build's own smoke test
  // drives, since it needs the result list rendered without a keystroke.
  var initial = new URLSearchParams(window.location.search).get("q");
  if (initial) { input.value = initial; run(initial); }

  /* ── scrollspy for the on-this-page nav ────────────────────────────────── */
  var links = {};
  document.querySelectorAll(".toc a").forEach(function (a) { links[a.getAttribute("href").slice(1)] = a; });
  var headings = document.querySelectorAll(".prose h2[id], .prose h3[id]");
  if (headings.length && window.IntersectionObserver) {
    var seen = new Set();
    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) seen.add(entry.target.id); else seen.delete(entry.target.id);
        });
        var active = null;
        headings.forEach(function (h) { if (!active && seen.has(h.id)) active = h.id; });
        Object.keys(links).forEach(function (id) { links[id].classList.toggle("active", id === active); });
      },
      { rootMargin: "-70px 0px -70% 0px" },
    );
    headings.forEach(function (h) { observer.observe(h); });
  }
})();
