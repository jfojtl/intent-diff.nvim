# intent-diff.nvim Navigation Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the sidebar cursor open file diffs the same way it already previews intents and directories, give `<CR>` the distinct job of jumping into the diff, and add sidebar show/hide plus a toggle-all-intents action.

**Architecture:** All five changes are wiring in existing modules. `apply_hover` gains a file branch that opens; `open_file` gains focus flags; `sidebar.create` gains `hide`/`show` closures and two keymaps; `view.install_keymaps` carries the sidebar-toggle key to the diff panes so it is reachable when the sidebar is hidden.

**Tech Stack:** Lua, Neovim 0.10+ API, plenary.nvim busted specs, codediff.nvim (consumed only through `lua/intentdiff/view.lua`).

**Spec:** `docs/superpowers/specs/2026-07-31-intent-diff-navigation-design.md`

## Global Constraints

- `lua/intentdiff/view.lua` is the ONLY module permitted to `require` codediff.
- Never create or close a window to render a preview; preview buffers are never fold-filtered.
- Tests never call a real LLM — fake provider functions or `helpers.fake_bin` only.
- Hunk ranges are 1-based and end-exclusive.
- Commits are GPG-signed (`git commit -S`). No `Co-Authored-By` lines.
- Run the full suite with `tests/run_tests.sh`; it must report `failing=0`. Baseline: **248 successes across 20 spec files**. If the number of reporting spec files drops, something is wrong.
- Work directly on `master`.
- **Lua does not hoist `local`s.** `lua/intentdiff/init.lua` is one long chunk of locals; a function that calls another defined later in the file must use the file's existing forward-declaration pattern (see `local close_entry`, `local select_file`, `local auto_open_first`). This exact mistake has already cost one fix round in this repo.
- `PlenaryBustedFile` does NOT work here — plenary spawns a child nvim with `--noplugin` and no `-u`, so codediff is off the runtimepath. Use `tests/run_tests.sh`, or `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('<abs path>')"` for a faster loop.

---

### Task 1: The cursor opens file diffs

**Files:**
- Modify: `lua/intentdiff/init.lua` (`open_file`'s `on_ready`, `select_file`, `apply_hover`), `lua/intentdiff/config.lua`
- Test: `tests/hover_spec.lua`, `tests/config_spec.lua`

**Interfaces:**
- Consumes: existing `open_file(token, group_i, file_i, opts)`, `apply_hover(token)`, `entry.hover_key`.
- Produces: `open_file` accepts `opts.restore_focus` (return focus to the sidebar once ready). `entry.hover_key` for a file row is now `("f%d:%d"):format(group_i, file_i)` rather than the flat `"file"`. Task 2 builds on both.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hover_spec.lua` (reuse the file's existing `open_ready`, `line_of` and `hover` helpers):

```lua
describe("cursor opens files", function()
  local function file_rows(entry)
    local rows = {}
    for l = 1, vim.api.nvim_buf_line_count(entry.sidebar.bufnr) do
      local m = entry.sidebar.meta_at(l)
      if m and m.kind == "file" then
        rows[#rows + 1] = { lnum = l, group_i = m.group_i, file_i = m.file_i }
      end
    end
    return rows
  end

  it("renders the hovered file's diff and keeps focus in the sidebar", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
    local rows = file_rows(entry)
    assert.is_true(#rows >= 1)
    hover(entry, rows[1].lnum)

    local path = entry.model.groups[rows[1].group_i].files[rows[1].file_i].path
    assert.truthy(helpers.wait_for(function()
      local shown = require("intentdiff.view")._last_shown[tab]
      return shown and shown.file_entry.path == path or nil
    end, 10000), "hovered file was never rendered")
    assert.is_nil(require("intentdiff.view")._preview_active[tab])
    assert.equals(entry.sidebar.winid, vim.api.nvim_get_current_win())
  end)

  it("re-renders when the cursor moves to a different file row", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
    local rows = file_rows(entry)
    assert.is_true(#rows >= 2, "fixture must have two file rows")
    local function path_of(r)
      return entry.model.groups[r.group_i].files[r.file_i].path
    end
    assert.not_equals(path_of(rows[1]), path_of(rows[2]))

    hover(entry, rows[1].lnum)
    assert.truthy(helpers.wait_for(function()
      local s = require("intentdiff.view")._last_shown[tab]
      return s and s.file_entry.path == path_of(rows[1]) or nil
    end, 10000))

    hover(entry, rows[2].lnum)
    assert.truthy(helpers.wait_for(function()
      local s = require("intentdiff.view")._last_shown[tab]
      return s and s.file_entry.path == path_of(rows[2]) or nil
    end, 10000), "moving between file rows must re-render (per-file de-dupe key)")
  end)

  it("leaves the preview when moving from a group row to a file row", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
    hover(entry, line_of(entry, "group"))
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab]
    end, 10000))
    hover(entry, file_rows(entry)[1].lnum)
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab] == nil or nil
    end, 10000))
  end)

  it("restores instead of opening when hover_opens_files is false", function()
    local tab, entry = open_ready({
      preview = { enabled = true, debounce_ms = 10, hover_opens_files = false },
    })
    local before = require("intentdiff.view")._last_shown[tab]
    hover(entry, file_rows(entry)[1].lnum)
    vim.wait(400, function() return false end, 50)
    local after = require("intentdiff.view")._last_shown[tab]
    assert.equals(before and before.file_entry.path, after and after.file_entry.path)
  end)
