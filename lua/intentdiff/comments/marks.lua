-- Rendering comments into the diff panes and the sidebar.
--
-- Two namespaces: `ns` for the comments themselves, `ns_padding` for the blank
-- virt_lines that keep the two panes the same height. A box on one side makes
-- that side taller, and codediff's scroll sync aligns by filler count — without
-- the padding the panes drift apart as soon as you comment on one side.
local M = {}

local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")
local hl = require("intentdiff.highlight")

M.ns = vim.api.nvim_create_namespace("intentdiff_comments")
M.ns_padding = vim.api.nvim_create_namespace("intentdiff_comments_padding")

local MIN_BOX_WIDTH = 20

--- Type metadata by key, from the configured list.
local function type_info(key)
  for _, t in ipairs((config.options.comments or {}).types or {}) do
    if t.key == key then
      return t
    end
  end
  return { key = key, name = tostring(key), icon = "●" }
end

--- The bordered comment body, as `virt_lines`. Every line is padded to the
--- same DISPLAY width — a box padded by byte count misaligns the moment the
--- text contains anything non-ASCII.
--- @return table[] virt_lines
function M.build_box(text, type_name, hl_group)
  local lines = vim.split(text or "", "\n")
  local width = MIN_BOX_WIDTH
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local header = ("[%s]"):format(tostring(type_name):upper())
  -- `comments.types[].name` is free user text: a header longer than
  -- `width + 1` would otherwise make the `string.rep` count below negative.
  -- Lua's string.rep silently returns "" for n <= 0 (no error, so the pcalls
  -- around every extmark call downstream never see it) and the top border
  -- comes out shorter than every other line. Clamp width up first so the
  -- rep count floors at 0, never below.
  width = math.max(width, vim.fn.strdisplaywidth(header) - 1)
  local out = {}
  out[#out + 1] = { { "╭─" .. header .. string.rep("─", width - vim.fn.strdisplaywidth(header) + 1) .. "╮", hl_group } }
  for _, line in ipairs(lines) do
    local pad = width - vim.fn.strdisplaywidth(line)
    out[#out + 1] = { { "│ " .. line .. string.rep(" ", pad) .. " │", hl_group } }
  end
  out[#out + 1] = { { "╰" .. string.rep("─", width + 2) .. "╯", hl_group } }
  return out
end

--- The 0-indexed (first, final) anchor rows for a line/range comment,
--- clamped into `[0, last - 1]`. `last` is the buffer's line count
--- (`nvim_buf_line_count`, always >= 1), so this always returns somewhere
--- renderable — a persisted comment that drifted past EOF (in `line`,
--- `line_end`, or both) clamps onto the last line rather than being
--- dropped, so it stays visible and exportable. Shared by `render_buffer`
--- and `align`'s `heights()` so the two can never disagree about where a
--- drifted comment's box actually landed.
local function clamp_rows(c, last)
  local max_row = math.max(last - 1, 0)
  local first = math.min(c.line - 1, max_row)
  local final = math.min((c.line_end or c.line) - 1, max_row)
  if final < first then
    final = first
  end
  return first, final
end

--- Rendered height of a comment's box, and the 0-indexed row it hangs from,
--- clamped exactly as `render_buffer` clamps the extmark itself.
local function box_height(c, last)
  local _, final = clamp_rows(c, last)
  return #vim.split(c.text or "", "\n") + 2, final
end

--- After anchoring a file-level comment's box above line 0 with
--- `virt_lines_above`, nudge every window currently showing this buffer so
--- the box is actually on screen instead of scrolled off above line 1.
--- `topfill` is the number of virtual "filler" lines vim renders above
--- topline when topline is at (or before) the first line — exactly what
--- `virt_lines_above` needs to make room for. Follows review.nvim's approach.
local function nudge_topfill(bufnr, box_lines)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    -- pcall: the window can close between win_findbuf listing it and us
    -- getting to it (e.g. another render or a user action mid-loop).
    pcall(vim.api.nvim_win_call, win, function()
      local view = vim.fn.winsaveview()
      if view.topline <= 1 then
        view.topfill = box_lines
        vim.fn.winrestview(view)
      end
    end)
  end
end

--- Clear and re-render every comment for `file` on `side` into `bufnr`.
function M.render_buffer(bufnr, file, side)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and file) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local last = vim.api.nvim_buf_line_count(bufnr)

  for _, c in ipairs(store.get_for_file(file, side)) do
    local info = type_info(c.type)
    local sign_hl, line_hl = hl.comment_groups(c.type)
    local box = M.build_box(c.text, info.name, sign_hl)

    if (c.line or 0) == 0 then
      local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, 0, 0, {
        sign_text = info.icon,
        sign_hl_group = sign_hl,
        virt_lines = box,
        virt_lines_above = true,
      })
      if ok then
        nudge_topfill(bufnr, #box)
      end
    else
      -- A persisted comment can outlive the lines it pointed at (in `line`,
      -- `line_end`, or both); clamp_rows clamps rather than dropping it, so
      -- it stays visible and exportable.
      local first, final = clamp_rows(c, last)
      if final == first then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, first, 0, {
          sign_text = info.icon,
          sign_hl_group = sign_hl,
          line_hl_group = line_hl,
          virt_lines = box,
        })
      else
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, first, 0, {
          sign_text = info.icon,
          sign_hl_group = sign_hl,
          line_hl_group = line_hl,
        })
        for row = first + 1, final - 1 do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, 0, { line_hl_group = line_hl })
        end
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, final, 0, {
          line_hl_group = line_hl,
          virt_lines = box,
        })
      end
    end
  end
