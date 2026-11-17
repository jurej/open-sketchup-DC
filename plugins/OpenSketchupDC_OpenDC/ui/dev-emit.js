// Dev-only mirror of AstGraph.to_formula (core/ast_graph.rb) shared by
// the dev harnesses so docs can be asserted as formula strings without
// SketchUp. NOT shipped.
(function () {
  "use strict";
// ---- mock Ruby bridge ----------------------------------------------------
  // Mirrors AstGraph.to_formula (plugins/.../core/ast_graph.rb) so harness
  // assertions exercise the same emission rules Ruby applies.
  var PRECEDENCE = {
    "OR": 1, "AND": 2, "=": 3, "<>": 3, "<": 3, ">": 3, "<=": 3, ">=": 3,
    "&": 4, "+": 5, "-": 5, "*": 6, "/": 6, "%": 6, "^": 6 };
  var UN_PREC = 7, PRIMARY_PREC = 8;
  var NON_ASSOC_RIGHT = ["-","/","%","^","=","<>","<",">","<=",">="];
  var FN_ARITY = { IF: 3, ROUND: 1, MIN: 1, MAX: 1, PI: 0, CHOOSE: 2 };

  function emitPort(nodes, inMap, id, port) {
    var src = inMap[id + "|" + port];
    if (src == null) throw new Error("unconnected input " + port + " on " + id);
    return emitNode(src, nodes, inMap);
  }
  function emitNode(id, nodes, inMap) {
    var n = nodes[id];
    if (!n) throw new Error("unknown node " + id);
    switch (n.t) {
      case "const":
        return [n.k === "str" ? '"' + String(n.v).replace(/"/g, "") + '"'
                             : String(n.v), PRIMARY_PREC];
      case "attr": case "ref": return [String(n.v), PRIMARY_PREC];
      case "un": {
        var x = emitPort(nodes, inMap, id, "x");
        var inner = x[1] < UN_PREC ? "(" + x[0] + ")" : x[0];
        var op = String(n.v);
        return [op === "NOT" ? "NOT " + inner : op + inner, UN_PREC];
      }
      case "bin": {
        var op2 = String(n.v);
        var pr = PRECEDENCE[op2];
        if (pr == null) throw new Error("unknown operator " + op2);
        var l = emitPort(nodes, inMap, id, "a");
        var r = emitPort(nodes, inMap, id, "b");
        var lt = l[1] < pr ? "(" + l[0] + ")" : l[0];
        var rt = (NON_ASSOC_RIGHT.indexOf(op2) >= 0 ? r[1] <= pr : r[1] < pr)
          ? "(" + r[0] + ")" : r[0];
        var to = (op2 === "AND" || op2 === "OR") ? " " + op2 + " " : op2;
        return [lt + to + rt, pr];
      }
      case "call": {
        var args = Object.keys(inMap)
          .filter(function (k) { var kv = k.split("|");
            return kv[0] === id && kv[1].indexOf("arg") === 0; })
          .sort(function (x, y) {
            return +x.split("|")[1].slice(3) - +y.split("|")[1].slice(3); });
        var fn = String(n.v);
        if (!args.length && (FN_ARITY[fn.toUpperCase()] || 1) > 0)
          throw new Error(fn + " has no arguments");
        var texts = args.map(function (k) {
          return emitNode(inMap[k], nodes, inMap)[0]; });
        return [fn + "(" + texts.join(",") + ")", PRIMARY_PREC];
      }
      default: throw new Error("unknown node type " + n.t);
    }
  }
  function toFormula(doc) {
    var nodes = doc.nodes || {}, links = doc.links || [];
    var inMap = {}, fed = {};
    links.forEach(function (l) {
      inMap[l.t + "|" + String(l.p)] = l.f;
      fed[l.f] = true;
    });
    var root = doc.root;
    if (root == null) {
      root = Object.keys(nodes).find(function (k) { return !fed[k]; });
    }
    if (root == null) throw new Error("empty graph");
    return emitNode(String(root), nodes, inMap)[0];
  }

    window.ODCDocEmit = { toFormula: toFormula };
})();
