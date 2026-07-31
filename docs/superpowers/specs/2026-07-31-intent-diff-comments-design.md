# Review comments and Markdown export

Add line-level review comments to intent-diff, in the style of
[review.nvim](https://github.com/georgeguimaraes/review.nvim), and export them
as Markdown to the clipboard or a file so they can be pasted into an agent
harness (Claude Code, sidekick, …) as the review to act on.

The point of difference from review.nvim: intent-diff knows *why* each change
was made, so the export files every comment under the intent its line belongs
to. The agent reads "here is the intent, and here is what is wrong with it"
rather than an undifferentiated list of file:line notes.

## What a user does

1. `:IntentDiff`, wait for grouping, browse the sidebar as today.
2. In a diff pane, put the cursor on a line (or visually select a range) and
   press `<localleader>cc`. A float asks for a type — Note, Suggestion, Issue,
   Praise — and the comment text. `<Tab>` cycles the type, `<C-s>` submits.
   `<localleader>ci` and friends skip the type step.
3. The comment renders in place: a sign in the gutter, the line highlighted,
   and the text in a box below the line.
4. On a sidebar group row, `<localleader>cf` attaches a comment to the whole
   intent instead of to any line.
5. `<localleader>cy` copies every comment as Markdown; `<localleader>cw`
   writes it to a file. Paste, or point the agent at the path.

Comments persist per repo and revision range, so closing Neovim and coming
back resumes the same review.

## Anchoring model

A comment stores `(file, line, side)` and nothing about intents. Which intent
it belongs to is recomputed on every render and every export, by finding the
hunk whose line range contains that line and asking the model which group owns
that hunk.

This is deliberate. Re-classifying with `R` regroups every hunk; because
intent membership was never stored, every comment re-files itself for free.
Two alternatives were rejected:

- **Anchor to `(hunk_id, offset)`.** Hunk ids are `path:ordinal`, so editing
  the working tree and re-running renumbers them — `src/a.lua:3` can silently
  become a different hunk. Same staleness as line numbers, harder to notice.
- **Extmark-tracked lines.** codediff panes are read-only snapshots that are
  torn down and re-rendered on every file switch, so extmarks would have to be
  re-seeded from stored line numbers anyway. That is the line-number model
  plus a layer.

Within a session nothing drifts: the panes are read-only. Across sessions a
stored line number degrades visibly (see "Unmatched comments" below) rather
than invisibly.

### Determining `side`

`view.diff_wins(tabpage)` already identifies the original and modified
windows. `side` is derived from which window the cursor is in — original pane
→ `"old"`, modified pane → `"new"`. Inline layout is always `"new"`, because
codediff decorates the modified buffer and renders deletions as virtual lines.

An old-side comment can therefore only be *created* in side-by-side layout,
but once created it renders whenever the original pane is visible.

### Determining `line`

`nvim_win_get_cursor` directly. No coordinate translation is needed: codediff
renders alignment fillers as `virt_lines` extmarks rather than real buffer
lines (`codediff/ui/filler.lua`, `codediff/scrollsync.lua`), so buffer line N
is file line N on that side, in both layouts.

### Determining `file`

From the session's currently-shown entry (`view._last_shown`), not by parsing
the buffer name. codediff's `codediff://` URI shapes never have to be
understood.

## Comment record

```lua
--- @class intentdiff.Comment
--- @field file string|nil       repo-relative path; nil for an intent comment
--- @field line integer|nil      1-based; 0 = file-level; nil for an intent comment
--- @field line_end integer|nil  set only for a range comment
--- @field side "old"|"new"|nil  nil for file-level and intent comments
--- @field intent_title string|nil  set only for an intent comment
--- @field type "note"|"suggestion"|"issue"|"praise"
--- @field text string           may contain newlines
--- @field created_at integer    os.time()
```

Five shapes, distinguished by which fields are set:

| Shape | Fields | Location in export |
|---|---|---|
| Line | `file`, `line`, `side` | `src/a.ts:12` |
| Range | `file`, `line`, `line_end`, `side` | `src/a.ts:12-18` |
| Old-side line | `side = "old"` | `src/a.ts:~12` |
| File-level | `file`, `line = 0` | `src/a.ts` |
| Intent | `intent_title` | a paragraph under that heading |

An intent comment anchors to the group's **title**, not to an index. If
re-classification produces a differently-titled group, the comment surfaces as
unattached rather than being silently misfiled onto whatever group happens to
occupy that position.

## Modules

New code lives under `lua/intentdiff/comments/`, one responsibility per file,
following the existing module conventions (a local `M`, `pcall`'d Neovim API
calls, no cross-module state reaching).

| Module | Responsibility |
|---|---|
| `comments/store.lua` | In-memory records: add, update, delete, `get_at_line`, `get_for_file`, `get_all`, `count`, `clear`. No UI, no disk. Writes through to `storage` on mutation. |
| `comments/storage.lua` | JSON persistence keyed by git root + revision range. Load, save, clear, expiry sweep. |
| `comments/popup.lua` | The type-picker and text float. Callback receives `(type, text)` or `(nil, nil)` on cancel. |
| `comments/marks.lua` | Renders signs, line highlights and comment boxes into pane buffers; sidebar intent-row signs; side-by-side alignment padding. |
| `comments/export.lua` | Builds the grouped Markdown and implements the two export targets. |
| `comments/init.lua` | The action layer the keymaps call: resolve cursor context, drive popup → store → marks, navigation, list picker. |

`comments/init.lua` is the only module the rest of the plugin talks to.

## Persistence

Files live under `config.cache_dir .. "/comments/"` — the directory
intent-diff already owns and creates.

The key is git root plus what is being reviewed:

```
<hash(git_root)>-<safe_branch>.json          -- working-tree review
<hash(git_root)>-<rev1>_<rev2>.json          -- explicit revision range
```

`hash` is the same cheap string hash review.nvim uses (multiply-by-31 mod
2^31-1, hex-formatted); `safe_branch` replaces every non-`[%w%-_]` character
with `_`; revisions are truncated to 8 characters with a trailing `^` stripped.
Revisions come from the session's already-resolved `base_revision` /
`target_revision`, not from a fresh `git` call.

Deliberately **not** keyed by the diff-text hash used for the classification
cache: that hash changes the moment a file is edited, which would discard
comments exactly when they are still relevant.

Files older than 7 days are removed by a sweep that runs at most once per
Neovim session, deferred so it never blocks the first render.

Saving is best-effort. An unwritable directory notifies once per session and
the store continues in memory. A corrupt or unparseable file is treated as
empty and logged to `:IntentDiffLog`.

## Rendering

`marks.refresh()` clears the plugin's namespace and re-renders from the store.
It is called after every event that rebuilds a pane:

- `view.show_file`
- `view.toggle_layout` and `view.toggle_preview_layout`
- `view.apply_group_folds`
- `view.restore`
- any store mutation

Per comment, in the buffer for its `side` — and, for a file-level comment
(which has no side), in both panes:

- **Single line** — one extmark carrying `sign_text` (the type icon),
  `sign_hl_group`, `line_hl_group`, and `virt_lines` holding the box.
- **Range** — sign and line highlight on the first line, line highlight on
  each interior line, and the box on the last line.
- **File-level** — the same at line 0 with `virt_lines_above = true`, plus a
  `winsaveview`/`winrestview` `topfill` nudge so a box above the first line is
  actually visible.
- **Intent** — a sign on the group's first title row in the sidebar. No box:
  the sidebar is a dense navigation surface and boxes would push rows around.

The box is review.nvim's: a rounded border with the uppercased type name in
the top edge, sized to the widest text line with a minimum width of 20.

Because a box on one side makes that side taller, side-by-side panes are
re-aligned after rendering: for each anchor line, the shorter side receives
blank `virt_lines` padding in a separate namespace equal to the height
difference. Without this, codediff's scroll sync drifts.

Every extmark call is `pcall`'d — a bad line number costs that one mark, not
the whole render.

## Highlights

Following the existing convention, each group is defined with
`default = true` and re-established from the plugin's `ColorScheme` autocmd.

| Group | Default link | Used for |
|---|---|---|
| `IntentDiffCommentNote` | `DiagnosticHint` | Note sign and box border |
| `IntentDiffCommentSuggestion` | `DiagnosticInfo` | Suggestion sign and box border |
| `IntentDiffCommentIssue` | `DiagnosticWarn` | Issue sign and box border |
| `IntentDiffCommentPraise` | `DiagnosticOk` | Praise sign and box border |
| `IntentDiffCommentNoteLine` | `CursorLine` | Commented line background, note |
| `IntentDiffCommentSuggestionLine` | `CursorLine` | …suggestion |
| `IntentDiffCommentIssueLine` | `CursorLine` | …issue |
| `IntentDiffCommentPraiseLine` | `CursorLine` | …praise |

Group names are derived from the type key: `IntentDiffComment` plus the key
with its first letter capitalised, and the same again with a `Line` suffix. A
type configured beyond the built-in four therefore gets
`IntentDiffComment<Key>` / `IntentDiffComment<Key>Line`, which the plugin
defines pointing at the note defaults so an unstyled custom type still renders
rather than erroring.

## Popup

A self-contained float, built with the same machinery as the existing `g?`
cheatsheet — no new plugin dependency. Two stacked floats: a one-line type
selector and a multi-line text area, centred, 60 columns wide.

```
╭─ Type (⇥ to switch) ─────────────────╮
│ ✍ Note 💡 Suggestion [⚠ Issue] ✨ … │
╰──────────────────────────────────────╯
╭─ Comment (^s submit) ────────────────╮
│ This import still points at the      │
│ old module.█                         │
╰──────────────────────────────────────╯
```

The selected type is bracketed and the row is truncated with `…` when the
configured types do not fit the 60-column width; `<Tab>` cycles (both insert
and normal mode).
Focus starts in the text area in insert mode. `<C-s>` submits, `<Esc>` and `q`
cancel, and cancelling or submitting empty text discards the comment. Focus
returns to the window the popup was opened from.

When editing an existing comment the popup opens pre-filled with its current
type and text.

## Keymaps

A new `keymaps.comments` surface in the config table — cross-surface by
nature, installed on both the diff panes and the sidebar. Every binding goes
through the existing `keymaps.install` helper, so `false` disables an action
and a list binds several keys to one.

| Action | Default | Meaning |
|---|---|---|
| `add_comment` | `<localleader>cc` | Add, picking the type in the popup (normal and visual) |
| `add_note` | `<localleader>cn` | Add a note directly |
| `add_suggestion` | `<localleader>cs` | Add a suggestion directly |
| `add_issue` | `<localleader>ci` | Add an issue directly |
| `add_praise` | `<localleader>cp` | Add praise directly |
| `add_file_comment` | `<localleader>cf` | File-level comment; on a sidebar group row, an intent comment |
| `edit_comment` | `<localleader>ce` | Edit the comment at the cursor |
| `delete_comment` | `<localleader>cd` | Delete the comment at the cursor |
| `list_comments` | `<localleader>cl` | List every comment and jump to one |
| `next_comment` | `]n` | Jump to the next comment |
| `prev_comment` | `[n` | Jump to the previous comment |
| `export_clipboard` | `<localleader>cy` | Copy the Markdown ("yank") |
| `export_file` | `<localleader>cw` | Write the Markdown to a file |
| `clear_comments` | `<localleader>cx` | Delete every comment in this review |
| `export_and_close` | `<localleader>q` | Copy the Markdown, then close the review tab |

`<localleader>q` is the review.nvim end-of-review flow: finish, copy, paste
into the agent. Plain `q` keeps meaning exactly what it means today — close
the tab, touch nothing else — so the clipboard is only ever written by a key
that says it writes the clipboard. When there are no comments,
`<localleader>q` notifies and still closes, rather than refusing to close.

`<localleader>` is `\` by default and the two keys differ in their first
keystroke, so binding `<localleader>q` costs plain `q` no `timeoutlen` delay.

In visual mode `add_comment` and the four direct-type actions use the `'<`/`'>`
marks and produce a range comment.

Which shape an add action produces depends on where the cursor is, not on
which action was pressed. In a diff pane every add action except
`add_file_comment` produces a line or range comment; on a sidebar group row
*every* add action produces an intent comment, since there is no line to
attach to. `add_file_comment` is the only action whose shape differs by
surface: a file-level comment in a diff pane, an intent comment on a group
row. On a sidebar file row it produces a file-level comment for that file.

The `g?` cheatsheet is built from the config table, so these appear there with
no extra work — rebound keys show up rebound, disabled ones not at all.

## Commands

| Command | Behaviour |
|---|---|
| `:IntentDiffCommentsYank` | Copy the Markdown to `+` and `*`, notify with the count |
| `:IntentDiffCommentsWrite [path]` | Write the Markdown to `path`; without an argument, prompt |
| `:IntentDiffCommentsList` | The comment list/jump picker |
| `:IntentDiffCommentsClear` | Delete every comment in this review, after confirmation |

`:IntentDiffCommentsWrite` without an argument opens `vim.ui.input`,
pre-filled with the last path used this session and otherwise with
`.intentdiff-review.md`. A relative path resolves against the git root. Parent
directories are created. The resolved path is reported on success.

Both export commands warn and do nothing when there are no comments — in
particular, `Yank` must not clobber the clipboard with a "no comments" string.
Neither clears the store: exporting twice, or to both targets, is normal.

## Export format

Numbering runs continuously across groups. Groups appear in sidebar order with
`Ungrouped` last. Within a group, comments sort by file path, then by line,
with the file-level comment for a file before its line comments (this can
differ from the sidebar's tree order, which lists directories first).

```markdown
I reviewed your code and have the following comments. Please address them.

Comment types: ISSUE (problems to fix), SUGGESTION (improvements),
NOTE (observations), PRAISE (positive feedback)
Lines prefixed with ~ refer to the old (left) side of the diff.

## Rename UserService to AccountService

This rename missed the DI container entirely — see below.

1. **[ISSUE]** `src/api/routes.ts:12`
   This import still points at the old module.

2. **[SUGGESTION]** `src/services/account.ts:~45`
   The old implementation was cleaner.

## Add retry logic to HTTP client

3. **[PRAISE]** `src/http/client.ts`
   Good call keeping the timeout separate.

4. **[NOTE]** `src/http/client.ts:44-51`
   No jitter here — fine for now.
```

Details that matter:

- The unattached paragraph under a heading is that intent's own comment. A
  group can have several; they are emitted in creation order, before the
  numbered list.
- Comment text sits on its own lines, indented three spaces, rather than after
  a ` - ` separator. review.nvim's single-line format corrupts the list when a
  comment contains newlines; this does not.
- The `~` trailer line is emitted **only when an old-side comment exists**, so
  there is never a legend for notation the document does not use.
- The type legend is always emitted, since the type tags always appear.

### Fallbacks

- **No groups yet** — while classification is running, or after it failed,
  there is no meaningful grouping. The export degrades to a single flat
  numbered list with no `##` headings, keeping the header and trailer lines.
- **Unmatched comments** — a comment whose line lands in no hunk (typically a
  persisted comment from before the working tree changed), or an intent
  comment whose title no longer matches any group, is emitted under a trailing
  `## Unmatched comments` heading. Flagged, never dropped — the same
  philosophy as the sidebar's visible `Ungrouped` bucket.

## Configuration

```lua
comments = {
  enabled = true,

  -- Comment types, in the order the popup cycles them. Each needs a name,
  -- an icon, and the two highlight groups above.
  types = {
    { key = "note",       name = "Note",       icon = "✍" },
    { key = "suggestion", name = "Suggestion", icon = "💡" },
    { key = "issue",      name = "Issue",      icon = "⚠" },
    { key = "praise",     name = "Praise",     icon = "✨" },
  },

  -- Days before a stored review is swept. false disables the sweep.
  expire_days = 7,

  -- Default path offered by :IntentDiffCommentsWrite, relative to the
  -- git root.
  export_path = ".intentdiff-review.md",
}
```

Setting `comments.enabled = false` installs no keymaps and no autocmds, and
the feature never loads its modules. The four `:IntentDiffCommentsYank` /
`…Write` / `…List` / `…Clear` commands ARE still registered, because
`plugin/` runs before `setup()` and so cannot know the user's setting yet;
each one refuses with a notice while comments are disabled. Either way the
feature is inert — the plugin behaves exactly as it does today.

## Error handling

No failure path may cost a comment the user has typed.

| Situation | Behaviour |
|---|---|
| `cache_dir` unwritable | Notify once per session; store continues in memory |
| Stored JSON corrupt | Treated as empty; logged to `:IntentDiffLog` |
| Second comment on a line that already has one | Refused: "Comment already exists at this line. Use edit instead." |
| Comment range overlaps an existing range comment | Same refusal |
| `edit`/`delete` with no comment at the cursor | Notice, no-op |
| Add on a row resolving to no file and no group | Notice, no-op |
| Export with zero comments | Warning; clipboard and files untouched |
| Export file path unwritable | Error naming the path; store untouched |
| Extmark rejected (bad line) | `pcall`'d; that mark is skipped, the render continues |

Storage writes and the expiry sweep are logged to `:IntentDiffLog` alongside
the existing classification diagnostics, so a review that fails to persist is
diagnosable after the fact.

## Testing

Plenary busted specs under `tests/`, matching the existing naming and using
`tests/helpers.lua` for temp repositories.

| Spec | Covers |
|---|---|
| `comments_store_spec` | add / update / delete; duplicate and overlap rejection; `get_at_line` range containment; `get_for_file` side filtering |
| `comments_storage_spec` | round-trip; key derivation for working-tree vs revision-range reviews; expiry sweep; corrupt-file and unwritable-directory tolerance |
| `comments_export_spec` | grouping and ordering; continuous numbering; old-side `~`; ranges; file-level; intent paragraphs; conditional `~` trailer; flat fallback; unmatched section; empty-store behaviour |
| `comments_marks_spec` | extmark placement for single, range, file-level and intent comments; side-by-side alignment padding |
| `comments_popup_spec` | type cycling; submit; cancel; empty-text discard; pre-fill when editing |
| `integration_spec` (extended) | add → render → reclassify → export, asserting comments re-file under the new intents |

`comments_export_spec` carries the most weight: the export is the plugin's
contract with the agent, and it is pure — a store plus a model in, a string
out — so it can be tested exhaustively without a running review tab.

## Out of scope

- Sending comments to sidekick.nvim. review.nvim has it; clipboard and file
  cover the stated workflow, and the export module is where it would slot in
  later.
- Commenting inside whole-intent preview buffers, which would need a reverse
  map from a concatenated preview line back to `(file, line, side)`.
- Threading, replies, or resolving comments.
- Reading an agent's response back into the review.
