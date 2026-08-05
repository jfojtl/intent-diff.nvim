-- Puts a render plan into buffers. The impure half of the renderer: plan.lua
-- decides what the panes contain, this decides nothing and only draws it.
local M = {}

M.ns = vim.api.nvim_create_namespace("intentdiff_render")

--- codediff.ui.inline, if the plugin is installed. Guarded with pcall so a
--- missing codediff degrades to no syntax highlighting instead of erroring.
local function cd_inline()
  local ok, mod = pcall(require, "codediff.ui.inline")
  if ok then
    return mod
  end
  return nil
end

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

--- Treesitter highlights for every (file, side) the plan draws, keyed
--- syntax[path][side][file_line] = { {start_col, end_col, hl_group}, ... }.
---
--- Computed per (file, side) rather than per pane row range because
--- compute_syntax_highlights parses its input as ONE document: an inline pane
--- interleaves deletion rows (original content) with addition and context rows
--- (modified content), and parsing that mixture would produce garbage at every
--- changed run.
local function compute_syntax(plan, content)
  local inline = cd_inline()
  if not inline or not content then
    return {}
  end
  local syntax = {}
  for _, file in ipairs(plan.files) do
    local per_file = content[file.path]
    if per_file and file.filetype and file.filetype ~= "" then
      syntax[file.path] = {
        old = inline.compute_syntax_highlights(per_file.old or {}, file.filetype),
        new = inline.compute_syntax_highlights(per_file.new or {}, file.filetype),
      }
    end
  end
  return syntax
end

--- Place syntax extmarks on every row of `pane` that addresses a real line.
--- Separators and fillers have no map entry and so get nothing.
local function paint_syntax(buf, pane, syntax)
  for row = 1, #pane.lines do
    local t = pane.map[row]
    if t then
      local per_file = syntax[t.file]
      local per_side = per_file and per_file[t.side]
      local hls = per_side and per_side[t.line]
      if hls then
        local text = pane.lines[row]
        for _, hl in ipairs(hls) do
          -- compute_syntax_highlights returns 1-based inclusive start_col and
          -- an exclusive end_col; extmarks want 0-based start and exclusive end.
          local sc = math.max(0, hl.start_col - 1)
          local ec = math.min(hl.end_col, #text)
          if ec > sc then
            pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row - 1, sc,
              { end_col = ec, hl_group = hl.hl_group, priority = 90 })
          end
        end
      end
    end
  end
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
--- @param content table|nil { [path] = { old = string[], new = string[] } };
---   when nil, no syntax highlighting is applied.
--- @return table { bufs = { original = bufnr|nil, modified = bufnr }, plan = plan }
function M.render(plan, wins, content)
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

  local syntax = compute_syntax(plan, content)

  if two_pane then
    bufs.original = pane_buf(plan.original)
    paint_syntax(bufs.original, plan.original, syntax)
    vim.api.nvim_win_set_buf(wins.original, bufs.original)
  end
  bufs.modified = pane_buf(plan.modified)
  paint_syntax(bufs.modified, plan.modified, syntax)
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
