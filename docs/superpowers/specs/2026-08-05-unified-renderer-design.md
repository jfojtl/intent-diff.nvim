# One renderer for files and intents

Replace the two rendering paths — codediff's per-file diff and our own
whole-intent preview — with a single renderer that intent-diff owns. A
single-file view becomes a render plan over one file; an intent view becomes a
render plan over several. Same code, same coordinate system, same comments,
same folds.

## Why

The plugin currently renders the same information two different ways.

Per-file diffs go through codediff: `view.lua` calls into seven of its internal
modules across twenty-two call sites, and 1,385 lines exist largely to absorb
the impedance. codediff always opens its own tab, so we adopt the one it
created after the fact. Its `TabLeave` handler deletes every buffer-local
mapping whose left-hand side it owns and `TabEnter` reinstalls its versions, so
we re-assert ours two event-loop ticks later. Its re-render path is
explorer-only, so we track which file to redraw ourselves. Its added and
deleted files load asynchronously through `codediff://` URLs, so we poll.

Whole-intent previews go through `preview.lua`, 354 lines of a second renderer
that is measurably weaker: whole-line highlight groups only, no character-level
highlighting, no syntax highlighting, and a `max_lines` truncation the file view
does not need. Consumers branch on which surface is live —
`comments/init.lua:354` picks `preview_context` over the file context,
`comments/marks.lua:312` picks `preview_placements` over the file-diff path —
and two capabilities are simply refused inside a preview: comments are not
shown (`comments/init.lua:598`) and hover-opens-files is disabled
(`comments/init.lua:597`).

The duality also produced a bug we documented rather than fixed: with an
untracked, added or deleted file as the anchor, codediff's single-file entry
points have already collapsed the session to one window, so the preview stays
inline and `t` cannot reach side-by-side until a modified file is shown again
(`view.lua:898-907`).

Worst of all, the two chunkings disagree on screen right now.
`apply_group_folds` builds synthetic `changes` from **our git hunks** and hands
them to codediff's `compute_visible_lines` (`view.lua:260-263`), so the folds
follow git's chunking while the rendered diff and its character highlights
follow VSCode's. The sidebar agrees with only one of them. The function also
requires `session.stored_diff_result` to exist (`view.lua:257`) purely as a
precondition, then ignores its contents.

## Built on codediff.nvim

