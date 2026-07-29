-- The ONLY module allowed to require codediff internals. Everything is
-- pcall-guarded; on any mismatch the plugin degrades instead of erroring.
local M = {}

M.available = false
local cd = {} -- loaded codediff modules

local function try(name)
  local ok, mod = pcall(require, name)
  return ok and mod or nil
end

--- Load and verify codediff internals. Call once at :IntentDiff time.
function M.load()
  cd.view = try("codediff.ui.view")
  cd.compact = try("codediff.ui.view.compact")
  cd.lifecycle = try("codediff.ui.lifecycle")
  cd.git = try("codediff.core.git")
  cd.path = try("codediff.core.path")
  cd.side_by_side = try("codediff.ui.view.side_by_side")
  M.available = cd.view ~= nil
    and type(cd.view.create) == "function"
    and type(cd.view.update) == "function"
    and type(cd.view.toggle_layout) == "function"
    and cd.compact ~= nil
    and type(cd.compact.compute_visible_lines) == "function"
    and cd.lifecycle ~= nil
    and type(cd.lifecycle.get_session) == "function"
    and cd.git ~= nil
    and cd.path ~= nil
    and type(cd.path.make_ref) == "function"
    and type(cd.path.empty) == "function"
    and cd.side_by_side ~= nil
    and type(cd.side_by_side.show_untracked_file) == "function"
    and type(cd.side_by_side.show_added_virtual_file) == "function"
    and type(cd.side_by_side.show_deleted_virtual_file) == "function"
  if not M.available then
    vim.notify("intent-diff: codediff API mismatch — grouped view disabled", vim.log.levels.ERROR)
  end
  return M.available
end

function M.git()
  return cd.git
end

-- ---------------------------------------------------------------- folds ----

local visible_by_win = {}

--- Hunks currently applied per tabpage via M.apply_group_folds, so the
--- TabEnter handler below can re-assert them. Set on success in
--- apply_group_folds, cleared in M.close_tab.
M._active_folds = {}

local folds_augroup

--- codediff's own session TabEnter autocmd (codediff/ui/lifecycle/session.lua)
--- calls `vim.schedule(reapply_keymaps)`, which ends by calling
--- `compact.refresh(tabpage)` — when the user has `diff.compact = true` this
--- re-applies codediff's *all-hunks* compact fold, clobbering our
--- group-filtered foldexpr/visible lines. Re-assert our folds after that runs.
---
--- We can't rely on autocmd registration order alone to guarantee we run
--- after codediff's handler (a later :IntentDiff session could register
--- codediff's per-tab TabEnter autocmd after this augroup already exists), so
--- we defer two ticks (nested vim.schedule): codediff's handler's own
--- vim.schedule callback always lands on the first tick after TabEnter fires,
--- so scheduling ours from within a first-tick callback guarantees ours runs
--- on a later tick, deterministically after.
local function ensure_folds_augroup()
  if folds_augroup then
    return
  end
  folds_augroup = vim.api.nvim_create_augroup("IntentDiffFolds", { clear = true })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = folds_augroup,
    callback = function()
      local tab = vim.api.nvim_get_current_tabpage()
      if not M._active_folds[tab] then
        return -- inert for tabs without active group folds
      end
      vim.schedule(function()
        vim.schedule(function()
          if vim.api.nvim_get_current_tabpage() == tab and M._active_folds[tab] then
            M.apply_group_folds(tab, M._active_folds[tab])
          end
        end)
      end)
    end,
  })
end

function M.foldexpr()
  local visible = visible_by_win[vim.api.nvim_get_current_win()]
  if not visible then
    return "0"
  end
  return visible[vim.v.lnum] and "0" or "1"
end

local function context_lines()
  local ours = require("intentdiff.config").options.context_lines
  if ours then
    return ours
  end
  local cd_config = try("codediff.config")
  return cd_config and cd_config.options.diff.compact_context_lines or 3
end

