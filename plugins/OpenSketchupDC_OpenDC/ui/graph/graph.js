// Open DC - modern Dynamic Components for SketchUp
// Copyright (C) 2026 Jure Judež and contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

// Dependency graph on the same Rete.js canvas as the formula node editor.
// Each attribute is a node: the "deps" input collects the attributes its
// formula references, the "out" socket feeds its dependents.
//   - drag out -> deps:  writes formula(target) = source (with confirm)
//   - click edge + Del:  unlinks - refs in the formula become literals
//   - double-click / fx: opens that attribute's formula canvas
// Ruby pushes {label, entityId, graph:{nodes,edges}} via renderGraph.
(function () {
  "use strict";

  var socketVal = new Rete.Socket("val", "Value");
  socketVal.combineWith(socketVal.name);

  var editor = null;
  var cur = null;        // latest payload {label, entityId, graph}
  var selConn = null;    // selected edge (Rete connection)
  var building = false;  // suppress edit ops while rebuilding the canvas
  var savedView = null;  // pan/zoom kept across re-renders
  var toastTimer = null;
  var confirmCb = null;

  function toast(msg, isErr) {
    var el = document.getElementById("gtoast");
    el.textContent = msg;
    el.className = "show" + (isErr ? " err" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.className = ""; }, 2600);
  }

  function send(payload) {
    sketchup.gact(JSON.stringify(payload));
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
  // The "+ attr" button and the canvas context menu both open the name
  // dialog; Ruby creates the attribute and re-pushes the graph, so the
  // new param lands in the leftmost column as a fresh wire target.
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
    ev.stopPropagation(); // keep Del/Escape out of the canvas handlers
    if (ev.key === "Enter") submitNewAttr();
    else if (ev.key === "Escape") hideNewAttr();
  });

  // Async feedback for ops without a graph re-push (mostly errors).
  window.onGraphStatus = function (r) {
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

  // ---- node template -------------------------------------------------
  // Same family as the formula editor's ODCNode: kind tag + name title,
  // left inputs / right outputs, and an fx button into the node editor.
  var KIND = { param: "param", ext: "external", virt: "builtin" };

  var socketDir = {
    bind: function (el, binding, vnode) {
      vnode.context.bindSocket(el, binding.arg, binding.value);
    },
    update: function (el, binding, vnode) {
      vnode.context.bindSocket(el, binding.arg, binding.value);
    }
  };

  var DepNode = {
    props: ["node", "editor", "bindSocket", "bindControl"],
    directives: { socket: socketDir },
    template:
      '<div class="node" :class="[selected(), node.data.t, {cyc: node.data.cyclic}]"' +
        ' @dblclick.stop="openFx">' +
        '<div class="ntitle">' +
          '<span class="nkind">{{kind}}</span>' +
          '<span class="nname" :title="node.data.v">{{node.data.v}}</span>' +
          '<button v-if="editable" class="fxbtn" title="Open formula canvas" ' +
            '@mousedown.stop @click.stop="openFx">fx</button>' +
        '</div>' +
        '<div class="nbody">' +
          '<div class="col ins">' +
            '<div v-for="i in inputs()" :key="i.key" class="port">' +
              '<div v-socket:input="i" class="sock"></div>' +
              '<div class="ptitle">{{i.key}}</div>' +
            '</div>' +
          '</div>' +
          '<div class="col ctrls">' +
            '<div v-if="fx" class="fxline" :title="fxTitle">{{fx}}</div>' +
          '</div>' +
          '<div class="col outs">' +
            '<div v-for="o in outputs()" :key="o.key" class="port out">' +
              '<div v-socket:output="o" class="sock"></div>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>',
    computed: {
      kind: function () { return KIND[this.node.data.t] || "param"; },
      editable: function () { return this.node.data.t === "param"; },
      fx: function () {
        var f = String(this.node.data.formula || "");
        return f ? "=" + (f.length > 22 ? f.slice(0, 22) + "…" : f) : "";
      },
      fxTitle: function () { return String(this.node.data.formula || ""); }
    },
    methods: {
      inputs: function () { return Array.from(this.node.inputs.values()); },
      outputs: function () { return Array.from(this.node.outputs.values()); },
      selected: function () {
        return this.editor.selected.contains(this.node) ? "selected" : "";
      },
      openFx: function () { openFx(this.node.data.v); }
    }
  };

  // ---- components ----------------------------------------------------
  function comp(name, build) {
    var c = new Rete.Component(name);
    c.builder = function (node) { build(node); return node; };
    c.worker = function () {};
    return c;
  }

  // deps is multi-connection: a formula may reference several attributes.
  var components = [
    comp("param", function (n) {
      n.addInput(new Rete.Input("deps", "deps", socketVal, true));
      n.addOutput(new Rete.Output("out", "value", socketVal));
    }),
    comp("ext", function (n) {
      n.addOutput(new Rete.Output("out", "value", socketVal));
    }),
    comp("virt", function (n) {
      n.addOutput(new Rete.Output("out", "value", socketVal));
    })
  ];

  function typeOf(d) { return d.external ? "ext" : d.virtual ? "virt" : "param"; }

  // node.name doubles as the CSS class in vue-render, so it carries the
  // node TYPE; the attribute name lives in data.v.
  async function makeNode(d) {
    var t = typeOf(d);
    var node = await components.find(function (c) { return c.name === t; })
      .createNode({
        v: d.id,
        formula: d.formula || "",
        cyclic: !!d.cyclic
      });
    node.data.t = t;
    node.name = t;
    return node;
  }

  // ---- graph doc -> rete ---------------------------------------------
  // Columns by dependency level (deps left, dependents right), rows in
  // payload order - same columnar layout the old SVG renderer used.
  async function buildEditor(graph) {
    var cols = {};
    (graph.nodes || []).forEach(function (n) {
      var l = n.external || n.virtual ? 0 : (n.level || 0);
      (cols[l] = cols[l] || []).push(n);
    });
    var lvls = Object.keys(cols).map(Number).sort(function (a, b) { return a - b; });
    var idMap = {};
    for (var ci = 0; ci < lvls.length; ci++) {
      var col = cols[lvls[ci]];
      for (var ri = 0; ri < col.length; ri++) {
        var node = await makeNode(col[ri]);
        node.position = [50 + ci * 230, 50 + ri * 90];
        editor.addNode(node);
        idMap[col[ri].id] = node;
      }
    }
    (graph.edges || []).forEach(function (e) {
      var s = idMap[e.from], d = idMap[e.to];
      if (!s || !d) return;
      var out = s.outputs.get("out"), inp = d.inputs.get("deps");
      if (out && inp) editor.connect(out, inp);
    });
  }

  // Blue-highlight connections into/out of the selected node(s).
  function markLit() {
    var sel = editor.selected.list;
    editor.view.connections.forEach(function (cv) {
      var c = cv.connection;
      var lit = sel.some(function (n) {
        return c.input.node === n || c.output.node === n;
      });
      if (cv.el) cv.el.classList.toggle("lit", lit);
    });
  }

  function wireEditorEvents() {
    // A user-drawn connection is only an intent: the real edge set is
    // owned by Ruby. Remove the visual connection and send the wire op;
    // the pushed re-render shows the result.
    editor.on("connectioncreated", function (conn) {
      if (building) return;
      var from = conn.output.node.data.v, to = conn.input.node.data.v;
      building = true;
      // defer out of the emit - mutating the connection set while the
      // event is being dispatched leaves stale views in vue-render
      setTimeout(function () {
        try { editor.removeConnection(conn); } catch (e) { /* already gone */ }
        building = false;
        wire(from, to);
      }, 0);
    });

    // Edge removal (Del on a selected edge, or rewiring one) unlinks the
    // reference in the target's formula.
    editor.on("connectionremoved", function (conn) {
      if (building) return;
      if (!conn.output || !conn.input || !conn.output.node || !conn.input.node) return;
      selConn = null;
      unlinkEdge(conn.output.node.data.v, conn.input.node.data.v);
    });

    editor.on("nodeselected", markLit);
    editor.on("connectioncreated connectionremoved", markLit);
  }

  // Click an edge's path to select it (Del then unlinks). Delegated on
  // the document - the #rete element itself is replaced on every render.
  document.addEventListener("click", function (ev) {
    if (!editor || !editor.view) return;
    var el = ev.target.closest ? ev.target.closest(".connection") : null;
    var hit = null;
    editor.view.connections.forEach(function (cv) {
      var on = !!(el && cv.el && cv.el.contains(ev.target));
      if (cv.el && cv.el.classList) cv.el.classList.toggle("sel", on);
      if (on) hit = cv.connection;
    });
    selConn = hit;
    if (hit) {
      toast("edge " + hit.output.node.data.v + " -> " + hit.input.node.data.v +
            " - press Del to unlink");
    }
  });

  // ---- boot -----------------------------------------------------------
  window.renderGraph = function (data) {
    cur = data;
    selConn = null;
    document.getElementById("gtitle").textContent =
      (data.label || "") + " - dependencies";
    var empty = !(data.graph && data.graph.nodes && data.graph.nodes.length);
    document.getElementById("gmsg").style.display = empty ? "block" : "none";

    if (editor && editor.view && editor.view.area && editor.view.area.transform) {
      savedView = editor.view.area.transform;
    }

    // Fresh container each render: rete's zoom/drag leaves bound wheel/
    // pointer listeners on the element, so reusing it would stack them.
    var old = document.getElementById("rete");
    var container = old.cloneNode(false);
    old.parentNode.replaceChild(container, old);
    if (editor) {
      try { editor.destroy(); } catch (e) { /* best effort */ }
    }
    editor = new Rete.NodeEditor("odcdep@0.1.0", container);
    editor.use(ConnectionPlugin.default);
    editor.use(VueRenderPlugin.default, { component: DepNode });
    editor.use(ContextMenuPlugin.default, {
      searchBar: false,
      delay: 120,
      items: { "New attribute": function () { openNewAttr(); } },
      // default allocate returns [] per component which still registers a
      // bare menu item - return null so only our item shows
      allocate: function () { return null; },
      // nodes are data-owned: hide the stock Delete/Clone, offer the
      // formula canvas on real params instead
      nodeItems: function (n) {
        var items = { Delete: false, Clone: false };
        if (n.data.t === "param") {
          items["Open formula canvas"] = function () { openFx(n.data.v); };
        } else {
          items["(external / builtin)"] = function () {};
        }
        return items;
      }
    });
    components.forEach(function (c) { editor.register(c); });

    building = true;
    buildEditor(data.graph || { nodes: [], edges: [] }).then(function () {
      editor.view.resize();
      if (savedView && editor.view && editor.view.area) {
        editor.view.area.transform = savedView;
        editor.view.area.update();
      }
      building = false;
      editor.trigger("process");
    }).catch(function (e) {
      building = false;
      toast("graph build failed: " + (e && e.message || e), true);
    });

    wireEditorEvents();
  };

  document.addEventListener("keydown", function (ev) {
    if ((ev.key === "Delete" || ev.key === "Backspace") && selConn && editor &&
        !building) {
      var c = selConn;
      selConn = null;
      try { editor.removeConnection(c); } catch (e) { /* already gone */ }
    }
  });

  if (window.sketchup && sketchup.gready) sketchup.gready("");
})();
