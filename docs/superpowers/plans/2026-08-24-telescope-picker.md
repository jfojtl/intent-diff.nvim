# Telescope Intent Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional Telescope picker that fuzzy-finds any intent, directory or file in a review and opens it, so the sidebar can stay hidden on small screens.

**Architecture:** A pure `targets.lua` turns a model into a flat list of selectable targets carrying stable identity (intent title + path) rather than array indices. A new public `intentdiff.select(tabpage, target)` re-resolves that identity against the live model and delegates to the existing render paths. A Telescope extension consumes both. Telescope is resolved only at invocation, never at load.

**Tech Stack:** Lua, Neovim 0.11+, plenary.nvim (busted-style specs), telescope.nvim (optional runtime dep), nvim-web-devicons (optional).

**Spec:** `docs/superpowers/specs/2026-08-24-telescope-picker-design.md`

## Global Constraints

- Telescope is **never** a hard dependency. No `require("telescope")` at plugin-load or `setup()` time. The only `require` is inside `intentdiff.find()`, on the invocation path.
- `lua/intentdiff/targets.lua` must stay pure: it takes a model table, returns tables, and calls no vim API. This is what makes it testable without a UI, matching `sidebar.layout()` (`lua/intentdiff/sidebar.lua:88`).
- Targets carry `group_title` and `path`. They must never carry `group_i` / `file_i` across time — `:Telescope resume` replays cached results, and reclassification swaps the whole model (`lua/intentdiff/init.lua:360`, `:402-405`).
- Tests run via `make test` (a single spec: `make test TEST=tests/foo_spec.lua`). Never `PlenaryBustedFile` — see the comment block at the top of `Makefile`.
- New user-facing keys go through `config.options.keymaps.<surface>.<action>` and must honour the `false`-disables convention, installed via `require("intentdiff.keymaps").each`.
- Do not modify sidebar behaviour: tree, folds, comment signs, stats footer, spinner, cursor-driven preview and `toggle_sidebar` all stay exactly as they are.

---

## File Structure

| File | Responsibility |
|---|---|
| `lua/intentdiff/targets.lua` (create) | Pure model → target list. The reusable seam. |
| `tests/targets_spec.lua` (create) | Covers the above with plain tables. |
| `lua/intentdiff/init.lua` (modify) | Adds public `M.select(tabpage, target)` and `M.find()`. |
| `tests/telescope_select_spec.lua` (create) | Identity re-resolution, including the stale-model regression. |
| `lua/intentdiff/config.lua` (modify) | `telescope` options block; `find` keymap on two surfaces. |
| `lua/intentdiff/keymap_help.lua` (modify) | One cheatsheet row per surface. |
| `lua/telescope/_extensions/intentdiff.lua` (create) | Telescope finder, entry display, previewer, action. Inert without Telescope. |
| `plugin/intentdiff.lua` (modify) | `:IntentDiffFind` command. |
| `lua/intentdiff/sidebar.lua`, `lua/intentdiff/view.lua` (modify) | Install the `find` key on their surfaces. |
| `tests/init.lua` (modify) | Clone telescope.nvim for the smoke spec. |
| `tests/telescope_extension_spec.lua` (create) | Smoke test, skips when Telescope is absent. |
| `README.md` (modify) | Document the picker and its optional status. |

---

## Task 1: `targets.lua` — the pure data layer

**Files:**
- Create: `lua/intentdiff/targets.lua`
- Test: `tests/targets_spec.lua`

**Interfaces:**
- Consumes: `require("intentdiff.tree").build(files)` and `.flatten(nodes, collapsed)` (`lua/intentdiff/tree.lua:40`, `:113`). `flatten` rows carry `kind`, `name`, `path`, `additions`, `deletions`, `file_i`.
- Produces:
  ```lua
  --- @return Target[]
  function M.list(model, opts)
  ```
  where `opts` is `{ include_dirs = boolean }` (default `true`) and a Target is:
  ```lua
  { kind = "group"|"dir"|"file",
    group_title = string,
    path = string|nil,      -- file path, or directory path when kind == "dir"
    additions = integer,
    deletions = integer,
    hunk_count = integer }
  ```

Background the implementer needs: a `model` is `{ state, groups }`; each group is `{ title, files, hunks, collapsed, collapsed_dirs }`; each file is `{ path, status, hunks }`; each hunk carries `additions` and `deletions`. `tree.flatten` is called with an **empty** collapsed table here — a fuzzy list has no folds, so every row is always emitted regardless of the sidebar's current fold state.

- [ ] **Step 1: Write the failing test**

Create `tests/targets_spec.lua`:

