// Open DC node editor - litegraph (ComfyOrg fork, vendored UMD).
// Loads an AstGraph doc via window.renderNodes(payload); edits produce a
// preview via sketchup.nact {op:"preview"}; Apply writes the formula.
// Node kinds map to AstGraph doc types: const/attr/ref/un/bin/call(+act)
// plus the fixed FORMULA output node (doc t "res", UI-only).
// Every input slot gets a companion text widget: while the slot is
// unconnected it takes a literal port value (same "manual" semantics as
// the Rete editor); while connected it is hidden. Single-use const
// leaves from the doc collapse into those fields on load.
(function () {
  "use strict";

  var lg = window.litegraph && window.litegraph.js;
  if (!lg) {
    document.getElementById("ptitle").textContent = "litegraph failed to load";
    return;
  }

  // litegraph's bg pipeline is self-inconsistent on hidpi screens: the
  // front canvas draws nodes in unscaled graph coords (device px), while
  // drawBackCanvas applies a devicePixelRatio transform and the bg blit
  // divides by dpr - compressing grid/links into 1/dpr of the window.
  // Forcing dpr=1 makes resize, transforms, and hit-testing uniformly
  // CSS-pixel based; slightly softer text, but everything lands right.
  if (window.devicePixelRatio !== 1) {
    try {
      Object.defineProperty(window, "devicePixelRatio",
        { value: 1, configurable: true });
    } catch (e) { /* older CEF - rendering stays correct at any rate */ }
  }

  var LiteGraph = lg.LiteGraph;

  var canvas = null;      // LGraphCanvas
  var graph = null;       // the single editable LGraph
  var state = null;       // {entityId,name,label,functions,actions,attrs,builtins,globals,fnArity,fnVararg,fnGroups,isAction}
  var building = false;   // suppress preview while rebuilding
  var toastTimer = null;
  var previewTimer = null;

  // Shared AST node layer (ui/astkit.js) - node classes, widgets, manual
  // port fields, doc helpers. Hooks wire it to this page's preview/theme.
  var kit = window.ODCAst.createNodes(lg, {
    tint: function (n, v) { n.boxcolor = cssVar(v); },
    preview: function () { requestPreview(); },
    fnArity: function () { return (state || {}).fnArity; },
    fnVararg: function () { return (state || {}).fnVararg; }
  });
  var makeNode = kit.makeNode, syncManWidgets = kit.syncManWidgets,
      parseLit = window.ODCAst.parseLit, litDisplay = window.ODCAst.litDisplay,
      layoutDepth = window.ODCAst.layoutDepth, BIN_OPS = window.ODCAst.BIN_OPS;

  function toast(msg, isErr) {
    var el = document.getElementById("ntoast");
    el.textContent = msg;
    el.className = "show" + (isErr ? " err" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.className = ""; }, 2600);
  }

  function send(payload) {
    if (window.sketchup && sketchup.nact) sketchup.nact(JSON.stringify(payload));
    else console.log("NACT", payload);
  }

  // ---- theme -------------------------------------------------------------
  function cssVar(n) {
    return getComputedStyle(document.documentElement)
      .getPropertyValue(n).trim();
  }

  function applyTheme() {
    LiteGraph.NODE_FONT = "Segoe UI, sans-serif";
    LiteGraph.DEFAULT_FONT = "Segoe UI, sans-serif";
    LiteGraph.NODE_TEXT_SIZE = 13;
    LiteGraph.NODE_WIDTH = 160;
    LiteGraph.NODE_TITLE_HEIGHT = 26;
    LiteGraph.NODE_SLOT_HEIGHT = 18;
    LiteGraph.NODE_TITLE_COLOR = cssVar("--dim");
    LiteGraph.NODE_SELECTED_TITLE_COLOR = cssVar("--fg");
    LiteGraph.NODE_TEXT_COLOR = cssVar("--fg");
    LiteGraph.NODE_TEXT_HIGHLIGHT_COLOR = cssVar("--fg");
    LiteGraph.NODE_DEFAULT_BGCOLOR = cssVar("--bg3");
    LiteGraph.NODE_DEFAULT_COLOR = cssVar("--bg2");
    LiteGraph.NODE_DEFAULT_BOXCOLOR = cssVar("--border");
    LiteGraph.LINK_COLOR = cssVar("--muted");
    LiteGraph.CONNECTING_LINK_COLOR = cssVar("--accent2");
    LiteGraph.WIDGET_BGCOLOR = cssVar("--bg2");
    LiteGraph.WIDGET_OUTLINE_COLOR = cssVar("--border");
    LiteGraph.WIDGET_TEXT_COLOR = cssVar("--fg");
    LiteGraph.WIDGET_SECONDARY_TEXT_COLOR = cssVar("--dim");
    LiteGraph.WIDGET_DISABLED_TEXT_COLOR = cssVar("--muted");
    if (canvas) canvas.clear_background_color = cssVar("--bg");
  }

  // ---- graph doc <-> litegraph --------------------------------------------
  function buildEditor(doc) {
    var nodes = doc.nodes || {}, links = doc.links || [];
    var depth = layoutDepth(nodes, links), perLevel = {}, idMap = {};
    // A const node feeding exactly one port collapses into that port's
    // manual-value widget. Multi-use consts stay visible (shared value).
    var useCnt = {}, collapsed = {}, manual = {};
    links.forEach(function (l) { useCnt[l.f] = (useCnt[l.f] || 0) + 1; });
    links.forEach(function (l) {
      var src = nodes[l.f];
      if (src && src.t === "const" && useCnt[l.f] === 1 && nodes[l.t]) {
        collapsed[l.f] = true;
        (manual[l.t] = manual[l.t] || {})[l.p] = litDisplay(src.v, src.k);
      }
    });
    Object.keys(nodes).forEach(function (id) {
      if (collapsed[id]) return;
      var nd = nodes[id];
      var argc = (nd.t === "call" || nd.t === "act")
        ? links.filter(function (l) { return l.t === id; }).length
        : undefined;
      var n = makeNode(nd.t, nd.v, { k: nd.k, argc: argc });
      var man = manual[id] || {};
      (n.widgets || []).forEach(function (w) {
        if (w._port && man[w._port] != null) w.value = man[w._port];
      });
      var lv = depth[id] || 0;
      perLevel[lv] = (perLevel[lv] || 0) + 1;
      n.pos = [60 + lv * 220, 40 + (perLevel[lv] - 1) * 110];
      graph.add(n);
      idMap[id] = n;
    });
    links.forEach(function (l) {
      if (collapsed[l.f]) return;
      var s = idMap[l.f], d = idMap[l.t];
      if (!s || !d) return;
      var ii = d.inputs.findIndex(function (i) { return i.name === l.p; });
      if (ii >= 0) s.connect(0, d, ii);
    });
    // FORMULA output node: always present, docked right of the doc root
    // (or top-left on an empty graph) and wired to it.
    var res = makeNode("res", null);
    var rn = doc.root ? idMap[doc.root] : null;
    if (rn) {
      res.pos = [rn.pos[0] + 250, rn.pos[1]];
    } else {
      var lvMax = Object.keys(depth).reduce(function (m, id) {
        return Math.max(m, depth[id]);
      }, -1);
      res.pos = [60 + (lvMax + 1) * 220, 40];
    }
    graph.add(res);
    if (rn) rn.connect(0, res, 0);
    (graph._nodes || []).forEach(syncManWidgets);
  }

  function resNode() {
    return graph && (graph._nodes || []).find(function (n) {
      return n._odc && n._odc.t === "res";
    });
  }

  // Serialize the canvas back to the AstGraph doc schema. The FORMULA
  // node is stripped; the node feeding it becomes the emitted root.
  function graphDoc() {
    var nodes = {}, links = [], root = null;
    var res = resNode();
    (graph._nodes || []).forEach(function (n) {
      if (!n._odc || n._odc.t === "res") return;
      var id = String(n.id);
      nodes[id] = { t: n._odc.t === "act" ? "call" : n._odc.t,
                    v: n._odc.v, k: n._odc.k };
      (n.inputs || []).forEach(function (inp) {
        if (inp.link == null) return;
        var L = graph.getLink(inp.link);
        if (L) links.push({ f: String(L.origin_id), t: id, p: inp.name });
      });
    });
    if (res && res.inputs[0] && res.inputs[0].link != null) {
      var rl = graph.getLink(res.inputs[0].link);
      if (rl) root = String(rl.origin_id);
    }
    // Typed port values become a synthesized const node + link, keeping
    // the doc schema and the Ruby emitter unchanged. A value typed into
    // the FORMULA input itself is a literal result (e.g. `42`).
    (graph._nodes || []).forEach(function (n) {
      if (!n._odc) return;
      (n.widgets || []).forEach(function (w) {
        if (!w._port) return;
        var inp = (n.inputs || []).find(function (i) {
          return i.name === w._port;
        });
        if (!inp || inp.link != null) return;
        var raw = String(w.value || "").trim();
        if (!raw) return;
        var lit = parseLit(raw);
        var mid = "m" + n.id + "_" + w._port;
        nodes[mid] = { t: "const", v: lit.v, k: lit.k };
        if (n._odc.t === "res") {
          if (!root) root = mid;
        } else {
          links.push({ f: mid, t: String(n.id), p: w._port });
        }
      });
    });
    return { nodes: nodes, links: links, root: root };
  }

  // ---- preview / apply -----------------------------------------------------
  function requestPreview() {
    if (!state || building) return;
    clearTimeout(previewTimer);
    previewTimer = setTimeout(function () {
      // Nothing wired into FORMULA -> there is no result to emit.
      var res = resNode();
      var wired = res && res.inputs[0] && res.inputs[0].link != null;
      var w = res && (res.widgets || []).find(function (x) { return x._port; });
      var man = w && String(w.value || "").trim();
      if (res && !wired && !man) {
        window.onNodeStatus({ ok: false,
          errors: ["connect an expression to FORMULA"] });
        return;
      }
      send({ op: "preview", entityId: state.entityId, name: state.name,
             doc: graphDoc() });
    }, 250);
  }

  window.onNodeStatus = function (r) {
    var el = document.getElementById("nformula");
    var apply = document.getElementById("napply");
    if (r.error) { toast(r.error, true); return; }
    if (r.ok) {
      el.textContent = r.formula;
      el.classList.remove("bad");
      apply.disabled = false;
      if (r.applied) toast("Applied: " + r.formula);
    } else {
      el.textContent = r.errors ? r.errors.join("; ") : "invalid";
      el.classList.add("bad");
      apply.disabled = true;
    }
  };

  // ---- context menu ----------------------------------------------------------
  function addItem(type, v, extra) {
    return {
      content: String(v === "" ? "(empty text)" : v),
      callback: function () {
        var n = makeNode(type, v, extra);
        var m = canvas.graph_mouse || [80, 80];
        n.pos = [m[0] - 40, m[1] - 20];
        graph.add(n);
        syncManWidgets(n);
        requestPreview();
      }
    };
  }

  function menuItems() {
    function sub(name, opts) {
      return { content: name, has_submenu: true, submenu: { options: opts } };
    }
    var ops = BIN_OPS.map(function (op) { return addItem("bin", op); });
    ops.push({ content: "unary -", callback: addItem("un", "-").callback },
             { content: "NOT", callback: addItem("un", "NOT").callback });
    // Attribute lists get long, so split by origin: the component's own
    // attrs, SketchUp builtins (x/y/z/rot...), model globals (scope refs).
    var attrSubs = [];
    if ((state.attrs || []).length) {
      attrSubs.push(sub("Custom",
        state.attrs.map(function (a) { return addItem("attr", a); })));
    }
    if ((state.builtins || []).length) {
      attrSubs.push(sub("SketchUp",
        state.builtins.map(function (a) { return addItem("attr", a); })));
    }
    if ((state.globals || []).length) {
      attrSubs.push(sub("Globals", state.globals.map(function (g) {
        return addItem("ref", "global!" + g);
      })));
    }
    if ((state.skprops || []).length) {
      attrSubs.push(sub("SketchUp props", state.skprops.map(function (n) {
        return addItem("ref", "sketchup!" + n);
      })));
    }
    if ((state.dicts || []).length) {
      attrSubs.push(sub("Dictionaries", state.dicts.map(function (n) {
        return addItem("ref", n);
      })));
    }
    // Functions grouped by category (fnGroups from AstGraph::FN_GROUPS);
    // anything not listed lands in "Other".
    var fns = state.functions || [];
    var grouped = {};
    var fnSubs = (state.fnGroups || []).map(function (pair) {
      var names = fns.filter(function (f) {
        if (pair[1].indexOf(f) < 0) return false;
        grouped[f] = true;
        return true;
      });
      return names.length
        ? sub(pair[0], names.map(function (f) { return addItem("call", f); }))
        : null;
    }).filter(Boolean);
    var rest = fns.filter(function (f) { return !grouped[f]; });
    if (rest.length) {
      fnSubs.push(sub("Other",
        rest.map(function (f) { return addItem("call", f); })));
    }
    var items = [
      sub("Operators", ops),
      sub("Literals", [
        { content: "Number", callback: addItem("const", "0", { k: "num" }).callback },
        { content: "Text", callback: addItem("const", "", { k: "str" }).callback }
      ]),
      sub("Attributes", attrSubs),
      sub("Functions", fnSubs)
    ];
    if (state.isAction) {
      items.push(sub("Actions",
        (state.actions || []).map(function (f) { return addItem("act", f); })));
    }
    return items;
  }

  // ---- canvas ---------------------------------------------------------------
  function ensureCanvas() {
    if (canvas) return;
    var el = document.getElementById("lgcanvas");
    canvas = new lg.LGraphCanvas(el, new lg.LGraph());
    canvas.clear_background = true;
    canvas.clear_background_color = cssVar("--bg");
    canvas.allow_searchbox = false;
    canvas.render_canvas_border = false;
    // Centre arrow markers use _centreAngle (verified forward); the
    // render_connection_arrows chevrons read backwards, so leave them off.
    canvas.render_connection_arrows = false;
    canvas.linkMarkerShape = lg.LinkMarkerShape.Arrow;
    canvas.getCanvasMenuOptions = function () { return menuItems(); };
    // FORMULA is the fixed result node - everything else is deletable.
    canvas.deleteSelected = function () {
      var sel = this.selected_nodes || {};
      Object.keys(sel).forEach(function (id) {
        var n = sel[id];
        if (n._odc && n._odc.t === "res") return;
        graph.remove(n);
      });
      this.setDirty(true, true);
      requestPreview();
    };
    window.addEventListener("resize", function () { canvas.resize(); });
    // resize() reads the parent box in CSS px - correct once dpr is 1.
    requestAnimationFrame(function () { canvas.resize(); });
  }

  // ---- boot --------------------------------------------------------------------
  window.renderNodes = function (payload) {
    state = payload;
    document.getElementById("ptitle").textContent = payload.label || payload.name;
    applyTheme();
    ensureCanvas();

    building = true;
    graph = new lg.LGraph();
    graph.onNodeAdded = function () { requestPreview(); };
    graph.onNodeRemoved = function () { requestPreview(); };
    canvas.setGraph(graph);
    try {
      buildEditor(payload.graph || { nodes: {}, links: [] });
    } catch (e) {
      send({ op: "dbg", err: String(e && e.message || e),
             stack: String(e && e.stack || "").slice(0, 400) });
      toast("graph build failed: " + (e && e.message || e), true);
    }
    building = false;
    requestPreview();
  };

  document.getElementById("napply").addEventListener("click", function () {
    if (state) send({ op: "apply", entityId: state.entityId, name: state.name,
                      doc: graphDoc() });
  });

  // Debug/dev hook (same role as the dep-graph __odc).
  window.__dbg = function () {
    return { canvas: canvas, graph: graph, doc: graphDoc };
  };

  if (window.sketchup && sketchup.nready) sketchup.nready("");
})();
