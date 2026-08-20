# intent-diff.nvim

Review a git diff grouped by *reason of change* instead of by file. A sidebar
lists LLM-generated groups ("Rename UserService → AccountService", "Add retry
logic", "Drive-by lint fixes"); each group contains the files it touches, and
opening a file shows only that group's hunks — the rest of the file's diff is
folded away. Add review comments on any line or whole intent and export them
as Markdown for an agent to act on.

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
Ungrouped group, degrading toward a plain diff, never below it.

## Built on codediff.nvim

intent-diff owns its own renderer, but that renderer runs on top of
**[codediff.nvim](https://github.com/esmuellert/codediff.nvim)** by Yanuo Ma
(MIT). Specifically: codediff's `libvscode-diff` — a C port of VSCode's own
`defaultLinesDiffComputer` — is what gives intent-diff character-level
highlighting inside a changed line, and its treesitter helper is what lets
intent-diff syntax-highlight the synthetic multi-file buffers it builds.
codediff's git plumbing also resolves every revision intent-diff reviews. This
is a named runtime dependency, not vendored code, on purpose: install
codediff.nvim and you can see exactly what it's doing underneath.

**If you want a general-purpose diff, merge and git-history tool for Neovim,
install [codediff.nvim](https://github.com/esmuellert/codediff.nvim) directly.**
It is excellent, and intent-diff does not replace it — intent-diff does one
narrow thing: it groups a diff by *intent* and gives you a review surface over
those groups.

Full credits, including VSCode and utf8proc upstream of codediff.nvim itself,
in [ATTRIBUTION.md](ATTRIBUTION.md).

## Requirements

- Neovim ≥ 0.10
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- `claude` CLI on `$PATH` (only needed for the default provider; swap in your
  own provider to avoid the dependency — see "Custom providers")

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
    "jfojtl/intent-diff.nvim",
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

## Commands

| Command | Does |
|---|---|
| `:IntentDiff [revision-args]` | Open a review tab. Same argument forms as codediff's `:CodeDiff` — no args (working tree), a single revision, `revision...` for merge-base-relative, or `base target`. |
| `:IntentDiffSidebar` | Show/hide the sidebar (same as `<leader>b`) |
| `:IntentDiffToggleAll` | Collapse every intent if any is expanded, else expand every one |
| `:IntentDiffCommentsYank` / `…Write` / `…List` / `…Clear` | Review comment actions — see below |
| `:IntentDiffLog` | Open the diagnostics log |

## Usage

### The sidebar

Each group renders as a wrapped title line followed by a stats line —
`N hunks · M files`, then `+A`, `-B`, or both, whichever are nonzero. Below
that, when expanded, is a file tree: directories are their own rows, and a
chain of directories with only one child at each level is compressed onto a
single row (`src/services/api` instead of three nested rows). File rows show a
status gutter (`A`, `M`, `D`, or `?` for untracked) and, with
[nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons)
installed, a file-type icon.

`za`, `h`, and `l` are interchangeable collapse/expand keys: on a directory
row they toggle that directory; on any other row in the group — a title line,
the stats line, or a file row — they toggle the *enclosing group*. `<CR>`
behaves the same way on a group or directory row; on a file row it renders
that file's diff (if the cursor hasn't already) and moves focus into the diff
pane so you can scroll and search it.

### Previewing an intent

With `preview.enabled = true` (the default), the sidebar cursor drives the
diff panes on its own — no key press needed — after `preview.debounce_ms` of
the cursor sitting still:

- **A group row** (title or stats line) previews that group's whole diff:
  every file it touches, each preceded by a `── path   status   +A -B`
  separator, in file-tree order.
- **A directory row** previews just that subtree.
- **A file row** renders that file's own diff, folded to whichever group it
  belongs to, while leaving focus in the sidebar so you can keep browsing.

A file whose content runs past `line_budget` lines renders hunks-only instead
of its whole content, and its separator says why (`over line budget`).

Each changed line renders as *plain text*, not a unified-diff `+`/`-` line; a
removed line and its replacement are separate real buffer rows, told apart by
background color (`IntentDiffDelete` / `IntentDiffAdd`, annotated here since a
code fence can't show color):

```
── src/api/routes.ts   M   +1 -1
import { UserService } from './user-service'       (removed)
import { AccountService } from './account-service'  (added)
── src/services/account.ts   M   +1 -1
export class UserService {      (removed)
export class AccountService {   (added)
   constructor(private db: Db) {}
```

In an intent view, `]c`/`[c` jump to the next/previous hunk across every file
the intent touches (no wraparound), and the layout-toggle key (`t` by default)
flips between inline and side-by-side, keeping the same folds and cursor
position. That key is read from codediff's `keymaps.view.toggle_layout` so you
configure it once and both plugins agree.

In side-by-side layout the two panes are kept aligned **absolutely**: buffer
row N on the left is buffer row N on the right, so every scroll and cursor
move re-establishes the relationship rather than accumulating drift the way
`scrollbind` does. Only the row is copied, not the column. Long lines are not
wrapped by default (`pane_wrap`) for the same reason.

### Added and untracked files

Added (git status `A`) and untracked (`??`) files render their real file
contents in the diff panes — there is no "before" to diff against. When such a
file is at least `added_file_split.min_lines` long, it's split into sub-hunks
at blank-line boundaries, so different parts of one new file can land in
different intents and the pane can fold down to the open intent. Set
`added_file_split.enabled = false` for one whole-file hunk instead.

Deleted files are never fold-filtered — a deleted file has exactly one hunk
covering the whole file, so there is nothing to fold.

## Keymaps

Press `g?` in a review tab for a floating cheatsheet built from your own
config — a rebound key shows up rebound, a disabled one not at all.

The whole set deliberately mirrors codediff's, so the two tools share muscle
memory: the fold verbs are its explorer's, `R`/`gf`/`<CR>` mean what they mean
there, and the sidebar toggle sits on its `toggle_explorer` default.

**Sidebar:**

| Key | Action |
|---|---|
| `<CR>` | On a file row, render its diff and move focus into the diff pane. On a group or directory row, toggle it. |
| `za` / `zA` | Toggle the fold under the cursor / toggle it recursively |
| `zo` `l` / `zO` | Open the fold under the cursor / open it recursively |
| `zc` `h` / `zC` | Close the fold under the cursor / close it recursively |
| `zR` / `zM` | Expand / collapse every intent. Per-directory state inside each intent is preserved. |
| `<leader>b` | Show or hide the sidebar — also works from the diff panes |
| `R` | Re-classify (bypasses cache) |
| `gf` | Open the real file at the group's first hunk, closing the review tab |
| `<Tab>` / `<S-Tab>` | Jump to next / previous group header |
| `g?` | Toggle the keymap cheatsheet |
| `q` | Close the review tab |

A fold key acts on the directory under the cursor; anywhere else in an intent
it acts on the enclosing intent. "Recursive" additionally reaches every
directory beneath the row — the only way to move directory state in bulk,
since `zR`/`zM` are deliberately intent-level.

**Diff panes:**

| Key | Action |
|---|---|
| `]c` / `[c` | Next / previous hunk of whatever is currently painted — one file's hunks, or every hunk of a whole intent, in file order. No wraparound. |
| `gf` | Open the real file at the cursor's exact line, in a new tab. The only way from a pane's read-only scratch buffer into the editable file. |
| `<leader>b` | Show or hide the sidebar |
| `g?` | Toggle the keymap cheatsheet |
| `q` | Close the review tab |

**Comments:** installed on both the diff panes and the sidebar — an intent
comment is added from a sidebar group row, a line comment from a pane row, and
both surfaces need the export keys.

| Key | Action |
|---|---|
| `<localleader>cc` | Add a comment, picking the type in the popup (normal and visual) |
| `<localleader>cn` `cs` `ci` `cp` | Add a note / suggestion / issue / praise directly |
| `<localleader>cf` | File-level comment on a diff pane or sidebar file row; whole-intent comment on a sidebar group row |
| `<localleader>ce` / `cd` | Edit / delete the comment at the cursor |
| `<localleader>cl` | List every comment in the review and jump to one |
| `]n` / `[n` | Next / previous comment in the current render |
| `<localleader>cy` | Copy the review as Markdown |
| `<localleader>cw` | Write the review to a file |
| `<localleader>cx` | Delete every comment in this review, after confirmation |
| `<localleader>q` | Copy the review as Markdown, then close the review tab |
| `<localleader>cP` | Submit the review to the pull request |

## Review comments

Put comments directly on a diff, in the style of
[review.nvim](https://github.com/georgeguimaraes/review.nvim), then export them
as Markdown to hand to an agent. The difference from review.nvim: intent-diff
knows *why* each change was made, so the export files every comment under the
intent its line belongs to — an agent reads "here is the intent, and here is
what's wrong with it" instead of an undifferentiated list of file:line notes.

Four types — Note (`✍`), Suggestion (`💡`), Issue (`⚠`), Praise (`✨`) —
cycled with `<Tab>` in the popup, or reachable directly by key.

Which *shape* of comment you get depends on where the cursor is, not on which
key was pressed:

- **Line** — cursor on a body row of a diff pane, whether it's showing one
  file or a whole intent.
- **Range** — a visual selection within one file's rows.
- **File-level** — `<localleader>cf` in a diff pane, or on a sidebar **file**
  row.
- **Whole-intent** — any add key on a sidebar **group** row. Anchors to the
  group's *title*, so re-classifying under a differently-named group leaves
  the comment in the export's "Unmatched comments" section rather than
  silently landing on whatever group now occupies that slot.

A separator row or a side-by-side filler row refuses: it displays no line of
any file, so there is nothing to attach to. So does a visual range spanning
two files.

A comment's **side** comes from the row it is made on, never from which window
the cursor is in. In side-by-side, a row of the original pane is `"old"` and a
row of the modified pane is `"new"`; inline, a removed line is a real buffer
row carrying an `"old"` coordinate. So an old-side comment can be created,
read, edited and jumped to in either layout — toggle between them and every
box stays where you left it. The rule is one rule: **a box is drawn wherever a
row addresses its line.**

Comments made on an intent view are stored as ordinary `(file, line, side)`
records — comment on an intent, then open the file, and the box is already
there on the same line.

### The popup

`<Tab>` cycles the type (in both insert and normal mode); `<C-s>` submits.
Focus starts in the text area in insert mode, so the first `<Esc>` only leaves
insert mode; a second `<Esc>`, or `q`, cancels. Submitting empty text is
treated as cancelling. `<localleader>ce` reopens the same popup, pre-filled.

### Persistence

Comments are stored as JSON under `cache_dir .. "/comments/"`, one file per
review, keyed by git root plus what is being reviewed — deliberately *not* the
diff-text hash the classification cache uses, since that hash changes the
moment a file is edited.

- A **working-tree review** (plain `:IntentDiff`) keys by **branch**, so the
  review survives new commits on that branch.
- An **explicit revision or range** (`:IntentDiff HEAD~1`, `:IntentDiff
  main...`) keys by the **revision pair**.

Files older than `comments.expire_days` (7 by default) are swept once per
Neovim session; set `expire_days = false` to disable the sweep.

Reviewing the same working tree in **two review tabs at once** is not
supported: both tabs derive the same branch key and share one underlying
buffer, so their comment boxes clear each other on render and whichever tab
saves last wins on disk.

### Exporting

| Key | Command | Does |
|---|---|---|
| `<localleader>cy` | `:IntentDiffCommentsYank` | Copy the Markdown to `+`/`*`, notify with the count |
| `<localleader>cw` | `:IntentDiffCommentsWrite [path]` | Write the Markdown to `path` (prompted when omitted, default `.intentdiff-review.md` relative to the git root) |
| `<localleader>q` | — | Copy the Markdown, **then close the review tab** |
| `<localleader>cP` | `:IntentDiffCommentsSubmit` | Submit the review to the pull request this branch is linked to |

Plain `q` still means what it means everywhere else — close the tab, touch
nothing else — so the clipboard is only ever written by a key that says it
writes the clipboard.

A sample export, for the two groups shown in the sidebar at the top of this
file:

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

Numbering runs continuously across groups. A group's whole-intent comment is
emitted as a plain paragraph before its numbered entries; within a group, a
file's file-level comment sorts before its line comments. The `~` legend line
appears only when the export actually contains an old-side comment. While
classification is still running (or if it failed) the export degrades to one
flat numbered list with no headings, and a comment whose line lands in no hunk
at all is emitted under a trailing `## Unmatched comments` heading rather than
dropped.

### Submitting to a pull request

When the branch is linked to a GitHub pull request, `<localleader>cP`
(`:IntentDiffCommentsSubmit`) posts the review to it as **one atomic review** —
inline comments, a body, and a verdict together. Requires the
[`gh` CLI](https://cli.github.com), authenticated.

Nothing leaves your machine until you pick a verdict:

```
Approve  ·  Request changes  ·  Comment (no verdict)  ·  Cancel
```

**Two modes.** Which one you get is decided before anything is sent:

- **Inline** — when local `HEAD` *is* the PR head, no commented file has
  uncommitted changes, and the review is based exactly where the PR diverged.
  Each comment posts on its line: ranges as multi-line comments, old-side
  comments on the left, file-level comments on the file itself. The body
  carries the intent structure and an index of what went where.

  In practice that means reviewing against the base branch **as the remote has
  it** — `:IntentDiff origin/main...`, not `:IntentDiff main...`. GitHub diffs
  a PR against `origin/main`, so if your local `main` has drifted even one
  commit, the two diffs are not the same one and the old side is off by
  whatever `main` gained. The submit says so, names the drift, and degrades
  rather than guessing.
- **General** — anything else. Line numbers in a dirty tree, or at a commit the
  PR has not seen, do not mean what they mean on GitHub, so the whole review
  posts as one general comment carrying the Markdown export. You are told which
  it will be, and why, before you confirm.

Other states refuse, each with its own reason: on the default branch there is
no PR to comment on; on a branch with no PR yet you are asked to create one
first; a remote that is not GitHub reports that no forge serves it — if it *is*
GitHub, on an Enterprise host `auto` cannot recognise, set `forge = "github"`
to use it anyway.

Comments GitHub cannot anchor — a line outside the PR diff — are moved into the
review body under `## Not attached to a line` rather than dropped, and you are
told how many. This is worked out locally against the PR's own diff, because
the reviews API is atomic: one bad line would reject the entire review. A
comment that anchors fine but belongs to no intent is listed under
`## Not attached to an intent` — as a pointer, since its text is already on its
line. A whole-intent comment whose group was renamed away lands under the same
heading, but in full: it addresses no line, so there is no inline copy of it to
point at.

**Posted comments are remembered.** Each one that lands is stamped, its box
header reads `[ISSUE · POSTED]`, and a later submit offers only the comments
you have added since — so a second pass cannot duplicate the first. When every
comment is already posted, you are offered a verdict on its own. Editing a
posted comment does not clear the stamp: the edit is local, and the PR still
holds what was sent.

The abstraction behind this is service-neutral (`lua/intentdiff/forges/`), with
GitHub as the first implementation; the payload is expressed in the plugin's own
vocabulary so another git-based service can be added as one module.

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
    -- self-contained.
    agentic = true,
  },

  -- Lines of context kept around each visible hunk when computing folds.
  context_lines = 3,

  -- Above this many lines on either side, a file renders hunks-only instead
  -- of its whole content, and says so on its separator. Guards against a huge
  -- generated/vendored file blowing up a diff pane.
  line_budget = 20000,

  -- Width (columns) of the sidebar split.
  sidebar_width = 40,

  -- Wrap long lines in the diff panes. Off, and deliberately so: the two panes
  -- are kept aligned row for row, and a changed line that is 40 characters on
  -- one side and 200 on the other takes one screen row against three — so with
  -- wrapping on, everything below such a line sits at a different height in
  -- each pane. Set to true if you would rather read long lines whole.
  pane_wrap = false,

  -- File icons from nvim-web-devicons (if installed) in the sidebar's file
  -- tree. Silently omitted if the plugin isn't present, or set to false here.
  icons = true,

  -- Auto-open the first file worth looking at instead of leaving the diff
  -- panes empty until you press <CR>: the first file of the flat "All
  -- changes" list while classification is still running, then the first file
  -- of the first real group once it completes. A manual selection (or ]c/[c
  -- navigation) always wins. Focus stays in (or returns to) the sidebar.
  auto_open = true,

  -- Above this diff size (bytes), the prompt sends per-hunk summaries only
  -- (file + the hunk's first 4 lines, then "… (N more lines)") instead of the
  -- full diff text.
  max_full_diff_bytes = 100 * 1024,

  -- Above this many hunks, classification is skipped entirely with a
  -- notice — the sidebar stays in flat file-list mode.
  max_hunks = 600,

  -- Where a finished review can be sent, besides the clipboard and a file.
  -- "auto" picks by the origin remote's host; "github" forces it; a table
  -- implementing the forge interface is used directly; false disables it.
  forge = "auto",
  forge_opts = {
    github = { cmd = "gh", timeout_ms = 30000 },
  },

  -- Added and untracked files arrive from git as a single whole-file hunk, so
  -- they could only ever belong to one intent. Splitting them at blank-line
  -- boundaries lets different parts of one new file land in different
  -- intents, and makes the group fold filter meaningful for them. Set
  -- enabled = false to restore one hunk per added/untracked file.
  added_file_split = {
    enabled = true,
    min_lines = 60,    -- files shorter than this stay a single hunk
    target_lines = 40, -- approximate lines per sub-hunk once split
  },

  -- Where classification results are cached, keyed by diff-text hash.
  cache_dir = vim.fn.stdpath("cache") .. "/intentdiff",

  -- Diagnostics log used by :IntentDiffLog.
  log_file = vim.fn.stdpath("cache") .. "/intentdiff/intentdiff.log",

  -- Cursor-driven navigation: moving the sidebar cursor onto a group or
  -- directory row shows that intent's complete diff in the diff panes, with
  -- a separator per file; moving it onto a file row renders that file's own
  -- diff too.
  preview = {
    enabled = true,
    debounce_ms = 120,  -- cursor settle time before rendering, so scrolling
                        -- past rows doesn't thrash the panes
  },

  -- Review comments attached to diff lines and to whole intents, exported as
  -- Markdown for an agent to act on.
  comments = {
    enabled = true,

    -- Comment types, in the order the popup cycles them. Each needs a name
    -- and an icon; its highlight groups are derived from `key` — see
    -- "Highlights" below. A type added beyond the built-in four gets working
    -- (if unstyled) highlight defaults for free.
    types = {
      { key = "note",       name = "Note",       icon = "✍" },
      { key = "suggestion", name = "Suggestion", icon = "💡" },
      { key = "issue",      name = "Issue",      icon = "⚠" },
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
  -- .history / .conflict). Set any action to `false` to install nothing. An
  -- action may also be a LIST of keys, all bound to it.
  keymaps = {
    -- The diff panes — one file or a whole intent, same buffers.
    view = {
      quit = "q",
      -- Show/hide the sidebar. Named after (and sharing a default with)
      -- codediff's keymaps.view.toggle_explorer, because our sidebar is that
      -- explorer's counterpart. Installed on the sidebar AND on the diff
      -- panes, since a sidebar-only key is unreachable once the sidebar is
      -- hidden.
      toggle_sidebar = "<leader>b",
      next_hunk = "]c",       -- group-scoped: only this intent's hunks
      prev_hunk = "[c",
      show_help = "g?",
      -- The panes are read-only scratch buffers; this is the only way from
      -- one into the real, editable file, at the cursor's exact line. Opens
      -- in a new tab. No collision with the sidebar's own `gf` (goto_file) —
      -- a different surface, a different buffer.
      open_file = "gf",
    },
    -- The intent sidebar.
    sidebar = {
      select = "<CR>",
      quit = "q",
      reclassify = "R",       -- what codediff's explorer uses
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
      -- Collapse every intent if any is expanded, else expand every one.
      -- Unbound by default (`zR`/`zM` do the two halves explicitly) and
      -- reachable as :IntentDiffToggleAll.
      fold_toggle_all = false,
    },
    -- Review comments. Cross-surface by nature: an intent comment is added
    -- from a sidebar group row, a line comment from a diff pane row, and both
    -- surfaces need the export keys — so this is installed on both.
    comments = {
      add_comment = "<localleader>cc", -- pick the type in the popup
      add_note = "<localleader>cn",
      add_suggestion = "<localleader>cs",
      add_issue = "<localleader>ci",
      add_praise = "<localleader>cp",
      add_file_comment = "<localleader>cf", -- an intent comment on a group row
      edit_comment = "<localleader>ce",
      delete_comment = "<localleader>cd",
      list_comments = "<localleader>cl",
      next_comment = "]n",
      prev_comment = "[n",
      export_clipboard = "<localleader>cy",
      export_file = "<localleader>cw",
      clear_comments = "<localleader>cx",
      -- The review.nvim end-of-review flow: copy, then close. Plain `q`
      -- still closes without touching the clipboard.
      export_and_close = "<localleader>q",
      submit_review = "<localleader>cP",
      -- Popup-local keys for the comment entry float, buffer-local to its
      -- text area rather than tab-wide.
      popup_cycle_type = "<Tab>",
      popup_submit = "<C-s>",
      popup_cancel = "q",
    },
  },
}
```

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
longer, and is always present regardless of diff size. Each hunk also carries
a compact integer `n` (1..N, inventory order), and `request.numbering` is the
`n -> id` map. `request.repo`, when present, names the repo root and revision
range being reviewed, so a provider can run its own read-only lookups.

### Group response shape

Each returned group may identify its hunks either way — **both are accepted,
and may even appear in the same response**:

- **Compact (preferred; what claude_cli asks the model for):**
  `{ title = "...", ids = "1-4,7,12-15" }` — `ids` is a string of integers
  with ranges, referring to `hunks[i].n` / `request.numbering`, not the hunks'
  `id` strings. It's also tolerant of a JSON array of numbers (`{1,2,3}`) or a
  bare number.
- **Legacy:** `{ title = "...", hunk_ids = { "src/a.lua:1", ... } }` — the
  array-of-inventory-id-strings shape.

Providers never need to worry about completeness: ids you omit, mistype, or
that fail to map back to a real hunk are reconciled by the plugin itself —
missing hunks land in Ungrouped, hallucinated ids are discarded, duplicates
keep only the first group. Run async and never block the UI.

Return a cancel handle — `{ cancel = function() … end }` — if your provider
can be aborted: intent-diff calls it when a newer classification supersedes
yours (`R`) or when the review tab is closed.

## Safety: the read-only tool allowlist

`claude_cli` runs pointed at the repo being reviewed — including any
uncommitted changes in the working tree — so by default it's restricted to
read-only tools: `provider_opts.disallowed_tools` (`--disallowedTools`) blocks
`Edit`/`Write`/`NotebookEdit`, and `provider_opts.allowed_tools`
(`--allowedTools`) scopes it to read-only git subcommands plus
`Read`/`Grep`/`Glob`. Set either to `{}` (or `nil`) to omit that flag and fall
back to `claude`'s own defaults.

This is a safety measure, not a correctness one — the grouping itself is
validated independently — so a misbehaving or adversarially-prompted model
can't edit the diff it's supposed to be describing.

By default (`provider_opts.agentic = true`) the model is also told it *may*
run those read-only commands, comparing the exact base/target revisions being
reviewed, to work out *why* a change was made, rather than intent-diff
guessing at that by stuffing commit messages into the prompt itself. Set
`agentic = false` for a fully self-contained prompt, if you'd rather not have
the model spend time/tokens shelling out.

## Highlights

| Group | Default link | Used for |
|---|---|---|
| `IntentDiffGroupTitle` | `Title` | A group's (wrapped) title text |
| `IntentDiffGroupStats` | `Comment` | A group's `N hunks · M files` stats line |
| `IntentDiffAdd` | *derived, see below* | Whole-row background tint for an added line in a diff pane |
| `IntentDiffDelete` | *derived, see below* | Whole-row background tint for a deleted line in a diff pane |
| `IntentDiffDirectory` | `Directory` | A directory row's name in the file tree |
| `IntentDiffIndent` | `Comment` | The indentation before a nested tree row |
| `IntentDiffStatusA` | `Added` | Status-gutter letter for an added file |
| `IntentDiffStatusM` | `Changed` | Status-gutter letter for a modified file |
| `IntentDiffStatusD` | `Removed` | Status-gutter letter for a deleted file |
| `IntentDiffStatusUntracked` | `Added` | Status-gutter letter for an untracked file |
| `IntentDiffFileSeparator` | `Title` | A per-file `── path   status   +A -B` separator |
| `IntentDiffFiller` | `Comment` | Filler rows padding the shorter side of a side-by-side pane |
| `IntentDiffAddChar` | *derived, see below* | Stronger background for the actually-changed words inside an added line |
| `IntentDiffDeleteChar` | *derived, see below* | Stronger background for the actually-changed words inside a deleted line |
| `IntentDiffCommentNote` | `DiagnosticHint` | Note sign and comment-box border |
| `IntentDiffCommentSuggestion` | `DiagnosticInfo` | Suggestion sign and comment-box border |
| `IntentDiffCommentIssue` | `DiagnosticWarn` | Issue sign and comment-box border |
| `IntentDiffCommentPraise` | `DiagnosticOk` | Praise sign and comment-box border |
| `IntentDiffCommentNoteLine` | `CursorLine` | Commented-line background, note |
| `IntentDiffCommentSuggestionLine` | `CursorLine` | …suggestion |
| `IntentDiffCommentIssueLine` | `CursorLine` | …issue |
| `IntentDiffCommentPraiseLine` | `CursorLine` | …praise |

The four *derived* groups are not links. `IntentDiffAdd`/`IntentDiffDelete`
set only a `bg` (no `fg`, so treesitter's syntax colours keep showing
through), taken from the colourscheme's own `DiffAdd`/`DiffDelete` background
when that background actually reads as green/red — several built-in schemes
define `DiffDelete` as a magenta. Whichever side fails that check falls back
to a GitHub-ish red/green blended into the editor's `Normal` background, so it
still adapts to light vs. dark. `IntentDiffAddChar`/`IntentDiffDeleteChar` are
that resolved colour pushed further from the editor background, so the words
that actually changed stand out inside the tinted row.

The eight comment groups are derived from each type's `key`, so
`comments.types[].key = "question"` gets `IntentDiffCommentQuestion` /
`IntentDiffCommentQuestionLine` defined for free, linked to the note defaults.

Every group is set with `default = true`, so your own definition always wins —
but `:colorscheme` clears all definitions and this plugin re-establishes its
defaults, so set overrides from your own `ColorScheme` autocmd rather than a
one-off call:

```lua
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    vim.api.nvim_set_hl(0, "IntentDiffGroupTitle", { fg = "#c4a7e7", bold = true })
  end,
})
```

## Performance

Classification takes seconds on a small diff and up to a minute or two on a
genuinely large one — the sidebar's `⟳ classifying… Ns` counter shows how long
it's been running, and a second `:IntentDiff` on the same diff is instant
(cached by diff-text hash).

**Prompt size is not the bottleneck — output size is.** Measured with `claude
-p --model haiku` on a 99-hunk / 28-file diff, sending the full diff text
(95KB of prompt) versus just the hunk manifest (24KB) both cost ~1:45–1:50;
switching the model's *response* from verbose `"src/a/b.lua:1"` ids (4.0KB) to
the compact range format `"1-4,7,12-15"` (641B) roughly halved it to ~1:00. So
if classification feels slow, lowering `max_full_diff_bytes` will barely
help — what you want is fewer, more compressible groups or a smaller/faster
model.

If you hit "provider timed out", check `:IntentDiffLog` first — look at
`id_mapping_failures` and `parse_outcome` before assuming it's purely a speed
problem — then raise `provider_opts.timeout_ms` if it's genuine.

## Diagnostics

`:IntentDiffLog` opens the diagnostics log (`config.log_file`) in a scratch
buffer, cursor at the end so the newest entry is visible. Every classification
appends timestamped entries covering:

- **Provider invocations** — the command+args spawned, prompt size, hunk
  count, elapsed time, exit code, the first ~400 bytes of stdout and stderr,
  and how the response parsed.
- **Classification outcomes** — cache hit, re-match against the previous
  classification, skipped for exceeding `max_hunks`, or provider
  success/error.
- **Reconciliation stats** — total inventory hunks, how many the provider
  assigned, how many ids were unrecognized or duplicated, how many landed in
  Ungrouped, and `id_mapping_failures` for compact responses.

The log file is capped at roughly 200KB, truncating the oldest entries on
write.

## License

MIT — see [LICENSE](LICENSE). Every dependency it builds on is MIT too; the
per-component copyright notices are in [ATTRIBUTION.md](ATTRIBUTION.md).
