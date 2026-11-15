# Attribute format reference

Both engines store parameters as clusters inside an attribute dictionary.
Keys are always lowercase. Underscore-prefixed keys are meta/system fields.

## `dynamic_attributes` (classic, Trimble format)

### Component (top-level DC)

- **Definition dictionary** — defaults + full meta clusters:
  ```
  lenx                = 10.0        # attribute value (default)
  _lenx_label         = "LenX"      # cased display name
  _lenx_formlabel     = "Width"     # label in the options dialog
  _lenx_access        = "TEXTBOX"   # NONE | VIEW | TEXTBOX | LIST
  _lenx_options       = "A=1&B=2"   # url-encoded list (LIST only)
  _lenx_units         = "INCHES"    # INCHES CENTIMETERS MILLIMETERS METERS
                                    # FEET DEGREES FLOAT INTEGER STRING BOOLEAN
  _lenx_formula       = "5*2"       # formula source (no leading =)
  _lenx_formulaunits  = "INCHES"
  _lenx_nominal       = 10.0        # unscaled length (LenX/Y/Z only)
  _lenx_error         = "..."       # last eval error (engine-written)
  _name               = "panel"     # node name for `name!` references
  _formatversion      = 1.0
  _hasbehaviors       = 1.0
  _lengthunits        = "CENTIMETERS"
  _lastmodified       = "..."
  _scaletool          = <bitmask>
  ```
- **Instance dictionary** — per-instance overrides. Verified against
  Trimble's engine: the instance stores `_<name>_formula` (the authoritative
  user input) plus a plain `<name>` computed cache the engine rewrites on
  redraw.

### Authoritative input vs computed cache (verified, SketchUp 2026)

Two storage styles coexist in real components:

- **Literal attrs** (e.g. `lenx` on a TEXTBOX-editable size): plain `<name>`
  holds the user input; **no** `_<name>_formula` key exists.
- **Formula attrs** (e.g. `sirina`): `_<name>_formula` is authoritative;
  `<name>` is only the engine's computed cache.

Write rules that work against Trimble's engine (verified):

- Writing `_<name>_formula` works in both cases — the engine treats the
  formula slot as user input even when none existed before, and evaluates
  bare literals (`"39.37"`, `"Red"`) and strings fine. `DCWriter.set_value`
  therefore always targets `_<name>_formula` for the classic dict.
- Writing plain `<name>` on a def is picked up **only** via the engine's
  own deferred observer redraw (idle-time) — not reliably immediate.
- Writing plain `<name>` or `_inst_<name>` on an **instance** dict is
  ignored for literals — per-instance overrides only work through the
  `_<name>_formula` slot (verified: sibling instances keep own values).
- Instance dicts otherwise hold only engine-written computed caches of
  formula attrs (`sirina`, `visina`, ...).
- Booleans must be strings (`"FALSE"`); the engine crashes on Ruby `false`.
- Formulas are stored **HTML-escaped** (`&quot;`, `&amp;`). `DCReader`
  unescapes on read; `DCWriter` re-escapes on classic writes.
- Bare numbers in the formula slot are evaluated in the attr's
  `_<name>_units` context, **not** inches (verified: `"35.43"` with
  `_lenx_units="CENTIMETERS"` produced 35.43 cm / 13.95"). The panel
  therefore stores display-unit numbers for classic DCs and only converts
  display→inches for `open_dc` (whose engine stores inches internally).

### `onclick` behavior cluster (verified on a real door DC)

- `onclick` = action formula, e.g. `SET("zzzOdprto",0,15,30,45,60,75,90)` —
  a plain literal attr (no `_onclick_formula` needed).
- `_onclick_state1` on the definition dict tracks the last SET state index.
- `SET`/`ANIMATE` writes target the attr's input slot: `_<name>_formula`
  when the attr is formula-backed (the engine recomputes and would clobber
  a plain-key write), `<name>` otherwise. The next state is computed from
  the *formula-slot* value, not the lagging evaluated cache, so consecutive
  clicks advance correctly under deferred eval.

### `_<name>_error` = eval status slot

Holds the last formula eval result, either a plain value or an HTML span
(`<span class=subformula-success>80.0</span>` /
`subformula-error`). `DCReader` strips markup and suppresses
success/numeric results — only real errors reach the UI.

### The `""` (unnamed) dictionary

Instances also carry a nameless dictionary holding `_last_lenx/y/z` —
the engine's record of last-applied sizes (scale-change detection).

### `""` deferred redraw + options encoding

- DC's own EntityObservers trigger a deferred recalc at idle; explicit
  `redraw_with_undo` is still needed for immediate geometry updates and
  works for formula-slot writes.
- LIST `_<name>_options` may have stray `&`s:
  `"&2-slojno=2&3-slojno=3&"` — empty pairs are skipped when parsing.

### Nested component instance (inside a DC)

- Instance dictionary uses the `_inst_` prefix:
  `_inst_lenx` (evaluated value), `_inst__lenx_access` (per-instance meta).

### Nested group (DC child as a group)

- All attributes + `_<attr>_<meta>` directly on the **instance** dictionary.

## `open_dc` (Open DC format)

Same cluster schema, plus:

```
_engine      = "osdc"       # ownership marker (checked by DCReader.engine_of)
_legacy_dc   = <JSON>       # tagged snapshot of the classic dict (revert)
_osdc_copy   = <Integer>    # marks generated copy instances
```

Model-level globals for `global!name` references live on the model's own
`open_dc` dictionary as plain keys.

## Write rules (DCWriter)

| Operation | `dynamic_attributes` (classic) | `open_dc` |
|---|---|---|
| user value edit | instance `_<name>_formula` (as string) | instance `<name>` (typed) |
| default edit | owner `<name>` (literal default) | owner `<name>` (typed) |
| meta edit | owner `_<name>_<field>` | owner `_<name>_<field>` |
| new attribute | owner: `<name>` (string cache) + full meta + `_<name>_formula` | owner: `<name>` + full meta |
| system key | owner raw `_<key>` | owner raw `_<key>` |
