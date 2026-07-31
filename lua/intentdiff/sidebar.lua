local M = {}

M.ns = vim.api.nvim_create_namespace("intentdiff_sidebar")

local tree = require("intentdiff.tree")
local hl = require("intentdiff.highlight")

--- Hard-wrap `text` to `width` display columns on word boundaries, hard-cutting
--- a single word that is longer than the width. The sidebar window keeps
--- `wrap = false` so tree alignment survives; wrapping happens here instead.
---
--- The hard-cut path works in whole Unicode characters (vim.fn.strchars /
--- strcharpart), never bytes: shrinking a candidate substring one BYTE at a
--- time (string:sub) can slice a multibyte character in half, and Vim
--- renders an invalid UTF-8 prefix as "<xx>" — display width 4, always
--- bigger than any width we're trying to fit. That byte-wise shrink can
--- therefore degrade all the way to "", consuming zero bytes of `word` per
--- outer iteration, and spin forever — this bit group titles (LLM output,
--- so a CJK character or an emoji is unremarkable) at any sidebar_width <= 3
--- (title wrap width = sidebar_width - 2). Character-wise cutting always
--- removes at least one whole codepoint per outer iteration, so it always
--- makes progress; if even a single character does not fit `width` (a
--- degenerate width, or one very wide glyph), that one character is still
--- emitted rather than nothing, and the loop moves past it.
local function wrap_text(text, width)
  -- A non-positive width would otherwise never let anything "fit". Clamp to
  -- 1 so a pathological config value can't wedge the editor either.
  width = math.max(width, 1)
  local out, line = {}, ""
  for word in text:gmatch("%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if vim.fn.strdisplaywidth(candidate) <= width then
      line = candidate
    else
      if line ~= "" then
        out[#out + 1] = line
      end
      while vim.fn.strdisplaywidth(word) > width do
        local n = vim.fn.strchars(word)
        local cut = word
        -- Shrink by whole characters until it fits, but never below one
        -- character — a single glyph wider than `width` is still emitted
        -- whole rather than leaving nothing to consume from `word`.
        while n > 1 and vim.fn.strdisplaywidth(cut) > width do
          n = n - 1
          cut = vim.fn.strcharpart(word, 0, n)
        end
        out[#out + 1] = cut
        word = vim.fn.strcharpart(word, n)
      end
      line = word
    end
  end
  if line ~= "" then
    out[#out + 1] = line
  end
  if #out == 0 then
    out[1] = ""
  end
  return out
end

--- Devicon for `path`, or "" when nvim-web-devicons is absent or icons are off.
--- Mirrors codediff's own pcall guard (ui/explorer/nodes.lua).
local function file_icon(path)
  if not require("intentdiff.config").options.icons then
    return "", nil
  end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return "", nil
  end
  local icon, icon_hl = devicons.get_icon(path, nil, { default = true })
  return icon or "", icon_hl
end

local function stats_text(additions, deletions)
  local parts = {}
  if additions > 0 then
    parts[#parts + 1] = "+" .. additions
  end
  if deletions > 0 then
    parts[#parts + 1] = "-" .. deletions
  end
  return parts
end

--- Pure layout: Model → buffer lines, per-line metadata, highlight spans.
--- @return string[] lines, table[] meta, table[] highlights
---   highlight span: { line, col_start, col_end, hl } — 1-based line,
---   0-based byte columns, col_end exclusive.
function M.layout(model)
  local width = require("intentdiff.config").options.sidebar_width
  local lines, meta, highlights = {}, {}, {}

  local function add(text, m)
    lines[#lines + 1] = text
    meta[#lines] = m
    return #lines
  end
  local function span(line, col_start, col_end, group)
    if col_end > col_start then
      highlights[#highlights + 1] =
        { line = line, col_start = col_start, col_end = col_end, hl = group }
    end
  end

  if model.state == "loading" then
    if type(model.elapsed_s) == "number" then
      add(("⟳ classifying… %ds"):format(model.elapsed_s), { kind = "info" })
    else
      add("⟳ classifying…", { kind = "info" })
    end
  end
  if model.message then
    add("⚠ " .. model.message, { kind = "info" })
  end

  for gi, g in ipairs(model.groups or {}) do
    -- Hover/toggle treat every title line and the stats line as one row
    -- (kind == "group" on all of them, sharing group_i). But group-to-group
    -- navigation (<Tab>/<S-Tab>) needs to land on exactly one line per
    -- group, not re-visit every wrapped title line — so the first title
    -- line alone also carries group_head = true, in its own table (title
    -- lines 2+ and the stats line share `group_meta`, so group_head must
    -- NOT be set on that shared table, or every line would report it).
    local group_meta = { kind = "group", group_i = gi }
    -- `title` rides along on the HEAD row only, so handle.comment_rows can
    -- report one row per intent — with the title comment lookups key on —
    -- without the sidebar having to retain the model it last rendered. The
    -- shared `group_meta` deliberately does not carry it, for the same reason
    -- it does not carry group_head: every wrapped title line and the stats
    -- line share that one table.
    local group_head_meta = { kind = "group", group_i = gi, group_head = true, title = g.title }
    local marker = g.collapsed and "▸" or "▾"
    local title_lines = wrap_text(g.title, width - 2)
    for i, text in ipairs(title_lines) do
      local prefix = i == 1 and (marker .. " ") or "  "
      local lnum = add(prefix .. text, i == 1 and group_head_meta or group_meta)
      span(lnum, #prefix, #prefix + #text, "IntentDiffGroupTitle")
    end

    local additions, deletions = 0, 0
    for _, h in ipairs(g.hunks or {}) do
      additions = additions + (h.additions or 0)
      deletions = deletions + (h.deletions or 0)
    end
    local counts = ("  %d hunks · %d files"):format(#(g.hunks or {}), #(g.files or {}))
    local stats_line = counts
    local parts = stats_text(additions, deletions)
    local lnum = add(stats_line .. (#parts > 0 and ("  " .. table.concat(parts, " ")) or ""),
      group_meta)
    span(lnum, 0, #counts, "IntentDiffGroupStats")
    local col = #stats_line + 2
    for _, part in ipairs(parts) do
      span(lnum, col, col + #part,
        part:sub(1, 1) == "+" and "IntentDiffAdd" or "IntentDiffDelete")
      col = col + #part + 1
    end

    if not g.collapsed then
      local rows = tree.flatten(tree.build(g.files or {}), g.collapsed_dirs or {})
      for _, row in ipairs(rows) do
        local status = row.kind == "file" and hl.status_char(row.status) or " "
        local gutter = (" %-1s "):format(status)
        local indent = string.rep("  ", row.depth)
        local text, icon_hl, icon
        if row.kind == "dir" then
          text = (row.collapsed and "▸ " or "▾ ") .. row.name
        else
          icon, icon_hl = file_icon(row.path)
          text = "  " .. (icon ~= "" and (icon .. " ") or "") .. row.name
        end
        local body = gutter .. indent .. text
        local row_parts = row.kind == "file" and stats_text(row.additions, row.deletions) or {}
        local suffix = #row_parts > 0 and ("  " .. table.concat(row_parts, " ")) or ""
        local row_meta = row.kind == "dir"
            and { kind = "dir", group_i = gi, dir_path = row.path }
          or { kind = "file", group_i = gi, file_i = row.file_i }
        local rnum = add(body .. suffix, row_meta)

        if row.kind == "file" then
          span(rnum, 1, 1 + #status, hl.status_group(row.status))
        end
        if #indent > 0 then
          span(rnum, #gutter, #gutter + #indent, "IntentDiffIndent")
        end
        if row.kind == "dir" then
          span(rnum, #gutter + #indent, #body, "IntentDiffDirectory")
        elseif icon_hl then
          local icon_start = #gutter + #indent + 2
          span(rnum, icon_start, icon_start + #icon, icon_hl)
        end
        local scol = #body + 2
        for _, part in ipairs(row_parts) do
          span(rnum, scol, scol + #part,
            part:sub(1, 1) == "+" and "IntentDiffAdd" or "IntentDiffDelete")
          scol = scol + #part + 1
        end
      end
    end
  end

  if model.state == "ready" then
    local stale = (model.stale_count or 0) > 0
        and (" · stale — %d unclassified"):format(model.stale_count) or ""
    -- No provider label ⇒ no provider produced this grouping (flat fallback
    -- after a provider failure). Omit the field entirely; a literal "?" read
    -- like a broken provider name.
    local label = model.provider_label and (" · " .. model.provider_label) or ""
    add(("%d/%d hunks%s%s"):format(model.grouped_hunks, model.total_hunks, label, stale),
      { kind = "footer" })
  end
  return lines, meta, highlights
end

local function apply_win_opts(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].winfixwidth = true
  vim.wo[win].wrap = false
end

--- Open the sidebar split and wire keymaps. Returns a handle.
function M.create(callbacks)
  hl.ensure()
  local width = require("intentdiff.config").options.sidebar_width
  vim.cmd("topleft " .. width .. "vsplit")
  local winid = vim.api.nvim_get_current_win()
  -- The tab this sidebar belongs to, captured once: init.lua creates the
  -- sidebar INSIDE the codediff tab it just bootstrapped, and hiding the
  -- sidebar drops handle.winid, so re-deriving it later would fail exactly
  -- when a comment refresh still needs it.
  local tabpage = vim.api.nvim_win_get_tabpage(winid)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide" -- survives hiding; init.lua's forget_entry deletes it
  vim.bo[bufnr].filetype = "intentdiff"
  apply_win_opts(winid)

  local handle = { winid = winid, bufnr = bufnr, meta = {}, visible = true }

  function handle.meta_at(lnum)
    return handle.meta[lnum]
  end

  --- The one row per intent that a comment sign can hang from, straight out of
  --- the meta table the last render produced — no retained model, so this can
  --- never disagree with what is on screen.
  ---
  --- `pairs`, not `ipairs`: meta is keyed by line number and the caller sorts
  --- nothing, but more importantly a hole would end an ipairs walk early.
  --- @return { lnum: integer, title: string }[]
  function handle.comment_rows()
    local out = {}
    for lnum, m in pairs(handle.meta) do
      if m and m.kind == "group" and m.group_head and m.title then
        out[#out + 1] = { lnum = lnum, title = m.title }
      end
    end
    return out
  end

  function handle.update(model)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local lines, meta, highlights = M.layout(model)
    handle.meta = meta
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    for i, m in ipairs(meta) do
      local line_hl = ({ info = "WarningMsg", footer = "Comment" })[m.kind]
      if line_hl then
        vim.api.nvim_buf_set_extmark(bufnr, M.ns, i - 1, 0, { line_hl_group = line_hl })
      end
    end
    for _, s in ipairs(highlights) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, s.line - 1, s.col_start,
        { end_col = s.col_end, hl_group = s.hl })
    end
    -- Comment signs live in their own namespace, and the render above just
    -- moved every row: re-sign the intents that carry a comment. No-op when
    -- comments are off, or before this sidebar's session is registered (the
    -- very first update, which has nothing to sign anyway).
    if require("intentdiff.config").comments_enabled() then
      pcall(function()
        require("intentdiff.comments").refresh_sidebar(tabpage)
      end)
    end
  end

  --- Close the sidebar window, keeping the buffer (and therefore the model,
  --- the meta table and every keymap) intact. Refuses to close the last window
  --- in the tab, which would take the review tab with it.
  function handle.hide()
    if not handle.visible then
      return false
    end
    if handle.winid and vim.api.nvim_win_is_valid(handle.winid) then
      -- `tabpage` is the one captured at create time; the sidebar window has
      -- never lived anywhere else, so re-deriving it here only shadowed it
      -- with an identical value.
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

  --- Bind every key an action is configured with. `spec` is a single lhs, a
  --- list of them, or false/nil to install nothing.
  local function map(spec, fn, desc)
    require("intentdiff.keymaps").each(spec, function(lhs)
      vim.keymap.set("n", lhs, fn, { buffer = bufnr, nowait = true, desc = desc })
    end)
  end
  local function cursor_meta()
    if not (handle.winid and vim.api.nvim_win_is_valid(handle.winid)) then
      return {}
    end
    return handle.meta_at(vim.api.nvim_win_get_cursor(handle.winid)[1]) or {}
  end

  local keys = require("intentdiff.config").options.keymaps or {}
  local skm = keys.sidebar or {}
  local vkm = keys.view or {}

  map(skm.select, function()
    local m = cursor_meta()
    if m.kind == "file" then
      callbacks.on_select(m.group_i, m.file_i)
    elseif m.kind == "dir" then
      callbacks.on_fold(m.group_i, m.dir_path, "toggle", false)
    elseif m.kind == "group" then
      callbacks.on_fold(m.group_i, nil, "toggle", false)
    end
  end, "intent-diff: open file / toggle intent")

  --- A fold key acts on the directory under the cursor, or — on a title,
  --- stats or file row — on the intent that row belongs to.
  local function fold(action, recursive)
    return function()
      local m = cursor_meta()
      if m.kind == "dir" then
        callbacks.on_fold(m.group_i, m.dir_path, action, recursive)
      elseif m.group_i then
        callbacks.on_fold(m.group_i, nil, action, recursive)
      end
    end
  end
  map(skm.fold_open, fold("open", false), "intent-diff: open fold")
  map(skm.fold_open_recursive, fold("open", true), "intent-diff: open fold recursively")
  map(skm.fold_close, fold("close", false), "intent-diff: close fold")
  map(skm.fold_close_recursive, fold("close", true), "intent-diff: close fold recursively")
  map(skm.fold_toggle, fold("toggle", false), "intent-diff: toggle fold")
  map(skm.fold_toggle_recursive, fold("toggle", true), "intent-diff: toggle fold recursively")
  map(skm.fold_open_all, function()
    callbacks.on_fold_all("open")
  end, "intent-diff: expand every intent")
  map(skm.fold_close_all, function()
    callbacks.on_fold_all("close")
  end, "intent-diff: collapse every intent")
  map(skm.fold_toggle_all, function()
    callbacks.on_fold_all("toggle")
  end, "intent-diff: expand or collapse every intent")

  -- Lives in keymaps.view but is installed here too: once the sidebar is
  -- hidden a sidebar-local key would be unreachable.
  map(vkm.toggle_sidebar, function()
    callbacks.on_toggle_sidebar()
  end, "intent-diff: show/hide the sidebar")
  map(skm.show_help, function()
    require("intentdiff.keymap_help").toggle()
  end, "intent-diff: toggle this help")
  map(skm.reclassify, callbacks.on_reclassify, "intent-diff: re-classify")
  map(skm.quit, callbacks.on_close, "intent-diff: close")
  map(skm.next_group, callbacks.on_next_group, "intent-diff: next intent")
  map(skm.prev_group, callbacks.on_prev_group, "intent-diff: previous intent")
  map(skm.goto_file, function()
    local m = cursor_meta()
    if m.kind == "file" then
      callbacks.on_goto_file(m.group_i, m.file_i)
    end
  end, "intent-diff: open the real file")

  -- The comment keys are installed on the sidebar as well as on the panes: an
  -- intent comment is added from a group row, and the export/list keys have to
  -- be reachable from whichever surface the user happens to be in.
  require("intentdiff.view").install_comment_keymaps(bufnr, tabpage)

  return handle
end

return M
