-- Floating help window listing the review tab's keymaps (g?).
--
-- Modeled on codediff's own ui/keymap_help.lua so the two feel like one tool:
-- same centered float, same right-aligned KEYS → ACTION columns, same q/<Esc>/
-- g? to dismiss. Every row is read from config.options.keymaps, so a rebound
-- or disabled key shows up rebound or not at all — the help can never drift
-- from what is actually installed.
local M = {}

local ns = vim.api.nvim_create_namespace("intentdiff_help")

-- Key column width (right-aligned keys sit in this space)
local KEY_COL = 16

local function setup_highlights()
  vim.api.nvim_set_hl(0, "IntentDiffHelpSection", { link = "Statement", default = true })
  vim.api.nvim_set_hl(0, "IntentDiffHelpKey", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "IntentDiffHelpSep", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "IntentDiffHelpDesc", { link = "Normal", default = true })
end

--- Render an action's configured key(s) as one display string, or nil when the
--- action is disabled. A list-valued action shows every key it is bound to.
local function keys_label(spec)
  if not spec then
    return nil
  end
  if type(spec) ~= "table" then
    return tostring(spec)
  end
  local parts = {}
  for _, key in ipairs(spec) do
    if key then
      parts[#parts + 1] = tostring(key)
    end
  end
  return #parts > 0 and table.concat(parts, " ") or nil
end

--- Drop entries whose action is disabled, and the whole section if that leaves
--- it empty.
local function section(title, entries)
  local items = {}
  for _, entry in ipairs(entries) do
    local label = keys_label(entry[1])
    if label then
      items[#items + 1] = { label, entry[2] }
    end
  end
  if #items == 0 then
    return nil
  end
  return { title = title, items = items }
end

local function build_sections(keymaps)
  local skm = keymaps.sidebar or {}
  local vkm = keymaps.view or {}
  local sections = {}

  local sidebar = section("SIDEBAR", {
    { skm.select, "Open file / toggle intent" },
    { skm.fold_open, "Open fold" },
    { skm.fold_open_recursive, "Open fold recursively" },
    { skm.fold_close, "Close fold" },
    { skm.fold_close_recursive, "Close fold recursively" },
    { skm.fold_toggle, "Toggle fold" },
    { skm.fold_toggle_recursive, "Toggle fold recursively" },
    { skm.fold_open_all, "Expand every intent" },
    { skm.fold_close_all, "Collapse every intent" },
    { skm.fold_toggle_all, "Expand or collapse every intent" },
    { skm.next_group, "Next intent" },
    { skm.prev_group, "Previous intent" },
    { skm.goto_file, "Open the real file, closing this tab" },
    { skm.reclassify, "Re-classify (bypasses cache)" },
    { skm.quit, "Close the review tab" },
  })
  if sidebar then
    sections[#sections + 1] = sidebar
  end

  local view_items = {
    { vkm.next_hunk, "Next hunk in the current intent" },
    { vkm.prev_hunk, "Previous hunk in the current intent" },
    { vkm.open_file, "Open the real file at this line (new tab)" },
    { vkm.toggle_sidebar, "Show/hide the sidebar (works in both)" },
    { vkm.quit, "Close the review" },
  }
  -- The layout toggle is ours outright — view.toggle_layout re-renders our own
  -- plan in the other layout. We borrow only the KEY from codediff, so a user
  -- who rebound it there does not have to rebind it twice.
  local ok, cd_config = pcall(require, "codediff.config")
  local cd_toggle = ok and cd_config.options and cd_config.options.keymaps
    and cd_config.options.keymaps.view and cd_config.options.keymaps.view.toggle_layout
  if cd_toggle then
    view_items[#view_items + 1] = { cd_toggle, "Toggle inline/side-by-side" }
  end
  view_items[#view_items + 1] = { vkm.show_help, "Toggle this help" }
  local view = section("DIFF PANES", view_items)
  if view then
    sections[#sections + 1] = view
  end

  -- Review comments. Listed only while the feature is on, so a user who set
  -- comments.enabled = false never sees keys that install nothing.
  --
  -- The popup-local keys (popup_cycle_type / popup_submit / popup_cancel) are
  -- deliberately absent: they are buffer-local to the comment entry float, not
  -- to any tab-wide surface this cheatsheet describes, and the float shows its
  -- own footer.
  local ckm = keymaps.comments or {}
  if require("intentdiff.config").comments_enabled() then
    local comments = section("COMMENTS", {
      { ckm.add_comment, "Add a comment (pick the type)" },
      { ckm.add_note, "Add a note" },
      { ckm.add_suggestion, "Add a suggestion" },
      { ckm.add_issue, "Add an issue" },
      { ckm.add_praise, "Add praise" },
      { ckm.add_file_comment, "Comment on the file / the intent" },
      { ckm.edit_comment, "Edit the comment at the cursor" },
      { ckm.delete_comment, "Delete the comment at the cursor" },
      { ckm.next_comment, "Next comment" },
      { ckm.prev_comment, "Previous comment" },
      { ckm.list_comments, "List every comment" },
      { ckm.export_clipboard, "Copy the review as Markdown" },
      { ckm.export_file, "Write the review to a file" },
      { ckm.clear_comments, "Delete every comment" },
      { ckm.export_and_close, "Copy the review, then close the tab" },
    })
    if comments then
      sections[#sections + 1] = comments
    end
  end

  return sections
end

--- Exposed for tests: the section list the float renders.
M._build_sections = build_sections

local function compute_width(sections)
  local max_desc, max_key = 0, 0
  for _, sec in ipairs(sections) do
    for _, item in ipairs(sec.items) do
      max_key = math.max(max_key, vim.fn.strdisplaywidth(item[1]))
      max_desc = math.max(max_desc, vim.fn.strdisplaywidth(item[2]))
    end
  end
  local key_col = math.max(KEY_COL, max_key)
  -- key column + " → " + desc + padding
  return math.max(key_col + 4 + max_desc + 3, 40), key_col
end

local function render(sections, win_width, key_col)
  local lines, hls = {}, {}
  for i, sec in ipairs(sections) do
    if i > 1 then
      lines[#lines + 1] = ""
    end
    local pad = math.max(math.floor((win_width - #sec.title) / 2), 0)
    lines[#lines + 1] = string.rep(" ", pad) .. sec.title
    hls[#hls + 1] = { #lines - 1, pad, pad + #sec.title, "IntentDiffHelpSection" }

    local header = string.format("%" .. key_col .. "s    %s", "KEYS", "ACTION")
    lines[#lines + 1] = header
    hls[#hls + 1] = { #lines - 1, 0, #header, "IntentDiffHelpSep" }

    for _, item in ipairs(sec.items) do
      -- Pad by DISPLAY width: "%16s" counts bytes, so a multi-key label or a
      -- non-ASCII lhs would misalign the arrow column.
      local gap = math.max(key_col - vim.fn.strdisplaywidth(item[1]), 0)
      local key_str = string.rep(" ", gap) .. item[1]
      local line = key_str .. " → " .. item[2]
      lines[#lines + 1] = line
      local row = #lines - 1
      hls[#hls + 1] = { row, 0, #key_str, "IntentDiffHelpKey" }
      hls[#hls + 1] = { row, #key_str, #key_str + #" → ", "IntentDiffHelpSep" }
      hls[#hls + 1] = { row, #key_str + #" → ", #line, "IntentDiffHelpDesc" }
    end
  end
  return lines, hls
end

--- Window currently showing the help, if any. Module-level rather than
--- per-session: only one help float can be focused at a time anyway, and this
--- keeps the sidebar and the panes toggling the same window.
local open_win = nil

--- Show the help float, or close it if it is already open.
function M.toggle()
  if open_win and vim.api.nvim_win_is_valid(open_win) then
    vim.api.nvim_win_close(open_win, true)
    open_win = nil
    return
  end
  setup_highlights()

  local sections = build_sections(require("intentdiff.config").options.keymaps or {})
  if #sections == 0 then
    return vim.notify("intent-diff: every keymap is disabled", vim.log.levels.INFO)
  end
  local win_width, key_col = compute_width(sections)
  local lines, hls = render(sections, win_width, key_col)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "intentdiff-help"
  for _, hl in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, hl[1], hl[2],
      { end_col = hl[3], hl_group = hl[4] })
  end

  -- Clamp to the editor so a tall list (or a short window) still opens.
  local height = math.min(#lines, math.max(vim.o.lines - 4, 1))
  local width = math.min(win_width, math.max(vim.o.columns - 4, 1))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(math.floor((vim.o.lines - height) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " intent-diff keymaps ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = "NormalFloat:Normal"
  open_win = win

  --- Clearing `open_win` is guarded on it still pointing HERE: the WinLeave
  --- close below is scheduled, so a dismiss-then-reopen inside one tick would
  --- otherwise run this stale closure against the new window's tracking and
  --- strand it — untracked, and impossible to toggle shut.
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if open_win == win then
      open_win = nil
    end
  end
  local dismiss = { "q", "<Esc>" }
  local km = require("intentdiff.config").options.keymaps or {}
  for _, spec in ipairs({ (km.view or {}).show_help, (km.sidebar or {}).show_help }) do
    for _, lhs in ipairs(type(spec) == "table" and spec or { spec }) do
      if lhs then
        dismiss[#dismiss + 1] = lhs
      end
    end
  end
  for _, lhs in ipairs(dismiss) do
    pcall(vim.keymap.set, "n", lhs, close, { buffer = buf, nowait = true })
  end
  -- The float is a normal window: leaving it (a click, <C-w>w) should not
  -- strand it on screen with a stale `open_win` pointing at it.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

return M
