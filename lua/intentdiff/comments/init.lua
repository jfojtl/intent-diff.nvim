-- The action layer: everything the keymaps call. Turns a cursor position into
-- a comment, and drives popup → store → marks.
--
-- The pure decision functions (side_for_win, visual_range, next_line,
-- prev_line, list_entries) are separated from the Neovim plumbing so they can
-- be tested without a review tab.
local M = {}

local store = require("intentdiff.comments.store")
local storage = require("intentdiff.comments.storage")
local marks = require("intentdiff.comments.marks")
local popup = require("intentdiff.comments.popup")
local export = require("intentdiff.comments.export")
local config = require("intentdiff.config")

--- Which side of the diff a window shows. Inline layout puts the same window
--- in both roles, and only ever shows the modified file — so "new".
function M.side_for_win(winid, session)
  if not session then
    return "new"
  end
  if session.original_win == winid and session.modified_win ~= winid then
    return "old"
  end
  return "new"
end

--- Normalize a visual selection into (line, line_end). A single-line selection
--- has no end, so it stores as a plain line comment.
--- @return integer first, integer|nil last
function M.visual_range(a, b)
  local first, last = math.min(a, b), math.max(a, b)
  if first == last then
    return first, nil
  end
  return first, last
end

local function line_comments(file, side)
  local out = {}
  for _, c in ipairs(store.get_for_file(file, side)) do
    if (c.line or 0) ~= 0 then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(x, y) return x.line < y.line end)
  return out
end

--- @return integer|nil
function M.next_line(file, from, side)
  for _, c in ipairs(line_comments(file, side)) do
    if c.line > from then
      return c.line
    end
  end
  return nil
end

--- @return integer|nil
function M.prev_line(file, from, side)
  local best
  for _, c in ipairs(line_comments(file, side)) do
    if c.line < from then
      best = c.line
    end
  end
  return best
end

--- One selectable row per comment, for the list picker.
function M.list_entries()
  local out = {}
  for _, c in ipairs(store.get_all()) do
    local first_line = vim.split(c.text or "", "\n")[1] or ""
    local where
    if c.intent_title then
      where = "intent: " .. c.intent_title
    elseif (c.line or 0) == 0 then
      where = c.file
    elseif c.line_end then
      where = ("%s:%d-%d"):format(c.file, c.line, c.line_end)
    else
      where = ("%s:%d"):format(c.file, c.line)
    end
    out[#out + 1] = {
      comment = c,
      label = ("[%s] %s — %s"):format(tostring(c.type):upper(), where, first_line),
    }
  end
  return out
end

--- The intent-diff session entry for a tabpage, via the plugin's own registry.
local function entry_for(tabpage)
  return require("intentdiff")._session(tabpage or vim.api.nvim_get_current_tabpage())
end

--- Current branch of `git_root`, for the storage key of a working-tree review.
local function branch_of(git_root)
  local out = vim.fn.systemlist({ "git", "-C", git_root, "rev-parse", "--abbrev-ref", "HEAD" })[1]
  if vim.v.shell_error ~= 0 or not out or out == "" then
    return nil
  end
  return out
end

--- HEAD's commit hash, for is_worktree's "does base_revision still name HEAD"
--- check.
local function head_hash(git_root)
  local out = vim.fn.systemlist({ "git", "-C", git_root, "rev-parse", "HEAD" })[1]
  if vim.v.shell_error ~= 0 or not out or out == "" then
    return nil
  end
  return out
end

--- A working-tree review keys by BRANCH so it survives new commits; anything
--- pinned to explicit revisions keys by the revision pair.
---
--- init.lua sets base_revision/target_revision unconditionally once a review
--- resolves (base_revision = the resolved base hash, target_revision =
--- target_rev or "WORKING") — so a plain `:IntentDiff` working-tree review
--- ends up with BOTH fields populated, exactly like a `:IntentDiff base
--- target` revision-range review. Keying purely on "are both fields set"
--- would therefore always take the revision-pair branch, keying a
--- working-tree review to the current HEAD hash — the moment the user makes
--- a commit, HEAD moves, the key changes, and the review's comments are
--- orphaned. The distinguishing fact is that target_revision == "WORKING"
--- *and* base_revision still names HEAD (i.e. nothing pinned base away from
--- HEAD); a `:IntentDiff HEAD~1`-style review also has target == "WORKING"
--- but a base that is NOT HEAD, and must key by the revision pair so it stays
--- separate from the plain working-tree review.
local function is_worktree(sess)
  if not sess.base_revision or not sess.target_revision then
    return true
  end
  if sess.target_revision ~= "WORKING" then
    return false
  end
  return sess.base_revision == head_hash(sess.git_root)
