// Open DC - modern Dynamic Components for SketchUp
// Copyright (C) 2026 Jure Judež and contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

/* Open DC parameter panel - vanilla JS, talks to Ruby via sketchup.dc(json). */
window.OpenDC = (function () {
  var state = { entities: [], batch: null, dcAvailable: true, globals: [] };
  var configMode = false; // author view: formulas, structure, ordering
  var openAdd = {};   // entityId -> bool
  var openEdit = {};  // entityId::name -> bool (advanced editor expanded)
  var fxTimers = {};  // entityId::name -> debounce timer
  var fxReq = {};     // entityId::name -> last validation request id
  var fxValid = {};   // entityId::name -> last validation ok flag (true/false/undefined)
  var fxReqSeq = 0;
  var entsFolded = true; // multi-select: per-entity cards folded behind a summary
  var openFolds = {};    // entityId::section key -> open (survives re-render)

  // Classic DC _<name>_units vocabulary + display suffixes. DEFAULT is
  // native "End user's model units" - resolved server-side per param.
  var DC_UNITS = ["DEFAULT", "INCHES", "CENTIMETERS", "MILLIMETERS", "METERS", "FEET",
                  "DEGREES", "RADIANS", "DECIMAL", "FLOAT", "INTEGER",
                  "PERCENT", "BOOLEAN", "STRING", "TEXT",
                  "DOLLARS", "EUROS", "YEN"];
  var UNIT_SUFFIX = {
    INCHES: '"', CENTIMETERS: "cm", MILLIMETERS: "mm", METERS: "m",
    FEET: "'", DEGREES: "°", RADIANS: "rad", PERCENT: "%"
  };

  function unitSuffix(p) {
    var u = (p.displayUnits || p.units || "").toUpperCase();
    return UNIT_SUFFIX[u] || "";
  }

  // Formatted display strings (model-units attrs) already carry the unit.
  function paramSuffix(p) {
    return p.displayString ? "" : unitSuffix(p);
  }

  // What a param's value input/label shows: model-format string when the
  // reader produced one (DEFAULT units), else unit-converted number.
  function displayOf(p) {
    if (p.mixed) return "";
    if (p.displayString != null) return p.displayString;
    return p.displayValue != null ? p.displayValue : p.value;
  }

  function defaultOf(p) {
    if (p.displayDefaultString != null) return p.displayDefaultString;
    if (p.displayDefault != null) return p.displayDefault;
    return p["default"];
  }

  function unitSelect(field, cur) {
    var opts = DC_UNITS.slice();
    if (cur && opts.indexOf(cur) === -1) opts.push(cur);
    return '<select data-f="' + field + '">' +
      '<option value="">(none)</option>' +
      opts.map(function (u) {
        var label = u === "DEFAULT" ? "model units" : u;
        return '<option value="' + u + '"' + (u === cur ? " selected" : "") + ">" +
          label + "</option>";
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
      var suf = paramSuffix(p);
      return '<div class="prow">' +
        '<span class="pname" title="' + esc(p.name) + '"><b>' + esc(p.displayName) + '</b></span>' +
        '<span>' + inputFor(p, "batch",
          suf ? ' <span class="pun">' + esc(suf) + '</span>' : "") + '</span>' +
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
    var cards = ents.map(function (e) {
      var cfg = configMode;
      var params = (e.params || []).filter(function (p) {
        // Synthesized SketchUp attrs are configure-view only - they join
        // the main panel once a display rule (fx -> access) adopts them.
        // Driver attrs (name contains "!") live in the foldable sections.
        return p.name.indexOf("!") < 0 && (cfg ? match(p, q)
          : (match(p, q) && p.access !== "NONE" && !p.internal && !p.builtin));
      });
      return '<div class="card" data-eid="' + esc(e.entityId) + '">' +
        '<header>' +
        (cfg
          ? '<input class="cname" data-cname value="' + esc(e.label) + '"' +
            ' title="Component name (writes _name)">'
          : '<span class="name" title="' + esc(e.label) + '">' + esc(e.label) + '</span>') +
        '<span class="badge kind">' + esc(e.kind) + '</span>' +
        '<span class="badge ' + (e.engine === "osdc" ? "osdc" : (e.dynamic === false ? "static" : "")) + '">' +
          (e.engine === "osdc" ? "Open DC" : (e.dynamic === false ? "Static" : "Classic")) + '</span>' +
        (cfg ? '<button class="small ghost-acc" data-graph title="Dependency graph"' +
          ' aria-label="Dependency graph"><i class="modus-icon-graph" aria-hidden="true"></i></button>' : "") +
        (cfg && e.dynamic !== false
          ? (e.engine === "osdc"
            ? '<button class="small danger" data-act="revert" ' +
              'title="Revert this component to classic Dynamic Components">Revert</button>'
            : '<button class="small primary" data-act="convert" ' +
              'title="Convert this component to Open DC">Convert</button>')
          : "") +
        '</header>' +
        '<div class="params">' +
        instNameRow(e) +
        params.map(function (p, i) {
          var sec = p.section || "";
          var hdr = "";
          if (i === 0 || (params[i - 1].section || "") !== sec) {
            // named sections get a labeled divider; a trailing unnamed
            // group gets a bare line so it isn't glued to the last section
            if (sec || (params[i - 1] && params[i - 1].section)) {
              hdr = '<div class="section' + (sec ? "" : " bare") + '"' +
                    (sec ? ' data-sec="' + esc(sec) + '"' : "") + '">' +
                    (cfg && sec
                      ? '<span class="grip secgrip" draggable="true" title="Drag to reorder">⠇</span>' +
                        '<span class="secname" data-secedit title="Click to rename">' + esc(sec) + '</span>' +
                        '<span class="secdel" data-secdel title="Remove divider">&times;</span>'
                      : (sec ? '<span class="secname">' + esc(sec) + '</span>' : "")) +
                    '</div>';
            }
          }
          // built-in SketchUp attributes live under their own labeled
          // divider - read-only section chrome, not an _itemorder marker
          if (p.builtin && !(params[i - 1] && params[i - 1].builtin)) {
            hdr = '<div class="section"><span class="secname">SketchUp</span></div>';
          }
          // Insert-divider strips (configure mode): above the first row
          // when it is unsectioned, and inside contiguous same-section
          // runs - a strip at an existing boundary would only make an
          // empty marker, so it isn't offered there.
          var insTop = cfg && i === 0 && !sec
            ? '<div class="secinsert" data-secins title="Insert a section divider here"></div>' : "";
          var insBot = cfg && i < params.length - 1 &&
            (params[i + 1].section || "") === sec
            ? '<div class="secinsert" data-secins title="Insert a section divider here"></div>' : "";
          return insTop + hdr + renderParam(e, p, cfg) + insBot;
        }).join("") +
        (params.length ? "" : '<div class="prow"><span class="pname">' +
          (e.dynamic === false ? "No attributes yet." : "No parameters.") + '</span></div>') +
        '</div>' +
        (cfg ? skSection(e) + dictsSection(e) : "") +
        (cfg ? addFormHtml(e) : "") +
        '</div>';
    }).join("");

    // Multi-select: the batch editor is the primary UI, so the per-entity
    // cards fold behind a summary bar instead of filling the panel.
    host.innerHTML = ents.length > 1
      ? '<details id="entsfold"' + (entsFolded ? "" : " open") + '>' +
        '<summary><span class="fcount">' + ents.length + '</span> ' +
        'selected components</summary>' +
        '<div class="foldbody">' + cards + '</div></details>'
      : cards;

    var fold = host.querySelector("#entsfold");
    if (fold) {
      fold.addEventListener("toggle", function () { entsFolded = !fold.open; });
    }

    wireEntityCards(host);
  }

  // Pinned row for the SketchUp instance name (Entity Info "Name") -
  // a plain instance property, unlike the DC _name node name edited via
  // the header field in configure mode. Groups have no instance name.
  function instNameRow(e) {
    if (e.kind !== "component") return "";
    return '<div class="prow instname">' +
      '<span class="pname" title="SketchUp instance name (Entity Info) - ' +
      'not the DC _name used for node! references"><b>Instance name</b></span>' +
      '<span><input type="text" data-iname value="' + esc(e.instanceName || "") + '"' +
      ' placeholder="(unnamed)"></span><span></span></div>';
  }

  /* ---------------- foldable native / dictionary sections ---------------- */
  // Live entity properties (sketchup! scope) and foreign attribute
  // dictionaries. Writes go straight to the entity/dict - nothing is
  // stored in the DC dictionary. <details> open state is kept in
  // openFolds so a state push doesn't collapse the sections.

  function foldKey(card, det) {
    var eid = card ? card.getAttribute("data-eid") : "?";
    return eid + "::" + (det.getAttribute("data-fold") || det.getAttribute("data-dg"));
  }

  // One row in the native/dictionary sections. Writable entries may be
  // driven by a formula ("driver" attr stored as <ref>_formula) - shown
  // as an fx button that toggles a lean editor. Read-only rows display
  // and stay referenceable (sketchup!x / dict!key) as formula inputs.
  function secRow(e, ref, label, tip, valueHtml, canFx, driven) {
    var key = e.entityId + "::" + ref;
    var f = driven && driven.formula ? driven.formula : "";
    var err = driven && driven.error
      ? '<div class="err">' + esc(driven.error) + '</div>' : "";
    var fx = canFx
      ? '<button class="small' + (f ? " fx-on" : "") + '" data-edit="' +
        esc(key) + '" data-name="' + esc(ref) + '"' +
        ' title="Drive with a formula' + (f ? " - " + esc(f) : "") + '">fx</button>'
      : "";
    var html = '<div class="prow">' +
      '<span class="pname" title="' + esc(tip) + '"><b>' + esc(label) + '</b>' +
      (f ? ' <span class="formula-hint">fx</span>' : "") + '</span>' +
      '<span>' + valueHtml + '</span>' +
      '<span>' + fx + '</span>' + err + '</div>';
    if (canFx && openEdit[key]) html += secEditorHtml(ref, f);
    return html;
  }

  // Minimal editor for a driver ref (sketchup!prop / dict!key): just the
  // formula. data-pedit carries the ref so the shared [data-save] loop and
  // the live validator handle it like any attribute editor.
  function secEditorHtml(ref, formula) {
    var n = esc(ref);
    return '<div class="pedit" data-pedit="' + n + '">' +
      '<div class="full"><label>formula - drives ' + n +
      ' on every recompute &middot; clear and Apply to stop driving</label>' +
      '<div class="fxedit">' +
      '<div class="fxed" contenteditable="true" spellcheck="false" autocapitalize="off"></div>' +
      '<input type="hidden" data-f="formula" value="' + esc(formula || "") + '">' +
      '<button type="button" class="fxbtn" data-fxdocs ' +
      'title="Function &amp; syntax reference">&#402;(x)</button>' +
      '<button type="button" class="fxbtn" data-fxnodes="' + n + '" ' +
      'title="Edit as node graph"><i class="modus-icon-graph" aria-hidden="true"></i></button>' +
      '<div class="fxlist hidden"></div></div>' +
      '<div class="fxstatus"></div></div>' +
      '<div class="full row-actions">' +
      '<button class="small confirm" data-save="' + n + '" ' +
      'title="Apply this formula">Apply</button>' +
      '</div></div>';
  }

  function skSection(e) {
    var props = e.sketchup || [];
    if (!props.length) return "";
    var osdc = e.engine === "osdc";
    var rows = props.map(function (p) {
      var ref = "sketchup!" + p.name;
      var inp = p.writable
        ? '<input type="text" data-skprop="' + esc(p.name) + '" value="' +
          esc(fmt(p.value)) + '"' + (p.formula ? " disabled" : "") + '>'
        : '<span class="ro">' + esc(fmt(p.value)) + '</span>';
      return secRow(e, ref, p.label, p.tip || ref, inp, osdc && p.writable, p);
    }).join("");
    return '<details class="foldsec sksec" data-fold="sk">' +
      '<summary>SketchUp</summary>' + rows + '</details>';
  }

  function dictsSection(e) {
    var dicts = e.dictionaries || [];
    if (!dicts.length) return "";
    var osdc = e.engine === "osdc";
    var inner = dicts.map(function (d) {
      var rows = d.attrs.map(function (a) {
        var ref = d.name + "!" + a.name;
        var inp = a.writable
          ? '<input type="text" data-dattr="' + esc(a.name) + '" value="' +
            esc(fmt(a.value)) + '"' + (a.formula ? " disabled" : "") + '>'
          : '<span class="ro">' + esc(fmt(a.value)) + '</span>';
        return secRow(e, ref, a.name,
          ref + (a.writable ? "" : " - structured value, read-only"),
          inp, osdc && a.writable, a);
      }).join("");
      return '<details class="dictgroup" data-dg="' + esc(d.name) + '">' +
        '<summary>' + esc(d.name) +
        ' <span class="downer">' + esc(d.owner) + '</span></summary>' +
        rows + '</details>';
    }).join("");
    return '<details class="foldsec dictsec" data-fold="dicts">' +
      '<summary>Attribute dictionaries <span class="fcount">' + dicts.length +
      '</span></summary>' + inner + '</details>';
  }

  function renderParam(e, p, advanced) {
    var id = esc(e.entityId);
    var err = p.error ? '<div class="err">' + esc(p.error) + '</div>' : "";
    var key = id + "::" + p.name;
    var editOpen = openEdit[key] && advanced;
    var suf = paramSuffix(p);
    var pun = suf ? ' <span class="pun">' + esc(suf) + '</span>' : "";
    var grip = advanced && !p.internal && !p.builtin
      ? '<span class="grip" draggable="true" title="Drag to reorder">&#x2807;</span>'
      : "";
    var tip = advanced ? (p.tooltip || p.name) : (p.tooltip || "");
    var html = '<div class="prow' + (p.internal ? " internal" : "") + '"' +
      (p.internal || p.builtin ? "" : ' data-pname="' + esc(p.name) + '"') + '>' +
      '<span class="pname"' + (tip ? ' title="' + esc(tip) + '"' : "") + '>' + grip +
      '<b>' + esc(p.displayName) + '</b>' +
      (p.tooltip ? ' <span class="tipdot">i</span>' : '') +
      (p.internal ? ' <span class="formula-hint">sys</span>' : '') +
      (p.overridden ? ' <span class="formula-hint">*</span>' : '') +
      '</span>' +
      '<span>' + (p.access === "VIEW" || p.internal
        ? '<span class="ro">' + esc(fmt(displayOf(p))) + pun + '</span>'
        : inputFor(p, e.entityId, pun)) + '</span>' +
      '<span>' +
      (advanced && !p.internal
        ? '<button class="small' + (p.formula ? " fx-on" : "") + '" data-edit="' +
          esc(key) + '" data-name="' + esc(p.name) + '"' +
          ' title="Edit attribute' +
          (p.formula ? ' - formula: ' + esc(p.formula) : '') + '">fx</button>'
        : "") +
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
      '<div><label>formlabel</label><input data-f="formlabel" value="' + esc(p.formlabel || "") + '"></div>' +
      '<div><label>id</label><input data-f="label" value="' + esc(p.label || "") + '"></div>' +
      '<div class="full"><label>tooltip - hint shown when hovering the attribute</label>' +
      '<input data-f="tooltip" value="' + esc(p.tooltip || "") + '" ' +
      'placeholder="e.g. Door panel thickness"></div>' +
      '<div class="full"><label>formula</label>' +
      '<div class="fxedit">' +
      '<div class="fxed" contenteditable="true" spellcheck="false" autocapitalize="off"></div>' +
      '<input type="hidden" data-f="formula" value="' + esc(p.formula || "") + '">' +
      '<button type="button" class="fxbtn" data-fxdocs ' +
      'title="Function &amp; syntax reference">&#402;(x)</button>' +
      '<button type="button" class="fxbtn" data-fxnodes="' + n + '" ' +
      'title="Edit as node graph"><i class="modus-icon-graph" aria-hidden="true"></i></button>' +
      '<div class="fxlist hidden"></div></div>' +
      '<div class="fxstatus"></div></div>' +
      '<div><label>default' + (p.formula ? " (formula-driven)" : "") + '</label>' +
      '<span class="uwrap"><input data-f="default" value="' + esc(fmt(defaultOf(p))) + '"' +
      (p.formula ? " disabled" : "") + '>' +
      (paramSuffix(p) ? '<span class="pun">' + esc(paramSuffix(p)) + '</span>' : "") + '</span></div>' +
      '<div><label>display rule</label><select data-f="access">' +
      [["NONE", "hidden"], ["VIEW", "view only"], ["TEXTBOX", "edit"], ["LIST", "list"]]
        .map(function (a) {
          return '<option value="' + a[0] + '"' +
            (p.access === a[0] ? " selected" : "") + '>' + a[1] + '</option>';
        }).join("") + '</select></div>' +
      '<div><label>units</label>' + unitSelect("units", p.units || "") + '</div>' +
      '<div><label>formula units</label>' + unitSelect("formulaunits", p.formulaunits || "") + '</div>' +
      '<div class="full"><label>options - type Label or Label=value, Enter adds it ' +
      '&middot; click a chip to edit, drag to reorder</label>' +
      '<div class="opted" data-opted>' +
      (p.optionsList || []).map(function (o) { return optChipHtml(o.label, o.value); }).join("") +
      '<input class="optin" placeholder="Label=value">' +
      '</div><input type="hidden" data-f="options" value="' + esc(p.options || "") + '"></div>' +
      '<div class="full row-actions">' +
      (p.builtin ? "" : '<button class="small danger" data-del="' + n + '" ' +
        'title="Delete this attribute">Delete</button>') +
      '<button class="small confirm" data-save="' + n + '" ' +
      'title="Apply changes to this attribute">Apply</button>' +
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
      esc(fmt(displayOf(p))) + '"' + data + ph + '>' +
      (pun || "") + '</span>';
  }

  /* ---------------- options tag editor ---------------- */
  // Chips of Label=value with an inline input; serialized to the hidden
  // data-f="options" input as classic `l=v&l=v` on every change.

  function optShow(label, value) {
    return String(value) === String(label) ? label : label + "=" + value;
  }

  function optChipHtml(label, value) {
    return '<span class="optchip" draggable="true" ' +
      'title="Drag to reorder - click the label to edit">' +
      '<span class="optlabel">' + esc(optShow(label, value)) + '</span>' +
      '<button type="button" class="optx" title="Remove option">&times;</button></span>';
  }

  function optSync(box) {
    var pairs = [];
    box.querySelectorAll(".optchip").forEach(function (c) {
      var lab = c.querySelector(".optlabel");
      var ed = c.querySelector(".optedit");
      var t = lab ? lab.textContent : (ed ? ed.value : "");
      if (t.trim()) pairs.push(t.trim());
    });
    box.parentElement.querySelector('input[data-f="options"]').value = pairs.join("&");
  }

  // Commit pending input text as chip(s). Accepts "l", "l=v", or a pasted
  // "l=v&l=v" run. Returns false if nothing valid was committed.
  function optCommit(input) {
    var box = input.closest("[data-opted]");
    var raw = input.value.trim();
    if (raw === "") return false;
    var added = false;
    raw.split("&").forEach(function (part) {
      var t = part.trim();
      if (!t) return;
      var eq = t.indexOf("=");
      var label = eq === -1 ? t : t.slice(0, eq).trim();
      var value = eq === -1 ? t : t.slice(eq + 1).trim();
      if (!label) return;
      input.insertAdjacentHTML("beforebegin", optChipHtml(label, value || label));
      added = true;
    });
    input.value = "";
    if (added) optSync(box);
    return added;
  }

  // Swap a chip's label for an inline input (mirrors the section rename);
  // Enter/blur commits re-normalized "Label" or "Label=value", Escape reverts.
  function optEditStart(box, lab) {
    var cur = lab.textContent;
    var inp = document.createElement("input");
    inp.className = "optedit";
    inp.value = cur;
    inp.size = Math.max(4, cur.length);
    lab.replaceWith(inp);
    inp.focus();
    inp.select();
    function commit(save) {
      if (!inp.parentNode) return;
      var v = inp.value.trim();
      inp.replaceWith(lab);
      if (!save || v === "" || v === cur) return;
      var eq = v.indexOf("=");
      var label = eq === -1 ? v : v.slice(0, eq).trim();
      var value = eq === -1 ? v : v.slice(eq + 1).trim();
      if (!label) return;
      lab.textContent = optShow(label, value || label);
      optSync(box);
    }
    inp.addEventListener("keydown", function (e) {
      if (e.key === "Enter") commit(true);
      else if (e.key === "Escape") commit(false);
      e.stopPropagation();
    });
    inp.addEventListener("blur", function () { commit(true); });
  }

  function clearOptMarks(box) {
    box.querySelectorAll(".optchip.drop-before, .optchip.drop-after").forEach(function (c) {
      c.classList.remove("drop-before", "drop-after");
    });
    box._dropChip = null;
  }

  function wireOptionEditors(host) {
    host.querySelectorAll("[data-opted]").forEach(function (box) {
      var input = box.querySelector(".optin");
      box.addEventListener("mousedown", function (ev) {
        if (ev.target === box) { ev.preventDefault(); input.focus(); }
      });
      input.addEventListener("keydown", function (ev) {
        if (ev.key === "Enter" || ev.key === "Tab") {
          if (optCommit(input)) ev.preventDefault();
        } else if (ev.key === "Backspace" && input.value === "") {
          var last = box.querySelector(".optchip:last-of-type");
          if (last) { last.remove(); optSync(box); }
        } else if (ev.key === "Escape") {
          input.value = "";
        }
      });
      input.addEventListener("blur", function () { optCommit(input); });
      // delegated so chips added later are covered too
      box.addEventListener("click", function (ev) {
        var lab = ev.target.closest(".optlabel");
        if (lab) { optEditStart(box, lab); return; }
        if (ev.target.closest(".optx")) {
          ev.target.closest(".optchip").remove();
          optSync(box);
        }
      });
      // horizontal drag-reorder inside this chip list (like .grip on rows);
      // stopPropagation keeps the .params row-drag handlers out of it
      box.addEventListener("dragstart", function (ev) {
        var chip = ev.target.closest(".optchip");
        if (!chip || !box.contains(chip)) return;
        ev.dataTransfer.effectAllowed = "move";
        ev.dataTransfer.setData("text/plain", chip.textContent.trim());
        ev.dataTransfer.setDragImage(chip, 8, 8);
        chip.classList.add("dragging");
      });
      box.addEventListener("dragover", function (ev) {
        if (!box.querySelector(".optchip.dragging")) return;
        ev.preventDefault();
        ev.stopPropagation();
        ev.dataTransfer.dropEffect = "move";
        clearOptMarks(box);
        var chip = ev.target.closest(".optchip");
        if (chip && !chip.classList.contains("dragging")) {
          var r = chip.getBoundingClientRect();
          var before = ev.clientX < r.left + r.width / 2;
          chip.classList.add(before ? "drop-before" : "drop-after");
          box._dropChip = chip;
          box._dropBefore = before;
        }
      });
      box.addEventListener("drop", function (ev) {
        var src = box.querySelector(".optchip.dragging");
        if (!src) return;
        ev.preventDefault();
        ev.stopPropagation();
        var dst = box._dropChip;
        if (dst && src !== dst) {
          box.insertBefore(src, box._dropBefore ? dst : dst.nextSibling);
        } else if (!dst) {
          box.insertBefore(src, input); // open space drops at the end
        }
        optSync(box);
        clearOptMarks(box);
      });
      box.addEventListener("dragend", function () {
        box.querySelectorAll(".optchip.dragging").forEach(function (c) {
          c.classList.remove("dragging");
        });
        clearOptMarks(box);
      });
    });
  }

  function addFormHtml(e) {
    var id = esc(e.entityId);
    if (openAdd[e.entityId]) {
      return '<form class="addform" data-addform="' + id + '">' +
        '<input name="name" placeholder="name (no spaces)" required>' +
        '<input name="label" placeholder="id">' +
        '<select name="access" title="display rule: where the attribute appears - edit: free input · list: dropdown of options · view only: read-only · hidden: not shown">' +
        '<option value="TEXTBOX">edit</option><option value="LIST">list</option>' +
        '<option value="VIEW">view only</option><option value="NONE">hidden</option></select>' +
        '<input name="value" placeholder="default value">' +
        '<button type="submit" class="primary" title="Add the attribute">Add</button>' +
        '<button type="button" class="small" data-addcancel="' + id + '" ' +
        'title="Cancel without adding">✕</button></form>';
    }
    return '<div class="addrow"><button class="addbtn" data-add="' + id + '" ' +
      'title="Add a new attribute to this component">+ Add attribute</button></div>';
  }

  /* ---------------- events ---------------- */

  function wireEntityCards(host) {
    host.querySelectorAll("[data-act]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var card = btn.closest(".card");
        send(btn.getAttribute("data-act"), { entityId: card.getAttribute("data-eid") });
      });
    });

    host.querySelectorAll("[data-cname]").forEach(function (inp) {
      inp.addEventListener("change", function () {
        var card = inp.closest(".card");
        send("rename", { entityId: card.getAttribute("data-eid"), name: inp.value });
      });
    });

    host.querySelectorAll("[data-graph]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        send("graph", { entityId: btn.closest(".card").getAttribute("data-eid") });
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

    host.querySelectorAll("input[data-iname]").forEach(function (inp) {
      inp.addEventListener("change", function () {
        var card = inp.closest(".card");
        send("setInstName", {
          entityId: card.getAttribute("data-eid"),
          name: inp.value
        });
      });
    });

    // Native SketchUp properties (sketchup! scope) - write-through edits.
    host.querySelectorAll("input[data-skprop]").forEach(function (inp) {
      inp.addEventListener("change", function () {
        send("setEntityProp", {
          entityId: inp.closest(".card").getAttribute("data-eid"),
          name: inp.getAttribute("data-skprop"),
          value: inp.value
        });
      });
    });

    // Foreign-dictionary scalar keys - write back to the owning dict.
    host.querySelectorAll("input[data-dattr]").forEach(function (inp) {
      inp.addEventListener("change", function () {
        send("setDictAttr", {
          entityId: inp.closest(".card").getAttribute("data-eid"),
          dict: inp.closest(".dictgroup").getAttribute("data-dg"),
          name: inp.getAttribute("data-dattr"),
          value: inp.value
        });
      });
    });

    // <details> open state survives re-render (state pushes rebuild the DOM).
    host.querySelectorAll(".foldsec, .dictgroup").forEach(function (det) {
      var k = foldKey(det.closest(".card"), det);
      if (openFolds[k]) det.open = true;
      det.addEventListener("toggle", function () { openFolds[k] = det.open; });
    });

    host.querySelectorAll("[data-add]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        openAdd[btn.getAttribute("data-add")] = true;
        render();
      });
    });

    host.querySelectorAll("[data-addcancel]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        delete openAdd[btn.getAttribute("data-addcancel")];
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

    host.querySelectorAll("[data-fxnodes]").forEach(function (b) {
      b.addEventListener("click", function () {
        send("nodes", {
          entityId: b.closest(".card").getAttribute("data-eid"),
          name: b.getAttribute("data-fxnodes")
        });
      });
    });

    wireOptionEditors(host);

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

    wireReorder(host);
  }

  /* ---------------- attribute reorder (configure mode) ---------------- */
  // Drag the grip to reorder rows; on drop the visible sequence
  // (names + &Title& markers) is stored as _itemorder.
  function orderTokens(box) {
    var toks = [];
    box.querySelectorAll(".section, .prow[data-pname]").forEach(function (el) {
      if (el.classList.contains("section")) {
        // bare trailing-group dividers carry no marker - skipping them
        // also avoids writing "&null&" into _itemorder
        var s = el.getAttribute("data-sec");
        if (s) toks.push("&" + s + "&");
      } else {
        toks.push(el.getAttribute("data-pname"));
      }
    });
    return toks;
  }

  function clearDropMarks(box) {
    box.querySelectorAll(".prow.drop-before, .prow.drop-after").forEach(function (r) {
      r.classList.remove("drop-before", "drop-after");
    });
    box._dropRow = null;
  }

  function wireReorder(host) {
    host.querySelectorAll(".grip").forEach(function (g) {
      var row = g.closest(".prow, .section");
      g.addEventListener("dragstart", function (ev) {
        ev.dataTransfer.effectAllowed = "move";
        ev.dataTransfer.setData("text/plain",
          row.getAttribute("data-pname") || "&section&");
        ev.dataTransfer.setDragImage(row, 12, 12);
        row.classList.add("dragging");
      });
    });
    host.querySelectorAll(".params").forEach(function (box) {
      box.addEventListener("dragover", function (ev) {
        var row = ev.target.closest(".prow[data-pname]");
        if (!row || row.classList.contains("dragging")) return;
        if (!box.querySelector(".prow.dragging, .section.dragging")) return;
        ev.preventDefault();
        ev.dataTransfer.dropEffect = "move";
        var r = row.getBoundingClientRect();
        var before = ev.clientY < r.top + r.height / 2;
        clearDropMarks(box);
        row.classList.add(before ? "drop-before" : "drop-after");
        box._dropRow = row;
        box._dropBefore = before;
      });
      box.addEventListener("drop", function (ev) {
        ev.preventDefault();
        var src = box.querySelector(".prow.dragging, .section.dragging");
        var dst = box._dropRow;
        if (src && dst && src !== dst) {
          box.insertBefore(src, box._dropBefore ? dst : dst.nextSibling);
          send("reorder", {
            entityId: box.closest(".card").getAttribute("data-eid"),
            order: orderTokens(box)
          });
        }
        clearDropMarks(box);
      });
      box.addEventListener("dragend", function () {
        box.querySelectorAll(".dragging").forEach(function (r) {
          r.classList.remove("dragging");
        });
        clearDropMarks(box);
      });
    });

    // --- divider editing: insert / rename / delete ----------------------
    host.querySelectorAll("[data-secins]").forEach(function (strip) {
      strip.addEventListener("click", function () {
        var sec = document.createElement("div");
        sec.className = "section";
        sec.setAttribute("data-sec", "New section");
        sec.innerHTML = '<span class="secname">New section</span>';
        strip.parentNode.insertBefore(sec, strip.nextSibling);
        send("reorder", {
          entityId: strip.closest(".card").getAttribute("data-eid"),
          order: orderTokens(strip.parentNode)
        });
      });
    });

    host.querySelectorAll("[data-secdel]").forEach(function (x) {
      x.addEventListener("click", function () {
        var sec = x.closest(".section");
        var box = sec.parentNode;
        sec.remove();
        send("reorder", {
          entityId: box.closest(".card").getAttribute("data-eid"),
          order: orderTokens(box)
        });
      });
    });

    host.querySelectorAll("[data-secedit]").forEach(function (span) {
      span.addEventListener("click", function () {
        var sec = span.closest(".section");
        var cur = sec.getAttribute("data-sec");
        var inp = document.createElement("input");
        inp.className = "secinput";
        inp.value = cur;
        span.replaceWith(inp);
        inp.focus();
        inp.select();
        function commit() {
          var v = inp.value.trim().replace(/[&,]/g, "");
          inp.replaceWith(span);
          if (v && v !== cur) {
            sec.setAttribute("data-sec", v);
            span.textContent = v;
            send("reorder", {
              entityId: sec.closest(".card").getAttribute("data-eid"),
              order: orderTokens(sec.parentNode)
            });
          }
        }
        inp.addEventListener("keydown", function (e) {
          if (e.key === "Enter") inp.blur();
          if (e.key === "Escape") { inp.value = cur; inp.blur(); }
        });
        inp.addEventListener("blur", commit);
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
      .filter(function (p) { return !p.internal && p.name.indexOf("!") < 0; })
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
      var pool;
      if (scope === "global") {
        pool = (state.globals || []).map(function (g) {
          return { label: g.name, insert: g.name, kind: "glob" };
        });
      } else if (scope === "sketchup") {
        pool = (state.skprops || []).map(function (n) {
          return { label: n, insert: n, kind: "skp" };
        });
      } else if (scope === "model") {
        pool = (state.modelprops || []).map(function (n) {
          return { label: n, insert: n, kind: "skp" };
        });
      } else if (scope === "scene") {
        pool = (state.sceneprops || []).map(function (n) {
          return { label: n, insert: n, kind: "skp" };
        });
      } else {
        var dd = (e.dictionaries || []).find(function (d) {
          return d.name.toLowerCase() === scope;
        });
        pool = dd
          ? dd.attrs
              .filter(function (a) { return /^[a-z_][a-z0-9_]*$/i.test(a.name); })
              .map(function (a) { return { label: a.name, insert: a.name, kind: "dict" }; })
          : attrItems.slice();
      }
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
    (state.skprops || []).forEach(function (n) {
      items.push({ label: "sketchup!" + n, insert: "sketchup!" + n, kind: "skp" });
    });
    (state.modelprops || []).forEach(function (n) {
      items.push({ label: "model!" + n, insert: "model!" + n, kind: "skp" });
    });
    (state.sceneprops || []).forEach(function (n) {
      items.push({ label: "scene!" + n, insert: "scene!" + n, kind: "skp" });
    });
    (e.dictionaries || []).forEach(function (d) {
      if (!/^[a-z_][a-z0-9_]*$/i.test(d.name)) return;
      d.attrs.forEach(function (a) {
        if (/^[a-z_][a-z0-9_]*$/i.test(a.name)) {
          items.push({ label: d.name + "!" + a.name,
                       insert: d.name + "!" + a.name, kind: "dict" });
        }
      });
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
  document.getElementById("btn-config").addEventListener("click", function () {
    configMode = !configMode;
    this.classList.toggle("on", configMode);
    render();
  });
  document.getElementById("btn-refresh").addEventListener("click", function () { send("refresh"); });
  document.getElementById("btn-redraw").addEventListener("click", function () {
    send("redraw", { entityIds: (state.entities || [])
      .filter(function (e) { return e.dynamic !== false; })
      .map(function (e) { return e.entityId; }) });
  });

  document.addEventListener("DOMContentLoaded", function () { send("ready"); });

  return { update: update, error: error, send: send, onValidation: onValidation };
})();
