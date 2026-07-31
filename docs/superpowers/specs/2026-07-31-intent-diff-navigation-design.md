# intent-diff.nvim navigation pass — design

**Status:** approved
**Date:** 2026-07-31
**Builds on:** `2026-07-30-intent-diff-ux-design.md` (shipped)

## Goal

Three changes to how the sidebar is driven:

1. The cursor opens file diffs, exactly as it already previews intents and
   directories — removing the inconsistency where group and directory rows
   respond to the cursor but file rows require `<CR>`.
2. `<CR>` on a file row gains a distinct job: open and move focus into the diff
   pane.
3. Two new sidebar actions — toggle all intents expanded/collapsed, and
   show/hide the sidebar.

## Background

The current split is deliberate but wrong for this user. `apply_hover`'s file
branch calls `view.restore` rather than opening the hovered file, to avoid
re-running codediff's diff for every row the cursor passes over. The 120ms
debounce (`preview.debounce_ms`) already solves that: holding `j` through a
70-file tree never settles, so it renders once, at rest. The cost the split was
avoiding does not materialise.

## Global constraints

- `lua/intentdiff/view.lua` remains the ONLY module permitted to `require`
  codediff.
- Never create or close a window to render a preview.
- Preview buffers are never fold-filtered.
- Tests never call a real LLM.
- Hunk ranges stay 1-based and end-exclusive.
- Commits GPG-signed; no `Co-Authored-By`.
- `tests/run_tests.sh` must report `failing=0`. Baseline: 248 successes across
  20 spec files.

## 1. The cursor opens files

`apply_hover` (`lua/intentdiff/init.lua`) replaces its file branch. All three
row kinds become uniform:

| Row | Effect |
|---|---|
| group (any wrapped title line, or the stats line) | preview that whole intent |
| directory | preview that subtree |
| file | render that file's diff |

The de-dupe key for a file row changes from the flat `"file"` to
`("f%d:%d"):format(group_i, file_i)`. The flat key made every file row the same
target, which was correct when they all did the same thing and is wrong now —
without this, moving between two file rows would be a no-op.

Two consequences, both handled explicitly rather than discovered later:

**Focus.** codediff's render can move the current window, which is why
`auto_open_first` already restores focus to the sidebar afterwards. Hover needs
the same, via a new `opts.restore_focus` on `open_file`. This must be a
SEPARATE flag from the existing `opts.auto`: `auto` means "bail if the user has
already selected something", and hover sets `user_selected` itself, so reusing
`auto` would make every hover-open bail. `auto_open_first` passes both.

**Classification landing mid-browse.** Hovering a file sets
`entry.user_selected`, so a classification completing while the user is
browsing re-folds their current file in place (`refold_shown_file`) instead of
yanking them to the first group. Hovering a *group* does not set it — that path
is already handled correctly by `rerender_preview`, which re-derives the
preview from the row under the cursor after a model swap.

Gated by `preview.hover_opens_files` (default `true`). With it false, the file
branch keeps today's `view.restore` behaviour.

## 2. `<CR>` opens and jumps into the diff

On a file row, `<CR>` renders that file if it is not already shown, then moves
focus to the diff pane. When the cursor already rendered it — the common case
now — nothing re-renders: the existing `same_as_shown` identity check
(`init.lua`) makes this a pure focus change.

Group and directory rows keep their current `<CR>` behaviour (toggle collapse).

Focus target is `session.modified_win` when valid, falling back to
`session.original_win` — a deleted file populates only the original side.

## 3. Toggle all intents (`zA`)

Sidebar-only. If ANY group is expanded, collapse every group; otherwise expand
every group. Per-directory collapse state inside each group
(`g.collapsed_dirs`) is left untouched, so re-expanding restores the tree the
user had arranged.

Exposed as `callbacks.on_toggle_all()` from `sidebar.create`, and as
`:IntentDiffToggleAll`.

