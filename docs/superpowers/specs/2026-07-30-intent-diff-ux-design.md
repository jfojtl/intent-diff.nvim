# intent-diff.nvim UX pass — design

**Status:** approved
**Date:** 2026-07-30
**Builds on:** `2026-07-29-intent-diff-design.md` (the shipped plugin)

## Goal

Four changes to how intent-diff presents its results:

1. Sidebar group headers wrap their full title and carry `+N -M` line stats in
   proper colours.
2. Files render as a diffview-style tree instead of a flat list.
3. Newly added files show their contents (today they render an empty buffer),
   folded to just the additions belonging to the open intent.
4. Putting the cursor on a group row previews that whole intent's diff, with
   visible file boundaries.

## Global constraints

- **Every diff surface must support toggling between side-by-side and inline.**
  This includes the intent preview introduced here, not only per-file diffs.
- `view.lua` remains the only module permitted to `require` codediff.
- **Never create or close a window to render a preview.** Inject buffers into
  the pane windows the codediff session already owns. Empirically verified:
  creating a window by hand leaves an orphan pane and restores into a
  three-diff-window state with a duplicated buffer (Probe 2, below).
- The completeness invariant is unchanged: union(groups) + Ungrouped == the
  exact inventory. Added-file sub-hunks *are* inventory hunks, so reconciliation
  is untouched.
- Tests never call a real LLM — fake providers and `fake_bin` only.
- All layout/rendering logic lives in pure functions returning
  `lines, meta, highlights` so it is asserted directly, without a live UI.

## Evidence

Three headless probes against the real codediff established the mechanisms
below. Reproduce with `nvim --headless -u tests/init.lua -l <probe>`.

**Probe 1 — the added-file bug.** A staged-new file renders
`1 lines, first=""` from buffer `codediff:////…///WORKING/brand_new.lua`.
`view.lua` passes `sess.target_revision or "WORKING"` into
`side_by_side.show_added_virtual_file`, which builds that URL and runs
`git show WORKING:<path>`. That always fails, and
`core/virtual_file.lua:22-30` renders `{""}` on error. codediff's own explorer
never hits this: `ui/explorer/render.lua:273-299` only takes the virtual-file
branch when `target_revision ~= "WORKING"`, and otherwise loads the real file
from disk.

**Probe 2 — managing pane windows ourselves corrupts the session.**
`side_by_side.lua:478` returns early from `render_everything` when either pane
window is invalid, and `side_by_side.lua:438-459` only recreates a missing pane
when `session.single_pane` is set. Closing both panes and calling
`cd.view.update` therefore renders nothing. Creating the second pane by hand
instead (`vsplit` plus assigning `session.original_win`/`modified_win`) left an
orphaned pane behind, and the following `show_file` restored into four windows
with one buffer displayed twice:

```
D  two-pane preview built from inline  wins=4  w1005/b14(60L) w1002/b15(2L) w1006/b16(2L)
D' restored after D                    wins=4  w1005/b14(60L) w1002/b14(60L) w1006/b7(60L)
```

Hence the global constraint: inject only, never create or close.

**Probe 3 — buffer injection is clean.** Setting our own buffers into the
session's existing pane windows and registering them with
`lifecycle.update_buffers/update_paths/update_revisions/update_diff_result`
survives a full round trip in both layouts:

```
1 baseline side-by-side file   wins=3 layout=side-by-side sp=nil  w1001/b6(60L) w1002/b7(60L)
2 preview (side-by-side)       wins=3 layout=side-by-side sp=nil  w1001/b8(1L,"ORIG") w1002/b9(1L,"MOD")
3 restored file                wins=3 layout=side-by-side sp=nil  w1001/b10(60L) w1002/b7(60L)
4 toggled -> inline file       wins=2 layout=inline       sp=nil  w1002/b7(60L)
5 preview (inline)             wins=2 layout=inline       sp=nil  w1002/b12(4L,"UNIFIED-INLINE")
6 restored inline file         wins=2 layout=inline       sp=nil  w1002/b7(60L)
7 toggled -> side-by-side file wins=3 layout=side-by-side sp=nil  w1005/b14(60L) w1002/b7(60L)
8 preview (side-by-side again) wins=3 layout=side-by-side sp=nil  w1005/b15(1L) w1002/b16(1L)
9 restored file                wins=3 layout=side-by-side sp=nil  w1005/b17(60L) w1002/b7(60L)
```

`wins` never exceeds 3, `single_pane` never leaks, the layout marker stays
correct, and every restore repopulates the panes.

`side_by_side.show_welcome` also works for a single-pane preview, but it calls
`lifecycle.update_layout(tabpage, "side-by-side")` internally, corrupting the
layout marker when the session is inline. It is therefore **not** used.

## 1. Hunk statistics and added-file splitting — `hunks.lua`

### Statistics

`M.parse` records `additions` and `deletions` per hunk by counting body lines
starting with `+` / `-` (the `@@` header excluded). `M.untracked_hunk` sets
`additions = #lines, deletions = 0`. Every consumer sums these: file rows,
group headers, preview separators.