end)
```

Append to `tests/config_spec.lua`:

```lua
describe("config navigation defaults", function()
  it("opens files on hover by default", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.is_true(config.options.preview.hover_opens_files)
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run(vim.fn.getcwd() .. '/tests/hover_spec.lua')"`
Expected: FAIL — the hovered file is never rendered; `_last_shown` keeps whatever was auto-opened.

- [ ] **Step 3: Add the config key**

In `lua/intentdiff/config.lua`, extend the `preview` table:

```lua
  -- hover_opens_files: moving the sidebar cursor onto a file row renders that
  -- file's diff, matching how group and directory rows already preview on the
  -- cursor. debounce_ms is what keeps this cheap — holding `j` through a large
  -- tree never settles, so it renders once, at rest. Set false to go back to
  -- restoring the last selection on a file row and requiring <CR> to open.
  preview = { enabled = true, debounce_ms = 120, max_lines = 20000, hover_opens_files = true },
```

- [ ] **Step 4: Teach `open_file` to restore focus**

In `lua/intentdiff/init.lua`, in `open_file`'s `on_ready`, replace the focus block:

```lua
      if opts and opts.auto and vim.api.nvim_tabpage_is_valid(tabpage)
          and current.sidebar and vim.api.nvim_win_is_valid(current.sidebar.winid) then
        vim.api.nvim_set_current_win(current.sidebar.winid)
      end
```

with:

```lua
      -- `auto` and `restore_focus` are deliberately separate flags. `auto`
      -- ALSO means "bail if the user has selected something" (see the guard
      -- above), and a hover-open sets user_selected itself — reusing `auto`
      -- for it would make every hover-open bail before rendering.
      if opts and (opts.auto or opts.restore_focus)
          and vim.api.nvim_tabpage_is_valid(tabpage)
          and current.sidebar and current.sidebar.winid
          and vim.api.nvim_win_is_valid(current.sidebar.winid) then
        vim.api.nvim_set_current_win(current.sidebar.winid)
      end
```

- [ ] **Step 5: Give a file row its own de-dupe key**

In `select_file`, replace `entry.hover_key = "file"` with:

```lua
    -- Per-file, matching apply_hover's key: a flat "file" key made every file
    -- row the same hover target, which was right when they all did the same
    -- thing and is wrong now that each renders its own diff.
    entry.hover_key = ("f%d:%d"):format(group_i, file_i)
```

- [ ] **Step 6: Open the hovered file**

In `apply_hover`, replace the key derivation for files:

```lua
  elseif m.kind == "file" then
    key = "file"
```

with:

```lua
  elseif m.kind == "file" then
    key = ("f%d:%d"):format(m.group_i, m.file_i)
```

and replace the file branch:

```lua
  if m.kind == "file" then
    -- Hovering a file row does NOT open that file: rendering every row the
    -- cursor passes over would re-run codediff's diff for each one. It just
    -- leaves the preview, restoring whatever the user last selected. <CR>
    -- still selects.
    view.restore(entry.sess)
    return
  end
```

with:

```lua
  if m.kind == "file" then
    if not require("intentdiff.config").options.preview.hover_opens_files then
      view.restore(entry.sess)
      return
    end
    -- Opening on the cursor marks the selection: a classification completing
    -- while the user browses must re-fold their current file in place
    -- (refold_shown_file), not yank them to the first group. Hovering a GROUP
    -- deliberately does not set this — rerender_preview handles that path.
    entry.user_selected = true
    open_file(token, m.group_i, m.file_i, { restore_focus = true })
    return
  end
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run(vim.fn.getcwd() .. '/tests/hover_spec.lua')"`
Then: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run(vim.fn.getcwd() .. '/tests/config_spec.lua')"`
Expected: PASS.

- [ ] **Step 8: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0`, 20 spec files reporting.

- [ ] **Step 9: Commit**

```bash
git add lua/intentdiff/init.lua lua/intentdiff/config.lua tests/hover_spec.lua tests/config_spec.lua
git commit -S -m "feat: the sidebar cursor opens file diffs"
```

---

### Task 2: `<CR>` opens and jumps into the diff

**Files:**
- Modify: `lua/intentdiff/init.lua` (`same_as_shown` position, `select_file`, `open_file`'s `on_ready`)
- Test: `tests/hover_spec.lua`

**Interfaces:**
- Consumes: `opts.restore_focus` and the per-file `hover_key` from Task 1; the existing `same_as_shown(tabpage, file_entry)`.
- Produces: `open_file` accepts `opts.focus_diff`. `select_file` short-circuits to a pure focus change when the requested file is already displayed.

**Ordering hazard:** `same_as_shown` is currently defined AFTER `select_file`, and this task makes `select_file` call it. Lua does not hoist locals. **Move the whole `same_as_shown` function definition (with its doc comment) to just above `select_file`** — it depends only on `require("intentdiff.view")`, so moving it is safe. Do not add a second forward declaration; move it.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hover_spec.lua`:

```lua
describe("<CR> jumps into the diff", function()
  local function first_file_row(entry)
    for l = 1, vim.api.nvim_buf_line_count(entry.sidebar.bufnr) do
      local m = entry.sidebar.meta_at(l)
      if m and m.kind == "file" then return l end
    end
  end

  local function press_cr(entry, lnum)
    vim.api.nvim_set_current_win(entry.sidebar.winid)
    vim.api.nvim_win_set_cursor(entry.sidebar.winid, { lnum, 0 })
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  end

  it("moves focus into the diff pane without re-rendering an already-shown file", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
    local lnum = first_file_row(entry)
    hover(entry, lnum)
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._last_shown[tab] ~= nil or nil
    end, 10000))
    local before = require("intentdiff.view").get_session(tab).modified_bufnr

    press_cr(entry, lnum)
    vim.wait(500, function() return false end, 50)

    local session = require("intentdiff.view").get_session(tab)
    assert.equals(before, session.modified_bufnr, "already-shown file must not re-render")
    assert.equals(session.modified_win, vim.api.nvim_get_current_win())
  end)

  it("renders and focuses a file that was not shown yet", function()
    local tab, entry = open_ready({
      preview = { enabled = true, debounce_ms = 10, hover_opens_files = false },
    })
    local lnum = first_file_row(entry)
    local m = entry.sidebar.meta_at(lnum)
    local path = entry.model.groups[m.group_i].files[m.file_i].path

    press_cr(entry, lnum)
    assert.truthy(helpers.wait_for(function()
      local s = require("intentdiff.view")._last_shown[tab]
      return s and s.file_entry.path == path or nil
    end, 10000))
    local session = require("intentdiff.view").get_session(tab)
    assert.equals(session.modified_win, vim.api.nvim_get_current_win())
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run(vim.fn.getcwd() .. '/tests/hover_spec.lua')"`
Expected: FAIL — focus stays in the sidebar after `<CR>`.

- [ ] **Step 3: Move `same_as_shown` above `select_file`**

Cut the entire `--- True when \`file_entry\`'s hunks are exactly …` doc comment and its `local function same_as_shown(tabpage, file_entry) … end` body, and paste it immediately above the `--- Manual (sidebar <CR>) or ]c/[c-driven selection.` comment that precedes `select_file`. Change nothing inside it.

- [ ] **Step 4: Add the focus helper and the short-circuit**

In `lua/intentdiff/init.lua`, add `focus_diff_pane` **above `open_file`** (both `select_file` and `open_file` call it, and `open_file` is defined first):

```lua
--- Move focus to the diff pane of `tabpage`. Prefers the modified side; falls
--- back to the original, which is the only populated side for a deleted file.
--- @return boolean whether focus moved
local function focus_diff_pane(tabpage)
  local session = require("intentdiff.view").get_session(tabpage)
  if not session then
    return false
  end
  -- Deliberately NOT `ipairs({ modified_win, original_win })`: ipairs stops at
  -- the first nil, and a deleted file populates only the original side. That
  -- exact nil-hole has already shipped twice in this codebase.
  local win = (session.modified_win and vim.api.nvim_win_is_valid(session.modified_win)
      and session.modified_win)
    or (session.original_win and vim.api.nvim_win_is_valid(session.original_win)
      and session.original_win)
  if not win then
    return false
  end
  vim.api.nvim_set_current_win(win)
  return true
end
```

Then replace `select_file`'s body:

```lua
select_file = function(token, group_i, file_i, opts)
  local entry = sessions[token]
  if entry then
    entry.user_selected = true
    entry.hover_key = ("f%d:%d"):format(group_i, file_i)
  end
  -- <CR> on the file the cursor already rendered is a pure focus change: the
  -- panes are already correct, so re-rendering would spend a codediff diff to
  -- produce identical output.
  if opts and opts.focus_diff and entry then
    local _, file_entry = group_file(entry.model, group_i, file_i)
    if file_entry and same_as_shown(entry.sess.tabpage, file_entry) then
      focus_diff_pane(entry.sess.tabpage)
      return
    end
  end
  open_file(token, group_i, file_i, opts)
end
```

- [ ] **Step 5: Focus the pane after a render**

In `open_file`'s `on_ready`, immediately before the `restore_focus` block added in Task 1, add:

```lua
      if opts and opts.focus_diff then
        focus_diff_pane(tabpage)
      end
```

`focus_diff_pane` is defined above `select_file`, which is above `open_file`'s use of it at call time — but `open_file` is defined BEFORE `select_file` in the file. Confirm `focus_diff_pane` is placed above `open_file` too; if not, move it there. It has no dependencies beyond `require`.

- [ ] **Step 6: Pass the flag from the sidebar**

In `M.open`'s `sidebar.create` call, change:

```lua
    on_select = function(gi, fi) select_file(token, gi, fi) end,
```

to:

```lua
    -- <CR> renders if needed and then moves focus INTO the diff, so the user
    -- can scroll and search it. The cursor alone renders in place and leaves
    -- focus in the sidebar for continued browsing.
    on_select = function(gi, fi) select_file(token, gi, fi, { focus_diff = true }) end,
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run(vim.fn.getcwd() .. '/tests/hover_spec.lua')"`
Expected: PASS.

- [ ] **Step 8: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0`. `tests/navigation_spec.lua` and `tests/integration_spec.lua` also drive `select_file`; if either fails, report it rather than editing the spec.

- [ ] **Step 9: Commit**

```bash
git add lua/intentdiff/init.lua tests/hover_spec.lua
git commit -S -m "feat: <CR> opens a file and moves focus into the diff pane"
```

---

### Task 3: Toggle all intents

**Files:**
- Modify: `lua/intentdiff/sidebar.lua` (keymap), `lua/intentdiff/init.lua` (`on_toggle_all`, `M.toggle_all`), `lua/intentdiff/config.lua` (`keymaps`), `plugin/intentdiff.lua`
- Test: `tests/sidebar_spec.lua`, `tests/config_spec.lua`

**Interfaces:**
- Consumes: `model.groups[i].collapsed`, `sidebar.create`'s callback table.
- Produces: `callbacks.on_toggle_all()`; `intentdiff.toggle_all(tabpage)`; `config.options.keymaps.toggle_all` (default `"zA"`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/sidebar_spec.lua`:

```lua
describe("sidebar toggle-all", function()
  it("invokes on_toggle_all from the configured key", function()
    require("intentdiff.config").setup({})
    local called = 0
    local handle = sidebar.create({
      on_select = function() end, on_toggle_group = function() end,
      on_toggle_dir = function() end, on_toggle_all = function() called = called + 1 end,
      on_reclassify = function() end, on_close = function() end,
      on_next_group = function() end, on_prev_group = function() end,
      on_goto_file = function() end,
    })
    handle.update(mk_model())
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("zA", true, false, true), "x", false)
    assert.equals(1, called)
    pcall(vim.api.nvim_win_close, handle.winid, true)
  end)
end)
```

Append to `tests/config_spec.lua`:

```lua
describe("config keymaps", function()
  it("defaults the two new sidebar keys", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.equals("zA", config.options.keymaps.toggle_all)
    assert.equals("<leader>gVt", config.options.keymaps.toggle_sidebar)
  end)

  it("lets a keymap be disabled with false", function()
    local config = require("intentdiff.config")
    config.setup({ keymaps = { toggle_all = false } })
    assert.is_false(config.options.keymaps.toggle_all)
  end)
end)
```

Append to `tests/integration_spec.lua`:

```lua
  it("toggles every intent collapsed and back, keeping directory state", function()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      log_file = vim.fn.tempname() .. "/l.log",
      provider = fake_provider({
        { title = "First", ids = "1" },
        { title = "Second", ids = "2-99" },
      }),
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local entry = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model and s.model.state == "ready" and s or nil
    end, 15000)
    assert.truthy(entry)
    assert.is_true(#entry.model.groups >= 2)

    entry.model.groups[1].collapsed_dirs = { ["src"] = true }

    require("intentdiff").toggle_all(tab)
    for _, g in ipairs(entry.model.groups) do
      assert.is_true(g.collapsed, "every intent must collapse")
    end

    require("intentdiff").toggle_all(tab)
    for _, g in ipairs(entry.model.groups) do
      assert.is_falsy(g.collapsed, "every intent must expand again")
    end
    assert.is_true(entry.model.groups[1].collapsed_dirs["src"],
      "per-directory state must survive the round trip")
  end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run(vim.fn.getcwd() .. '/tests/config_spec.lua')"`
Expected: FAIL — `config.options.keymaps` is nil.

- [ ] **Step 3: Add the config block**

In `lua/intentdiff/config.lua`:

```lua
  -- Buffer-local keys the plugin installs inside a review tab. Set any of them
  -- to false to install nothing, exactly as the plugin already handles
  -- codediff's toggle_layout key being disabled.
  keymaps = {
    toggle_sidebar = "<leader>gVt", -- installed on the sidebar AND the diff panes
    toggle_all = "zA",              -- sidebar only
  },
```

- [ ] **Step 4: Wire the sidebar key**

In `lua/intentdiff/sidebar.lua`'s `M.create`, after the existing `za`/`h`/`l` loop:

```lua
  local keys = require("intentdiff.config").options.keymaps or {}
  if keys.toggle_all then
    map(keys.toggle_all, function()
      callbacks.on_toggle_all()
    end)
  end
```

- [ ] **Step 5: Implement the toggle**

The logic lives in ONE place — the public entry point — and the sidebar callback delegates to it. Add next to `M.close` in `lua/intentdiff/init.lua`:

```lua
--- :IntentDiffToggleAll and the toggle_all key — collapse every intent, or
--- expand every intent.
---
--- Any expanded intent ⇒ collapse everything; otherwise expand everything.
--- Per-directory state (g.collapsed_dirs) is deliberately untouched, so
--- re-expanding restores the tree the user had arranged.
function M.toggle_all(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = M._session(tabpage)
  if not (entry and entry.model and entry.model.groups) then
    return
  end
  local any_expanded = false
  for _, g in ipairs(entry.model.groups) do
    if not g.collapsed then
      any_expanded = true
      break
    end
  end
  for _, g in ipairs(entry.model.groups) do
    g.collapsed = any_expanded or nil
  end
  entry.sidebar.update(entry.model)
end
```

Then add the delegating callback to the `sidebar.create` table:

```lua
    on_toggle_all = function()
      local entry = sessions[token]
      if entry then
        M.toggle_all(entry.sess.tabpage)
      end
    end,
```

- [ ] **Step 6: Add the command**

In `plugin/intentdiff.lua`:

```lua
vim.api.nvim_create_user_command("IntentDiffToggleAll", function()
  require("intentdiff").toggle_all()
end, { desc = "Collapse or expand every intent in the sidebar" })
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `tests/run_tests.sh`
Expected: `failing=0`.

- [ ] **Step 8: Commit**

```bash
git add lua/intentdiff/sidebar.lua lua/intentdiff/init.lua lua/intentdiff/config.lua plugin/intentdiff.lua tests/
git commit -S -m "feat: toggle every intent collapsed or expanded"
```

---

### Task 4: Show/hide the sidebar

**Files:**
- Modify: `lua/intentdiff/sidebar.lua` (`bufhidden`, `hide`/`show`, toggle key), `lua/intentdiff/init.lua` (`M.toggle_sidebar`, `forget_entry` buffer delete, `winid` guards), `lua/intentdiff/view.lua` (toggle key on the diff panes), `plugin/intentdiff.lua`
- Test: `tests/sidebar_toggle_spec.lua` (create)

**Interfaces:**
- Consumes: `config.options.keymaps.toggle_sidebar` from Task 3.
- Produces: `handle.hide()`, `handle.show(model)`, `handle.visible`; `intentdiff.toggle_sidebar(tabpage)`.

**The trap.** The sidebar buffer is `bufhidden = "wipe"`, so closing its window DESTROYS the buffer — the failure that broke the sidebar during the original build. This task changes it to `"hide"`, which means nothing reclaims it any more: `forget_entry` must delete it explicitly or the plugin leaks one buffer per review session. Both halves are required; neither is optional.

- [ ] **Step 1: Write the failing tests**

Create `tests/sidebar_toggle_spec.lua`:

```lua
local helpers = require("tests.helpers")

describe("sidebar show/hide", function()
  local repo

  local function fake_provider(groups)
    return function(_, cb)
      vim.schedule(function() cb({ groups = groups }) end)
      return { cancel = function() end }
    end
  end

  before_each(function()
    repo = helpers.make_repo({
      ["src/a.lua"] = table.concat(vim.fn.range(1, 40), "\n"),
      ["b.lua"] = "x",
    })
    helpers.write_file(repo, "src/a.lua",
      "CHANGED\n" .. table.concat(vim.fn.range(2, 39), "\n") .. "\nCHANGED")
    helpers.write_file(repo, "b.lua", "y")
    vim.cmd("cd " .. repo)
  end)

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      pcall(vim.cmd, "tabclose $")
    end
  end)

  local function open_ready()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      log_file = vim.fn.tempname() .. "/l.log",
      provider = fake_provider({ { title = "Everything", ids = "1-99" } }),
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local entry = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model and s.model.state == "ready" and s or nil
    end, 15000)
    assert.truthy(entry, "session never became ready")
    return tab, entry
  end

  it("hides and shows without disturbing the diff panes", function()
    local tab, entry = open_ready()
    helpers.wait_for(function()
      return require("intentdiff.view")._last_shown[tab] ~= nil or nil
    end, 10000)
    local session = require("intentdiff.view").get_session(tab)
    local orig_buf, mod_buf = session.original_bufnr, session.modified_bufnr
    local bufnr = entry.sidebar.bufnr

    require("intentdiff").toggle_sidebar(tab)
    assert.is_false(entry.sidebar.visible)
    assert.is_true(vim.api.nvim_buf_is_valid(bufnr), "buffer must survive hiding")

    require("intentdiff").toggle_sidebar(tab)
    assert.is_true(entry.sidebar.visible)
    assert.is_true(vim.api.nvim_win_is_valid(entry.sidebar.winid))
    assert.equals(bufnr, vim.api.nvim_win_get_buf(entry.sidebar.winid))

    local after = require("intentdiff.view").get_session(tab)
    assert.equals(orig_buf, after.original_bufnr, "diff panes must survive a hide/show cycle")
    assert.equals(mod_buf, after.modified_bufnr)
  end)

  it("re-renders the current model after showing", function()
    local tab, entry = open_ready()
    local before = vim.api.nvim_buf_get_lines(entry.sidebar.bufnr, 0, -1, false)
    require("intentdiff").toggle_sidebar(tab)
    require("intentdiff").toggle_sidebar(tab)
    local after = vim.api.nvim_buf_get_lines(entry.sidebar.bufnr, 0, -1, false)
    assert.same(before, after)
  end)

  it("survives group navigation while hidden", function()
    local tab, entry = open_ready()
    require("intentdiff").toggle_sidebar(tab)
    -- these read the sidebar cursor; with the sidebar hidden they must no-op
    assert.has_no.errors(function()
      require("intentdiff").toggle_all(tab)
    end)
    require("intentdiff").toggle_sidebar(tab)
    assert.is_true(entry.sidebar.visible)
  end)

  it("deletes the sidebar buffer when the session closes", function()
    local tab, entry = open_ready()
    local bufnr = entry.sidebar.bufnr
    require("intentdiff").close(tab)
    vim.wait(500, function() return not vim.api.nvim_buf_is_valid(bufnr) end, 20)
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr),
      "bufhidden is no longer 'wipe' — the session must delete its own buffer")
  end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run(vim.fn.getcwd() .. '/tests/sidebar_toggle_spec.lua')"`
