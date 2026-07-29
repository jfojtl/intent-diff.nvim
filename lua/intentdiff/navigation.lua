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

--- Install per-tabpage state and buffer-local ]c/[c on the diff pane buffers.
function M.attach(tabpage, ctx)
  state[tabpage] = ctx
  for _, win in ipairs(require("intentdiff.view").diff_wins(tabpage)) do
    local buf = vim.api.nvim_win_get_buf(win)
    vim.keymap.set("n", "]c", function() M.next_hunk(tabpage) end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "[c", function() M.prev_hunk(tabpage) end, { buffer = buf, nowait = true })
  end
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

return M