```lua
local targets = require("intentdiff.targets")

local function hunk(adds, dels)
  return { additions = adds or 1, deletions = dels or 0 }
end

local function file(path, hunks)
  return { path = path, status = "M", hunks = hunks or { hunk(1, 0) } }
end

local function model(groups)
  return { state = "ready", groups = groups }
end

describe("targets.list", function()
  it("emits one target per intent, directory and file, in sidebar order", function()
    local out = targets.list(model({
      { title = "Add retry logic", files = { file("src/a.lua"), file("src/b.lua") } },
    }))
    assert.equals(4, #out)
    assert.equals("group", out[1].kind)
    assert.equals("Add retry logic", out[1].group_title)
    assert.is_nil(out[1].path)
    assert.equals("dir", out[2].kind)
    assert.equals("src", out[2].path)
    assert.equals("file", out[3].kind)
    assert.equals("src/a.lua", out[3].path)
    assert.equals("file", out[4].kind)
    assert.equals("src/b.lua", out[4].path)
  end)

  it("carries the intent title on every target, not an index", function()
    local out = targets.list(model({
      { title = "First", files = { file("a.lua") } },
      { title = "Second", files = { file("b.lua") } },
    }))
    for _, t in ipairs(out) do
      assert.is_string(t.group_title)
      assert.is_nil(t.group_i)
      assert.is_nil(t.file_i)
    end
    assert.equals("Second", out[#out].group_title)
  end)

  it("sums additions, deletions and hunk counts per kind", function()
    local out = targets.list(model({
      { title = "T", files = {
        file("src/a.lua", { hunk(3, 1), hunk(2, 0) }),
        file("src/b.lua", { hunk(5, 4) }),
      } },
    }))
    assert.equals(10, out[1].additions) -- intent: every hunk it owns
    assert.equals(5, out[1].deletions)
    assert.equals(3, out[1].hunk_count)
    assert.equals(10, out[2].additions) -- dir "src": every file beneath it
    assert.equals(5, out[2].deletions)
    assert.equals(3, out[2].hunk_count)
    assert.equals(5, out[3].additions) -- file src/a.lua
    assert.equals(1, out[3].deletions)
    assert.equals(2, out[3].hunk_count)
  end)

  it("omits directory rows when include_dirs is false", function()
    local out = targets.list(model({
      { title = "T", files = { file("src/a.lua") } },
    }), { include_dirs = false })
    assert.equals(2, #out)
    assert.equals("group", out[1].kind)
    assert.equals("file", out[2].kind)
  end)

  it("ignores collapse state — a collapsed intent still yields its files", function()
    local out = targets.list(model({
      { title = "T", collapsed = true, collapsed_dirs = { src = true },
        files = { file("src/a.lua") } },
    }))
    assert.equals(3, #out)
  end)

  it("handles the loading model and an empty model", function()
    local out = targets.list(model({
      { title = "All changes", files = { file("a.lua") } },
    }))
    assert.equals(2, #out)
    assert.same({}, targets.list(model({})))
    assert.same({}, targets.list(nil))
  end)

  it("handles an intent with no files", function()
    local out = targets.list(model({ { title = "Empty", files = {} } }))
    assert.equals(1, #out)
    assert.equals("group", out[1].kind)
    assert.equals(0, out[1].hunk_count)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test TEST=tests/targets_spec.lua`