Expected: FAIL — `attempt to call field 'toggle_sidebar' (a nil value)`.

- [ ] **Step 3: Make the sidebar hideable**

In `lua/intentdiff/sidebar.lua`'s `M.create`, restructure so the buffer setup and the window options are reusable. Change `bufhidden`:

```lua
  vim.bo[bufnr].bufhidden = "hide" -- survives hiding; init.lua's forget_entry deletes it
```

Extract the window-option application into a local used by both `create` and `show`:

```lua
  local function apply_win_opts(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].winfixwidth = true
    vim.wo[win].wrap = false
  end
```

and call it where those four lines were. Add `handle.visible = true` next to `handle.winid`, then after `handle.update` add:

```lua
  --- Close the sidebar window, keeping the buffer (and therefore the model,
  --- the meta table and every keymap) intact. Refuses to close the last window
  --- in the tab, which would take the review tab with it.
  function handle.hide()
    if not handle.visible then
      return false
    end
    if handle.winid and vim.api.nvim_win_is_valid(handle.winid) then
      local tabpage = vim.api.nvim_win_get_tabpage(handle.winid)
      if #vim.api.nvim_tabpage_list_wins(tabpage) <= 1 then
        return false
      end
      pcall(vim.api.nvim_win_close, handle.winid, true)
    end
    handle.winid = nil
    handle.visible = false
    return true
  end

  --- Re-open the sidebar window with the same buffer and re-render `model`.
  function handle.show(model)
    if handle.visible and handle.winid and vim.api.nvim_win_is_valid(handle.winid) then
      return false
    end
    if not vim.api.nvim_buf_is_valid(handle.bufnr) then
      return false -- caller degrades; the session is being torn down
    end
    vim.cmd("topleft " .. width .. "vsplit")
    handle.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(handle.winid, handle.bufnr)
    apply_win_opts(handle.winid)
    handle.visible = true
    if model then
      handle.update(model)
    end
    return true
  end
```

