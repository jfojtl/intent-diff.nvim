local M = {}

M.ns = vim.api.nvim_create_namespace("intentdiff_sidebar")

local tree = require("intentdiff.tree")
local hl = require("intentdiff.highlight")

--- Hard-wrap `text` to `width` display columns on word boundaries, hard-cutting
--- a single word that is longer than the width. The sidebar window keeps
--- `wrap = false` so tree alignment survives; wrapping happens here instead.
local function wrap_text(text, width)
  -- A non-positive width would leave `cut` degrading to "" below, so `word`
  -- is never consumed and the inner while loop spins forever. Clamp to 1: a
  -- pathological config value shouldn't be able to wedge the editor.
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
        local cut = word
        while vim.fn.strdisplaywidth(cut) > width do
          cut = cut:sub(1, #cut - 1)
        end
        out[#out + 1] = cut
        word = word:sub(#cut + 1)
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
    local group_head_meta = { kind = "group", group_i = gi, group_head = true }
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

--- Open the sidebar split and wire keymaps. Returns a handle.
function M.create(callbacks)
  hl.ensure()
  local width = require("intentdiff.config").options.sidebar_width
  vim.cmd("topleft " .. width .. "vsplit")
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "intentdiff"
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].winfixwidth = true
  vim.wo[winid].wrap = false

  local handle = { winid = winid, bufnr = bufnr, meta = {} }

  function handle.meta_at(lnum)
    return handle.meta[lnum]
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
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, nowait = true })
  end
  local function cursor_meta()
    return handle.meta_at(vim.api.nvim_win_get_cursor(winid)[1]) or {}
  end
  map("<CR>", function()
    local m = cursor_meta()
    if m.kind == "file" then
      callbacks.on_select(m.group_i, m.file_i)
    elseif m.kind == "dir" then
      callbacks.on_toggle_dir(m.group_i, m.dir_path)
    elseif m.kind == "group" then
      callbacks.on_toggle_group(m.group_i)
    end
  end)
  for _, key in ipairs({ "za", "h", "l" }) do
    map(key, function()
      local m = cursor_meta()
      if m.kind == "dir" then
        callbacks.on_toggle_dir(m.group_i, m.dir_path)
      elseif m.group_i then
        callbacks.on_toggle_group(m.group_i)
      end
    end)
  end
  map("r", callbacks.on_reclassify)
  map("q", callbacks.on_close)
  map("<Tab>", callbacks.on_next_group)
  map("<S-Tab>", callbacks.on_prev_group)
  map("gf", function()
    local m = cursor_meta()
    if m.kind == "file" then
      callbacks.on_goto_file(m.group_i, m.file_i)
    end
  end)

  return handle
end

return M
