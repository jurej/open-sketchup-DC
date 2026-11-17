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

  // Async feedback for ops without a graph re-push: {error|msg} toasts;
  // {ok,formula|errors,applied} updates the subgraph preview/apply bar.
  window.onGraphStatus = function (r) {
    if (r.ok !== undefined) return setSubStatus(r);
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

  function odcMenu(n) {
    var o = n._odc || {};
    if (o.kind === "sub") return [
      { content: "Open formula graph",
        callback: function () { canvas.openSubgraph(n.subgraph); } },
      { content: "Edit formula (fx)",
        callback: function () { openFx(o.name); } }
    ];
    if (o.kind === "param") return [
      { content: "Open formula canvas",
        callback: function () { openFx(o.name); } }
    ];
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
    sub.onNodeAdded = function () { requestSubPreview(); };
    sub.onNodeRemoved = function () { requestSubPreview(); };
    sub.events.addEventListener("link-created", function () {
      if (building) return;
      requestSubPreview();
    });
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
    if (!sub || building) return;
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
  // top-level node ids when absent.
  function subMenuItems(sub) {
    var pal = cur.palette || {};
    var attrs = pal.attrs || (cur.graph.nodes || [])
      .filter(function (n) { return !n.external && !n.virtual; })
      .map(function (n) { return n.id; });
    function sub2(name, opts) {
      return { content: name, has_submenu: true, submenu: { options: opts } };
    }
    function addItem(type, v, extra) {
      return {
        content: String(v === "" ? "(empty text)" : v),
        callback: function () {
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
    if (String(sub.name || "").toLowerCase() === "onclick"
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
    sn.setSize(sn.computeSize());
    if (d.cyclic) sn.boxcolor = cssVar("--error");
    return sn;
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

  // Columns by dependency level (deps left, dependents right), rows
  // stacked by estimated node height.
  function buildTop(graph, g) {
    var cols = {};
    (g.nodes || []).forEach(function (n) {
      var l = n.external || n.virtual ? 0 : (n.level || 0);
      (cols[l] = cols[l] || []).push(n);
    });
    var lvls = Object.keys(cols).map(Number).sort(function (a, b) {
      return a - b;
    });
    var idMap = {};
    lvls.forEach(function (lv, ci) {
      var y = 50;
      cols[lv].forEach(function (d) {
        var node = makeTopNode(d);
        var sz = node.computeSize();
        node.setSize(sz);
        node.pos = [60 + ci * 280, y];
        graph.add(node);
        y += sz[1] + 30;
        idMap[d.id] = node;
      });
    });
    (g.edges || []).forEach(function (e) {
      var s = idMap[e.from], d = idMap[e.to];
      if (!s || !d) return;
      var inIdx = inputIndexFor(d, e.from);
      if (inIdx < 0) return;
      var link = s.connect(0, d, inIdx);
      if (link) link.data = { from: e.from, to: e.to };
    });
  }

  // ---- canvas wiring ------------------------------------------------------
  function linkMenu(segment, e) {
    if (canvas.subgraph) {
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
    if (d.from) {
      items.push({ content: "Unlink (replace refs with literal)",
        callback: function () { unlinkEdge(d.from, d.to); } });
      items.push(null);
    }
    items.push("Cancel");
    new LiteGraph.ContextMenu(items, { event: e, callback: function () {} });
    return false;
  }

  function wireLinkEvents() {
    // A user-drawn link is only an intent: the real edge set is owned by
    // Ruby. Remove it and send the wire op; the pushed re-render shows
    // the result.
    rootGraph.events.addEventListener("link-created", function (ev) {
      if (building) return;
      var link = ev.detail;
      var s = rootGraph.getNodeById(link.origin_id),
          d = rootGraph.getNodeById(link.target_id);
      try { rootGraph.removeLink(link.id); } catch (e) { /* gone */ }
      if (!s || !d) return;
      var from = s._odc && s._odc.name, to = d._odc && d._odc.name;
      if (!from || !to) return;
      if (d.isSubgraphNode && d.isSubgraphNode()) {
        toast("'" + to + "' is a formula - edit via fx or dive in", true);
        return;
      }
      wire(from, to);
    });
  }

  function updateCrumbs() {
    var sub = canvas && canvas.subgraph;
    document.getElementById("gback").style.display = sub ? "" : "none";
    document.getElementById("gcrumb").textContent =
      sub ? ("‹ " + sub.name) : "";
    document.getElementById("gsubbar").style.display = sub ? "flex" : "none";
    if (sub) {
      var el = document.getElementById("gsubformula");
      el.textContent = "";
      el.classList.remove("bad");
      document.getElementById("gsubapply").disabled = true;
      requestSubPreview();
    }
  }

  document.getElementById("gsubapply").addEventListener("click", function () {
    var sub = canvas && canvas.subgraph;
    if (sub) send({ op: "applyDoc", entityId: cur.entityId, name: sub.name,
                    doc: subDoc(sub) });
  });

  document.getElementById("gback").addEventListener("click", function () {
    canvas.subgraph = null;
    canvas.setGraph(rootGraph);
    updateCrumbs();
  });

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
    canvas.getCanvasMenuOptions = function () {
      if (canvas.subgraph) {
        var items = subMenuItems(canvas.subgraph);
        items.push(null, { content: "Back to dependencies",
          callback: function () {
            canvas.subgraph = null;
            canvas.setGraph(rootGraph);
            updateCrumbs();
          } });
        return items;
      }
      return [{ content: "New attribute",
        callback: function () { openNewAttr(); } }];
    };
    canvas.showLinkMenu = linkMenu;
    canvas.onNodeDblClicked = function (n) {
      if (n.isSubgraphNode && n.isSubgraphNode()) {
        canvas.openSubgraph(n.subgraph);
        return;
      }
      if (n._odc) openFx(n._odc.name);
    };
    canvas.deleteSelected = function () {
      if (canvas.subgraph) {
        var sel = this.selected_nodes || {};
        Object.keys(sel).forEach(function (id) {
          var n = sel[id];
          if (n._odc) canvas.subgraph.remove(n);   // docks have no _odc
        });
        this.setDirty(true, true);
        requestSubPreview();
        return;
      }
      toast("Nodes are data-owned - use fx or the panel to edit");
    };
    el.addEventListener("subgraph-opened", updateCrumbs);
    window.addEventListener("resize", function () { canvas.resize(); });
    // resize() reads the parent box in CSS px - correct once dpr is 1.
    requestAnimationFrame(function () { canvas.resize(); });
  }

  // ---- boot -----------------------------------------------------------
  window.renderGraph = function (data) {
    cur = data;
    document.getElementById("gtitle").textContent =
      (data.label || "") + " - dependencies";
    var empty = !(data.graph && data.graph.nodes && data.graph.nodes.length);
    document.getElementById("gmsg").style.display = empty ? "block" : "none";

    if (canvas && canvas.ds) {
      savedView = { scale: canvas.ds.scale,
                    offset: [canvas.ds.offset[0], canvas.ds.offset[1]] };
    }

    building = true;
    applyTheme();
    ensureCanvas();
    rootGraph = new lg.LGraph();
    buildTop(rootGraph, data.graph || { nodes: [], edges: [] });
    wireLinkEvents();
    canvas.subgraph = null;
    canvas.setGraph(rootGraph);
    building = false;

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
