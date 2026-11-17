// Open DC - modern Dynamic Components for SketchUp
// Copyright (C) 2026 Jure Judež and contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Dependency graph on litegraph (ComfyOrg fork, vendored UMD).
// Top level: one node per attribute; attributes with a formula carry a
// litegraph Subgraph holding the formula's AST - double-click or the
// title button dives in, the header back button returns. Edges point
// dep -> dependent (data flow) and land on the subgraph's named input
// slot for the attribute they feed.
//   - drag out -> deps:  writes formula(target) = source (with confirm)
//   - click link -> Unlink: refs in the formula become literals
//   - double-click / context menu: dive into the formula subgraph
// Ruby pushes {label, entityId, graph:{nodes,edges}} via renderGraph;
// each node may carry "doc" (AstGraph doc) for its subgraph.
(function () {
  "use strict";

  var lg = window.litegraph && window.litegraph.js;
  if (!lg) { document.getElementById("gmsg").textContent = "litegraph failed to load"; }

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

  var LiteGraph = lg.LiteGraph, LGraphNode = lg.LGraphNode,
      SubgraphNode = lg.SubgraphNode;

  var canvas = null;      // LGraphCanvas
  var rootGraph = null;   // top-level LGraph
  var cur = null;         // latest payload {label, entityId, graph, palette}
  var lastEntityId = null;// entity of the last rendered graph
  var building = false;   // suppress edit ops while rebuilding the canvas
  var savedView = null;   // pan/zoom kept across re-renders
  var layoutByEnt = {};   // entityId -> {positions:{id:[x,y]}, groups:[...]}
  var posTimer = null;    // debounce for saveLayout sends
  var toastTimer = null;
  var confirmCb = null;
  var previewTimer = null;

  // Shared AST node layer (ui/astkit.js) - same widgets/manual port
  // fields/doc helpers as the fx editor, hooked to the subgraph preview.
  var kit = window.ODCAst.createNodes(lg, {
    tint: function (n, v) { n.boxcolor = cssVar(v); },
    preview: function () { requestSubPreview(); },
    fnArity: function () { return ((cur || {}).palette || {}).fnArity; },
    fnVararg: function () { return ((cur || {}).palette || {}).fnVararg; }
  });

  function toast(msg, isErr) {
    var el = document.getElementById("gtoast");
    el.textContent = msg;
    el.className = "show" + (isErr ? " err" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.className = ""; }, 2600);
  }

  function send(payload) {
    if (window.sketchup && sketchup.gact) sketchup.gact(JSON.stringify(payload));
    else console.log("GACT", payload);
  }

  function applyFormula(name, formula) {
    send({ entityId: cur.entityId, name: name, formula: formula });
  }

  function nodeById(id) {
    return (cur.graph.nodes || []).find(function (n) { return n.id === id; });
  }

  // ---- wiring ------------------------------------------------------
  // Would wiring from->to close a dependency cycle? Only if 'to'
  // already reaches 'from' transitively.
  function createsCycle(from, to) {
    var map = {};
    cur.graph.edges.forEach(function (e) {
      (map[e.from] = map[e.from] || []).push(e.to);
    });
    var seen = {}, stack = [to];
    while (stack.length) {
      var n = stack.pop();
      if (n === from) return true;
      if (!seen[n]) {
        seen[n] = true;
        (map[n] || []).forEach(function (m) { stack.push(m); });
      }
    }
    return false;
  }

  function wire(from, to) {
    if (from === to) {
      toast("Can't wire a node to itself", true);
      return;
    }
    var t = nodeById(to);
    if (!t) return;
    if (t.external || t.virtual) {
      toast("'" + to + "' is external/builtin - it can't take a formula", true);
      return;
    }
    if (createsCycle(from, to)) {
      toast("Wiring " + from + " -> " + to + " would create a cycle", true);
      return;
    }
    if (t.hasFormula) {
      askConfirm(
        "Replace formula of '" + to + "' with '" + from + "'?",
        function () { applyFormula(to, from); }
      );
    } else {
      applyFormula(to, from);
    }
  }

  // Scene mode: fromAttr on entity fromEid feeds toAttr on toEid. Ruby
  // picks the scope token (nodename!/global!) and validates the write.
  function wireEntity(fromEid, fromAttr, toEid, toAttr) {
    if (fromEid === toEid) {
      toast("Internal wiring lives in the component's dependency graph - " +
            "double-click the node to open it", true);
      return;
    }
    if (toEid === "$globals") {
      toast("Globals are set in the panel, not driven by formulas", true);
      return;
    }
    if (createsCycle(fromEid, toEid)) {
      toast("Wiring these would create a cycle", true);
      return;
    }
    var t = (cur.graph.nodes || []).find(function (n) { return n.id === toEid; });
    var ta = t && (t.attrs || []).find(function (a) { return a.name === toAttr; });
    var label = (fromEid === "$globals" ? "global!" : "") + fromAttr;
    var send2 = function () {
      send({ op: "wireEntity", fromEid: fromEid, fromAttr: fromAttr,
             toEid: toEid, toAttr: toAttr });
    };
    if (ta && ta.hasFormula) {
      askConfirm("Replace formula of '" + toAttr + "' with '" + label + "'?",
                 send2);
    } else {
      send2();
    }
  }

  function askConfirm(text, cb) {
    document.getElementById("gctext").textContent = text;
    document.getElementById("gconfirm").classList.add("show");
    confirmCb = cb;
  }
  document.getElementById("gcok").addEventListener("click", function () {
    document.getElementById("gconfirm").classList.remove("show");
    if (confirmCb) confirmCb();
    confirmCb = null;
  });
  document.getElementById("gccancel").addEventListener("click", function () {
    document.getElementById("gconfirm").classList.remove("show");
    confirmCb = null;
  });

  // ---- unlink (edge delete = substitute literal value) ---------------
  // Replace CURRENT("name")-style calls first (the ref lives inside a
  // string literal), then bare identifiers outside quoted strings.
  function unlinkFormula(formula, refId, literal) {
    var f = formula;
    if (refId.indexOf("!") < 0) {
      f = f.replace(new RegExp(
        '(CURRENT|OPTIONINDEX|OPTIONVALUE)\\(\\s*"' + refId + '"\\s*\\)', "gi"),
        literal);
    }
    var pat = refId.replace(/[.*+?^${}()|[\]\\!]/g, "\\$&");
    var re = new RegExp("\\b" + pat + "\\b", "gi");
    var parts = f.split('"'); // odd indexes are inside strings
    return parts.map(function (p, i) {
      return i % 2 ? p : p.replace(re, literal);
    }).join('"');
  }

  function unlinkEdge(from, to) {
    var t = nodeById(to);
    if (!t || !t.formula) return;
    var e = (cur.graph.edges || []).find(function (x) {
      return x.from === from && x.to === to;
    });
    var lit = (e && e.literal) || "0";
    applyFormula(to, unlinkFormula(t.formula, from, lit));
    toast("Unlinked " + from + " -> " + to + " (replaced by " + lit + ")");
  }

  // Scene-mode unlink: the stored link data names the concrete scope ref
  // (nodename!a / global!a) and the target attr - same literal
  // substitution, written through the generic formula path.
  function unlinkSceneEdge(d) {
    var t = (cur.graph.nodes || []).find(function (n) { return n.id === d.to; });
    var ta = t && (t.attrs || []).find(function (a) { return a.name === d.toAttr; });
    if (!ta || !ta.formula) return;
    var refId = d.refId || ((d.from === "$globals" ? "global!" : "") + d.fromAttr);
    var lit = d.literal || "0";
    send({ entityId: d.to, name: d.toAttr,
           formula: unlinkFormula(ta.formula, refId, lit) });
    toast("Unlinked " + refId + " -> " + d.toAttr +
          " (replaced by " + lit + ")");
  }

  // ---- add attribute -------------------------------------------------
  function openNewAttr() {
    document.getElementById("gnewname").value = "";
    document.getElementById("gnew").classList.add("show");
    setTimeout(function () {
      document.getElementById("gnewname").focus();
    }, 0);
  }

  function hideNewAttr() {
    document.getElementById("gnew").classList.remove("show");
  }

  function submitNewAttr() {
    var raw = document.getElementById("gnewname").value;
    hideNewAttr();
    var name = raw.trim();
    if (!name) return;
    if (!/^[a-zA-Z][a-zA-Z0-9_]*$/.test(name)) {
      toast("Invalid name '" + name + "' - letters, digits, underscores", true);
      return;
    }
    if (cur && nodeById(name.toLowerCase())) {
      toast("'" + name + "' already exists", true);
      return;
    }
    if (cur && cur.entityId) {
      send({ op: "addParam", entityId: cur.entityId, name: name });
    }
  }

  document.getElementById("gadd").addEventListener("click", openNewAttr);
  document.getElementById("gnok").addEventListener("click", submitNewAttr);
  document.getElementById("gncancel").addEventListener("click", hideNewAttr);
  document.getElementById("gnewname").addEventListener("keydown", function (ev) {
    ev.stopPropagation();
    if (ev.key === "Enter") submitNewAttr();
    else if (ev.key === "Escape") hideNewAttr();
  });

  // ---- node title alias ----------------------------------------------
  // A custom title is a display label stored in lay.titles (or the
  // fold/stencil record) - it never touches _odc.name, so scope refs,
  // edges, fold membership and find-by-name all keep working. Empty
  // input (or Reset) restores the data-derived title.
  var renameTarget = null;

  function openRename(n) {
    var o = n && n._odc;
    if (!o || !o.name) return;
    renameTarget = n;
    var real = n._odcTitle || o.name;
    var hint = o.dcname ? " (scope: " + o.dcname + "!)" : "";
    document.getElementById("grtext").textContent =
      "Rename " + real + hint;
    var inp = document.getElementById("grname");
    inp.placeholder = real;
    inp.value = n.title !== real ? n.title : "";
    document.getElementById("grename").classList.add("show");
    setTimeout(function () { inp.focus(); inp.select(); }, 0);
  }

  function hideRename() {
    renameTarget = null;
    document.getElementById("grename").classList.remove("show");
  }

  function submitRename(reset) {
    var n = renameTarget;
    var v = reset ? "" :
      document.getElementById("grname").value.trim();
    hideRename();
    if (!n) return;
    var o = n._odc;
    var lay = layoutFor(cur.entityId);
    if (o.kind === "fold") {
      var fd = (lay.folds || {})[o.fid];
      if (!fd) return;
      fd.title = v || "Subgraph";
      n.title = fd.title;
    } else if (o.kind === "vx") {
      var sd = (lay.stencils || {})[o.vid];
      if (!sd) return;
      if (v) sd.title = v; else delete sd.title;
      n.title = sd.title || n._odcTitle;
    } else {
      lay.titles = lay.titles || {};
      if (v) lay.titles[o.name] = v; else delete lay.titles[o.name];
      n.title = v || n._odcTitle || o.name;
    }
    n.setDirtyCanvas(true, true);
    sendLayoutSoon();
  }

  document.getElementById("grok").addEventListener("click",
    function () { submitRename(false); });
  document.getElementById("grreset").addEventListener("click",
    function () { submitRename(true); });
  document.getElementById("grcancel").addEventListener("click", hideRename);
  document.getElementById("grname").addEventListener("keydown", function (ev) {
    ev.stopPropagation();
    if (ev.key === "Enter") submitRename(false);
    else if (ev.key === "Escape") hideRename();
  });

  // Async feedback for ops without a graph re-push: {error|msg} toasts;
  // {ok,formula|errors,applied} updates the subgraph preview/apply bar.
  window.onGraphStatus = function (r) {
    if (r.ok !== undefined) {
      if (r.vid && r.applied) recordApplied(r);
      return setSubStatus(r);
    }
    if (r.error) toast(r.error, true);
    else if (r.msg) toast(r.msg);
  };

  // ---- formula canvas access ----------------------------------------
  function openFx(name) {
    var n = nodeById(name);
    if (!cur || !cur.entityId || !n) return;
    if (n.external || n.virtual) {
      toast("'" + name + "' is external/builtin - no local formula", true);
      return;
    }
    send({ op: "openNodes", entityId: cur.entityId, name: name });
  }

  // ---- theme ----------------------------------------------------------
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

  // Kind accent as a thin box color - a filled title bar swallows labels.
  function tint(node, varName) {
    node.boxcolor = cssVar(varName);
  }

  // ---- node classes ---------------------------------------------------
  // All nodes are data-owned: no delete/clone through the canvas.
  class ODCNode extends LGraphNode {
    constructor(title) {
      super(title || "node");
      this.removable = false;
      this.clonable = false;
      this.block_delete = true;
      this._odc = {};
      // Data-derived title kept for rename resets - a custom title is a
      // display alias in lay.titles, never a rename of _odc.name.
      this._odcTitle = this.title;
    }
    getMenuOptions() { return odcMenu(this); }
    // litegraph shows Remove/Rename Slot on slot right-click - those are
    // meaningless on data-owned nodes, so surface the node menu instead.
    getSlotMenuOptions() { return odcMenu(this); }
  }

  class ODCSubNode extends SubgraphNode {
    constructor(graph, subgraph, instanceData) {
      super(graph, subgraph, instanceData);
      this.removable = false;
      this.clonable = false;
      this.block_delete = true;
      this._odc = {};
      // stock "enter_subgraph" title button uses an icon-font glyph we
      // don't ship - it renders as tofu. Double-click/menu do the same.
      this.title_buttons = (this.title_buttons || []).filter(
        function (b) { return b.name !== "enter_subgraph"; });
    }
    getMenuOptions() { return odcMenu(this); }
    getSlotMenuOptions() { return odcMenu(this); }
  }

  // Stock litegraph collapses via a small circle at the titlebar's left
  // edge. Keep it a top-left glyph button only - the rest of the
  // titlebar stays a drag handle and double-click rename zone - and
  // draw a ComfyUI-style accordion chevron instead of the circle.
  var origCollapse = LGraphNode.prototype.collapse;
  LGraphNode.prototype.isPointInCollapse = function (x, y) {
    return x >= this.pos[0] &&
           x < this.pos[0] + LiteGraph.NODE_TITLE_HEIGHT &&
           y >= this.pos[1] - LiteGraph.NODE_TITLE_HEIGHT &&
           y < this.pos[1];
  };
  LGraphNode.prototype.collapse = function (force) {
    origCollapse.call(this, force);
    sendLayoutSoon();
  };

  // Collapse glyph: chevron down while expanded, right while collapsed.
  // Sits in the same top-left titlebox spot the stock circle occupies.
  var origDrawTitleBox = LGraphNode.prototype.drawTitleBox;
  LGraphNode.prototype.drawTitleBox = function (ctx, opts) {
    if (this.onDrawTitleBox || !this.collapsible) {
      return origDrawTitleBox.call(this, ctx, opts);
    }
    var th = (opts && opts.title_height) || LiteGraph.NODE_TITLE_HEIGHT;
    var cx = th * 0.5, cy = th * -0.5;
    ctx.strokeStyle = this.renderingBoxColor;
    ctx.lineWidth = 1.6;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.beginPath();
    if (this.flags && this.flags.collapsed) {
      ctx.moveTo(cx - 2.5, cy - 4.5);
      ctx.lineTo(cx + 3, cy);
      ctx.lineTo(cx - 2.5, cy + 4.5);
    } else {
      ctx.moveTo(cx - 4.5, cy - 2.5);
      ctx.lineTo(cx, cy + 3);
      ctx.lineTo(cx + 4.5, cy - 2.5);
    }
    ctx.stroke();
  };

  // Stock resize hit-testing needs the pointer inside a 15-unit corner
  // square - hard to hit, and invisible until the cursor changes. Widen
  // the grab square, allow a few units of overshoot outside the bounds,
  // and cap at half the node so corners can't overlap on small nodes.
  // A corner bracket is drawn on hover in onDrawForeground (below).
  var RESIZE_GRAB = 26, RESIZE_OVER = 9;
  LGraphNode.prototype.findResizeDirection = function (x, y) {
    if (this.resizable === false) return;
    var b = this.boundingRect;
    if (!b) return;
    if (x < b.x - RESIZE_OVER || y < b.y - RESIZE_OVER ||
        x > b.right + RESIZE_OVER || y > b.bottom + RESIZE_OVER) return;
    var w = b.width != null ? b.width : b[2];
    var h = b.height != null ? b.height : b[3];
    var k = Math.min(RESIZE_GRAB + RESIZE_OVER, w / 2, h / 2);
    if (x >= b.right - k && y >= b.bottom - k) return "SE";
    if (x <= b.x + k && y >= b.bottom - k) return "SW";
    if (x >= b.right - k && y <= b.y + k) return "NE";
    if (x <= b.x + k && y <= b.y + k) return "NW";
  };

  function odcMenu(n) {
    var o = n._odc || {};
    var ren = { content: "Rename",
      callback: function () { openRename(n); } };
    if (o.kind === "fold") return [ren,
      { content: "Open subgraph",
        callback: function () { canvas.openSubgraph(n.subgraph); } },
      { content: "Unfold",
        callback: function () { unfold(o.fid); } }
    ];
    if (o.kind === "vx") return [ren,
      { content: "Edit expression",
        callback: function () { canvas.openSubgraph(n.subgraph); } },
      { content: "Remove stencil",
        callback: function () { removeStencil(o.vid); } }
    ];
    if (o.kind === "ent") return [ren,
      { content: "Open dependency graph",
        callback: function () { navEntity(o.eid); } },
      { content: o.expanded ? "Hide unused attributes"
        : "Show all attributes" +
          (o.hidden ? " (" + o.hidden + " hidden)" : ""),
        callback: function () { toggleShowAll(o.eid); } }
    ];
    if (o.kind === "pseudo") return [ren,
      { content: "(edit globals in the panel)", disabled: true }];
    if (o.kind === "sub") return [ren,
      { content: "Open formula graph",
        callback: function () { canvas.openSubgraph(n.subgraph); } },
      { content: "Edit formula (fx)",
        callback: function () { openFx(o.name); } }
    ];
    if (o.kind === "param") return [ren,
      { content: "Open formula canvas",
        callback: function () { openFx(o.name); } }
    ];
    if (o.kind === "ext" || o.kind === "virt") return [ren,
      { content: "(external / builtin)", disabled: true }];
    return [{ content: "(external / builtin)", disabled: true }];
  }

  // ---- inner (AST) nodes ----------------------------------------------
  // Editable: same kit nodes/widgets as the fx editor. _odc marks them
  // (IO docks lack it) so canvas delete/menus can tell them apart.
  function makeInner(nd, argc) {
    return kit.makeNode(nd.t, nd.v, { k: nd.k, argc: argc });
  }

  // Inside a subgraph, attr/ref leaves don't become nodes: the subgraph's
  // named input slots represent them (one slot per referenced name,
  // deduped), wired straight into the consuming ports. Single-use const
  // leaves collapse into port manual widgets (same rule as the fx editor).
  function buildSub(sub, doc) {
    var nodes = doc.nodes || {}, links = doc.links || [];
    var leaf = {}; // doc node id -> referenced attr name
    Object.keys(nodes).forEach(function (id) {
      var t = nodes[id].t;
      if (t === "attr" || t === "ref") leaf[id] = nodes[id].v;
    });
    var useCnt = {}, collapsed = {}, manual = {};
    links.forEach(function (l) { useCnt[l.f] = (useCnt[l.f] || 0) + 1; });
    links.forEach(function (l) {
      var src = nodes[l.f];
      if (src && src.t === "const" && useCnt[l.f] === 1 && nodes[l.t]) {
        collapsed[l.f] = true;
        (manual[l.t] = manual[l.t] || {})[l.p] =
          window.ODCAst.litDisplay(src.v, src.k);
      }
    });
    var argc = {};
    links.forEach(function (l) { argc[l.t] = (argc[l.t] || 0) + 1; });
    var depth = window.ODCAst.layoutDepth(nodes, links);
    var perLvl = {}, idMap = {};
    Object.keys(nodes).forEach(function (id) {
      if (leaf[id] || collapsed[id]) return;
      var n = makeInner(nodes[id], argc[id] || 0);
      var man = manual[id] || {};
      (n.widgets || []).forEach(function (w) {
        if (w._port && man[w._port] != null) w.value = man[w._port];
      });
      var lv = depth[id] || 0;
      perLvl[lv] = (perLvl[lv] || 0) + 1;
      n.pos = [160 + lv * 230, 140 + (perLvl[lv] - 1) * 110];
      sub.add(n);
      idMap[id] = n;
    });
    links.forEach(function (l) {
      if (collapsed[l.f]) return;
      var dst = idMap[l.t];
      if (!dst) return;
      var inIdx = dst.inputs.findIndex(function (i) {
        return i.name === l.p;
      });
      if (inIdx < 0) return;
      if (leaf[l.f] != null) {
        var si = sub.inputs.find(function (x) { return x.name === leaf[l.f]; });
        if (si) si.connect(dst.inputs[inIdx], dst);
      } else {
        var src = idMap[l.f];
        if (src) src.connect(0, dst, inIdx);
      }
    });
    var rn = idMap[doc.root];
    if (rn && sub.outputs[0]) {
      sub.outputs[0].connect(rn.outputs[0], rn);
    }
    // The IO docks both default to x=0 and overlap; park the output dock
    // to the right of the inner layout. arrange() (auto-run while dirty)
    // sizes them to their slots.
    var maxX = 160;
    Object.keys(idMap).forEach(function (id) {
      maxX = Math.max(maxX, idMap[id].pos[0] + idMap[id].size[0]);
    });
    sub.inputNode.pos = [0, 60];
    sub.outputNode.pos = [maxX + 180, 60];
    sub.inputNode.arrange();
    sub.outputNode.arrange();
    (sub._nodes || []).forEach(kit.syncManWidgets);
    // Editable formula canvas: link/node changes feed the live preview.
    // link-created arrives via the canvas-level linkConnector listener
    // in ensureCanvas (it never lands on graph/subgraph .events).
    sub.onNodeAdded = function () { requestSubPreview(); };
    sub.onNodeRemoved = function () { requestSubPreview(); };
  }

  // Serialize a formula subgraph back to the AstGraph doc schema. Input
  // dock slots become attr/ref leaf nodes (deduped by name); the node
  // feeding the output dock is the root; unwired ports with a typed
  // value emit synthesized const nodes - same rules as the fx editor.
  function subDoc(sub) {
    var nodes = {}, links = [], root = null;
    var inId = sub.inputNode.id, outId = sub.outputNode.id;
    var leafOf = {};
    function leafId(name) {
      if (!leafOf[name]) {
        leafOf[name] = "in_" + name;
        nodes[leafOf[name]] = { t: name.indexOf("!") >= 0 ? "ref" : "attr",
                                v: name, k: null };
      }
      return leafOf[name];
    }
    (sub._nodes || []).forEach(function (n) {
      if (!n._odc) return;
      nodes[String(n.id)] = { t: n._odc.t === "act" ? "call" : n._odc.t,
                              v: n._odc.v, k: n._odc.k };
    });
    (sub._links ? Array.from(sub._links.values()) : []).forEach(function (l) {
      var tgt, pname;
      if (l.target_id === outId) {
        root = l.origin_id === inId
          ? leafId(sub.inputs[l.origin_slot].name)
          : String(l.origin_id);
      } else if (l.origin_id === inId) {
        var nm = sub.inputs[l.origin_slot] && sub.inputs[l.origin_slot].name;
        tgt = sub.getNodeById(l.target_id);
        pname = tgt && tgt.inputs[l.target_slot] &&
                tgt.inputs[l.target_slot].name;
        if (nm && pname) {
          links.push({ f: leafId(nm), t: String(l.target_id), p: pname });
        }
      } else {
        tgt = sub.getNodeById(l.target_id);
        pname = tgt && tgt.inputs[l.target_slot] &&
                tgt.inputs[l.target_slot].name;
        if (pname) {
          links.push({ f: String(l.origin_id), t: String(l.target_id),
                       p: pname });
        }
      }
    });
    (sub._nodes || []).forEach(function (n) {
      if (!n._odc) return;
      (n.widgets || []).forEach(function (w) {
        if (!w._port) return;
        var inp = (n.inputs || []).find(function (i) {
          return i.name === w._port;
        });
        if (!inp || inp.link != null) return;
        var raw = String(w.value || "").trim();
        if (!raw) return;
        var lit = window.ODCAst.parseLit(raw);
        var mid = "m" + n.id + "_" + w._port;
        nodes[mid] = { t: "const", v: lit.v, k: lit.k };
        links.push({ f: mid, t: String(n.id), p: w._port });
      });
    });
    return { nodes: nodes, links: links, root: root };
  }

  // ---- subgraph editing: preview + apply ----------------------------------
  function setSubStatus(r) {
    var el = document.getElementById("gsubformula");
    var apply = document.getElementById("gsubapply");
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
  }

  function requestSubPreview() {
    var sub = canvas && canvas.subgraph;
    if (!sub || sub._odcFold || building) return;
    // Stencil edits persist as layout state; formula subgraphs derive
    // from param data and rebuild anyway.
    if (sub._odcStencil) sendLayoutSoon();
    clearTimeout(previewTimer);
    previewTimer = setTimeout(function () {
      var s2 = canvas.subgraph;
      if (!s2) return;
      var doc = subDoc(s2);
      if (!doc.root) {
        setSubStatus({ ok: false,
          errors: ["connect an expression to FORMULA"] });
        return;
      }
      send({ op: "previewDoc", entityId: cur.entityId, name: s2.name,
             doc: doc });
    }, 250);
  }

  // Node palette inside a formula subgraph - same categories as the fx
  // editor. Sources: cur.palette pushed by Ruby; attrs fall back to the
  // top-level node ids when absent. With `picker` set, item clicks go to
  // picker(type, v, extra) instead of adding to `sub` - the root canvas
  // reuses the same palette to seed stencil nodes.
  // Scene mode has no per-entity palette: attr refs are scoped -
  // dcname!attr for entity nodes, global!attr for the pseudo-node.
  function scenePaletteAttrs() {
    if (!cur.scene) return null;
    var out = [];
    (cur.graph.nodes || []).forEach(function (n) {
      var scope = n.id === "$globals" ? "global" : n.dcname;
      if (!scope) return;
      (n.attrs || []).forEach(function (a) {
        out.push(scope + "!" + a.name);
      });
    });
    return out;
  }

  function subMenuItems(sub, picker) {
    var pal = cur.palette || {};
    var attrs = pal.attrs || scenePaletteAttrs() ||
      (cur.graph.nodes || [])
        .filter(function (n) { return !n.external && !n.virtual; })
        .map(function (n) { return n.id; });
    function sub2(name, opts) {
      return { content: name, has_submenu: true, submenu: { options: opts } };
    }
    function addItem(type, v, extra) {
      return {
        content: String(v === "" ? "(empty text)" : v),
        callback: function () {
          if (picker) return picker(type, v, extra);
          var n = kit.makeNode(type, v, extra);
          var m = canvas.graph_mouse || [160, 140];
          n.pos = [m[0] - 40, m[1] - 20];
          sub.add(n);
          kit.syncManWidgets(n);
          requestSubPreview();
        }
      };
    }
    var ops = window.ODCAst.BIN_OPS.map(function (op) {
      return addItem("bin", op);
    });
    ops.push({ content: "unary -", callback: addItem("un", "-").callback },
             { content: "NOT", callback: addItem("un", "NOT").callback });
    var attrSubs = [];
    if (attrs.length) {
      attrSubs.push(sub2("Custom",
        attrs.map(function (a) { return addItem("attr", a); })));
    }
    if ((pal.builtins || []).length) {
      attrSubs.push(sub2("SketchUp",
        pal.builtins.map(function (a) { return addItem("attr", a); })));
    }
    if ((pal.globals || []).length) {
      attrSubs.push(sub2("Globals", pal.globals.map(function (g) {
        return addItem("ref", "global!" + g);
      })));
    }
    if ((pal.skprops || []).length) {
      attrSubs.push(sub2("SketchUp props", pal.skprops.map(function (n) {
        return addItem("ref", "sketchup!" + n);
      })));
    }
    if ((pal.modelprops || []).length) {
      attrSubs.push(sub2("Model", pal.modelprops.map(function (n) {
        return addItem("ref", "model!" + n);
      })));
    }
    if ((pal.sceneprops || []).length) {
      attrSubs.push(sub2("Scene", pal.sceneprops.map(function (n) {
        return addItem("ref", "scene!" + n);
      })));
    }
    if ((pal.dicts || []).length) {
      attrSubs.push(sub2("Dictionaries", pal.dicts.map(function (n) {
        return addItem("ref", n);
      })));
    }
    var fns = pal.functions || [];
    var grouped = {};
    var fnSubs = (pal.fnGroups || []).map(function (pair) {
      var names = fns.filter(function (f) {
        if (pair[1].indexOf(f) < 0) return false;
        grouped[f] = true;
        return true;
      });
      return names.length
        ? sub2(pair[0], names.map(function (f) { return addItem("call", f); }))
        : null;
    }).filter(Boolean);
    var rest = fns.filter(function (f) { return !grouped[f]; });
    if (rest.length) {
      fnSubs.push(sub2("Other",
        rest.map(function (f) { return addItem("call", f); })));
    }
    var items = [
      sub2("Operators", ops),
      sub2("Literals", [
        { content: "Number",
          callback: addItem("const", "0", { k: "num" }).callback },
        { content: "Text",
          callback: addItem("const", "", { k: "str" }).callback }
      ]),
      sub2("Attributes", attrSubs),
      sub2("Functions", fnSubs)
    ];
    if (sub && String(sub.name || "").toLowerCase() === "onclick"
        && (pal.actions || []).length) {
      items.push(sub2("Actions",
        pal.actions.map(function (f) { return addItem("act", f); })));
    }
    return items;
  }

  // ---- subgraphs --------------------------------------------------------
  function uuid() {
    return (crypto.randomUUID ? crypto.randomUUID()
      : "sg-" + Math.random().toString(16).slice(2));
  }

  // Subgraph inputs = every dep-edge source into this attribute plus any
  // attr/ref leaf names in its formula doc (deduped).
  function subgraphInputs(d) {
    var set = [];
    (cur.graph.edges || []).forEach(function (e) {
      if (e.to === d.id && set.indexOf(e.from) < 0) set.push(e.from);
    });
    Object.keys((d.doc && d.doc.nodes) || {}).forEach(function (id) {
      var nd = d.doc.nodes[id];
      if ((nd.t === "attr" || nd.t === "ref") && set.indexOf(nd.v) < 0) {
        set.push(nd.v);
      }
    });
    return set;
  }

  function makeSubgraphNode(d) {
    var sub = rootGraph.createSubgraph({
      id: uuid(), name: d.id,
      inputNode: { id: -10, bounding: [0, 0, 100, 160] },
      outputNode: { id: -20, bounding: [0, 0, 100, 160] },
      inputs: [], outputs: [], widgets: [],
      nodes: [], links: [], groups: [], reroutes: []
    });
    subgraphInputs(d).forEach(function (nm) { sub.addInput(nm, "*"); });
    sub.addOutput("out", "*");
    buildSub(sub, d.doc || { nodes: {}, links: [] });
    var sn = new ODCSubNode(rootGraph, sub, { id: -1 });
    sn._odc = { kind: "sub", name: d.id };
    sn.title = d.id;
    sn._odcTitle = d.id;
    sn.setSize(sn.computeSize());
    if (d.cyclic) sn.boxcolor = cssVar("--error");
    return sn;
  }

  // ---- expression stencils -------------------------------------------------
  // Canvas-owned scratch expression nodes: a formula subgraph with no
  // owning param. Inputs are the doc's attr/ref names (auto-linked to
  // matching nodes); wiring the output to a param applies the composed
  // formula via applyDoc. Persisted in lay.stencils like folds.
  function docRefs(doc) {
    var set = [];
    Object.keys((doc && doc.nodes) || {}).forEach(function (id) {
      var nd = doc.nodes[id];
      if ((nd.t === "attr" || nd.t === "ref") && set.indexOf(nd.v) < 0) {
        set.push(nd.v);
      }
    });
    return set;
  }

  function stencilTitle(doc) {
    var rn = doc && doc.nodes && doc.nodes[doc.root];
    if (rn) return rn.t === "call" ? rn.v + "()" : String(rn.v);
    var ids = Object.keys((doc && doc.nodes) || {});
    return ids.length === 1 ? String(doc.nodes[ids[0]].v) + "…"
                            : "expression";
  }

  function makeStencilNode(vid, sd) {
    var sub = rootGraph.createSubgraph({
      id: vid, name: stencilTitle(sd.doc),
      inputNode: { id: -10, bounding: [0, 0, 100, 160] },
      outputNode: { id: -20, bounding: [0, 0, 100, 160] },
      inputs: [], outputs: [], widgets: [],
      nodes: [], links: [], groups: [], reroutes: [] });
    sub._odcStencil = vid;
    docRefs(sd.doc).forEach(function (nm) { sub.addInput(nm, "*"); });
    sub.addOutput("out", "*");
    buildSub(sub, sd.doc || { nodes: {}, links: [] });
    var sn = new ODCSubNode(rootGraph, sub, { id: -1 });
    sn._odc = { kind: "vx", name: "stencil:" + vid, vid: vid };
    sn._odcTitle = stencilTitle(sd.doc);
    sn.title = sd.title || sn._odcTitle;
    sn.pos = sd.pos || [120, 120];
    // One literal widget per input: an unwired slot keeps its name, so
    // lits["b"] can only ever apply while b is unbound - wiring renames
    // the slot (and the doc leaf) and the lit stops matching.
    (sub.inputs || []).forEach(function (inp) {
      var w = sn.addWidget("text", inp.name,
        (sd.lits && sd.lits[inp.name]) || "",
        function () { maybeReapply(vid); }, {});
      w._litSlot = inp.name;
    });
    // A bare-const stencil is just a literal holder - edit its value on
    // the node instead of diving inside.
    var nds = (sd.doc && sd.doc.nodes) || {};
    var rootNd = nds[sd.doc && sd.doc.root] ||
                 (Object.keys(nds).length === 1 ? nds[Object.keys(nds)[0]]
                                              : null);
    if (rootNd && rootNd.t === "const" && !(sub.inputs || []).length) {
      var cw = sn.addWidget("text", "value",
        (sd.lits && sd.lits["__const"]) || rootNd.v,
        function () { maybeReapply(vid); }, {});
      cw._litSlot = "__const";
    }
    sn.onConnectionsChange = function () { syncLitWidgets(sn); };
    syncLitWidgets(sn);
    sn.setSize(sn.computeSize());
    return sn;
  }

  // Hide an input's literal widget while that slot is wired - the bound
  // ref wins, the literal is just the fallback.
  function syncLitWidgets(n) {
    var changed = false;
    (n.widgets || []).forEach(function (w) {
      if (!w._litSlot) return;
      var inp = (n.inputs || []).find(function (i) {
        return i.name === w._litSlot;
      });
      var h = !!(inp && inp.link != null);
      if (w.hidden !== h) { w.hidden = h; changed = true; }
    });
    if (changed) {
      n.setSize(n.computeSize());
      n.setDirtyCanvas(true, true);
    }
  }

  // Unwired-input literals typed on the stencil node, keyed by slot
  // (= leaf) name. Empty values don't bind.
  function litsOf(sn) {
    var l = {};
    (sn.widgets || []).forEach(function (w) {
      if (w._litSlot && String(w.value || "").trim() !== "") {
        l[w._litSlot] = String(w.value).trim();
      }
    });
    return l;
  }

  // Bake unwired-input literals into the doc: a leaf whose name has a
  // lit entry becomes a const. Bound leaves were renamed by their wire,
  // so only unbound names can match.
  function docWithLits(doc, lits) {
    if (!lits || !Object.keys(lits).length) return doc;
    var nodes = {};
    Object.keys(doc.nodes || {}).forEach(function (id) {
      var nd = doc.nodes[id];
      if ((nd.t === "attr" || nd.t === "ref") && lits[nd.v] != null) {
        var lit = window.ODCAst.parseLit(lits[nd.v]);
        nodes[id] = { t: "const", v: lit.v, k: lit.k };
      } else {
        nodes[id] = nd;
      }
    });
    // Bare-const stencil: the "value" widget edits the literal itself.
    if (lits["__const"] != null) {
      var rid = doc.root || Object.keys(nodes)[0];
      var rn = rid && nodes[rid];
      if (rn && rn.t === "const") {
        var lit2 = window.ODCAst.parseLit(lits["__const"]);
        nodes[rid] = { t: "const", v: lit2.v, k: lit2.k };
      }
    }
    return { nodes: nodes, links: doc.links, root: doc.root };
  }

  // Once a stencil has been applied to a target, later edits (literal
  // widgets, input rebinding, closing its interior) silently re-write
  // the target's formula - but only while it still holds the exact
  // text we wrote. A manual edit detaches the link.
  function maybeReapply(vid) {
    var lay = cur && cur.entityId && layoutByEnt[cur.entityId];
    var sd = lay && lay.stencils && lay.stencils[vid];
    var ap = sd && sd.appliedTo;
    if (!ap) return;
    var sn = (rootGraph._nodes || []).find(function (n) {
      return n._odc && n._odc.vid === vid;
    });
    if (!sn) return;
    if (targetFormula(ap.eid || cur.entityId, ap.name) !== ap.formula) {
      sd.appliedTo = null;
      return;
    }
    var doc = docWithLits(subDoc(sn.subgraph), litsOf(sn));
    send({ op: "applyDoc", entityId: ap.eid || cur.entityId,
           name: ap.name, doc: doc, vid: vid });
  }

  function targetFormula(eid, name) {
    if (cur.scene) {
      var n = (cur.graph.nodes || []).find(function (x) {
        return x.id === eid;
      });
      var a = n && (n.attrs || []).find(function (x) {
        return x.name === name;
      });
      return a && a.formula;
    }
    var t = nodeById(name);
    return t && t.formula;
  }

  // Ruby echoes the applied formula back - record the target so edits
  // can re-apply while the formula text still matches.
  function recordApplied(r) {
    var lay = cur && cur.entityId && layoutByEnt[cur.entityId];
    var sd = lay && lay.stencils && lay.stencils[r.vid];
    if (!sd) return;
    sd.appliedTo = { eid: r.eid, name: r.name, formula: r.formula };
    sendLayoutSoon();
  }

  // Find the node + output slot that should feed a stencil input named
  // `rname`. Dep mode resolves plain attr names; scene mode resolves
  // global!x, name!attr (via node dcname) and uniquely-matched attrs.
  function refSourceFor(rname, idMap, g) {
    if (rname.indexOf("!") >= 0) {
      var p = rname.split("!");
      if (p[0] === "global") {
        var gn = idMap["$globals"];
        return gn ? { node: gn, attr: p[1] } : null;
      }
      var ent = (g.nodes || []).find(function (n) { return n.dcname === p[0]; });
      return ent ? { node: idMap[ent.id], attr: p[1] } : null;
    }
    if (idMap[rname]) return { node: idMap[rname], attr: null };
    var hits = (g.nodes || []).filter(function (n) {
      return (n.attrs || []).some(function (a) { return a.name === rname; });
    });
    return hits.length === 1
      ? { node: idMap[hits[0].id], attr: rname } : null;
  }

  // Recreate stencils at root and auto-link each input to its same-named
  // source node. The links are display-only intent; real edges still
  // come from cur.graph.edges.
  function buildStencils(graph, g, idMap) {
    var lay = cur && cur.entityId && layoutByEnt[cur.entityId];
    var stencils = (lay && lay.stencils) || {};
    Object.keys(stencils).forEach(function (vid) {
      var sd = stencils[vid];
      if (!sd || !sd.doc) return;
      var sn = makeStencilNode(vid, sd);
      graph.add(sn);
      applyLayColor(sn);
      (sn.inputs || []).forEach(function (inp, ii) {
        var src = refSourceFor(inp.name, idMap, g);
        if (!src || !src.node) return;
        var oi = src.attr == null ? 0
          : (src.node.outputs || []).findIndex(function (o) {
              return o.name === src.attr;
            });
        if (oi >= 0) connectCross(src.node, oi, sn, ii, null);
      });
      syncLitWidgets(sn);
      // The applied binding drawn as a persistent link - a stencil's
      // out-wire is consumed on write, so without this the connection
      // looks rejected even though the formula landed.
      var ap = sd.appliedTo;
      if (ap &&
          targetFormula(ap.eid || cur.entityId, ap.name) === ap.formula) {
        var tn = cur.scene ? idMap[ap.eid] : idMap[ap.name];
        if (tn) {
          var tii = cur.scene
            ? (tn.inputs || []).findIndex(function (i) {
                return i.name === ap.name; })
            : (tn.inputs || []).findIndex(function (i) {
                return i.name === "deps"; });
          if (!cur.scene && tii < 0) tii = 0;
          if (tii >= 0) {
            var al = connectCross(sn, 0, tn, tii,
              { from: "stencil:" + vid, to: ap.name, applied: true });
            if (al) al.color = cssVar("--accent2");
          }
        }
      } else if (ap) {
        // Formula diverged from what we wrote - the binding is stale.
        sd.appliedTo = null;
      }
    });
  }

  // Palette pick at root: seed a stencil whose doc is a single node of
  // the picked type, then rebuild so it lands as a real node.
  function createStencil(type, v, extra) {
    var lay = layoutFor(cur.entityId);
    lay.stencils = lay.stencils || {};
    var vid = "vx_" + Date.now().toString(36);
    var m = canvas.graph_mouse || [120, 120];
    var doc;
    // Operators become real op nodes: a/b (or x) leaves are the input
    // dock slots, so the stencil gets wireable inputs + literal widgets
    // on the outside immediately.
    if (type === "bin") {
      doc = { nodes: { ia: { t: "attr", v: "a" },
                       ib: { t: "attr", v: "b" },
                       op: { t: "bin", v: v } },
              links: [{ f: "ia", t: "op", p: "a" },
                      { f: "ib", t: "op", p: "b" }],
              root: "op" };
    } else if (type === "un") {
      doc = { nodes: { ix: { t: "attr", v: "x" },
                       op: { t: "un", v: v } },
              links: [{ f: "ix", t: "op", p: "x" }],
              root: "op" };
    } else if (type === "call") {
      // Functions get one named input per argument: friendly names
      // (cond/then/else, x/ndigits, ...) from the astkit table so the
      // outer slots read like the signature.
      var arity = ((cur.palette || {}).fnArity || {})[v] || 1;
      doc = { nodes: { fn: { t: "call", v: v } }, links: [], root: "fn" };
      for (var ai = 0; ai < arity; ai++) {
        var anm = window.ODCAst.argLabel("call", v, "arg" + ai, ai, arity);
        doc.nodes["ia" + ai] = { t: "attr", v: anm };
        doc.links.push({ f: "ia" + ai, t: "fn", p: "arg" + ai });
      }
    } else {
      // A scoped pick (name!attr) is a ref, not a plain attr - same rule
      // subDoc uses when serializing input dock slots.
      var t = type === "attr" && String(v).indexOf("!") >= 0 ? "ref" : type;
      doc = { nodes: { n1: { t: t, v: v,
                             k: (extra && extra.k) || null } },
              links: [], root: null };
    }
    lay.stencils[vid] = { title: stencilTitle(doc), doc: doc,
                          pos: [m[0], m[1]] };
    window.renderGraph(cur);
    sendLayoutSoon();
  }

  // Wiring stencil.out -> param applies the doc as that param's formula
  // through the existing validated applyDoc path. Cross-entity in scene
  // mode: entityId is the target node's eid, name its attr.
  function applyStencil(tEid, tName, doc, vid) {
    var refs = docRefs(doc);
    var selfRef = tName;
    if (cur.scene) {
      var tn = (cur.graph.nodes || []).find(function (n) {
        return n.id === tEid;
      });
      selfRef = tn && tn.dcname ? tn.dcname + "!" + tName : tName;
    }
    if (refs.indexOf(selfRef) >= 0 || refs.indexOf(tName) >= 0) {
      toast("Expression references '" + tName +
            "' - applying it would self-reference", true);
      return;
    }
    var t = nodeById(tName) ||
            (cur.graph.nodes || []).find(function (n) {
              return n.id === tEid; });
    var hasF = t && (t.hasFormula ||
      (t.attrs || []).some(function (a) {
        return a.name === tName && a.hasFormula; }));
    var go = function () {
      send({ op: "applyDoc", entityId: tEid, name: tName, doc: doc,
             vid: vid });
    };
    if (hasF) {
      askConfirm("Replace formula of '" + tName +
                 "' with the stencil expression?", go);
    } else {
      go();
    }
  }

  // Wiring attr -> stencil input renames that ref inside the doc: the
  // slot named `x` fed by `width` rewrites every x-ref to width. Ref
  // names live on the subgraph's input slots (leaves are dock slots,
  // not nodes), so the rename is a slot rename - harvest re-derives
  // the doc from it.
  function renameStencilRefs(stencil, slotName, newRef) {
    var si = (stencil.subgraph.inputs || []).find(function (i) {
      return i.name === slotName;
    });
    if (!si) return;
    si.name = newRef;
    window.renderGraph(cur);
    maybeReapply(stencil._odc.vid);
    sendLayoutSoon();
  }

  // Stencils are canvas-owned - removal deletes them outright.
  function removeStencil(vid) {
    var lay = layoutFor(cur.entityId);
    delete lay.stencils[vid];
    window.renderGraph(cur);
    sendLayoutSoon();
  }

  // The display name a source node contributes when wired into a
  // stencil input: dep attrs are bare names, scene sources are scoped.
  function stencilRefName(node, slotIdx) {
    if (node._odc.kind === "vx") return null; // stencil->stencil: no name
    if (!cur.scene) return node._odc.name;
    var out = (node.outputs || [])[slotIdx];
    if (!out) return null;
    if (node._odc.eid === "$globals") return "global!" + out.name;
    return (node._odc.dcname || node._odc.name) + "!" + out.name;
  }

  // ---- scene-level graph --------------------------------------------------
  // One node per top-level osdc entity: outputs and inputs are the
  // entity's attributes; wires across nodes write name!/global! refs.
  // Compact slot policy: customs always show; builtins only when they
  // carry a formula or an edge (an edge endpoint must keep its slot or
  // the link can't render). Right-click toggles the full set.
  function makeSceneNode(d, connected) {
    var lay = cur && cur.entityId && layoutByEnt[cur.entityId];
    var all = lay && lay.showAll && lay.showAll[d.id];
    var n = new ODCNode(d.label || d.id);
    var hidden = 0;
    (d.attrs || []).forEach(function (a) {
      var vis = all || !a.builtin || a.hasFormula ||
                (connected && connected[a.name]);
      if (!vis) { hidden++; return; }
      n.addInput(a.name, 0);
      n.addOutput(a.name, 0);
    });
    n._odc = { kind: d.pseudo ? "pseudo" : "ent", eid: d.id, name: d.id,
               dcname: d.dcname,
               hidden: hidden, expanded: !!all };
    if (d.pseudo) tint(n, "--accent2");
    return n;
  }

  function buildScene(graph, g) {
    var lay = cur && cur.entityId && layoutByEnt[cur.entityId];
    var stored = (lay && lay.positions) || {};
    var collapsed = (lay && lay.collapsed) || {};
    // Attrs on an edge endpoint must stay slotted - per node.
    var conn = {};
    (g.edges || []).forEach(function (e) {
      (conn[e.from] = conn[e.from] || {})[e.fromAttr] = true;
      (conn[e.to] = conn[e.to] || {})[e.toAttr] = true;
    });
    var plan = foldPlan(graph);
    var idMap = {};
    (g.nodes || []).forEach(function (d, i) {
      var node = makeSceneNode(d, conn[d.id]);
      var alias = lay && lay.titles && lay.titles[d.id];
      if (alias) node.title = alias;
      var sz = node.computeSize();
      node.setSize(sz);
      var pos = stored[d.id] ? stored[d.id].slice(0, 2)
                             : [60 + (i % 4) * 320, 50 + Math.floor(i / 4) * 240];
      addGraphNode(plan, graph, node, d, pos, !!collapsed[d.id]);
      idMap[d.id] = node;
    });
    (g.edges || []).forEach(function (e) {
      var s = idMap[e.from], d = idMap[e.to];
      if (!s || !d) return;
      var oi = (s.outputs || []).findIndex(function (o) {
        return o.name === e.fromAttr;
      });
      var ii = (d.inputs || []).findIndex(function (i) {
        return i.name === e.toAttr;
      });
      if (oi < 0 || ii < 0) return;
      connectCross(s, oi, d, ii, e);
    });
    finalizeFolds(plan, collapsed);
    buildStencils(graph, g, idMap);
  }

  // ---- top-level graph ----------------------------------------------------
  function makeTopNode(d) {
    var n;
    if (d.external) {
      n = new ODCNode(d.id);
      n.addOutput("out", 0);
      n._odc = { kind: "ext", name: d.id };
      tint(n, "--accent2");
    } else if (d.virtual) {
      n = new ODCNode(d.id);
      n.addOutput("out", 0);
      n._odc = { kind: "virt", name: d.id };
      tint(n, "--accent");
    } else if (d.hasFormula && d.doc) {
      n = makeSubgraphNode(d);
    } else {
      n = new ODCNode(d.id);
      n.addInput("deps", 0);
      n.addOutput("out", 0);
      n._odc = { kind: "param", name: d.id };
    }
    if (d.cyclic) n.boxcolor = cssVar("--error");
    return n;
  }

  function inputIndexFor(node, from) {
    if (node.isSubgraphNode && node.isSubgraphNode()) {
      return node.inputs.findIndex(function (i) { return i.name === from; });
    }
    return node.inputs.length ? 0 : -1;
  }

  // Canvas layout state is user-owned, not data-owned: dragged node
  // positions and litegraph groups must survive every incoming re-push.
  function layoutFor(eid) {
    return layoutByEnt[eid] ||
      (layoutByEnt[eid] = { positions: {}, groups: [], collapsed: {},
                            folds: {}, showAll: {}, stencils: {},
                            titles: {}, colors: {} });
  }

  // Snapshot the current canvas arrangement before a rebuild so it can
  // be re-applied to the fresh graph. Keyed per entity - the window
  // retargets when the selection changes.
  function harvestLayout() {
    if (!rootGraph || !cur || !cur.entityId) return;
    var lay = layoutFor(cur.entityId);
    (rootGraph._nodes || []).forEach(function (n) {
      if (n._odc && n._odc.name) {
        lay.positions[n._odc.name] = [n.pos[0], n.pos[1]];
      }
      // Fold proxies carry their interior layout in the fold record -
      // positions/collapsed flags of the member nodes inside it.
      if (n._odc && n._odc.kind === "fold" && n.subgraph) {
        var fd = (lay.folds || {})[n._odc.fid];
        if (fd) {
          fd.pos = [n.pos[0], n.pos[1]];
          fd.innerPos = {};
          fd.innerCollapsed = {};
          (n.subgraph._nodes || []).forEach(function (m) {
            if (m._odc && m._odc.name) {
              fd.innerPos[m._odc.name] = [m.pos[0], m.pos[1]];
              if (m.flags && m.flags.collapsed) {
                fd.innerCollapsed[m._odc.name] = true;
              }
            }
          });
        }
      }
    });
    lay.groups = (rootGraph._groups || []).map(function (gr) {
      var b = gr._bounding;
      return { title: gr.title, color: gr.color,
               bounding: [b[0], b[1], b[2], b[3]] };
    });
    var col = {};
    var st = {};
    (rootGraph._nodes || []).forEach(function (n) {
      if (n._odc && n._odc.name && n.flags && n.flags.collapsed) {
        col[n._odc.name] = true;
      }
      // Stencil docs live on the node's subgraph - harvest them so a
      // reopen/refresh keeps the scratch expression. Only for records
      // that still exist: removeStencil deletes the record while the
      // old node is still on canvas.
      if (n._odc && n._odc.kind === "vx" && n.subgraph &&
          lay.stencils[n._odc.vid]) {
        var doc = subDoc(n.subgraph);
        st[n._odc.vid] = { title: stencilTitle(doc), doc: doc,
                           pos: [n.pos[0], n.pos[1]],
                           lits: litsOf(n),
                           appliedTo: lay.stencils[n._odc.vid].appliedTo };
      }
    });
    // Keep records with no node on the old canvas: createStencil writes
    // the record before its rebuild places the node.
    Object.keys(lay.stencils || {}).forEach(function (vid) {
      if (!st[vid]) st[vid] = lay.stencils[vid];
    });
    lay.collapsed = col;
    lay.stencils = st;
  }

  // Recreate stored group boxes on the fresh graph (nodes already exist,
  // so each group re-resolves which nodes sit inside its bounds).
  function restoreGroups(graph) {
    var lay = cur && cur.entityId && layoutByEnt[cur.entityId];
    ((lay && lay.groups) || []).forEach(function (gd) {
      var b = gd.bounding || [];
      var grp = new lg.LGraphGroup(gd.title || "Group");
      grp.pos = [b[0] || 0, b[1] || 0];
      grp.size = [Math.max(b[2] || 140, 20), Math.max(b[3] || 80, 20)];
      if (gd.color) grp.color = gd.color;
      graph.add(grp);
      grp.recomputeInsideNodes();
    });
  }

  // Report the arrangement to Ruby (session memory - a reopened dialog
  // restores it). Debounced; drags send once per gesture.
  function flushLayout() {
    if (!cur || !cur.entityId) return;
    clearTimeout(posTimer);
    posTimer = null;
    harvestLayout(); // catch menu edits (rename/recolor) too
    var lay = layoutFor(cur.entityId);
    send({ op: "saveLayout", entityId: cur.entityId,
           positions: lay.positions, groups: lay.groups,
           collapsed: lay.collapsed || {}, folds: lay.folds || {},
           showAll: lay.showAll || {},
           stencils: lay.stencils || {},
           titles: lay.titles || {},
           colors: lay.colors || {} });
  }

  function sendLayoutSoon() {
    if (!cur || !cur.entityId) return;
    clearTimeout(posTimer);
    posTimer = setTimeout(flushLayout, 400);
  }

  // "Add group" canvas menu entry - a colored container box; dragging
  // its title bar moves the nodes inside (stock litegraph behavior).
  function addGroup() {
    var grp = new lg.LGraphGroup("Group");
    var m = canvas.graph_mouse || [60, 60];
    grp.pos = [m[0], m[1]];
    rootGraph.add(grp);
    grp.recomputeInsideNodes();
    canvas.setDirty(true, true);
    sendLayoutSoon();
  }

  // ---- folds (selected nodes collapsed into one subgraph node) --------
  // A fold is canvas state: { title, pos, members:{name:1},
  // innerPos:{name:[x,y]}, innerCollapsed:{name:1} } under lay.folds.
  // Rebuilds place members inside a fresh LGraph subgraph and rewire
  // every boundary edge through that subgraph's IO slots, so the folded
  // node proxies the wiring without going stale (unlike litegraph's
  // convertToSubgraph, which clones nodes into serialized data).
  function foldPlan(graph) {
    var lay = cur && cur.entityId && layoutByEnt[cur.entityId];
    var folds = (lay && lay.folds) || {};
    var plan = { memberOf: {}, list: [] };
    Object.keys(folds).forEach(function (fid) {
      var fd = folds[fid];
      if (!fd || !fd.members) return;
      var sub = graph.createSubgraph({
        id: fid, name: fd.title || "Subgraph",
        inputNode: { id: -10, bounding: [0, 0, 75, 100] },
        outputNode: { id: -20, bounding: [0, 0, 75, 100] },
        inputs: [], outputs: [], widgets: [],
        nodes: [], links: [], groups: [], reroutes: [] });
      sub._odcFold = fid;
      var proxy = new ODCSubNode(graph, sub, { id: -1 });
      proxy._odc = { kind: "fold", name: "fold:" + fid, fid: fid };
      proxy.title = fd.title || "Subgraph";
      proxy._odcTitle = "Subgraph";
      proxy.pos = fd.pos || [120, 120];
      graph.add(proxy);
      applyLayColor(proxy);
      var fc = { fid: fid, data: fd, sub: sub, proxy: proxy,
                 inMap: {}, outMap: {} };
      Object.keys(fd.members).forEach(function (m) {
        if (fd.members[m]) plan.memberOf[m] = fc;
      });
      plan.list.push(fc);
    });
    return plan;
  }

  // Node color preset from the layout (lay.colors[_odc.name]) - same
  // alias channel as titles, using the litegraph/ComfyUI color set.
  function applyLayColor(node) {
    var lay = cur && cur.entityId && layoutByEnt[cur.entityId];
    var key = lay && lay.colors && node._odc &&
              lay.colors[node._odc.name];
    var opt = key && lg.LGraphCanvas.node_colors[key];
    if (opt) node.setColorOption(opt);
  }

  // Where a graph node lands: inside its fold's subgraph or at root.
  function addGraphNode(plan, graph, node, d, pos, isCollapsed) {
    applyLayColor(node);
    var fc = plan.memberOf[d.id];
    if (fc) {
      var ip = (fc.data.innerPos || {})[d.id];
      node.pos = ip ? ip.slice(0, 2) : pos;
      if ((fc.data.innerCollapsed || {})[d.id]) {
        node.flags.collapsed = true;
      }
      fc.sub.add(node);
      node._odcFold = fc;
    } else {
      node.pos = pos;
      if (isCollapsed) node.flags.collapsed = true;
      graph.add(node);
      node._odcFold = null;
    }
  }

  // Edge connect that tunnels through fold IO: an edge into or out of a
  // folded node becomes member <-> subgraph slot <-> proxy slot <-> the
  // other side. `data` is stamped on every created link segment so the
  // unlink menu works on either side of the boundary.
  function connectCross(s, oi, d, ii, data) {
    // The hover tooltip prints data.toToolTip() when present - give the
    // edge record a readable label instead of "[Object]".
    if (data && typeof data === "object" && !data.toToolTip) {
      data.toToolTip = function () {
        var fl = data.fromAttr ? (s._odcTitle || s.title || data.from) +
                                 "." + data.fromAttr
                               : (data.from || s.title || "?");
        var tl = data.toAttr ? (d._odcTitle || d.title || data.to) +
                               "." + data.toAttr
                             : (data.to || d.title || "?");
        return fl + " -> " + tl;
      };
    }
    var fs = s._odcFold, fd = d._odcFold;
    if (fs === fd) {
      var l0 = s.connect(oi, d, ii);
      if (l0) l0.data = data;
      return l0;
    }
    var outNode = s, outSlot = oi;
    if (fs) {
      var okey = (s._odc.name || s.id) + "@" + oi;
      if (fs.outMap[okey] == null) {
        var oname = s.outputs[oi] && s.outputs[oi].name;
        var so = fs.sub.addOutput(
          oname && oname !== "out" ? (s._odc.name + "." + oname)
                                   : (s._odc.name || "out"), "*");
        var lo = so.connect(s.outputs[oi], s);
        if (lo) lo.data = data;
        fs.outMap[okey] = fs.sub.outputs.length - 1;
      }
      outNode = fs.proxy;
      outSlot = fs.outMap[okey];
    }
    if (fd) {
      var ikey = (d._odc.name || d.id) + "@" + ii;
      if (fd.inMap[ikey] == null) {
        var iname = d.inputs[ii] && d.inputs[ii].name;
        var si = fd.sub.addInput(
          iname && iname !== "deps" ? (d._odc.name + "." + iname)
                                    : (d._odc.name || "in"), "*");
        var li = si.connect(d.inputs[ii], d);
        if (li) li.data = data;
        fd.inMap[ikey] = fd.sub.inputs.length - 1;
      }
      var lp = outNode.connect(outSlot, fd.proxy, fd.inMap[ikey]);
      if (lp) lp.data = data;
      return lp;
    }
    var lr = outNode.connect(outSlot, d, ii);
    if (lr) lr.data = data;
    return lr;
  }

  // After edges ran, size proxies to their mirrored slots and park the
  // interior IO docks beside the member layout (same trick as buildSub).
  function finalizeFolds(plan, collapsedMap) {
    plan.list.forEach(function (fc) {
      if (collapsedMap && collapsedMap["fold:" + fc.fid]) {
        fc.proxy.flags.collapsed = true;
      }
      fc.proxy.setSize(fc.proxy.computeSize());
      var minX = Infinity, maxX = -Infinity, y = 60;
      (fc.sub._nodes || []).forEach(function (n) {
        minX = Math.min(minX, n.pos[0]);
        maxX = Math.max(maxX, n.pos[0] + n.size[0]);
        y = Math.min(y, n.pos[1]);
      });
      if (!isFinite(minX)) { minX = 0; maxX = 160; }
      fc.sub.inputNode.pos = [minX - 180, y];
      fc.sub.outputNode.pos = [maxX + 60, y];
      fc.sub.inputNode.arrange();
      fc.sub.outputNode.arrange();
    });
  }

  // Nodes eligible for folding: real data nodes at root (not proxies,
  // not nodes already inside a fold).
  function foldSelection() {
    var sel = canvas.selected_nodes || {};
    var nodes = Object.keys(sel).map(function (id) { return sel[id]; })
      .filter(function (n) {
        return n._odc && n._odc.kind !== "fold" && !n._odcFold;
      });
    if (!nodes.length) {
      toast("Select nodes to fold first", true);
      return;
    }
    var lay = layoutFor(cur.entityId);
    lay.folds = lay.folds || {};
    var fid = "fold_" + Date.now().toString(36);
    var members = {}, innerPos = {}, cx = 0, cy = 0;
    nodes.forEach(function (n) {
      members[n._odc.name] = true;
      innerPos[n._odc.name] = [n.pos[0], n.pos[1]];
      cx += n.pos[0]; cy += n.pos[1];
    });
    var k = nodes.length;
    lay.folds[fid] = { title: "Subgraph",
                       pos: [cx / k - 60, cy / k - 20],
                       members: members, innerPos: innerPos };
    window.renderGraph(cur);
    sendLayoutSoon();
  }

  // Return members to the root canvas at their interior positions.
  function unfold(fid) {
    var lay = layoutFor(cur.entityId);
    var fd = (lay.folds || {})[fid];
    if (!fd) return;
    Object.keys(fd.members || {}).forEach(function (m) {
      var p = (fd.innerPos || {})[m];
      if (p) lay.positions[m] = p;
      if (fd.innerCollapsed && fd.innerCollapsed[m]) {
        lay.collapsed = lay.collapsed || {};
        lay.collapsed[m] = true;
      }
    });
    delete lay.folds[fid];
    window.renderGraph(cur);
    sendLayoutSoon();
  }

  function foldableCount() {
    var sel = canvas.selected_nodes || {};
    return Object.keys(sel).filter(function (id) {
      var n = sel[id];
      return n._odc && n._odc.kind !== "fold" && !n._odcFold;
    }).length;
  }

  // Scene node slot visibility: compact shows customs + participating
  // builtins; the toggle expands a node to its full attribute set.
  function toggleShowAll(eid) {
    var lay = layoutFor(cur.entityId);
    lay.showAll = lay.showAll || {};
    if (lay.showAll[eid]) delete lay.showAll[eid];
    else lay.showAll[eid] = true;
    window.renderGraph(cur);
    sendLayoutSoon();
  }

  // Columns by dependency level (deps left, dependents right), rows
  // stacked by estimated node height. Nodes the user has placed keep
  // their stored position; only unseen nodes get the auto slot.
  function buildTop(graph, g) {
    var cols = {};
    var lay = cur && cur.entityId && layoutByEnt[cur.entityId];
    var stored = (lay && lay.positions) || {};
    var collapsed = (lay && lay.collapsed) || {};
    (g.nodes || []).forEach(function (n) {
      var l = n.external || n.virtual ? 0 : (n.level || 0);
      (cols[l] = cols[l] || []).push(n);
    });
    var lvls = Object.keys(cols).map(Number).sort(function (a, b) {
      return a - b;
    });
    var idMap = {};
    var plan = foldPlan(graph);
    lvls.forEach(function (lv, ci) {
      var y = 50;
      cols[lv].forEach(function (d) {
        var node = makeTopNode(d);
        var alias = lay && lay.titles && lay.titles[d.id];
        if (alias) node.title = alias;
        var sz = node.computeSize();
        node.setSize(sz);
        var pos = stored[d.id] ? stored[d.id].slice(0, 2)
                               : [60 + ci * 280, y];
        addGraphNode(plan, graph, node, d, pos, !!collapsed[d.id]);
        y += sz[1] + 30;
        idMap[d.id] = node;
      });
    });
    (g.edges || []).forEach(function (e) {
      var s = idMap[e.from], d = idMap[e.to];
      if (!s || !d) return;
      var inIdx = inputIndexFor(d, e.from);
      if (inIdx < 0) return;
      connectCross(s, 0, d, inIdx, { from: e.from, to: e.to });
    });
    finalizeFolds(plan, collapsed);
    buildStencils(graph, g, idMap);
  }

  // ---- canvas wiring ------------------------------------------------------
  function linkMenu(segment, e) {
    // Formula subgraphs rewrite their doc, not formulas - fold subgraphs
    // fall through to the normal root unlink paths.
    if (canvas.subgraph && !canvas.subgraph._odcFold) {
      var sub = canvas.subgraph;
      new LiteGraph.ContextMenu(
        [{ content: "Remove link",
           callback: function () {
             sub.removeLink(segment.id);
             requestSubPreview();
           } },
         null, "Cancel"], { event: e, callback: function () {} });
      return false;
    }
    var d = (segment && segment.data) || {};
    var items = [];
    if (d.applied) {
      // Stencil-applied binding - the formula is the stencil's whole
      // doc, not a single ref, so detach just drops the live link.
      items.push({ content: "Detach stencil (keep formula)",
        callback: function () {
          var vid = String(d.from).replace("stencil:", "");
          var lay2 = layoutFor(cur.entityId);
          if (lay2.stencils && lay2.stencils[vid]) {
            lay2.stencils[vid].appliedTo = null;
          }
          window.renderGraph(cur);
          sendLayoutSoon();
        } });
      items.push(null);
    } else if (cur.scene && d.to) {
      items.push({ content: "Unlink (replace ref with literal)",
        callback: function () { unlinkSceneEdge(d); } });
      items.push(null);
    } else if (d.from) {
      items.push({ content: "Unlink (replace refs with literal)",
        callback: function () { unlinkEdge(d.from, d.to); } });
      items.push(null);
    }
    items.push("Cancel");
    new LiteGraph.ContextMenu(items, { event: e, callback: function () {} });
    return false;
  }

  // Rewire tracking: grabbing a connected end fires before-move-* with
  // the original LLink. The old target keeps its formula unless we
  // unlink it, so an input-end move off slot z onto slot x would leave
  // z wired - the edge "jumps back" on rebuild. Unlinking substitutes
  // the ref with its literal, same as the context menu.
  var pendingMove = null;

  function captureMove(side) {
    return function (ev) {
      pendingMove = null;
      if (building) return;
      var l = ev.detail && ev.detail.link;
      if (!l) return;
      var g = canvas.subgraph || rootGraph;
      var sn = g.getNodeById(l.origin_id), dn = g.getNodeById(l.target_id);
      if (!sn || !dn || !sn._odc || !dn._odc) return;
      // Only formula-backed targets are unlinkable (entities at scene
      // level, params + formula-subgraph nodes on a dep graph) -
      // stencil/fold proxy ends have no formula to substitute into.
      var ok = cur.scene ? dn._odc.kind === "ent" || dn._odc.kind === "pseudo"
                         : dn._odc.kind !== "vx" && dn._odc.kind !== "fold";
      if (!ok) return;
      pendingMove = { side: side, sn: sn, dn: dn,
                      originSlot: l.origin_slot, targetSlot: l.target_slot };
    };
  }

  function unlinkDetached(pm) {
    if (cur.scene) {
      var on = (pm.sn.outputs || [])[pm.originSlot],
          io = (pm.dn.inputs || [])[pm.targetSlot];
      if (!on || !io) return;
      var eid = pm.dn._odc.eid;
      var refId = pm.sn._odc.kind === "pseudo" ? "global!" + on.name
                                               : pm.sn._odc.dcname + "!" + on.name;
      var edge = (cur.graph.edges || []).find(function (e) {
        return e.to === eid && e.toAttr === io.name;
      });
      unlinkSceneEdge({ to: eid, toAttr: io.name, refId: refId,
                        literal: (edge && edge.literal) || "0" });
    } else {
      unlinkEdge(pm.sn._odc.name, pm.dn._odc.name);
    }
  }

  // A user-drawn link is only an intent: the real edge set is owned by
  // Ruby. Remove it and send the wire op; the pushed re-render shows
  // the result. The fork dispatches link-created on the canvas's
  // linkConnector (one object for root and subgraph drags) - nothing
  // ever lands on LGraph#events, so listen once at canvas level.
  function wireLinkEvents() {
    canvas.linkConnector.events.addEventListener("before-move-input",
      captureMove("input"));
    canvas.linkConnector.events.addEventListener("before-move-output",
      captureMove("output"));
    // A move that lands without a new link = drag-away disconnect.
    canvas.linkConnector.events.addEventListener("after-drop-links",
      function () {
        if (!pendingMove) return;
        var pm = pendingMove;
        pendingMove = null;
        unlinkDetached(pm);
      });
    canvas.linkConnector.events.addEventListener("link-created",
      function (ev) {
        if (building) return;
        if (canvas.subgraph) {
          if (!canvas.subgraph._odcFold) {
            requestSubPreview();
            return;
          }
          // Inside a fold: same wire semantics as root, but nodes live
          // in the fold's subgraph. Links to the IO docks are managed
          // by the rebuild - drawn links to them just vanish.
          var flink = ev.detail;
          var fs = canvas.subgraph.getNodeById(flink.origin_id),
              fd = canvas.subgraph.getNodeById(flink.target_id);
          try { canvas.subgraph.removeLink(flink.id); }
          catch (e) { /* gone */ }
          if (!fs || !fd || !fs._odc || !fd._odc) return;
          if (cur.scene) {
            var fo = (fs.outputs || [])[flink.origin_slot],
                fi = (fd.inputs || [])[flink.target_slot];
            if (fo && fi) {
              wireEntity(fs._odc.eid, fo.name, fd._odc.eid, fi.name);
            }
            return;
          }
          var ffrom = fs._odc.name, fto = fd._odc.name;
          if (ffrom && fto) wire(ffrom, fto);
          return;
        }
        var link = ev.detail;
        var s = rootGraph.getNodeById(link.origin_id),
            d = rootGraph.getNodeById(link.target_id);
        try { rootGraph.removeLink(link.id); } catch (e) { /* gone */ }
        if (!s || !d || !s._odc || !d._odc) return;
        // Stencil source: apply its doc as the target's formula.
        if (s._odc.kind === "vx") {
          var sdoc = docWithLits(subDoc(s.subgraph), litsOf(s));
          if (!sdoc.root) {
            toast("Stencil is empty - double-click to build an " +
                  "expression first", true);
            return;
          }
          if (d._odc.kind === "vx") {
            toast("Can't apply a stencil to another stencil - " +
                  "wire to a parameter", true);
            return;
          }
          if (d._odc.kind === "pseudo" || d._odc.kind === "fold") return;
          var tName = cur.scene
            ? ((d.inputs || [])[link.target_slot] || {}).name
            : d._odc.name;
          if (!tName) return;
          applyStencil(cur.scene ? d._odc.eid : cur.entityId, tName, sdoc,
                     s._odc.vid);
          return;
        }
        // Stencil input target: rename that ref inside the doc.
        if (d._odc.kind === "vx") {
          var slot = (d.inputs || [])[link.target_slot];
          var newRef = stencilRefName(s, link.origin_slot);
          if (!slot || !newRef) {
            toast("Can't name that input - wire an attribute", true);
            return;
          }
          renameStencilRefs(d, slot.name, newRef);
          return;
        }
        if (cur.scene) {
          if (!s._odc || !d._odc) return;
          var o = (s.outputs || [])[link.origin_slot],
              i = (d.inputs || [])[link.target_slot];
          if (!o || !i) return;
          var pm = pendingMove;
          pendingMove = null;
          if (pm && pm.side === "input" &&
              !(pm.dn === d && pm.targetSlot === link.target_slot)) {
            unlinkDetached(pm);
          }
          wireEntity(s._odc.eid, o.name, d._odc.eid, i.name);
          return;
        }
        var from = s._odc && s._odc.name, to = d._odc && d._odc.name;
        if (!from || !to) return;
        if (d.isSubgraphNode && d.isSubgraphNode()) {
          toast("'" + to + "' is a formula - edit via fx or dive in", true);
          return;
        }
        if (pendingMove) {
          var pmt = pendingMove;
          pendingMove = null;
          if (pmt.side === "input" &&
              !(pmt.dn === d && pmt.targetSlot === link.target_slot)) {
            unlinkDetached(pmt);
          }
        }
        wire(from, to);
      });
  }

  // ---- breadcrumb navigation ----------------------------------------
  // One canvas, one nav model: Scene > Entity > subgraph. The trail is
  // derived from cur (the pushed payload) plus canvas.subgraph - no
  // separate stack needed since this fork tracks one subgraph level.

  // Pop the subgraph back to the root graph (entity or scene view).
  function navRoot() {
    var sub = canvas.subgraph;
    canvas.subgraph = null;
    canvas.setGraph(rootGraph);
    updateCrumbs();
    // Interior edits re-apply on close - while inside, a push would
    // have rebuilt the canvas out from under the user.
    if (sub && sub._odcStencil) maybeReapply(sub._odcStencil);
  }

  // Up to the scene view: Ruby rebuilds the scene pending and pushes it
  // back through renderGraph, which resets cur.scene and the crumbs.
  // flushLayout first - a pending debounced save would otherwise fire
  // against the incoming view's entityId.
  function navScene() {
    flushLayout();
    send({ op: "sceneGraph" });
  }

  // Scene node dive -> entity dependency graph (same op path as before).
  function navEntity(eid) {
    flushLayout();
    send({ op: "openEntityGraph", entityId: eid });
  }

  // One level up: subgraph -> root, entity -> scene.
  function navBack() {
    if (canvas.subgraph) navRoot();
    else if (cur && !cur.scene) navScene();
  }

  function updateCrumbs() {
    var sub = canvas && canvas.subgraph;
    var trail = [{ label: "Scene",
      act: cur && cur.scene ? null : navScene }];
    if (cur && !cur.scene) {
      trail.push({ label: cur.label || cur.entityId || "entity",
                   act: sub ? navRoot : null });
    }
    if (sub) trail.push({ label: sub.name || "subgraph", act: null });
    var nav = document.getElementById("gcrumbs");
    nav.textContent = "";
    trail.forEach(function (c, i) {
      if (i) {
        var s = document.createElement("span");
        s.className = "gsep";
        s.textContent = "›";
        nav.appendChild(s);
      }
      var el = document.createElement(c.act ? "a" : "span");
      el.className = c.act ? "gcr" : "gcur";
      el.textContent = c.label;
      if (c.act) el.addEventListener("click", c.act);
      nav.appendChild(el);
    });
    document.getElementById("gback").style.display =
      (sub || (cur && !cur.scene)) ? "" : "none";
    // The formula preview bar only applies to formula subgraphs; a fold
    // subgraph is a container, not an expression canvas.
    document.getElementById("gsubbar").style.display =
      (sub && !sub._odcFold) ? "flex" : "none";
    if (sub) {
      var el = document.getElementById("gsubformula");
      el.textContent = "";
      el.classList.remove("bad");
      // Stencils apply by wiring their output, not the Apply button -
      // the preview still shows the composed formula.
      document.getElementById("gsubapply").style.display =
        sub._odcStencil ? "none" : "";
      document.getElementById("gsubapply").disabled = true;
      requestSubPreview();
    }
    updateSelbox();
  }

  document.getElementById("gsubapply").addEventListener("click", function () {
    var sub = canvas && canvas.subgraph;
    if (sub) send({ op: "applyDoc", entityId: cur.entityId, name: sub.name,
                    doc: subDoc(sub) });
  });

  document.getElementById("gback").addEventListener("click", navBack);

  // ---- canvas chrome: toolbar, selection toolbox, minimap -------------
  // Mostly stock litegraph/ComfyUI features surfaced through our chrome:
  // canvasNavigationMode gives the pan vs marquee-select tool pair,
  // alwaysSnapToGrid draws alignment guides while dragging,
  // dragZoomEnabled gives Ctrl+Shift-drag region zoom, and
  // links_render_mode switches bezier styles. Toolbox + minimap are DOM
  // overlays positioned from ds.offset/ds.scale. Preferences persist in
  // localStorage (UI state, not graph layout - no Ruby round trip).
  var uiPrefs = (function () {
    try { return JSON.parse(localStorage.getItem("odc.graphui")) || {}; }
    catch (e) { return {}; }
  })();
  var LINK_MODES = [["Straight", 0], ["Linear", 1], ["Spline", 2]];
  var miniT = null;        // minimap world->pixel transform {s,ox,oy}
  var findIdx = -1;

  function saveUiPrefs() {
    try { localStorage.setItem("odc.graphui", JSON.stringify(uiPrefs)); }
    catch (e) {}
  }

  function selItems() {
    return Array.from((canvas && canvas.selectedItems) || [])
      .filter(function (it) { return it && it.pos && it.size; });
  }

  // Visual bounds: node boundingRect includes the titlebar (pos sits
  // below it) and groups carry _bounding - plain pos+size would put
  // chrome over the title area.
  function boundsOf(items) {
    var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    items.forEach(function (it) {
      var r = it.boundingRect;
      var l = r ? r.x : (it._bounding ? it._bounding[0] : it.pos[0]);
      var t = r ? r.y : (it._bounding ? it._bounding[1] : it.pos[1]);
      var rr = r ? r.right
                 : (it._bounding ? it._bounding[0] + it._bounding[2]
                                 : it.pos[0] + it.size[0]);
      var bb = r ? r.bottom
                 : (it._bounding ? it._bounding[1] + it._bounding[3]
                                 : it.pos[1] + it.size[1]);
      x0 = Math.min(x0, l); y0 = Math.min(y0, t);
      x1 = Math.max(x1, rr); y1 = Math.max(y1, bb);
    });
    return isFinite(x0) ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : null;
  }

  function graphBounds(pad) {
    var g = canvas && canvas.graph;
    if (!g) return null;
    var items = (g._nodes || []).concat(g._groups || []);
    var b = boundsOf(items.map(function (it) {
      if (it._bounding) {
        return { pos: [it._bounding[0], it._bounding[1]],
                 size: [it._bounding[2], it._bounding[3]] };
      }
      return it;
    }));
    if (!b) return null;
    var p = pad || 0;
    return { x: b.x - p, y: b.y - p, w: b.w + 2 * p, h: b.h + 2 * p };
  }

  // css px = (world + ds.offset) * ds.scale; center world point (wx,wy)
  // by setting offsets so (w+off)*s lands at the css center.
  function centerOn(wx, wy) {
    var dpr = window.devicePixelRatio || 1;
    var s = canvas.ds.scale;
    canvas.ds.offset[0] = canvas.canvas.width / dpr / (2 * s) - wx;
    canvas.ds.offset[1] = canvas.canvas.height / dpr / (2 * s) - wy;
    canvas.setDirty(true, true);
  }

  // F / Fit button: fit the selection when there is one, else the graph.
  function fitView() {
    var b = boundsOf(selItems()) || graphBounds(60);
    if (!b) { toast("Nothing on canvas"); return; }
    var dpr = window.devicePixelRatio || 1;
    var cw = canvas.canvas.width / dpr, ch = canvas.canvas.height / dpr;
    canvas.ds.scale = Math.max(0.08,
      Math.min(cw / b.w, ch / b.h, 1.5));
    canvas.ds.offset[0] = cw / (2 * canvas.ds.scale) - (b.x + b.w / 2);
    canvas.ds.offset[1] = ch / (2 * canvas.ds.scale) - (b.y + b.h / 2);
    canvas.setDirty(true, true);
  }

  // Zoom keeping the world point under the canvas center fixed.
  function zoomBy(f) {
    var dpr = window.devicePixelRatio || 1;
    var cx = canvas.canvas.width / (2 * dpr),
        cy = canvas.canvas.height / (2 * dpr);
    var wx = cx / canvas.ds.scale - canvas.ds.offset[0];
    var wy = cy / canvas.ds.scale - canvas.ds.offset[1];
    var s = Math.max(0.08, Math.min(4, canvas.ds.scale * f));
    canvas.ds.scale = s;
    canvas.ds.offset[0] = cx / s - wx;
    canvas.ds.offset[1] = cy / s - wy;
    canvas.setDirty(true, true);
  }

  function setNavMode(select) {
    uiPrefs.select = select;
    // standard: drag = marquee, Space/middle-drag pans, wheel scrolls,
    // Ctrl+wheel zooms. legacy: drag pans, Ctrl+drag marquees.
    LiteGraph.canvasNavigationMode = select ? "standard" : "legacy";
    document.getElementById("gtpan").classList.toggle("on", !select);
    document.getElementById("gtsel").classList.toggle("on", select);
    saveUiPrefs();
  }

  function setSnap(on) {
    uiPrefs.snap = on;
    LiteGraph.alwaysSnapToGrid = on;
    document.getElementById("gtsnap").classList.toggle("on", on);
    saveUiPrefs();
  }

  function setLinkStyle(i) {
    uiPrefs.linki = i;
    var m = LINK_MODES[i];
    document.getElementById("gtlink").textContent = m[0];
    // LinkRenderType isn't exported from the umd - values are
    // STRAIGHT=0, LINEAR=1, SPLINE=2 (enum order in the source).
    if (canvas) {
      canvas.links_render_mode = m[1];
      canvas.setDirty(true, true);
    }
    saveUiPrefs();
  }

  function setMinimap(on) {
    uiPrefs.minimap = on;
    document.getElementById("gtmap").classList.toggle("on", on);
    document.getElementById("gmini").style.display = on ? "block" : "none";
    if (on) drawMinimap();
    saveUiPrefs();
  }

  function drawMinimap() {
    if (!uiPrefs.minimap || !canvas || !canvas.ds) return;
    var mini = document.getElementById("gmini");
    var W = mini.clientWidth || 180, H = mini.clientHeight || 120;
    var dpr = window.devicePixelRatio || 1;
    if (mini.width !== (W * dpr | 0)) {
      mini.width = W * dpr; mini.height = H * dpr;
    }
    var ctx = mini.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    var b = graphBounds(30);
    if (!b) { miniT = null; return; }
    var pad = 5;
    var s = Math.min((W - 2 * pad) / b.w, (H - 2 * pad) / b.h);
    var ox = pad + (W - 2 * pad - b.w * s) / 2 - b.x * s;
    var oy = pad + (H - 2 * pad - b.h * s) / 2 - b.y * s;
    miniT = { s: s, ox: ox, oy: oy };
    var g = canvas.graph;
    var dim = cssVar("--dim"), acc = cssVar("--accent");
    (g._groups || []).forEach(function (gr) {
      var gb = gr._bounding;
      if (!gb) return;
      ctx.globalAlpha = 0.25;
      ctx.fillStyle = gr.color || dim;
      ctx.fillRect(gb[0] * s + ox, gb[1] * s + oy, gb[2] * s, gb[3] * s);
      ctx.globalAlpha = 1;
    });
    (g._nodes || []).forEach(function (n) {
      ctx.fillStyle = n.selected ? acc : dim;
      ctx.fillRect(n.pos[0] * s + ox, n.pos[1] * s + oy,
                   Math.max(n.size[0] * s, 2), Math.max(n.size[1] * s, 2));
    });
    ctx.strokeStyle = acc;
    ctx.lineWidth = 1;
    ctx.strokeRect(-canvas.ds.offset[0] * s + ox,
                   -canvas.ds.offset[1] * s + oy,
                   canvas.canvas.width / dpr / canvas.ds.scale * s,
                   canvas.canvas.height / dpr / canvas.ds.scale * s);
  }

  function miniJump(e) {
    if (!miniT || !canvas) return;
    var r = document.getElementById("gmini").getBoundingClientRect();
    centerOn((e.clientX - r.left - miniT.ox) / miniT.s,
             (e.clientY - r.top - miniT.oy) / miniT.s);
  }

  // ---- selection toolbox -------------------------------------------
  // Inline SVG glyphs swapped per selection state (collapse/expand,
  // fold count) - static buttons keep their markup in index.html.
  var ICO = {
    collapse: '<svg viewBox="0 0 24 24"><path d="M9 4v5H4M15 4v5h5' +
              'M9 20v-5H4M15 20v-5h5"/></svg>',
    expand: '<svg viewBox="0 0 24 24"><path d="M4 9V4h5M20 9V4h-5' +
            'M4 15v5h5M20 15v5h-5"/></svg>',
    fold: '<svg viewBox="0 0 24 24"><path d="M12 3l8 4.5v9L12 21' +
          'l-8-4.5v-9zM4 7.5l8 4.5 8-4.5M12 12v9"/></svg>'
  };

  function updateSelbox() {
    var box = document.getElementById("gselbox");
    if (!canvas || building || !rootGraph) {
      box.style.display = "none"; return;
    }
    var items = selItems();
    if (!items.length) { box.style.display = "none"; return; }
    var b = boundsOf(items);
    var dpr = window.devicePixelRatio || 1;
    var sx = (b.x + b.w / 2 + canvas.ds.offset[0]) * canvas.ds.scale / dpr;
    var sy = (b.y + canvas.ds.offset[1]) * canvas.ds.scale / dpr;
    box.style.display = "flex";
    var bw = box.offsetWidth || 200, bh = box.offsetHeight || 30;
    var top = sy - bh - 10;
    if (top < 44) { // above the header? float below the selection instead
      top = (b.y + b.h + canvas.ds.offset[1]) * canvas.ds.scale / dpr + 10;
    }
    box.style.left = Math.max(6,
      Math.min(window.innerWidth - bw - 6, sx - bw / 2)) + "px";
    box.style.top = top + "px";
    var inSub = !!canvas.subgraph;
    var nodes = items.filter(function (it) {
      return it instanceof lg.LGraphNode;
    });
    var anyOpen = nodes.some(function (n) {
      return !(n.flags && n.flags.collapsed);
    });
    document.getElementById("gsbcol").innerHTML =
      anyOpen ? ICO.collapse : ICO.expand;
    document.getElementById("gsbcol").title =
      anyOpen ? "Collapse selected nodes" : "Expand selected nodes";
    document.getElementById("gsbcol").style.display =
      nodes.length ? "" : "none";
    document.getElementById("gsbalign").style.display =
      nodes.length > 1 ? "" : "none";
    var fc = inSub ? 0 : foldableCount();
    var fb = document.getElementById("gsbfold");
    fb.style.display = fc ? "" : "none";
    fb.innerHTML = ICO.fold + fc;
    fb.title = "Fold " + fc + " selected node" +
               (fc === 1 ? "" : "s") + " into a subgraph";
    var hasProxy = items.some(function (it) {
      return it._odc && it._odc.kind === "fold";
    });
    document.getElementById("gsbunfold").style.display =
      hasProxy ? "" : "none";
    // Highlight the active swatch when a single node carries a color.
    var opt = nodes.length === 1 && nodes[0].getColorOption ?
              nodes[0].getColorOption() : null;
    var curKey = null;
    if (opt) {
      var ncs = lg.LGraphCanvas.node_colors;
      curKey = Object.keys(ncs).filter(function (k) {
        return ncs[k] === opt;
      })[0] || null;
    }
    [].forEach.call(
      document.querySelectorAll("#gsbcolors .gsw"),
      function (d) {
        d.classList.toggle("cur",
          !!(curKey && d.dataset.color === curKey));
      });
  }

  function collapseAll(force) {
    selItems().forEach(function (it) {
      if (it instanceof lg.LGraphNode &&
          !!(it.flags && it.flags.collapsed) !== force) {
        it.collapse();
      }
    });
  }

  // Toolbox label says "Collapse" while any selected node is open -
  // clicking drives every selected node to the target state.
  function collapseSel() {
    collapseAll(selItems().some(function (it) {
      return it instanceof lg.LGraphNode &&
             !(it.flags && it.flags.collapsed);
    }));
  }

  // Build the ComfyUI-style swatch row from the palette the lib ships.
  function buildSwatches() {
    var row = document.getElementById("gsbcolors");
    var none = document.createElement("div");
    none.className = "gsw none";
    none.title = "No color (default)";
    none.addEventListener("click", function () { colorSel(null); });
    row.appendChild(none);
    Object.keys(lg.LGraphCanvas.node_colors).forEach(function (key) {
      var opt = lg.LGraphCanvas.node_colors[key];
      var d = document.createElement("div");
      d.className = "gsw";
      d.dataset.color = key;
      d.title = key;
      d.style.background = opt.bgcolor;
      d.addEventListener("click", function () { colorSel(key); });
      row.appendChild(d);
    });
  }

  // Color is an alias like titles: preset name persists in lay.colors
  // keyed on _odc.name; groups carry their own color in the group record.
  function colorSel(key) {
    var lay = layoutFor(cur.entityId);
    lay.colors = lay.colors || {};
    selItems().forEach(function (it) {
      if (!it.setColorOption) return;
      it.setColorOption(key ? lg.LGraphCanvas.node_colors[key] : null);
      if (it instanceof lg.LGraphGroup) return; // gd.color round-trips
      if (!it._odc || !it._odc.name) return;
      if (key) lay.colors[it._odc.name] = key;
      else delete lay.colors[it._odc.name];
    });
    canvas.setDirty(true, true);
    sendLayoutSoon();
    updateSelbox();
  }

  // "i" - surface the real data identity behind the display title.
  function infoSel() {
    var n = selItems().filter(function (it) {
      return it instanceof lg.LGraphNode;
    })[0];
    if (!n) { toast("Select a node first", true); return; }
    var o = n._odc || {};
    var parts = [o.name || n.title];
    if (o.dcname) parts.push("scope " + o.dcname + "!");
    if (o.kind) parts.push(o.kind);
    var slots = (n.inputs || []).length + (n.outputs || []).length;
    if (slots) parts.push(slots + " slots");
    toast(parts.join("  ·  "));
  }

  // "..." - the node's own menu for single selection, plus shared ops.
  function moreMenu(e) {
    var items = [];
    var nodes = selItems().filter(function (it) {
      return it instanceof lg.LGraphNode;
    });
    if (nodes.length === 1) {
      items = odcMenu(nodes[0]).concat([null]);
    }
    if (!canvas.subgraph) {
      items.push({ content: "Group around selection",
                   callback: groupSel });
    }
    items.push(
      { content: "Collapse all",
        callback: function () { collapseAll(true); } },
      { content: "Expand all",
        callback: function () { collapseAll(false); } });
    new LiteGraph.ContextMenu(items, { event: e,
      callback: function () {} });
  }

  function alignSel(mode) {
    var nodes = selItems().filter(function (it) {
      return it instanceof lg.LGraphNode;
    });
    if (nodes.length < 2) { toast("Select 2+ nodes to align", true); return; }
    var b = boundsOf(nodes);
    if (mode === "h" || mode === "v") {
      var ax = mode === "h" ? 0 : 1;
      nodes.sort(function (p, q) { return p.pos[ax] - q.pos[ax]; });
      var span = ax === 0 ? b.w : b.h;
      var total = nodes.reduce(function (t, n) {
        return t + n.size[ax];
      }, 0);
      var gap = Math.max(0, (span - total) / (nodes.length - 1));
      var p = ax === 0 ? b.x : b.y;
      nodes.forEach(function (n) {
        n.pos[ax] = p;
        p += n.size[ax] + gap;
      });
    } else {
      nodes.forEach(function (n) {
        if (mode === "l") n.pos[0] = b.x;
        if (mode === "r") n.pos[0] = b.x + b.w - n.size[0];
        if (mode === "t") n.pos[1] = b.y;
        if (mode === "b") n.pos[1] = b.y + b.h - n.size[1];
      });
    }
    canvas.setDirty(true, true);
    sendLayoutSoon();
  }

  // Wrap the selection in a group box - same persistence path as
  // "Add group": harvest picks it up and Ruby stores it.
  function groupSel() {
    var b = boundsOf(selItems());
    if (!b) { toast("Select items to group", true); return; }
    var grp = new lg.LGraphGroup("Group");
    grp.pos = [b.x - 30, b.y - 46];
    grp.size = [b.w + 60, b.h + 76];
    rootGraph.add(grp);
    grp.recomputeInsideNodes();
    canvas.setDirty(true, true);
    sendLayoutSoon();
  }

  function unfoldSel() {
    selItems().forEach(function (it) {
      if (it._odc && it._odc.kind === "fold") unfold(it._odc.fid);
    });
  }

  function findNext() {
    var q = document.getElementById("gfind").value.trim().toLowerCase();
    if (!q || !canvas) return;
    var g = canvas.graph || rootGraph;
    var hits = (g._nodes || []).filter(function (n) {
      var t = (n.title || "") + " " +
              ((n._odc && n._odc.name) || "");
      return t.toLowerCase().indexOf(q) >= 0;
    }).sort(function (a, b2) {
      return (a.title || "").localeCompare(b2.title || "");
    });
    if (!hits.length) {
      toast("No node matches \"" + q + "\"", true); return;
    }
    findIdx = (findIdx + 1) % hits.length;
    var n = hits[findIdx];
    canvas.deselectAll();
    canvas.selectNodes([n]);
    canvas.centerOnNode(n);
    toast((findIdx + 1) + "/" + hits.length + ": " + (n.title || q));
  }

  function wireChrome() {
    document.getElementById("gtpan").addEventListener("click",
      function () { setNavMode(false); });
    document.getElementById("gtsel").addEventListener("click",
      function () { setNavMode(true); });
    document.getElementById("gtzin").addEventListener("click",
      function () { zoomBy(1.25); });
    document.getElementById("gtzout").addEventListener("click",
      function () { zoomBy(0.8); });
    document.getElementById("gtfit").addEventListener("click", fitView);
    document.getElementById("gtsnap").addEventListener("click",
      function () { setSnap(!uiPrefs.snap); });
    document.getElementById("gtlink").addEventListener("click",
      function () { setLinkStyle(((uiPrefs.linki || 0) + 1) % 3); });
    document.getElementById("gtmap").addEventListener("click",
      function () { setMinimap(!uiPrefs.minimap); });
    var findEl = document.getElementById("gfind");
    findEl.addEventListener("input", function () { findIdx = -1; });
    findEl.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { findNext(); e.preventDefault(); }
      if (e.key === "Escape") findEl.blur();
    });
    document.getElementById("gsbcol").addEventListener("click",
      collapseSel);
    document.getElementById("gsbalign").addEventListener("click",
      function (e) {
        var opts = [
          { content: "Align left",   callback: function () { alignSel("l"); } },
          { content: "Align right",  callback: function () { alignSel("r"); } },
          { content: "Align top",    callback: function () { alignSel("t"); } },
          { content: "Align bottom", callback: function () { alignSel("b"); } },
          null,
          { content: "Distribute horizontally",
            callback: function () { alignSel("h"); } },
          { content: "Distribute vertically",
            callback: function () { alignSel("v"); } }];
        new LiteGraph.ContextMenu(opts, { event: e,
          callback: function () {} });
      });
    document.getElementById("gsbfold").addEventListener("click",
      foldSelection);
    document.getElementById("gsbunfold").addEventListener("click",
      unfoldSel);
    document.getElementById("gsbinfo").addEventListener("click",
      infoSel);
    document.getElementById("gsbcolor").addEventListener("click",
      function (e) {
        e.currentTarget.classList.toggle("on");
        document.getElementById("gsbcolors").classList.toggle("show");
      });
    document.getElementById("gsbmore").addEventListener("click",
      moreMenu);
    document.getElementById("gsbdel").addEventListener("click",
      function () { canvas.deleteSelected(); });
    buildSwatches();
    // Minimap: click or drag to move the viewport.
    var mini = document.getElementById("gmini"), dragging = false;
    mini.addEventListener("pointerdown", function (e) {
      dragging = true;
      mini.setPointerCapture(e.pointerId);
      miniJump(e);
    });
    mini.addEventListener("pointermove", function (e) {
      if (dragging) miniJump(e);
    });
    mini.addEventListener("pointerup", function () { dragging = false; });
    document.addEventListener("keydown", function (e) {
      if (e.target && /^(input|textarea|select)$/i
            .test(e.target.localName || "")) return;
      if (e.ctrlKey || e.metaKey || e.altKey || !canvas) return;
      var k = e.key.toLowerCase();
      if (k === "f") { fitView(); e.preventDefault(); }
      else if (k === "v") setNavMode(true);
      else if (k === "h") setNavMode(false);
      else if (k === "m") setMinimap(!uiPrefs.minimap);
      else if (k === "g" && !canvas.subgraph) addGroup();
    });
  }

  // Reflect saved prefs in the chrome; canvas-level prefs applied in
  // ensureCanvas once the canvas exists.
  function refreshChrome() {
    setNavMode(!!uiPrefs.select);
    setSnap(!!uiPrefs.snap);
    setLinkStyle(uiPrefs.linki != null ? uiPrefs.linki : 2);
    setMinimap(!!uiPrefs.minimap);
  }

  function ensureCanvas() {
    if (canvas) return;
    var el = document.getElementById("lgcanvas");
    canvas = new lg.LGraphCanvas(el, new lg.LGraph());
    canvas.clear_background = true;
    canvas.clear_background_color = cssVar("--bg");
    canvas.allow_searchbox = false;
    // Legacy: strokes the canvas pixel bounds in graph space (#235) -
    // shows as a stray blue frame whenever the view is offset.
    canvas.render_canvas_border = false;
    // Centre arrow markers use _centreAngle (verified forward); the
    // render_connection_arrows chevrons read backwards, so leave them off.
    canvas.render_connection_arrows = false;
    canvas.linkMarkerShape = lg.LinkMarkerShape.Arrow;
    // Chrome hooks: the overlay draw fires on every canvas repaint, so
    // the toolbox tracks pan/zoom and the minimap stays live for free.
    canvas.dragZoomEnabled = true; // Ctrl+Shift+drag zooms into the box
    canvas.onDrawOverlay = function () {
      updateSelbox();
      drawMinimap();
      document.getElementById("gtzoom").textContent =
        Math.round(canvas.ds.scale * 100) + "%";
    };
    // Resize affordance: faint SE grip whenever the pointer sits over a
    // resizable node, bright corner bracket once it enters the grab zone
    // (which findResizeDirection above reports + the cursor already
    // reflects). ctx is in world coords here; sizes scale with zoom.
    canvas.onDrawForeground = function (ctx) {
      var n = canvas.node_over;
      if (!n || n.resizable === false ||
          (n.flags && n.flags.collapsed)) return;
      var b = n.boundingRect;
      if (!b) return;
      var dir = canvas.pointer && canvas.pointer.resizeDirection;
      ctx.save();
      if (dir) {
        var cx = dir.charAt(1) === "E" ? b.right : b.x;
        var cy = dir.charAt(0) === "S" ? b.bottom : b.y;
        var arm = 16 / canvas.ds.scale;
        ctx.strokeStyle = cssVar("--accent");
        ctx.lineWidth = 2 / canvas.ds.scale;
        ctx.beginPath();
        ctx.moveTo(cx + (dir.charAt(1) === "E" ? -arm : arm), cy);
        ctx.lineTo(cx, cy);
        ctx.lineTo(cx, cy + (dir.charAt(0) === "S" ? -arm : arm));
        ctx.stroke();
      } else {
        var g = 12;
        ctx.globalAlpha = 0.45;
        ctx.fillStyle = cssVar("--muted");
        ctx.beginPath();
        ctx.moveTo(b.right, b.bottom);
        ctx.lineTo(b.right - g, b.bottom);
        ctx.lineTo(b.right, b.bottom - g);
        ctx.closePath();
        ctx.fill();
      }
      ctx.restore();
    };
    canvas.getCanvasMenuOptions = function () {
      if (canvas.subgraph) {
        var sub = canvas.subgraph;
        if (sub._odcFold) {
          return [{ content: "Unfold",
            callback: function () { unfold(sub._odcFold); } },
            null, { content: "Back to dependencies",
            callback: navRoot }];
        }
        var items = subMenuItems(sub);
        items.push(null, { content: "Back to dependencies",
          callback: navRoot });
        return items;
      }
      var fc = foldableCount();
      var foldItem = {
        content: "Fold " + fc + " node" + (fc === 1 ? "" : "s") +
                 " into subgraph",
        disabled: fc < 1,
        callback: foldSelection };
      // Same palette as formula subgraphs - picks seed stencil nodes.
      var exprItem = { content: "Expression", has_submenu: true,
        submenu: { options: subMenuItems(null, createStencil) } };
      if (cur && cur.scene) {
        return [exprItem, foldItem,
                { content: "Add group",
          callback: function () { addGroup(); } }];
      }
      return [{ content: "New attribute",
        callback: function () { openNewAttr(); } },
              exprItem, foldItem,
              { content: "Add group",
        callback: function () { addGroup(); } }];
    };
    canvas.showLinkMenu = linkMenu;
    wireLinkEvents(); // once: linkConnector lives on the canvas, not the graph
    canvas.onNodeDblClicked = function (n) {
      // Titlebar double-click renames (display alias); body keeps the
      // open/dive behavior. Collapsed nodes keep opening - their whole
      // visible area is the title, so a title check would swallow it.
      // The left titlebox square is the collapse arrow - not a rename.
      var mx = canvas.graph_mouse && canvas.graph_mouse[0];
      var my = canvas.graph_mouse && canvas.graph_mouse[1];
      if (n._odc && !(n.flags && n.flags.collapsed) &&
          my != null && my < n.pos[1] &&
          (mx == null || mx >= n.pos[0] + LiteGraph.NODE_TITLE_HEIGHT)) {
        openRename(n);
        return;
      }
      // SubgraphNode check first - covers formula nodes and fold proxies
      // in both modes (a scene-mode fold proxy must open, not retarget).
      if (n.isSubgraphNode && n.isSubgraphNode()) {
        canvas.openSubgraph(n.subgraph);
        return;
      }
      if (cur && cur.scene) {
        if (n._odc && n._odc.kind === "ent") navEntity(n._odc.eid);
        return;
      }
      if (n._odc) openFx(n._odc.name);
    };
    // Drag end: remember positions locally (re-render guard) and report
    // them so a reopened dialog can restore the same layout.
    canvas.onNodeMoved = function () { sendLayoutSoon(); };
    // Catch-all for changes that emit no drag event (group rename or
    // recolor through the built-in group menu).
    canvas.onSelectionChange = function () {
      sendLayoutSoon();
      updateSelbox();
    };
    canvas.deleteSelected = function () {
      if (canvas.subgraph) {
        if (canvas.subgraph._odcFold) {
          toast("Nodes are data-owned - unfold to remove the container");
          return;
        }
        var sel = this.selected_nodes || {};
        Object.keys(sel).forEach(function (id) {
          var n = sel[id];
          if (n._odc) canvas.subgraph.remove(n);   // docks have no _odc
        });
        this.setDirty(true, true);
        requestSubPreview();
        return;
      }
      // Nodes are data-owned, but fold proxies and groups are canvas
      // state - Del on a proxy unfolds, Del on a group removes it.
      var items = this.selectedItems ? Array.from(this.selectedItems) : [];
      var canvasOwned = false;
      items.forEach(function (item) {
        if (item._odc && item._odc.kind === "fold") {
          unfold(item._odc.fid);
          canvasOwned = true;
        }
        if (item._odc && item._odc.kind === "vx") {
          removeStencil(item._odc.vid);
          canvasOwned = true;
        }
      });
      if (canvasOwned) return;
      var removed = false;
      items.forEach(function (item) {
        if (item instanceof lg.LGraphGroup) {
          rootGraph.remove(item);
          removed = true;
        }
      });
      if (removed) {
        this.setDirty(true, true);
        sendLayoutSoon();
        return;
      }
      toast("Nodes are data-owned - use fx or the panel to edit");
    };
    el.addEventListener("subgraph-opened", updateCrumbs);
    wireChrome();
    refreshChrome();
    window.addEventListener("resize", function () { canvas.resize(); });
    // resize() reads the parent box in CSS px - correct once dpr is 1.
    requestAnimationFrame(function () { canvas.resize(); });
  }

  // ---- boot -----------------------------------------------------------
  window.renderGraph = function (data) {
    harvestLayout(); // outgoing graph keeps its dragged layout
    cur = data;
    // Ruby-side copy survives a dialog close/reopen; it seeds an entity
    // this page hasn't seen yet - local memory wins thereafter.
    if (!layoutByEnt[data.entityId]) {
      var lay = layoutFor(data.entityId);
      var seed = data.positions || {};
      Object.keys(seed).forEach(function (k) {
        lay.positions[k] = seed[k];
      });
      if (Array.isArray(data.groups)) lay.groups = data.groups;
      if (data.collapsed) lay.collapsed = data.collapsed;
      if (data.folds) lay.folds = data.folds;
      if (data.showAll) lay.showAll = data.showAll;
      if (data.stencils) lay.stencils = data.stencils;
      if (data.titles) lay.titles = data.titles;
      if (data.colors) lay.colors = data.colors;
    }
    document.getElementById("gadd").style.display = data.scene ? "none" : "";
    var empty = !(data.graph && data.graph.nodes && data.graph.nodes.length);
    document.getElementById("gmsg").textContent = data.scene
      ? "No Open DC components at top level - convert one first."
      : "No parameter dependencies.";
    document.getElementById("gmsg").style.display = empty ? "block" : "none";

    if (canvas && canvas.ds) {
      savedView = { scale: canvas.ds.scale,
                    offset: [canvas.ds.offset[0], canvas.ds.offset[1]] };
    }

    // Rebuilds swap every node object - remember the selection by its
    // data key so toolbox work (select, then a formula write triggers a
    // re-render) doesn't lose it mid-gesture.
    var prevSel = {};
    if (canvas) {
      Object.keys(canvas.selected_nodes || {}).forEach(function (id) {
        var n = canvas.selected_nodes[id];
        if (n._odc && n._odc.name) prevSel[n._odc.name] = true;
      });
    }

    building = true;
    pendingMove = null;   // node refs die with the old graph
    applyTheme();
    ensureCanvas();
    rootGraph = new lg.LGraph();
    if (data.scene) {
      buildScene(rootGraph, data.graph || { nodes: [], edges: [] });
    } else {
      buildTop(rootGraph, data.graph || { nodes: [], edges: [] });
    }
    restoreGroups(rootGraph);
    canvas.subgraph = null;
    canvas.setGraph(rootGraph);
    building = false;

    if (Object.keys(prevSel).length) {
      var re = (rootGraph._nodes || []).filter(function (n) {
        return n._odc && prevSel[n._odc.name];
      });
      if (re.length) canvas.selectNodes(re);
    }

    // Keep pan/zoom across re-renders of the same entity; a retargeted
    // window (selection changed) starts at the default framing instead.
    if (savedView && !empty && data.entityId === lastEntityId) {
      canvas.ds.scale = savedView.scale;
      canvas.ds.offset[0] = savedView.offset[0];
      canvas.ds.offset[1] = savedView.offset[1];
      canvas.setDirty(true, true);
    }
    lastEntityId = data.entityId;
    updateCrumbs();
  };

  // Debug/dev hook (same role as __dbg in the nodes editor).
  window.__odc = function () {
    return { canvas: canvas, root: rootGraph, kit: kit,
             subDoc: subDoc, payload: function () { return cur; },
             current: canvas && canvas.graph };
  };

  if (window.sketchup && sketchup.gready) sketchup.gready("");
})();
