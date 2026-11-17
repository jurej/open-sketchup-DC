# Architecture

```
UI panel (HtmlDialog + vanilla JS)
        │  JSON {action, payload}  /  state snapshots
        ▼
Panel (ui/panel.rb) ── route → DCWriter / Convert / Commands
        │
        ▼
Selection ──► DCReader ──► ParamSet/Param  (pure Ruby)
        │
        ├── classic engine: DCBridge → $dc_observers.redraw_with_undo
        │
        └── osdc engine:    Engine → Expression + Graph → Applier
                                    (dirty-set, timer-coalesced, one undo op)

Observers: SelectionSpy → Panel pushes; EntitySpy on entities + dicts →
           panel refresh + Engine.mark_dirty (osdc owners only)
```

Dialogs (panel, graph, node editor, fx reference) follow the Windows
color mode: `ui/theme.js` applies `html[data-theme]` from
`prefers-color-scheme` on load, and `Panel.os_theme` reads
`HKCU\...\Personalize\AppsUseLightTheme` and overrides it via
`OpenDCTheme.set()` on every state/graph/nodes push. All colors are CSS
variables — add new colors as vars in both palettes.

## Invariants

- One engine owns a component at a time (`_engine` marker, dict deleted on
  convert — see Convert).
- Every model mutation inside `Helpers.undo_wrap` (re-entrant/coordinated
  via the framework's shared operation tracker).
- Engine evaluation never mutates during iteration: collect → sort →
  write_back → apply. Writes skip unchanged values to avoid observer churn.
- `@applying` guard prevents the engine's own writes from re-dirtying itself.

## Known beta-1 limitations

- `redraw_with_undo` creates one undo step per classic instance in batch ops.
- Nested children of a shared definition share storage — last parent-context
  evaluation wins (true per-instance isolation needs definition cloning).
- `name!` sibling references read stored (not freshly evaluated) values.
- Copies only for component children (not groups); no onClick/Interact yet.
- Scale tool on osdc components is not yet intercepted.
- Lengths entered in the panel are raw inches; unit-aware editing is a
  polish item.

## Manual QA checklist

- [ ] Classic DC: select → Options tab shows configurable params → edit →
      Trimble engine redraws.
- [ ] Advanced tab: formula edit, access change TEXTBOX↔LIST, options edit.
- [ ] Add attribute → appears in native DC Component Attributes too.
- [ ] Batch: select 3+ DCs → shared params → `<mixed>` → set value → all
      update.
- [ ] Convert → `_engine` marker set, classic dict gone, engine badge flips.
- [ ] osdc: formula `=width*2` recomputes on source change.
- [ ] `global!` link: model `open_dc` attr referenced from two components.
- [ ] `copies` on a child: instances created/erased + per-copy `copy` index.
- [ ] Revert roundtrip: classic dict restored from `_legacy_dc`.
- [ ] Undo: each edit/batch/convert reverts cleanly.
- [ ] Panel reflects external edits (native Component Options dialog, Ruby
      console).
- [ ] Dialogs (panel / graph / node editor / fx reference) follow the
      Windows light/dark app mode, including a flip while open.
