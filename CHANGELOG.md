# Changelog

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
