# intent-diff.nvim — Design

**Date:** 2026-07-29
**Status:** Approved

## Purpose

Review a git diff grouped by *reason of change* instead of by file. A sidebar
lists LLM-generated groups ("Rename UserService → AccountService", "Add retry
logic", "Drive-by lint fixes"); each group contains the files it touches, and
opening a file shows only that group's hunks — the rest of the file's diff is
folded away. Rendering is delegated to codediff.nvim.

Replaces the user's three codediff diff keymaps (`<leader>gVv` working tree,
`<leader>gVH` vs previous commit, `<leader>gVb` branch vs default). History
keymaps (`<leader>gVh`, `<leader>gVl`) stay on plain codediff.

## Decisions made during brainstorming

| Question | Decision |
|---|---|
| What groups hunks | LLM, pluggable provider; default `claude -p --model haiku` |
| Where it lives | Companion plugin depending on codediff.nvim internals (not a fork) |
| Diff scopes | Same as the user's codediff keymaps: working tree, `HEAD~1`, branch vs default; arbitrary `:CodeDiff`-style args accepted |
| History views | Unchanged plain codediff |
| Sidebar UX | Group headers → file children → partial per-file diff (folds); inline↔side-by-side toggle preserved |
| Classification lifecycle | Async on open + manual refresh; cache keyed by diff hash; stale hunks → Ungrouped |
| Architecture | Own sidebar + codediff's view + filtered compact folds (Approach A) |

## Architecture

Standalone plugin repo at `~/dev/github.com/jfojtl/intent-diff.nvim`, loaded in
the user's LazyVim config via `dir = ...` during development.

```
lua/intentdiff/
  init.lua          -- setup(opts), public API, :IntentDiff command
  config.lua        -- defaults: provider, context_lines, cache dir, thresholds, icons
  hunks.lua         -- run git diff, parse into hunk inventory
  classify.lua      -- orchestrates: cache check → provider call → reconcile result
  providers/
    claude_cli.lua  -- default provider: async `claude -p --model haiku`, JSON out
  cache.lua         -- diff-hash keyed persistence under stdpath('cache')
  sidebar.lua       -- group→file tree buffer: rendering, keymaps, loading states
  view.lua          -- adapter: the ONLY module that requires codediff internals
  navigation.lua    -- group-scoped next/prev hunk with cross-file rollover
```

### Coupling boundary

`view.lua` is the single module allowed to `require` codediff internals:

- `codediff.ui.view` — `create(session_config, filetype, on_ready)`,
  `update(tabpage, session_config, ...)`, `toggle_layout(tabpage)`
- `codediff.ui.view.compact` — `compute_visible_lines(changes, side,
  line_count, context_lines)`, `enable(tabpage)` (fold machinery)
- `codediff.core.git` / `codediff.core.diff` — revision resolution and diff
  computation helpers

Every internal access is `pcall`-guarded at setup; on mismatch (codediff
update changed internals) the plugin disables itself with an explicit
"codediff API mismatch (vX.Y): grouped view disabled" message. codediff stays
pinned via lazy-lock.

### Provider contract

```lua
--- @param request { diff_text: string, hunks: { id: string, file: string, summary_lines: string[] }[] }
--- @param callback fun(result: { groups: { title: string, hunk_ids: string[] }[] }|nil, err: string|nil)
provider(request, callback)
```

Adding a provider (codex CLI, HTTP API, …) = one new file in `providers/`
returning that function. Providers run async (jobstart); never block the UI.

## Data flow & completeness guarantee

The LLM never decides *what* the changes are, only how to *label* them.

