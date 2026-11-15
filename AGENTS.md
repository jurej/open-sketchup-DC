# Open DC — AI Coding Guidelines

Modern replacement for SketchUp's Dynamic Components, built on the
[Open SketchUp Framework](../open-sketchup-framework) (v0.3.0). Read that
repo's `AGENTS.md` first — all conventions apply here.

## Namespace & Layout

- Namespace: `OpenSketchupDC::OpenDC` (NOT `OpenSketchUp::DC` — the
  `OpenSketchUp` top-level module is reserved for the Registry extension).
- Extension-Warehouse layout: `plugins/OpenSketchupDC_OpenDC.rb` (registration
  only) + `plugins/OpenSketchupDC_OpenDC/` (all logic).
- `helpers.rb` is a vendored copy of the framework helpers — regenerate with
  `powershell -File scripts/vendor_helpers.ps1`, do not edit by hand.
- Never define a module named `UI` inside our namespace — it would shadow
  SketchUp's `::UI` and break menu/dialog calls.
- Load files with `Sketchup.require(File.join(__dir__, ...))`, no extensions.

## Domain Model

- `dynamic_attributes` — Trimble's classic DC dictionary ("classic" mode).
- `open_dc` — our own dictionary ("osdc" mode), same `_<attr>_<meta>` cluster
  schema plus `_engine`, `_legacy_dc`, `_osdc_copy` keys.
- A component is owned by exactly one engine: Convert deletes the classic
  dict (snapshot under `_legacy_dc`); Revert restores it.
- See `docs/attribute-format.md` for the full schema. Key rule: for classic,
  `_<attr>_formula` is the authoritative user input and `<attr>` is only the
  computed cache — `DCWriter.set_value` writes the formula slot accordingly.
- Values in classic dicts are strings (`"5"`, `"FALSE"`); Trimble's engine
  crashes on non-string types like Ruby booleans — stringify classic writes.

## Layering

- `core/params.rb`, `core/expression.rb`, `core/graph.rb` are pure Ruby —
  no SketchUp API references at load time or in tests. Keep them that way.
- `DCReader`/`DCWriter` accept `Sketchup::AttributeDictionary` OR plain
  `Hash` — the unit tests use Hashes.
- All model modifications go through `Helpers.undo_wrap`.
- The panel module is `Panel` (`ui/panel.rb`), not `UI`.

## Testing

- `ruby -Itest tests/test_*.rb` runs the suite outside SketchUp (Minitest).
- Manual QA checklist lives in `docs/architecture.md`.
- Dev install: `powershell -File scripts/install_dev.ps1`
- Package: `powershell -File scripts/build_rbz.ps1`

## Version floor

SketchUp 2024+ (Ruby 3.2, CEF 112 for the HtmlDialog panel).
