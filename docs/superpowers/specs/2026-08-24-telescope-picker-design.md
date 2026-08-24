# Telescope picker for intent navigation

Status: approved design, not yet implemented
Branch: `feat/telescope-plugin`

## Problem

The sidebar is a 40-column vertical split (`sidebar.lua:233`). On a small
laptop screen that is a large fraction of the width, and the two diff panes
depend on width more than most buffers do: the side-by-side view rests on row
N left being row N right, which is why `pane_wrap` defaults to false
(`config.lua:41-45`). Narrow panes make a review harder to read.

`<leader>b` already hides the sidebar (`init.lua:927`, `sidebar.lua:304-336`).
The reason that is not a usable workflow is that hiding the sidebar removes
the only way to reach another intent. The space fix exists; what is missing is
navigation that does not require the sidebar to be on screen.

A second gap is independent of screen size. Intent titles are LLM-generated
prose — "Rename UserService → AccountService", "Add retry logic". A fold tree
cannot match on them. Typing `retry` and landing on the right intent is
something the current UI structurally cannot offer.

## Goals

- Reach any intent, directory or file without the sidebar being visible.
- Fuzzy-match intent titles and file paths in one prompt.
- Reuse Telescope's own conventions: prompt history, `:Telescope resume`.

## Non-goals

- Replacing or changing the sidebar. It keeps the tree, folds, comment signs,
  the stats footer, the classification spinner, cursor-driven preview, and
  `toggle_sidebar`. All persistent review state continues to live there.
- Reproducing the side-by-side diff anywhere but the real panes.
- Making Telescope a required dependency.

## Design

### 1. A registered Telescope extension

The picker ships as `lua/telescope/_extensions/intentdiff.lua`, registering one
picker named `intents`.

Registering as a named extension rather than calling `telescope.pickers`
directly from our own module is what buys the conventions:

- `:Telescope intentdiff intents` and `:Telescope resume` work with no extra
  code.
- Telescope's built-in prompt history is a single shared list, but
  `telescope-smart-history` keys history by picker name and cwd. Only a named,
  registered picker can be scoped that way.

Telescope stays optional. `plugin/intentdiff.lua` gains:

```lua
vim.api.nvim_create_user_command("IntentDiffFind", function()
  require("intentdiff").find()
end, { desc = "intent-diff: fuzzy-find an intent, directory or file" })
```

`M.find()` resolves the current tab's session, then `pcall`s
`require("telescope")` and `load_extension("intentdiff")`. When Telescope is
absent it notifies once at WARN level and returns. Nothing else in the plugin
changes behaviour based on whether Telescope is installed.

### 2. `lua/intentdiff/targets.lua` — the data layer

One pure function:

```lua
--- @return Target[]
function M.list(model, opts)
```

`opts.include_dirs` (default true) controls directory rows. Each target:

```lua
{
  kind = "group" | "dir" | "file",
  group_title = string,   -- stable identity, not an index
  path = string | nil,    -- file path, or directory path for kind == "dir"
  additions = integer,
  deletions = integer,
  hunk_count = integer,
}
```

Ordering is sidebar order: each intent's own row, then its directory rows and
file rows in `tree.flatten` order, ignoring collapse state — a fuzzy list has
no folds. Directory rows come from `tree.build` / `tree.dir_paths`, the same
calls the fold code uses (`init.lua:1159`).

The function takes a model and returns tables. It touches no vim API, calls no
Telescope code, and holds no state. This mirrors `sidebar.layout(model)`
(`sidebar.lua:88`), which is pure for the same reason: it is what makes the
behaviour testable without a UI. A future fzf-lua or snacks picker consumes
this same function.

Comment counts are **not** part of `targets.list`. They depend on the
tabpage's comment store, not the model, so the extension decorates entries
after the fact, using the accessors `marks.render_sidebar` already uses
(`comments/marks.lua:375`):

- `kind == "group"`: `store.get_for_intent(title)` (`comments/store.lua:144`).
  Intent-level comments only, matching exactly what the sidebar sign counts.
  Line comments inside the intent's files are not rolled up.
- `kind == "file"`: `store.get_for_file(path, nil)` (`comments/store.lua:118`).
  A nil `side` means both panes, which is what a single count should reflect.
- `kind == "dir"`: the sum over the files beneath it, using the same call.

This keeps `targets.list` a pure function of the model and keeps every comment
query in one place.

### 3. Identity, not indices

`select_file(token, group_i, file_i, opts)` takes indices into the current
model. Targets must not carry those indices across time.

The reason is `:Telescope resume`, which replays a cached result set.
Classification swaps the whole model — `flat_model(inventory, "loading")` at
`init.lua:360`, then `flat_model`/`grouped_model` at `:402-405`. A cached
`(group_i, file_i)` captured before a reclassify can address a different
intent afterwards. Opening the wrong diff silently is the worst failure
available here, and resume makes it reachable in normal use.

So a target carries `group_title` and `path`, and resolution happens at select
time against the live model:

1. `path` present: `locate_in_model(entry.model, { path = path })`
   (`init.lua:729`) gives `(group_i, file_i)`.
2. `path` absent (`kind == "group"`): match `group_title` against
   `entry.model.groups`; first exact title match wins.
3. Directory targets resolve to their intent, then narrow through
   `subtree_group(group, dir_path)` (`init.lua:967`) — the same path a
   directory row already takes.

