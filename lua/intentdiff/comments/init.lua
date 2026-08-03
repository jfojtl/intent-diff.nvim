-- The action layer: everything the keymaps call. Turns a cursor position into
-- a comment, and drives popup → store → marks.
--
-- Every review session owns its own store (`entry.comment_store`, created by
-- attach_session), so two review tabs never see each other's comments and
-- never write under each other's storage key. The keymaps already pass the
-- tabpage they were installed for; `store_for` turns that into the right
-- store via the plugin's own session registry, which is the one lookup that
-- keeps working when codediff moves a session's tabpage under us.
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

local function line_comments(st, file, side)
  local out = {}
  for _, c in ipairs(st.get_for_file(file, side)) do
    if (c.line or 0) ~= 0 then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(x, y) return x.line < y.line end)
  return out
end

--- @return integer|nil
function M.next_line(st, file, from, side)
  for _, c in ipairs(line_comments(st, file, side)) do
    if c.line > from then
      return c.line
    end
  end
  return nil
end

--- @return integer|nil
function M.prev_line(st, file, from, side)
  local best
  for _, c in ipairs(line_comments(st, file, side)) do
    if c.line < from then
      best = c.line
    end
  end
  return best
end

--- Human-readable label for one comment: `[TYPE] where — first text line`.
--- Shared by the list picker (`list_entries`, every comment in the review)
--- and the intent-disambiguation picker (`at_cursor`, comments within ONE
--- intent) so the two read alike.
local function label_for(c)
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
  return ("[%s] %s — %s"):format(tostring(c.type):upper(), where, first_line)
end