end

--- Point the store at this review's storage key and load what it has.
function M.attach_session(entry)
  local sess = entry and entry.sess
  if not (sess and sess.git_root) then
    return
  end
  local key
  if is_worktree(sess) then
    key = storage.key(sess.git_root, nil, nil, branch_of(sess.git_root))
  else
    key = storage.key(sess.git_root, sess.base_revision, sess.target_revision, nil)
  end
  if key then
    store.attach(key)
  end
end

function M.detach_session()
  store.detach()
  store.replace({})
  marks.clear_all()
end

--- What the cursor is pointing at: a line in a pane, or an intent in the
--- sidebar.
--- @return table|nil ctx, string|nil err
function M.context(tabpage, opts)
  opts = opts or {}
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = entry_for(tabpage)
  if not entry then
    return nil, "not in a review tab"
  end
  local win = vim.api.nvim_get_current_win()

  -- Sidebar: an intent comment from a group row, a file comment from a file row.
  if entry.sidebar and entry.sidebar.winid == win then
    local meta = entry.sidebar.meta_at(vim.api.nvim_win_get_cursor(win)[1]) or {}
    local group = entry.model and entry.model.groups and entry.model.groups[meta.group_i]
    if meta.kind == "file" then
      local file = group and group.files and group.files[meta.file_i]
      if file then
        return { file = file.path, line = 0 }
      end
    end
    if group then
      return { intent_title = group.title }
    end
    return nil, "no intent under the cursor"
  end

  -- Diff pane.
  local view = require("intentdiff.view")
  local shown = view._last_shown[tabpage]
  if not (shown and shown.file_entry) then
    return nil, "no file open"
  end
  if view._preview_active[tabpage] then
    return nil, "comments cannot be added in an intent preview"
  end
  local session = view.get_session(tabpage)
  local side = M.side_for_win(win, session)
  local ctx = { file = shown.file_entry.path, side = side }
  if opts.file_level then
    ctx.line = 0
    ctx.side = nil
    return ctx
  end
  if opts.visual then
    local first, last = M.visual_range(
      vim.fn.line("'<"), vim.fn.line("'>"))
    ctx.line, ctx.line_end = first, last
  else
    ctx.line = vim.api.nvim_win_get_cursor(win)[1]
  end
  return ctx
end

local function notify(msg, level)
  vim.notify("intent-diff: " .. msg, level or vim.log.levels.INFO)
end

--- Add a comment at the cursor. `comment_type` nil opens the type picker.
function M.add(tabpage, comment_type, opts)
  local ctx, err = M.context(tabpage, opts)
  if not ctx then
    return notify(err, vim.log.levels.WARN)
  end
  popup.open({ type = comment_type }, function(chosen, text)
    if not (chosen and text) then
      return
    end
    ctx.type = chosen
    ctx.text = text
    local added, add_err = store.add(ctx)
    if not added then
      return notify(add_err, vim.log.levels.WARN)
    end
    marks.refresh(tabpage)
    M.refresh_sidebar(tabpage)
    notify(("added %s comment"):format(chosen))
  end)
end

function M.add_file(tabpage)
  return M.add(tabpage, nil, { file_level = true })
end

--- The comment under the cursor, for edit/delete.
local function at_cursor(tabpage)
  local ctx = M.context(tabpage)
  if not ctx then
    return nil
  end
  if ctx.intent_title then
    return store.get_for_intent(ctx.intent_title)[1]
  end
  if (ctx.line or 0) == 0 then
    for _, c in ipairs(store.get_for_file(ctx.file)) do
      if (c.line or 0) == 0 then
        return c
      end
    end
    return nil
  end
  return store.get_at_line(ctx.file, ctx.line, ctx.side)
end

