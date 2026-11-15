/* Open DC parameter panel - vanilla JS, talks to Ruby via sketchup.dc(json). */
window.OpenDC = (function () {
  var state = { entities: [], batch: null, dcAvailable: true, globals: [] };
  var tabs = {};      // entityId -> "options" | "advanced"
  var openAdd = {};   // entityId -> bool
  var openEdit = {};  // entityId::name -> bool (advanced editor expanded)
  var fxTimers = {};  // entityId::name -> debounce timer
  var fxReq = {};     // entityId::name -> last validation request id
  var fxValid = {};   // entityId::name -> last validation ok flag (true/false/undefined)
  var fxReqSeq = 0;

  // Function chip templates (inserted at caret). Parens/commas left for the
  // user to fill - like block-builder "blocks" but text-native.
  var FN_CHIPS = [
    "IF(,,)", "CHOOSE(,,)", 'CURRENT("")', "MIN(,)", "MAX(,)", "ROUND(,)",
    "OPTIONINDEX(\"\")", "OPTIONVALUE(,\"\")"
  ];
  var ACTION_CHIPS = [
    'SET("",,)', 'ANIMATE("",,)', "REDRAW()", 'ALERT("")', 'GOTOSCENE("")'
  ];

  function send(action, payload) {
    sketchup.dc(JSON.stringify({ action: action, payload: payload || {} }));
  }

  function update(s) { state = s; render(); }

  function error(msg) {
    var t = document.getElementById("toast");
    t.textContent = msg;
    t.classList.remove("hidden");
    setTimeout(function () { t.classList.add("hidden"); }, 4000);
  }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function fmt(v) {
    if (v == null) return "";
    if (typeof v === "number") return +v.toFixed(6);
    return String(v);
  }

  function filter() {
    return document.getElementById("search").value.trim().toLowerCase();
  }

  function match(p, q) {
    if (!q) return true;
    return (p.name + " " + (p.displayName || "") + " " + (p.label || ""))
      .toLowerCase().indexOf(q) !== -1;
  }

  /* ---------------- render ---------------- */

  function render() {
    var banner = document.getElementById("banner");
    if (!state.dcAvailable) {
      banner.textContent = "SketchUp's Dynamic Components extension is unavailable - " +
        "classic components can be edited but not re-evaluated by its engine.";
      banner.classList.remove("hidden");
    } else {
      banner.classList.add("hidden");
    }

    var ents = state.entities || [];
    document.getElementById("empty").classList.toggle("hidden", ents.length !== 0);
    renderBatch();
    renderEntities(ents);
  }

  function renderBatch() {
    var el = document.getElementById("batch");
    var b = state.batch;
    if (!b || !b.shared || !b.shared.length) { el.classList.add("hidden"); return; }

    var q = filter();
    var rows = b.shared.filter(function (p) { return match(p, q); }).map(function (p) {
      return '<div class="prow">' +
        '<span class="pname" title="' + esc(p.name) + '"><b>' + esc(p.displayName) + '</b></span>' +
        '<span>' + inputFor(p, "batch") + '</span>' +
        '<span class="formula-hint">' + (p.formula ? "fx" : "") + '</span>' +
        '</div>';
    }).join("");

    el.innerHTML = '<header>Batch edit - ' + b.count + ' components</header>' +
      '<div class="params">' + rows + '</div>';
    el.classList.remove("hidden");

    el.querySelectorAll("input[data-name], select[data-name]").forEach(function (inp) {
      inp.addEventListener("change", function () {
        send("batchSet", {
          entityIds: JSON.parse(inp.getAttribute("data-ids")),
          name: inp.getAttribute("data-name"),
          value: inp.value
        });
      });
    });
  }

  function renderEntities(ents) {
    var host = document.getElementById("entities");
    var q = filter();
    host.innerHTML = ents.map(function (e) {
      var tab = tabs[e.entityId] || "options";
      var params = (e.params || []).filter(function (p) {
        return tab === "advanced" ? match(p, q) : (match(p, q) && p.access !== "NONE" && !p.internal);
      });
      return '<div class="card" data-eid="' + esc(e.entityId) + '">' +
        '<header>' +
        '<span class="name" title="' + esc(e.label) + '">' + esc(e.label) + '</span>' +
        '<span class="badge kind">' + esc(e.kind) + '</span>' +
        '<span class="badge ' + (e.engine === "osdc" ? "osdc" : "") + '">' +
          (e.engine === "osdc" ? "Open DC" : "Classic") + '</span>' +
        (e.engine === "osdc"
          ? '<button class="small" data-act="revert">Revert</button>'
          : '<button class="small" data-act="convert">Convert</button>') +
        '</header>' +
        '<div class="tabs">' +
        '<button data-tab="options" class="' + (tab === "options" ? "active" : "") + '">Options</button>' +
        '<button data-tab="advanced" class="' + (tab === "advanced" ? "active" : "") + '">Advanced</button>' +
        '</div>' +
        '<div class="params">' +
        params.map(function (p) { return renderParam(e, p, tab === "advanced"); }).join("") +
        (params.length ? "" : '<div class="prow"><span class="pname">No parameters.</span></div>') +
        '</div>' +
        addFormHtml(e) +
        '</div>';
    }).join("");

    wireEntityCards(host);
  }

  function renderParam(e, p, advanced) {
    var id = esc(e.entityId);
    var err = p.error ? '<div class="err">' + esc(p.error) + '</div>' : "";
    var key = id + "::" + p.name;
    var editOpen = openEdit[key] && advanced;
    var html = '<div class="prow' + (p.internal ? " internal" : "") + '">' +
      '<span class="pname" title="' + esc(p.name) + '"><b>' + esc(p.displayName) + '</b>' +
      (p.internal ? ' <span class="formula-hint">sys</span>' : '') +
      (p.overridden ? ' <span class="formula-hint">*</span>' : '') +
      '</span>' +
      '<span>' + (p.access === "VIEW" || p.internal
        ? '<span class="ro">' + esc(fmt(p.displayValue != null ? p.displayValue : p.value)) + '</span>'
        : inputFor(p, e.entityId)) + '</span>' +
      '<span>' +
      (advanced && !p.internal
        ? '<button class="small" data-edit="' + esc(key) + '" data-name="' + esc(p.name) + '">fx</button>'
        : (p.formula ? '<span class="formula-hint">fx</span>' : '')) +
      '</span>' +
      err +
      '</div>';
    if (editOpen) html += editorHtml(e.entityId, p);
    return html;
  }

  function chip(text, ins, cls, title) {
    return '<button type="button" class="fxchip ' + cls + '" data-ins="' + esc(ins) +
      '" title="' + esc(title || ins) + '">' + esc(text) + '</button>';
  }

  // Click-to-insert palette: every existing attribute on the entity as a
  // chip (no manual name typing -> no attr-name typos), plus global!s,
  // function templates, and onClick actions when editing that attribute.
  function paletteHtml(e, p) {
    var out = ['<div class="fxpalette">'];
    out.push('<span class="fxgroup">attrs</span>');
    (e.params || []).forEach(function (x) {
      if (!x.internal)
        out.push(chip(x.name, x.name, "attr", x.displayName || x.name));
    });
    if ((e.params || []).some(function (x) { return x.name === "copies"; }))
      out.push(chip("copy", "copy", "attr", "copy index inside generated copies"));
    (state.globals || []).forEach(function (g) {
      out.push(chip("global!" + g.name, "global!" + g.name, "glob", "model-global attribute"));
    });
    out.push('<span class="fxgroup">fns</span>');
    FN_CHIPS.forEach(function (t) { out.push(chip(t.replace(/\(.*/, "") + "()", t, "fn", t)); });
    if (p.name === "onclick") {
      out.push('<span class="fxgroup">actions</span>');
      ACTION_CHIPS.forEach(function (t) { out.push(chip(t.replace(/\(.*/, "") + "()", t, "act", t)); });
    }
    out.push('</div>');
    return out.join("");
  }

  function editorHtml(entityId, p) {
    var e = (state.entities || []).find(function (x) { return x.entityId === entityId; }) || { params: [] };
    var id = esc(entityId);
    var n = esc(p.name);
    return '<div class="pedit" data-pedit="' + n + '">' +
      '<div class="full"><label>formula - click an attribute below to insert it</label>' +
      '<input data-f="formula" value="' + esc(p.formula || "") + '">' +
      paletteHtml(e, p) +
      '<div class="fxstatus"></div></div>' +
      '<div><label>default</label><input data-f="default" value="' + esc(fmt(p["default"])) + '"></div>' +
      '<div><label>access</label><select data-f="access">' +
      ["NONE", "VIEW", "TEXTBOX", "LIST"].map(function (a) {
        return '<option' + (p.access === a ? " selected" : "") + '>' + a + '</option>';
      }).join("") + '</select></div>' +
      '<div><label>units</label><input data-f="units" value="' + esc(p.units || "") + '"></div>' +
      '<div class="full"><label>options (Label=value&amp;…)</label><input data-f="options" value="' + esc(p.options || "") + '"></div>' +
      '<div><label>formlabel</label><input data-f="formlabel" value="' + esc(p.formlabel || "") + '"></div>' +
      '<div><label>label</label><input data-f="label" value="' + esc(p.label || "") + '"></div>' +
      '<div class="full row-actions">' +
      '<button class="small" data-del="' + n + '">Delete</button>' +
      '<button class="small primary" data-save="' + n + '">Apply</button>' +
      '</div>' +
      '</div>';
  }

  function inputFor(p, entityId) {
    var ids = "";
    var name = esc(p.name);
    if (entityId === "batch") {
      ids = ' data-ids="' + esc(JSON.stringify(p.entityIds || [])) + '"';
      entityId = p.name;
    }
    var data = ' data-name="' + name + '" data-eid="' + esc(entityId) + '"' + ids;
    var ph = p.mixed ? ' placeholder="<mixed>"' : "";

    if (p.access === "LIST" && p.optionsList && p.optionsList.length) {
      var cur = p.displayValue != null ? p.displayValue : p.value;
      var mixedOpt = p.mixed ? '<option value="" disabled selected>&lt;mixed&gt;</option>' : "";
      return '<select' + data + '>' + mixedOpt +
        p.optionsList.map(function (o) {
          var sel = (!p.mixed && String(o.value) === String(cur)) ? " selected" : "";
          return '<option value="' + esc(o.value) + '"' + sel + '>' + esc(o.label) + '</option>';
        }).join("") + '</select>';
    }
    return '<input type="text" value="' + esc(fmt(p.displayValue != null ? p.displayValue : p.value)) + '"' + data + ph + '>';
  }

  function addFormHtml(e) {
    var id = esc(e.entityId);
    if (openAdd[e.entityId]) {
      return '<form class="addform" data-addform="' + id + '">' +
        '<input name="name" placeholder="attribute name" required>' +
        '<input name="label" placeholder="label">' +
        '<select name="access"><option>TEXTBOX</option><option>LIST</option><option>VIEW</option><option>NONE</option></select>' +
        '<input name="value" placeholder="value">' +
        '<button type="submit">Add</button></form>';
    }
    return '<div class="prow"><span class="pname"></span><span></span>' +
      '<button class="small" data-add="' + id + '">+ attr</button></div>';
  }

  /* ---------------- events ---------------- */

  function wireEntityCards(host) {
    host.querySelectorAll("[data-act]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var card = btn.closest(".card");
        send(btn.getAttribute("data-act"), { entityId: card.getAttribute("data-eid") });
      });
    });

    host.querySelectorAll("[data-tab]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var card = btn.closest(".card");
        tabs[card.getAttribute("data-eid")] = btn.getAttribute("data-tab");
        render();
      });
    });

    host.querySelectorAll("input[data-name], select[data-name]").forEach(function (inp) {
      inp.addEventListener("change", function () {
        var card = inp.closest(".card");
        send("setParam", {
          entityId: card.getAttribute("data-eid"),
          name: inp.getAttribute("data-name"),
          value: inp.value
        });
      });
    });

    host.querySelectorAll("[data-add]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        openAdd[btn.getAttribute("data-add")] = true;
        render();
      });
    });

    host.querySelectorAll("[data-edit]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var key = btn.getAttribute("data-edit");
        openEdit[key] = !openEdit[key];
        render();
      });
    });

    // Formula builder: attribute/function chips insert at the caret (no
    // hand-typed attr names -> no typos).
    host.querySelectorAll(".fxchip[data-ins]").forEach(function (c) {
      c.addEventListener("click", function () {
        var input = c.closest(".pedit").querySelector('input[data-f="formula"]');
        var ins = c.getAttribute("data-ins");
        input.setRangeText(ins, input.selectionStart, input.selectionEnd, "end");
        input.focus();
        queueValidation(input);
      });
    });

    host.querySelectorAll('input[data-f="formula"]').forEach(function (inp) {
      inp.addEventListener("input", function () { queueValidation(inp); });
      queueValidation(inp);
    });

    host.querySelectorAll("[data-save]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var card = btn.closest(".card");
        var eid = card.getAttribute("data-eid");
        var name = btn.getAttribute("data-save");
        var box = card.querySelector('.pedit[data-pedit="' + name + '"]');
        if (fxValid[eid + "::" + name] === false) {
          error("Fix the formula errors before applying.");
          return;
        }
        // default -> definition, other fields -> meta
        box.querySelectorAll("[data-f]").forEach(function (f) {
          var field = f.getAttribute("data-f");
          if (field === "default") {
            send("setDefault", { entityId: eid, name: name, value: f.value });
          } else {
            send("setMeta", { entityId: eid, name: name, field: field, value: f.value });
          }
        });
      });
    });

    host.querySelectorAll("[data-del]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        if (!confirm("Delete attribute '" + btn.getAttribute("data-del") + "'?")) return;
        var card = btn.closest(".card");
        send("deleteParam", { entityId: card.getAttribute("data-eid"), name: btn.getAttribute("data-del") });
      });
    });

    host.querySelectorAll("[data-addform]").forEach(function (form) {
      form.addEventListener("submit", function (ev) {
        ev.preventDefault();
        var card = form.closest(".card");
        send("addParam", {
          entityId: card.getAttribute("data-eid"),
          name: form.elements.namedItem("name").value,
          label: form.elements.namedItem("label").value,
          access: form.elements.namedItem("access").value,
          value: form.elements.namedItem("value").value
        });
      });
    });
  }

  /* ---------------- formula validation ---------------- */

  // Debounced server-side check: the real parser catches syntax errors and
  // unknown attribute references before they're saved.
  function queueValidation(inp) {
    var box = inp.closest(".pedit");
    var card = inp.closest(".card");
    if (!box || !card) return;
    var eid = card.getAttribute("data-eid");
    var name = box.getAttribute("data-pedit");
    var key = eid + "::" + name;
    clearTimeout(fxTimers[key]);
    var status = box.querySelector(".fxstatus");
    if (status) status.textContent = "";
    if (inp.value.trim() === "") {   // blank = remove formula: always fine
      fxValid[key] = true;
      inp.classList.remove("invalid");
      return;
    }
    fxTimers[key] = setTimeout(function () {
      var req = ++fxReqSeq;
      fxReq[key] = req;
      send("validateFormula", {
        entityId: eid, name: name, formula: inp.value, req: req
      });
    }, 250);
  }

  function onValidation(msg) {
    var key = msg.entityId + "::" + msg.name;
    if (fxReq[key] !== msg.req) return; // stale response
    var card = document.querySelector('.card[data-eid="' + msg.entityId + '"]');
    if (!card) return;
    var box = card.querySelector('.pedit[data-pedit="' + msg.name + '"]');
    if (!box) return;
    var input = box.querySelector('input[data-f="formula"]');
    var status = box.querySelector(".fxstatus");
    fxValid[key] = msg.ok;
    if (input) input.classList.toggle("invalid", !msg.ok);
    var parts = [];
    (msg.errors || []).forEach(function (e) {
      parts.push('<div class="bad">' + esc(e) + "</div>");
    });
    (msg.hints || []).forEach(function (h) {
      parts.push('<div class="hint">' + esc(h) + "</div>");
    });
    if (msg.ok && parts.length === 0) parts.push('<div class="ok">looks good</div>');
    status.innerHTML = parts.join("");
  }

  document.getElementById("search").addEventListener("input", render);
  document.getElementById("btn-refresh").addEventListener("click", function () { send("refresh"); });
  document.getElementById("btn-redraw").addEventListener("click", function () {
    send("redraw", { entityIds: (state.entities || []).map(function (e) { return e.entityId; }) });
  });

  document.addEventListener("DOMContentLoaded", function () { send("ready"); });

  return { update: update, error: error, send: send, onValidation: onValidation };
})();
