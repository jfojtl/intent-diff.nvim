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
    timeout_ms = 60000,    -- kill the job and report failure after this long
  },

  -- Lines of context around each hunk when computing folds. nil = follow
  -- codediff's own diff.compact_context_lines setting.
  context_lines = nil,

  -- Width (columns) of the sidebar split.
  sidebar_width = 36,

  -- Above this diff size (bytes), the prompt sends per-hunk summaries only
  -- (file + the hunk's first 4 lines, then "… (N more lines)") instead of the
  -- full diff text.
  max_full_diff_bytes = 100 * 1024,

  -- Above this many hunks, classification is skipped entirely with a
  -- notice — the sidebar stays in flat file-list mode.
  max_hunks = 400,

  -- Where classification results are cached, keyed by diff-text hash.
  cache_dir = vim.fn.stdpath("cache") .. "/intentdiff",
}
```

## Custom providers

A provider is a function that receives the hunk inventory and returns groups
asynchronously:

```lua
--- @param request { diff_text: string|nil, hunks: { id: string, file: string, summary_lines: string[] }[] }
--- @param callback fun(result: { groups: { title: string, hunk_ids: string[] }[] }|nil, err: string|nil)
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

Providers never need to worry about completeness: `hunk_ids` you omit or
mistype are reconciled by the plugin itself — missing hunks land in
Ungrouped, hallucinated IDs are discarded, and duplicates keep only the first
group. Run async and never block the UI.

Return a cancel handle — `{ cancel = function() … end }` — if your provider can
be aborted: intent-diff calls it when a newer classification supersedes yours
(e.g. the user pressed `r`) or when the review tab is closed, so the abandoned
request does not keep running.

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

## Manual smoke test (real LLM)

1. In a repo with a multi-purpose dirty working tree, run `:IntentDiff`.
2. Sidebar shows flat "All changes" + `⟳ classifying…`, then regroups within ~5s.
3. Footer shows `N/N hunks` — total must equal the hunk count of `git diff HEAD` + untracked files.
4. Open a file in a group: unrelated hunks are folded; `zo` peeks at them.
5. `]c` at the last hunk of a file jumps to the group's next file.
6. Toggle inline view (codediff's key) — folds still filter to the group.
7. `r` re-classifies; a second `:IntentDiff` on the same diff is instant (cache).
