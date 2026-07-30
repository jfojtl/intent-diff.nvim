local M = {}

M.ns = vim.api.nvim_create_namespace("intentdiff_sidebar")

--- Pure layout: Model → buffer lines + per-line metadata.
function M.layout(model)
  local lines, meta = {}, {}
  local function add(text, m)
    lines[#lines + 1] = text
    meta[#lines] = m
  end
  if model.state == "loading" then
    add("⟳ classifying…", { kind = "info" })
  end
  if model.message then
    add("⚠ " .. model.message, { kind = "info" })
  end
  for gi, g in ipairs(model.groups or {}) do
    local marker = g.collapsed and "▸" or "▾"
    add(("%s %s  (%d)"):format(marker, g.title, #g.hunks), { kind = "group", group_i = gi })
    if not g.collapsed then
      for fi, f in ipairs(g.files) do
        local branch = fi == #g.files and "└" or "├"
        local name = f.path:match("([^/]+)$") or f.path
        local dir = f.path:sub(1, #f.path - #name)
        add(("  %s %s  %s%s"):format(branch, name, dir ~= "" and dir .. " " or "", f.status),
          { kind = "file", group_i = gi, file_i = fi })
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
  return lines, meta
end

--- Open the sidebar split and wire keymaps. Returns a handle.
function M.create(callbacks)
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
    local lines, meta = M.layout(model)
    handle.meta = meta
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    for i, m in ipairs(meta) do
      local hl = ({ group = "Title", info = "WarningMsg", footer = "Comment" })[m.kind]
      if hl then
        vim.api.nvim_buf_set_extmark(bufnr, M.ns, i - 1, 0, { line_hl_group = hl })
      end
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
    elseif m.kind == "group" then
      callbacks.on_toggle_group(m.group_i)
    end
  end)
  for _, key in ipairs({ "za", "h", "l" }) do
    map(key, function()
      local m = cursor_meta()
      if m.group_i then
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
