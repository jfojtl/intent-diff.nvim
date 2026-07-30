# intent-diff.nvim

Review a git diff grouped by *reason of change* instead of by file. A sidebar
lists LLM-generated groups ("Rename UserService → AccountService", "Add retry
logic", "Drive-by lint fixes"); each group contains the files it touches, and
opening a file shows only that group's hunks — the rest of the file's diff is
folded away. Rendering is delegated to
[codediff.nvim](https://github.com/esmuellert/codediff.nvim); intent-diff only
adds grouping, a sidebar, and group-scoped navigation on top of it.

```
▾ Rename UserService → AccountService   (4)
  ├ account.ts  src/services/         M
  └ routes.ts   src/api/              M
▾ Add retry logic to HTTP client       (3)
  └ client.ts   src/http/             M
▸ Ungrouped                            (1)
──────────────────────────────────────
9/9 hunks · claude:haiku · 2.1s
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
  sidebar_width = 36,

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
  max_hunks = 400,

  -- Where classification results are cached, keyed by diff-text hash.
  cache_dir = vim.fn.stdpath("cache") .. "/intentdiff",

  -- Diagnostics log used by :IntentDiffLog (see "Diagnostics" below).
  log_file = vim.fn.stdpath("cache") .. "/intentdiff/intentdiff.log",
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

## Keymaps

**Sidebar:**

| Key | Action |
|---|---|
| `<CR>` | Open partial diff for a file, or toggle a group under cursor |
| `za` / `h` / `l` | Collapse/expand group under cursor |
| `r` | Re-classify (bypasses cache) |
| `gf` | Open the real file at the group's first hunk, closing the review tab |
| `<Tab>` / `<S-Tab>` | Jump to next / previous group header |
| `q` | Close the review tab |

**Diff panes:** `]c` / `[c` (and codediff's own hunk keys) are group-scoped —
they move only through the current group's hunks; at a file's last hunk in
the group they roll over to the group's next file. codediff's inline↔side-by-side
toggle keeps working; the fold filter re-applies after every toggle.

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