end

--- Blank-line padding so a box on one side does not make the panes drift.
function M.align(orig_buf, mod_buf, file)
  for _, buf in ipairs({ orig_buf, mod_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ns_padding, 0, -1)
    end
  end
  if not (orig_buf and mod_buf and file
    and vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)) then
    return
  end

  --- row → total box height on that side. `get_for_file(file, side)` already
  --- filters to that side, so no side check belongs here. What excludes a
  --- file-level comment (line 0) is `(c.line or 0) ~= 0` below: it renders
  --- identically on both panes via render_buffer's own branch, not through
  --- this alignment path, and has no single row of its own to key padding
  --- on. Do not reintroduce a `(c.side or "new") == side` clause here — a
  --- file-level comment has no `side` field, so it defaults to `"new"` and
  --- such a clause would pass it through on the new-side pass rather than
  --- excluding it; the `(c.line or 0) ~= 0` check is the only thing doing
  --- that job.
  local function heights(side, buf)
    local map = {}
    local last = vim.api.nvim_buf_line_count(buf)
    for _, c in ipairs(store.get_for_file(file, side)) do
      if (c.line or 0) ~= 0 then
        local h, row = box_height(c, last)
        map[row] = (map[row] or 0) + h
      end
    end
    return map
  end

  local old_h, new_h = heights("old", orig_buf), heights("new", mod_buf)
  local rows = {}
  for row in pairs(old_h) do rows[row] = true end
  for row in pairs(new_h) do rows[row] = true end

  for row in pairs(rows) do
    local diff = (old_h[row] or 0) - (new_h[row] or 0)
    if diff ~= 0 then
      local target = diff > 0 and mod_buf or orig_buf
      local padding = {}
      for _ = 1, math.abs(diff) do
        padding[#padding + 1] = { { "", "Normal" } }
      end
      pcall(vim.api.nvim_buf_set_extmark, target, M.ns_padding, row, 0, { virt_lines = padding })
    end
  end
end

--- Sign the sidebar rows whose intent carries a comment. No box: the sidebar
--- is a dense navigation surface and boxes would push rows around.
--- @param rows { lnum: integer, title: string }[] group head rows, 1-indexed
function M.render_sidebar(bufnr, rows)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  for _, row in ipairs(rows or {}) do
    local comments = store.get_for_intent(row.title)
    if #comments > 0 then
      local info = type_info(comments[1].type)
      local sign_hl = hl.comment_groups(comments[1].type)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row.lnum - 1, 0, {
        sign_text = info.icon,
        sign_hl_group = sign_hl,
      })
    end
  end
end

function M.clear_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
      vim.api.nvim_buf_clear_namespace(buf, M.ns_padding, 0, -1)
    end
  end
end

-- M.refresh(tabpage) is deliberately absent here — it needs view's
-- pane/session lookup and is added in Task 7, where the wiring lives.

return M
