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

For the classic format, `_<name>_formula` is the **authoritative user
input** — not just for `=expr` formulas but for every editable value.
`<name>` is only the engine's computed cache:

- Typing `5` in Component Options stores `"5"` (or `"5.0"`) in
  `_lenx_formula`; redraw evaluates it and writes `lenx = "5"` as cache.
- Writing `<name>` directly has no lasting effect — the next redraw
  overwrites it from `_<name>_formula`.
- String values are stored bare in the formula slot (`Red`, not `"Red"`);
  the evaluator treats unquoted words as string literals.
- Booleans must be strings (`"FALSE"`); Trimble's engine crashes
  (`to_f` on `false`) if a Ruby boolean lands in `hidden`.
- Per-instance overrides are `_<name>_formula` on the **instance** dict
  (siblings keep their own values — verified).

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
| default edit | owner `_<name>_formula` (as string) | owner `<name>` (typed) |
| meta edit | owner `_<name>_<field>` | owner `_<name>_<field>` |
| new attribute | owner: `<name>` (string cache) + full meta + `_<name>_formula` | owner: `<name>` + full meta |
| system key | owner raw `_<key>` | owner raw `_<key>` |
