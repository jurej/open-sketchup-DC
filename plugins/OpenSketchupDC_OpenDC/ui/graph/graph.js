// Dependency-graph SVG renderer shared by the graph window.
// OpenDCGraph.render(g) -> HTML string. Nodes carry data-gp (param id),
// edges carry data-f (dep id) / data-t (dependent id) for highlighting.
(function () {
  "use strict";

  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function render(g) {
    if (!g || !g.nodes || !g.nodes.length) {
      return '<div class="gmsg">No parameter dependencies.</div>';
    }
    var NW = 132, NH = 26, GX = 36, GY = 14, PAD = 10;
    var cols = {};
    g.nodes.forEach(function (n) {
      var l = n.external || n.virtual ? 0 : (n.level || 0);
      (cols[l] = cols[l] || []).push(n);
    });
    var lvls = Object.keys(cols).map(Number).sort(function (a, b) { return a - b; });
    var pos = {}, maxRows = 0;
    lvls.forEach(function (l, ci) {
      cols[l].forEach(function (n, ri) {
        pos[n.id] = { x: PAD + ci * (NW + GX), y: PAD + ri * (NH + GY), n: n };
      });
      if (cols[l].length > maxRows) maxRows = cols[l].length;
    });
    var w = PAD * 2 + lvls.length * (NW + GX) - GX;
    var h = PAD * 2 + maxRows * (NH + GY) - GY;

    var paths = g.edges.map(function (e2) {
      var a = pos[e2.from], b = pos[e2.to];
      if (!a || !b) return "";
      var x1 = a.x + NW, y1 = a.y + NH / 2, x2 = b.x, y2 = b.y + NH / 2;
      var mx = (x1 + x2) / 2;
      return '<path class="gedge" data-f="' + esc(e2.from) + '" data-t="' +
        esc(e2.to) + '" d="M' + x1 + ' ' + y1 +
        ' C' + mx + ' ' + y1 + ' ' + mx + ' ' + y2 + ' ' + x2 + ' ' + y2 + '"/>';
    }).join("");

    var boxes = g.nodes.map(function (n) {
      var p = pos[n.id];
      var cls = "gnode" + (n.external ? " ext" : "") + (n.virtual ? " virt" : "") +
        (n.cyclic ? " cyclic" : "");
      return '<g class="' + cls + '" data-gp="' + esc(n.id) + '"' +
        ' transform="translate(' + p.x + ',' + p.y + ')">' +
        '<rect width="' + NW + '" height="' + NH + '" rx="5"/>' +
        '<text x="' + (NW / 2) + '" y="' + (NH / 2 + 4) + '">' + esc(n.id) + '</text></g>';
    }).join("");

    return '<div class="gscroll"><svg class="depgraph" width="' + w + '" height="' + h + '"' +
      ' viewBox="0 0 ' + w + ' ' + h + '">' +
      '<defs><marker id="garr" markerWidth="8" markerHeight="8" refX="7" refY="4"' +
      ' orient="auto"><path d="M0 0 L8 4 L0 8 Z" class="garr"/></marker></defs>' +
      paths + boxes + '</svg></div>';
  }

  window.OpenDCGraph = { render: render };
})();
