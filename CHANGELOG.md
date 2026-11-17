# Changelog

## Unreleased

### Attributes beyond the parameter list

- **Native SketchUp properties** as attributes: `sketchup!name`,
  `sketchup!instname`, `sketchup!layer`, `sketchup!description`,
  `sketchup!summary`/`itemcode`/`creator` (writable) and
  `sketchup!guid`/`persistentid`/`entityid`/`typename`/`instances`
  (read-only inputs).
- **Foreign attribute dictionaries**: every other dictionary on the
  entity is readable via `dictname!key` or `DICTATTR("dict","key")`.
  Enumerated from the entity — pick, don't type.
- **Driver formulas** (Open DC engine): attach fx to any writable
  `sketchup!` prop or foreign dict key and every recompute writes the
  value back to SketchUp (rename the definition, drive
  `su_instanceset!price`, tag by formula). Broken drivers stop applying
  and flag `apply:` errors instead of rewriting stale caches.
- **Read-only input scopes** `model!` (name/title/path/units/lat/lng/
  north angle/georeferenced/scene count) and `scene!` (active scene
  name/description/times) — usable in formulas and as node-editor inputs.
- Panel: foldable **SketchUp** and **Attribute dictionaries** sections in
  Configure mode only; the Options view stays clean. Autocomplete and
  both node editors gained `sketchup!`/`dict`/`model!`/`scene!` entries.
- **`root!name` scope**: reads the outermost osdc component's attribute
  at any nesting depth — the multi-level answer to one-level `parent!`.
  Reads the root's freshly computed value; at top level it's a valid
  self-reference. Reserved scope, osdc-only.
- **Globals section** (Configure mode): add/edit/delete model-level
  `global!name` parameters — previously console-only. Writes mark all
  osdc components dirty so dependents recompute immediately.
- **Scene graph** (▦ toolbar button, works with no selection): every
  top-level osdc component as a node with per-attribute in/out slots.
  Drag `attr → attr` across nodes to write `name!attr` (or `global!attr`
  from the Globals pseudo-node) into the target's formula; click a link
  to unlink back to a literal; double-click a node to dive into that
  component's dependency graph. Layout + groups persist like the
  per-entity graph.
- **Expression stencils** (both graph modes): right-click canvas →
  "Expression" gives the full formula palette (operators, literals,
  attributes, functions). A pick seeds a scratch subgraph node — dive
  in to compose, inputs auto-link to same-named attrs, and wiring its
  output to a param applies the composed formula (cross-entity in
  scene mode). Stencils persist as canvas state; Del removes them.
- **Compact scene nodes**: builtins hide unless they carry a formula
  or an edge endpoint. Right-click a node → "Show all attributes (N
  hidden)" to expand; the choice persists per node.
- **Fold nodes into subgraphs** (both graph modes): select nodes,
  right-click canvas → "Fold N nodes into subgraph". Members collapse
  into a proxy node and boundary edges rewire through its slots —
  double-click or right-click → "Open subgraph" to see inside, "Unfold"
  (menu or Del) to restore. Folded interiors stay live: they rebuild
  from current formulas on every push. Clicking a node's titlebar now
  also toggles litegraph's collapsed state.

### Fixes

- Plain components/groups convert to Open DC directly — no pre-existing
  attribute needed (`_engine` + nominal dims seeded on conversion).
- Scaling/moving/rotating a component recomputes dependents: observers
  now map the entity itself to its Open DC target, and `lenx/y/z` use
  real `transformation.x/y/zscale` (axis vectors are normalized — their
  `.length` was always 1). Identical transform writes are skipped so
  applies can't loop.
- `sketchup!layer` with an unknown tag name falls back to
  Layer0/Untagged.
- `onClick`, `copies`, `copy`, `scaletool` appear as real attribute rows
  (fx-editable); `onClick` validates with action functions and stays out
  of value evaluation.
- Dependency graph includes formula-less parameters and builtins as
  nodes — wiring a dependency into one writes + adopts the formula.
- `_<attr>_error` clears on the first good eval — a recovered formula no
  longer keeps a phantom error flag in the panel (`apply:` driver errors
  remain owned by the apply pass). Typing `parent!`/`root!`/`global!`
  into the fx field now offers the scope prefixes in autocomplete.
