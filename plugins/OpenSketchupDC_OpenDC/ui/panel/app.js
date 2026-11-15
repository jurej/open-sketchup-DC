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

  // Classic DC _<name>_units vocabulary + display suffixes.
  var DC_UNITS = ["INCHES", "CENTIMETERS", "MILLIMETERS", "METERS", "FEET",
                  "DEGREES", "RADIANS", "DECIMAL", "FLOAT", "INTEGER",
                  "PERCENT", "BOOLEAN", "STRING", "TEXT",
                  "DOLLARS", "EUROS", "YEN"];
  var UNIT_SUFFIX = {
    INCHES: '"', CENTIMETERS: "cm", MILLIMETERS: "mm", METERS: "m",
    FEET: "'", DEGREES: "°", RADIANS: "rad", PERCENT: "%"
  };

  function unitSuffix(p) {
    return UNIT_SUFFIX[(p.units || "").toUpperCase()] || "";
  }

  function unitSelect(field, cur) {
    var opts = DC_UNITS.slice();
    if (cur && opts.indexOf(cur) === -1) opts.push(cur);
    return '<select data-f="' + field + '">' +
      '<option value="">(none)</option>' +
      opts.map(function (u) {
        return '<option' + (u === cur ? " selected" : "") + ">" + u + "</option>";
      }).join("") + "</select>";
  }

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
        '<span>' + inputFor(p, "batch",
          unitSuffix(p) ? ' <span class="pun">' + esc(unitSuffix(p)) + '</span>' : "") + '</span>' +
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
    var suf = unitSuffix(p);
    var pun = suf ? ' <span class="pun">' + esc(suf) + '</span>' : "";
    var html = '<div class="prow' + (p.internal ? " internal" : "") + '">' +
      '<span class="pname" title="' + esc(p.name) + '"><b>' + esc(p.displayName) + '</b>' +
      (p.internal ? ' <span class="formula-hint">sys</span>' : '') +
      (p.overridden ? ' <span class="formula-hint">*</span>' : '') +
      '</span>' +
      '<span>' + (p.access === "VIEW" || p.internal
        ? '<span class="ro">' + esc(fmt(p.displayValue != null ? p.displayValue : p.value)) + pun + '</span>'
        : inputFor(p, e.entityId, pun)) + '</span>' +
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

  function editorHtml(entityId, p) {
    var e = (state.entities || []).find(function (x) { return x.entityId === entityId; }) || { params: [] };
    var id = esc(entityId);
    var n = esc(p.name);
    return '<div class="pedit" data-pedit="' + n + '">' +
      '<div class="full"><label>formula <button type="button" class="fxdocs" ' +
      'data-fxdocs title="Function &amp; syntax reference">&#402;(x)</button></label>' +
      '<div class="fxedit">' +
      '<div class="fxed" contenteditable="true" spellcheck="false" autocapitalize="off"></div>' +
      '<input type="hidden" data-f="formula" value="' + esc(p.formula || "") + '">' +
      '<div class="fxlist hidden"></div></div>' +
      '<div class="fxstatus"></div></div>' +
      '<div><label>default' + (p.formula ? " (formula-driven)" : "") + '</label>' +
      '<span class="uwrap"><input data-f="default" value="' + esc(fmt(p["default"])) + '"' +
      (p.formula ? " disabled" : "") + '>' +
      (unitSuffix(p) ? '<span class="pun">' + esc(unitSuffix(p)) + '</span>' : "") + '</span></div>' +
      '<div><label>access</label><select data-f="access">' +
      ["NONE", "VIEW", "TEXTBOX", "LIST"].map(function (a) {
        return '<option' + (p.access === a ? " selected" : "") + '>' + a + '</option>';
      }).join("") + '</select></div>' +
      '<div><label>units</label>' + unitSelect("units", p.units || "") + '</div>' +
      '<div><label>formula units</label>' + unitSelect("formulaunits", p.formulaunits || "") + '</div>' +
      '<div class="full"><label>options (Label=value&amp;…)</label><input data-f="options" value="' + esc(p.options || "") + '"></div>' +
      '<div><label>formlabel</label><input data-f="formlabel" value="' + esc(p.formlabel || "") + '"></div>' +
      '<div><label>label</label><input data-f="label" value="' + esc(p.label || "") + '"></div>' +
      '<div class="full row-actions">' +
      '<button class="small" data-del="' + n + '">Delete</button>' +
      '<button class="small primary" data-save="' + n + '">Apply</button>' +
      '</div>' +
      '</div>';
  }

  function inputFor(p, entityId, pun) {
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
    return '<span class="uwrap"><input type="text" value="' +
      esc(fmt(p.displayValue != null ? p.displayValue : p.value)) + '"' + data + ph + '>' +
      (pun || "") + '</span>';
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

    host.querySelectorAll("[data-fxdocs]").forEach(function (b) {
      b.addEventListener("click", function () { send("fxDocs"); });
    });

    host.querySelectorAll(".fxed").forEach(function (ed) {
      var hidden = ed.closest(".fxedit").querySelector('input[data-f="formula"]');
      fxRender(ed, hidden.value, fxKnown(ed.closest(".card")));
      ed.addEventListener("input", function () { fxSync(ed); });
      ed.addEventListener("keydown", function (ev) {
        if (fxKeyNav(ed, ev)) return;
        if (ev.key === "Enter") ev.preventDefault(); // formulas are single-line
      });
      ed.addEventListener("paste", function (ev) {
        ev.preventDefault();
        var t = (ev.clipboardData || window.clipboardData).getData("text/plain") || "";
        t = t.replace(/[\r\n]+/g, " ");
        if (!document.execCommand("insertText", false, t)) {
          var sel = window.getSelection();
          if (sel.rangeCount && ed.contains(sel.anchorNode)) {
            var r = sel.getRangeAt(0), tn = document.createTextNode(t);
            r.deleteContents();
            r.insertNode(tn);
            fxCaretAfter(tn);
          } else {
            ed.appendChild(document.createTextNode(t));
          }
          fxSync(ed);
        }
      });
      ed.addEventListener("blur", function () {
        var box = ed.closest(".fxedit");
        setTimeout(function () { fxClose(box); }, 150);
      });
      queueValidation(hidden);
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
          if (f.disabled) return;
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

  /* ---------------- formula pill editor (contenteditable) ---------------- */
  // The fxed div holds a mix of plain text nodes and non-editable pill
  // spans; a hidden input carries the serialized formula for Apply and
  // server-side validation.

  var FX_KEYWORDS = { TRUE: 1, FALSE: 1, AND: 1, OR: 1, NOT: 1 };
  var fxSel = 0;    // selected index in the open suggestion list
  var fxItems = []; // current suggestions {label, insert, kind}
  var fxRes = null; // caret context of the open suggestion list

  // Function whitelist from the real parser (state.functions / .actions).
  function fxFnKind(name) {
    var up = name.toUpperCase();
    if ((state.functions || []).indexOf(up) !== -1) return "fn";
    if ((state.actions || []).indexOf(up) !== -1) return "act";
    return null;
  }

  function fxEntity(card) {
    var eid = card.getAttribute("data-eid");
    return (state.entities || []).find(function (x) { return x.entityId === eid; }) || { params: [] };
  }

  function fxKnown(card) {
    var e = fxEntity(card);
    var k = {};
    ((e && e.params) || []).forEach(function (p) { k[p.name] = true; });
    // built-in DC attrs are valid references on every DC
    (state.builtins || []).forEach(function (b) { k[b.toLowerCase()] = true; });
    if (k.copies) k.copy = true;
    return k;
  }

  function fxPillEl(kind, tok) {
    var s = document.createElement("span");
    s.className = "fxpill " + kind;
    s.setAttribute("contenteditable", "false");
    s.setAttribute("data-tok", tok);
    s.textContent = tok;
    return s;
  }

  // Tokenize a formula string into text / attr-pill / ref-pill segments.
  // Mirrors the Ruby lexer: " opens strings, ' only follows digits (feet).
  function fxTokens(src, known) {
    var segs = [], i = 0, n = src.length;
    function push(t, s) {
      var last = segs[segs.length - 1];
      if (t === "text" && last && last.t === "text") last.s += s;
      else if (s !== "") segs.push({ t: t, s: s });
    }
    while (i < n) {
      var c = src[i];
      if (/[\d.]/.test(c)) {
        var nm = /^[\d.]+[A-Za-z"']*/.exec(src.slice(i));
        push("text", nm[0]);
        i += nm[0].length;
        continue;
      }
      if (c === '"') {
        var j = i + 1;
        while (j < n && src[j] !== '"') j++;
        push("text", src.slice(i, Math.min(j + 1, n)));
        i = j + (j < n ? 1 : 0);
        continue;
      }
      var m = /^[A-Za-z_][A-Za-z0-9_]*(!\s*[A-Za-z_][A-Za-z0-9_]*)?/.exec(src.slice(i));
      if (m) {
        var tok = m[0];
        if (tok.indexOf("!") !== -1) {
          push("ref", tok.replace(/\s+/g, ""));
        } else if (/^\s*\(/.test(src.slice(i + tok.length))) {
          var fk = fxFnKind(tok);
          push(fk || "text", tok); // known function -> pill; unknown -> text (validation flags it)
        } else if (FX_KEYWORDS[tok.toUpperCase()]) {
          push("kw", tok);
        } else if (known[tok.toLowerCase()]) {
          push("attr", tok);
        } else {
          push("text", tok); // unknown identifier - plain; validation flags it
        }
        i += tok.length;
        continue;
      }
      push("text", c);
      i++;
    }
    return segs;
  }

  function fxRender(ed, src, known) {
    ed.innerHTML = "";
    fxTokens(src, known).forEach(function (seg) {
      ed.appendChild(seg.t === "text" ? document.createTextNode(seg.s) : fxPillEl(seg.t, seg.s));
    });
  }

  // Insert an element at the caret (or at the end when unfocused), then
  // place the caret after it - or at `innerOffset` inside a trailing text
  // node (function templates put the caret inside the parens).
  function fxInsertAtCaret(ed, nodes, innerOffset) {
    var last = nodes[nodes.length - 1];
    var sel = window.getSelection();
    if (sel.rangeCount && ed.contains(sel.anchorNode)) {
      var r = sel.getRangeAt(0);
      r.deleteContents();
      nodes.forEach(function (n) { r.insertNode(n); });
      if (innerOffset != null && last.nodeType === 3) {
        r.setStart(last, innerOffset);
        r.collapse(true);
        sel.removeAllRanges();
        sel.addRange(r);
      } else {
        fxCaretAfter(last);
      }
    } else {
      nodes.forEach(function (n) { ed.appendChild(n); });
    }
    fxSync(ed);
  }

  // Split "NAME(args)" into a function pill + argument text so the caret
  // lands inside the parens ready to type arguments.
  function fxFnNodes(template) {
    var p = template.indexOf("(");
    var kind = fxFnKind(template.slice(0, p)) || "fn";
    return [fxPillEl(kind, template.slice(0, p)), document.createTextNode(template.slice(p))];
  }

  function fxSerialize(ed) {
    var out = "";
    ed.childNodes.forEach(function (nd) {
      if (nd.nodeType === 3) out += nd.nodeValue;
      else if (nd.nodeType === 1) {
        out += nd.classList.contains("fxpill") ? nd.getAttribute("data-tok") : nd.textContent;
      }
    });
    return out.replace(/ /g, " ");
  }

  function fxHidden(ed) {
    return ed.closest(".fxedit").querySelector('input[data-f="formula"]');
  }

  function fxSync(ed) {
    var hidden = fxHidden(ed);
    hidden.value = fxSerialize(ed);
    fxShow(ed, fxCandidates(ed));
    queueValidation(hidden);
  }

  // Text before the caret inside the current text node. Tokens cannot span
  // pills, so the containing text node holds the whole fragment.
  function fxCaretText(ed) {
    var sel = window.getSelection();
    if (!sel.rangeCount || !ed.contains(sel.anchorNode)) return null;
    var nd = sel.anchorNode, off = sel.anchorOffset;
    if (nd.nodeType === 3) return { node: nd, upto: nd.nodeValue.slice(0, off) };
    if (nd === ed) {
      var k = off - 1;
      while (k >= 0 && ed.childNodes[k].nodeType !== 3) k--;
      if (k < 0) return null;
      return { node: ed.childNodes[k], upto: ed.childNodes[k].nodeValue };
    }
    return null;
  }

  // Candidate source for the token under the caret. A "scope!" prefix
  // switches the dictionary: global! -> model globals, parent!/node! ->
  // same-name attrs (best-effort; the panel can't see the parent context).
  function fxCandidates(ed) {
    var empty = { items: [], frag: "", scope: null, node: null, upto: "" };
    var ctx = fxCaretText(ed);
    if (!ctx) return empty;
    var upto = ctx.upto;
    var m = /[A-Za-z_][A-Za-z0-9_]*$/.exec(upto);
    var sm = /([A-Za-z_][A-Za-z0-9_]*)!([A-Za-z_][A-Za-z0-9_]*)?$/.exec(upto);
    var e = fxEntity(ed.closest(".card"));
    var attrItems = (e.params || [])
      .filter(function (p) { return !p.internal; })
      .map(function (p) { return { label: p.name, insert: p.name, kind: "attr" }; });
    var seen = {};
    attrItems.forEach(function (i) { seen[i.insert.toLowerCase()] = true; });
    (state.builtins || []).forEach(function (b) {
      if (!seen[b.toLowerCase()]) {
        attrItems.push({ label: b, insert: b, kind: "attr" });
        seen[b.toLowerCase()] = true;
      }
    });

    if (sm) {
      var scope = sm[1].toLowerCase(), frag = (sm[2] || "").toLowerCase();
      var pool = scope === "global"
        ? (state.globals || []).map(function (g) { return { label: g.name, insert: g.name, kind: "glob" }; })
        : attrItems.slice();
      return { items: pool.filter(function (i) { return i.label.toLowerCase().indexOf(frag) === 0; }),
               frag: frag, scope: scope, node: ctx.node, upto: upto };
    }

    var frag = m ? m[0] : "";
    if (frag === "") return empty;
    var low = frag.toLowerCase();
    var items = attrItems;
    (state.globals || []).forEach(function (g) {
      items.push({ label: "global!" + g.name, insert: "global!" + g.name, kind: "glob" });
    });
    (state.functions || []).forEach(function (n) {
      items.push({ label: n + "()", insert: n + "(", kind: "fn" });
    });
    var box = ed.closest(".pedit");
    if (box && box.getAttribute("data-pedit") === "onclick") {
      (state.actions || []).forEach(function (n) {
        items.push({ label: n + "()", insert: n + "(", kind: "act" });
      });
    }
    if ((e.params || []).some(function (p) { return p.name === "copies"; }))
      items.push({ label: "copy", insert: "copy", kind: "attr" });
    return { items: items.filter(function (i) { return i.label.toLowerCase().indexOf(low) === 0; }),
             frag: frag, scope: null, node: ctx.node, upto: upto };
  }

  function fxClose(box) {
    var list = box && box.querySelector(".fxlist");
    if (list) list.classList.add("hidden");
    fxItems = [];
    fxRes = null;
  }

  function fxShow(ed, res) {
    var box = ed.closest(".fxedit");
    var list = box.querySelector(".fxlist");
    if (!res.items.length) { fxClose(box); return; }
    fxItems = res.items.slice(0, 9);
    fxRes = res;
    fxSel = 0;
    list.innerHTML = fxItems.map(function (i, k) {
      return '<div class="fxitem" data-i="' + k + '">' +
        '<span class="fxkind ' + i.kind + '">' + i.kind + '</span>' +
        '<span class="fxlabel">' + esc(i.label) + "</span></div>";
    }).join("");
    list.querySelectorAll(".fxitem").forEach(function (it) {
      it.addEventListener("mousedown", function (ev) {
        ev.preventDefault();
        fxAccept(ed, fxItems[+it.getAttribute("data-i")]);
      });
    });
    list.classList.remove("hidden");
    paintFxSel(list);
  }

  function paintFxSel(list) {
    list.querySelectorAll(".fxitem").forEach(function (it, k) {
      it.classList.toggle("sel", k === fxSel);
    });
    var sel = list.querySelector(".fxitem.sel");
    if (sel) sel.scrollIntoView({ block: "nearest" });
  }

  function fxCaretAfter(node) {
    var r = document.createRange();
    r.setStartAfter(node);
    r.collapse(true);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
  }

  // Replace the token/fragment under the caret with a pill (attrs, refs)
  // or text (function/action templates).
  function fxAccept(ed, item) {
    var res = fxRes;
    if (!res || !res.node || !res.node.parentNode) { fxClose(ed.closest(".fxedit")); return; }
    var drop = res.frag.length + (res.scope ? res.scope.length + 1 : 0);
    var r = document.createRange();
    r.setStart(res.node, res.upto.length - drop);
    r.setEnd(res.node, res.upto.length);
    r.deleteContents();
    if (item.kind === "fn" || item.kind === "act") {
      var nodes = fxFnNodes(item.insert);
      nodes.forEach(function (n) { r.insertNode(n); });
      var tnode = nodes[nodes.length - 1];
      var nr = document.createRange();
      nr.setStart(tnode, 1); // caret just inside "(..." of the template
      nr.collapse(true);
      var sel2 = window.getSelection();
      sel2.removeAllRanges();
      sel2.addRange(nr);
    } else {
      var node = (item.kind === "attr")
        ? fxPillEl("attr", item.insert)
        : fxPillEl("ref", res.scope ? res.scope + "!" + item.insert : item.insert);
      r.insertNode(node);
      fxCaretAfter(node);
    }
    fxSync(ed);
  }

  function fxKeyNav(ed, ev) {
    var box = ed.closest(".fxedit");
    var list = box && box.querySelector(".fxlist");
    if (!list || list.classList.contains("hidden")) return false;
    if (ev.key === "ArrowDown") { fxSel = Math.min(fxSel + 1, fxItems.length - 1); paintFxSel(list); }
    else if (ev.key === "ArrowUp") { fxSel = Math.max(fxSel - 1, 0); paintFxSel(list); }
    else if (ev.key === "Enter" || ev.key === "Tab") { fxAccept(ed, fxItems[fxSel]); }
    else if (ev.key === "Escape") { fxClose(box); }
    else return false;
    ev.preventDefault();
    return true;
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
      var ed0 = inp.closest(".fxedit") && inp.closest(".fxedit").querySelector(".fxed");
      (ed0 || inp).classList.remove("invalid");
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
    var ed = box.querySelector(".fxed");
    if (ed) ed.classList.toggle("invalid", !msg.ok);
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