--- One selectable row per comment, for the list picker.
function M.list_entries(st)
  local out = {}
  for _, c in ipairs(st.get_all()) do
    out[#out + 1] = { comment = c, label = label_for(c) }
  end
  return out
end

--- The intent-diff session entry for a tabpage, via the plugin's own registry.
local function entry_for(tabpage)
  return require("intentdiff")._session(tabpage or vim.api.nvim_get_current_tabpage())
end

--- The comment store of the review shown in `tabpage`, or nil when that tab is
--- not a review tab, its review has been torn down, or comments are disabled
--- (in which case attach_session never ran and no store was ever created — so
--- `comments.enabled = false` stays a genuine no-op here too).
---
--- Not written as `entry and entry.comment_store or nil`: `and/or` collapses a
--- legitimately-nil middle term, and this codebase has already paid for that
--- idiom three times.
--- @return table|nil
function M.store_for(tabpage)
  local entry = entry_for(tabpage)
  if not entry then
    return nil
  end
  return entry.comment_store
end

--- `git -C git_root <...>`'s first output line, or nil on any failure —
--- including `git` not being executable at all. `vim.fn.systemlist` throws
--- (E475) rather than returning an error value when the argv[0] executable
--- cannot be found, so this must be pcall'd like every other Neovim API call
--- that can fail on the user's environment, not just checked via
--- vim.v.shell_error.
--- @return string|nil
local function git_rev(git_root, ...)
  local ok, out = pcall(vim.fn.systemlist, { "git", "-C", git_root, ... })
  if not ok or vim.v.shell_error ~= 0 then
    return nil
  end
  local first = out and out[1]
  if not first or first == "" then
    return nil
  end
  return first
end

--- Current branch of `git_root`, for the storage key of a working-tree review.
local function branch_of(git_root)
  return git_rev(git_root, "rev-parse", "--abbrev-ref", "HEAD")
end

--- HEAD's commit hash, for is_worktree's "does base_revision still name HEAD"
--- check.
local function head_hash(git_root)
  return git_rev(git_root, "rev-parse", "HEAD")
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

--- Give this review its OWN store, pointed at this review's storage key, and
--- load what that key has. The store hangs off the session entry, so it lives
--- and dies with the session and is reachable from any tabpage lookup — two
--- concurrent reviews get two stores and two keys.
---
--- Called after init.lua assigns base_revision/target_revision, because
--- is_worktree reads exactly those two fields.
--- @return table|nil store
function M.attach_session(entry)
  local sess = entry and entry.sess
  if not (sess and sess.git_root) then
    return nil
  end
  local st = store.new()
  entry.comment_store = st
  local key
  if is_worktree(sess) then
    key = storage.key(sess.git_root, nil, nil, branch_of(sess.git_root))
  else
    key = storage.key(sess.git_root, sess.base_revision, sess.target_revision, nil)
  end
  -- No derivable key: a working-tree review whose branch cannot be read at all
  -- (git not executable, or git_root not actually a repository) — the review
  -- still takes comments, they just do not persist. A detached HEAD is NOT one
  -- of those cases: `git rev-parse --abbrev-ref HEAD` answers the literal
  -- "HEAD", which is a non-empty branch name, so storage.key does return a key
  -- and such a review DOES persist — with every detached-HEAD working-tree
  -- review of that repo sharing the one key.
  if key then
    st.attach(key)
  end
  return st
end

--- Tear down ONE review's comments: stop persisting, drop the store, and wipe
--- the extmarks THIS review drew — in the buffers it drew them in. Takes the
--- entry rather than a tabpage because init.lua's forget_entry has already
--- removed the session from the registry by the time it calls this.
function M.detach_session(entry)
  local st = entry and entry.comment_store
  if not st then
    return
  end
  entry.comment_store = nil
  st.detach()
  marks.clear_for(st)
end

--- Refusals for the whole-intent preview. Both name the fix, not just the
--- failure: a row that shows no line of any file cannot carry a comment, and a
--- comment records ONE file.
local NOT_A_LINE =
  "nothing to comment on here — put the cursor on an added, removed or context "
  .. "line (file separators, @@ headers and filler rows show no line)"
local SPANS_FILES =
  "a comment records one file — select lines inside a single file's diff"
local NOT_A_PREVIEW_PANE =
  "put the cursor in the intent preview to comment on it"

--- What the cursor is pointing at inside a live whole-intent preview.
---
--- The preview is a COORDINATE SYSTEM, never a storage concept: this returns
--- exactly the ctx shape the file-diff branch returns — { file, side, line,
--- line_end? } — so the record that reaches the store is indistinguishable
--- from one made in that file's own diff. `side` comes from the render's map,
--- NOT from `side_for_win`: in a preview both windows hold scratch buffers of
--- ours, so window identity says nothing, and in the inline layout the two
--- sides are interleaved inside one buffer.
---
--- A visual range resolves through the rows it actually covers, so an
--- unaddressed row inside it (a separator, a filler) is skipped rather than
--- refusing a selection that is otherwise fine — but a range covering rows of
--- TWO files refuses, because no single record can express it. Its side is the
--- side of its first addressed row; in the inline layout, where one buffer
--- interleaves both sides, that is what keeps a `-`-first selection an
--- old-side range and a context/`+`-first one a new-side range.
--- @return table|nil ctx, string|nil err
local function preview_context(tabpage, win, opts)
  local view = require("intentdiff.view")
  local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, win)
  if not ok_buf then
    return nil, NOT_A_PREVIEW_PANE
  end
  local pane = view.preview_pane_for_buf(tabpage, bufnr)
  if not pane then
    return nil, NOT_A_PREVIEW_PANE
  end

  local first_row, last_row
  if opts.visual then
    local mark_start, mark_end = vim.fn.line("'<"), vim.fn.line("'>")
    -- An unset visual mark reports line 0; see the file-diff branch below.
    if mark_start == 0 or mark_end == 0 then
      return nil, "no visual selection"
    end
    local a, b = M.visual_range(mark_start, mark_end)
    first_row, last_row = a, b or a
  else
    first_row = vim.api.nvim_win_get_cursor(win)[1]
    last_row = first_row
  end

  local preview = require("intentdiff.preview")
  local targets = {}
  for row = first_row, last_row do
    local t = preview.target_at(pane, row)
    if t then
      targets[#targets + 1] = t
    end
  end
  if #targets == 0 then
    return nil, NOT_A_LINE
  end
  local file = targets[1].file
  for _, t in ipairs(targets) do
    if t.file ~= file then
      return nil, SPANS_FILES
    end
  end
  if opts.file_level then
    return { file = file, line = 0 }
  end
  local side = targets[1].side
  local first, last
  for _, t in ipairs(targets) do
    if t.side == side then
      if not first or t.line < first then first = t.line end
      if not last or t.line > last then last = t.line end
    end
  end
  local ctx = { file = file, side = side, line = first }
  if last > first then
    ctx.line_end = last
  end
  return ctx
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

  -- Whole-intent preview. Resolved BEFORE the `_last_shown` check: a preview
  -- can own the panes before any file has ever been selected in the tab, and
  -- `_last_shown` names the last file rendered, which is not what a preview
  -- displays.
  local view = require("intentdiff.view")
  if view._preview_active[tabpage] then
    return preview_context(tabpage, win, opts)
  end

  -- Diff pane.
  local shown = view._last_shown[tabpage]
  if not (shown and shown.file_entry) then
    return nil, "no file open"
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
    local mark_start, mark_end = vim.fn.line("'<"), vim.fn.line("'>")
    -- An unset visual mark reports line 0 (not the cursor line, not an
    -- error). Taking that at face value falls straight into visual_range and
    -- produces line = 0 — silently creating a FILE-LEVEL comment instead of a
    -- line comment. Refuse instead: there is no selection to record.
    if mark_start == 0 or mark_end == 0 then
      return nil, "no visual selection"
    end
    local first, last = M.visual_range(mark_start, mark_end)
    ctx.line, ctx.line_end = first, last
  else
    ctx.line = vim.api.nvim_win_get_cursor(win)[1]
  end
  return ctx
end

local function notify(msg, level)
  vim.notify("intent-diff: " .. msg, level or vim.log.levels.INFO)
end

--- Every action needs the review's store; there is no global one to fall back
--- on, and inventing one would be the singleton again. A tab with no store is
--- one that is not a review tab, whose review has been torn down, or whose
--- review has not attached yet (comments are attached the moment the revisions
--- resolve, just before the first render).
local NO_STORE = "no comments available in this tab"

--- Add a comment at the cursor. `comment_type` nil opens the type picker.
function M.add(tabpage, comment_type, opts)
  -- Context first: it gives the precise reason ("no file open", "comments
  -- cannot be added in an intent preview") where there is one.
  local ctx, err = M.context(tabpage, opts)
  if not ctx then
    return notify(err, vim.log.levels.WARN)
  end
  local st = M.store_for(tabpage)
  if not st then
    return notify(NO_STORE, vim.log.levels.WARN)
  end
  popup.open({ type = comment_type }, function(chosen, text)
    if not (chosen and text) then
      return
    end
    ctx.type = chosen
    ctx.text = text
    local added, add_err = st.add(ctx)
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

--- The buffer the cursor is in, or nil. The same window `M.context` read the
--- cursor line from, so a clamped lookup measures against exactly the buffer
--- the user is looking at.
--- @return integer|nil
local function current_buf()
  local ok, bufnr = pcall(vim.api.nvim_win_get_buf, vim.api.nvim_get_current_win())
  if not ok then
    return nil
  end
  return bufnr
end

--- The comment whose RENDERED box covers `line` in `bufnr` — the fallback for
--- a comment that drifted past the end of the buffer.
---
--- `store.get_at_line` matches on the RAW stored line, while `marks` clamps a
--- past-EOF comment onto the buffer's last line so it stays visible. Without
--- this, a comment stored at line 500 of a file that is now 5 lines long draws
--- a box the user can see and reports "no comment here" for every edit/delete
--- on it — visible, but unreachable. The clamp is `marks.clamped_span_in_buf`,
--- the very function the renderer places the box with, so the two answers
--- cannot disagree.
--- @return intentdiff.Comment|nil
local function drifted_at_line(st, ctx, bufnr)
  local line = ctx.line
  if not (bufnr and line) then
    return nil
  end
  for _, c in ipairs(st.get_for_file(ctx.file, ctx.side)) do
    -- File-level comments hang above line 1 and address no line at all.
    if (c.line or 0) ~= 0 then
      local first, final = marks.clamped_span_in_buf(c, bufnr)
      if first and line >= first and line <= final then
        return c
      end
    end
  end
  return nil
end

--- The comment under the cursor, for edit/delete. Calls `cb(comment|nil)` —
--- an intent can carry SEVERAL comments (the design spec's "a group can have
--- several; they are emitted in creation order"), and disambiguating among
--- them needs a `vim.ui.select` round-trip, so this resolves asynchronously
--- even though every other branch answers synchronously (cb is still called
--- before returning in those cases). A file-level comment never needs
--- disambiguation: `store.collides` enforces exactly one per file.
local function at_cursor(tabpage, st, cb)
  -- Resolved here, not left nil for M.context to default internally: the
  -- preview check below reads a per-tabpage table with it.
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local ctx = M.context(tabpage)
  if not ctx then
    return cb(nil)
  end
  if ctx.intent_title then
    local candidates = st.get_for_intent(ctx.intent_title)
    if #candidates == 0 then
      return cb(nil)
    end
    if #candidates == 1 then
      return cb(candidates[1])
    end
    local entries = {}
    for _, c in ipairs(candidates) do
      entries[#entries + 1] = { comment = c, label = label_for(c) }
    end
    return vim.ui.select(entries, {
      prompt = "intent-diff: which comment?",
      format_item = function(e) return e.label end,
    }, function(choice)
      cb(choice and choice.comment or nil)
    end)
  end
  if (ctx.line or 0) == 0 then
    for _, c in ipairs(st.get_for_file(ctx.file)) do
      if (c.line or 0) == 0 then
        return cb(c)
      end
    end
    return cb(nil)
  end
  local found = st.get_at_line(ctx.file, ctx.line, ctx.side)
  -- The drifted fallback measures a comment against the BUFFER's line count,
  -- which only means anything when the buffer IS the file. A preview buffer is
  -- a render of many files, so clamping there would match a comment stored at
  -- line 500 onto whatever the preview's last row happens to be — the "checks
  -- one thing, acts on another" failure this fallback was written to fix, in
  -- mirror image. A preview simply does not draw a comment whose lines it does
  -- not show, so there is nothing there to reach.
  if not found and not require("intentdiff.view")._preview_active[tabpage] then
    found = drifted_at_line(st, ctx, current_buf())
  end
  return cb(found)
end

function M.edit(tabpage)
  local st = M.store_for(tabpage)
  if not st then
    return notify(NO_STORE, vim.log.levels.WARN)
  end
  at_cursor(tabpage, st, function(comment)
    if not comment then
      return notify("no comment here", vim.log.levels.WARN)
    end
    popup.open({ type = comment.type, text = comment.text }, function(chosen, text)
      if not (chosen and text) then
        return
      end
      st.update(comment, chosen, text)
      marks.refresh(tabpage)
      M.refresh_sidebar(tabpage)
    end)
  end)
end

function M.delete(tabpage)
  local st = M.store_for(tabpage)
  if not st then
    return notify(NO_STORE, vim.log.levels.WARN)
  end
  at_cursor(tabpage, st, function(comment)
    if not comment then
      return notify("no comment here", vim.log.levels.WARN)
    end
    st.delete(comment)
    marks.refresh(tabpage)
    M.refresh_sidebar(tabpage)
    notify("deleted comment")
  end)
end

--- Is `win` one of this review's diff panes? `]n`/`[n` are installed on the
--- SIDEBAR as well (every comment key is, so the export keys are reachable from
--- either surface), and a sidebar row number is not a diff line — jumping on it
--- moved the sidebar cursor to an arbitrary row, which with
--- `preview.hover_opens_files` on then re-rendered the panes to whatever intent
--- that row belongs to.
local function in_diff_pane(tabpage, win)
  for _, w in ipairs(require("intentdiff.view").diff_wins(tabpage)) do
    if w == win then
      return true
    end
  end
  return false
end

local function jump(tabpage, finder)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local st = M.store_for(tabpage)
  if not st then
    return
  end
  local view = require("intentdiff.view")
  local shown = view._last_shown[tabpage]
  if not (shown and shown.file_entry) then
    return
  end
  -- The two guards every sibling checks: a preview buffer concatenates many
  -- files (M.list, M.context and marks.refresh all refuse there), and the
  -- comment keys reach surfaces that are not diff panes at all.
  if view._preview_active[tabpage] then
    return notify("comments are not shown in an intent preview", vim.log.levels.WARN)
  end
  local win = vim.api.nvim_get_current_win()
  if not in_diff_pane(tabpage, win) then
    return notify("comment navigation only works in a diff pane", vim.log.levels.WARN)
  end
  local session = view.get_session(tabpage)
  local side = M.side_for_win(win, session)
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local target = finder(st, shown.file_entry.path, cur, side)
  if not target then
    return notify("no more comments in this file")
  end
  -- A comment that outlived its lines is RENDERED on the last line (marks
  -- clamps it there); its stored line can be far past EOF, and
  -- nvim_win_set_cursor to a line that does not exist fails — silently, since
  -- it is pcall'd — so `]n` did nothing at all, not even the "no more
  -- comments" notice. Land on the box where it is actually drawn instead.
  local line = target
  local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, win)
  if ok_buf then
    local first = marks.clamped_span_in_buf({ line = target }, bufnr)
    if first then
      line = first
    end
  end
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
end

function M.next(tabpage)
  jump(tabpage, M.next_line)
end

function M.prev(tabpage)
  jump(tabpage, M.prev_line)
end

--- Put the cursor on `c`'s line, in every pane of `tabpage` showing `c`'s side.
---
--- An old-side comment's line number only addresses a row of the ORIGINAL
--- pane; jumping it into the modified pane too would land on an unrelated line
--- that merely shares the same number. `zv` afterwards opens just enough of
--- the group fold filter for the line — and the comment box hanging off it —
--- to be visible, instead of leaving the cursor buried in a closed fold.
local function place_cursor(tabpage, c)
  local view = require("intentdiff.view")
  local session = view.get_session(tabpage)
  for _, win in ipairs(view.diff_wins(tabpage)) do
    if (c.side or "new") == M.side_for_win(win, session) then
      -- Clamped per window, exactly as marks draws the box: a comment whose
      -- line outlived the file renders on the last line, and a cursor move to
      -- its raw line simply fails (pcall'd, so silently) — the picker would
      -- appear to do nothing.
      local line = c.line
      local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, win)
      if ok_buf then
        local first = marks.clamped_span_in_buf(c, bufnr)
        if first then
          line = first
        end
      end
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("normal! zv")
      end)
    end
  end
end

--- Show every comment in the review; picking one jumps the cursor to it,
--- opening its file first when that file is not the one on screen.
---
--- Opening goes through `intentdiff.open_path` — the same select_file/open_file
--- route the sidebar's <CR> takes — so the file arrives folded to its intent
--- before the cursor is placed. Jumping straight to `c.line` in whatever
--- happens to be on screen would land on the wrong line of the WRONG file, so
--- when the review has no such file to open this still refuses rather than
--- guessing.
function M.list(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local st = M.store_for(tabpage)
  if not st then
    return notify(NO_STORE, vim.log.levels.WARN)
  end
  local entries = M.list_entries(st)
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
    -- An intent comment lives on a sidebar row and a file-level comment hangs
    -- above line 1: neither addresses a line to jump to.
    if c.intent_title or (c.line or 0) == 0 then
      return
    end
    -- `_last_shown` names the last file RENDERED, which is not the same thing
    -- as what the panes currently DISPLAY: a hover preview swaps its own
    -- buffers in without touching it (view.show_preview), so during a preview
    -- _last_shown still names the pre-preview file while the panes hold a
    -- concatenation of a whole intent's files. Jumping to `c.line` there lands
    -- on an arbitrary line of an unrelated file — the exact wrong-file hazard
    -- this function refuses to take elsewhere. Treat a live preview as "not
    -- shown" so it falls through to open_path, which re-renders the real file
    -- first. marks.refresh and M.context guard on the same flag.
    local view = require("intentdiff.view")
    local shown = view._last_shown[tabpage]
    if shown and shown.file_entry and shown.file_entry.path == c.file
        and not view._preview_active[tabpage] then
      return place_cursor(tabpage, c)
    end
    local opened = require("intentdiff").open_path(tabpage, c.file, function()
      place_cursor(tabpage, c)
    end)
    if not opened then
      notify(("comment is in %s, which this review does not show"):format(c.file),
        vim.log.levels.WARN)
    end
  end)
end

local function model_of(tabpage)
  local entry = entry_for(tabpage)
  return entry and entry.model or { groups = {} }
end

function M.export_clipboard(tabpage)
  local st = M.store_for(tabpage)
  if not st then
    return notify(NO_STORE, vim.log.levels.WARN)
  end
  export.to_clipboard(st.get_all(), model_of(tabpage))
end

--- Path last used this session, so the prompt is pre-filled with it.
local last_path = nil

function M.export_file(tabpage, path)
  local st = M.store_for(tabpage)
  if not st then
    return notify(NO_STORE, vim.log.levels.WARN)
  end
  if st.count() == 0 then
    return notify("no comments to export", vim.log.levels.WARN)
  end
  local entry = entry_for(tabpage)
  local root = entry and entry.sess and entry.sess.git_root or vim.fn.getcwd()
  local function write(chosen)
    if not chosen or chosen == "" then
      return
    end
    -- expand() resolves "~/…" (and $VAR-style env references) before the
    -- absolute/relative check below — without it, "~/review.md" is treated
    -- as a literal relative path and creates a directory named "~" under the
    -- git root instead of writing under the user's home.
    local expanded = vim.fn.expand(chosen)
    local abs = expanded:sub(1, 1) == "/" and expanded or (root .. "/" .. expanded)
    local ok, err = export.to_file(st.get_all(), model_of(tabpage), abs)
    if not ok then
      return notify(err, vim.log.levels.ERROR)
    end
    last_path = chosen
    notify(("wrote %d comment(s) to %s"):format(st.count(), abs))
  end
  if path and path ~= "" then
    return write(path)
  end
  local default = last_path or (config.options.comments or {}).export_path or ".intentdiff-review.md"
  vim.ui.input({ prompt = "Write review to: ", default = default }, write)
end

function M.clear(tabpage)
  local st = M.store_for(tabpage)
  if not st then
    return notify(NO_STORE, vim.log.levels.WARN)
  end
  if st.count() == 0 then
    return notify("no comments to clear")
  end
  local answer = vim.fn.confirm(
    ("Delete all %d comment(s) in this review?"):format(st.count()), "&Yes\n&No", 2)
  if answer ~= 1 then
    return
  end
  st.clear()
  -- Only THIS review's marks: clear_all() used to blank a second review tab's
  -- boxes as well.
  marks.clear_for(st)
  marks.refresh(tabpage)
  M.refresh_sidebar(tabpage)
  notify("cleared all comments")
end

--- Copy the Markdown, then close the review tab. The review.nvim end-of-review
--- flow. Closes even with no comments — refusing to close would be worse than
--- an empty export.
function M.export_and_close(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local st = M.store_for(tabpage)
  -- No store (comments disabled, or a review that never attached) still
  -- closes: refusing to close would be worse than a missing export.
  if st and st.count() > 0 then
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
  if entry and entry.comment_store and entry.sidebar and entry.sidebar.comment_rows then
    marks.render_sidebar(entry.comment_store, entry.sidebar.bufnr, entry.sidebar.comment_rows())
  end
end

return M
