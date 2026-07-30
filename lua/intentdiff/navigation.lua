local M = {}

local state = {} -- [tabpage] = ctx

--- Decide the next move within a group. Pure.
--- @param file_entries table[] group.files
--- @param file_i integer current file index
--- @param cursor_line integer cursor line in the triggering pane
--- @param dir 1|-1
--- @param side "original"|"modified"|nil which side's line numbers to compare against (default "modified")
--- @return { line: integer }|{ file_i: integer, jump: "first"|"last" }|nil
function M.plan_move(file_entries, file_i, cursor_line, dir, side)
  side = side or "modified"
  local hunks = file_entries[file_i].hunks
  if dir == 1 then
    for _, h in ipairs(hunks) do
      if h[side].start_line > cursor_line then
        return { line = h[side].start_line }
      end
    end
    if file_entries[file_i + 1] then
      return { file_i = file_i + 1, jump = "first" }
    end
  else
    for i = #hunks, 1, -1 do
      if hunks[i][side].start_line < cursor_line then
        return { line = hunks[i][side].start_line }
      end
    end
    if file_i > 1 then
      return { file_i = file_i - 1, jump = "last" }
    end
  end
  return nil
end

local function move(tabpage, dir)
  local ctx = state[tabpage]
  if not ctx then
    return
  end
  local group = ctx.model.groups[ctx.group_i]
  if not group then
    return
  end
  local session = require("intentdiff.view").get_session(tabpage)
  if not session then
    return
  end
  local cur_win = vim.api.nvim_get_current_win()
  local side, win
  if cur_win == session.original_win then
    side, win = "original", session.original_win
  else
    side, win = "modified", session.modified_win
  end
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  local plan = M.plan_move(group.files, ctx.file_i, cursor_line, dir, side)
  if not plan then
    return
  end
  if plan.line then
    if cur_win ~= win then
      vim.api.nvim_set_current_win(win)
    end
    vim.api.nvim_win_set_cursor(win, { plan.line, 0 })
  else
    ctx.file_i = plan.file_i
    ctx.select_file(ctx.group_i, plan.file_i, { jump = plan.jump })
  end
end

function M.next_hunk(tabpage)
  move(tabpage or vim.api.nvim_get_current_tabpage(), 1)
end

function M.prev_hunk(tabpage)
  move(tabpage or vim.api.nvim_get_current_tabpage(), -1)
end

local function install_keymaps(tabpage)
  for _, win in ipairs(require("intentdiff.view").diff_wins(tabpage)) do
    local buf = vim.api.nvim_win_get_buf(win)
    vim.keymap.set("n", "]c", function() M.next_hunk(tabpage) end,
      { buffer = buf, nowait = true, desc = "intent-diff: next hunk in group" })
    vim.keymap.set("n", "[c", function() M.prev_hunk(tabpage) end,
      { buffer = buf, nowait = true, desc = "intent-diff: previous hunk in group" })
  end
end

--- Install per-tabpage state and buffer-local ]c/[c on the diff pane buffers.
function M.attach(tabpage, ctx)
  state[tabpage] = ctx
  install_keymaps(tabpage)
end

--- Reinstall ]c/[c for an already-attached tabpage, keeping its stored ctx.
---
--- codediff deletes the group-scoped maps from the pane buffers on TabLeave
--- (ui/lifecycle/accessors.lua clear_tab_keymaps deletes every lhs in its
--- keymaps.view table, whoever set it) and reinstalls its own all-hunks
--- versions on TabEnter. intentdiff.view's TabEnter re-assert calls this so
--- ]c/[c stay group-scoped across tab switches. Inert when the tabpage has no
--- attached state.
function M.reattach_keymaps(tabpage)
  if not state[tabpage] then
    return false
  end
  install_keymaps(tabpage)
  return true
end

function M.detach(tabpage)
  state[tabpage] = nil
end

--- Update current position without reinstalling keymaps.
function M.set_position(tabpage, group_i, file_i)
  local ctx = state[tabpage]
  if ctx then
    ctx.group_i, ctx.file_i = group_i, file_i
  end
end

--- Resync an attached ctx to a freshly-classified model. Without this, a
--- reclassify (or the initial classify finishing after the user has already
--- navigated) leaves ctx.model pointing at stale group/file data while
--- ctx.group_i/ctx.file_i still index into it — ]c/[c would then read from a
--- model no longer shown anywhere. No-op if `tabpage` has no attached state.
function M.update_model(tabpage, model)
  local ctx = state[tabpage]
  if not ctx then
    return
  end
  ctx.model = model
  local groups = model.groups or {}
  if #groups == 0 or ctx.group_i < 1 or ctx.group_i > #groups then
    ctx.group_i, ctx.file_i = 1, 1
    return
  end
  local files = groups[ctx.group_i].files or {}
  if #files == 0 or ctx.file_i < 1 or ctx.file_i > #files then
    ctx.file_i = 1
  end
end

return M
