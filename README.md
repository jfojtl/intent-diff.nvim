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