Then install the toggle key on the sidebar buffer, after the `toggle_all` mapping:

```lua
  if keys.toggle_sidebar then
    map(keys.toggle_sidebar, function()
      callbacks.on_toggle_sidebar()
    end)
  end
```

`cursor_meta` reads `handle.winid`; guard it:

```lua
  local function cursor_meta()
    if not (handle.winid and vim.api.nvim_win_is_valid(handle.winid)) then
      return {}
    end
    return handle.meta_at(vim.api.nvim_win_get_cursor(handle.winid)[1]) or {}
  end
```

- [ ] **Step 4: Guard every `winid` reader in `init.lua`**

`on_next_group` and `on_prev_group` read `vim.api.nvim_win_get_cursor(entry.sidebar.winid)` unguarded and throw when the sidebar is hidden. Add to both, immediately after fetching `entry`:

```lua
      if not (entry and entry.sidebar.winid
          and vim.api.nvim_win_is_valid(entry.sidebar.winid)) then
        return
      end
```

`apply_hover` already guards; leave it.

- [ ] **Step 5: Add the toggle entry point and the callback**

In `lua/intentdiff/init.lua`, next to `M.toggle_all`:

```lua
--- :IntentDiffSidebar / the toggle_sidebar key — show or hide the sidebar.
--- Hiding keeps the buffer and the session; only the window goes away.
function M.toggle_sidebar(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = M._session(tabpage)
  if not (entry and entry.sidebar) then
    return
  end
  if entry.sidebar.visible then
    entry.sidebar.hide()
  else
    entry.sidebar.show(entry.model)
  end
end
```

