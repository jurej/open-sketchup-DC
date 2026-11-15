# Open DC — a modern Dynamic Components replacement for SketchUp

**Status:** beta 1 (`v0.1.0`). Part of the
[Open SketchUp](https://github.com/jurej/open-sketchup-framework) ecosystem.

Open DC gives SketchUp's Dynamic Components a modern parameter panel and adds
capabilities the classic extension can't do:

| Feature | Status |
|---|---|
| Modern parameter panel (search, grouped views, formula editing) | beta 1 |
| Batch-edit one parameter across many selected DCs at once | beta 1 |
| Open engine (`open_dc`) — deterministic evaluation, `global!` cross-component links | beta 1 (opt-in Convert) |
| Node-graph editor, presets | planned (beta 2) |
| Interact/onClick, scale-tool handling | planned (beta 2) |

## Two engine modes

- **Classic mode** — the panel reads and writes the normal
  `dynamic_attributes` format and asks Trimble's engine to redraw.
  Components stay 100 % portable (SketchUp Web, iPad, users without this
  plugin).
- **Open DC mode** — opt-in per component via *Extensions → Open DC →
  Convert to Open DC*. Our own sandboxed formula engine evaluates a
  `dynamic_attributes`-compatible dialect plus `global!name` references
  (model-level parameters — links across separate components).
  Convert/Revert round-trips through a stored snapshot.

## Install

Dev: `powershell -File scripts/install_dev.ps1`
Package: `powershell -File scripts/build_rbz.ps1` → `dist/*.rbz`, install via
*Extensions → Extension Manager → Install Extension*.

Requires **SketchUp 2024+** (Windows/Mac).

## Use

- *Extensions → Open DC → Parameter Panel* — live parameter editor.
  - **Options** tab: user-facing parameters (like Component Options).
  - **Advanced** tab: every attribute incl. formulas & meta (`fx` expands
    an editor; `*` marks instance overrides).
  - Select multiple DCs → a **Batch edit** section appears with the shared
    parameters (`<mixed>` = different current values).
- *Extensions → Open DC → Convert / Revert* — switch engines per component.
- *Recompute Selected* — manual redraw/evaluate.

## Formula language (Open DC mode)

```
10cm  25.4mm  2'  4"        # lengths → inches
"text" & value              # string concat
+ - * / % ^  = <> < > <= >= AND OR NOT
attr  parent!attr  name!attr  global!attr   # references
IF CHOOSE CURRENT MIN MAX ROUND INT FLOOR CEILING ABS SQRT
SIN COS TAN ASIN ACOS ATAN PI DEGREES RADIANS
LARGEST SMALLEST OPTIONINDEX OPTIONVALUE
```

`global!` parameters live on the model itself — set them via the console or
future UI: `Sketchup.active_model.set_attribute("open_dc", "height", 100)`.

## Repo layout

See `AGENTS.md` and `docs/architecture.md`. Unit tests (no SketchUp needed):
`ruby -Itest tests/test_expression.rb` etc.

MIT licensed.
