-- Rendering comments into the painted panes and the sidebar.
--
-- ONE render path. A pane is a coordinate system — `pane.map` says which
-- (file, line, side) each row shows — so a comment is placed by asking the map
-- where its line landed, whether the panes hold a single file or a whole
-- intent. There is no second, file-shaped path any more, and therefore no way
-- for the two to disagree about where a comment lives.
--
-- Two namespaces: `ns` for the comments themselves, `ns_padding` for the blank
-- virt_lines that keep the two panes the same height. A box on one side makes
-- that side taller, and scrollbind aligns by row — without the padding the
-- panes drift apart as soon as you comment on one side.
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

local function visible_comments(store)
  if store and store.get_visible then
    return store.get_visible()
  end
  return store and store.get_all() or {}
end

--- store → set of buffers that store has drawn comment extmarks into, so a
--- review's teardown clears exactly what IT rendered and nothing else.
--- `clear_all()` used to walk every buffer in the editor, which wiped the other
--- review tab's boxes the moment either tab closed.
---
--- Weak KEYS: when a session entry drops its store, this record goes with it —
--- a strong table here would pin every store of every review ever opened.
local touched = setmetatable({}, { __mode = "k" })

--- Note this store drew into `bufnr`. Recorded even when the render placed no
--- extmark: render_pane CLEARS the namespace first, so a buffer it touched
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
--- @param opts { posted: boolean|nil }|nil
--- @return table[] virt_lines
function M.build_box(text, type_name, hl_group, opts)
  local lines = vim.split(text or "", "\n")
  local width = MIN_BOX_WIDTH
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  -- `· POSTED` rides INSIDE the brackets so the header stays one token and the
  -- clamp below still measures the whole thing.
  local header = ("[%s]"):format(tostring(type_name):upper())
  if opts and opts.posted then
    header = ("[%s · POSTED]"):format(tostring(type_name):upper())
  end
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

--- The rows of `pane` that comment `c` is DRAWN on, ascending.
---
--- Normally the rows its (file, line, side) maps to — `plan.rows_for`, the
--- inverse of the very map a cursor is resolved through, so a comment is drawn
--- exactly where commenting again would land.
---
--- The second return says the comment DRIFTED: its lines are not in this render
--- but its file is, so it clamps onto the last row of that file on that side
--- rather than vanishing. A persisted comment can outlive the code it pointed
--- at, and dropping it would leave it exportable but invisible. Clamping is
--- deliberately scoped to the file's own rows — clamping to the pane's last row
--- would land a comment of one file on top of another's, which is the mirror
--- image of the same bug.
---
--- This is the ONE definition of "where did that comment end up". The renderer
--- draws with it and the action layer reads back with it (comments/init.lua's
--- at_cursor / jump / place_cursor), so edit, delete and `]n` can never again
--- miss a comment the user can plainly see.
--- @return integer[] rows, boolean drifted
function M.rows_for_comment(pane, c)
  if not (pane and pane.map and c and c.file) then
    return {}, false
  end
  if not c.line or c.line == 0 or c.intent_title then
    return {}, false
  end
  local rows = require("intentdiff.render.plan").rows_for(pane, c)
  if #rows > 0 then
    return rows, false
  end
  local side = c.side or "new"
  local last
  -- Numeric loop, NOT ipairs: `map` is sparse by construction.
  for row = 1, #pane.lines do
    local t = pane.map[row]
    if t and t.file == c.file and t.side == side then
      last = row
    end
  end
  if not last then
    return {}, false -- this render does not show that file at all
  end
  return { last }, true
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
  local box = M.build_box(c.text, c.display_name or info.name, sign_hl,
    { posted = c.posted ~= nil })
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