--- Fold everything except `hunks`' ranges (+context) in both panes.
function M.apply_group_folds(tabpage, hunks)
  ensure_folds_augroup()
  local session = cd.lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end
  local changes = {}
  for i, h in ipairs(hunks) do
    changes[i] = { original = h.original, modified = h.modified }
  end
  local ctx = context_lines()
  local panes = {
    { win = session.original_win, buf = session.original_bufnr, side = "original" },
    { win = session.modified_win, buf = session.modified_bufnr, side = "modified" },
  }
  for _, pane in ipairs(panes) do
    if pane.win and vim.api.nvim_win_is_valid(pane.win)
        and pane.buf and vim.api.nvim_buf_is_valid(pane.buf) then
      local line_count = vim.api.nvim_buf_line_count(pane.buf)
      visible_by_win[pane.win] =
        cd.compact.compute_visible_lines(changes, pane.side, line_count, ctx)
      vim.wo[pane.win].foldmethod = "expr"
      vim.wo[pane.win].foldexpr = "v:lua.require'intentdiff.view'.foldexpr()"
      vim.wo[pane.win].foldlevel = 0
      vim.wo[pane.win].foldminlines = 0
      vim.wo[pane.win].foldenable = true
    end
  end
  M._active_folds[tabpage] = hunks
  return true
end

-- ----------------------------------------------------------- view driving --

--- Poll until codediff has the diff for `abs_path` ready in `tabpage`.
local function when_diff_ready(tabpage, abs_path, cb, tries)
  tries = tries or 0
  local session = cd.lifecycle.get_session(tabpage)
  if session and session.stored_diff_result
      and ((session.modified and session.modified.absolute == abs_path)
        or (session.original and session.original.absolute == abs_path)) then
    return cb()
  end
  if tries > 60 then
    return -- give up after ~3s; folds simply not applied
  end
  vim.defer_fn(function()
    when_diff_ready(tabpage, abs_path, cb, tries + 1)
  end, 50)
end

function M.open_tab()
  vim.cmd("tabnew")
  return vim.api.nvim_get_current_tabpage()
end

function M.close_tab(sess)
  M._active_folds[sess.tabpage] = nil
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab == sess.tabpage then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose")
      return
    end
  end
end

--- codediff.ui.view.create() always opens its own tab (`tabnew`) rather than
--- rendering into the current one, so any placeholder tab we pre-opened (e.g.
--- via M.open_tab()) is left behind as an empty stray. Run `fn` (expected to
--- call cd.view.create and land on the tab it created), then fold the
--- placeholder away and report the tab codediff actually used.
local function create_reconciling_tab(placeholder_tab, fn)
  fn()
  local actual_tab = vim.api.nvim_get_current_tabpage()
  if placeholder_tab and placeholder_tab ~= actual_tab
      and vim.api.nvim_tabpage_is_valid(placeholder_tab) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(placeholder_tab)) do
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  return actual_tab
end

--- Render the whole-file pane for a "??"/"A"/"D" status. Requires an
--- already-registered codediff session for `tabpage` (show_single_file
--- no-ops otherwise) — see the placeholder bootstrap in M.show_file.
local function show_whole_file(tabpage, sess, file_entry, abs_path)
  if file_entry.status == "??" then
    cd.side_by_side.show_untracked_file(tabpage, abs_path)
  elseif file_entry.status == "A" then
    cd.side_by_side.show_added_virtual_file(
      tabpage, sess.git_root, file_entry.path, sess.target_revision or "WORKING")
  elseif file_entry.status == "D" then
    cd.side_by_side.show_deleted_virtual_file(tabpage, sess.git_root, file_entry.path, sess.base_revision)
  end
end

