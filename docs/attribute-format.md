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
                                    # DEFAULT = "End user's model units"
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
- Formulas escape **only** `"` → `&quot;` on write. `&`, `<`, `>` must be
  stored **raw** — verified by live redraw: storing `&amp;`/`&lt;`/`&gt;`
  makes DC evaluate the literal `amp;`/`lt;`/`gt;` text and error
  (`<span class=subformula-error>` spans in `_<name>_error`), while raw
  `sirina&"/"&visina` and `sirina&&quot;/&quot;&visina` both evaluate
  correctly. `DCReader` still decodes the full entity set on read
  (`&amp;` last) so foreign-written formulas display cleanly.
- `_<name>_units = "DEFAULT"` = "End user's model units": display and
  input resolve to the model's `UnitsOptions.LengthUnit` (and format —
  architectural/fractional included). The panel converts through it on
  both reads and writes.
- Bare numbers in the formula slot are evaluated in the attr's
  `_<name>_formulaunits` context, **not** inches — and `formulaunits` can
  differ from the display `_<name>_units` (real door DC: `units=MILLIMETERS`,
  `formulaunits=CENTIMETERS`, so typing `10` in the mm field must store `1.0`).
  The panel converts display→formulaunits on classic writes; the literal
  `<name>` slot (used by `set_default`) stores **inches**; `open_dc` also
  stores inches internally. Earlier finding confirmed: `"35.43"` stored in a
  `_formulaunits="CENTIMETERS"` slot produced 35.43 cm / 13.95".

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

When the owner dictionary doesn't exist yet (plain component or group),
`DCWriter.add_param` first seeds it via `ensure_dict`: `_formatversion`,
`_hasbehaviors`, `_lengthunits` for classic (the keys Trimble's engine and
dialogs use to recognize a DC) or the `_engine` marker for `open_dc`. Any
component or group can therefore get its first attribute from the panel and
becomes dynamic on the spot.

## Built-in attributes (synthesized)

`DCReader.read` appends live-computed params for the built-in SketchUp
attributes (X Y Z, LenX/Y/Z, RotX/Y/Z, Hidden, Material) that no dict key
claims — the same names the classic engine resolves implicitly. They display
and edit like real params; a write adopts them into the dictionary (and
`ensure_dict` seeds the system keys on first write). `Param#builtin?` marks
them so they are skipped where a stored attribute is required:
`Engine.applied_values` (they must never drive the applier — a synthesized
`rotx` would recompose the transform on every recompute),
`ParamSet#editable` (batch intersection), and the dependency graph.

## `sketchup!` — native entity properties (osdc formulas)

`sketchup!<prop>` reads live SketchUp state; nothing is stored in either
dictionary, so values always reflect the current model. The scope is
reserved — a sibling node or dictionary named "sketchup" is unreachable
via `name!` (use `DICTATTR` for the dict).

| prop | source | writable |
|---|---|---|
| `name` | definition name (components) / entity name (groups) | yes — renames every instance |
| `instname` | instance name (Entity Info "Name"), components only | yes |
| `description` | definition / group description | yes |
| `summary`, `itemcode`, `creator` | definition Info fields | yes — components only |
| `layer` | assigned layer/tag name | yes — the layer must already exist |
| `guid`, `persistentid`, `entityid`, `typename` | entity/definition ids | read-only |
| `instances` | `definition.count_used_instances` | read-only |
| `x y z lenx/y/z rotx/y/z hidden material` | same live values as the synthesized builtins | read-only here (write via adopted attributes) |

`_name` (the DC node name `name!` refs resolve) is unrelated to
`sketchup!name` — keep them distinct.

Panel writes go straight to the entity/definition (`SkProps.write`),
never through `DCWriter` — no dict adoption, so they can't drive the
applier.

## Attribute dictionaries — `dictname!key` and `DICTATTR`

Every dictionary on the instance **and** its definition (any plugin's:
`SU_InstanceSet` Advanced Attributes, `AppliedSchemaTypes`, etc., plus
`dynamic_attributes`/`open_dc` themselves) is a reference scope:

- `su_instanceset!price` — scope resolution order is `parent`/`global`/
  `sketchup`, then sibling node name, **then** dictionary name
  (case-insensitive). Nodes win name collisions.
- `DICTATTR("dict name", "key")` — function form for dict names that
  aren't valid identifiers (spaces, dots) or for explicit clarity.

Key lookup is case-insensitive (`su_instanceset!price` finds `Price`).
Reads return scalars; structured values (arrays, points, times)
stringify so `&` concat still works. `sketchup!`, dict scopes and
`DICTATTR` are osdc-only — the classic engine doesn't know them, so
panel validation emits a hint when they appear in a
`dynamic_attributes` formula.

Panel writes (`setDictAttr`) update **existing scalar keys only** —
missing dicts/keys and structured values are refused, and writes keep
the existing value's type (numeric keys get numbers, boolean keys get
booleans). The "Attribute dictionaries" foldable section lists every
foreign dict on instance + definition; read-only rows mark structured
values.

## Driver attributes — fx on external targets

A param whose **name contains `!`** is a *driver*: its formula doesn't
produce a user attribute, it writes the computed value out to an
external target on every recompute.

| driver name | target |
|---|---|
| `sketchup!<prop>` | `SkProps.write` — a writable native property |
| `<dict>!<key>` | `SkProps.set_dict_attr` — an existing scalar dict key |

Storage is the ordinary meta cluster (`_sketchup!name_formula` etc.);
the non-greedy `INPUT_META_RE` round-trips `!` in the base name, so
drivers are discovered, evaluated, cached (`<sketchup!name>`) and
error-flagged (`_sketchup!name_error`) like any formula attr. No user
path can create `!` names (`addParam` is word-chars only), so the
marker is unambiguous and drivers never appear as user attrs — the
panel keeps them out of the params list entirely; the foldable
sections own them (configure mode, osdc entities only).

Apply semantics (`Applier.apply_drivers`):

- only values the *current* eval produced are written —
  `applied_values` drops drivers absent from `computed`, so a cleared
  formula or eval error stops driving (the target keeps its last
  value) instead of re-applying a stale cache;
- unchanged values are skipped before writing, so a no-op recompute
  doesn't dirty the model;
- failures flag `_<name>_error` with an `apply: ` prefix — distinct
  from eval errors, which are never overwritten or cleared by the
  apply pass;
- `sketchup!` wins the scope over a dictionary literally named
  "sketchup" (that dict stays readable via `DICTATTR`).

Clearing a driver's formula deletes the whole cluster (`delete_param`).
Drivers are **osdc-only** — `cmd_set_meta` refuses them on classic
entities, and Trimble's engine would never evaluate them anyway.
Read-only props (guid, ids) and structured dict values get no fx
affordance but remain usable as formula *inputs* via
`sketchup!`/`dictname!` refs and the node palettes.