If a target no longer exists, notify at WARN with the target's name and
degrade: a missing file falls back to its intent if that still exists,
otherwise nothing opens. Degrading is always toward *less* specific, never
toward a different target.

### 4. Display and preview

Entry display, columns aligned by `entry_display`:

```
 <icon>  <title or "intent → path">        +12 -3   <comment icon>
```

The icon reuses the existing `file_icon` helper's approach (`sidebar.lua:64`):
`nvim-web-devicons` when installed and `icons = true`, empty string otherwise.
Intent rows get no icon. The comment column shows the icon of the first
comment on that target, matching what the sidebar sign already shows
(`comments/marks.lua:377-382`); empty when there are none.

The ordinal — the string Telescope fuzzy-matches — is `group_title .. " " ..
(path or "")`, so one prompt matches both an intent's prose and a file's path.

The previewer concatenates `hunk.text` for every hunk under the target. Every
hunk already carries its own raw unified-diff text including the `@@` header
(`hunks.lua:54`, `:134`, `:190`, `:270`), so this is a string concat, not a
render. The preview buffer gets `filetype = diff`.

Output is capped at `telescope.preview_lines` (default 500) with a trailing
`… N more lines` marker. Without a cap, moving the cursor onto a large intent
re-renders thousands of lines on every keystroke.

The preview is plain unified diff. Character-level highlighting and
side-by-side alignment exist only in the real panes; this is stated in the
README so the difference reads as intentional rather than as a limitation.

### 5. Selection

The default action closes the picker and calls the same code path the
sidebar's `<CR>` calls: `select_file(token, group_i, file_i, { focus_diff =
true })`. One selection path, one render path.

`select_file` is a file-local and `M._session(tabpage)` returns the entry
without its token (`init.lua:83`), so the implementation adds a public
`M.select(tabpage, target)` that resolves per section 3 and delegates. The
extension calls only that.

The sidebar is not touched by selection. Hidden stays hidden; visible stays
visible, and its cursor is left where it was.

### 6. Configuration

```lua
telescope = {
  include_dirs = true,   -- directory rows in the picker
  preview_lines = 500,   -- cap on previewed diff lines
},
keymaps = {
  view    = { find = "<leader>f" },
  sidebar = { find = "<leader>f" },
},
```

Both keymaps are buffer-local inside the review tab, like every other key the
plugin installs, and follow the existing `false`-disables convention
(`config.lua:100-103`). `<leader>f` is consistent with `toggle_sidebar =
"<leader>b"` already being an in-tab leader key, and collides with nothing the
plugin currently binds. It is user-overridable, as all of them are.

`keymap_help.lua` gains a row for the new key in both surfaces.

## Error handling

| Condition | Behaviour |
|---|---|
| Telescope not installed | `:IntentDiffFind` notifies WARN, returns. Nothing else affected. |
| Not in a review tab | Notify WARN: no review in this tab. |
| Classification still running | Picker opens against the current `"loading"` model — the flat "All changes" group. It is a snapshot; reopening picks up the regrouped model. |
| Target missing after reclassify | Notify WARN, degrade per section 3. |
| Model empty (no hunks) | Picker opens with no entries; Telescope's own empty state applies. |

The picker is deliberately a snapshot rather than live-refreshing. The sidebar
is the surface that stays truthful during classification, which is exactly why
it is being kept.

## Testing

`tests/targets_spec.lua` — pure, no Telescope required:

- entry shape for each of `group`, `dir`, `file`
- ordering matches sidebar order
- `include_dirs = false` omits directory rows and nothing else
- additions/deletions/hunk counts against a known model
- loading model (flat "All changes") and empty model produce sane output

`tests/telescope_select_spec.lua` — resolution, no Telescope required, since
`M.select` takes a plain target table:

- a file target resolves to the right `(group_i, file_i)`
- **the regression that matters**: build targets from model A, swap in model B
  where intents are reordered, and assert selection still lands on the intent
  that owns the file — not on whatever now sits at the old index
- a vanished file degrades to its intent; a vanished intent opens nothing and
  notifies
- a directory target narrows through `subtree_group`

`tests/telescope_extension_spec.lua` — smoke only, guarded on
`pcall(require, "telescope")` so it skips cleanly when absent: the extension
loads, registers `intents`, and builds a finder without error.

CI: `tests/init.lua` clones plenary and codediff into `stdpath("data")` on
first run; Telescope is added the same way. `.github/workflows/tests.yml` keys
its cache on `hashFiles('tests/init.lua')`, so the cache invalidates itself
when that clone is added. No workflow change is needed.

## Risks

Directory rows are the part most likely to be regretted: in a fuzzy list they
largely duplicate their own files' matches. They are behind
`telescope.include_dirs` (default true) so turning them off is a config line,
not a patch. If they prove to be noise, the default flips; the code stays.

## Out of scope

Deliberately not in this change, and each is a separate decision:

- A float-hosted sidebar. `handle.show()` could gain a float mode cheaply, but
  the picker addresses the stated problem and two navigation surfaces is a
  cost to take on only if the picker turns out to be insufficient.
- fzf-lua / snacks / `vim.ui.select` backends. `targets.list` is the seam that
  makes them possible later; none is built now.
- Any change to cursor-driven preview, folds, comment signs, or the sidebar
  footer.