### Splitting added files

New `M.split_added(hunk, opts)`. Applies to any hunk whose original side is
empty — `@@ -0,0 +1,N @@`, which is what git emits for status `A` and what
`untracked_hunk` synthesises for `??`. Both statuses take one code path.

Rule: cut at blank lines; greedily accumulate blank-line-delimited blocks until
the accumulated chunk reaches `target_lines`, then cut. A hunk shorter than
`min_lines` is returned unchanged. Defaults `min_lines = 60`,
`target_lines = 40`. A file with no blank lines at all yields one chunk — the
rule never cuts mid-block.

Each sub-hunk gets its own `modified` range (end-exclusive, as everywhere),
`original` stays the zero-width anchor at 1, `text` is the `@@` header for its
own range plus its `+` lines, and `content_hash` is recomputed.
`M.collect` renumbers per file afterwards, so ids stay `path:1`, `path:2`, … —
`classify`, `cache`, and `reconcile` need no changes.

Two consequences, both intended:

- Added files now carry real `modified` ranges, so they fold like modified
  files. `view.show_file` stops bypassing `apply_group_folds` for them. This is
  what makes "only the additions relevant to this intent" true rather than
  aspirational.
- Inventory hunk counts rise. `max_hunks` goes 400 → 600.

Splitting is disabled by `added_file_split.enabled = false`, which restores
exactly today's one-hunk-per-added-file behaviour.

## 2. Added-file rendering — `view.lua`

`show_whole_file` and `show_whole_file_inline` gain the three-way dispatch that
mirrors `explorer/render.lua:273-299`:

- `target_revision` present and `~= "WORKING"` → `show_added_virtual_file` /
  `inline_view.show_single_file` with that revision (today's behaviour, correct
  for two-revision scopes).
- otherwise → load the real file from disk, exactly as `??` does.

The `:0` staged branch codediff also has is unreachable here: every scope
intent-diff supports (`:IntentDiff`, `<rev>`, `<rev>...`, `<base> <target>`)
has either the worktree or a named revision as its target.

Because added files now have multiple hunks, the whole-file branch of
`show_file` applies group folds after content is ready — reusing the existing
`wait_for_virtual_file` / synchronous-`??` split so folds are never applied to
an empty buffer.

## 3. Sidebar — `tree.lua` (new), `sidebar.lua`, `highlight.lua` (new)

### `tree.lua` — pure

- `M.build(files)` → nested nodes. Directories sort before files, alphabetical
  within each. Chains of single-child directories compress into one row
  (`app/api/integrations`), as diffview does.
- `M.flatten(nodes, collapsed)` → ordered rows, each
  `{ kind = "dir"|"file", depth, name, path, status, additions, deletions,
     last, file_i }`, skipping the subtrees of collapsed directories.

One tree per group, so trees stay shallow. Collapse state lives on the group as
`g.collapsed_dirs` (a set keyed by directory path), toggled by the existing
`za` / `h` / `l` when the cursor is on a directory row.

### `sidebar.lua`

`M.layout(model)` returns `lines, meta, highlights` — `highlights` being a list
of `{ line, col_start, col_end, hl }`. The window stays `wrap = false`; titles
are hard-wrapped into multiple buffer lines during layout so tree alignment
survives. Continuation lines carry the same `{ kind = "group", group_i }` meta,
so cursor-driven behaviour treats the whole header block as one row.

Group header block:

```
▾ Extract integration catalog into a
  shared provider registry
  12 hunks · 5 files  +130 -47
```

File and directory rows: a fixed two-column status gutter at the far left,
then indent guides, expand marker, icon, name, and stats:

```
 M  ▾  app/api/integrations
 M    ▾ [provider]/callback
 M       route.ts        +64 -12
 A     access.test.ts    +88 -0
```

Icons come from `nvim-web-devicons` behind a `pcall`, mirroring codediff's own
guard at `explorer/nodes.lua:70`, with a blank fallback when it is absent.
`icons = false` disables them.

`sidebar_width` default goes 36 → 40.

### `highlight.lua` — new

Defines every group with `default = true` links so users can override any of
them:

| Group | Links to |
|---|---|
| `IntentDiffGroupTitle` | `Title` |
| `IntentDiffGroupStats` | `Comment` |
| `IntentDiffAdd` | `Added` |
| `IntentDiffDelete` | `Removed` |
| `IntentDiffDirectory` | `Directory` |
| `IntentDiffIndent` | `Comment` |
| `IntentDiffStatusA` | `Added` |
| `IntentDiffStatusM` | `Changed` |
| `IntentDiffStatusD` | `Removed` |
| `IntentDiffStatusUntracked` | `Added` |
| `IntentDiffPreviewFile` | `Title` |
| `IntentDiffPreviewHunk` | `Comment` |
| `IntentDiffFiller` | `Comment` |

`IntentDiffAdd` / `IntentDiffDelete` are shared between the sidebar stats and
the preview body. Groups are (re)defined on `ColorScheme`.