Add to the `sidebar.create` callback table:

```lua
    on_toggle_sidebar = function()
      local entry = sessions[token]
      if entry then
        M.toggle_sidebar(entry.sess.tabpage)
      end
    end,
```

- [ ] **Step 6: Delete the buffer on teardown**

In `forget_entry`, after `require("intentdiff.navigation").detach(entry.sess.tabpage)`:

```lua
  -- The sidebar buffer is bufhidden="hide" so it can survive being hidden;
  -- nothing reclaims it automatically, so the session that created it owns
  -- deleting it. Without this the plugin leaks one buffer per review.
  if entry.sidebar and entry.sidebar.bufnr
      and vim.api.nvim_buf_is_valid(entry.sidebar.bufnr) then
    pcall(vim.api.nvim_buf_delete, entry.sidebar.bufnr, { force = true })
  end
```

- [ ] **Step 7: Carry the key to the diff panes**

In `lua/intentdiff/view.lua`, in `M.install_keymaps`, after the existing toggle-layout mapping, and in `M.install_preview_keymaps` after its `q` mapping, add the same block:

```lua
      local sidebar_key = require("intentdiff.config").options.keymaps
        and require("intentdiff.config").options.keymaps.toggle_sidebar
      if sidebar_key then
        pcall(vim.keymap.set, "n", sidebar_key, function()
          require("intentdiff").toggle_sidebar(tabpage)
        end, { buffer = buf, nowait = true, desc = "intent-diff: show/hide the sidebar" })
      end
```