--- Draw a file-level comment's box above `row0` — the first row of its file in
--- this render, which is line 1 when the panes show that file alone and the row
--- after its separator when they show a whole intent.
local function draw_file_level(bufnr, c, row0)
  local info = type_info(c.type)
  local sign_hl = hl.comment_groups(c.type)
  local box = M.build_box(c.text, c.display_name or info.name, sign_hl,
    { posted = c.posted ~= nil })
  local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, 0, {
    sign_text = info.icon,
    sign_hl_group = sign_hl,
    virt_lines = box,
    virt_lines_above = true,
  })
  -- Only the box hanging above the very first row can be scrolled off the top;
  -- anywhere else there are real lines above it to hold it on screen.
  if ok and row0 == 0 then
    nudge_topfill(bufnr, #box)
  end
end

-- ---------------------------------------------------- the painted panes --

--- The row each file's block starts on, valid on BOTH panes because a plan's
--- two panes always have the same line count.
---
--- Scanned over both panes, earliest wins: a file whose first row is a pure
--- addition has no original-side coordinate there, so each pane's own first row
--- for it can differ by a line — anchoring a file-level box at a different row
--- per pane is exactly the drift the padding below exists to prevent.
--- @return table [file] = row (1-indexed)
function M.file_anchors(plan)
  local out = {}
  local function scan(pane)
    if not pane then
      return
    end
    -- Numeric loop, NOT ipairs: `map` is sparse by construction.
    for row = 1, #pane.lines do
      local t = pane.map[row]
      if t and (out[t.file] == nil or row < out[t.file]) then
        out[t.file] = row
      end
    end
  end
  if plan then
    scan(plan.original)
    scan(plan.modified)
  end
  return out
end

--- Every comment `store` holds that this pane draws, with the rows it draws it
--- on. `above` marks a file-level box, which hangs ABOVE its anchor row.
---
--- Comments this render does not show — another intent's files, a file-level
--- comment on a file that is not on screen — yield nothing and are skipped:
--- they still exist, still export, and must not error here. Intent comments
--- address no line at all and live on a sidebar row.
--- @return table[] { comment, rows, above } — rows 1-indexed, ascending
local function placements(store, pane, anchors)
  local out = {}
  for _, c in ipairs(visible_comments(store)) do
    -- Intent comments live on a sidebar row and address no line, so they are
    -- simply not candidates here.
    if not c.intent_title and c.file then
      if (c.line or 0) == 0 then
        local row = anchors[c.file]
        if row then
          out[#out + 1] = { comment = c, rows = { row }, above = true }
        end
      else
        local rows = M.rows_for_comment(pane, c)
        if #rows > 0 then
          out[#out + 1] = { comment = c, rows = rows, above = false }
        end
      end
    end
  end
  return out
end

--- Clear and re-render `store`'s comments into one painted pane buffer.
---
--- THE render path, for every surface: `pane.map` is what says which line each
--- row shows, so one file and a whole intent are the same call.
--- `anchors` may be omitted, in which case they are derived from this pane
--- alone — correct whenever there is only one pane to be consistent with.
function M.render_pane(store, bufnr, pane, anchors)
  if not (store and bufnr and vim.api.nvim_buf_is_valid(bufnr) and pane) then
    return
  end
  anchors = anchors or M.file_anchors({ modified = pane })
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  remember(store, bufnr)
  for _, placement in ipairs(placements(store, pane, anchors)) do
    if placement.above then
      draw_file_level(bufnr, placement.comment, placement.rows[1] - 1)
    else
      local rows0 = {}
      for i, row in ipairs(placement.rows) do
        rows0[i] = row - 1
      end
      draw_rows(bufnr, placement.comment, rows0)
    end
  end
end

--- Blank-line padding between the two painted panes, so a box on one side does
--- not slide the other out of scroll sync.
---
--- Keyed on pane ROWS: both panes show the same rows by construction (the plan
--- pads with real filler rows), so the comparison is row by row. A file-level
--- box is drawn identically on both panes at the same anchor row, so it
--- contributes the same height to each and cancels out — it is included rather
--- than special-cased so that stays true by arithmetic rather than by comment.
---
--- The ONLY place that clears `ns_padding`. Callers that skip it (a single
--- pane, nothing painted) must still clear, which is why the clearing loop runs
--- before the early return: padding set while a buffer was previously shown
--- side-by-side would otherwise survive a layout toggle forever.
function M.align_panes(store, panes, anchors)
  for _, entry in ipairs(panes) do
    if vim.api.nvim_buf_is_valid(entry.bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, entry.bufnr, M.ns_padding, 0, -1)
      remember(store, entry.bufnr)
    end
  end
  if #panes ~= 2 or not store then
    return -- inline layout: one buffer, nothing to keep aligned
  end
  anchors = anchors or {}

  --- 0-indexed row -> total box height drawn on it in this pane.
  local function heights(entry)
    local map = {}
    for _, placement in ipairs(placements(store, entry.pane, anchors)) do
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
      local target
      if diff > 0 then
        target = panes[2].bufnr
      else
        target = panes[1].bufnr
      end
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
---
--- Nothing here asks WHAT the panes are showing: the painted plan is a
--- coordinate system, and every comment is placed by its own (file, line, side)
--- through that plan's map. That is what makes one file and a whole intent the
--- same render.
function M.refresh(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local store = require("intentdiff.comments").store_for(tabpage)
  if not store then
    return
  end
  local view = require("intentdiff.view")
  local panes = view.painted_panes(tabpage)
  local anchors = M.file_anchors(view.current_plan(tabpage))
  for _, entry in ipairs(panes) do
    M.render_pane(store, entry.bufnr, entry.pane, anchors)
  end
  M.align_panes(store, panes, anchors)
end

return M
