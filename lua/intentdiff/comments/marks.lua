-- Rendering comments into the diff panes and the sidebar.
--
-- Two namespaces: `ns` for the comments themselves, `ns_padding` for the blank
-- virt_lines that keep the two panes the same height. A box on one side makes
-- that side taller, and codediff's scroll sync aligns by filler count — without
-- the padding the panes drift apart as soon as you comment on one side.
--
-- Every render takes the STORE it is rendering, never a global one: with two
-- review tabs open there are two stores, and the only thing that says which
-- comments belong in this buffer is which store was handed in.
local M = {}

local config = require("intentdiff.config")
local hl = require("intentdiff.highlight")

M.ns = vim.api.nvim_create_namespace("intentdiff_comments")
M.ns_padding = vim.api.nvim_create_namespace("intentdiff_comments_padding")

local MIN_BOX_WIDTH = 20

--- store → set of buffers that store has drawn comment extmarks into, so a
--- review's teardown clears exactly what IT rendered and nothing else.
--- `clear_all()` used to walk every buffer in the editor, which wiped the other
--- review tab's boxes the moment either tab closed.
---
--- Weak KEYS: when a session entry drops its store, this record goes with it —
--- a strong table here would pin every store of every review ever opened.
local touched = setmetatable({}, { __mode = "k" })

--- Note this store drew into `bufnr`. Recorded even when the render placed no
--- extmark: render_buffer CLEARS the namespace first, so a buffer it touched
--- is one whose marks this review owns and must clean up.
local function remember(store, bufnr)
  if not (store and bufnr) then
    return
  end
  local bufs = touched[store]
  if not bufs then
    bufs = {}
    touched[store] = bufs
  end
  bufs[bufnr] = true
end

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

--- The 1-indexed (first, final) LINES a line/range comment actually occupies
--- in a buffer of `last` lines, clamped into `[1, last]`. A persisted comment
--- that drifted past EOF (in `line`, `line_end`, or both) clamps onto the last
--- line rather than being dropped, so it stays visible and exportable.
---
--- This is the ONE definition of "where did that comment end up", and it is
--- public because the action layer needs the same answer: `marks` clamps the
--- box onto the last line while `store.get_at_line` matches on the RAW stored
--- line, so edit/delete/jump used to miss a drifted comment entirely — visible,
--- but un-editable, un-deletable and un-jumpable. Everything that has to agree
--- about a drifted comment's position (render_buffer, align's heights(),
--- comments/init.lua's at_cursor / jump / place_cursor) goes through here, so
--- they cannot drift apart again.
--- @return integer first, integer final
function M.clamped_span(c, last)
  local max_line = math.max(last or 1, 1)
  local line = c.line or 1
  local first = math.min(line, max_line)
  local final = math.min(c.line_end or line, max_line)
  if final < first then
    final = first
  end
  return first, final
end

--- `clamped_span` against a live buffer's current line count, or nil when the
--- buffer is gone (a pane can be torn down between a keypress and this call).
--- @return integer|nil first, integer|nil final
function M.clamped_span_in_buf(c, bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local ok, last = pcall(vim.api.nvim_buf_line_count, bufnr)
  if not ok then
    return nil
  end
  return M.clamped_span(c, last)
end

--- The 0-indexed anchor rows, for the extmark API. A thin adapter over
--- `clamped_span` so the rendering path and the action layer can never
--- disagree about where a drifted comment's box landed.
local function clamp_rows(c, last)
  local first, final = M.clamped_span(c, last)
  return first - 1, final - 1
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

--- Draw `c` across `rows` (0-indexed, ascending, at least one): sign and line
--- highlight on the first, line highlight on the rest, the box hanging off the
--- last.
---
--- The ONE definition of how a line/range comment is painted, shared by the
--- file-diff path (a contiguous, clamped span) and the whole-intent preview
--- (the rows its map says the comment's real lines landed on, which need not
--- be contiguous — a file separator can sit inside a range). Duplicating it
--- per surface is how the renderer and the action layer came to disagree once
--- already.
local function draw_rows(bufnr, c, rows)
  local n = #rows
  if n == 0 then
    return
  end
  local info = type_info(c.type)
  local sign_hl, line_hl = hl.comment_groups(c.type)
  local box = M.build_box(c.text, info.name, sign_hl)
  if n == 1 then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, rows[1], 0, {
      sign_text = info.icon,
      sign_hl_group = sign_hl,
      line_hl_group = line_hl,
      virt_lines = box,
    })
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, rows[1], 0, {
    sign_text = info.icon,
    sign_hl_group = sign_hl,
    line_hl_group = line_hl,
  })
  for i = 2, n - 1 do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, rows[i], 0, { line_hl_group = line_hl })
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, rows[n], 0, {
    line_hl_group = line_hl,
    virt_lines = box,
  })
end

