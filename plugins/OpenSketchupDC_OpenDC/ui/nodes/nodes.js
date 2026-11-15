// Open DC node editor - Rete.js v1 expression graph.
// Loads an AstGraph doc via window.renderNodes(payload); edits produce a
// preview via sketchup.nact {op:"preview"}; Apply writes the formula.
(function () {
  "use strict";

  var socketVal = new Rete.Socket("val", "Value");
  socketVal.combineWith(socketVal.name);

  var editor = null;
  var state = null;           // {entityId,name,label,functions,actions,attrs,builtins,fnArity,fnVararg,isAction}
  var toastTimer = null;
  var previewTimer = null;

  function toast(msg, isErr) {
    var el = document.getElementById("ntoast");
    el.textContent = msg;
    el.className = "show" + (isErr ? " err" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.className = ""; }, 2600);
  }

  // ---- controls --------------------------------------------------------
  var TextControl = {
    props: ["ikey", "getData", "putData"],
    template: '<input type="text" :value="value" @input="change($event)" ' +
      '@mousedown.stop @dblclick.stop/>',
    data: function () { return { value: "" }; },
    methods: {
      change: function (e) {
        this.value = e.target.value;
        this.putData(this.ikey, this.value);
        requestPreview();
      }
    },
    mounted: function () { this.value = this.getData(this.ikey) || ""; }
  };

  var AddArgBtn = {
    props: ["ikey", "getData", "putData", "node"],
    template: '<button class="addarg" @click="add" @mousedown.stop>+ arg</button>',
    methods: {
      add: function () {
        var n = this.node;
        n.addInput(new Rete.Input("arg" + n.inputs.size, "" + n.inputs.size, socketVal));
        n.update();
        editor.view.updateConnections({ node: n });
        requestPreview();
      }
    }
  };

  // Operator chooser - edits data.v among a fixed op list.
  var OpSelect = {
    props: ["ikey", "getData", "putData", "ops"],
    template: '<select class="nops" :value="value" @change="change($event)" ' +
      '@mousedown.stop><option v-for="o in ops" :value="o">{{o}}</option></select>',
    data: function () { return { value: "" }; },
    methods: {
      change: function (e) {
        this.value = e.target.value;
        this.putData(this.ikey, this.value);
        requestPreview();
      }
    },
    mounted: function () { this.value = this.getData(this.ikey) || ""; }
  };

  // Rete.Control is abstract - controls must subclass it (ES6 class).
  class ODCControl extends Rete.Control {
    constructor(key, component, extra) {
      super(key);
      this.component = component;
      this.props = Object.assign({ ikey: key }, extra || {});
    }
  }
  function ctrl(key, component, extra) {
    return new ODCControl(key, component, extra);
  }

  var BIN_OPS = ["+", "-", "*", "/", "%", "^", "&", "=", "<>", "<", ">",
                 "<=", ">=", "AND", "OR"];
  var UN_OPS = ["-", "+", "NOT"];

  // ---- node template ---------------------------------------------------
  // Replaces vue-render's default node: title = VALUE (NEAREST, lenx, +),
  // kind label = type, friendly arg names, "result" badge on the root.
  var KIND_LABEL = {
    const: "literal", attr: "attribute", ref: "reference",
    bin: "operator", un: "operator", call: "function", act: "action"
  };
  var ARG_NAMES = {
    IF: ["cond", "then", "else"],
    CHOOSE: ["i"],
    CURRENT: ["attr"],
    OPTIONINDEX: ["attr"],
    OPTIONVALUE: ["attr", "label"],
    ROUND: ["x", "ndigits"],
    NEAREST: ["x"],
    SET: ["attr"], ANIMATE: ["attr"], ANIMATESLOW: ["attr"],
    ANIMATEFAST: ["attr"], ANIMATECUSTOM: ["attr", "duration"]
  };

  function portName(input, node) {
    var t = node.data.t;
    if (t === "bin") return input.key;            // a / b
    if (t === "un") return "x";
    if (t === "call" || t === "act") {
      var idx = parseInt(input.key.slice(3), 10) || 0;
      var fn = String(node.data.v || "").toUpperCase();
      var names = ARG_NAMES[fn];
      if (names && names[idx]) return names[idx];
      if (/^(LARGEST|SMALLEST)$/.test(fn)) {
        return idx === node.inputs.size - 1 ? "k" : "v" + (idx + 1);
      }
      if (names) return "v" + idx;   // vararg candidates after the fixed head
      return "arg" + (idx + 1);
    }
    return input.key;
  }

  var socketDir = {
    bind: function (el, binding, vnode) {
      vnode.context.bindSocket(el, binding.arg, binding.value);
    },
    update: function (el, binding, vnode) {
      vnode.context.bindSocket(el, binding.arg, binding.value);
    }
  };
  var controlDir = {
    bind: function (el, binding, vnode) {
      if (binding.value) vnode.context.bindControl(el, binding.value);
    }
  };

  var ODCNode = {
    props: ["node", "editor", "bindSocket", "bindControl"],
    directives: { socket: socketDir, control: controlDir },
    template:
      '<div class="node" :class="[selected(), node.data.t, {root: node.data.root}]">' +
        '<div class="ntitle">' +
          '<span class="nkind">{{kind}}</span>' +
          '<span class="nname">{{display}}</span>' +
        '</div>' +
        '<div class="nbody">' +
          '<div class="col ins">' +
            '<div v-for="i in inputs()" :key="i.key" class="port">' +
              '<div v-socket:input="i" class="sock"></div>' +
              '<div class="ptitle">{{portLabel(i)}}</div>' +
              '<input v-if="!i.connections.length" class="manval" type="text" ' +
                ':value="manualVal(i)" @input="setManual(i, $event)" ' +
                '@mousedown.stop @dblclick.stop @pointerdown.stop ' +
                'placeholder="val"/>' +
            '</div>' +
          '</div>' +
          '<div class="col ctrls">' +
            '<div v-for="c in controls()" :key="c.key" v-control="c" class="control"></div>' +
          '</div>' +
          '<div class="col outs">' +
            '<div v-for="o in outputs()" :key="o.key" class="port out">' +
              '<div v-socket:output="o" class="sock"></div>' +
            '</div>' +
          '</div>' +
        '</div>' +
        '<div class="rbadge" v-if="node.data.root">result</div>' +
      '</div>',
    computed: {
      kind: function () { return KIND_LABEL[this.node.data.t] || "node"; },
      display: function () {
        var v = this.node.data.v;
        return v == null || v === "" ? "" : String(v);
      }
    },
    methods: {
      inputs: function () { return Array.from(this.node.inputs.values()); },
      outputs: function () { return Array.from(this.node.outputs.values()); },
      controls: function () { return Array.from(this.node.controls.values()); },
      selected: function () {
        return this.editor.selected.contains(this.node) ? "selected" : "";
      },
      portLabel: function (input) { return portName(input, this.node); },
      manualVal: function (input) {
        return ((this.node.data.manual || {})[input.key]) || "";
      },
      setManual: function (input, e) {
        var m = this.node.data.manual || (this.node.data.manual = {});
        m[input.key] = e.target.value;
        requestPreview();
      }
    }
  };

  // ---- components -------------------------------------------------------
  function comp(name, build) {
    var c = new Rete.Component(name);
    c.builder = function (node) { build(node); return node; };
    c.worker = function () {};
    return c;
  }

  var components = [
    comp("attr", function (n) {
      n.addOutput(new Rete.Output("out", "value", socketVal));
    }),
    comp("ref", function (n) {
      n.addOutput(new Rete.Output("out", "value", socketVal));
    }),
    comp("const", function (n) {
      n.addControl(ctrl("v", TextControl));
      n.addOutput(new Rete.Output("out", "value", socketVal));
    }),
    comp("bin", function (n) {
      n.addControl(ctrl("v", OpSelect, { ops: BIN_OPS }));
      n.addInput(new Rete.Input("a", "a", socketVal));
      n.addInput(new Rete.Input("b", "b", socketVal));
      n.addOutput(new Rete.Output("out", "value", socketVal));
    }),
    comp("un", function (n) {
      n.addControl(ctrl("v", OpSelect, { ops: UN_OPS }));
      n.addInput(new Rete.Input("x", "x", socketVal));
      n.addOutput(new Rete.Output("out", "value", socketVal));
    }),
    comp("call", function (n) {
      var v = n.data.v;
      var arity = (state.fnArity || {})[v];
      var count = n.data.argc || arity || 1;
      for (var i = 0; i < count; i++) {
        n.addInput(new Rete.Input("arg" + i, "" + i, socketVal));
      }
      if (state.fnVararg && state.fnVararg.indexOf(v) >= 0) {
        n.addControl(ctrl("addarg", AddArgBtn, { node: n }));
      }
      n.addOutput(new Rete.Output("out", "value", socketVal));
    }),
    comp("act", function (n) {
      var count = n.data.argc || 2;
      for (var i = 0; i < count; i++) {
        n.addInput(new Rete.Input("arg" + i, "" + i, socketVal));
      }
      n.addControl(ctrl("addarg", AddArgBtn, { node: n }));
      n.addOutput(new Rete.Output("out", "value", socketVal));
    })
  ];

  var TYPE2COMP = { const: "const", attr: "attr", ref: "ref",
                    bin: "bin", un: "un", call: "call", act: "act" };

  // node.name doubles as the CSS class and the title in vue-render, so it
  // carries the node TYPE (attr/const/call...); the value is shown by the
  // node's inner control. createNode is async in Rete v1.
  async function makeNode(type, v, extra) {
    var node = await components.find(function (c) {
      return c.name === TYPE2COMP[type];
    }).createNode(Object.assign({ v: v, manual: {} }, extra || {}));
    node.data.t = type;
    node.name = type;
    return node;
  }

  // Manual port values: "abc" -> str abc, 12.5 -> num, bare word -> str.
  function parseLit(raw) {
    var s = String(raw).trim();
    if (s.length > 1 && s[0] === '"' && s[s.length - 1] === '"')
      return { v: s.slice(1, -1), k: "str" };
    if (/^[+-]?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(s))
      return { v: s, k: "num" };
    return { v: s, k: "str" };
  }
  // Display form for a const value collapsed into a port field:
  // strings stay quoted so the type round-trips unambiguously.
  function litDisplay(v, k) {
    return k === "str" ? '"' + v + '"' : String(v);
  }

  // ---- graph doc <-> rete ------------------------------------------------
  // depth = longest path from a leaf; leaves left, root right.
  function layoutDepth(doc) {
    var depth = {}, links = doc.links || [];
    function depthOf(id, seen) {
      if (depth[id] != null) return depth[id];
      if (seen[id]) return 0;
      seen[id] = true;
      var ins = links.filter(function (l) { return l.t === id; });
      return depth[id] = ins.length
        ? 1 + Math.max.apply(null, ins.map(function (l) { return depthOf(l.f, seen); }))
        : 0;
    }
    Object.keys(doc.nodes).forEach(function (id) { depthOf(id, {}); });
    return depth;
  }

  async function buildEditor(doc) {
    var depth = layoutDepth(doc);
    var perLevel = {}, idMap = {};
    // A const node feeding exactly one port collapses into that port's
    // manual-value field. Multi-use consts stay visible (shared value).
    var useCnt = {}, collapsed = {}, manual = {};
    (doc.links || []).forEach(function (l) {
      useCnt[l.f] = (useCnt[l.f] || 0) + 1;
    });
    (doc.links || []).forEach(function (l) {
      var src = doc.nodes[l.f];
      if (src && src.t === "const" && useCnt[l.f] === 1 && doc.nodes[l.t]) {
        collapsed[l.f] = true;
        (manual[l.t] = manual[l.t] || {})[l.p] = litDisplay(src.v, src.k);
      }
    });
    for (var id of Object.keys(doc.nodes)) {
      if (collapsed[id]) continue;
      var n = doc.nodes[id];
      var argc = (n.t === "call" || n.t === "act")
        ? doc.links.filter(function (l) { return l.t === id; }).length
        : undefined;
      var node = await makeNode(n.t, n.v, { k: n.k, argc: argc });
      node.data.manual = manual[id] || {};
      var lv = depth[id] || 0;
      perLevel[lv] = (perLevel[lv] || 0) + 1;
      node.position = [60 + lv * 190, 40 + (perLevel[lv] - 1) * 110];
      editor.addNode(node);
      idMap[id] = node;
    }
    doc.links.forEach(function (l) {
      if (collapsed[l.f]) return;
      var src = idMap[l.f], dst = idMap[l.t];
      if (src && dst) editor.connect(src.outputs.get("out"), dst.inputs.get(l.p));
    });
  }

  function graphDoc() {
    var d = editor.toJSON();
    var nodes = {}, links = [], fed = {};
    Object.keys(d.nodes).forEach(function (id) {
      var n = d.nodes[id];
      var t = n.data.t === "act" ? "call" : (n.data.t || n.name);
      nodes[id] = { t: t, v: n.data.v, k: n.data.k };
      Object.keys(n.outputs).forEach(function (ok) {
        (n.outputs[ok].connections || []).forEach(function (c) {
          links.push({ f: id, t: String(c.node), p: c.input });
          fed[id] = true;
        });
      });
    });
    // Typed port values become a synthesized const node + link, keeping
    // the doc schema and the Ruby emitter unchanged.
    editor.nodes.forEach(function (n) {
      var man = n.data.manual || {};
      Object.keys(man).forEach(function (pk) {
        var inp = n.inputs.get(pk);
        if (!inp || inp.connections.length) return;
        var raw = String(man[pk]).trim();
        if (!raw) return;
        var lit = parseLit(raw);
        var mid = "m" + n.id + "_" + pk;
        nodes[mid] = { t: "const", v: lit.v, k: lit.k };
        links.push({ f: mid, t: String(n.id), p: pk });
        fed[mid] = true;
      });
    });
    var roots = Object.keys(nodes).filter(function (id) { return !fed[id]; });
    return { nodes: nodes, links: links, root: rootId ? String(rootId) : roots[0] };
  }

  // ---- preview / apply ---------------------------------------------------
  function send(payload) {
    sketchup.nact(JSON.stringify(payload));
  }

  function requestPreview() {
    if (!state) return;
    clearTimeout(previewTimer);
    previewTimer = setTimeout(function () {
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

  // ---- context menu --------------------------------------------------------
  // The plugin calls item.onClick(args) and ignores the return value —
  // the callback itself must add the built node to the editor.
  function addItem(type, v, extra) {
    return function () {
      return makeNode(type, v, extra).then(function (n) {
        editor.addNode(n);
        markRoots();
        requestPreview();
      }).catch(function (err) {
        toast("add failed: " + err.message, true);
      });
    };
  }
  function menuItems() {
    var items = { Operators: {} };
    ["+", "-", "*", "/", "%", "^", "&", "=", "<>", "<", ">", "<=", ">=",
     "AND", "OR"].forEach(function (op) {
      items.Operators[op] = addItem("bin", op);
    });
    items.Operators["unary -"] = addItem("un", "-");
    items.Operators["NOT"] = addItem("un", "NOT");
    items.Literals = {
      Number: addItem("const", "0", { k: "num" }),
      Text: addItem("const", "", { k: "str" })
    };
    items.Attributes = {};
    (state.attrs || []).concat(state.builtins || []).forEach(function (a) {
      items.Attributes[a] = addItem("attr", a);
    });
    (state.globals || []).forEach(function (g) {
      items.Attributes["global!" + g] = addItem("ref", "global!" + g);
    });
    items.Functions = {};
    (state.functions || []).forEach(function (f) {
      items.Functions[f] = addItem("call", f);
    });
    if (state.isAction) {
      items.Actions = {};
      (state.actions || []).forEach(function (f) {
        items.Actions[f] = addItem("act", f);
      });
    }
    return items;
  }

  // ---- boot ---------------------------------------------------------------
  window.renderNodes = function (payload) {
    state = payload;
    document.getElementById("ptitle").textContent = payload.label || payload.name;

    var container = document.getElementById("rete");
    container.innerHTML = "";
    editor = new Rete.NodeEditor("odc@0.1.0", container);
    editor.use(ConnectionPlugin.default);
    editor.use(VueRenderPlugin.default, { component: ODCNode });
    editor.use(ContextMenuPlugin.default, {
      items: menuItems(),
      // default allocate returns [] per component which still registers a
      // bare menu item - return null so only our categorized items show
      allocate: function () { return null; },
      // default 1s submenu hide delay leaves overlapping submenus open
      delay: 120
    });
    components.forEach(function (c) { editor.register(c); });
    window.__dbg = { editor: editor, comps: components, markRoots: markRoots };

    buildEditor(payload.graph || { nodes: {}, links: [] }).then(function () {
      markRoots();
      editor.view.resize();
      editor.trigger("process");
      requestPreview();
    }).catch(function (e) {
      send({ op: "dbg", err: String(e && e.message || e),
             stack: String(e && e.stack || "").slice(0, 400) });
      toast("graph build failed: " + (e && e.message || e), true);
    });

    editor.on("connectioncreated connectionremoved noderemoved nodecreated", function () {
      // re-render ports so manual fields hide/show on (dis)connect
      editor.nodes.forEach(function (n) { if (n.update) n.update(); });
      markRoots();
      requestPreview();
    });

    // Blue-highlight connections into/out of the selected node(s).
    function markSelectedConns() {
      var sel = editor.selected.list;
      editor.view.connections.forEach(function (cv) {
        var c = cv.connection;
        var lit = sel.some(function (n) {
          return c.input.node === n || c.output.node === n;
        });
        if (cv.el) cv.el.classList.toggle("lit", lit);
      });
    }
    editor.on("nodeselected", markSelectedConns);
    editor.on("connectioncreated connectionremoved", markSelectedConns);

    requestPreview();
  };

  // Exactly one node is the result - the root the formula is emitted
  // from. Other sinks (disconnected fragments, freshly added nodes)
  // are NOT results. Tracked as a stable rootId: kept while still a
  // sink, followed downstream when wired into another node, and
  // re-picked (largest upstream tree) when deleted.
  var rootId = null;

  function isSink(n) {
    return !Array.from(n.outputs.values())
      .some(function (o) { return o.connections.length > 0; });
  }

  function downstreamSink(n) {
    var seen = {};
    while (n && !seen[n.id]) {
      seen[n.id] = true;
      if (isSink(n)) return n;
      var nxt = null;
      n.outputs.forEach(function (o) {
        if (!nxt && o.connections.length) nxt = o.connections[0].input.node;
      });
      n = nxt;
    }
    return null;
  }

  function upstreamCount(n) {
    var seen = {};
    (function walk(m) {
      m.inputs.forEach(function (i) {
        i.connections.forEach(function (c) {
          var src = c.output.node;
          if (!seen[src.id]) { seen[src.id] = true; walk(src); }
        });
      });
    })(n);
    return Object.keys(seen).length;
  }

  function markRoots() {
    if (!editor) return;
    var sinks = editor.nodes.filter(isSink);
    var root = editor.nodes.find(function (n) { return String(n.id) === String(rootId); });
    if (root && !isSink(root)) root = downstreamSink(root);
    if (!root || !isSink(root)) {
      root = null;
      var best = -1;
      sinks.forEach(function (s) {
        var c = upstreamCount(s);
        if (c > best) { best = c; root = s; }
      });
    }
    rootId = root ? root.id : null;
    editor.nodes.forEach(function (n) {
      var isRoot = !!root && n.id === root.id;
      if (!!n.data.root !== isRoot) {
        n.data.root = isRoot || undefined;
        n.update();
      }
    });
  }

  document.getElementById("napply").addEventListener("click", function () {
    if (state) send({ op: "apply", entityId: state.entityId, name: state.name,
                      doc: graphDoc() });
  });

  document.addEventListener("keydown", function (ev) {
    if ((ev.key === "Delete" || ev.key === "Backspace") && editor &&
        editor.selected.list.length) {
      editor.selected.list.slice().forEach(function (n) { editor.removeNode(n); });
      editor.selected.clear();
      requestPreview();
    }
  });

  if (window.sketchup && sketchup.nready) sketchup.nready("");
})();