1. **Inventory is ground truth.** `hunks.lua` parses `git diff` output into an
   inventory with stable IDs (`path/to/file.ts:1`, `:2`, …), including
   untracked files (intent-to-add semantics, matching codediff's view).
   Deterministic, LLM-free.
2. **LLM assigns, code reconciles.** `classify.lua` reconciles the provider's
   groups against the inventory:
   - inventory hunk in no group → forced into a visible **Ungrouped** bucket
     (never silently dropped)
   - group hunk not in inventory (hallucinated ID) → discarded
   - hunk in multiple groups → kept in the first, removed from the rest

   Invariant, by construction: **union of groups + Ungrouped = the exact
   diff.** Reviewing every group means seeing every hunk.
3. **Staleness is detected, not guessed.** Cache key = hash of full diff text.
   If the current diff hash differs from the classified one, hunks whose
   content still matches keep their group; new/changed hunks land in Ungrouped
   with a `[stale — n unclassified]` sidebar indicator until manual
   re-classification (`r`).
4. **Visible cross-check.** Group headers show hunk counts; the sidebar footer
   shows `Σ = N/N hunks`. Any mismatch is treated as a plugin bug and warned
   loudly instead of rendered.

Worst case with a bad LLM response: one boring group named Ungrouped —
degrades toward plain codediff, never below it.

## UI & interaction

**Command:** `:IntentDiff [revision-args]`, accepting the same argument forms
as `:CodeDiff`. Keymaps `<leader>gVv` / `<leader>gVH` / `<leader>gVb` are
repointed at it in the user's config.

**Opening:** new tab, sidebar left, codediff view right. While classification
runs, the sidebar shows the plain file list under a `⟳ classifying…` header —
flat review is possible immediately. On completion it re-renders into groups.
Cached diffs render grouped instantly.

**Sidebar** (reuses codediff's explorer styling: highlight groups, devicons,
`M/A/D/??` status symbols):

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

A file touched by two groups appears under both, each entry showing only its
group's hunks.

**Sidebar keymaps:** `<CR>` open partial diff · `za`/`h`/`l` collapse/expand
group · `r` re-classify · `gf` open real file at group's first hunk ·
`<Tab>`/`<S-Tab>` next/prev group · `q` close tab.

**Diff panes:** selection calls codediff `view.update()`, then enables compact
folding computed from only the group's hunks (context lines configurable,
default = codediff's compact default). Other groups' changes sit in closed
folds — `zo` peeks, `zM` re-hides. codediff's inline↔side-by-side toggle keeps
working; the fold filter is re-applied after every toggle/update via the
view's ready/refresh path. Panes show real file states with true line numbers.

**Navigation:** `]c`/`[c` (and codediff's hunk keys) in grouped panes are
group-scoped; at a file's last group hunk they roll over to the group's next
file.

## Error handling

- **Provider failure** (CLI missing, non-zero exit, 60s timeout, malformed
  JSON): sidebar stays in flat file-list mode with a one-line warning and `r`
  to retry. One automatic JSON-repair attempt (strip markdown fences) before
  declaring failure. Review is never blocked on the LLM.
- **Huge diffs:** above a configurable hunk/byte threshold the prompt sends
  per-hunk summaries (file + hunk header + first/last lines) instead of full
  diff text; above a hard cap, classification is skipped with a notice.
- **Not a repo / empty diff:** same behavior as codediff.
- **codediff API mismatch:** see coupling boundary — explicit disable, no
  mid-review errors.
- **Concurrent classifications:** a new request cancels the in-flight job
  (job-token check in the callback); stale results never overwrite newer ones.

## Testing

Follow codediff's own test idioms (busted-style specs, headless nvim).

- **Unit (no UI):** hunk parsing from fixture diffs; reconciliation invariants
  (union = inventory; missed → Ungrouped; hallucinated dropped; duplicates
  deduped) property-style over generated assignments; cache round-trip and
  stale re-matching; prompt building across size thresholds.
- **Provider pipeline:** fake `claude` executable on `$PATH` (shell script
  emitting canned JSON) exercising async flow, timeout, and malformed-output
  repair — no real LLM calls in tests.
- **Integration (headless nvim + fixture repo):** `:IntentDiff` with fake
  provider → assert sidebar tree contents, fold ranges for a selected group,
  group-scoped navigation rollover, inline/side-by-side toggle preserving the
  filter.
- **Manual smoke:** one documented real `claude -p` run in the README
  checklist (prompt quality is not unit-testable).

## Out of scope (v1)

- Grouping inside history views (may hook codediff history later)
- Staging/unstaging by group
- Manual re-assignment of hunks between groups
- Persisting group titles across diff changes beyond content-hash re-matching
