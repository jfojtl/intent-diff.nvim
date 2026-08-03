# intent-diff.nvim

Review a git diff grouped by *reason of change* instead of by file. A sidebar
lists LLM-generated groups ("Rename UserService → AccountService", "Add retry
logic", "Drive-by lint fixes"); each group contains the files it touches, and
opening a file shows only that group's hunks — the rest of the file's diff is
folded away. Rendering is delegated to
[codediff.nvim](https://github.com/esmuellert/codediff.nvim); intent-diff only
adds grouping, a sidebar, and group-scoped navigation on top of it.

The sidebar below is the *real* output of `sidebar.layout()` (generated
headlessly against a representative model, not hand-drawn — no column
alignment, no tree-drawing characters, and only the nonzero side of a
`+A`/`-B` stat is ever shown):

```
▾ Rename UserService to AccountService
  2 hunks · 2 files  +2 -2
   ▾ src
     ▾ api
 M       routes.ts  +1 -1
     ▾ services
 M       account.ts  +1 -1
▾ Add retry logic to HTTP client
  1 hunks · 1 files  +3
   ▾ src/http
 M     client.ts  +3
▾ Ungrouped
  1 hunks · 1 files  +3
   ▾ docs
 ?     notes.md  +3
4/4 hunks · claude:haiku
```

The LLM never decides *what* changed, only how to *label* it: every hunk in
the diff ends up in exactly one group or in the visible "Ungrouped" bucket —
never silently dropped. Worst case with a bad LLM response is one boring
Ungrouped group, degrading toward plain codediff, never below it.

## Requirements

- Neovim ≥ 0.10
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- `claude` CLI on `$PATH` (only needed for the default provider; swap in your
  own provider to avoid the dependency — see below)

## Installation (lazy.nvim)

```lua
local function default_branch()
  local ref = vim.fn.systemlist("git rev-parse --abbrev-ref origin/HEAD")[1]
  if vim.v.shell_error == 0 and ref and ref ~= "" then
    return ref:gsub("^origin/", "")
  end
  for _, name in ipairs({ "main", "master", "develop" }) do
    vim.fn.system("git rev-parse --verify --quiet " .. name)
    if vim.v.shell_error == 0 then
      return name
    end
  end
  return "HEAD"
end

return {
  {
    dir = "~/dev/github.com/jfojtl/intent-diff.nvim",
    name = "intent-diff.nvim",
    dependencies = { "esmuellert/codediff.nvim" },
    cmd = "IntentDiff",
    opts = {},
    keys = {
      { "<leader>gVv", "<cmd>IntentDiff<cr>", desc = "IntentDiff: working tree" },
      { "<leader>gVH", "<cmd>IntentDiff HEAD~1<cr>", desc = "IntentDiff: vs previous commit" },
      {
        "<leader>gVb",
        function()
          vim.cmd("IntentDiff " .. default_branch() .. "...")
        end,
        desc = "IntentDiff: branch vs default (merge-base)",
      },
    },
  },
}
```

`:IntentDiff [revision-args]` accepts the same argument forms as codediff's
`:CodeDiff` — no args (working tree), a single revision, `revision...` for
merge-base-relative, or `base target`.

`:IntentDiffSidebar` is the command-line equivalent of the `<leader>b` key
described under "Keymaps" below, showing/hiding the sidebar.
`:IntentDiffToggleAll` collapses every intent if any is expanded and expands
every one otherwise; it has no default key (`zR` and `zM` do the two halves
explicitly), but `keymaps.sidebar.fold_toggle_all` can bind it.

## Configuration

Defaults, passed via `opts` (or `require("intentdiff").setup(opts)`):

```lua
{
  -- Grouping provider: a name under intentdiff.providers.*, or a
  -- function(request, callback) — see "Custom providers" below.
  provider = "claude_cli",

  -- Options passed to the resolved provider. For claude_cli:
  provider_opts = {
    cmd = "claude",        -- CLI binary to run
    model = "haiku",       -- --model passed to `claude -p`
    timeout_ms = 180000,   -- kill the job and report failure after this long

    -- Tool restrictions passed to `claude -p` as --disallowedTools /
    -- --allowedTools (comma-joined). This process runs pointed at the
    -- user's own — possibly uncommitted — working tree, so by default it
    -- can look but not touch: no edits, only read-only git/file access. An
    -- empty list (`{}`) or `nil` omits the corresponding flag entirely
    -- rather than passing an empty value.
    disallowed_tools = { "Edit", "Write", "NotebookEdit" },
    allowed_tools = {
      "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
      "Bash(git blame:*)", "Bash(git status:*)", "Read", "Grep", "Glob",
    },

    -- Let the model run those read-only git commands and read files in the
    -- repo on its own, to understand WHY a change was made, instead of
    -- intent-diff pre-stuffing commit messages or `git log` output into the
    -- prompt. The job's cwd is set to the repo root so its commands land in
    -- the right place. Set to `false` to keep the prompt fully
    -- self-contained (today's behavior).
    agentic = true,
  },

  -- Lines of context around each hunk when computing folds. nil = follow
  -- codediff's own diff.compact_context_lines setting.
  context_lines = nil,

  -- Width (columns) of the sidebar split.
  sidebar_width = 40,

  -- File icons from nvim-web-devicons (if installed) in the sidebar's file
  -- tree. Silently omitted if the plugin isn't present, or set to false here.
  icons = true,

  -- Auto-open the first file worth looking at instead of leaving codediff's
  -- diff panes empty until you press <CR>: the first file of the flat "All
  -- changes" list while classification is still running, then the first
  -- file of the first real group once it completes. A manual selection (or
  -- ]c/[c navigation) always wins — auto-open never overrides it, it just
  -- keeps folds in sync with the group your open file ends up in. Focus
  -- stays in (or returns to) the sidebar so you can keep navigating rows.
  -- Set to false to keep the sidebar-only-until-<CR> behavior.
  auto_open = true,

  -- Above this diff size (bytes), the prompt sends per-hunk summaries only
  -- (file + the hunk's first 4 lines, then "… (N more lines)") instead of the
  -- full diff text.
  max_full_diff_bytes = 100 * 1024,

  -- Above this many hunks, classification is skipped entirely with a
  -- notice — the sidebar stays in flat file-list mode.
  max_hunks = 600,

  -- Added and untracked files arrive from git as a single whole-file hunk, so
  -- they could only ever belong to one intent. Splitting them at blank-line
  -- boundaries lets different parts of one new file land in different
  -- intents, and makes the group fold filter meaningful for them (see "Added
  -- and untracked files" below). Set enabled = false to restore one hunk per
  -- added/untracked file.
  added_file_split = {
    enabled = true,
    min_lines = 60,    -- files shorter than this stay a single hunk
    target_lines = 40, -- approximate lines per sub-hunk once split
  },

  -- Where classification results are cached, keyed by diff-text hash.
  cache_dir = vim.fn.stdpath("cache") .. "/intentdiff",

  -- Diagnostics log used by :IntentDiffLog (see "Diagnostics" below).
  log_file = vim.fn.stdpath("cache") .. "/intentdiff/intentdiff.log",

  -- Cursor-driven navigation: moving the sidebar cursor onto a group or
  -- directory row shows that intent's complete diff in the diff panes, with
  -- a separator per file; moving it onto a file row renders that file's own
  -- diff (see "Previewing an intent" below).
  preview = {
    enabled = true,
    debounce_ms = 120,  -- cursor settle time before rendering, so scrolling
                         -- past rows doesn't thrash the panes
    max_lines = 20000,  -- cap on a group/directory preview's length; the
                         -- omitted count is stated
    hover_opens_files = true, -- moving the cursor onto a file row renders
                               -- its diff too; false requires <CR> instead
                               -- and just restores the last-opened file
  },

  -- Review comments attached to diff lines and to whole intents, exported as
  -- Markdown for an agent to act on. See "Review comments" above and
  -- :IntentDiffCommentsYank / …Write / …List / …Clear.
  comments = {
    enabled = true,

    -- Comment types, in the order the popup cycles them. Each needs a name
    -- and an icon; its highlight groups are derived from `key`, not listed
    -- here — see "Highlights" above. A type added beyond the built-in four
    -- gets working (if unstyled) highlight defaults for free.
    types = {
      { key = "note",       name = "Note",       icon = "✍" },
      { key = "suggestion", name = "Suggestion", icon = "💡" },
      { key = "issue",      name = "Issue",       icon = "⚠" },
      { key = "praise",     name = "Praise",     icon = "✨" },
    },

    -- Days before a stored review is swept, so a review left over from a
    -- long-abandoned branch doesn't accumulate under cache_dir forever. Runs
    -- at most once per session, deferred so it never blocks the first
    -- render. false disables the sweep entirely.
    expire_days = 7,

    -- Default path :IntentDiffCommentsWrite offers (and pre-fills with on
    -- repeat use within a session), resolved against the git root when
    -- relative.
    export_path = ".intentdiff-review.md",
  },

  -- Buffer-local keys the plugin installs inside a review tab, namespaced by
  -- surface the way codediff namespaces its own (keymaps.view / .explorer /
  -- .history / .conflict). Set any action to `false` to install nothing,
  -- exactly as the plugin already handles codediff's own toggle_layout key
  -- being disabled. An action may also be a LIST of keys, all bound to it.
  keymaps = {
    -- The diff panes, and the whole-intent preview buffers.
    view = {
      quit = "q",             -- preview buffers; the panes use codediff's own
      -- Show/hide the sidebar. Named after (and sharing a default with)
      -- codediff's keymaps.view.toggle_explorer, because our sidebar is that
      -- explorer's counterpart. Installed on the sidebar AND on the diff
      -- panes, since a sidebar-only key is unreachable once the sidebar is
      -- hidden — and it works even when codediff's own layout-toggle key is
      -- disabled.
      toggle_sidebar = "<leader>b",
      next_hunk = "]c",       -- group-scoped: only this intent's hunks
      prev_hunk = "[c",
      show_help = "g?",
    },
    -- The intent sidebar.
    sidebar = {
      select = "<CR>",
      quit = "q",
      reclassify = "R",       -- was `r`; `R` is what codediff's explorer uses
      goto_file = "gf",
      next_group = "<Tab>",
      prev_group = "<S-Tab>",
      show_help = "g?",
      -- Vim-style folds, matching codediff's explorer set. On a directory row
      -- these act on that directory; anywhere else in an intent (title, stats
      -- line, file row) they act on the enclosing intent. "Recursive" means
      -- the row plus every directory beneath it.
      fold_open = { "zo", "l" },
      fold_open_recursive = "zO",
      fold_close = { "zc", "h" },
      fold_close_recursive = "zC",
      fold_toggle = "za",
      fold_toggle_recursive = "zA",
      -- Whole-sidebar. Per-directory state is deliberately preserved, so
      -- re-expanding restores the tree you had arranged.
      fold_open_all = "zR",
      fold_close_all = "zM",
      -- The pre-namespacing `zA` — collapse every intent if any is expanded,
      -- else expand every one. `zA` now means fold_toggle_recursive, so this
      -- is unbound by default and reachable as :IntentDiffToggleAll.
      fold_toggle_all = false,
    },
    -- Review comments. Cross-surface by nature: an intent comment is added
    -- from a sidebar group row, a line comment from a diff pane or a
    -- whole-intent preview row, and every surface needs the export keys — so
    -- this is installed on all three, not one.
    comments = {
      add_comment = "<localleader>cc", -- pick the type in the popup
      add_note = "<localleader>cn",
      add_suggestion = "<localleader>cs",
      add_issue = "<localleader>ci",
      add_praise = "<localleader>cp",
      add_file_comment = "<localleader>cf", -- file-level; an intent comment on a sidebar group row
      edit_comment = "<localleader>ce",
      delete_comment = "<localleader>cd",
      list_comments = "<localleader>cl",
      next_comment = "]n",
      prev_comment = "[n",
      export_clipboard = "<localleader>cy",
      export_file = "<localleader>cw",
      clear_comments = "<localleader>cx",
      -- The review.nvim end-of-review flow: copy, then close. Plain `q`
      -- still closes without touching the clipboard — the two differ in
      -- their first keystroke, so this costs `q` no timeoutlen delay.
      export_and_close = "<localleader>q",
      -- Popup-local keys for the comment entry float (comments/popup.lua),
      -- buffer-local to its text area rather than tab-wide — not listed in
      -- the g? cheatsheet, which only covers tab-wide surfaces.
      popup_cycle_type = "<Tab>",
      popup_submit = "<C-s>",
      popup_cancel = "q",
    },
  },
}
```

### Migrating from the flat `keymaps` table

The old flat `keymaps.toggle_sidebar` / `keymaps.toggle_all` still work — they
are rewritten to `keymaps.view.toggle_sidebar` and
`keymaps.sidebar.fold_toggle_all` at `setup()` time, with a one-line notice.
Three defaults changed, so if you had been relying on them:

| Was | Now | To keep the old key |
|---|---|---|
| `<leader>gVt` show/hide sidebar | `<leader>b` | `view = { toggle_sidebar = "<leader>gVt" }` |
| `r` re-classify | `R` | `sidebar = { reclassify = "r" }` |
| `zA` expand/collapse every intent | `zR` / `zM`, explicitly | `sidebar = { fold_toggle_recursive = false, fold_toggle_all = "zA" }` |

## Custom providers

A provider is a function that receives the hunk inventory and returns groups
asynchronously:

```lua
--- @param request {
---   diff_text: string|nil,
---   hunks: { id: string, n: integer, file: string, summary_lines: string[] }[],
---   numbering: table<integer, string>,       -- n -> hunks[i].id
---   repo: { git_root: string, base_revision: string?, target_revision: string? }|nil,
--- }
--- @param callback fun(result: { groups: { title: string, ids: string?, hunk_ids: string[]? }[] }|nil, err: string|nil)
local function my_provider(request, callback)
  -- e.g. call a different CLI, an HTTP API, or return a static grouping.
  vim.system({ "codex", "exec", "--json" }, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return callback(nil, "codex exited " .. res.code)
      end
      local ok, decoded = pcall(vim.json.decode, res.stdout)
      if not ok then
        return callback(nil, "malformed JSON from codex")
      end
      callback(decoded)
    end)
  end)
end

require("intentdiff").setup({
  provider = my_provider,
})
```

`request.diff_text` is the full unified diff **or `nil`** — it is dropped when
the diff exceeds `max_full_diff_bytes`, so a custom provider must nil-check it
and fall back to `request.hunks`. Each `hunks[i].summary_lines` holds the
hunk's first 4 raw diff lines plus a `… (N more lines)` marker when it was
longer, and is always present regardless of diff size.

Each hunk also carries a compact integer `n` (1..N, inventory order), and
`request.numbering` is the `n -> id` map — this is what makes the compact
response format below possible. `request.repo`, when present, names the repo
root and revision range being reviewed; a provider can use it to run its own
read-only lookups (see "Read-only tool allowlist" and "Agentic lookup
channel" below) instead of relying solely on `request.diff_text`/`hunks`.

### Group response shape

Each returned group may identify its hunks either way — **both are accepted,
and may even appear in the same response**:

- **Compact (preferred; what claude_cli asks the model for):**
  `{ title = "...", ids = "1-4,7,12-15" }` — `ids` is a string of integers
  with ranges, referring to `hunks[i].n` / `request.numbering`, not the
  hunks' `id` strings. It's also tolerant of a JSON array of numbers
  (`{1,2,3}`) or a bare number.
- **Legacy:** `{ title = "...", hunk_ids = { "src/a.lua:1", ... } }` — the
  original array-of-inventory-id-strings shape. Still fully supported; a
  provider that only ever emits this keeps working identically.

Providers never need to worry about completeness: ids/hunk_ids you omit,
mistype, or that fail to map back to a real hunk are reconciled by the plugin
itself — missing hunks land in Ungrouped, hallucinated or unmappable ids are
discarded, and duplicates keep only the first group. Run async and never
block the UI.

Return a cancel handle — `{ cancel = function() … end }` — if your provider can
be aborted: intent-diff calls it when a newer classification supersedes yours
(e.g. the user pressed `r`) or when the review tab is closed, so the abandoned
request does not keep running.

## Read-only tool allowlist

`claude_cli` runs pointed at the repo being reviewed — including any
uncommitted changes in the working tree — so by default it's restricted to
read-only tools: `provider_opts.disallowed_tools` (`--disallowedTools`)
blocks `Edit`/`Write`/`NotebookEdit`, and `provider_opts.allowed_tools`
(`--allowedTools`) scopes it to read-only git subcommands plus
`Read`/`Grep`/`Glob`. Both are plain string lists, comma-joined onto the
flag; set either to `{}` (or `nil`) to omit that flag entirely and fall back
to `claude`'s own defaults. This is a safety measure, not a correctness one —
the grouping itself is validated independently (see "completeness" above);
the allowlist exists so a misbehaving or adversarially-prompted model can't
edit the diff it's supposed to be describing.

## Agentic lookup channel

By default (`provider_opts.agentic = true`) claude_cli tells the model it may
run read-only git commands and read files in the repo — comparing the exact
base/target revisions being reviewed — to understand *why* a change was made,
rather than intent-diff guessing at that by stuffing commit messages or `git
log` output into the prompt itself (it deliberately doesn't). The job's
working directory is set to the repo root so those commands land in the right
place. The model still must answer using the hunk numbers given in the
prompt, not file paths or line numbers, and still must not modify anything
(enforced by the tool allowlist above, not by the prompt instruction alone).

Set `provider_opts.agentic = false` to turn this off and go back to a fully
self-contained prompt (today's original behavior, and useful if you'd rather
not have the model spend time/tokens shelling out).

## Sidebar

Each group renders as a wrapped title line (long LLM-generated titles wrap
onto multiple lines rather than being truncated) followed by a stats line —
`N hunks · M files`, then `+A`, `-B`, or both, whichever are nonzero (a zero
side is never printed — see the real output below). Below that, when the
group is expanded, is a file tree: directories are their own rows, and a
chain of directories with only one child at each level is compressed onto a
single row (`src/services/api` instead of three nested `src` → `services` →
`api` rows) — exactly the compression codediff itself uses for the same
reason. File rows show a one-character status gutter (`A`, `M`, `D`, or `?`
for untracked) and, when `icons = true` and
[nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) is
installed, a file-type icon; both degrade silently (gutter letter still
shows, icon just omitted) when devicons isn't present. Rows are not
column-aligned — a file's name butts directly up against its indent, and its
stats immediately follow its name — exactly as in the real output above.

`za`, `h`, and `l` are interchangeable collapse/expand keys: on a directory
row they toggle that directory; on any other row in the group — a title
line, the stats line, or even one of its file rows — they toggle the
*enclosing group* instead, so standing on a file row and pressing `za`
collapses the whole group it belongs to. `<CR>` behaves the same way on a
group or directory row (toggles it); on a file row it renders that file's
diff if the cursor hasn't already done so (see "Previewing an intent"
below), then moves focus into the diff pane so you can scroll and search it.
If the cursor already rendered that exact file, `<CR>` is a pure focus
change — nothing is re-rendered.

## Previewing an intent

With `preview.enabled = true` (the default), the sidebar cursor drives the
diff panes on its own — no key press needed — after `preview.debounce_ms` of
the cursor sitting still, so scrolling past several rows doesn't thrash the
panes. What lands in the panes depends on the kind of row the cursor is on:

- **A group row** (any of its title lines or its stats line) previews that
  group's whole diff: every file it touches, each preceded by a
  `── path   status   +A -B` separator line (three spaces on either side of
  `status`), in file-tree order.
- **A directory row** previews just that subtree — the same rendering,
  restricted to the files under that directory.
- **A file row renders that file's own diff** — folded to whichever group it
  belongs to, exactly like `<CR>` would show — while leaving focus in the
  sidebar so you can keep browsing with `j`/`k`. This is
  `preview.hover_opens_files`, on by default; set it to `false` to go back to
  the older behavior, where hovering a file row just restores the panes to
  whatever file was last opened via `<CR>`, and only `<CR>` renders it.

The group/directory preview is capped at `preview.max_lines`; a truncated
preview's last line states how many more lines were omitted rather than
silently cutting off.

This is the real output of `preview.render()` (inline layout) for the same
"Rename UserService to AccountService" group shown above:

```
── src/api/routes.ts   M   +1 -1
@@ -4,2 +4,2 @@
-import { UserService } from './user-service'
+import { AccountService } from './account-service'
── src/services/account.ts   M   +1 -1
@@ -12,3 +12,3 @@
-export class UserService {
+export class AccountService {
   constructor(private db: Db) {}
```

Inside the preview, `]c`/`[c` jump the cursor to the next/previous hunk
header (no wraparound: at the first or last hunk they simply do nothing), and
codediff's own layout-toggle key (`t` by default) flips the preview between
inline and side-by-side exactly like it does for a normal diff — it restores
the last-selected file, performs the ordinary layout toggle on it, and then
re-renders the preview in the new layout. `q` closes the review tab from
inside the preview too, same as from the sidebar.

### Commenting on a preview

The preview takes comments, with the same keys and the same popup as a real
file diff — looking at an intent and commenting on it is one thing, not two.
Each body row of the preview knows which file, line and side it displays, so a
comment made there is stored as an ordinary `(file, line, side)` record: there
is nothing "preview" about it in the store, on disk, or in the export. Comment
on an intent, then open the file — the box is already there, on the same line;
comment in the file, then hover its intent — it is there too.

What still refuses, and why:

- **A `── path` separator, a `@@` hunk header, a side-by-side filler row and
  the truncation summary line.** These display no line of any file, so there
  is nothing to attach to. The refusal says so and names the fix.
- **A visual range covering two files.** A comment records one file; select
  within one file's diff instead. A range *inside* one file works, and a range
  in the inline layout takes its side from its first `+`/`-`/context row.
- **`]n` / `[n`** stay refused in a preview, as does the comment list picker's
  jump — the list opens the real file rather than jumping inside the preview.

File-level and whole-intent comments are not drawn in a preview (they hang off
a file's line 1 and off a sidebar row respectively, neither of which the
preview has), and a comment whose line falls outside what the preview renders
— another intent's file, or past `preview.max_lines` — simply isn't drawn
there. In every case the comment still exists and still exports.

## Review comments

Put comments directly on a diff, in the style of
[review.nvim](https://github.com/georgeguimaraes/review.nvim), then export
them as Markdown to hand to an agent. The difference from review.nvim: intent-
diff knows *why* each change was made, so the export files every comment under
the intent its line belongs to — an agent reads "here is the intent, and here
is what's wrong with it" instead of an undifferentiated list of file:line
notes.

### Adding a comment

Four types — Note (`✍`), Suggestion (`💡`), Issue (`⚠`), Praise (`✨`) —
cycled with `<Tab>` in the popup, and reachable directly without it:

| Key | Adds |
|---|---|
| `<localleader>cc` | Pick the type in the popup |
| `<localleader>cn` | Note |
| `<localleader>cs` | Suggestion |
| `<localleader>ci` | Issue |
| `<localleader>cp` | Praise |

Which *shape* of comment one of these produces depends on where the cursor
is, not on which key was pressed:

- **Line** — cursor on a line in a diff pane, or on a body row of a
  whole-intent preview (see "Commenting on a preview" above).
- **Range** — a visual selection (`'<`/`'>`) in a diff pane, or within one
  file's rows of a preview.
- **File-level** — `<localleader>cf` (`add_file_comment`) in a diff pane, or
  on a sidebar **file** row. In a preview it applies to the file the cursor's
  row belongs to.
- **Whole-intent** — `<localleader>cf`, or in fact any of the five add keys
  above, on a sidebar **group** row: there is no line to attach to there, so
  every add action produces an intent comment. This is the only case where
  the row, not the key, decides the shape.

An intent comment anchors to the group's *title*, not an index, so
re-classifying under a differently-named group leaves the comment surfacing
as unattached — in the export's "Unmatched comments" section — rather than
silently landing on whatever group now occupies that slot.

### Old side vs. new side

A comment's side is derived from which window the cursor is in when it's
created — the original pane → `"old"`, the modified pane → `"new"`. Inline
layout only ever has one window (the modified buffer; deletions render as
virtual lines), so **an old-side comment can only be created in side-by-side
layout** — except in a whole-intent preview, where the side comes from the row
itself: a `-` row addresses the old side even in the inline preview, because
that render carries the removed lines as real buffer lines.

Once created, it renders whenever the original pane is visible — but
deliberately not in an inline *file diff*. This is not a bug to route around:
inline shows only the modified file's buffer, and an old-side line number
addresses a row of the *original* file that simply has no corresponding row in
that buffer to hang a box off. Toggle back to side-by-side and the comment is
exactly where it was left; toggle to inline and it is invisible and
unreachable until you toggle back.

The inline *preview* is the exception, and for the same reason it can create
old-side comments there: its `-` rows are real buffer lines, so an old-side
comment does render on them. The rule is one rule — a box is drawn wherever a
row addresses its line — and only the inline file diff has no such row.

### The popup

`<Tab>` cycles the type (in both insert and normal mode); `<C-s>` submits.
Focus starts in the text area, in insert mode — so the first `<Esc>` only
leaves insert mode, same as it always does; a second `<Esc>`, or `q`,
cancels. Submitting empty text is treated exactly like cancelling: nothing is
saved. Editing an existing comment (`<localleader>ce`) opens the same popup,
pre-filled with its current type and text.

### Persistence

Comments are stored as JSON under `cache_dir .. "/comments/"`, one file per
review, keyed by git root plus **what is being reviewed** — deliberately
*not* the diff-text hash the classification cache uses, because that hash
changes the moment a file is edited, which would discard comments exactly
when they are still relevant.

- A **working-tree review** (plain `:IntentDiff`) keys by **branch**, so the
  review survives new commits made on that branch.
- An **explicit revision or revision range** (`:IntentDiff HEAD~1`,
  `:IntentDiff main...`) keys by the **revision pair** instead.

Files older than `comments.expire_days` (7 by default) are swept once per
Neovim session, deferred so it never blocks the first render; set
`expire_days = false` to disable the sweep.

### Exporting

| Key | Command | Does |
|---|---|---|
| `<localleader>cy` | `:IntentDiffCommentsYank` | Copy the Markdown to `+`/`*`, notify with the count |
| `<localleader>cw` | `:IntentDiffCommentsWrite [path]` | Write the Markdown to `path` (prompted when omitted, pre-filled with the last path used this session, default `.intentdiff-review.md` relative to the git root) |
| `<localleader>q` | — | Copy the Markdown, **then close the review tab** |

`<localleader>q` is the review.nvim end-of-review flow: finish, copy, paste
into the agent. Plain `q` still means exactly what it means everywhere else
in this plugin — close the tab, touch nothing else — so the clipboard is
only ever written by a key that says it writes the clipboard. With no
comments, `<localleader>q` notifies and still closes rather than refusing to.

This is the real output of `export.generate()` — generated headlessly against
a small model and five comments (an intent comment, a new-side issue, an
old-side suggestion, a range, and a file-level comment), not hand-typed — for
the same two groups shown in the sidebar at the top of this file:

```markdown
I reviewed your code and have the following comments. Please address them.

Comment types: ISSUE (problems to fix), SUGGESTION (improvements),
NOTE (observations), PRAISE (positive feedback)
Lines prefixed with ~ refer to the old (left) side of the diff.

## Rename UserService to AccountService

This rename missed the DI container entirely — see below.

1. **[ISSUE]** `src/api/routes.ts:5`
   This import still points at the old module.

2. **[SUGGESTION]** `src/services/account.ts:~41`
   The old implementation was cleaner.

## Add retry logic to HTTP client

3. **[PRAISE]** `src/http/client.ts`
   Good call keeping the timeout separate.

4. **[NOTE]** `src/http/client.ts:44-51`
   No jitter here — fine for now.
```

Numbering runs continuously across groups, not restarting per group. A
group's own comment (the whole-intent one) is emitted as a plain paragraph
before its numbered entries, not as a numbered entry itself. Within a group,
a file's file-level comment sorts before its line comments — that's why
`## Add retry logic to HTTP client`'s `[PRAISE]` (a file-level comment on
`client.ts`) is entry 3 and its `[NOTE]` range comment on the same file is
entry 4, even though the range comment was added first. The `~` legend line
is only emitted when the export actually contains an old-side comment — there
is never a legend for notation the document doesn't use. While classification
is still running (or failed), there is no grouping to hang headings off, and
the export degrades to one flat numbered list with no `##` headings; a
comment whose line lands in no hunk at all — typically one that outlived the
working-tree edit it pointed at — is emitted under a trailing
`## Unmatched comments` heading, flagged rather than dropped.

### Two review tabs on the same file

Two review tabs of the same repo, both showing the modified side of the same
working-tree file, share **one** underlying buffer: codediff resolves a real
working-tree file with `vim.fn.bufadd`, which always hands back the same
buffer number for the same path regardless of which tab asked. Comments
render into a single shared extmark namespace in that buffer, so each tab's
render clears the *other* tab's comment boxes there, and closing either tab
clears both. This self-heals the next time either tab is switched into —
`TabEnter` re-asserts that tab's state and re-renders its own comments — but
between those two events the other tab's boxes are genuinely gone from the
screen, not merely stale.

The same collision shows up in persistence: two tabs reviewing the same
working tree derive the **same branch key** (see "Persistence" above), so
they read and write the same JSON file. Whichever tab saves last wins — a
comment added in one tab can be silently dropped from disk by the other tab's
next save. This is arguably degenerate usage — why review the same working
tree in two tabs at once? — but it is real, and there is no cross-tab locking
to prevent it.

## Added and untracked files

Added (git status `A`) and untracked (`??`) files render their real file
contents in the diff panes — not a hunk-only fragment — since there is no
"before" to diff against. When such a file is at least
`added_file_split.min_lines` lines long, it's split into sub-hunks at
blank-line boundaries (each roughly `added_file_split.target_lines` lines),
so different parts of one new file can land in different intents; the pane
then folds down to just the lines belonging to the currently open intent,
the same as for an ordinary modified file. Set
`added_file_split.enabled = false` to go back to one whole-file hunk per
added/untracked file (no splitting, and therefore no folding within it).

Deleted files are deliberately never fold-filtered — a deleted file always
has exactly one hunk covering the entire file, so there is nothing to fold.

## Highlights

Every highlight group below is defined with `default = true`
(`nvim_set_hl(0, name, { link = target, default = true })`), which only sets
the link when the group has no definition yet — a definition you set
*before* the group is first defined (i.e. before the first `:IntentDiff` of
the session) is never overwritten by that first call, and one you set at any
later point also takes effect immediately, since a plain `nvim_set_hl` call
(no `default`) always overwrites unconditionally.

**That protection does not survive `:colorscheme`.** `:colorscheme` clears
every highlight definition and then reloads them; this plugin's own
`ColorScheme` autocmd re-establishes its `default = true` link at that point,
but a plain override you set earlier is gone by then — verified directly:
set `IntentDiffGroupTitle` with a bare `nvim_set_hl` call, run `:colorscheme
habamax`, and `nvim_get_hl(0, { name = "IntentDiffGroupTitle" })` reports
`{ default = true, link = "Title" }` again, not the override. So an override
wins from the moment you set it until the *next* `:colorscheme`, at which
point the plugin's default is reasserted and the override must be reapplied.

| Group | Default link | Used for |
|---|---|---|
| `IntentDiffGroupTitle` | `Title` | A group's (wrapped) title text |
| `IntentDiffGroupStats` | `Comment` | A group's `N hunks · M files` stats line |
| `IntentDiffAdd` | `Added` | `+N` addition counts, and `+`-prefixed preview lines |
| `IntentDiffDelete` | `Removed` | `-N` deletion counts, and `-`-prefixed preview lines |
| `IntentDiffDirectory` | `Directory` | A directory row's name in the file tree |
| `IntentDiffIndent` | `Comment` | The indentation before a nested tree row |
| `IntentDiffStatusA` | `Added` | Status-gutter letter for an added file |
| `IntentDiffStatusM` | `Changed` | Status-gutter letter for a modified file |
| `IntentDiffStatusD` | `Removed` | Status-gutter letter for a deleted file |
| `IntentDiffStatusUntracked` | `Added` | Status-gutter letter for an untracked file |
| `IntentDiffPreviewFile` | `Title` | A preview's per-file `── path   status   +A -B` separator |
| `IntentDiffPreviewHunk` | `Comment` | A preview's `@@ ... @@` hunk headers |
| `IntentDiffFiller` | `Comment` | Filler rows padding the shorter side of a side-by-side preview |
| `IntentDiffCommentNote` | `DiagnosticHint` | Note sign and comment-box border |
| `IntentDiffCommentSuggestion` | `DiagnosticInfo` | Suggestion sign and comment-box border |
| `IntentDiffCommentIssue` | `DiagnosticWarn` | Issue sign and comment-box border |
| `IntentDiffCommentPraise` | `DiagnosticOk` | Praise sign and comment-box border |
| `IntentDiffCommentNoteLine` | `CursorLine` | Commented-line background, note |
| `IntentDiffCommentSuggestionLine` | `CursorLine` | …suggestion |
| `IntentDiffCommentIssueLine` | `CursorLine` | …issue |
| `IntentDiffCommentPraiseLine` | `CursorLine` | …praise |

The eight comment groups are derived from each type's `key`, not hand-listed
per type: `IntentDiffComment` plus the key with its first letter capitalised,
and the same again with a `Line` suffix — `comments.types[].key = "note"`
therefore always produces `IntentDiffCommentNote` /
`IntentDiffCommentNoteLine`, whatever the type's configured `name` or `icon`
is. A type configured beyond the built-in four (say, `key = "question"`) gets
`IntentDiffCommentQuestion` / `IntentDiffCommentQuestionLine` — not listed
above, since it doesn't exist until configured — but the plugin defines both
anyway, linked to the note defaults (`DiagnosticHint` / `CursorLine`), so an
unstyled custom type still renders instead of erroring.

The reliable way to keep an override across colorscheme changes is to set it
from your own `ColorScheme` autocmd rather than a one-off call. It doesn't
matter whether you register it before or after intent-diff's own (which is
only registered lazily, on the first `:IntentDiff` of the session) — a plain
`nvim_set_hl` call always beats a `default = true` one, whichever order the
two end up running in on a given `:colorscheme`:

```lua
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    vim.api.nvim_set_hl(0, "IntentDiffGroupTitle", { fg = "#c4a7e7", bold = true })
  end,
})
```

A bare `vim.api.nvim_set_hl(0, "IntentDiffGroupTitle", { fg = "#c4a7e7", bold
= true })` with no autocmd works too, right up until the next
`:colorscheme` — which is exactly what makes it a trap: it looks like it
worked (and does, until the theme changes) rather than failing loudly.

## Keymaps

Press `g?` in a review tab for a floating cheatsheet built from your own
config — a rebound key shows up rebound, a disabled one not at all.

The whole set deliberately mirrors codediff's, so the two tools share muscle
memory: the fold verbs are its explorer's, `R`/`gf`/`<CR>` mean what they mean
there, and the sidebar toggle sits on its `toggle_explorer` default.

**Sidebar:**

| Key | Action |
|---|---|
| `<CR>` | On a file row, render its diff if needed (a pure focus change if the cursor already rendered it) and move focus into the diff pane. On a group or directory row, toggle it. |
| `za` / `zA` | Toggle the fold under the cursor / toggle it recursively |
| `zo` `l` / `zO` | Open the fold under the cursor / open it recursively |
| `zc` `h` / `zC` | Close the fold under the cursor / close it recursively |
| `zR` / `zM` | Expand / collapse every intent. Per-directory collapse state inside each intent is preserved. |
| `<leader>b` | Show or hide the sidebar — also works from the diff panes, see below. (`:IntentDiffSidebar`) |
| `R` | Re-classify (bypasses cache) |
| `gf` | Open the real file at the group's first hunk, closing the review tab |
| `<Tab>` / `<S-Tab>` | Jump to next / previous group header |
| `g?` | Toggle the keymap cheatsheet |
| `q` | Close the review tab |

A fold key acts on the directory under the cursor; anywhere else in an intent
(title, stats line, or a file row) it acts on the enclosing intent.
"Recursive" additionally reaches every directory beneath the row — that is the
only way to move directory state in bulk, since `zR`/`zM` are deliberately
intent-level. `:IntentDiffToggleAll` still collapses-if-any-expanded-else-
expands; it is unbound by default now that `zA` carries codediff's meaning.

Resting the cursor on a row (no key press) also drives the diff panes — see
"Previewing an intent" above.

**Diff panes:** `]c` / `[c` (and codediff's own hunk keys) are group-scoped —
they move only through the current group's hunks; at a file's last hunk in
the group they roll over to the group's next file. codediff's inline↔side-by-side
toggle keeps working; the fold filter re-applies after every toggle.
`<leader>b` (`keymaps.view.toggle_sidebar`) and `g?` are also installed here,
not just on the sidebar — since a sidebar-only key would be unreachable once
the sidebar is hidden, the toggle works even when codediff's own layout-toggle
key is disabled. Both work inside a whole-intent preview too — see "Previewing
an intent" above.

**Comments:** cross-surface by nature, installed on the diff panes, the
whole-intent preview buffers and the sidebar — an intent comment is added from
a sidebar group row, a line comment from a pane or a preview row, and every
surface needs the export keys (see "Review comments" above).

| Key | Action |
|---|---|
| `<localleader>cc` | Add a comment, picking the type in the popup (normal and visual) |
| `<localleader>cn` `cs` `ci` `cp` | Add a note / suggestion / issue / praise directly (normal and visual) |
| `<localleader>cf` | File-level comment on a diff pane or sidebar file row; a whole-intent comment on a sidebar group row |
| `<localleader>ce` | Edit the comment at the cursor |
| `<localleader>cd` | Delete the comment at the cursor |
| `<localleader>cl` | List every comment in the review and jump to one (`:IntentDiffCommentsList`) |
| `]n` / `[n` | Next / previous comment in this file |
| `<localleader>cy` | Copy the review as Markdown (`:IntentDiffCommentsYank`) |
| `<localleader>cw` | Write the review to a file (`:IntentDiffCommentsWrite`) |
| `<localleader>cx` | Delete every comment in this review, after confirmation (`:IntentDiffCommentsClear`) |
| `<localleader>q` | Copy the review as Markdown, then close the review tab |

## Diagnostics

`:IntentDiffLog` opens the diagnostics log (`config.log_file`, default
`vim.fn.stdpath("cache") .. "/intentdiff/intentdiff.log"`) in a scratch
buffer, cursor at the end so the newest entry is visible. If nothing has
been logged yet, it shows a one-line "no entries yet" buffer instead of
erroring.

Every classification appends timestamped entries covering:

- **Provider invocations** — the command+args spawned, prompt size in
  bytes, hunk count in the request, elapsed time, exit code, the first
  ~400 bytes of stdout and stderr each, and how the response parsed.
- **Classification outcomes** — cache hit, re-match against the previous
  classification (with the stale count), skipped for exceeding
  `max_hunks`, or provider success/error.
- **Reconciliation stats** — total inventory hunks, how many the provider
  assigned, how many ids were unrecognized (not in the inventory — i.e.
  dropped as hallucinated), how many were duplicates, how many landed in
  Ungrouped, and (for compact `ids` responses) `id_mapping_failures` — how
  many numbers in the response's `ids` string/array/number couldn't be
  mapped back to a hunk (out of range, non-numeric, or a nonsensical
  range) and were dropped before reconciliation even ran.

The log file is capped at roughly 200KB, truncating the oldest entries on
write, so it can't grow unbounded across a long Neovim session.

## Manual smoke test (real LLM)

1. In a repo with a multi-purpose dirty working tree, run `:IntentDiff`.
2. Sidebar shows flat "All changes" + `⟳ classifying…`, then regroups once the
   provider responds — seconds on a small diff, but expect well over a minute
   on a large one (see the measured latency table below; not ~5s).
3. Footer shows `N/N hunks` — total must equal the hunk count of `git diff HEAD` + untracked files.
4. The first file opens on its own (`auto_open`, default on) as soon as
   there's something to show — no need to select anything: unrelated hunks
   are folded; `zo` peeks at them.
5. `]c` at the last hunk of a file jumps to the group's next file.
6. Toggle inline view (codediff's key) — folds still filter to the group.
7. `r` re-classifies; a second `:IntentDiff` on the same diff is instant (cache).
8. In a pane, `<localleader>cn` on a changed line: the popup opens **already in
   insert mode** — type without pressing `i`. `<C-s>` submits, a box appears
   under the line, and you are back in normal mode in the pane you came from
   (`<Esc>` cancels and must leave you in normal mode too). The automated
   tests all drive the popup with `no_insert`, so this insert/stopinsert path
   is only ever exercised here.
9. Add a second comment further down the same file, then `]n` / `[n` from a
   pane: the cursor walks between the two boxes and reports "no more comments
   in this file" at the ends. Press `]n` with the cursor in the **sidebar**:
   it must refuse ("comment navigation only works in a diff pane") and the
   sidebar cursor must not move — a sidebar row is not a diff line, and with
   `preview.hover_opens_files` on a stray jump there re-renders the panes.
10. `<localleader>ce` on a commented line edits it, `<localleader>cd` deletes
    it. Then, in another Neovim (or `:!`), delete most of the file's lines so
    a comment's line number is past the end, and reopen the review: the box
    is clamped onto the last line, and `]n`, `<localleader>ce` and
    `<localleader>cd` must all still reach it there.
11. Open a **second** `:IntentDiff` tab on the same working tree and comment in
    it, then switch back to the first tab: the first tab's boxes reappear on
    `TabEnter` (the two tabs share one underlying buffer and one extmark
    namespace — see "Two review tabs on the same file"). They should be back
    the moment you land, not after another keypress.
12. `<localleader>cy` copies the Markdown; paste it somewhere and check the
    headings match the sidebar's intents. `<localleader>q` copies and closes
    the tab in one go.

Large diffs take longer than the ~5s above. Measured with `claude -p --model
haiku` on a 99-hunk / 28-file diff:

| Prompt                              | Output size | Wall time |
|--------------------------------------|-------------|-----------|
| Full diff + verbose (path:n) ids     | 4.0KB       | 1:46      |
| Manifest only + verbose ids          | 4.0KB       | 1:49      |
| Manifest + compact ids, range output | 641B        | 1:01      |

**Prompt size is not the bottleneck — output size is.** Sending the full diff
text instead of just the manifest (file + hunk header + a few summary lines
per hunk, `max_full_diff_bytes`) barely moved the needle: 95KB of prompt vs.
24KB cost about the same ~1:45-1:50. What actually dominates decode time is
how much the model has to *write back* — echoing a verbose `"src/a/b.lua:1"`
style id per hunk produces several KB of output; the compact integer `ids`
format with range compression (`"1-4,7,12-15"`) cut that to well under 1KB and
very roughly halved wall-clock time in this measurement. In other words: if
classification feels slow, lowering `max_full_diff_bytes` will barely help —
what you actually want is fewer, more compressible groups (which the
"prefer 3-8 groups" instruction in the prompt already pushes for) or a
smaller/faster model.

Expect classification to still take up to a minute or two on genuinely large
diffs (the sidebar's `⟳ classifying… Ns` counter shows how long it's been
running). If you hit "provider timed out", check `:IntentDiffLog` first —
look at `id_mapping_failures` and `parse_outcome` before assuming it's purely
a speed problem — then raise `provider_opts.timeout_ms` if it's genuine.