This must live on the pane buffers: a sidebar-local key is unreachable when the sidebar is hidden.

- [ ] **Step 8: Add the command**

In `plugin/intentdiff.lua`:

```lua
vim.api.nvim_create_user_command("IntentDiffSidebar", function()
  require("intentdiff").toggle_sidebar()
end, { desc = "Show or hide the intent-diff sidebar" })
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run(vim.fn.getcwd() .. '/tests/sidebar_toggle_spec.lua')"`
Expected: PASS.

- [ ] **Step 10: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0`, 21 spec files reporting.

- [ ] **Step 11: Commit**

```bash
git add lua/intentdiff/sidebar.lua lua/intentdiff/init.lua lua/intentdiff/view.lua plugin/intentdiff.lua tests/sidebar_toggle_spec.lua
git commit -S -m "feat: show/hide the sidebar"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md`

**Interfaces:** consumes everything from Tasks 1-4; produces nothing.

- [ ] **Step 1: Verify every claim against the code before writing**

Read `lua/intentdiff/config.lua`, `lua/intentdiff/sidebar.lua`, `lua/intentdiff/init.lua` (`apply_hover`, `select_file`, `M.toggle_all`, `M.toggle_sidebar`) and `plugin/intentdiff.lua`. Document what the code does, not what this plan says it should do. Where they differ, document the code and report it.

- [ ] **Step 2: Update the config table**

Add rows with real defaults read from `config.lua`:

| Option | Default | Meaning |
|---|---|---|
| `preview.hover_opens_files` | `true` | Moving the sidebar cursor onto a file row renders that file's diff. |
| `keymaps.toggle_sidebar` | `"<leader>gVt"` | Show/hide the sidebar; installed on the sidebar and the diff panes. `false` installs nothing. |
| `keymaps.toggle_all` | `"zA"` | Collapse or expand every intent. Sidebar only. `false` installs nothing. |

- [ ] **Step 3: Rewrite the navigation description**

State plainly that the cursor drives everything: a group row previews the whole intent, a directory row previews its subtree, a file row renders that file's diff — and that `<CR>` on a file row does the same but moves focus into the diff pane so it can be scrolled and searched. Correct any existing text that says hovering a file row does not open it.

- [ ] **Step 4: Document the two new actions and commands**

`zA` toggles every intent (per-directory state is preserved). `<leader>gVt` shows/hides the sidebar and works from the diff panes too, since a sidebar key is unreachable while it is hidden. Add `:IntentDiffToggleAll` and `:IntentDiffSidebar` to the commands list.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0` — documentation must not change behaviour.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -S -m "docs: cursor-driven navigation, sidebar toggle and intent toggle"
```

---

## Self-review notes

**Spec coverage.** Spec §1 → Task 1. §2 → Task 2. §3 → Task 3. §4 → Task 4. §5 (config) → Tasks 1 and 3, documented in Task 5. §6 (error handling) → the `hide`/`show` no-op guards and the invalid-buffer degrade in Task 4 Step 3, the `winid` guards in Task 4 Step 4, the disabled-keymap branches in Tasks 3 and 4, the empty-groups guard in Task 3, and `focus_diff_pane` returning false in Task 2. §7 (testing) → the spec's list maps onto the specs in Tasks 1-4.

**Ordering hazards flagged explicitly** (Lua does not hoist locals): `same_as_shown` must move above `select_file` (Task 2 Step 3), and `focus_diff_pane` must sit above `open_file` (Task 2 Step 5).

**Nil-hole flagged explicitly**: `focus_diff_pane` must not use `ipairs` over a table literal whose first element can be nil (Task 2 Step 4) — the same defect has shipped twice in this codebase.

**Interface consistency.** `opts.restore_focus` (Task 1) and `opts.focus_diff` (Task 2) are distinct from the pre-existing `opts.auto` and `opts.jump`; all four are read in the same `on_ready`. The file `hover_key` format `("f%d:%d")` is written identically in `apply_hover` (Task 1 Step 6) and `select_file` (Task 1 Step 5, Task 2 Step 4). `config.options.keymaps` is created in Task 3 and consumed in Task 4, so Task 4 must not re-add it.