- `global!` validation on a classic component checked the model's
  `dynamic_attributes` instead of `open_dc` and skipped the osdc-only
  warning — both fixed.

## v0.1.1 — beta 1.1

- **Right-click context menu**: an *Open DC* submenu (Parameter Panel,
  Interact, Recompute, Convert/Revert) appears when right-clicking a
  dynamic component. Non-DC selections are untouched.

## v0.1.0 — beta 1

First public beta. Open DC is a modern replacement surface for SketchUp
Dynamic Components: fully compatible with the classic `dynamic_attributes`
format, with an opt-in open engine on top.

### Parameter panel

- Two-audience UI: a clean **Options** view for people who only change
  parameters, and a **Configure** mode (⚙ gear) for DC authors — formulas,
  units, display rules, option lists, ordering, tooltips, rename,
  add/delete attributes.
- **Section dividers** (`&Title&` markers in `_itemorder`): insert between
  rows, rename inline, remove, drag to reorder — all classic-compatible.
- **Drag reordering** of attributes and sections; order persists as
  classic `_itemorder`.
- **Tooltips** per attribute (`_<name>_tooltip`), shown on Options labels.
- **Display rules** replace raw access tokens in the UI
  (hidden / view only / edit / list → NONE / VIEW / TEXTBOX / LIST).
- **Batch edit**: select several DCs, edit shared parameters once;
  differing values show `<mixed>`.
- Search/filter across parameters; component rename from Configure;
  clear button hierarchy (confirm / danger / accent).

### Formula editing

- Contenteditable editor with inline **pills** for attributes, `scope!`
  refs, functions and keywords; caret-aware autocomplete.
- **Live validation** through the real parser — errors are explained in
  plain language ("looks like a text value - wrap it in double quotes",
  "unknown unit 'xx' - use mm, cm, m …") with did-you-mean suggestions;
  invalid formulas can't be saved.
- `ƒ(x)` function/syntax reference window.
- **Type-checked value writes**: numeric fields reject text, BOOLEAN
  wants true/false, INTEGER wants whole numbers, LIST values must match
  the option list; `10cm`/`18"`/`45deg` literals coerce through their own
  unit instead of storing raw strings.

### Node & dependency graphs

- **Expression node editor** (Rete.js): build formulas by wiring nodes —
  attributes, constants, operators, functions. Inline values on
  unconnected inputs (no extra const node needed); single fixed FORMULA
  output node defines the result; serializes back to the formula string.
- **Dependency graph** window: every attribute as a node, edges = formula
  references. Rewire by dragging `out → deps` (cycle-guarded), Del on an
  edge to unlink, double-click to open that attribute's node canvas.

### Engines

- **Classic mode**: reads/writes `dynamic_attributes`, asks Trimble's DC
  engine to redraw — components stay fully portable.
- **Open DC mode** (opt-in, per component): sandboxed deterministic
  evaluator, `dynamic_attributes`-compatible dialect plus `global!name`
  model-level references; Convert/Revert round-trips via snapshot.
- **Interact tool**: `onClick` actions (`SET`, `REDRAW`, `ALERT`,
  `GOTOSCENE`) on both engines, nested-click bubbling like classic;
  `ANIMATE*` steps to the next state.
- `NEAREST` function; unit-aware value handling (display units ↔ inches ↔
  formula units).

### Robustness & compatibility

- Zero/near-zero length scales are clamped (`MIN_SCALE = 1e-4`) and
  flagged via `_len<axis>_error` instead of crashing SketchUp with a
  singular transform; the flag auto-clears on the next good eval.
- Non-finite position/rotation values rejected; transform assignment
  rescued as a last resort — evaluation failures log instead of popping
  modals.
- Real-world classic formats handled: all `_itemorder` encodings
  (`&T&`, `&T&name`, `name&T&name`), multi-encoding LIST options,
  `&quot;`-only formula escaping, dict-insertion-order fallback.
- Verified against 24 production classic DCs: parse, order, decode, and
  evaluate correctly (e.g. a Blum drawer's `lenz` follows `Tip_predala`).
