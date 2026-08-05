-- Puts a render plan into buffers. The impure half of the renderer: plan.lua
-- decides what the panes contain, this decides nothing and only draws it.
local M = {}

M.ns = vim.api.nvim_create_namespace("intentdiff_render")

--- Per-window visible-row sets, read by M.foldexpr.
local folded_by_win = {}

--- Fold expression: 1 inside a fold range, 0 outside. Registered per window by
--- M.render. Reads a per-window set rather than the plan so a recycled window
--- id can never answer with a stale plan's ranges.
function M.foldexpr()
  local win = vim.api.nvim_get_current_win()
  local set = folded_by_win[win]
  if not set then
    return "0"
  end
  return set[vim.v.lnum] and "1" or "0"
end

--- A fresh scratch buffer holding `pane`.
---
--- bufhidden is deliberately "hide", not "wipe": a window may still be being
--- swapped off this buffer when the next generation arrives, and "wipe" would
--- delete it mid-swap, leaving a caller reading an already-invalid buffer id.
--- M.retire cleans up afterwards instead.
local function pane_buf(pane)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, pane.lines)
  vim.bo[buf].modifiable = false
  for _, s in ipairs(pane.spans) do
    if s.col_end == -1 then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, s.line - 1, 0,
        { line_hl_group = s.hl })
    else
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, s.line - 1, s.col_start,
        { end_col = s.col_end, hl_group = s.hl })
    end
  end
  return buf
end

--- True when `buf` is the current buffer of any window, in any tabpage.
local function buf_is_displayed(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      return true
    end
  end
  return false
end

--- Delete a previous generation's buffers one event-loop tick from now, once
--- whatever replaced them in their windows has settled.
---
--- Never deletes a buffer still displayed: nvim_buf_delete with force closes
--- every window showing it, and takes the tabpage with it if that was the last
--- window — exactly the window-closing this whole mechanism exists to avoid.
function M.retire(bufs)
  if not bufs then
    return
  end
  vim.schedule(function()
    for _, buf in pairs(bufs) do
      if buf and vim.api.nvim_buf_is_valid(buf) and not buf_is_displayed(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)
end

--- Apply `plan.folds` to `win`, or clear folding when there is nothing to fold.
local function apply_folds(win, plan)
  if #plan.folds == 0 then
    folded_by_win[win] = nil
    vim.wo[win].foldenable = false
    return
  end
  local set = {}
  for _, range in ipairs(plan.folds) do
    for row = range[1], range[2] do
      set[row] = true
    end
  end
  folded_by_win[win] = set
  vim.wo[win].foldmethod = "expr"
  vim.wo[win].foldexpr = "v:lua.require'intentdiff.render.paint'.foldexpr()"
  vim.wo[win].foldlevel = 0
  vim.wo[win].foldminlines = 0
  vim.wo[win].foldenable = true
end

--- Render `plan` into `wins`.
--- @param wins table { original = win|nil, modified = win }
--- @return table { bufs = { original = bufnr|nil, modified = bufnr }, plan = plan }
function M.render(plan, wins)
  -- Drop entries for windows that no longer exist, so foldexpr never answers
  -- for a recycled window id.
  for win in pairs(folded_by_win) do
    if not vim.api.nvim_win_is_valid(win) then
      folded_by_win[win] = nil
    end
  end

  local bufs = {}
  local two_pane = plan.original ~= nil
    and wins.original ~= nil
    and wins.original ~= wins.modified
    and vim.api.nvim_win_is_valid(wins.original)

  if two_pane then
    bufs.original = pane_buf(plan.original)
    vim.api.nvim_win_set_buf(wins.original, bufs.original)
  end
  bufs.modified = pane_buf(plan.modified)
  vim.api.nvim_win_set_buf(wins.modified, bufs.modified)

  for side, win in pairs({ original = wins.original, modified = wins.modified }) do
    if (side ~= "original" or two_pane) and win and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].scrollbind = two_pane
      vim.wo[win].cursorbind = two_pane
      apply_folds(win, plan)
    end
  end

  if two_pane then
    vim.api.nvim_win_call(wins.modified, function()
      vim.cmd("syncbind")
    end)
  end

  return { bufs = bufs, plan = plan }
end

return M
