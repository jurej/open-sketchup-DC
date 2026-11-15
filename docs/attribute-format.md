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
- **Instance dictionary** — plain-key overrides for values that differ
  from the definition defaults.

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

| Operation | Target dictionary | Key |
|---|---|---|
| user value edit | instance | `<name>` |
| default edit | definition (group: instance) | `<name>` |
| meta edit | definition (group: instance) | `_<name>_<field>` |
| new attribute | definition (group: instance) | value + full meta cluster |
| system key | definition (group: instance) | raw `_<key>` |