## 4. Show/hide the sidebar (`<leader>gVt`)

The sidebar buffer is currently `bufhidden = "wipe"`. Closing its window
therefore destroys the buffer — the exact failure that broke the sidebar during
the first build. So:

- the buffer becomes `bufhidden = "hide"`;
- `sidebar.hide(handle)` closes the window and leaves the buffer;
- `sidebar.show(handle)` re-opens `topleft <width>vsplit`, re-binds the buffer,
  and re-applies every window option `create` sets;
- **`forget_entry` gains an explicit `nvim_buf_delete` for the sidebar buffer**,
  because nothing wipes it automatically any more. Without this the plugin
  leaks one buffer per review session.

`handle.visible` tracks state. Every reader of `sidebar.winid` gets a validity
guard; `on_next_group` and `on_prev_group` currently read the cursor unguarded
and would throw with the sidebar hidden.

The key is buffer-local on BOTH the sidebar buffer and the diff pane buffers —
it must work from the panes, since a sidebar-local key is unreachable when the
sidebar is hidden. It is installed alongside the existing `t`/`q` overrides in
`view.install_keymaps` and `view.install_preview_keymaps`, dispatching through
`require("intentdiff").toggle_sidebar(tabpage)` exactly as the preview's `q`
already dispatches through `require("intentdiff").close(tabpage)`.

Also exposed as `:IntentDiffSidebar`.

Hiding returns the sidebar's width to the diff panes and codediff may
re-arrange them; showing takes it back. The panes must survive a hide/show
cycle with their buffers and fold state intact.

## 5. Configuration

New:

```lua
preview = {
  enabled = true,
  debounce_ms = 120,
  max_lines = 20000,
  hover_opens_files = true, -- NEW
},
keymaps = {                 -- NEW
  toggle_sidebar = "<leader>gVt",
  toggle_all = "zA",
},
```

Setting a keymap to `false` or `nil` installs nothing, matching how the plugin
already treats codediff's `toggle_layout` key being disabled.

`preview.hover_opens_files` sits under `preview` rather than forcing a rename
of `preview.enabled`/`debounce_ms`, which are documented and already in use.
The whole cursor-driven mechanism is "hover"; `preview` is what it renders for
group and directory rows.

## 6. Error handling

- Sidebar hidden → hover cannot fire (no CursorMoved on an invisible buffer);
  `on_next_group`/`on_prev_group`/focus-restore all no-op behind validity
  guards.
- `show` called when already visible, or `hide` when already hidden → no-op.
- Sidebar buffer invalidated behind our back → `show` recreates it and
  re-renders from the current model rather than erroring.
- `<CR>` on a file row with no valid diff window → renders, skips the focus
  move.
- A keymap configured as `false`/`nil` → not installed, no error.
- Toggle-all with no groups → no-op.

## 7. Testing

Pure/unit:

- `sidebar.layout` unchanged; `sidebar.create`'s `zA` invokes `on_toggle_all`.
- Toggle-all semantics: mixed state collapses all; all-collapsed expands all;
  `collapsed_dirs` preserved across a collapse/expand round trip.

Integration, against a real codediff session in a temp repo:

- Moving the cursor onto a file row renders that file's diff, with focus
  remaining in the sidebar.
- Moving between two file rows renders the second (guards the per-file
  de-dupe key).
- `<CR>` on the already-hovered file moves focus into the diff pane and does
  NOT re-render (assert the pane buffer id is unchanged).
- `<CR>` on a not-yet-shown file renders it and focuses the pane.
- Classification completing while the cursor sits on a file row re-folds that
  file in place rather than jumping to the first group.
- Hide/show the sidebar: the diff panes survive with their buffers and fold
  state intact, and the sidebar re-renders the same model.
- The sidebar buffer is deleted when the session closes (guards the
  `bufhidden` change against a buffer leak).
- `preview.hover_opens_files = false` restores the previous restore-on-file-row
  behaviour.