Expected: FAIL — `module 'intentdiff.targets' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `lua/intentdiff/targets.lua`:

```lua
-- Pure model → selectable-target list. No Neovim UI state and no vim API:
-- this is the seam every picker sits on, and keeping it pure is what lets the
-- whole navigation behaviour be tested without a UI (the same reason
-- sidebar.layout is pure).
--
-- Targets carry the intent TITLE and the file PATH, never array indices.
-- `:Telescope resume` replays a cached result set, and classification swaps
-- the whole model out (init.lua's flat_model → grouped_model), so an index
-- captured before a reclassify can address a different intent afterwards.
-- Identity survives that; indices do not.
local M = {}

local tree = require("intentdiff.tree")

local function sum_hunks(hunks)
  local additions, deletions, count = 0, 0, 0
  for _, h in ipairs(hunks or {}) do
    additions = additions + (h.additions or 0)
    deletions = deletions + (h.deletions or 0)
    count = count + 1
  end
  return additions, deletions, count
end

--- Every hunk of every file at or beneath `prefix`, or of the whole group when
--- `prefix` is nil.
local function hunks_under(group, prefix)
  local out = {}
  for _, f in ipairs(group.files or {}) do
    if not prefix or f.path:sub(1, #prefix + 1) == prefix .. "/" then
      vim.list_extend(out, f.hunks or {})
    end
  end
  return out
end

--- Flatten `model` into selectable targets, in sidebar order.
---
--- Fold state is deliberately ignored: tree.flatten is called with an empty
--- collapsed table, so a collapsed intent still yields its files. A fuzzy list
--- has no folds, and hiding matches behind the sidebar's current fold state
--- would make the picker's results depend on invisible UI state.
---
--- @param model table|nil { state, groups }
--- @param opts table|nil { include_dirs = boolean } — defaults to true
--- @return table[] targets
function M.list(model, opts)
  opts = opts or {}
  local include_dirs = opts.include_dirs ~= false
  local out = {}
  for _, g in ipairs(model and model.groups or {}) do
    local additions, deletions, count = sum_hunks(hunks_under(g, nil))
    out[#out + 1] = {
      kind = "group",
      group_title = g.title,
      path = nil,
      additions = additions,
      deletions = deletions,
      hunk_count = count,
    }
    for _, row in ipairs(tree.flatten(tree.build(g.files or {}), {})) do
      if row.kind == "dir" then
        if include_dirs then
          local a, d, c = sum_hunks(hunks_under(g, row.path))
          out[#out + 1] = {
            kind = "dir",
            group_title = g.title,
            path = row.path,
            additions = a,
            deletions = d,
            hunk_count = c,
          }
        end
      else
        local f = (g.files or {})[row.file_i]
        local _, _, c = sum_hunks(f and f.hunks)
        out[#out + 1] = {
          kind = "file",
          group_title = g.title,
          path = row.path,
          additions = row.additions,
          deletions = row.deletions,
          hunk_count = c,
        }
      end
    end
  end
  return out
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test TEST=tests/targets_spec.lua`
Expected: PASS, all 7 examples.

- [ ] **Step 5: Run the whole suite to confirm nothing regressed**

Run: `make test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/targets.lua tests/targets_spec.lua
git commit -m "feat(targets): pure model-to-target list for pickers

Targets carry intent title and file path rather than array indices, so a
cached result set stays correct across a reclassification."
```

---

## Task 2: `intentdiff.select` — identity re-resolution

**Files:**
- Modify: `lua/intentdiff/init.lua` (add `M.select` after `subtree_group`, which ends around `:978`, and before `M.open` at `:1104`)
- Test: `tests/telescope_select_spec.lua`

**Interfaces:**
- Consumes: `M.list` targets from Task 1. Internal locals already in `init.lua`: `sessions`, `locate_in_model` (`:729` area), `select_file` (`:661`), `show_group` (`:~980`), `subtree_group` (`:967`), `focus_diff_pane` (`:475`).
- Produces:
  ```lua
  --- @param tabpage integer|nil
  --- @param target table  a target from intentdiff.targets.list
  --- @return boolean opened
  function M.select(tabpage, target)
  ```

Background: sidebar `<CR>` renders only **file** rows; on a group or directory row it toggles a fold. Whole-intent rendering lives only in `apply_hover` → `show_group` / `subtree_group`. So `M.select` has two delegation paths. `show_group(entry, group, opts)` forwards `opts` to `view.show`, whose `opts.on_ready` fires once after the first paint (`lua/intentdiff/view.lua:476-480`) — that is where focus moves, because hover deliberately leaves focus in the sidebar.

Degradation rule: a missing file falls back to its intent if the intent still exists; a missing intent opens nothing and notifies. Degrade toward *less* specific, never toward a different target.

- [ ] **Step 1: Write the failing test**

Create `tests/telescope_select_spec.lua`. `helpers.lua` exists in `tests/` — read it first and follow its session-construction pattern if it provides one; otherwise drive through the public API as below.

```lua
local intentdiff = require("intentdiff")
local targets = require("intentdiff.targets")

local function hunk(adds, dels)
  return { additions = adds or 1, deletions = dels or 0 }
end
local function file(path)
  return { path = path, status = "M", hunks = { hunk(1, 0) } }
end

--- A session entry stubbed far enough for M.select: a model, a tabpage, and
--- recording stand-ins for the two render paths.
local function stub_session(groups)
  local calls = {}
  local entry = {
    model = { state = "ready", groups = groups },
    sess = { tabpage = vim.api.nvim_get_current_tabpage() },
    _test_hooks = {
      select_file = function(_, gi, fi) calls[#calls + 1] = { "file", gi, fi } end,
      show_group = function(_, group) calls[#calls + 1] = { "group", group.title } end,
    },
  }
  intentdiff._register_test_session(entry)
  return entry, calls
end

describe("intentdiff.select", function()
  after_each(function()
    intentdiff._clear_test_sessions()
  end)

  it("opens a file target at its current indices", function()
    local entry, calls = stub_session({
      { title = "First", files = { file("a.lua") } },
      { title = "Second", files = { file("b.lua") } },
    })
    local list = targets.list(entry.model)
    local t = vim.tbl_filter(function(x) return x.path == "b.lua" end, list)[1]
    assert.is_true(intentdiff.select(entry.sess.tabpage, t))
    assert.same({ "file", 2, 1 }, calls[1])
  end)

  it("follows the file when the model is reordered underneath it", function()
    local entry, calls = stub_session({
      { title = "First", files = { file("a.lua") } },
      { title = "Second", files = { file("b.lua") } },
    })
    local list = targets.list(entry.model)
    local t = vim.tbl_filter(function(x) return x.path == "b.lua" end, list)[1]

    -- Reclassification swaps the model: the intents change places.
    entry.model = { state = "ready", groups = {
      { title = "Second", files = { file("b.lua") } },
      { title = "First", files = { file("a.lua") } },
    } }

    assert.is_true(intentdiff.select(entry.sess.tabpage, t))
    -- Index 2 would now be the WRONG intent. Identity must win.
    assert.same({ "file", 1, 1 }, calls[1])
  end)

  it("renders a whole intent for a group target", function()
    local entry, calls = stub_session({
      { title = "Add retry logic", files = { file("a.lua") } },
    })
    local t = targets.list(entry.model)[1]
    assert.is_true(intentdiff.select(entry.sess.tabpage, t))
    assert.same({ "group", "Add retry logic" }, calls[1])
  end)

  it("narrows a directory target to its subtree", function()
    local entry, calls = stub_session({
      { title = "T", files = { file("src/a.lua"), file("other/b.lua") } },
    })
    local t = vim.tbl_filter(function(x) return x.kind == "dir" and x.path == "src" end,
      targets.list(entry.model))[1]
    assert.is_true(intentdiff.select(entry.sess.tabpage, t))
    assert.same({ "group", "src" }, calls[1]) -- subtree_group titles itself by dir
  end)

  it("degrades a vanished file to its intent", function()
    local entry, calls = stub_session({
      { title = "T", files = { file("gone.lua"), file("kept.lua") } },
    })
    local t = vim.tbl_filter(function(x) return x.path == "gone.lua" end,
      targets.list(entry.model))[1]
    entry.model = { state = "ready", groups = {
      { title = "T", files = { file("kept.lua") } },
    } }
    assert.is_true(intentdiff.select(entry.sess.tabpage, t))
    assert.same({ "group", "T" }, calls[1])
  end)

  it("opens nothing when the intent is gone too", function()
    local entry, calls = stub_session({
      { title = "T", files = { file("gone.lua") } },
    })
    local t = targets.list(entry.model)[1]
    entry.model = { state = "ready", groups = {
      { title = "Different", files = { file("other.lua") } },
    } }
    assert.is_false(intentdiff.select(entry.sess.tabpage, t))
    assert.equals(0, #calls)
  end)

  it("returns false when the tab holds no review", function()
    assert.is_false(intentdiff.select(vim.api.nvim_get_current_tabpage(),
      { kind = "group", group_title = "T" }))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test TEST=tests/telescope_select_spec.lua`
Expected: FAIL — `attempt to call field '_register_test_session' (a nil value)`.

- [ ] **Step 3: Add the test seam and `M.select` to `init.lua`**

Add near `M._session` (`lua/intentdiff/init.lua:83`), keeping the existing `_`-prefix convention for test-facing entry points:

```lua
--- Register a stubbed session entry. Test-only: M.select's resolution logic is
--- worth testing on its own, and standing up a real review tab to do it would
--- test the renderer instead.
function M._register_test_session(entry)
  next_token = next_token + 1
  sessions[next_token] = entry
  entry._token = next_token
  return next_token
end

function M._clear_test_sessions()
  for token, entry in pairs(sessions) do
    if entry._test_hooks then
      sessions[token] = nil
    end
  end
end
```

Then add `M.select` **after** `subtree_group` and `show_group` are both in scope — place it immediately before `function M.open(argline)` (`lua/intentdiff/init.lua:1104`):

```lua
--- Open `target` — an entry from intentdiff.targets.list — in `tabpage`.
---
--- Targets carry identity (intent title, file path), never indices, so this
--- re-resolves against the CURRENT model on every call. That is what makes
--- `:Telescope resume` safe: resume replays a cached result set, and a
--- reclassification between the original pick and the resume would otherwise
--- have moved the indices under it.
---
--- Two delegation paths, because the sidebar has two. A file row's <CR> goes
--- through select_file; a group or directory row's <CR> only toggles a fold,
--- and whole-intent rendering lives in apply_hover's show_group/subtree_group.
--- Hover leaves focus in the sidebar on purpose, so an explicit pick asks
--- view.show to move it once the first paint lands.
---
--- Degrades toward LESS specific, never toward a different target: a file that
--- is gone falls back to its intent, and a missing intent opens nothing.
--- @return boolean opened
function M.select(tabpage, target)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = M._session(tabpage)
  if not (entry and target) then
    return false
  end
  local hooks = entry._test_hooks or {}
  local do_select_file = hooks.select_file or select_file
  local do_show_group = hooks.show_group or show_group

  if target.path and target.kind == "file" then
    local group_i, file_i = locate_in_model(entry.model, { path = target.path })
    if group_i then
      do_select_file(entry._token, group_i, file_i, { focus_diff = true })
      return true
    end
    -- Fall through: the file is gone, so try its intent.
  end

  local group_i
  for gi, g in ipairs(entry.model and entry.model.groups or {}) do
    if g.title == target.group_title then
      group_i = gi
      break
    end
  end
  if not group_i then
    vim.notify(("intent-diff: %s is no longer in this review")
      :format(target.path or target.group_title or "that target"), vim.log.levels.WARN)
    return false
  end

  local group = entry.model.groups[group_i]
  if target.kind == "dir" and target.path then
    group = subtree_group(group, target.path)
  end
  do_show_group(entry, group, {
    on_ready = function()
      focus_diff_pane(tabpage)
    end,
  })
  return true
end
```

Note for the implementer: `select_file` and `show_group` are locals declared earlier in the file, so `M.select` must appear textually after both. `subtree_group` is at `:967` and `show_group` just below it — placing `M.select` immediately before `M.open` satisfies all of them.

- [ ] **Step 4: Run test to verify it passes**

Run: `make test TEST=tests/telescope_select_spec.lua`
Expected: PASS, all 7 examples. In particular "follows the file when the model is reordered underneath it" must pass — that is the regression this task exists for.

- [ ] **Step 5: Run the whole suite**

Run: `make test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/init.lua tests/telescope_select_spec.lua
git commit -m "feat(select): resolve picker targets by identity, not index

A cached target from :Telescope resume must still open the intent that
owns the file after a reclassification reorders the model."
```

---

## Task 3: Configuration and keymaps

**Files:**
- Modify: `lua/intentdiff/config.lua` (`M.defaults`, around `:37` for the options block and `:100-135` for the keymap surfaces)
- Modify: `lua/intentdiff/keymap_help.lua` (around `:86`, where `toggle_sidebar` is listed)
- Test: `tests/config_spec.lua` (append)

**Interfaces:**
- Produces: `config.options.telescope = { include_dirs = boolean, preview_lines = integer }`, `config.options.keymaps.view.find`, `config.options.keymaps.sidebar.find`.

- [ ] **Step 1: Write the failing test**

Append to `tests/config_spec.lua`:

```lua
describe("telescope options", function()
  it("defaults to directory rows on and a 500-line preview cap", function()
    require("intentdiff.config").setup({})
    local opts = require("intentdiff.config").options
    assert.is_true(opts.telescope.include_dirs)
    assert.equals(500, opts.telescope.preview_lines)
  end)

  it("lets a user turn directory rows off without losing preview_lines", function()
    require("intentdiff.config").setup({ telescope = { include_dirs = false } })
    local opts = require("intentdiff.config").options
    assert.is_false(opts.telescope.include_dirs)
    assert.equals(500, opts.telescope.preview_lines)
  end)

  it("binds find on both the view and the sidebar", function()
    require("intentdiff.config").setup({})
    local km = require("intentdiff.config").options.keymaps
    assert.equals("<leader>f", km.view.find)
    assert.equals("<leader>f", km.sidebar.find)
  end)

  it("honours false to disable the find key", function()
    require("intentdiff.config").setup({ keymaps = { view = { find = false } } })
    local km = require("intentdiff.config").options.keymaps
    assert.is_false(km.view.find)
    assert.equals("q", km.view.quit) -- sibling actions survive the override
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test TEST=tests/config_spec.lua`
Expected: FAIL — `attempt to index field 'telescope' (a nil value)`.

- [ ] **Step 3: Add the options**

In `lua/intentdiff/config.lua`, inside `M.defaults`, after the `preview` block (`:78`):

```lua
  -- Optional Telescope picker (:IntentDiffFind). Telescope is never required:
  -- these options are inert when it is not installed.
  telescope = {
    include_dirs = true, -- directory rows alongside intents and files
    -- Cap on previewed diff lines. Without it, moving the cursor onto a large
    -- intent re-renders thousands of lines on every keystroke.
    preview_lines = 500,
  },
```

In the `keymaps.view` table (after `open_file`, `:117`):

```lua
      -- Fuzzy-find any intent, directory or file. Installed on the sidebar
      -- too, since the picker's whole point is being reachable with the
      -- sidebar hidden. No-op with an explanatory notice when telescope.nvim
      -- is not installed.
      find = "<leader>f",
```

In the `keymaps.sidebar` table (after `show_help`, `:127`):

```lua
      find = "<leader>f",
```

In `lua/intentdiff/keymap_help.lua`, beside the `toggle_sidebar` row (`:86`):

```lua
    { vkm.find, "Fuzzy-find an intent, file or directory (needs telescope.nvim)" },
```

The row is listed unconditionally rather than probed for, because probing would force-load Telescope just to draw the cheatsheet — see the spec's "Why availability is not checked up front".

- [ ] **Step 4: Run test to verify it passes**

Run: `make test TEST=tests/config_spec.lua`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `make test`
Expected: PASS. `tests/keymap_help_spec.lua` may assert on row counts — if it fails, update its expectation to include the new row.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/config.lua lua/intentdiff/keymap_help.lua tests/config_spec.lua tests/keymap_help_spec.lua
git commit -m "feat(config): telescope options and the find keymap"
```

---

## Task 4: The Telescope extension, the command, and the keys

**Files:**
- Create: `lua/telescope/_extensions/intentdiff.lua`
- Modify: `lua/intentdiff/init.lua` (add `M.find`)
- Modify: `plugin/intentdiff.lua` (add `:IntentDiffFind`)
- Modify: `lua/intentdiff/sidebar.lua` (install `find` alongside `toggle_sidebar`, around `:400`)
- Modify: `lua/intentdiff/view.lua` (install `find` alongside `toggle_sidebar`, around `:815`)
- Modify: `tests/init.lua` (clone telescope.nvim)
- Test: `tests/telescope_extension_spec.lua`

**Interfaces:**
- Consumes: `targets.list(model, opts)` (Task 1), `intentdiff.select(tabpage, target)` (Task 2), `config.options.telescope` (Task 3).
- Produces: `intentdiff.find()`; a Telescope extension exposing the `intents` picker.

- [ ] **Step 1: Add Telescope to the test bootstrap**

In `tests/init.lua`, after the codediff block and before `vim.cmd("runtime! plugin/*.lua")`:

```lua
-- telescope: optional at runtime, but the extension smoke spec needs it.
-- Cloned the same way as plenary; the CI cache key is hashFiles('tests/init.lua'),
-- so adding this invalidates the cache exactly once.
local telescope_dir = vim.fn.stdpath("data") .. "/telescope.nvim"
if vim.fn.isdirectory(telescope_dir) == 0 then
  vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/nvim-telescope/telescope.nvim", telescope_dir })
end
vim.opt.rtp:prepend(telescope_dir)
```

- [ ] **Step 2: Write the failing test**

Create `tests/telescope_extension_spec.lua`:

```lua
local has_telescope = pcall(require, "telescope")

describe("telescope extension", function()
  if not has_telescope then
    it("skips when telescope.nvim is absent", function()
      assert.is_true(true)
    end)
    return
  end

  it("registers an intents picker", function()
    require("telescope").load_extension("intentdiff")
    local ext = require("telescope").extensions.intentdiff
    assert.is_function(ext.intents)
  end)

  it("builds entries from a model without touching a real review", function()
    require("telescope").load_extension("intentdiff")
    local ext = require("telescope").extensions.intentdiff
    -- nil store, not {}: comment_icon treats any truthy store as a real one and
    -- calls store.get_for_file on it.
    local entry = ext._entry_maker({
      kind = "file",
      group_title = "Add retry logic",
      path = "src/a.lua",
      additions = 3,
      deletions = 1,
      hunk_count = 2,
    }, nil)
    assert.equals("Add retry logic src/a.lua", entry.ordinal)
    assert.is_function(entry.display)
  end)
end)

describe("intentdiff.find without a review", function()
  it("returns false rather than erroring", function()
    assert.is_false(require("intentdiff").find())
  end)
end)
```

Note: `_entry_maker` is reached through `require("telescope").extensions.intentdiff`, not by requiring the extension file directly. The file returns `telescope.register_extension({ exports = ... })`, whose return value nests everything under `.exports`; Telescope flattens those onto `extensions.<name>` when the extension loads. Requiring the file directly would give you the un-flattened table and `_entry_maker` would be nil.

- [ ] **Step 3: Run test to verify it fails**

Run: `make test TEST=tests/telescope_extension_spec.lua`
Expected: FAIL — the extension does not exist, and `intentdiff.find` is nil.

- [ ] **Step 4: Add `M.find` to `init.lua`**

Place immediately after `M.select`:

```lua
--- Open the Telescope picker for this tab's review.
---
--- Telescope is resolved HERE and nowhere else. It is never required at load
--- or setup time, and this is the only `require` of it in the plugin — the
--- same treatment nvim-web-devicons gets in sidebar.lua, not the treatment
--- codediff gets in view.load(), because unlike codediff it is genuinely
--- optional.
---
--- Resolving at invocation rather than at startup is deliberate: under
--- lazy.nvim an installed-but-unloaded plugin is not yet on the runtimepath,
--- so a startup probe would report "not installed" for exactly the users who
--- do have it. A require on the invocation path loads it correctly instead.
--- @return boolean opened
function M.find(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  if not M._session(tabpage) then
    vim.notify("intent-diff: no review in this tab", vim.log.levels.WARN)
    return false
  end
  local ok, telescope = pcall(require, "telescope")
  if not ok then
    vim.notify("intent-diff: :IntentDiffFind needs telescope.nvim", vim.log.levels.WARN)
    return false
  end
  local loaded = pcall(telescope.load_extension, "intentdiff")
  if not loaded then
    vim.notify("intent-diff: could not load the telescope extension", vim.log.levels.WARN)
    return false
  end
  telescope.extensions.intentdiff.intents()
  return true
end
```

- [ ] **Step 5: Write the extension**

Create `lua/telescope/_extensions/intentdiff.lua`:

```lua
-- Telescope extension for intent-diff.
--
-- This file is INERT without Telescope. It lives on the runtimepath, but Lua
-- loads a module only when something requires it, and the only thing that ever
-- requires this one is Telescope's own load_extension. With Telescope absent
-- it is never read.
--
-- Registered as a named extension rather than calling telescope.pickers
-- directly, because that is what buys the conventions: `:Telescope resume`,
-- and per-picker prompt history under telescope-smart-history, which keys
-- history by picker name and cwd and therefore needs a named picker.
local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  error("intent-diff: this telescope extension requires telescope.nvim")
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")
local entry_display = require("telescope.pickers.entry_display")

local M = {}

local displayer = entry_display.create({
  separator = " ",
  items = {
    { width = 2 },   -- devicon
    { remaining = true },
    { width = 9 },   -- +N -M
    { width = 2 },   -- comment marker
  },
})

--- Devicon for `path`, mirroring sidebar.lua's guard: absent devicons or
--- `icons = false` yields an empty string rather than an error.
local function file_icon(path)
  if not path or not require("intentdiff.config").options.icons then
    return "", nil
  end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return "", nil
  end
  local icon, icon_hl = devicons.get_icon(path, nil, { default = true })
  return icon or "", icon_hl
end

--- Comment count for one target, using the same accessors the sidebar sign
--- uses. Intent rows count intent-level comments only — line comments inside
--- the intent's files are not rolled up, matching comments/marks.lua's
--- render_sidebar. `store` is nil when comments are disabled.
local function comment_icon(store, target)
  if not store then
    return ""
  end
  local comments
  if target.kind == "group" then
    comments = store.get_for_intent(target.group_title)
  elseif target.kind == "file" then
    comments = store.get_for_file(target.path, nil)
  else
    comments = {}
    for _, c in ipairs(store.get_all()) do
      if c.file and not c.intent_title and c.file:sub(1, #target.path + 1) == target.path .. "/" then
        comments[#comments + 1] = c
      end
    end
  end
  if #comments == 0 then
    return ""
  end
  for _, t in ipairs(require("intentdiff.config").options.comments.types) do
    if t.key == comments[1].type then
      return t.icon
    end
  end
  return "*"
end

--- Exposed for testing: a target plus its comment store becomes a Telescope
--- entry. The ordinal joins the intent's prose and the path so one prompt
--- matches both "retry" and "config.lua".
function M._entry_maker(target, store)
  local label = target.kind == "group" and target.group_title
    or (target.group_title .. " → " .. target.path)
  local stats = ("+%d -%d"):format(target.additions, target.deletions)
  local icon, icon_hl = file_icon(target.kind == "file" and target.path or nil)
  return {
    value = target,
    ordinal = target.group_title .. " " .. (target.path or ""),
    display = function()
      return displayer({
        { icon, icon_hl },
        label,
        { stats, "Comment" },
        comment_icon(store, target),
      })
    end,
  }
end

--- Unified diff for `target`, straight out of the hunks already in memory.
--- Every hunk carries its own raw diff text including the @@ header, so this
--- is a concat, not a render. Capped: without a cap, moving the cursor onto a
--- large intent re-renders thousands of lines on every keystroke.
local function preview_lines_for(model, target, cap)
  local lines = {}
  for _, g in ipairs(model and model.groups or {}) do
    if g.title == target.group_title then
      for _, f in ipairs(g.files or {}) do
        local under = target.kind == "group"
          or (target.kind == "file" and f.path == target.path)
          or (target.kind == "dir" and f.path:sub(1, #target.path + 1) == target.path .. "/")
        if under then
          for _, h in ipairs(f.hunks or {}) do
            for line in (h.text or ""):gmatch("(.-)\n") do
              lines[#lines + 1] = line
            end
          end
        end
      end
      break
    end
  end
  if #lines > cap then
    local trimmed = vim.list_slice(lines, 1, cap)
    trimmed[#trimmed + 1] = ("… %d more lines"):format(#lines - cap)
    return trimmed
  end
  return lines
end

local function intents(opts)
  opts = opts or {}
  local cfg = require("intentdiff.config").options
  local tabpage = vim.api.nvim_get_current_tabpage()
  local entry = require("intentdiff")._session(tabpage)
  if not entry then
    vim.notify("intent-diff: no review in this tab", vim.log.levels.WARN)
    return
  end
  local model = entry.model
  local store = require("intentdiff.config").comments_enabled()
    and require("intentdiff.comments").store_for(tabpage) or nil
  local list = require("intentdiff.targets").list(model,
    { include_dirs = cfg.telescope.include_dirs })

  pickers.new(opts, {
    prompt_title = "Intents",
    finder = finders.new_table({
      results = list,
      entry_maker = function(target) return M._entry_maker(target, store) end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Diff",
      define_preview = function(self, entry_)
        local lines = preview_lines_for(model, entry_.value, cfg.telescope.preview_lines)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "diff"
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selected = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selected then
          require("intentdiff").select(tabpage, selected.value)
        end
      end)
      return true
    end,
  }):find()
end

return telescope.register_extension({ exports = { intents = intents, _entry_maker = M._entry_maker } })
```

- [ ] **Step 6: Register the command and the keys**

In `plugin/intentdiff.lua`, after the `IntentDiffSidebar` command:

```lua
-- Registered unconditionally. Registering a command creates no dependency —
-- its body never runs unless called — and gating it on a startup probe for
-- telescope.nvim would hide it from lazy.nvim users whose telescope is
-- installed but not yet on the runtimepath.
vim.api.nvim_create_user_command("IntentDiffFind", function()
  require("intentdiff").find()
end, { desc = "intent-diff: fuzzy-find an intent, directory or file" })
```

In `lua/intentdiff/sidebar.lua`, beside the existing `map(vkm.toggle_sidebar, ...)` (`:400`):

```lua
  map(vkm.find, function()
    require("intentdiff").find()
  end, "intent-diff: fuzzy-find an intent, file or directory")
```

In `lua/intentdiff/view.lua`, beside the existing `toggle_sidebar` entry (`:815`) and its description table (`:685`):

```lua
      find = function()
        require("intentdiff").find()
      end,
```
```lua
  find = "intent-diff: fuzzy-find an intent, file or directory",
```

- [ ] **Step 7: Run test to verify it passes**

Run: `make test TEST=tests/telescope_extension_spec.lua`
Expected: PASS. The first run clones telescope.nvim, so allow extra time.

- [ ] **Step 8: Verify the optional-dependency guarantee holds**

This is the constraint most easily broken by a stray `require`, so check it directly:

Run: `grep -rn 'require("telescope' lua/intentdiff/`
Expected: exactly one hit, inside `M.find` in `lua/intentdiff/init.lua`. Any hit at module top level is a bug — fix it before committing.

Run: `nvim --headless --clean -c 'set rtp+=.' -c 'runtime! plugin/*.lua' -c 'lua require("intentdiff").setup()' -c 'lua print(vim.fn.exists(":IntentDiffFind"))' -c 'qa'`
Expected: prints `2` (the command exists) with no error, on a runtimepath that has no Telescope at all.

- [ ] **Step 9: Run the whole suite**

Run: `make test`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lua/telescope tests/telescope_extension_spec.lua tests/init.lua \
  lua/intentdiff/init.lua lua/intentdiff/sidebar.lua lua/intentdiff/view.lua \
  plugin/intentdiff.lua
git commit -m "feat(telescope): optional fuzzy picker for intents, dirs and files

Telescope is resolved only inside intentdiff.find(), so the plugin loads
and works unchanged without it."
```

---

## Task 5: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the picker**

Add a subsection under the existing usage material, covering:

- What `:IntentDiffFind` / `<leader>f` does: fuzzy-match intent titles and file paths in one prompt, then open the result in the diff panes.
- That it pairs with `<leader>b`: hide the sidebar on a small screen and navigate entirely from the picker.
- That telescope.nvim is **optional** — without it the plugin behaves exactly as before and the command reports what is missing.
- That the picker's preview is plain unified diff, and character-level highlighting plus side-by-side alignment exist only in the real panes. State this as the deliberate choice it is.
- The `telescope.include_dirs` and `telescope.preview_lines` options.
- That `:Telescope resume` works, and that selections stay correct across a reclassification.

Add telescope.nvim to the installation section as an optional dependency, e.g. in the `lazy.nvim` snippet:

```lua
    dependencies = {
      "esmuellert/codediff.nvim",
      "nvim-telescope/telescope.nvim", -- optional: enables :IntentDiffFind
    },
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document the optional Telescope picker"
```

---

## Verification

Before calling the feature done:

- [ ] `make test` passes in full.
- [ ] `grep -rn 'require("telescope' lua/intentdiff/` returns exactly one hit, inside `M.find`.
- [ ] The headless no-Telescope check from Task 4 Step 8 passes.
- [ ] Manual: open a review, press `<leader>b` to hide the sidebar, `<leader>f`, type part of an intent title, select it, confirm the intent renders across all its files and focus lands in the diff.
- [ ] Manual: open the picker, `<Esc>`, then `:Telescope resume` — the same list returns and selecting from it opens the right target.
- [ ] Manual: press `R` to reclassify, then `:Telescope resume` and select — confirm you land on the intent that owns the file, or get a WARN if it is gone, never a silently wrong diff.