intent-diff continues to depend on
[codediff.nvim](https://github.com/esmuellert/codediff.nvim) by Yanuo Ma (MIT),
and this design deliberately keeps it a named dependency rather than vendoring
its code. Users install it by name, which is the most visible credit we can
give.

What we use from it after this change:

- `codediff.core.diff` — the LuaJIT FFI binding to `libvscode-diff`, a C port
  of VSCode's `defaultLinesDiffComputer`. This is what gives us character-level
  refinement, and it also handles downloading the prebuilt binary.
- `codediff.core.git` — revision resolution and file content fetching.
- `codediff.ui.inline`'s `compute_syntax_highlights` and
  `utf16_col_to_byte_col`, and `codediff.ui.highlights` for colour derivation.

What we stop using entirely: `ui.view`, `ui.view.compact`, `ui.view.side_by_side`,
`ui.view.inline_view`, `ui.lifecycle`, `core.path`. **We no longer create a
codediff session at all.** The dependency surface drops from seven modules
spanning the UI and session layers to three leaf modules with no UI involvement.

The README gains a "Built on" section near the top — not a footer — stating
plainly that the diff engine is `libvscode-diff` from codediff.nvim, a C port
of VSCode's algorithm, and recommending codediff.nvim to anyone who wants a
general-purpose diff, merge and git-history tool, which intent-diff is not. An
`ATTRIBUTION.md` modeled on codediff's own credits codediff.nvim, Microsoft's
VSCode (MIT) for the algorithm, and utf8proc (MIT) bundled inside the binary.
`:checkhealth intentdiff` reports the resolved `libvscode-diff` version.

## What changes for a user

Mostly the surfaces converge upward — the intent preview gains what only the
file view had:

- Character-level highlighting inside changed lines, in both views.
- Syntax highlighting, in both views. The preview has none today.
- Comments render and can be created in an intent view. Both refusals go away.
- Folds work in an intent view, so you can unfold context around an intent's
  hunks — impossible today.
- `t` toggles layout consistently, including when anchored on an untracked,
  added or deleted file.
- `preview.max_lines` truncation disappears; folds handle size instead.

Two deliberate visible changes:

- **Diff panes are never real file buffers.** Today a working-tree diff runs
  `:edit <real file>` in the modified pane, so that pane is the actual file,
  editable, with your LSP and gitsigns attached. Under one renderer the panes
  are always read-only scratch buffers. A key opens the real file at the
  cursor's exact `(file, line, side)` in a normal window — identical in
  single-file and intent views, which is more than `hover_opens_files` can do
  today.
- **The per-file view adopts git's chunking**, so hunk boundaries may differ
  slightly from what VSCode's algorithm produced. This is the point: the pane,
  the sidebar and the folds finally agree.

`+`/`-` markers move out of the buffer text into a line highlight plus a
sign-column glyph, and `@@` header rows are dropped in favour of the `── path
M  +3 -1` file separators, since folds already communicate elision.

## The unified concept

Everything is a **render plan**: a list of files, each with its complete diff,
plus a set of hunk ids to leave unfolded.

```lua
plan.build(files, visible, layout, opts)
```

A file view is a plan over one file with all its hunks visible. An intent view
is a plan over that intent's files with that intent's hunks visible. Nothing
else distinguishes them.

```
sidebar cursor (debounced)  ─┐
layout toggle `t`            ├─→ view.show(sess, files, visible)
classification completes     │      ├─ content.ensure(files)
comment added/edited/deleted ┘      ├─ plan.build(files, visible, layout)
                                    ├─ paint.render(plan, win_o, win_m)
                                    └─ marks.render(store, plan.map)
```

All five triggers run one path. Today they fan out across `show_file`,
`show_preview`, `toggle_layout`, `toggle_preview_layout`, `restore` and
`reassert`, each with its own preconditions.

## Chunking: git hunks decide, VSCode decorates

`hunks.lua` stays exactly as it is. `git diff` output remains the source of
truth for where hunks begin and end, which means `classify.lua`, `cache.lua`,
`content_hash`, comment anchoring and the Markdown export are untouched by this
work.

`libvscode-diff` runs only *inside* each changed run — the `minus[]`/`plus[]`
arrays that `pair_body` already builds (`preview.lua:157-198`) — to produce
character ranges for highlighting. The two algorithms can never disagree about
line pairing, because VSCode's only ever runs within a region git already
decided is changed.

Rejected: making `compute_diff` the source of truth for chunking. It would keep
the per-file view pixel-identical to today, but intent boundaries would shift,
every `content_hash` would change (wiping the classification cache once), and
comment anchoring would need revalidation — a large blast radius for a
consistency we get more cheaply above.

Rejected: dropping character-level highlighting to avoid the question. That
ships the unification but regresses the file view, which has character
highlights today.

## Modules

### `intentdiff/render/plan.lua` — pure

`preview.lua` generalized. No Neovim UI state; `paint.lua` puts the result into
buffers. Roughly 400 lines.

```lua
--- @param files table[]  full file entries, each carrying ALL its hunks
--- @param visible table  set of hunk ids to leave unfolded
--- @param layout string  "inline" | "side-by-side"
--- @param opts table|nil { context = integer, line_budget = integer }
--- @return table plan
plan.build(files, visible, layout, opts)
```

The returned plan:

```lua
{
  layout   = "side-by-side",
  original = pane,          -- { lines, spans, map }
  modified = pane,          -- same line count as original, by construction
  files    = {              -- metadata, in render order
    { path = "a.lua", filetype = "lua", status = "M" },
  },
  runs     = {              -- changed runs, for character refinement
    {
      file  = "a.lua",
      minus = { "old text", ... },   -- original-side lines of the run
      plus  = { "new text", ... },   -- modified-side lines of the run
      -- pane rows each side's line i landed on, so paint can place spans
      -- without re-deriving the pairing
      minus_rows = { 12, 13 },
      plus_rows  = { 12, 14 },
    },
  },
  folds    = { {2, 11}, {40, 88} },   -- row ranges to close, both panes
}
```

`folds` is a single list rather than one per pane: equal line counts mean a
fold range is the same rows on both sides.

Three pieces carry over from `preview.lua` essentially unchanged, and they are
the load-bearing ones:

- `pair_body` — deletion and addition runs paired by index, with a filler on
  the shorter side. Deliberately avoids the `x and y or z` idiom, because an
  empty source line is a legitimate falsy-but-real middle term.
- The sparse `map`: row → `{file, line, side}`, with no entry for rows that
  display no line of any file (separators, fillers). Never walk it with
  `ipairs`; walk `1 .. #pane.lines`.
- `rows_for` derived by *scanning* `map` rather than being accumulated
  alongside it. A second, independently-built index is exactly how the renderer
  and the store came to disagree about a drifted comment once already.

`target_at` and `rows_for` keep their current signatures, so `marks.lua` and
`comments/init.lua` call the same functions — just on every surface instead of
one.

New: `files`, `runs` and `folds`. Folds are computed once and are valid for
both panes, because equal line counts mean identical row ranges. This retires
`compute_visible_lines` and all per-side fold logic.

### `intentdiff/render/paint.lua` — impure

Takes a plan and two window ids; roughly 350 lines. Creates the scratch
buffers, sets lines, then decorates in three passes:

1. Line spans from `pane.spans` — add, delete, filler, separator.
2. Syntax, looked up through `map` (see below).
3. Characters, per run: `compute_diff(run.minus, run.plus)`, UTF-16 columns
   converted through `utf16_col_to_byte_col`, merged over syntax highlights the
   way `get_merged_hl` does (`codediff/ui/inline.lua:26`). Spans land on
   `run.minus_rows` and `run.plus_rows`.

Then `foldexpr` from `plan.folds`, and `scrollbind`/`cursorbind` on both
windows.

**Syntax highlighting is computed per `(file, side)`, not per row range.**
`compute_syntax_highlights` parses its input as a single document, so it must
only ever see coherent content. A pane row range is not coherent: in inline
layout the rows interleave deletion lines (original file) with addition and
context lines (modified file), and parsing that mixture would produce garbage
at every changed run. codediff avoids this by keeping the modified buffer real
and rendering deletions as `virt_lines`, which is not available to us once
fillers are real rows.

So paint calls `compute_syntax_highlights(content, filetype)` twice per file —
once over the original file's full content, once over the modified's — caching
the result as `syntax[file][side]`, keyed by *file* line number. Then for each
pane row it reads `map[row]` and looks up
`syntax[t.file][t.side][t.line]`.

This is exact in both layouts, needs no offset arithmetic, and handles
separators and fillers for free: they have no `map` entry, so they get no
syntax. The cache is keyed the same way as `content.lua`'s, so the parse
happens once per file per review rather than once per repaint.

### `intentdiff/render/content.lua`

Session-scoped cache, `(revision, path) → lines`.

```lua
--- Ensure both sides of every file are cached. Returns immediately with
--- `ready = false` for any file still in flight; the caller paints what it
--- can and repaints on the callback.
--- @return boolean ready, table missing
content.ensure(sess, files, on_ready)

--- Cached lines, or nil if not yet fetched.
--- @return string[]|nil
content.get(sess, path, side)
```


| Status | Original side | Modified side |
|---|---|---|
| `M` | `git show <base>:<old_path or path>` | worktree read, or `git show <target>:<path>` |
| `A` / `??` | empty (all fillers) | worktree read |
| `D` | `git show <base>:<path>` | empty (all fillers) |

This is new I/O — the plugin currently never reads file content, only `git
diff` output plus `readfile` for untracked files (`hunks.lua:211`). An intent
touching six files means up to twelve subprocess calls, 60–180ms, which is
unacceptable on every debounced sidebar move. Two mitigations:

- Base-revision content is immutable for the life of a review, so each file is
  fetched at most once. Worktree content is re-read when its file changes,
  which the plugin already tracks for comment invalidation.
- The file list is known from `git diff` before classification returns, so the
  cache is warmed in the background there. Navigation finds it resident.

A cache miss at paint time renders from hunk bodies alone with folds disabled —
today's preview behaviour — and repaints when content lands. It degrades to
today rather than blocking.

### `intentdiff/view.lua`

Owns the tab and two windows, and nothing else. Around 400 lines, down from
1,385. `show_file` and `show_preview` collapse into one `show(sess, files,
visible)`.

Deleted: `bootstrap`, `open_tab`'s tab adoption, `when_diff_ready`,
`wait_for_virtual_file`, `normalize_for_inline`, all three `show_whole_file*`
variants, `reassert`, `ensure_folds_augroup`, `retire_preview_bufs`, and the
`_preview_active` / `_preview_sess` / `_preview_bufs` / `_preview_maps` tables.

## Rendering details

**Alignment.** Both panes are padded to identical line counts with real filler
rows carrying a filler highlight — what `preview.lua` does today. Equal line
counts make fold ranges identical on both sides and let plain
`scrollbind`/`cursorbind` keep the panes together.

Rejected: `virt_lines` fillers, as codediff uses. Buffer line numbers stay
meaningful, but the two buffers differ in length, so folds must be computed per
side and alignment needs codediff's `scrollsync` fill-table model.

**Markers.** No `+`/`-` prefix in the buffer text. The pane text *is* the file
text, so treesitter columns and character ranges are exact without offset
correction, and inline and side-by-side share one text-building path. Sign
column plus line highlight convey the marker.

**Sides.** In side-by-side, a row's side is the pane it is in. In inline, one
buffer holds everything, so side comes from the row's kind: a deletion row
addresses the original file, addition and context rows address the modified
one. Context consumes a line on both sides and is addressed as new. This is the
existing rule (`preview.lua:107-110`), unchanged.

**Deleted, added and untracked files stop being special.** An added file is a
plan whose original side is entirely fillers. This retires the `??`/`A`/`D`
branch in `show_file` (`view.lua:648-672`), the `"D"` fold exclusion and its
explanation of codediff's `single_side` behaviour (`view.lua:636-647`), and the
`t`-cannot-reach-side-by-side limitation.

## Navigation and the edit escape hatch

`]c`/`[c` and `]n`/`[n` read hunk row ranges from the plan, so they are
group-scoped by construction. The `TabLeave`/`TabEnter` re-assert
(`view.lua:120-142`), which exists only because codediff deletes our mappings,
goes away with the session.

The edit escape hatch resolves `map[row]` to `{file, line, side}` and opens
that file in a normal window at that line, identically in single-file and
intent views.

## Error handling

Each rung degrades independently; the surface below it still works.

| Failure | Behaviour |
|---|---|
| Content fetch fails | Render from hunk bodies, folds disabled. Notify once per file, not per repaint. |
| Binary file | Detect at parse time, render one `── path  M  binary` row that maps to nothing. |
| `libvscode-diff` unavailable | Character highlights drop to line-level. Everything else unaffected — chunking comes from git, not the C library. |
| codediff API mismatch | Keep the capability-check pattern (`view.lua:14-49`), narrowed to three leaf modules. Clear message, not a stack trace. |
| Missing treesitter parser | `compute_syntax_highlights` already `pcall`s and returns `{}`. No syntax highlighting, nothing else affected. |
| File exceeds `line_budget` | Fall back to hunks-only rendering for that file, with the reason stated in its separator row. |
| A pane window closed | Degrade to a single pane, as `view.lua:908-915` does today. |

Binary handling is genuinely new work: `hunks.lua` has none. `git diff` emits
`Binary files a/x and b/x differ` with no `@@`, so the parser currently yields
a file entry with zero hunks. That is harmless today because nothing renders
it; under full content we would `git show` a binary.

The `line_budget` replaces `preview.max_lines`. `max_lines` truncated
silently — a row past the cut simply had its `map` entry dropped. The budget
states what it did. It is a per-file guard, defaulting to 20,000 lines, chosen
to sit well above any file a human reviews by hand while still bounding the
plan for generated or vendored files.

## Testing

`plan.lua` is pure and tests like `preview.lua` does today: construct hunks,
assert on rows, `map`, spans and fold ranges. `preview_spec.lua`,
`comments_preview_spec.lua` and `view_preview_spec.lua` largely carry over,
widened to cover the single-file case that previously went down the codediff
path.

`paint.lua` needs integration tests against real buffers: extmark placement,
fold ranges, scrollbind, and syntax lookup through `map` — specifically that an
inline pane highlights a deletion row from the *original* file's parse and the
context row below it from the *modified* file's, since that is the case a naive
per-row-range implementation gets wrong.

New invariant test: `target_at` and `rows_for` must be exact inverses over a
generated plan. That property previously broke between the renderer and the
store, and it is now load-bearing for every surface rather than one.

The migration cost is 90 codediff references across 11 spec files, concentrated
in `integration_spec.lua` (36) and `view_spec.lua` (20), out of 10,175 lines of
tests. Most are assertions that poke codediff's session to verify our
workarounds survived — `stored_diff_result`, `session.layout`, the keymap
re-assert, the `CodeDiff N.N` placeholder-buffer check. They are deleted, not
ported: the behaviours they guard stop existing.

## Highlight groups

`highlight.lua` already defines `IntentDiffAdd`, `IntentDiffDelete`,
`IntentDiffFiller` and `IntentDiffPreviewFile`. The first three carry over
unchanged; `IntentDiffPreviewFile` is renamed `IntentDiffFileSeparator`, since
"preview" stops being a concept. `IntentDiffPreviewHunk` is dropped along with
the `@@` header rows.

New groups, all with conservative defaults derived the way
`codediff.ui.highlights` derives its own — by adjusting the effective
background of the line group rather than hardcoding colours, so they work in
light and dark colourschemes:

- `IntentDiffAddChar` / `IntentDiffDeleteChar` — character-level ranges inside
  a changed line, drawn over the line group and under syntax.
- `IntentDiffSignAdd` / `IntentDiffSignDelete` — the sign-column glyphs that
  replace the `+`/`-` text prefixes.

## Configuration changes

- `preview.max_lines` — removed, replaced by an internal `line_budget` guard.
- `preview.hover_opens_files` — superseded by the edit escape hatch, which
  works on every surface.
- `context_lines` — no longer follows codediff's
  `diff.compact_context_lines`; it becomes ours outright.
- New keymap for the edit escape hatch, in the `view` surface namespace.

## Out of scope

- Changing how hunks are parsed, classified, cached or exported. `hunks.lua`,
  `classify.lua`, `cache.lua` and `comments/export.lua` are untouched.
- Vendoring codediff's code. Considered and rejected in favour of keeping it a
  named dependency; see "Built on codediff.nvim".
- Editing inside diff panes. The escape hatch opens the real file instead.
- Merge conflict resolution, git history browsing, and `:CodeDiff` interop.
  intent-diff never surfaced these.
- Move detection. `compute_diff` can compute it; we do not ask for it.
