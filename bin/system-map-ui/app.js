/* System map client. Buildless; talks only to the local server that served it.
   All content is inserted with textContent or DOM nodes, never as HTML. */
(function () {
  "use strict";

  var AUTO_MS = 30000;
  var COLLECT_POLL_MS = 4000;
  var SVGNS = "http://www.w3.org/2000/svg";

  var state = {
    project: null, view: null, loadedAt: null, error: null, lens: "observed", tab: "map",
    selected: null, dfilter: "open", timer: null, collecting: false,
    // Unsaved note and intent drafts, keyed "<target>|<field>". They survive
    // reloads and auto-refresh until saved or explicitly discarded.
    drafts: {},
    accessPhase: "all", accessQuery: "",
    zoom: 1
  };
  function draftKeys(prefix) { return Object.keys(state.drafts).filter(function (k) { return k.indexOf(prefix) === 0; }); }
  function dropDrafts(prefix) { draftKeys(prefix).forEach(function (k) { delete state.drafts[k]; }); }

  // ---------------------------------------------------------------- helpers
  function h(tag, attrs) {
    var el = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v === null || v === undefined || v === false) return;
        if (k === "text") el.textContent = v;
        else if (k === "class") el.className = v;
        else if (k.slice(0, 2) === "on") el.addEventListener(k.slice(2), v);
        else el.setAttribute(k, v === true ? "" : v);
      });
    }
    for (var i = 2; i < arguments.length; i++) append(el, arguments[i]);
    return el;
  }
  function append(el, child) {
    if (child === null || child === undefined || child === false) return;
    if (Array.isArray(child)) { child.forEach(function (c) { append(el, c); }); return; }
    el.appendChild(typeof child === "string" || typeof child === "number" ? document.createTextNode(String(child)) : child);
  }
  function s(tag, attrs) {
    var el = document.createElementNS(SVGNS, tag);
    Object.keys(attrs || {}).forEach(function (k) {
      if (k === "text") el.textContent = attrs[k];
      else if (k.slice(0, 2) === "on") el.addEventListener(k.slice(2), attrs[k]);
      else if (attrs[k] !== null && attrs[k] !== undefined) el.setAttribute(k, attrs[k]);
    });
    return el;
  }
  function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }
  function $(id) { return document.getElementById(id); }

  function parseTime(v) { var t = Date.parse(v); return isNaN(t) ? null : t; }
  function ago(v) {
    var t = parseTime(v);
    if (t === null) return "never";
    var sec = Math.round((Date.now() - t) / 1000);
    var future = sec < 0; sec = Math.abs(sec);
    var txt = sec < 90 ? sec + "s" : sec < 5400 ? Math.round(sec / 60) + "m" : sec < 172800 ? Math.round(sec / 3600) + "h" : Math.round(sec / 86400) + "d";
    return future ? "in " + txt : txt + " ago";
  }
  function stamp(v) {
    var t = parseTime(v);
    if (t === null) return h("span", { class: "muted", text: "no time recorded" });
    return h("time", { datetime: v, title: new Date(t).toLocaleString() }, ago(v) + " (" + v.replace("T", " ").replace(/\.\d+/, "") + ")");
  }

  var TONES = {
    runtime: { "as-intended": "ok", deviation: "bad", partial: "warn", denied: "bad", error: "bad", unknown: "unknown", unobserved: "none", "not-observed": "none", observed: "info" },
    implementation: { complete: "ok", built: "ok", "in-progress": "info", partial: "warn", "not-started": "warn", unknown: "unknown" },
    deployment: { deployed: "ok", mismatch: "bad", absent: "absent", unknown: "unknown", untracked: "none" },
    proof: { proven: "ok", failed: "bad", stale: "warn", unversioned: "warn", "not-demonstrated": "quiet", unknown: "unknown" },
    outcome: { ok: "ok", absent: "absent", denied: "bad", error: "bad", unknown: "unknown" },
    result: { pass: "ok", fail: "bad", "not-run": "quiet" },
    acceptance: { passed: "ok", failed: "bad", stale: "warn", unversioned: "warn", "not-demonstrated": "quiet" },
    severity: { high: "bad", medium: "warn", low: "info", info: "quiet" },
    collector: { ok: "ok", partial: "warn", failed: "bad" }
  };
  TONES.prerequisite = { present: "info", absent: "absent", denied: "bad", unknown: "unknown", stale: "warn", "not-tested": "quiet", mismatch: "bad", error: "bad", observed: "info" };
  var LABELS = {
    "as-intended": "as intended", "not-observed": "not observed", unobserved: "not observed",
    "not-demonstrated": "not demonstrated", "in-progress": "in progress", "not-started": "not started", "not-run": "not run",
    ok: "read ok", unversioned: "passed, not version-bound"
  };
  function chip(kind, value, extra) {
    var tone = (TONES[kind] || {})[value] || "none";
    return h("span", { class: "chip chip--" + tone, title: extra || null }, LABELS[value] || value || "none");
  }

  function api(path, opts) {
    opts = opts || {};
    var init = { method: opts.method || "GET", headers: { "Accept": "application/json" }, cache: "no-store" };
    if (opts.body) {
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(opts.body);
    }
    return fetch(path, init).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (!res.ok) { var err = new Error(data.error || ("HTTP " + res.status)); err.status = res.status; throw err; }
        return data;
      });
    });
  }

  // ---------------------------------------------------------------- hash
  function readHash() {
    var params = new URLSearchParams(location.hash.slice(1));
    if (params.get("tab")) state.tab = params.get("tab");
    if (params.get("lens")) state.lens = params.get("lens");
    if (params.get("subject")) state.selected = params.get("subject");
    if (params.get("project")) state.project = params.get("project");
  }
  function writeHash() {
    var params = new URLSearchParams();
    if (state.project) params.set("project", state.project);
    params.set("tab", state.tab);
    params.set("lens", state.lens);
    if (state.selected) params.set("subject", state.selected);
    history.replaceState(null, "", "#" + params.toString());
  }

  // ---------------------------------------------------------------- load
  function load() {
    if (!state.project) return Promise.resolve();
    $("reload").disabled = true;
    return api("/api/state?project=" + encodeURIComponent(state.project)).then(function (view) {
      state.view = view; state.loadedAt = new Date(); state.error = null;
      state.collecting = !!view.collecting;
      render();
    }).catch(function (err) {
      state.error = err.message;
      renderBanners();
      renderHealth();
    }).then(function () {
      $("reload").disabled = false;
      schedule();
    });
  }
  function schedule() {
    clearTimeout(state.timer);
    var auto = $("auto").checked;
    if (state.collecting) state.timer = setTimeout(load, COLLECT_POLL_MS);
    else if (auto) state.timer = setTimeout(load, AUTO_MS);
  }
  function collectNow() {
    $("collect").disabled = true;
    api("/api/collect", { method: "POST", body: { project: state.project } }).then(function () {
      state.collecting = true; renderHealth(); schedule();
    }).catch(function (err) {
      state.error = err.status === 409 ? "A collection is already running." : err.message;
      state.collecting = err.status === 409;
      renderBanners(); schedule();
    }).then(function () { $("collect").disabled = false; });
  }

  // ---------------------------------------------------------------- render
  function render() {
    renderHealth();
    renderBanners();
    renderMap();
    renderEdgeTable();
    renderDetail();
    renderDiff();
    renderTimeline();
    renderAcceptance();
    renderReadiness();
    renderAccess();
    renderCredentials();
    showTab(state.tab, false);
  }

  function renderHealth() {
    var el = clear($("health"));
    var v = state.view;
    if (!v) { append(el, h("span", { text: state.error ? "Map unavailable" : "Loading…" })); return; }
    var c = v.collector || {};
    if (c.fixture) append(el, h("span", { class: "chip chip--bad", text: "TEST DATA" }));
    append(el, h("span", null, "Observations ", chip("collector", c.last_status || "never", c.last_error || null)));
    append(el, h("span", null, "last success ", h("strong", { text: ago(c.last_success_at) })));
    var scope = v.scope || {};
    var verified = scope.account_verified === true ? "account verified" : scope.account_verified === false ? "account NOT verified" : "account unverified";
    if (scope.region || scope.account_label) append(el, h("span", { text: [scope.account_label, scope.region].filter(Boolean).join(" · ") + " · " + verified }));
    append(el, h("span", { text: "intent r" + v.manifest.revision }));
    if (c.activity) append(el, h("span", { title: c.activity.reasons.map(function (r) { return r.task + ": " + r.source; }).join(", "), text: (c.activity.active ? "active" : "idle") + " cadence · " + Math.round(c.interval_seconds / 60) + "m" }));
    if (state.collecting) append(el, h("span", { class: "chip chip--info", text: "collecting…" }));
    if (state.loadedAt) append(el, h("span", { title: state.loadedAt.toLocaleString(), text: "page loaded " + ago(state.loadedAt.toISOString()) }));
  }

  function renderBanners() {
    var el = clear($("banners"));
    if (state.error) {
      append(el, h("p", { class: "banner banner--danger", role: "alert" }, h("strong", { text: "Could not load the map: " }), state.error,
        state.loadedAt ? " Showing data loaded " + ago(state.loadedAt.toISOString()) + "." : ""));
    }
    var v = state.view;
    if (!v) return;
    var c = v.collector || {};
    if (c.fixture) {
      append(el, h("p", { class: "banner banner--danger", role: "alert" }, h("strong", { text: "Test data. " }),
        "These observations came from a test stand-in for the AWS CLI, not from live AWS. Nothing here describes the real account."));
    }
    if (!c.last_attempt_at) {
      append(el, h("p", { class: "banner banner--warn" }, h("strong", { text: "Never collected. " }), "Every observed state below is unknown until the first collection runs."));
    } else if (c.last_status === "failed") {
      append(el, h("p", { class: "banner banner--danger" }, h("strong", { text: "The last collection failed " + ago(c.last_attempt_at) + ". " }),
        c.last_error || "", " Displayed observations come from the latest published snapshot; failed reads show their errors and earlier successful reads are labeled separately."));
    } else if (c.stale) {
      append(el, h("p", { class: "banner banner--warn" }, h("strong", { text: "Observations are stale. " }),
        "Last success " + ago(c.last_success_at) + "; the collector should run every " + Math.round(v.config.active_interval / 60) + " minutes while work is under way and every " + Math.round(v.config.idle_interval / 60) + " minutes when idle."));
    } else if (c.last_status === "partial") {
      append(el, h("p", { class: "banner banner--info" }, "Some reads failed in the last collection; those observations show their error and the last successful read separately."));
    }
    if (c.manifest_revision_at_snapshot && c.manifest_revision_at_snapshot !== v.manifest.revision) {
      append(el, h("p", { class: "banner banner--info" }, "The intended design changed (r" + v.manifest.revision + ") after the last collection (r" + c.manifest_revision_at_snapshot + "). New observations arrive with the next collection."));
    }
  }

  function subjectTone(sub) {
    if (state.lens === "intended") return { tone: "none", text: intendedText(sub) };
    if (state.lens === "difference") return { tone: sub.discrepancies.length ? "bad" : "none", text: sub.discrepancies.length ? sub.discrepancies.length + " open difference" + (sub.discrepancies.length > 1 ? "s" : "") : "no open difference", faded: !sub.discrepancies.length };
    var rt = sub.layers.runtime;
    if (rt.status === "not-observed" || rt.status === "unobserved") {
      var impl = sub.layers.implementation.status;
      return { tone: "none", text: "not observed · " + (LABELS[impl] || impl) };
    }
    var tone = TONES.runtime[rt.status] || "none";
    if (rt.status === "observed" && rt.observed === "absent") tone = "absent";
    return { tone: tone, text: (rt.observed || LABELS[rt.status] || rt.status) + (rt.status === "deviation" ? " ≠ " + rt.intended : "") };
  }
  function intendedText(sub) {
    var mode = state.view.manifest.expected_mode;
    var want = (sub.intended || {})[mode];
    return want ? mode + ": " + want : "no runtime intent";
  }

  function nodeGeometry(v) {
    var ids = v.order.components, pos = {}, maxX = 0, maxY = 0, auto = 0;
    ids.forEach(function (id) {
      var sub = v.subjects[id];
      var x = typeof sub.x === "number" ? sub.x : (auto % 5);
      var y = typeof sub.y === "number" ? sub.y : Math.floor(auto / 5) + 5;
      if (typeof sub.x !== "number") auto++;
      pos[id] = { x: 36 + x * 214, y: 44 + y * 108, w: 186, h: 62 };
      maxX = Math.max(maxX, pos[id].x + 186); maxY = Math.max(maxY, pos[id].y + 62);
    });
    return { pos: pos, width: maxX + 36, height: maxY + 30 };
  }
  function clip(a, b) {
    // Point where the segment from a's centre toward b's centre leaves a's box.
    var cx = a.x + a.w / 2, cy = a.y + a.h / 2, tx = b.x + b.w / 2, ty = b.y + b.h / 2;
    var dx = tx - cx, dy = ty - cy;
    if (!dx && !dy) return { x: cx, y: cy };
    var sx = dx ? (a.w / 2) / Math.abs(dx) : Infinity, sy = dy ? (a.h / 2) / Math.abs(dy) : Infinity;
    var k = Math.min(sx, sy);
    return { x: cx + dx * k, y: cy + dy * k };
  }

  function select(id, focusDetail) {
    state.selected = id; writeHash();
    renderMap(); renderEdgeTable(); renderDetail();
    if (focusDetail) $("detail").focus();
  }
  function activate(ev, id) {
    if (ev.type === "click" || ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); select(id, ev.type !== "click"); }
  }

  function renderMap() {
    var v = state.view, holder = clear($("canvas"));
    if (!v) return;
    document.querySelectorAll("[data-lens]").forEach(function (b) { b.setAttribute("aria-checked", String(b.dataset.lens === state.lens)); });
    $("mode-line").textContent = "Intended mode right now: " + v.manifest.expected_mode + ". " +
      (state.lens === "intended" ? "Showing the intended state of each component." : state.lens === "observed" ? "Showing the latest observed runtime state." : "Showing only what differs from the intended design.");
    var g = nodeGeometry(v);
    var svg = s("svg", { viewBox: "0 0 " + g.width + " " + g.height, role: "group", "aria-label": "System map of " + v.manifest.title });
    var defs = s("defs");
    var marker = s("marker", { id: "arrow", viewBox: "0 0 10 10", refX: "9", refY: "5", markerWidth: "7", markerHeight: "7", orient: "auto-start-reverse" });
    marker.appendChild(s("path", { d: "M0 0 L10 5 L0 10 z", class: "arrow" }));
    defs.appendChild(marker); svg.appendChild(defs);
    var groupLayer = s("g"), edgeLayer = s("g"), nodeLayer = s("g"), labelLayer = s("g");
    // Group containers mark the manifest's groups (trust and ownership
    // boundaries) as boxes around their members, so the architecture's
    // boundaries stay visible instead of a flat graph.
    (v.manifest.groups || []).forEach(function (grp) {
      var members = v.order.components.filter(function (id) { return v.subjects[id].group === grp.id; });
      if (!members.length) return;
      var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      members.forEach(function (id) { var p = g.pos[id]; x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x + p.w); y1 = Math.max(y1, p.y + p.h); });
      groupLayer.appendChild(s("rect", { x: x0 - 14, y: y0 - 30, width: x1 - x0 + 28, height: y1 - y0 + 44, rx: 12, class: "grp-band" }));
      groupLayer.appendChild(s("text", { x: x0 - 4, y: y0 - 12, class: "grp-label", text: grp.title }));
    });
    v.order.connections.forEach(function (id) {
      var e = v.subjects[id], a = g.pos[e.from], b = g.pos[e.to];
      if (!a || !b) return;
      var p1 = clip(a, b), p2 = clip(b, a);
      var tone = state.lens === "difference" ? (e.discrepancies.length ? "bad" : "faded")
        : state.lens === "observed" ? ({ ok: "ok", bad: "bad", warn: "warn" })[TONES.runtime[e.layers.runtime.status]] || ({ "not-started": "bad", partial: "warn" })[e.layers.implementation.status] || "" : "";
      var label = e.title + ": " + (v.subjects[e.from] || {}).title + " to " + (v.subjects[e.to] || {}).title;
      var grp = s("g", { class: "edge", tabindex: "0", role: "button", "aria-label": "Connection " + label, "aria-pressed": String(state.selected === id), "data-tone": tone,
        onclick: function (ev) { activate(ev, id); }, onkeydown: function (ev) { activate(ev, id); } });
      var d = "M" + p1.x + " " + p1.y + " L" + p2.x + " " + p2.y;
      grp.appendChild(s("path", { d: d, class: "edge__hit" }));
      grp.appendChild(s("path", { d: d, class: "edge__line", "marker-end": "url(#arrow)" }));
      var title = s("title", { text: label }); grp.appendChild(title);
      edgeLayer.appendChild(grp);
      if (state.selected === id) {
        labelLayer.appendChild(s("text", { x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 - 6, "text-anchor": "middle", class: "edge__label", text: e.title }));
      }
    });
    v.order.components.forEach(function (id) {
      var sub = v.subjects[id], p = g.pos[id], t = subjectTone(sub);
      var grp = s("g", { class: "node", tabindex: "0", role: "button", "aria-pressed": String(state.selected === id), "data-tone": t.tone, "data-faded": String(!!t.faded),
        "aria-label": sub.title + ": " + t.text, onclick: function (ev) { activate(ev, id); }, onkeydown: function (ev) { activate(ev, id); } });
      grp.appendChild(s("rect", { x: p.x, y: p.y, width: p.w, height: p.h, rx: 9, class: "node__box" }));
      grp.appendChild(s("rect", { x: p.x + 1, y: p.y + 8, width: 4, height: p.h - 16, rx: 2, class: "node__tone" }));
      grp.appendChild(s("text", { x: p.x + 14, y: p.y + 25, class: "node__title", "data-max": String(p.w - 24), text: sub.title }));
      grp.appendChild(s("text", { x: p.x + 14, y: p.y + 45, class: "node__sub", "data-max": String(p.w - 24), text: t.text }));
      if (sub.discrepancies.length && state.lens !== "intended") {
        grp.appendChild(s("circle", { cx: p.x + p.w - 4, cy: p.y + 4, r: 9, class: "node__badge" }));
        grp.appendChild(s("text", { x: p.x + p.w - 4, y: p.y + 7.5, "text-anchor": "middle", class: "node__badge-text", text: String(sub.discrepancies.length) }));
      }
      grp.appendChild(s("title", { text: sub.title + " - " + t.text }));
      nodeLayer.appendChild(grp);
    });
    svg.appendChild(groupLayer); svg.appendChild(edgeLayer); svg.appendChild(nodeLayer); svg.appendChild(labelLayer);
    // Natural size by default inside a scrolling frame; "fit" shrinks to the frame.
    if (state.zoom === "fit") { svg.style.width = "100%"; svg.style.minWidth = "0"; }
    else { svg.style.width = Math.round(g.width * state.zoom) + "px"; svg.style.minWidth = "0"; }
    holder.appendChild(svg);
    fitLabels(svg);
    $("zoom-level").textContent = state.zoom === "fit" ? "fit" : Math.round(state.zoom * 100) + "%";
    renderLegend();
  }
  // Shorten node labels until they fit their box; full titles stay in the
  // tooltip, the accessible name, and the detail panel.
  function fitLabels(svg) {
    svg.querySelectorAll("text[data-max]").forEach(function (t) {
      var max = Number(t.getAttribute("data-max")), full = t.textContent, n = full.length;
      if (!t.getComputedTextLength) return;
      while (n > 1 && t.getComputedTextLength() > max) { n--; t.textContent = full.slice(0, n) + "…"; }
    });
  }
  function trunc(t, n) { t = String(t || ""); return t.length > n ? t.slice(0, n - 1) + "…" : t; }

  function renderLegend() {
    var el = clear($("legend"));
    var items = state.lens === "intended" ? [["none", "Intended state for the current mode"]]
      : state.lens === "difference" ? [["bad", "Has an open difference"], ["none", "No open difference (dimmed)"]]
      : [["ok", "As intended"], ["bad", "Deviates, denied, or read failed"], ["warn", "Partly observed"], ["unknown", "Unknown: not read successfully"],
         ["absent", "Absent: read succeeded, resource not found"], ["info", "Observed, no intent to compare"], ["none", "Not observed by any collector"]];
    items.forEach(function (it) {
      var sw = s("svg", { width: "26", height: "16", viewBox: "0 0 26 16", "aria-hidden": "true" });
      var cls = it[0] === "unknown" ? "node" : "node";
      var g = s("g", { class: cls, "data-tone": it[0] });
      g.appendChild(s("rect", { x: 1, y: 1, width: 24, height: 14, rx: 3, class: "node__box" }));
      g.appendChild(s("rect", { x: 2, y: 4, width: 3, height: 8, rx: 1, class: "node__tone" }));
      sw.appendChild(g);
      el.appendChild(h("li", null, sw, it[1]));
    });
    if (state.lens !== "intended") el.appendChild(h("li", null, h("span", { class: "count", text: "2" }), "Open differences on that component"));
    el.appendChild(h("li", null, h("span", { class: "chip chip--hist", text: "historical" }), "Old evidence, never counted for the current version"));
  }

  function renderEdgeTable() {
    var v = state.view, body = $("edge-table").tBodies[0];
    clear(body);
    if (!v) return;
    v.order.connections.forEach(function (id) {
      var e = v.subjects[id];
      body.appendChild(h("tr", { "aria-selected": String(state.selected === id) },
        h("td", null, h("button", { type: "button", class: "btn--link btn", text: e.title, onclick: function () { select(id, true); } })),
        h("td", { text: (v.subjects[e.from] || {}).title || e.from }),
        h("td", { text: (v.subjects[e.to] || {}).title || e.to }),
        h("td", null, chip("implementation", e.layers.implementation.status)),
        h("td", null, chip("runtime", e.layers.runtime.status)),
        h("td", null, chip("proof", e.layers.proof.status))));
    });
  }

  function provenance(p) {
    if (!p) return null;
    var kind = { receipt: "machine receipt", "imported-report": "imported from a report", manual: "operator assertion" }[p.kind || "receipt"] || p.kind;
    return h("div", { class: "item__foot" }, "Source: " + p.source + " (" + kind + ", not a live collector read)",
      p.by ? " · by " + p.by : "",
      p.path ? [" · ", h("code", { text: p.path })] : "",
      p.url ? [" · ", h("a", { href: p.url, rel: "noreferrer noopener", target: "_blank", text: p.url })] : "");
  }

  function renderDetail() {
    var el = $("detail"), v = state.view;
    var active = document.activeElement;
    // Never rebuild the panel under the caret; drafts cover every other case.
    if (active && el.contains(active) && (active.tagName === "TEXTAREA" || active.tagName === "INPUT")) return;
    clear(el);
    if (!v) return;
    var sub = state.selected && v.subjects[state.selected];
    if (!sub) {
      append(el, h("h2", { class: "detail__title", text: v.manifest.title }));
      append(el, h("p", { text: v.manifest.description || "" }));
      append(el, h("p", { class: "detail__empty", text: "Select a component or connection on the map, or a connection in the list below it, to see its intended design, observations, evidence and differences. Escape clears the selection." }));
      append(el, annotationsBlock("design", v.annotations.filter(function (a) { return a.target === "design"; })));
      return;
    }
    var isEdge = sub.type === "connection";
    append(el, h("h2", { class: "detail__title", text: sub.title }));
    append(el, h("p", { class: "detail__meta" }, (isEdge ? "Connection" : "Component") + (sub.kind ? " · " + sub.kind : "") + (sub.group ? " · " + groupTitle(sub.group) : "") +
      (isEdge ? " · " + (v.subjects[sub.from] || {}).title + " → " + (v.subjects[sub.to] || {}).title : "")));
    if (sub.description) append(el, h("p", { text: sub.description }));
    if (sub.owners && sub.owners.length) append(el, h("p", { class: "muted" }, "Owner: " + sub.owners.map(function (o) { return (o.name || o.task || o.role) + (o.task && o.name ? " (task " + o.task + ")" : ""); }).join(", ")));
    if (sub.exception) append(el, h("p", { class: "callout" }, h("strong", { text: "Accepted exception: " }), sub.exception.text, sub.exception.until ? " Until: " + sub.exception.until + "." : "", sub.exception.approved_by ? " Approved by " + sub.exception.approved_by + "." : ""));

    var intended = Object.keys(sub.intended || {});
    append(el, h("h3", { class: "h3", text: "Status, layer by layer" }));
    var L = sub.layers, dl = h("dl", { class: "layers" });
    function row(name, kind, layer, extra) {
      dl.appendChild(h("dt", { text: name }));
      dl.appendChild(h("dd", null, chip(kind, layer.status), h("span", { class: "sub", text: layer.detail || "" }), extra || null));
    }
    row("Implementation", "implementation", L.implementation, L.implementation.evidence ? h("span", { class: "sub" }, "Evidence: ", h("code", { text: L.implementation.evidence })) : null);
    row("Deployment", "deployment", L.deployment);
    row("Runtime", "runtime", { status: L.runtime.status, detail: "Observed: " + (L.runtime.observed || "nothing yet") + " · intended (" + v.manifest.expected_mode + "): " + (L.runtime.intended || "none declared") });
    row("Proof", "proof", L.proof);
    append(el, dl);
    var access = v.access || { interactions: [], dependencies: [] };
    var related = access.interactions.filter(function (i) { return i.caller === sub.id || i.target === sub.id || i.identity === sub.id || i.dependencies.some(function (id) { return access.dependencies.some(function (d) { return d.id === id && d.subject === sub.id; }); }); });
    if (related.length) append(el, [h("h3", { class: "h3", text: "Required access" }), accessList(related), h("button", { type: "button", class: "btn", text: "Open consolidated access coverage", onclick: function () { showTab("access", true); } })]);
    if (sub.lineage && sub.lineage.length) append(el, lineageList(sub.lineage));
    if (sub.live_verified !== null && sub.live_verified !== undefined) {
      append(el, h("p", { class: sub.live_verified === true ? "muted" : "callout" }, sub.live_verified === true ? "Landed work on this subject is live-verified by later passing evidence at the current version."
        : sub.live_verified === "unversioned" ? "Landed work on this subject has later passing evidence, but the subject declares no version source, so it is not live-verified across deployments."
        : "Landed work on this subject is implementation-complete but not live-verified."));
    }
    if (intended.length) append(el, h("p", { class: "muted", text: "Intended by mode: " + intended.map(function (m) { return m + " = " + sub.intended[m]; }).join(" · ") }));

    if (sub.discrepancies.length) {
      append(el, h("h3", { class: "h3", text: "Open differences" }));
      var dlist = h("ul", { class: "list" });
      v.discrepancies.filter(function (d) { return sub.discrepancies.indexOf(d.id) >= 0; }).forEach(function (d) {
        dlist.appendChild(h("li", { class: "item" }, h("div", { class: "item__head" }, chip("severity", d.severity), h("strong", { text: d.title })), d.detail ? h("div", { text: d.detail }) : null,
          h("div", { class: "item__foot", text: d.id + " · first seen " + ago(d.first_seen) + (d.links && d.links.length ? " · linked to " + d.links.join(", ") : "") })));
      });
      append(el, dlist);
    }

    if (sub.observations.length) {
      append(el, h("h3", { class: "h3", text: "Observations" }));
      var olist = h("ul", { class: "list" });
      sub.observations.forEach(function (o) {
        var cur = o.current;
        var li = h("li", { class: "item" });
        if (!cur) {
          append(li, h("div", { class: "item__head" }, chip("outcome", "unknown"), h("strong", { text: o.id }), h("span", { class: "muted", text: o.adapter })));
          append(li, h("div", { class: "muted", text: "Never collected." }));
        } else {
          append(li, h("div", { class: "item__head" }, chip("outcome", cur.outcome), h("strong", { text: o.id }), h("span", { class: "muted", text: o.adapter + (cur.resource_label ? " · " + cur.resource_label : "") })));
          var kv = h("dl", { class: "kv" });
          kv.appendChild(h("dt", { text: "state" })); kv.appendChild(h("dd", { text: cur.state || "-" }));
          if (cur.version) { kv.appendChild(h("dt", { text: "version" })); kv.appendChild(h("dd", null, h("code", { text: cur.version }))); }
          Object.keys(cur.facts || {}).forEach(function (k) {
            var val = cur.facts[k];
            if (val === null || val === undefined || val === "") return;
            kv.appendChild(h("dt", { text: k })); kv.appendChild(h("dd", { text: typeof val === "object" ? JSON.stringify(val) : String(val) }));
          });
          kv.appendChild(h("dt", { text: "checked" })); kv.appendChild(h("dd", null, stamp(cur.checked_at)));
          var sc = cur.scope || {};
          kv.appendChild(h("dt", { text: "scope" })); kv.appendChild(h("dd", { text: sc.kind === "local" ? "local host" : [sc.account_label, sc.region].filter(Boolean).join(" · ") + (sc.account_verified === true ? " · account verified" : sc.account_verified === false ? " · account NOT verified" : " · account unverified") }));
          if (cur.error) { kv.appendChild(h("dt", { text: "error" })); kv.appendChild(h("dd", { text: cur.error })); }
          append(li, kv);
          if (o.last_success) {
            append(li, h("div", { class: "historic" }, h("strong", { text: "Last successful read (historical, not current): " }),
              (o.last_success.state || o.last_success.outcome) + " at ", stamp(o.last_success.checked_at)));
          }
        }
        olist.appendChild(li);
      });
      append(el, olist);
    }

    append(el, h("h3", { class: "h3", text: "Evidence" }));
    if (!sub.evidence.length) append(el, h("p", { class: "muted", text: "No evidence records name this " + (isEdge ? "connection" : "component") + "." }));
    else {
      var elist = h("ul", { class: "list" });
      sub.evidence.forEach(function (r) {
        elist.appendChild(h("li", { class: "item" },
          h("div", { class: "item__head" }, chip("result", r.result), r.historical ? h("span", { class: "chip chip--hist", text: "historical" }) : null,
            h("strong", { text: r.id }), h("span", { class: "muted", text: r.qualification })),
          h("div", { text: r.summary }),
          h("div", { class: "item__foot" }, "Recorded ", stamp(r.recorded_at), r.observed_at ? [" · observed ", stamp(r.observed_at)] : "",
            r.versions && Object.keys(r.versions).length ? " · versions: " + Object.keys(r.versions).map(function (k) { return k + "=" + r.versions[k]; }).join(", ") : " · no version named",
            r.run_id ? " · run " + r.run_id : ""),
          provenance(r.provenance)));
      });
      append(el, elist);
    }

    if (sub.credentials.length) {
      append(el, h("h3", { class: "h3", text: "Credentials (metadata only)" }));
      var clist = h("ul", { class: "list" });
      sub.credentials.forEach(function (c) { clist.appendChild(credItem(c)); });
      append(el, clist);
    }
    if (sub.tasks.length) {
      append(el, h("h3", { class: "h3", text: "Bound Firstmate tasks" }));
      append(el, h("ul", { class: "list" }, sub.tasks.map(function (t) {
        return h("li", { class: "item" }, h("strong", { text: t.task }), " bound ", stamp(t.bound_at), t.note ? h("div", { text: t.note }) : null);
      })));
    }
    append(el, annotationsBlock(sub.id, sub.annotations));
    append(el, editBlock(sub));
  }
  function groupTitle(id) {
    var g = (state.view.manifest.groups || []).filter(function (x) { return x.id === id; })[0];
    return g ? g.title : id;
  }
  function credItem(c) {
    var exp = (c.expiry_basis || "observed") === "observed" ? parseTime(c.expires) : null, soon = exp !== null && exp - Date.now() < 7 * 86400000;
    return h("li", { class: "item" }, h("div", { class: "item__head" }, h("strong", { text: c.title }), c.kind ? h("span", { class: "muted", text: c.kind }) : null,
      exp === null ? h("span", { class: "chip chip--unknown", text: "expiry not recorded" }) : h("span", { class: "chip chip--" + (exp < Date.now() ? "bad" : soon ? "warn" : "ok"), text: exp < Date.now() ? "expired" : "expires " + ago(c.expires) })),
      h("div", { text: c.purpose }), h("div", { class: "item__foot", text: "Owner: " + (c.owner || "not recorded") + (c.rotation ? " · Rotation: " + c.rotation : "") + (c.note ? " · " + c.note : "") }));
  }

  function annotationsBlock(target, list) {
    var wrap = h("div");
    append(wrap, h("h3", { class: "h3", text: "Notes" }));
    var open = list.filter(function (a) { return !a.resolved_at; }), done = list.filter(function (a) { return a.resolved_at; });
    if (!open.length) append(wrap, h("p", { class: "muted", text: "No open notes." }));
    var ul = h("ul", { class: "list" });
    open.forEach(function (a) {
      ul.appendChild(h("li", { class: "item" }, h("div", { text: a.text }),
        h("div", { class: "item__foot" }, a.author + " · ", stamp(a.created_at), " · ",
          h("button", { type: "button", class: "btn btn--link", text: "Mark resolved", onclick: function () { resolveNote(a.id); } }))));
    });
    append(wrap, ul);
    if (done.length) append(wrap, h("p", { class: "muted", text: done.length + " resolved note" + (done.length > 1 ? "s" : "") + " kept in the record." }));
    var msg = h("p", { class: "form-msg", role: "status" });
    var key = target + "|note";
    var ta = h("textarea", { id: "note-text", name: "text", maxlength: "4000", placeholder: "What should the next reader know?" });
    ta.value = state.drafts[key] || "";
    ta.addEventListener("input", function () { if (ta.value) state.drafts[key] = ta.value; else delete state.drafts[key]; });
    var discard = h("button", { type: "button", class: "btn btn--small", text: "Discard draft", hidden: !state.drafts[key], onclick: function () {
      delete state.drafts[key]; ta.value = ""; discard.hidden = true; msg.className = "form-msg"; msg.textContent = "Draft discarded.";
    } });
    ta.addEventListener("input", function () { discard.hidden = !ta.value; });
    var form = h("form", { class: "stack", onsubmit: function (ev) {
      ev.preventDefault();
      if (!ta.value.trim()) { msg.className = "form-msg form-msg--bad"; msg.textContent = "Write the note first."; return; }
      api("/api/annotate", { method: "POST", body: { project: state.project, target: target, text: ta.value } }).then(function () {
        delete state.drafts[key]; ta.value = ""; msg.className = "form-msg form-msg--ok"; msg.textContent = "Note saved."; return load();
      }).catch(function (err) { msg.className = "form-msg form-msg--bad"; msg.textContent = "Not saved: " + err.message; });
    } }, h("label", { class: "field", for: "note-text" }, "Add a note", ta), h("div", { class: "row" }, h("button", { type: "submit", class: "btn btn--small", text: "Save note" }), discard), msg);
    append(wrap, form);
    return wrap;
  }
  function resolveNote(id) {
    api("/api/annotation/resolve", { method: "POST", body: { project: state.project, id: id } }).then(load).catch(function (err) { state.error = err.message; renderBanners(); });
  }

  function editBlock(sub) {
    var v = state.view, msg = h("p", { class: "form-msg", role: "status" });
    var fields = [["title", "Title", sub.title, "input"], ["description", "Description", sub.description || "", "textarea"]];
    v.manifest.modes.forEach(function (m) { fields.push(["intended." + m, "Intended state while " + m, (sub.intended || {})[m] || "", "input"]); });
    var inputs = {}, prefix = sub.id + "|edit|";
    var reason = h("input", { type: "text", id: "edit-reason", placeholder: "Why the intent changed (recorded in history)" });
    if ((prefix + "reason") in state.drafts) reason.value = state.drafts[prefix + "reason"];
    reason.addEventListener("input", function () { if (reason.value) state.drafts[prefix + "reason"] = reason.value; else delete state.drafts[prefix + "reason"]; });
    var form = h("form", { class: "stack", onsubmit: function (ev) {
      ev.preventDefault();
      var changes = fields.filter(function (f) { return inputs[f[0]].value !== f[2]; });
      if (!changes.length) { msg.className = "form-msg"; msg.textContent = "Nothing changed."; return; }
      var rev = v.manifest.revision, chain = Promise.resolve();
      changes.forEach(function (f) {
        chain = chain.then(function () {
          return api("/api/intent", { method: "POST", body: { project: state.project, subject: sub.id, field: f[0], value: inputs[f[0]].value, base_revision: rev, reason: reason.value } })
            .then(function (res) { rev = res.revision; });
        });
      });
      chain.then(function () { dropDrafts(prefix); msg.className = "form-msg form-msg--ok"; msg.textContent = "Intended design saved as r" + rev + ". Observed facts are unchanged."; return load(); })
        .catch(function (err) { msg.className = "form-msg form-msg--bad"; msg.textContent = (err.status === 409 ? "Someone changed the design first: " : "Not saved: ") + err.message; });
    } });
    fields.forEach(function (f) {
      var id = "edit-" + f[0].replace(/\W/g, "-");
      var input = f[3] === "textarea" ? h("textarea", { id: id, maxlength: "4000" }) : h("input", { type: "text", id: id, maxlength: "400" });
      var dkey = prefix + f[0];
      input.value = dkey in state.drafts ? state.drafts[dkey] : f[2]; inputs[f[0]] = input;
      input.addEventListener("input", function () { if (input.value !== f[2]) state.drafts[dkey] = input.value; else delete state.drafts[dkey]; });
      append(form, h("label", { class: "field", for: id }, f[1], input));
    });
    append(form, h("label", { class: "field", for: "edit-reason" }, "Reason", reason));
    var hasDraft = draftKeys(prefix).length > 0;
    append(form, h("div", { class: "row" }, h("button", { type: "submit", class: "btn btn--small", text: "Save intended design" }),
      h("button", { type: "button", class: "btn btn--small", text: "Discard changes", onclick: function () { dropDrafts(prefix); renderDetail(); } })), msg);
    if (hasDraft) append(msg, "Unsaved changes are kept until you save or discard them.");
    return h("details", { class: "edit", open: hasDraft }, h("summary", { text: "Edit intended design" + (hasDraft ? " (unsaved changes)" : "") }),
      h("p", { class: "hint", text: "Changes the intended design only. Each save is validated, raises the design revision, and keeps the previous revision in history. Observed states never change here." }), form);
  }

  function renderDiff() {
    var v = state.view, body = $("diff-table").tBodies[0];
    clear(body);
    if (!v) return;
    var open = v.discrepancies.filter(function (d) { return d.status === "open"; });
    $("diff-count").textContent = open.length ? String(open.length) : "";
    document.querySelectorAll("[data-dfilter]").forEach(function (b) { b.setAttribute("aria-checked", String(b.dataset.dfilter === state.dfilter)); });
    var rows = v.discrepancies.filter(function (d) { return state.dfilter === "all" || d.status === state.dfilter; });
    if (!rows.length) body.appendChild(h("tr", null, h("td", { colspan: "6", class: "muted", text: state.dfilter === "open" ? "No open differences." : "Nothing here." })));
    rows.forEach(function (d) {
      var subj = v.subjects[d.subject];
      body.appendChild(h("tr", null,
        h("td", null, chip("severity", d.severity), d.status !== "open" ? h("div", { class: "muted", text: "resolved " + ago(d.resolved_at) }) : null),
        h("td", null, h("strong", { text: d.title }), d.detail ? h("span", { class: "cell-sum", text: d.detail }) : null, h("span", { class: "cell-sum mono", text: d.id })),
        h("td", null, subj ? h("button", { type: "button", class: "btn btn--link", text: subj.title, onclick: function () { state.tab = "map"; select(d.subject, false); showTab("map", true); } }) : d.subject),
        h("td", { text: d.kind }),
        h("td", null, "first ", stamp(d.first_seen), h("br"), "last ", stamp(d.last_seen)),
        h("td", { text: (d.owners || []).map(function (o) { return o.task || o.name; }).filter(Boolean).concat((d.links || []).map(function (l) { return "linked: " + l; })).join(", ") || "none recorded" })));
    });
    var extra = clear($("diff-extra"));
    if (v.invalid_evidence && v.invalid_evidence.length) {
      append(extra, h("h3", { class: "h3", text: "Unreadable evidence records" }));
      append(extra, h("ul", { class: "list" }, v.invalid_evidence.map(function (r) { return h("li", { class: "item" }, h("strong", { text: r.id }), " ", r.invalid); })));
    }
    var pending = Object.keys(v.requests || {});
    if (pending.length) {
      append(extra, h("h3", { class: "h3", text: "Waiting for the supervisor" }));
      append(extra, h("ul", { class: "list" }, pending.map(function (k) { var r = v.requests[k]; return h("li", { class: "item" }, h("strong", { text: k }), " ", r.detail, h("div", { class: "item__foot" }, "queued ", stamp(r.created_at), r.emitted_at ? [" · surfaced ", stamp(r.emitted_at)] : " · not surfaced yet")); })));
    }
  }

  function renderTimeline() {
    var v = state.view, table = clear($("life-table"));
    if (!v) return;
    var lc = v.manifest.lifecycle || {};
    $("life-title").textContent = lc.title || "Experiment timeline";
    $("life-desc").textContent = (lc.description || "") + " Each run shows what its evidence records say for each phase; an empty cell means no record.";
    var phases = v.timeline.phases;
    if (!phases.length) { table.appendChild(h("tbody", null, h("tr", null, h("td", { class: "muted", text: "The manifest declares no lifecycle phases." })))); return; }
    table.appendChild(h("thead", null, h("tr", null, h("th", { scope: "col", text: "Run" }), phases.map(function (p) { return h("th", { scope: "col", text: p.title }); }))));
    var body = h("tbody");
    var accept = {};
    v.acceptance.forEach(function (a) { accept[a.id] = a; });
    body.appendChild(h("tr", null, h("th", { scope: "row" }, "MVP criterion now"), phases.map(function (p) {
      var a = accept[p.criterion];
      return h("td", null, a ? chip("acceptance", a.status) : h("span", { class: "muted", text: "no criterion" }));
    })));
    if (!v.timeline.runs.length) body.appendChild(h("tr", null, h("td", { colspan: String(phases.length + 1), class: "muted", text: "No run evidence recorded yet." })));
    v.timeline.runs.forEach(function (run) {
      body.appendChild(h("tr", null,
        h("th", { scope: "row" }, h("span", { class: "mono", text: run.run_id }), run.historical ? [" ", h("span", { class: "chip chip--hist", text: "historical" })] : null,
          h("span", { class: "cell-sum muted", text: "recorded " + ago(run.last) }),
          run.notes.map(function (n) { return h("span", { class: "cell-sum" }, chip("result", n.result), " ", n.summary); })),
        phases.map(function (p) {
          var c = run.cells[p.id];
          return h("td", null, c ? [chip("result", c.result), h("span", { class: "cell-sum", text: c.summary })] : h("span", { class: "muted", text: "no record" }));
        })));
    });
    table.appendChild(body);
  }

  function renderAcceptance() {
    var v = state.view, ol = clear($("criteria"));
    if (!v) return;
    if (!v.acceptance.length) { ol.appendChild(h("li", { class: "muted", text: "The manifest declares no acceptance criteria." })); return; }
    v.acceptance.forEach(function (a) {
      ol.appendChild(h("li", null,
        h("div", { class: "item__head" }, chip("acceptance", a.status), h("h3", { text: a.title })),
        a.description ? h("p", { text: a.description }) : null,
        a.deployment_mismatches && a.deployment_mismatches.length ? h("p", { class: "callout", text: "Deployment differs from the intended pin: " + a.deployment_mismatches.map(function (sid) { return (v.subjects[sid] || {}).title || sid; }).join(", ") + "." }) : null,
        a.unresolved_pins && a.unresolved_pins.length ? h("p", { class: "callout", text: "Declared pin has no binding value: " + a.unresolved_pins.map(function (sid) { return (v.subjects[sid] || {}).title || sid; }).join(", ") + "." }) : null,
        a.unversioned_subjects && a.unversioned_subjects.length ? h("p", { class: "callout", text: "Not version-bound: " + a.unversioned_subjects.map(function (sid) { return (v.subjects[sid] || {}).title || sid; }).join(", ") + " declare no version source, so this criterion cannot pass as current-version proof." }) : null,
        h("p", { class: "muted", text: "Depends on: " + (a.subjects || []).map(function (sid) { return (v.subjects[sid] || {}).title || sid; }).join(", ") }),
        a.evidence.length ? h("ul", { class: "list" }, a.evidence.map(function (r) {
          return h("li", { class: "item" }, h("div", { class: "item__head" }, chip("result", r.result), r.historical ? h("span", { class: "chip chip--hist", text: "historical" }) : null, h("strong", { text: r.id }), h("span", { class: "muted", text: r.qualification })),
            h("div", { text: r.summary }), provenance(r.provenance));
        })) : h("p", { class: "muted", text: "No evidence recorded for this criterion." })));
    });
  }

  function lineageList(items) {
    return h("details", null, h("summary", { text: "Source, artifact and installed lineage" }), h("ul", { class: "list" }, items.map(function (item) {
      return h("li", { class: "item" }, h("strong", { text: item.stage + " · " + item.subject }), " ", chip("prerequisite", item.status),
        h("div", { class: "cell-sum", text: "Observed version: " + (item.version || "unknown") }),
        item.reported_version ? h("div", { class: "cell-sum", text: "Reported version: " + item.reported_version + " · " + (item.recorded_at || "time unknown") }) : null,
        item.provenance ? provenance(item.provenance) : null,
        item.expected ? h("div", { class: "cell-sum", text: "Expected: " + item.expected }) : null,
        item.note ? h("div", { class: "muted", text: item.note }) : null);
    })));
  }

  function renderReadiness() {
    var el = clear($("readiness")), v = state.view;
    if (!v) return;
    var readiness = v.readiness || { phases: [], prerequisites: [] };
    if (!readiness.phases.length) append(el, h("p", { class: "muted", text: "Declare lifecycle phases and prerequisites in the intended design to expose coverage." }));
    readiness.phases.forEach(function (phase) {
      append(el, h("h3", { class: "h3", text: phase.title }));
      var checks = readiness.prerequisites.filter(function (p) { return phase.prerequisites.indexOf(p.id) >= 0; });
      if (!checks.length) { append(el, h("p", { class: "callout", text: "Coverage gap: no prerequisites declared for this phase. Next check: identify its required producers and resources with the phase owner." })); return; }
      var table = h("table", { class: "table prerequisite-table" }, h("thead", null, h("tr", null,
        ["Resource / baseline", "Observation / coverage", "Authorization", "Layers", "Owner / next check"].map(function (title) { return h("th", { scope: "col", text: title }); }))));
      var body = h("tbody");
      checks.forEach(function (p) {
        body.appendChild(h("tr", null,
          h("td", null, h("button", { class: "link", text: p.title, onclick: function () { showTab("map", false); select(p.producer, true); } }), h("span", { class: "cell-sum", text: p.resource }), h("span", { class: "cell-sum muted", text: "Required for: " + p.baseline + " · producer " + p.producer })),
          h("td", null, chip("prerequisite", p.state), h("span", { class: "cell-sum muted", text: p.coverage + (p.observed_state !== p.state ? " · last state " + p.observed_state : "") }), stamp(p.checked_at),
            h("details", null, h("summary", { text: "Scope and evidence" }), h("p", { text: p.detail }), h("p", { text: typeof p.scope === "string" ? p.scope : JSON.stringify(p.scope || {}) }), p.provenance ? provenance(p.provenance) : h("p", { class: "muted", text: "No evidence source." }))),
          h("td", null, h("span", { class: "chip chip--" + (p.authorization === "authorized" || p.authorization === "not-required" ? "info" : "unknown"), text: p.authorization.replace(/-/g, " ") })),
          h("td", null, Object.keys(p.layers).map(function (key) { return h("span", { class: "cell-sum" }, key + " ", chip(key, p.layers[key].status)); }), p.lineage.length ? lineageList(p.lineage) : null),
          h("td", null, h("strong", { text: p.owners.map(function (o) { return (o.name || o.role || "owner") + (o.task ? " · " + o.task : ""); }).join(", ") || "Owner not recorded" }), h("span", { class: "cell-sum", text: p.next_check }))));
      });
      append(table, body); append(el, h("div", { class: "tablewrap", tabindex: "0", role: "region", "aria-label": phase.title + " prerequisites; scroll for all columns" }, table));
    });
  }

  function accessList(items) {
    var v = state.view, access = v.access;
    function subjectLink(sid) {
      return v.subjects[sid] ? h("button", { type: "button", class: "btn btn--link", text: v.subjects[sid].title, onclick: function () { showTab("map", false); select(sid, true); } }) : h("span", { text: sid });
    }
    return h("ul", { class: "list access-list" }, items.map(function (i) {
      var deps = i.dependencies.map(function (id) { return access.dependencies.find(function (d) { return d.id === id; }); });
      return h("li", { class: "item" }, h("h3", { class: "h3", text: i.title }),
        h("p", null, subjectLink(i.caller), " through ", subjectLink(i.identity), " to ", subjectLink(i.target)),
        h("p", { class: "mono", text: i.operations.join(", ") }),
        h("p", null, h("strong", { text: "Static coverage: " }), i.static_coverage.replace(/-/g, " "), " · Request: ", i.request_proof.replace(/-/g, " ")),
        h("p", { class: "muted", text: "Phases: " + i.phases.join(", ") + " · Effective access: unknown · Propagation: unobserved" }),
        i.missing_kinds.length ? h("p", { class: "callout", text: "Unmapped checks: " + i.missing_kinds.join(", ") }) : null,
        h("details", null, h("summary", { text: "Policy, trust and configuration checks (" + deps.length + ")" }),
          h("ul", { class: "list" }, deps.map(function (d) {
            return h("li", { class: "item" }, h("strong", { text: d.title }), " · ", d.kind,
              h("p", null, chip("prerequisite", d.state), " · ", d.comparison.replace(/-/g, " "), " · ", d.coverage),
              h("p", { text: d.reason || d.error || "Baseline observation only; no effective permission conclusion." }),
              h("p", { class: "muted", text: "Source: " + (d.source || "uncollected") + " · Resource: " + d.subject }), stamp(d.checked_at),
              h("p", { text: "Scope / observing identity: " + JSON.stringify(d.scope || {}) }),
              h("p", { class: "mono", text: "Version: " + (d.version || "unknown") }),
              h("details", null, h("summary", { text: "Observed policy / configuration metadata" }), h("pre", { class: "access-context", text: JSON.stringify(d.facts, null, 2) }), d.reads.map(function (r) { return h("p", { class: "mono", text: r.service + ":" + r.operation + " · " + r.observed_at + " · response " + r.response_sha256 + " · private source " + r.path }); })),
              d.provenance ? provenance(d.provenance) : null,
              d.baseline ? h("p", { class: "muted", text: "Baseline: " + d.baseline.source + " · " + d.baseline.observed_at + " · " + (d.baseline.complete ? "complete" : "incomplete") }) : null,
              d.reference_states.length ? h("p", { text: "Trust references: " + d.reference_states.map(function (r) { return r.subject + ": " + r.state + " · created " + (r.created_at || "unknown") + " · propagation unobserved"; }).join("; ") }) : null,
              d.unobserved_policy_documents.length ? h("p", { class: "callout", text: d.unobserved_policy_documents.length + " attached or inline policy documents are unobserved." }) : null,
              h("p", { text: "Owner: " + d.owners.map(function (o) { return o.name || o.task || o.role; }).join(", ") + " · Next: " + d.next_check }));
          }))),
        h("details", null, h("summary", { text: "Request context, scope and proof binding" }),
          h("p", { text: i.analysis_scope + " Context coverage: " + i.context_coverage }), h("pre", { class: "access-context", text: JSON.stringify(i.context, null, 2) }),
          h("p", { class: "mono", text: "Assertion digest: " + i.assertion_digest }),
          i.evidence_record ? [h("p", { text: i.evidence_record.summary }), provenance(i.evidence_record.provenance)] : h("p", { text: "No actual request receipt recorded." })),
        h("p", { class: "muted", text: "Owner: " + i.owners.map(function (o) { return o.name || o.task || o.role; }).join(", ") + " · Next: " + i.next_check }));
    }));
  }

  function renderAccess() {
    var el = $("access"), v = state.view;
    if (!v || (el.contains(document.activeElement) && document.activeElement.tagName === "INPUT")) return;
    clear(el);
    var access = v.access || { interactions: [], dependencies: [], gaps: [], phases: [] };
    append(el, h("p", { class: "callout", text: access.limit || "No access relationships declared." }));
    var gaps = h("details", { class: "access-gaps" }, h("summary", { text: "All missing checks (" + access.gaps.length + ")" }));
    if (!access.gaps.length) append(gaps, h("p", { class: "muted", text: "No declared coverage gaps. This is not an effective permission result." }));
    else append(gaps, h("ul", { class: "list" }, access.gaps.map(function (g) {
      return h("li", { class: "item" }, h("strong", { text: g.title || g.dependency || g.interaction || g.phase }), " · " + (g.kind || g.subject || "phase interactions") + ": " + g.state + (g.comparison ? " · " + g.comparison : ""), h("div", { class: "cell-sum", text: g.next_check }), g.interactions && g.interactions.length > 1 ? h("details", null, h("summary", { text: "Affects " + g.interactions.length + " interactions" }), h("p", { class: "mono", text: g.interactions.join(", ") })) : null);
    })));
    append(el, [gaps, h("h3", { class: "h3", text: "Required interactions" })]);
    var phase = h("select", { id: "access-phase" }, h("option", { value: "all", text: "All phases" }), access.phases.map(function (p) { return h("option", { value: p.id, text: p.title }); }));
    phase.value = state.accessPhase;
    var query = h("input", { id: "access-query", type: "search", placeholder: "Resource, identity or operation", value: state.accessQuery });
    var count = h("p", { class: "muted", "aria-live": "polite" }), list = h("div");
    function filter() {
      state.accessPhase = phase.value; state.accessQuery = query.value;
      var text = query.value.toLowerCase().trim();
      var items = access.interactions.filter(function (i) {
        var related = [i.caller, i.identity, i.target].map(function (id) { return (v.subjects[id] || {}).title || id; });
        return (phase.value === "all" || i.phases.indexOf(phase.value) >= 0) && (!text || [i.title, i.id].concat(related, i.operations).join(" ").toLowerCase().indexOf(text) >= 0);
      });
      count.textContent = items.length + " of " + access.interactions.length + " interactions";
      clear(list); append(list, items.length ? accessList(items) : h("p", { text: "No interactions match these filters." }));
    }
    phase.addEventListener("change", filter); query.addEventListener("input", filter);
    append(el, [h("div", { class: "access-filters" }, h("label", { for: "access-phase" }, "Consuming phase", phase), h("label", { for: "access-query" }, "Find access", query)), count, list]);
    filter();
  }

  function renderCredentials() {
    var v = state.view, body = $("cred-table").tBodies[0];
    clear(body);
    if (!v) return;
    var creds = v.credentials || v.manifest.credentials || [];
    if (!creds.length) body.appendChild(h("tr", null, h("td", { colspan: "5", class: "muted", text: "No credentials described." })));
    creds.forEach(function (c) {
      var exp = (c.expiry_basis || "observed") === "observed" ? parseTime(c.expires) : null, soon = exp !== null && exp - Date.now() < 7 * 86400000;
      body.appendChild(h("tr", null,
        h("td", null, h("strong", { text: c.title }), c.kind ? h("span", { class: "cell-sum muted", text: c.kind }) : null),
        h("td", { text: c.purpose }),
        h("td", null, c.owner || "not recorded", h("span", { class: "cell-sum", text: "Renewal owner: " + (c.renewal_owner || c.owner || "unknown") }), h("span", { class: "cell-sum", text: "Mechanism: " + (c.rotation || "unknown") }), h("span", { class: "cell-sum", text: "Restart required: " + (c.restart_required || "unknown") })),
        h("td", null, exp === null ? h("span", { class: "chip chip--unknown", text: "not recorded" }) : [h("span", { class: "chip chip--" + (exp < Date.now() ? "bad" : soon ? "warn" : "ok"), text: exp < Date.now() ? "expired" : ago(c.expires) }), h("span", { class: "cell-sum", text: c.expires + " · " + (c.expiry_basis || "observed") })],
          h("span", { class: "cell-sum", text: "Issuer: " + (c.issuer || "not recorded") }), c.expected_expires ? h("span", { class: "cell-sum", text: "Inferred expiry: " + c.expected_expires }) : null,
          c.full_window_seconds ? h("span", { class: "cell-sum", text: "Full window: " + (c.full_window || "unknown") + " · " + c.full_window_seconds + " seconds" }) : null,
          c.full_window_seconds ? h("span", { class: "cell-sum", text: "Latest safe start (strictly before): " + (c.latest_safe_start || "unknown") }) : null,
          c.note ? h("details", null, h("summary", { text: "Evidence and limits" }), h("p", { text: c.note })) : null),
        h("td", { text: (c.subjects || []).map(function (sid) { return (v.subjects[sid] || {}).title || sid; }).join(", ") })));
    });
  }

  // ---------------------------------------------------------------- tabs
  var TABS = { map: "tab-map", access: "tab-access", ready: "tab-ready", diff: "tab-diff", life: "tab-life", accept: "tab-accept", cred: "tab-cred" };
  function showTab(name, focus) {
    if (!TABS[name]) name = "map";
    state.tab = name; writeHash();
    Object.keys(TABS).forEach(function (k) {
      var tab = $(TABS[k]), panel = $(tab.getAttribute("aria-controls"));
      var on = k === name;
      tab.setAttribute("aria-selected", String(on)); tab.tabIndex = on ? 0 : -1; panel.hidden = !on;
      if (on && focus) tab.focus();
    });
  }

  function init() {
    readHash();
    $("auto").checked = (function () { try { return localStorage.getItem("fm-map-auto") !== "0"; } catch (e) { return true; } })();
    $("auto").addEventListener("change", function () { try { localStorage.setItem("fm-map-auto", this.checked ? "1" : "0"); } catch (e) { /* storage unavailable */ } schedule(); });
    $("reload").addEventListener("click", load);
    $("collect").addEventListener("click", collectNow);
    Object.keys(TABS).forEach(function (k) {
      $(TABS[k]).addEventListener("click", function () { showTab(k, false); });
      $(TABS[k]).addEventListener("keydown", function (ev) {
        var keys = Object.keys(TABS), i = keys.indexOf(k);
        if (ev.key === "ArrowRight") showTab(keys[(i + 1) % keys.length], true);
        else if (ev.key === "ArrowLeft") showTab(keys[(i + keys.length - 1) % keys.length], true);
        else if (ev.key === "Home") showTab(keys[0], true);
        else if (ev.key === "End") showTab(keys[keys.length - 1], true);
        else return;
        ev.preventDefault();
      });
    });
    function radios(selector, attr, apply) {
      var buttons = Array.prototype.slice.call(document.querySelectorAll(selector));
      buttons.forEach(function (b, i) {
        b.addEventListener("click", function () { apply(b.dataset[attr]); });
        b.addEventListener("keydown", function (ev) {
          var j = ev.key === "ArrowRight" ? (i + 1) % buttons.length : ev.key === "ArrowLeft" ? (i + buttons.length - 1) % buttons.length : -1;
          if (j < 0) return;
          ev.preventDefault(); buttons[j].focus(); apply(buttons[j].dataset[attr]);
        });
      });
    }
    radios("[data-lens]", "lens", function (lens) { state.lens = lens; writeHash(); renderMap(); });
    $("zoom-out").addEventListener("click", function () { state.zoom = Math.max(0.6, (state.zoom === "fit" ? 1 : state.zoom) - 0.2); renderMap(); });
    $("zoom-in").addEventListener("click", function () { state.zoom = Math.min(2, (state.zoom === "fit" ? 1 : state.zoom) + 0.2); renderMap(); });
    $("zoom-fit").addEventListener("click", function () { state.zoom = state.zoom === "fit" ? 1 : "fit"; renderMap(); });
    radios("[data-dfilter]", "dfilter", function (f) { state.dfilter = f; renderDiff(); });
    document.addEventListener("keydown", function (ev) {
      if (ev.key === "Escape" && state.selected && !(document.activeElement && /TEXTAREA|INPUT/.test(document.activeElement.tagName))) select(null, false);
    });
    document.addEventListener("visibilitychange", function () { if (!document.hidden && $("auto").checked) load(); });
    api("/api/projects").then(function (data) {
      var sel = $("project");
      data.projects.forEach(function (p) { sel.appendChild(h("option", { value: p, text: p })); });
      if (!state.project || data.projects.indexOf(state.project) < 0) state.project = data.projects[0] || null;
      sel.value = state.project || "";
      sel.addEventListener("change", function () { state.project = sel.value; state.selected = null; load(); });
      if (!state.project) { state.error = "No project is listed in config/system-map."; renderBanners(); return; }
      return load();
    }).catch(function (err) { state.error = err.message; renderBanners(); renderHealth(); });
  }
  document.addEventListener("DOMContentLoaded", init);
})();