--- codediff's show_added_virtual_file/show_deleted_virtual_file load their
--- buffer from a `codediff://` virtual URL: `show_single_file` returns as
--- soon as the buffer is registered in the session, but its *content* is
--- fetched asynchronously (codediff.core.git.get_file_content -> vim.schedule)
--- by codediff.core.virtual_file, which then fires
--- `User CodeDiffVirtualFileLoaded` with `data = { buf = <the buffer> }`.
--- Wait for that event (scoped to the buffer this show_file call actually
--- populated) before calling on_ready, so callers never observe an empty
--- buffer. Falls back to polling in case the event is ever missed.
local function wait_for_virtual_file(tabpage, status, on_ready)
  if not on_ready then
    return
  end
  local session = cd.lifecycle.get_session(tabpage)
  local buf = session and (status == "A" and session.modified_bufnr or session.original_bufnr)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.schedule(on_ready)
    return
  end

  local done = false
  local group = vim.api.nvim_create_augroup("IntentDiffVirtualFileWait_" .. buf, { clear = true })

  local function finish()
    if done then
      return
    end
    done = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    on_ready()
  end

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffVirtualFileLoaded",
    callback = function(event)
      if event.data and event.data.buf == buf then
        finish()
      end
    end,
  })

  local function poll(tries)
    if done then
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      finish()
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local has_content = #lines > 1 or (lines[1] ~= nil and lines[1] ~= "")
    if has_content or tries >= 60 then
      finish()
      return
    end
    vim.defer_fn(function()
      poll(tries + 1)
    end, 50)
  end
  vim.defer_fn(function()
    poll(1)
  end, 50)
end

--- Render file_entry's diff and fold to its hunks.
--- sess = { tabpage, git_root, base_revision, target_revision, view_created }
function M.show_file(sess, file_entry, opts)
  opts = opts or {}
  local tabpage = sess.tabpage
  local abs_path = sess.git_root .. "/" .. file_entry.path

  -- Whole-file statuses: the entire file is the change — no folds needed.
  if file_entry.status == "??" or file_entry.status == "A" or file_entry.status == "D" then
    if not sess.view_created then
      sess.view_created = true
      -- codediff's show_*_file helpers require an existing session (they
      -- no-op otherwise); mirror codediff's own explorer bootstrap by
      -- creating an empty-path placeholder session first (synchronous),
      -- then converting it to the single-pane view.
      sess.tabpage = create_reconciling_tab(tabpage, function()
        cd.view.create({
          mode = "explorer",
          git_root = sess.git_root,
          original = cd.path.empty(),
          modified = cd.path.empty(),
        }, nil, nil)
        show_whole_file(vim.api.nvim_get_current_tabpage(), sess, file_entry, abs_path)
      end)
    else
      show_whole_file(sess.tabpage, sess, file_entry, abs_path)
    end
    if file_entry.status == "??" then
      -- Real file, loaded synchronously by show_untracked_file.
      if opts.on_ready then vim.schedule(opts.on_ready) end
    else
      -- "A"/"D": virtual file, content arrives asynchronously.
      wait_for_virtual_file(sess.tabpage, file_entry.status, opts.on_ready)
    end
    return
  end

  ---@type table SessionConfig (codediff)
  local session_config = {
    mode = "explorer",
    git_root = sess.git_root,
    original = cd.path.make_ref(file_entry.old_path or file_entry.path, sess.git_root),
    modified = cd.path.make_ref(file_entry.path, sess.git_root),
    original_revision = sess.base_revision,
    modified_revision = sess.target_revision or "WORKING",
  }
  if not sess.view_created then
    sess.view_created = true
    sess.tabpage = create_reconciling_tab(tabpage, function()
      cd.view.create(session_config, nil, nil)
    end)
  else
    cd.view.update(sess.tabpage, session_config, false)
  end
  when_diff_ready(sess.tabpage, abs_path, function()
    M.apply_group_folds(sess.tabpage, file_entry.hunks)
    if opts.on_ready then
      opts.on_ready()
    end
  end)
end

--- Toggle inline/side-by-side, then re-apply the group filter.
function M.toggle_layout(sess, current_hunks)
  cd.view.toggle_layout(sess.tabpage)
  vim.defer_fn(function()
    M.apply_group_folds(sess.tabpage, current_hunks or {})
  end, 100)
end

--- Windows of the current diff panes (for keymap installation).
function M.diff_wins(tabpage)
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return {}
  end
  local wins = {}
  for _, w in ipairs({ session.original_win, session.modified_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      wins[#wins + 1] = w
    end
  end
  return wins
end

function M.get_session(tabpage)
  return cd.lifecycle.get_session(tabpage)
end

return M