## 4. Whole-intent preview — `preview.lua` (new), `view.lua`, `init.lua`

### `preview.lua` — pure

`M.render(group, layout, opts)` returns, for `layout == "inline"`:

```
lines, highlights
```

a single unified-diff buffer, and for `layout == "side-by-side"`:

```
original_lines, modified_lines, original_highlights, modified_highlights
```

Each file in the group contributes a separator followed by its hunks:

```
── dashboard/src/lib/integrations/catalog.ts   M   +147 -12
@@ -30,7 +30,9 @@
 export const catalog = {
+  googleAds,
```

Files appear in tree order, so the preview and the sidebar agree.

Side-by-side alignment is a standard pairing pass over each hunk body: a
context line emits a row on both sides; a run of `-` lines and the `+` run
following it emit `max(#minus, #plus)` rows, pairing by index with a filler row
on the shorter side. Separator and `@@` lines emit identically on both sides.
Both buffers therefore have equal line counts, and the two windows are put in
`scrollbind` + `cursorbind`; `show_file` clears both on restore.

`preview.max_lines` (default 20000) caps output with an explicit final line
naming how much was omitted — never a silent truncation.

### Driving it — `view.lua`

- `M.show_preview(sess, group)` renders for the session's current
  `session.layout`, then injects: one buffer into the single window when
  `original_win == modified_win` (inline), two buffers into the two windows
  otherwise. It registers them via `lifecycle.update_buffers`,
  `update_paths(empty, empty)`, `update_revisions(nil, nil)` and
  `update_diff_result({ changes = {}, moves = {} })`, and clears
  `M._active_folds[tab]` so neither the preview nor the `TabEnter` re-assert
  tries to fold a preview buffer. It creates and closes nothing.
- `M.restore(sess)` is `M.show_file(sess, view._last_shown[tab].file_entry)`,
  which re-applies that file's group folds on the way.
- Preview buffers get their own keymaps: codediff's toggle key (see below),
  `]c` / `[c` to jump between hunk headers *within* the preview (line numbers
  come straight from `render`), and `q` to close the session.

### Toggling in a preview

`t` while previewing runs: restore the last shown file → existing
`M.toggle_layout(tabpage)` → re-render the preview in the new layout. The
toggle therefore always executes against a real file, which is the only state
codediff's toggle supports; the preview simply follows `session.layout`
afterwards. Probe 3 steps 4–8 exercise exactly this sequence.

### Triggering — `init.lua`

A `CursorMoved` autocmd on the sidebar buffer, debounced by
`preview.debounce_ms` (default 120), acts on the row the cursor settles on:

- **group row** (including wrapped title lines and the stats line) → preview
  that group;
- **directory row** → preview that directory's subtree;
- **file row** → restore the panes to the last selected file.

A file row does **not** auto-open that file: hovering would re-render through
codediff for every row scrolled past. `<CR>` still selects, unchanged.

Re-entering a row that is already previewed is a no-op, so cursor jitter costs
nothing. `preview.enabled = false` disables the whole mechanism, leaving
today's selection-only behaviour.

## 5. Configuration

New:

```lua
icons = true,
preview = { enabled = true, debounce_ms = 120, max_lines = 20000 },
added_file_split = { enabled = true, min_lines = 60, target_lines = 40 },
```

Changed: `sidebar_width` 36 → 40, `max_hunks` 400 → 600.

## 6. Error handling

- Missing `nvim-web-devicons` → blank icons, no error.
- A group with no files → header renders, preview shows a single
  "no changes in this intent" line.
- Preview render exceeding `max_lines` → truncated with a stated count.
- A pane window invalidated between debounce and render → `show_preview`
  returns false and leaves the panes alone.
- An added file unreadable from disk → falls back to codediff's virtual-file
  path, i.e. today's behaviour rather than a hard failure.
- `hunks.split_added` on a malformed hunk (mixed original side) → returns the
  hunk unchanged.

## 7. Testing

Pure, asserted directly with busted specs:

- `tree.build` / `tree.flatten`: compression of single-child chains, dirs-first
  ordering, collapsed subtree omission, `last` flags for indent guides.
- `sidebar.layout`: wrapping at width, continuation-line meta identity, stats
  line contents, highlight span offsets.
- `preview.render`: file separators, both layouts, pairing and filler for
  unequal `-`/`+` runs, equal line counts across sides, `max_lines` truncation.
- `hunks.parse` additions/deletions; `hunks.split_added` block boundaries,
  `min_lines` threshold, id renumbering, malformed-hunk passthrough.

Integration, against a real codediff session in a temp repo:

- a staged-new file renders its actual contents in both layouts (the assertion
  that fails today);
- an added file over `min_lines` folds to only the open intent's sub-hunks;
- the probe-3 sequence as a regression test: preview → restore → toggle →
  preview → restore, asserting window count, `single_pane`, layout marker and
  pane line counts at each step;
- hover debounce: rapid cursor movement across rows produces one render.
