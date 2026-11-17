// Shared AST node layer for the litegraph formula canvases (fx node
// editor + dependency-graph formula subgraphs). Builds ODC nodes for
// the AstGraph doc types (const/attr/ref/un/bin/call/act/res) with
// widgets (const value/type, op combo, +arg), a manual-value text
// widget per input slot, friendly arg labels and the doc helpers both
// pages serialize with. Page code supplies hooks for preview/dirty and
// theming; everything else is one implementation.
(function () {
  "use strict";

  var BIN_OPS = ["+", "-", "*", "/", "%", "^", "&", "=", "<>", "<", ">",
                 "<=", ">=", "AND", "OR"];
  var UN_OPS = ["-", "+", "NOT"];

  // Friendly input names per function (same table as the old editor).
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

  function argLabel(t, v, key, idx, count) {
    if (t === "bin" || t === "un") return key;
    if (t === "call" || t === "act") {
      var fn = String(v || "").toUpperCase();
      var names = ARG_NAMES[fn];
      if (names && names[idx]) return names[idx];
      if (/^(LARGEST|SMALLEST)$/.test(fn)) {
        return idx === count - 1 ? "k" : "v" + (idx + 1);
      }
      if (names) return "v" + idx;
      return "arg" + (idx + 1);
    }
    return key;
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

  // depth = longest path from a leaf; leaves left, root right.
  function layoutDepth(nodes, links) {
    var depth = {};
    function depthOf(id, seen) {
      if (depth[id] != null) return depth[id];
      if (seen[id]) return 0;
      seen[id] = true;
      var ins = links.filter(function (l) { return l.t === id; });
      return depth[id] = ins.length
        ? 1 + Math.max.apply(null, ins.map(function (l) {
            return depthOf(l.f, seen); }))
        : 0;
    }
    Object.keys(nodes || {}).forEach(function (id) { depthOf(id, {}); });
    return depth;
  }

  // createNodes(LGraphNode, hooks) -> {Node, addIn, syncManWidgets, makeNode}
  //   hooks.tint(node, cssVar)   kind accent (boxcolor)
  //   hooks.preview()            debounced preview/validation request
  //   hooks.fnArity / hooks.fnVararg  catalogs for call nodes (live object
  //                                   refs - read at build time)
  function createNodes(lg, hooks) {
    var LGraphNode = lg.LGraphNode;

    class ODCNode extends LGraphNode {
      constructor() {
        super("node");
        this._odc = {};
      }
      getMenuOptions() { return []; }   // litegraph appends Remove itself
      // litegraph shows Remove/Rename Slot on slot right-click - the ODC
      // node action is clearer.
      getSlotMenuOptions() {
        if (this._odc.t === "res") {
          return [{ content: "(FORMULA output is fixed)", disabled: true }];
        }
        var n = this;
        return [{ content: "Remove node",
          callback: function () { n.graph && n.graph.remove(n); } }];
      }
      onConnectionsChange() {
        syncManWidgets(this);
        hooks.preview();
      }
    }

    // One companion text widget per input slot - the port's literal
    // value while nothing is wired into it.
    function addIn(n, name, label) {
      n.addInput(name, 0);
      var inp = n.inputs[n.inputs.length - 1];
      if (label) inp.label = label;
      var w = n.addWidget("text", "", "", function () { hooks.preview(); }, {});
      w._port = name;
      w.label = label || name;
      return inp;
    }

    function syncManWidgets(n) {
      var changed = false;
      (n.widgets || []).forEach(function (w) {
        if (!w._port) return;
        var inp = (n.inputs || []).find(function (i) { return i.name === w._port; });
        var h = !!(inp && inp.link != null);
        if (w.hidden !== h) { w.hidden = h; changed = true; }
      });
      if (changed) {
        n.setSize(n.computeSize());
        n.setDirtyCanvas(true, true);
      }
    }

    function constTitle(n) {
      var v = n._odc.v;
      return n._odc.k === "str" ? '"' + v + '"' : String(v);
    }

    function makeNode(t, v, extra) {
      var n = new ODCNode();
      n._odc = { t: t, v: v == null ? "" : v, k: (extra && extra.k) || null };
      switch (t) {
        case "const":
          n._odc.k = (extra && extra.k) || "num";
          n.title = constTitle(n);
          n.addWidget("text", "value", String(v == null ? "" : v),
            function (val) {
              n._odc.v = val;
              n.title = constTitle(n);
              hooks.preview();
            }, {});
          n.addWidget("combo", "type", n._odc.k, function (val) {
            n._odc.k = val;
            n.title = constTitle(n);
            hooks.preview();
          }, { values: ["num", "str"] });
          n.addOutput("out", 0);
          hooks.tint(n, "--warn");
          break;
        case "attr":
          n.title = v;
          n.addOutput("out", 0);
          hooks.tint(n, "--accent");
          break;
        case "ref":
          n.title = v;
          n.addOutput("out", 0);
          hooks.tint(n, "--accent2");
          break;
        case "un":
          n.title = v;
          n.addWidget("combo", "op", v, function (val) {
            n._odc.v = val;
            n.title = val;
            hooks.preview();
          }, { values: UN_OPS });
          addIn(n, "x", "x");
          n.addOutput("out", 0);
          break;
        case "bin":
          n.title = v;
          n.addWidget("combo", "op", v, function (val) {
            n._odc.v = val;
            n.title = val;
            hooks.preview();
          }, { values: BIN_OPS });
          addIn(n, "a", "a");
          addIn(n, "b", "b");
          n.addOutput("out", 0);
          break;
        case "call": {
          var arity = (hooks.fnArity() || {})[v];
          var count = (extra && extra.argc) || arity || 1;
          n.title = v;
          for (var i = 0; i < count; i++) {
            addIn(n, "arg" + i, argLabel(t, v, "arg" + i, i, count));
          }
          var vv = hooks.fnVararg() || [];
          if (vv.indexOf(v) >= 0) addArgButton(n, "call");
          n.addOutput("out", 0);
          hooks.tint(n, "--fn");
          break;
        }
        case "act":
          n.title = v;
          for (var j = 0; j < ((extra && extra.argc) || 2); j++) {
            addIn(n, "arg" + j,
              argLabel("act", v, "arg" + j, j, (extra && extra.argc) || 2));
          }
          addArgButton(n, "act");
          n.addOutput("out", 0);
          hooks.tint(n, "--warn");
          break;
        case "res":
          // The single FORMULA output node - whatever is wired into "in"
          // is the result. Always present, not deletable.
          n.title = "FORMULA";
          addIn(n, "in", "in");
          n.removable = false;
          n.clonable = false;
          n.block_delete = true;
          hooks.tint(n, "--accent2");
          break;
        default:
          n.title = t;
      }
      return n;
    }

    function addArgButton(n, t) {
      n.addWidget("button", "+ arg", null, function () {
        var idx = n.inputs.length;
        addIn(n, "arg" + idx,
          argLabel(t, n._odc.v, "arg" + idx, idx, idx + 1));
        n.setSize(n.computeSize());
        n.setDirtyCanvas(true, true);
        hooks.preview();
      });
    }

    return { Node: ODCNode, addIn: addIn,
             syncManWidgets: syncManWidgets, makeNode: makeNode };
  }

  window.ODCAst = {
    BIN_OPS: BIN_OPS, UN_OPS: UN_OPS, ARG_NAMES: ARG_NAMES,
    argLabel: argLabel, parseLit: parseLit, litDisplay: litDisplay,
    layoutDepth: layoutDepth, createNodes: createNodes
  };
})();