--- Draw a file-level comment's box above line 1.
local function draw_file_level(bufnr, c)
  local info = type_info(c.type)
  local sign_hl = hl.comment_groups(c.type)
  local box = M.build_box(c.text, info.name, sign_hl)
  local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, 0, 0, {
    sign_text = info.icon,
    sign_hl_group = sign_hl,
    virt_lines = box,
    virt_lines_above = true,
  })
  if ok then
    nudge_topfill(bufnr, #box)
  end
end

--- Clear and re-render every comment for `file` on `side` into `bufnr`, from
--- `store` — the store of the review this buffer belongs to.
function M.render_buffer(store, bufnr, file, side)
  if not (store and bufnr and vim.api.nvim_buf_is_valid(bufnr) and file) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  remember(store, bufnr)
  local last = vim.api.nvim_buf_line_count(bufnr)

  for _, c in ipairs(store.get_for_file(file, side)) do
    if (c.line or 0) == 0 then
      draw_file_level(bufnr, c)
    else
      -- A persisted comment can outlive the lines it pointed at (in `line`,
      -- `line_end`, or both); clamp_rows clamps rather than dropping it, so
      -- it stays visible and exportable.
      local first, final = clamp_rows(c, last)
      local rows = {}
      for row = first, final do
        rows[#rows + 1] = row
      end
      draw_rows(bufnr, c, rows)
    end
  end
end

--- Blank-line padding so a box on one side does not make the panes drift.
function M.align(store, orig_buf, mod_buf, file)
  -- Not `ipairs({ orig_buf, mod_buf })`: with orig_buf nil that literal has a
  -- hole at index 1 and ipairs stops before ever reaching mod_buf, leaving the
  -- one buffer there IS uncleared. Same nil-hole trap M.refresh's own comment
  -- below calls out.
  local function reset(buf)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ns_padding, 0, -1)
      remember(store, buf)
    end
  end
  reset(orig_buf)
  reset(mod_buf)
  if not (store and orig_buf and mod_buf and file
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

-- ------------------------------------------- the whole-intent preview --

--- Every line/range comment `store` holds, paired with the rows of `pane` it
--- lands on. Rows come from `preview.rows_for`, the inverse of the very map
--- the cursor is resolved through — so a comment is drawn exactly where
--- commenting again would land, and nowhere else.
---
--- Comments whose lines are not in this render (another intent's files, or
--- past `preview.max_lines`) yield no rows and are skipped: they still exist,
--- still export, and must not error here. File-level and intent comments
--- address no line and are not drawn in a preview at all.
--- @return table[] { comment, rows } — rows 1-indexed, ascending
local function preview_placements(store, pane)
  local out = {}
  local preview = require("intentdiff.preview")
  for _, c in ipairs(store.get_all()) do
    local rows = preview.rows_for(pane, c)
    if #rows > 0 then
      out[#out + 1] = { comment = c, rows = rows }
    end
  end
  return out
end

--- Clear and re-render `store`'s comments into one preview pane buffer.
function M.render_preview_buffer(store, bufnr, pane)
  if not (store and bufnr and vim.api.nvim_buf_is_valid(bufnr) and pane) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  remember(store, bufnr)
  for _, placement in ipairs(preview_placements(store, pane)) do
    local rows0 = {}
    for i, row in ipairs(placement.rows) do
      rows0[i] = row - 1
    end
    draw_rows(bufnr, placement.comment, rows0)
  end
end

--- Blank-line padding between two preview panes, so a box on one side does not
--- slide the other out of scroll sync. The preview's own alignment already
--- guarantees equal line counts; this keeps that true once boxes are drawn.
---
--- Keyed on preview ROWS rather than on file lines (which is what M.align
--- does): the two panes show the same rows, so the comparison is row by row.
local function align_preview(store, panes)
  for _, entry in ipairs(panes) do
    if vim.api.nvim_buf_is_valid(entry.bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, entry.bufnr, M.ns_padding, 0, -1)
      remember(store, entry.bufnr)
    end
  end
  if #panes ~= 2 then
    return -- inline preview: one buffer, nothing to keep aligned
  end

  --- 0-indexed row → total box height drawn on it in this pane.
  local function heights(pane)
    local map = {}
    for _, placement in ipairs(preview_placements(store, pane.pane)) do
      local row = placement.rows[#placement.rows] - 1
      map[row] = (map[row] or 0) + #vim.split(placement.comment.text or "", "\n") + 2
    end
    return map
  end

  local left, right = heights(panes[1]), heights(panes[2])
  local rows = {}
  for row in pairs(left) do rows[row] = true end
  for row in pairs(right) do rows[row] = true end
  for row in pairs(rows) do
    local diff = (left[row] or 0) - (right[row] or 0)
    if diff ~= 0 then
      local target = (diff > 0) and panes[2].bufnr or panes[1].bufnr
      local padding = {}
      for _ = 1, math.abs(diff) do
        padding[#padding + 1] = { { "", "Normal" } }
      end
      pcall(vim.api.nvim_buf_set_extmark, target, M.ns_padding, row, 0, { virt_lines = padding })
    end
  end
end

--- Re-render every comment into `tabpage`'s live preview panes.
---
--- The preview is a coordinate system, not a storage concept: nothing here
--- consults `_last_shown`, because a preview shows a whole intent's files at
--- once and every comment is placed by its own (file, line, side).
function M.render_preview(store, tabpage)
  local panes = require("intentdiff.view").preview_panes(tabpage)
  for _, entry in ipairs(panes) do
    M.render_preview_buffer(store, entry.bufnr, entry.pane)
  end
  align_preview(store, panes)
end

--- Sign the sidebar rows whose intent carries a comment. No box: the sidebar
--- is a dense navigation surface and boxes would push rows around.
--- @param rows { lnum: integer, title: string }[] group head rows, 1-indexed
function M.render_sidebar(store, bufnr, rows)
  if not (store and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  remember(store, bufnr)
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

--- Wipe the comment and padding extmarks `store` drew, in the buffers IT drew
--- them in — a review's own teardown, not the editor-wide `clear_all()` this
--- replaces. Buffers can die between being recorded and being cleared, hence
--- the validity check and the pcalls.
function M.clear_for(store)
  local bufs = store and touched[store]
  if not bufs then
    return
  end
  touched[store] = nil
  for bufnr in pairs(bufs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns_padding, 0, -1)
    end
  end
end

--- Re-render every surface of a review tab. Called after any pane rebuild and
--- after every store mutation.
---
--- Resolves the store from the tabpage's session, so a caller that only knows
--- "this tab changed" (view.lua) still renders the right review's comments.
function M.refresh(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local store = require("intentdiff.comments").store_for(tabpage)
  local view = require("intentdiff.view")
  if not store then
    return
  end
  -- A preview buffer concatenates many files, so `_last_shown` (the last file
  -- RENDERED, which is not what the panes display) says nothing about it.
  -- Place every comment through the render's own row map instead. Checked
  -- BEFORE _last_shown: previewing an intent before any file has ever been
  -- selected is an ordinary first sidebar move, and its comments must still
  -- draw.
  if view._preview_active[tabpage] then
    return M.render_preview(store, tabpage)
  end
  local shown = view._last_shown[tabpage]
  local session = view.get_session(tabpage)
  if not (shown and shown.file_entry and session) then
    return
  end
  local file = shown.file_entry.path
  local orig_buf = session.original_win and vim.api.nvim_win_is_valid(session.original_win)
    and vim.api.nvim_win_get_buf(session.original_win) or nil
  local mod_buf = session.modified_win and vim.api.nvim_win_is_valid(session.modified_win)
    and vim.api.nvim_win_get_buf(session.modified_win) or nil
  -- Inline layout puts one buffer in both windows; render it once, as "new".
  -- Old-side comments are therefore deliberately invisible/unreachable in
  -- inline layout — do NOT "fix" this by rendering them here too. The single
  -- buffer inline shows is the MODIFIED file's content; an old-side line
  -- number addresses a row of the ORIGINAL file, which simply has no
  -- corresponding row in this buffer to anchor a box to. The check just below
  -- (`orig_buf ~= mod_buf`) is what skips the old-side render; it exists to
  -- avoid exactly that mis-positioned render, not merely to avoid rendering
  -- the same buffer twice.
  if orig_buf and orig_buf ~= mod_buf then
    M.render_buffer(store, orig_buf, file, "old")
  end
  if mod_buf then
    M.render_buffer(store, mod_buf, file, "new")
  end
  if orig_buf and mod_buf and orig_buf ~= mod_buf then
    M.align(store, orig_buf, mod_buf, file)
  else
    -- M.align is the ONLY place that clears ns_padding. Skipping it here
    -- (inline layout, or a whole-file pane with only one side populated)
    -- must not also skip that cleanup, or padding extmarks set while this
    -- buffer was previously shown side-by-side survive a layout toggle:
    -- e.g. a working-tree review's modified buffer picks up old-side-driven
    -- padding in side-by-side layout, the user toggles to inline (which
    -- reuses that same buffer), and without this the blank filler lines
    -- would render forever under a comment box that isn't even shown here.
    -- Not `ipairs({ orig_buf, mod_buf })`: a table literal with a nil first
    -- element (orig_buf nil, mod_buf set) makes ipairs stop before ever
    -- looking at index 2 — the same nil-hole this codebase's pane_windows
    -- helper (view.lua) exists to avoid — so each buffer is cleared
    -- explicitly instead.
    if orig_buf then
      pcall(vim.api.nvim_buf_clear_namespace, orig_buf, M.ns_padding, 0, -1)
    end
    if mod_buf then
      pcall(vim.api.nvim_buf_clear_namespace, mod_buf, M.ns_padding, 0, -1)
    end
  end
end

return M
