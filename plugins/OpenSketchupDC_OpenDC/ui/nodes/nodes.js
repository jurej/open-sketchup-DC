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

  // Read-only value label (attr name, function name, ref).
  var LabelControl = {
    props: ["ikey", "getData", "putData", "node"],
    template: '<div class="nval">{{node.data.v}}</div>'
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

  // ---- components -------------------------------------------------------
  function comp(name, build) {
    var c = new Rete.Component(name);
    c.builder = function (node) { build(node); return node; };
    c.worker = function () {};
    return c;
  }

  var components = [
    comp("attr", function (n) {
      n.addControl(ctrl("lbl", LabelControl, { node: n }));
      n.addOutput(new Rete.Output("out", "value", socketVal));
    }),
    comp("ref", function (n) {
      n.addControl(ctrl("lbl", LabelControl, { node: n }));
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
      n.addControl(ctrl("lbl", LabelControl, { node: n }));
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
      n.addControl(ctrl("lbl", LabelControl, { node: n }));
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
    }).createNode(Object.assign({ v: v }, extra || {}));
    node.data.t = type;
    node.name = type;
    return node;
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
    for (var id of Object.keys(doc.nodes)) {
      var n = doc.nodes[id];
      var argc = (n.t === "call" || n.t === "act")
        ? doc.links.filter(function (l) { return l.t === id; }).length
        : undefined;
      var node = await makeNode(n.t, n.v, { k: n.k, argc: argc });
      var lv = depth[id] || 0;
      perLevel[lv] = (perLevel[lv] || 0) + 1;
      node.position = [60 + lv * 190, 40 + (perLevel[lv] - 1) * 110];
      editor.addNode(node);
      idMap[id] = node;
    }
    doc.links.forEach(function (l) {
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
    var roots = Object.keys(nodes).filter(function (id) { return !fed[id]; });
    return { nodes: nodes, links: links, root: roots[0] };
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
  function menuItems() {
    var items = { Operators: {} };
    ["+", "-", "*", "/", "%", "^", "&", "=", "<>", "<", ">", "<=", ">=",
     "AND", "OR"].forEach(function (op) {
      items.Operators[op] = function () { return makeNode("bin", op); };
    });
    items.Operators["unary -"] = function () { return makeNode("un", "-"); };
    items.Operators["NOT"] = function () { return makeNode("un", "NOT"); };
    items.Literals = {
      Number: function () { return makeNode("const", "0", { k: "num" }); },
      Text: function () { return makeNode("const", "", { k: "str" }); }
    };
    items.Attributes = {};
    (state.attrs || []).concat(state.builtins || []).forEach(function (a) {
      items.Attributes[a] = function () { return makeNode("attr", a); };
    });
    (state.globals || []).forEach(function (g) {
      items.Attributes["global!" + g] = function () {
        return makeNode("ref", "global!" + g);
      };
    });
    items.Functions = {};
    (state.functions || []).forEach(function (f) {
      items.Functions[f] = function () { return makeNode("call", f); };
    });
    if (state.isAction) {
      items.Actions = {};
      (state.actions || []).forEach(function (f) {
        items.Actions[f] = function () { return makeNode("act", f); };
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
    editor.use(VueRenderPlugin.default);
    editor.use(ContextMenuPlugin.default, { items: menuItems() });
    components.forEach(function (c) { editor.register(c); });
    window.__dbg = { editor: editor, comps: components };

    buildEditor(payload.graph || { nodes: {}, links: [] }).then(function () {
      editor.view.resize();
      editor.trigger("process");
      requestPreview();
    }).catch(function (e) {
      send({ op: "dbg", err: String(e && e.message || e),
             stack: String(e && e.stack || "").slice(0, 400) });
      toast("graph build failed: " + (e && e.message || e), true);
    });

    editor.on("connectioncreated connectionremoved noderemoved", requestPreview);
    requestPreview();
  };

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