function M.edit(tabpage)
  local comment = at_cursor(tabpage)
  if not comment then
    return notify("no comment here", vim.log.levels.WARN)
  end
  popup.open({ type = comment.type, text = comment.text }, function(chosen, text)
    if not (chosen and text) then
      return
    end
    store.update(comment, chosen, text)
    marks.refresh(tabpage)
    M.refresh_sidebar(tabpage)
  end)
end

function M.delete(tabpage)
  local comment = at_cursor(tabpage)
  if not comment then
    return notify("no comment here", vim.log.levels.WARN)
  end
  store.delete(comment)
  marks.refresh(tabpage)
  M.refresh_sidebar(tabpage)
  notify("deleted comment")
end

local function jump(tabpage, finder)
  local view = require("intentdiff.view")
  local shown = view._last_shown[tabpage or vim.api.nvim_get_current_tabpage()]
  if not (shown and shown.file_entry) then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local session = view.get_session(tabpage)
  local side = M.side_for_win(win, session)
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local target = finder(shown.file_entry.path, cur, side)
  if not target then
    return notify("no more comments in this file")
  end
  pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
end

function M.next(tabpage)
  jump(tabpage, M.next_line)
end

function M.prev(tabpage)
  jump(tabpage, M.prev_line)
end

function M.list(tabpage)
  local entries = M.list_entries()
  if #entries == 0 then
    return notify("no comments yet")
  end
  vim.ui.select(entries, {
    prompt = "intent-diff comments",
    format_item = function(e) return e.label end,
  }, function(choice)
    if not choice then
      return
    end
    local c = choice.comment
    if c.intent_title or (c.line or 0) == 0 then
      return
    end
    local view = require("intentdiff.view")
    for _, win in ipairs(view.diff_wins(tabpage or vim.api.nvim_get_current_tabpage())) do
      pcall(vim.api.nvim_win_set_cursor, win, { c.line, 0 })
    end
  end)
end

local function model_of(tabpage)
  local entry = entry_for(tabpage)
  return entry and entry.model or { groups = {} }
end

function M.export_clipboard(tabpage)
  export.to_clipboard(store.get_all(), model_of(tabpage))
end

--- Path last used this session, so the prompt is pre-filled with it.
local last_path = nil

function M.export_file(tabpage, path)
  if store.count() == 0 then
    return notify("no comments to export", vim.log.levels.WARN)
  end
  local entry = entry_for(tabpage)
  local root = entry and entry.sess and entry.sess.git_root or vim.fn.getcwd()
  local function write(chosen)
    if not chosen or chosen == "" then
      return
    end
    local abs = chosen:sub(1, 1) == "/" and chosen or (root .. "/" .. chosen)
    local ok, err = export.to_file(store.get_all(), model_of(tabpage), abs)
    if not ok then
      return notify(err, vim.log.levels.ERROR)
    end
    last_path = chosen
    notify(("wrote %d comment(s) to %s"):format(store.count(), abs))
  end
  if path and path ~= "" then
    return write(path)
  end
  local default = last_path or (config.options.comments or {}).export_path or ".intentdiff-review.md"
  vim.ui.input({ prompt = "Write review to: ", default = default }, write)
end

function M.clear(tabpage)
  if store.count() == 0 then
    return notify("no comments to clear")
  end
  local answer = vim.fn.confirm(
    ("Delete all %d comment(s) in this review?"):format(store.count()), "&Yes\n&No", 2)
  if answer ~= 1 then
    return
  end
  store.clear()
  marks.clear_all()
  marks.refresh(tabpage)
  M.refresh_sidebar(tabpage)
  notify("cleared all comments")
end

--- Copy the Markdown, then close the review tab. The review.nvim end-of-review
--- flow. Closes even with no comments — refusing to close would be worse than
--- an empty export.
function M.export_and_close(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  if store.count() > 0 then
    M.export_clipboard(tabpage)
  else
    notify("no comments to export")
  end
  require("intentdiff").close(tabpage)
end

--- Re-sign the sidebar's group rows. The row list comes from the sidebar
--- handle, which knows its own layout.
function M.refresh_sidebar(tabpage)
  local entry = entry_for(tabpage)
  if entry and entry.sidebar and entry.sidebar.comment_rows then
    marks.render_sidebar(entry.sidebar.bufnr, entry.sidebar.comment_rows())
  end
end

return M
