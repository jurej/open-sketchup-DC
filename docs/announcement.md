# Open DC — share/post text

Short version (friends, chat):

> I've been building **Open DC** — a modern, open-source replacement for
> SketchUp's aging Dynamic Components extension. It keeps full
> compatibility with classic DCs, but adds a proper parameter panel, a
> real formula language with a node-graph editor, a dependency graph you
> can rewire, and a new engine that can do things Trimble's can't — like
> driving native SketchUp properties (name, layer/tag…) and other
> plugins' attribute dictionaries straight from formulas. It's beta 1,
> AGPL, and I'd love feedback:
> https://github.com/jurej/open-sketchup-DC

---

Longer version (forum post):

## Open DC — a modern Dynamic Components replacement (beta 1)

Dynamic Components are one of SketchUp's most powerful ideas stuck in
one of its oldest UIs. Open DC is my attempt at a modern take: it reads
and writes the **same `dynamic_attributes` format**, so classic DCs keep
working and stay portable — then adds an opt-in open engine on top.

**For DC users:**

- A modern parameter panel — search, labeled sections, tooltips,
  drag-reordering, batch-edit shared parameters across a multi-select.
- Two audiences: a clean **Options** view for people who just change
  values, and a **Configure** mode for authors (formulas, units, display
  rules, option lists, ordering).
- A formula editor that actually helps: inline pills, caret-aware
  autocomplete, live validation with plain-language errors, and a visual
  **node-graph** so you can wire expressions instead of typing them.
- An interactive **dependency graph** — every attribute a node, drag to
  rewire, double-click to edit. Cycle-safe.
- The Interact tool works — `onClick` with `SET`, `REDRAW`, `ALERT`,
  `GOTOSCENE`.

**For DC authors — the fun part:**

- **Scoped attributes.** Formulas can read *anything*: native entity
  properties (`sketchup!name`, `sketchup!layer`), other plugins'
  attribute dictionaries (`su_instanceset!price`, `DICTATTR()`), model
  and scene globals (`model!units`, `scene!name`), and `global!`
  parameters shared across components.
- **Driver formulas.** Attach fx to a writable native property or dict
  key and the engine *writes back to SketchUp* on every recompute —
  auto-name definitions, drive pricing keys in SU_InstanceSet, assign
  tags by formula. Unknown tag names safely fall back to Untagged.
- **Live recompute.** Scale or move a converted component and dependent
  formulas re-evaluate — `lenx` tracks real scale, pickets multiply
  themselves, rail lengths follow.
- **Convert anything.** Plain components convert to Open DC directly —
  no existing attributes needed. Convert/Revert round-trips via a stored
  snapshot.

The screenshots in the repo show a parametric picket fence: change one
`width` parameter and the rails stretch while `copies` respawns the
pickets (10 → 21).

**Status:** beta 1, SketchUp 2024+, Windows/Mac, AGPL-3.0.
Pure-Ruby formula engine with a unit-test suite; verified against a
24-component library of real-world classic DCs.

Repo: https://github.com/jurej/open-sketchup-DC
Feature tour with examples: docs/features.md

Feedback, bug reports, and weird classic DCs to test against are all
welcome.
