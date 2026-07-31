-- The ONLY module allowed to require codediff internals. Everything is
-- pcall-guarded; on any mismatch the plugin degrades instead of erroring.
local M = {}

M.available = false
local cd = {} -- loaded codediff modules

local function try(name)
  local ok, mod = pcall(require, name)
  return ok and mod or nil
end

--- Load and verify codediff internals. Call once at :IntentDiff time.
function M.load()
  cd.view = try("codediff.ui.view")
  cd.compact = try("codediff.ui.view.compact")
  cd.lifecycle = try("codediff.ui.lifecycle")
  cd.git = try("codediff.core.git")
  cd.path = try("codediff.core.path")
  cd.side_by_side = try("codediff.ui.view.side_by_side")
  cd.inline_view = try("codediff.ui.view.inline_view")
  M.available = cd.view ~= nil
    and type(cd.view.create) == "function"
    and type(cd.view.update) == "function"
    and type(cd.view.toggle_layout) == "function"
    and cd.compact ~= nil
    and type(cd.compact.compute_visible_lines) == "function"
    and cd.lifecycle ~= nil
    and type(cd.lifecycle.get_session) == "function"
    and type(cd.lifecycle.update_buffers) == "function"
    and type(cd.lifecycle.update_paths) == "function"
    and type(cd.lifecycle.update_revisions) == "function"
    and type(cd.lifecycle.update_diff_result) == "function"
    and cd.git ~= nil
    and cd.path ~= nil
    and type(cd.path.make_ref) == "function"
    and type(cd.path.empty) == "function"
    and cd.side_by_side ~= nil
    and type(cd.side_by_side.show_untracked_file) == "function"
    and type(cd.side_by_side.show_added_virtual_file) == "function"
    and type(cd.side_by_side.show_deleted_virtual_file) == "function"
    and cd.inline_view ~= nil
    and type(cd.inline_view.show_single_file) == "function"
  if not M.available then
    vim.notify("intent-diff: codediff API mismatch — grouped view disabled", vim.log.levels.ERROR)
  end
  return M.available
end

function M.git()
  return cd.git
end

-- ---------------------------------------------------------------- folds ----

local visible_by_win = {}

-- Forward-declared: M.cleanup_tab_state (defined below, well before this is
-- assigned) also calls it, so it must be an upvalue in scope from the top of
-- the file rather than a `local function` declared at its point of use.
local retire_preview_bufs

--- `{ hunks, context }` currently applied per tabpage via M.apply_group_folds,
--- so the TabEnter handler below can re-assert them with the same context
--- override. Set on success in apply_group_folds, cleared in M.close_tab.
M._active_folds = {}

--- Last { sess, file_entry } rendered per tabpage. Two uses:
---   * M.toggle_layout needs to know WHICH file to re-render after codediff
---     has flipped the layout (codediff's own rerender path is explorer-only
---     and we deliberately register no explorer — see M.toggle_layout);
---   * the TabEnter re-assert below uses it as the "this is an intent-diff
---     tab" marker, so it also fires for whole-file statuses that never
---     applied group folds.
M._last_shown = {}

--- Group currently previewed per tabpage, or nil. Set by M.show_preview and
--- cleared by M.show_file — i.e. by whatever actually puts a real file back in
--- the panes, including but not limited to M.restore. The TabEnter re-assert
--- and M.apply_group_folds both consult it: preview buffers must never be
--- folded to a group filter, and a value left behind after the preview is gone
--- disables both of those permanently for the tab.
M._preview_active = {}

--- The session behind each tabpage's active preview, so the preview's own
--- keymaps (which only capture a tabpage) can restore and re-render.
M._preview_sess = {}

local folds_augroup

--- codediff's own session TabEnter autocmd (codediff/ui/lifecycle/session.lua)
--- calls `vim.schedule(reapply_keymaps)`, which ends by calling
--- `compact.refresh(tabpage)` — when the user has `diff.compact = true` this
--- re-applies codediff's *all-hunks* compact fold, clobbering our
--- group-filtered foldexpr/visible lines. Re-assert our folds after that runs.
---
--- We can't rely on autocmd registration order alone to guarantee we run
--- after codediff's handler (a later :IntentDiff session could register
--- codediff's per-tab TabEnter autocmd after this augroup already exists), so
--- we defer two ticks (nested vim.schedule): codediff's handler's own
--- vim.schedule callback always lands on the first tick after TabEnter fires,
--- so scheduling ours from within a first-tick callback guarantees ours runs
--- on a later tick, deterministically after.
---
--- The same TabEnter tick is also where our buffer-local keymaps have to be
--- reinstalled: codediff's TabLeave handler runs
--- `lifecycle.clear_tab_keymaps` (ui/lifecycle/accessors.lua), which deletes
--- EVERY buffer-local mapping whose lhs appears in codediff's
--- `keymaps.view` table from the pane buffers — including the group-scoped
--- ]c/[c that intentdiff.navigation installed and our `t` override — and its
--- TabEnter handler then reinstalls codediff's own versions. So re-entering
--- the tab silently downgraded ]c/[c to codediff's all-hunks navigation and
--- `t` to codediff's explorer-only toggle. Re-assert both here.
local function reassert(tab)
  if M._preview_active[tab] then
    return -- preview buffers carry no group folds
  end
  local active = M._active_folds[tab]
  if active then
    M.apply_group_folds(tab, active.hunks, { context = active.context })
  end
  M.install_keymaps(tab)
  require("intentdiff.navigation").reattach_keymaps(tab)
end

local function ensure_folds_augroup()
  if folds_augroup then
    return
  end
  folds_augroup = vim.api.nvim_create_augroup("IntentDiffFolds", { clear = true })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = folds_augroup,
    callback = function()
      local tab = vim.api.nvim_get_current_tabpage()
      if not (M._active_folds[tab] or M._last_shown[tab]) then
        return -- inert for tabs intent-diff never rendered into
      end
      vim.schedule(function()
        vim.schedule(function()
          if vim.api.nvim_get_current_tabpage() == tab
              and (M._active_folds[tab] or M._last_shown[tab]) then
            reassert(tab)
          end
        end)
      end)
    end,
  })
end

function M.foldexpr()
  local visible = visible_by_win[vim.api.nvim_get_current_win()]
  if not visible then
    return "0"
  end
  return visible[vim.v.lnum] and "0" or "1"
end

--- Re-render the comment marks of `tabpage` after a pane rebuild. Every event
--- that replaces or refolds a pane buffer goes through here: extmarks live on
--- the buffer, so a fresh buffer (or a re-fold that changes what is visible)
--- loses them.
---
--- No-op when comments are disabled, and pcall'd: a failure to draw a comment
--- box must never break the render it is hanging off.
local function refresh_comments(tabpage)
  if (require("intentdiff.config").options.comments or {}).enabled == false then
    return
  end
  pcall(function()
    require("intentdiff.comments.marks").refresh(tabpage)
  end)
end

local function context_lines()
  local ours = require("intentdiff.config").options.context_lines
  if ours then
    return ours
  end
  local cd_config = try("codediff.config")
  return cd_config and cd_config.options.diff.compact_context_lines or 3
end

--- The panes group folds apply to. Mirrors codediff's own
--- ui/view/compact.lua `pane_entries`: in inline layout there is a single
--- window showing the MODIFIED buffer (deleted lines are virtual lines, so
--- real buffer line numbers are modified-side line numbers), and
--- session.original_win == session.modified_win. Folding it twice — once with
--- original-side ranges, once with modified-side — would leave whichever ran
--- last in `visible_by_win`; be explicit instead.
local function pane_entries(session)
  if session.layout == "inline" or session.original_win == session.modified_win then
    return { { win = session.modified_win, buf = session.modified_bufnr, side = "modified" } }
  end
  return {
    { win = session.original_win, buf = session.original_bufnr, side = "original" },
    { win = session.modified_win, buf = session.modified_bufnr, side = "modified" },
  }
end

--- Fold everything except `hunks`' ranges (+context) in both panes.
---
--- opts.context overrides the usual context_lines() amount. Whole-file
--- additions (see M.show_file) pass 0: their sub-hunks (hunks.split_added)
--- are adjacent partitions of one continuous addition with no real code
--- between them, so codediff's normal context-lines padding would bleed a
--- few lines of the NEXT (unowned) sub-hunk into view — unlike modified-file
--- hunks, where that padding is genuine surrounding code.
---
--- Refuses to do anything while a hover preview owns the panes: preview
--- buffers are our own scratch render of a WHOLE intent (many files, with
--- separators and filler lines), not the file these `hunks` line numbers were
--- computed against, so a foldexpr built from them folds arbitrary preview
--- content away — measured 10 of 14 lines closed. The guard lives here rather
--- than in each caller because the callers are many and growing (M.show_file,
--- M.toggle_layout, `reassert`, and two separate paths in init.lua's
--- classification-completion handler), and every one of them wants the same
--- answer. `reassert` keeps its own earlier return as well, for a different
--- reason: it must also skip re-installing the non-preview pane keymaps over
--- the preview's own.
--- @return boolean whether folds were applied
function M.apply_group_folds(tabpage, hunks, opts)
  opts = opts or {}
  ensure_folds_augroup()
  if M._preview_active[tabpage] then
    return false
  end
  local session = cd.lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end
  local changes = {}
  for i, h in ipairs(hunks) do
    changes[i] = { original = h.original, modified = h.modified }
  end
  local ctx = opts.context or context_lines()
  -- Layout toggles close panes; drop their stale visible-line sets so
  -- foldexpr never answers for a recycled window id.
  for win in pairs(visible_by_win) do
    if not vim.api.nvim_win_is_valid(win) then
      visible_by_win[win] = nil
    end
  end
  for _, pane in ipairs(pane_entries(session)) do
    if pane.win and vim.api.nvim_win_is_valid(pane.win)
        and pane.buf and vim.api.nvim_buf_is_valid(pane.buf) then
      local line_count = vim.api.nvim_buf_line_count(pane.buf)
      visible_by_win[pane.win] =
        cd.compact.compute_visible_lines(changes, pane.side, line_count, ctx)
      vim.wo[pane.win].foldmethod = "expr"
      vim.wo[pane.win].foldexpr = "v:lua.require'intentdiff.view'.foldexpr()"
      vim.wo[pane.win].foldlevel = 0
      vim.wo[pane.win].foldminlines = 0
      vim.wo[pane.win].foldenable = true
    end
  end
  M._active_folds[tabpage] = { hunks = hunks, context = opts.context }
  refresh_comments(tabpage)
  return true
end

-- ----------------------------------------------------------- view driving --

--- Poll until codediff has the diff for `abs_path` ready in `tabpage`.
local function when_diff_ready(tabpage, abs_path, cb, tries)
  tries = tries or 0
  local session = cd.lifecycle.get_session(tabpage)
  if session and session.stored_diff_result
      and ((session.modified and session.modified.absolute == abs_path)
        or (session.original and session.original.absolute == abs_path)) then
    return cb()
  end
  if tries > 60 then
    return -- give up after ~3s; folds simply not applied
  end
  vim.defer_fn(function()
    when_diff_ready(tabpage, abs_path, cb, tries + 1)
  end, 50)
end

function M.open_tab()
  vim.cmd("tabnew")
  return vim.api.nvim_get_current_tabpage()
end

--- Forget every piece of per-tab state we keep for `tabpage`. Called from
--- M.close_tab and from init.lua's TabClosed handler (a tab closed behind our
--- back, e.g. `:tabclose` in the review tab).
function M.cleanup_tab_state(tabpage)
  M._active_folds[tabpage] = nil
  M._last_shown[tabpage] = nil
  M._preview_active[tabpage] = nil
  M._preview_sess[tabpage] = nil
  if M._preview_bufs[tabpage] then
    retire_preview_bufs(M._preview_bufs[tabpage])
    M._preview_bufs[tabpage] = nil
  end
  for win in pairs(visible_by_win) do
    if not vim.api.nvim_win_is_valid(win) then
      visible_by_win[win] = nil
    end
  end
end

function M.close_tab(sess)
  M.cleanup_tab_state(sess.tabpage)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab == sess.tabpage then
      -- `tabclose` on the last tab is an error ("cannot close last tab
      -- page") — the session tab would stay open with a half-torn-down
      -- session. Open a scratch tab to land on first, exactly like
      -- codediff's own ui/lifecycle/cleanup.lua close() does.
      if #vim.api.nvim_list_tabpages() == 1 then
        vim.cmd("tabnew")
      end
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose")
      return
    end
  end
end

--- Create the codediff session for `sess` and adopt the tab codediff opened.
---
--- codediff.ui.view.create() always opens its own tab (`tabnew`) rather than
--- rendering into the current one. Bootstrapping the session FIRST — with the
--- empty-Path explorer placeholder config codediff's own :CodeDiff explorer
--- entry point uses (commands.lua) — means the real review tab exists before
--- anything else is put in it, so the sidebar can be created INSIDE it and
--- every later file selection is a plain cd.view.update() into an existing
--- session. The alternative (create the view lazily on the first file
--- selection) had to close the pre-opened placeholder tab, which destroyed
--- the sidebar living in it.
---
--- If `sess.tabpage` is already set (a placeholder from M.open_tab), its
--- windows are closed once codediff's tab is up.
--- @return integer|nil tabpage the codediff session lives in
function M.bootstrap(sess)
  local placeholder = sess.tabpage
  cd.view.create({
    mode = "explorer", -- empty Paths ⇒ codediff's explorer placeholder branch
    git_root = sess.git_root,
    original = cd.path.empty(),
    modified = cd.path.empty(),
  }, "", nil)
  local tab = vim.api.nvim_get_current_tabpage()
  local session = cd.lifecycle.get_session(tab)
  if not session then
    return nil -- codediff failed to register a session; caller degrades
  end
  -- The session had to be CREATED as mode="explorer" (that is the branch that
  -- accepts empty Paths and builds placeholder panes), but from here on it
  -- behaves like a standalone session that keeps being pointed at new files —
  -- there is no codediff explorer in this tab, ours is a different panel that
  -- codediff knows nothing about. Saying so matters for exactly one codediff
  -- code path: ui/view/toggle.lua's re-render step dispatches on session.mode,
  -- and its "explorer" branch requires a registered explorer object
  -- (lifecycle.get_explorer) that we deliberately do not fake — a stub would
  -- also have to satisfy ]f/[f, <leader>b/<leader>e and the staging actions,
  -- all of which reach into explorer.tree/split. With mode="explorer" and no
  -- explorer, codediff's `t` normalized the windows and then silently failed
  -- to re-render: the pane showed the plain file and toggling back lost the
  -- other pane entirely. As "standalone" it re-renders from the session's own
  -- path/revision fields, which is exactly the current file. Everything else
  -- keyed off mode outside ui/explorer/ is the `is_explorer_mode` flag for
  -- explorer-only keymaps (`-` staging) and keymap_help's listing — both
  -- correctly OFF for us.
  session.mode = "standalone"
  sess.tabpage = tab
  sess.view_created = true
  if placeholder and placeholder ~= tab and vim.api.nvim_tabpage_is_valid(placeholder) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(placeholder)) do
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  ensure_folds_augroup()
  return tab
end

--- True when this session's target side is the working tree rather than a
--- named revision.
---
--- codediff loads an "A" pane through `git show <revision>:<path>`; the
--- sentinel "WORKING" is not a revision, so that lookup always fails and
--- codediff renders a single empty line (core/virtual_file.lua). codediff's own
--- explorer sidesteps this the same way, taking the virtual-file branch only
--- when target_revision ~= "WORKING" (ui/explorer/render.lua:273) and reading
--- the file off disk otherwise.
local function targets_worktree(sess)
  return sess.target_revision == nil or sess.target_revision == "WORKING"
end

--- True when `file_entry`'s pane content comes from a real file on disk, which
--- codediff loads synchronously — as opposed to a `codediff://` virtual file,
--- whose content arrives asynchronously (see wait_for_virtual_file).
local function loads_from_disk(sess, file_entry)
  return file_entry.status == "??"
    or (file_entry.status == "A" and targets_worktree(sess))
end

--- Render the whole-file pane for a "??"/"A"/"D" status in side-by-side
--- layout. Requires an already-registered codediff session for `tabpage`
--- (show_*_file no-ops otherwise) — see M.bootstrap. These helpers
--- self-normalize windows from ANY prior window configuration (inline's
--- single shared window, or side-by-side with only one side populated) by
--- reading lifecycle.get_windows and closing whichever pane isn't kept, so
--- no separate normalize step is needed before calling them — unlike
--- show_whole_file_inline below.
local function show_whole_file(tabpage, sess, file_entry, abs_path)
  if loads_from_disk(sess, file_entry) then
    cd.side_by_side.show_untracked_file(tabpage, abs_path)
  elseif file_entry.status == "A" then
    cd.side_by_side.show_added_virtual_file(
      tabpage, sess.git_root, file_entry.path, sess.target_revision)
  elseif file_entry.status == "D" then
    cd.side_by_side.show_deleted_virtual_file(tabpage, sess.git_root, file_entry.path, sess.base_revision)
  end
end

--- Point session.modified_win at whichever single-file pane window is
--- currently valid (closing the other one if both happen to exist).
---
--- Mirrors codediff's ui/view/toggle.lua `normalize_inline_layout`, which we
--- cannot call directly (it's local to that module and bundled together with
--- the two-sided `rerender_current_file` step that corrupts whole-file
--- panes — see M.toggle_layout). Needed ONLY before
--- cd.inline_view.show_single_file: unlike the side_by_side show_*_file
--- helpers, it unconditionally reads session.modified_win rather than
--- self-normalizing, and for a "D" pane coming from side-by-side layout
--- (where only session.original_win is populated — see
--- side_by_side.show_deleted_virtual_file) that field is nil.
local function normalize_for_inline(tabpage)
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return false
  end
  local original_win = session.original_win
  local modified_win = session.modified_win
  local keep_win = (modified_win and vim.api.nvim_win_is_valid(modified_win) and modified_win)
    or (original_win and vim.api.nvim_win_is_valid(original_win) and original_win)
  if not keep_win then
    return false
  end
  local close_win = nil
  if original_win and modified_win and original_win ~= modified_win then
    close_win = keep_win == modified_win and original_win or modified_win
  end
  session.original_win = keep_win
  session.modified_win = keep_win
  if close_win and vim.api.nvim_win_is_valid(close_win) then
    vim.api.nvim_set_current_win(keep_win)
    pcall(vim.api.nvim_win_close, close_win, true)
  end
  return true
end

--- Render the whole-file pane for a "??"/"A"/"D" status in inline layout, via
--- codediff's single-file inline entry point (ui/view/inline_view.lua
--- show_single_file) rather than side_by_side's show_*_file helpers.
local function show_whole_file_inline(tabpage, sess, file_entry, abs_path)
  normalize_for_inline(tabpage)
  if loads_from_disk(sess, file_entry) then
    cd.inline_view.show_single_file(tabpage, abs_path, { side = "modified" })
  elseif file_entry.status == "A" then
    cd.inline_view.show_single_file(tabpage, file_entry.path, {
      revision = sess.target_revision,
      git_root = sess.git_root,
      rel_path = file_entry.path,
      side = "modified",
    })
  elseif file_entry.status == "D" then
    cd.inline_view.show_single_file(tabpage, file_entry.path, {
      revision = sess.base_revision,
      git_root = sess.git_root,
      rel_path = file_entry.path,
      side = "original",
    })
  end
end

--- codediff's show_added_virtual_file/show_deleted_virtual_file load their
--- buffer from a `codediff://` virtual URL: `show_single_file` returns as
--- soon as the buffer is registered in the session, but its *content* is
--- fetched asynchronously (codediff.core.git.get_file_content -> vim.schedule)
--- by codediff.core.virtual_file, which then fires
--- `User CodeDiffVirtualFileLoaded` with `data = { buf = <the buffer> }`.
--- Wait for that event (scoped to the buffer this show_file call actually
--- populated) before calling on_ready, so callers never observe an empty
--- buffer. Falls back to polling in case the event is ever missed.
local function wait_for_virtual_file(tabpage, status, on_ready)
  if not on_ready then
    return
  end
  local session = cd.lifecycle.get_session(tabpage)
  local buf = session and (status == "A" and session.modified_bufnr or session.original_bufnr)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.schedule(on_ready)
    return
  end

  local done = false
  local group = vim.api.nvim_create_augroup("IntentDiffVirtualFileWait_" .. buf, { clear = true })

  local function finish()
    if done then
      return
    end
    done = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    on_ready()
  end

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffVirtualFileLoaded",
    callback = function(event)
      if event.data and event.data.buf == buf then
        finish()
      end
    end,
  })

  local function poll(tries)
    if done then
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      finish()
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local has_content = #lines > 1 or (lines[1] ~= nil and lines[1] ~= "")
    if has_content or tries >= 60 then
      finish()
      return
    end
    vim.defer_fn(function()
      poll(tries + 1)
    end, 50)
  end
  vim.defer_fn(function()
    poll(1)
  end, 50)
end

--- Render `file_entry`'s whole-file ("??"/"A"/"D") pane in `target_layout`
--- ("side-by-side" or "inline"), then call `on_ready` once content has
--- actually loaded — synchronously for untracked files, after codediff's
--- async virtual-file fetch completes for "A"/"D" (wait_for_virtual_file
--- above). Shared by M.show_file (the session's CURRENT layout) and
--- M.toggle_layout (whichever layout the user just toggled to) so the status
--- dispatch and the async-ready wait live in exactly one place.
local function show_whole_file_in_layout(tabpage, sess, file_entry, abs_path, target_layout, on_ready)
  if target_layout == "inline" then
    show_whole_file_inline(tabpage, sess, file_entry, abs_path)
  else
    show_whole_file(tabpage, sess, file_entry, abs_path)
  end
  local function ready()
    M.install_keymaps(tabpage)
    if on_ready then
      on_ready()
    end
  end
  if loads_from_disk(sess, file_entry) then
    -- Real file, loaded synchronously by show_untracked_file /
    -- show_single_file.
    vim.schedule(ready)
  else
    -- "A"/"D": virtual file, content arrives asynchronously.
    wait_for_virtual_file(tabpage, file_entry.status, ready)
  end
end

--- Render file_entry's diff and fold to its hunks.
--- sess = { tabpage, git_root, base_revision, target_revision, view_created }
function M.show_file(sess, file_entry, opts)
  opts = opts or {}
  if not sess.view_created and not M.bootstrap(sess) then
    return
  end
  local tabpage = sess.tabpage
  local abs_path = sess.git_root .. "/" .. file_entry.path
  M._last_shown[tabpage] = { sess = sess, file_entry = file_entry }

  -- Putting a real file in the panes ENDS any preview that owned them — the
  -- preview's buffers are about to be replaced by codediff's, below. Retiring
  -- the preview bookkeeping HERE rather than in each caller is what keeps
  -- M._preview_active from going stale: a truthy _preview_active for a tab
  -- whose panes show a file makes `reassert` early-return forever (killing the
  -- TabEnter re-assert of group folds and of the group-scoped ]c/[c), makes
  -- M.apply_group_folds refuse forever, and leaves M._preview_bufs naming
  -- orphaned buffers. M.restore is no longer the only caller that legitimately
  -- takes the panes over; classification completing mid-preview can reach
  -- show_file too (init.lua).
  local prior_preview = M._preview_bufs[tabpage]
  M._preview_active[tabpage] = nil
  M._preview_sess[tabpage] = nil
  M._preview_bufs[tabpage] = nil

  -- Whole-file statuses render a single pane. Added and untracked files are
  -- split into sub-hunks (hunks.split_added), so a group may own only part of
  -- one — fold the rest away exactly as for modified files. "D" is excluded:
  -- pane_entries (above) always resolves the "modified" side's window/buffer
  -- in inline layout, but a deleted file's real content lives on the
  -- "original" side (inline_view.show_single_file sets session.single_side =
  -- "original" and leaves modified_bufnr a 1-line empty scratch buffer — see
  -- codediff/ui/view/inline_view.lua ~587-599). A deleted hunk's `modified`
  -- range is also a zero-width anchor at line 1 (hunks.lua), so
  -- compute_visible_lines(..., "modified", line_count=1, ...) would mark only
  -- line 1 "visible" — and that foldexpr lands on the window that's actually
  -- showing the deleted file, collapsing it entirely. Deleted files always
  -- have a single hunk spanning everything anyway, so skipping the fold is a
  -- no-op in side-by-side layout and avoids this inline-layout bug.
  if file_entry.status == "??" or file_entry.status == "A" or file_entry.status == "D" then
    -- The session's CURRENT layout, not a hardcoded "side-by-side": this is
    -- reached on every sidebar cursor move onto a file row (M.restore), so
    -- hardcoding it silently reverted a user working in inline layout back to
    -- side-by-side just by scrolling the sidebar past an untracked/added/
    -- deleted file. codediff keeps session.layout current for both entry
    -- points show_whole_file_in_layout dispatches to (side_by_side's
    -- show_untracked_file sets "side-by-side"; inline_view's show_single_file
    -- sets "inline"), so reading it back is exact rather than a guess.
    local current = cd.lifecycle.get_session(tabpage)
    local layout = (current and current.layout == "inline") and "inline" or "side-by-side"
    show_whole_file_in_layout(tabpage, sess, file_entry, abs_path, layout, function()
      if file_entry.status ~= "D" and file_entry.hunks then
        M.apply_group_folds(tabpage, file_entry.hunks, { context = 0 })
      end
      -- Not covered by apply_group_folds' own refresh: it is skipped for "D"
      -- and for a file with no hunks, and refuses outright during a preview.
      refresh_comments(tabpage)
      if opts.on_ready then
        opts.on_ready()
      end
    end)
    retire_preview_bufs(prior_preview)
    return
  end

  ---@type table SessionConfig (codediff)
  local session_config = {
    mode = "standalone", -- see M.bootstrap on why our sessions are standalone
    git_root = sess.git_root,
    original = cd.path.make_ref(file_entry.old_path or file_entry.path, sess.git_root),
    modified = cd.path.make_ref(file_entry.path, sess.git_root),
    original_revision = sess.base_revision,
    modified_revision = sess.target_revision or "WORKING",
  }
  cd.view.update(tabpage, session_config, false)
  -- Strictly AFTER cd.view.update: it moves session.*_bufnr off the preview
  -- buffers from a callback it schedules itself, and retire_preview_bufs also
  -- defers by one tick — so queueing ours second is what guarantees it never
  -- deletes a buffer the session still names. (This ordering used to live in
  -- M.restore, the only caller that had preview buffers to retire.)
  retire_preview_bufs(prior_preview)
  when_diff_ready(tabpage, abs_path, function()
    M.apply_group_folds(tabpage, file_entry.hunks)
    M.install_keymaps(tabpage)
    refresh_comments(tabpage)
    if opts.on_ready then
      opts.on_ready()
    end
  end)
end

--- Preview buffers currently installed per tabpage, so a later call can wipe
--- the previous generation out from under nobody. See `retire_preview_bufs`
--- below for why bufhidden isn't just "wipe".
M._preview_bufs = {}

--- Put `lines` into a fresh scratch buffer and apply `highlights`.
--- A span with col_end == -1 covers the whole line.
---
--- bufhidden is deliberately "hide", not "wipe": codediff's own cd.view.update
--- (M.show_file's real-file path) calls nvim_win_set_buf to swap a pane's
--- window onto the restored file's buffer SYNCHRONOUSLY, but only writes the
--- new bufnr into session.modified_bufnr/original_bufnr from a callback it
--- schedules for the next event-loop tick (side_by_side.lua render_everything,
--- invoked via vim.schedule). "wipe" would delete this buffer the instant that
--- nvim_win_set_buf runs, leaving session.modified_bufnr pointing at an
--- already-invalid buffer for that one tick — and vim.wait's first condition
--- check (as helpers.wait_for's callers do right after M.restore) lands
--- exactly there, hard-erroring nvim_buf_line_count on a dead buffer id.
--- "hide" leaves the vacated buffer valid (just unlisted and windowless)
--- through that gap; retire_preview_bufs cleans it up afterward instead.
local function preview_buf(pane)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, pane.lines)
  vim.bo[buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("intentdiff_preview")
  for _, s in ipairs(pane.highlights) do
    if s.col_end == -1 then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, s.line - 1, 0,
        { line_hl_group = s.hl })
    else
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, s.line - 1, s.col_start,
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

--- Delete `bufs` (a tabpage's previous-generation preview buffers, or nil)
--- one event-loop tick from now — after codediff's own scheduled
--- render_everything (see preview_buf above) has had a chance to move
--- session.*_bufnr off of them, so deleting them can never leave that field
--- dangling mid-tick for a caller that reads it in between.
---
--- Never deletes a buffer still displayed in a window: `nvim_buf_delete`
--- with `force = true` closes every window showing that buffer, and closes
--- the tabpage along with it if it was the tab's last window — exactly the
--- window-closing this whole preview mechanism exists to avoid. A caller
--- that retires buffers before anything has actually replaced them in their
--- windows (M.restore with nothing to restore to, M.cleanup_tab_state
--- racing a not-yet-closed tab) would otherwise take the tab down with it.
--- Buffers this leaves behind are still tracked by whichever M._preview_bufs
--- entry named them, and get a further chance to retire the next time that
--- entry is replaced or the tab is actually torn down.
function retire_preview_bufs(bufs)
  if not bufs or #bufs == 0 then
    return
  end
  vim.schedule(function()
    for _, buf in ipairs(bufs) do
      if buf and vim.api.nvim_buf_is_valid(buf) and not buf_is_displayed(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)
end

--- session.original_win/modified_win as a plain array with nil entries
--- dropped. `ipairs({ a, b })` stops at the first missing index — if
--- `a` is nil it never even looks at `b`, even though `b` is set. Whole-file
--- ??/A/D panes routinely leave exactly one of the two nil (codediff's
--- show_single_file, used for untracked/added/deleted files, closes the
--- window it doesn't need and sets that side's session field to nil rather
--- than leaving it pointing at a closed window) — a bare table-literal loop
--- over both fields silently no-ops for those statuses. Every loop over both
--- panes in this file must go through this instead of the literal.
local function pane_windows(session)
  local wins = {}
  if session.original_win then
    wins[#wins + 1] = session.original_win
  end
  if session.modified_win and session.modified_win ~= session.original_win then
    wins[#wins + 1] = session.modified_win
  end
  return wins
end

--- Every buffer of `session`'s diff panes that a buffer-local keymap should be
--- installed on, hole-free and de-duplicated.
---
--- Takes the buffers the pane WINDOWS actually display first, and only then
--- the session's own original_bufnr/modified_bufnr fields.
---
--- The window-derived half is the point. Those session fields lag a render:
--- codediff writes them from a callback it schedules (see preview_buf's
--- comment on exactly that), and mid-flight they were observed still naming
--- codediff's 1-line "CodeDiff 2.1"/"2.2" placeholder buffers while the panes
--- had already moved on to the real file and its `codediff://` counterpart.
--- Whether a given install_keymaps call lands inside that gap depends on
--- codediff's scheduling, so keys installed from the fields alone are keys
--- that MIGHT end up on a buffer nobody is looking at. intentdiff.navigation
--- has always installed ]c/[c via `nvim_win_get_buf(win)`, and marks.lua
--- renders comment boxes the same way; this puts the rest of our buffer-local
--- keys on that same footing. The fields are still consulted afterwards, so a
--- pane whose window is momentarily closed (a layout toggle in flight) keeps
--- its keys.
---
--- The de-duplication is not cosmetic: inline layout puts one buffer in both
--- panes, and the two sources overlap by design.
---
--- Deliberately not `ipairs({ session.original_bufnr, session.modified_bufnr })`:
--- that stops at the first nil. Codediff does appear to keep both bufnr fields
--- populated even for a single-pane ??/A/D file (it is the *_win fields that go
--- nil there — see pane_windows), so this is a guard rather than a fix for an
--- observed break; but nothing about codediff's API promises it, and this
--- codebase has shipped that exact nil hole twice.
local function pane_bufs(session)
  local out, seen = {}, {}
  local function add(buf)
    if buf and not seen[buf] and vim.api.nvim_buf_is_valid(buf) then
      seen[buf] = true
      out[#out + 1] = buf
    end
  end
  for _, win in ipairs(pane_windows(session)) do
    if vim.api.nvim_win_is_valid(win) then
      local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
      if ok then
        add(buf)
      end
    end
  end
  add(session.original_bufnr)
  add(session.modified_bufnr)
  return out
end

--- Drop any group-fold state for `tabpage`'s panes, so a preview buffer is
--- never filtered through a foldexpr computed for a different buffer.
local function clear_folds(tabpage)
  M._active_folds[tabpage] = nil
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return
  end
  for _, win in ipairs(pane_windows(session)) do
    if vim.api.nvim_win_is_valid(win) then
      visible_by_win[win] = nil
      vim.wo[win].foldenable = false
      vim.wo[win].foldmethod = "manual"
    end
  end
end

--- Show `group`'s whole diff in the session's diff panes.
---
--- Injects buffers into the windows the session ALREADY owns — one in inline
--- layout, two in side-by-side — and never creates or closes a window. Probe 2
--- (docs/superpowers/specs/2026-07-30-ux-probes/probe_preview2.lua) shows that
--- building a pane by hand leaves an orphan window behind and corrupts the
--- following restore; probe 3 shows this injection surviving a full round trip
--- in both layouts.
--- @return boolean whether the preview was rendered
function M.show_preview(sess, group)
  local tabpage = sess.tabpage
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return false
  end
  local original_win, modified_win = session.original_win, session.modified_win
  -- The session's own layout decides, so that `t` inside a preview
  -- (M.toggle_preview_layout — which flips session.layout through codediff's
  -- toggle and then re-renders the preview) actually changes how the preview
  -- looks. Deriving it from window identity alone made the preview's layout an
  -- accident of whatever the last-shown file happened to need.
  --
  -- The window structure is still a hard floor: two panes need two distinct,
  -- valid pane windows, and when the last-shown file is untracked/added/
  -- deleted codediff's single-file entry points have already collapsed the
  -- session to ONE window. We may not manufacture the second one — this
  -- function must never create or close a window (probe 2 section D:
  -- hand-built panes orphan a window and corrupt the following restore), so a
  -- single-window session falls back to a single-pane preview even when
  -- session.layout says "side-by-side". Known, deliberate limitation: with a
  -- ??/A/D file as the anchor, the preview stays inline and `t` cannot change
  -- that until a modified file is shown again.
  local two_pane = session.layout ~= "inline"
    and original_win ~= nil
    and modified_win ~= nil
    and original_win ~= modified_win
    and vim.api.nvim_win_is_valid(original_win)
    and vim.api.nvim_win_is_valid(modified_win)
  local single = not two_pane
  local layout = single and "inline" or "side-by-side"
  local rendered = require("intentdiff.preview").render(group, layout,
    { max_lines = require("intentdiff.config").options.preview.max_lines })

  local prior_bufs = M._preview_bufs[tabpage]
  clear_folds(tabpage)
  if single then
    local win = (modified_win and vim.api.nvim_win_is_valid(modified_win))
      and modified_win or original_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return false
    end
    local buf = preview_buf(rendered.modified)
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].scrollbind = false
    vim.wo[win].cursorbind = false
    cd.lifecycle.update_buffers(tabpage, buf, buf)
    M._preview_bufs[tabpage] = { buf }
  else
    local original_buf = preview_buf(rendered.original)
    local modified_buf = preview_buf(rendered.modified)
    vim.api.nvim_win_set_buf(original_win, original_buf)
    vim.api.nvim_win_set_buf(modified_win, modified_buf)
    -- Equal line counts by construction (preview.render pads with fillers), so
    -- scrollbind keeps the two sides aligned.
    for _, win in ipairs({ original_win, modified_win }) do
      vim.wo[win].scrollbind = true
      vim.wo[win].cursorbind = true
    end
    cd.lifecycle.update_buffers(tabpage, original_buf, modified_buf)
    M._preview_bufs[tabpage] = { original_buf, modified_buf }
  end
  cd.lifecycle.update_paths(tabpage, cd.path.empty(), cd.path.empty())
  cd.lifecycle.update_revisions(tabpage, nil, nil)
  cd.lifecycle.update_diff_result(tabpage, { changes = {}, moves = {} })
  -- The old preview buffers are already fully replaced in the session/panes
  -- above (unlike M.restore, nothing async needs to catch up), so retiring
  -- them can happen right away.
  retire_preview_bufs(prior_bufs)

  M._preview_active[tabpage] = group
  M.install_preview_keymaps(tabpage, sess, rendered.hunk_lines)
  return true
end

--- Leave the preview and re-render the file that was last shown, folds and all.
---
--- Returns false — leaving the preview exactly as it is, buffers, windows and
--- all — when there's nothing to restore to yet: previewing before any file
--- has ever been selected in this tab is the ordinary first moment of a
--- sidebar cursor move, not an error. Clearing preview state or retiring the
--- preview buffers in that case, before anything has actually replaced them
--- in their windows, would hand still-displayed buffers to
--- retire_preview_bufs — which now refuses to delete those (see its comment)
--- but there is no reason to even try: nothing changed, so nothing needs
--- retiring.
--- @return boolean whether a file was restored
function M.restore(sess)
  local tabpage = sess.tabpage
  local shown = M._last_shown[tabpage]
  if not shown then
    return false
  end
  local session = cd.lifecycle.get_session(tabpage)
  if session then
    for _, win in ipairs(pane_windows(session)) do
      if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].scrollbind = false
        vim.wo[win].cursorbind = false
      end
    end
  end
  -- Clearing M._preview_active/_preview_sess and retiring the preview buffers
  -- is M.show_file's job now (see its comment): it is what actually replaces
  -- the preview in the panes, and doing it there covers every caller that
  -- does so, not just this one.
  M.show_file(shown.sess, shown.file_entry)
  -- show_file's own completion path refreshes too, once its (async) render has
  -- landed; this covers the synchronous half — the preview's marks are gone
  -- from these buffers the moment the file is back.
  refresh_comments(tabpage)
  return true
end

--- Re-point `tabpage`'s deferred restore at `file_entry` — the same file
--- M._last_shown already names, but carrying a different (freshly classified)
--- hunk set — WITHOUT touching what the panes currently display.
---
--- Used when classification completes while a hover preview owns the panes.
--- The last-shown file is off screen, so applying its new group's folds now
--- would mean folding the PREVIEW buffers (M.apply_group_folds refuses, by
--- design), and skipping the refold entirely would leave the file wearing the
--- pre-classification "All changes" filter the next time M.restore renders it.
--- Recording the new entry here defers the refold to that render instead.
---
--- Replaces the stored entry rather than mutating it: file_entry tables are
--- shared with the model (classify.group_files), and the model is not ours to
--- edit.
--- @return boolean whether there was a last-shown file to re-point
function M.rebind_shown_file(tabpage, file_entry)
  local shown = M._last_shown[tabpage]
  if not shown then
    return false
  end
  M._last_shown[tabpage] = { sess = shown.sess, file_entry = file_entry }
  return true
end

--- Install our buffer-local overrides on the diff panes of `tabpage`.
---
--- Currently just codediff's layout-toggle key (`t` by default). codediff
--- binds it to codediff.ui.view.toggle_layout, which — now that our sessions
--- report mode="standalone" (see M.bootstrap) — re-renders correctly on its
--- own but knows nothing about our group folds: the pane it re-creates when
--- toggling back to side-by-side is a fresh window with no foldexpr. Point the
--- key at M.toggle_layout, which does the same toggle and then re-applies the
--- filter.
---
--- Re-run after every render: codediff's setup_all_keymaps reinstalls its own
--- version at the end of each create/update, and its TabLeave/TabEnter pair
--- deletes and reinstalls them too (see `reassert`). If codediff's version
--- ever wins that race, pressing `t` still yields a coherent diff (that is
--- what mode="standalone" buys us) — just with the group filter dropped until
--- the next selection or TabEnter re-assert.
function M.install_keymaps(tabpage)
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return
  end
  local cd_config = try("codediff.config")
  local keys = cd_config and cd_config.options and cd_config.options.keymaps
  local key = keys and keys.view and keys.view.toggle_layout
  -- Read BEFORE the "no toggle_layout key" early return below: our own view
  -- keys must still be installed on the pane buffers even when codediff's
  -- toggle_layout key is disabled — the sidebar toggle in particular is the
  -- only in-pane way back once the sidebar itself is hidden (a sidebar-local
  -- key is unreachable then). An early return gated only on `key` used to
  -- skip this block entirely.
  local vkm = require("intentdiff.config").options.keymaps.view or {}
  -- Was an early return; it is now a flag, because the comment keys below are
  -- installed on the same buffers and have nothing to do with whether any
  -- `keymaps.view` action is enabled.
  local want_view_keys = (key or vkm.toggle_sidebar or vkm.show_help) and true or false
  -- pane_bufs, not `ipairs({ original_bufnr, modified_bufnr })`: see its
  -- comment on the nil hole that literal opens up for whole-file panes.
  for _, buf in ipairs(pane_bufs(session)) do
    if want_view_keys then
      if key then
        pcall(vim.keymap.set, "n", key, function()
          M.toggle_layout(tabpage)
        end, { buffer = buf, nowait = true, desc = "intent-diff: toggle layout (keeps group folds)" })
      end
      M.map_view_keys(buf, {
        toggle_sidebar = function()
          require("intentdiff").toggle_sidebar(tabpage)
        end,
        show_help = function()
          require("intentdiff.keymap_help").toggle()
        end,
      })
    end
    M.install_comment_keymaps(buf, tabpage)
  end
end

--- Descriptions for the `keymaps.comments` actions, shown in :map / which-key.
M.COMMENT_DESCS = {
  add_comment = "intent-diff: add a comment",
  add_note = "intent-diff: add a note",
  add_suggestion = "intent-diff: add a suggestion",
  add_issue = "intent-diff: add an issue",
  add_praise = "intent-diff: add praise",
  add_file_comment = "intent-diff: comment on the file / the intent",
  edit_comment = "intent-diff: edit the comment at the cursor",
  delete_comment = "intent-diff: delete the comment at the cursor",
  list_comments = "intent-diff: list every comment",
  next_comment = "intent-diff: next comment",
  prev_comment = "intent-diff: previous comment",
  export_clipboard = "intent-diff: copy the review as Markdown",
  export_file = "intent-diff: write the review to a file",
  clear_comments = "intent-diff: delete every comment",
  export_and_close = "intent-diff: copy the review, then close the tab",
}

--- The visual-mode comment actions, in the order the popup's type list uses.
---
--- An ORDERED LIST of records, deliberately not a table keyed by lhs: an entry
--- whose VALUE is nil is simply absent from a table constructor (so
--- `add_comment`, whose type is nil by design, would vanish), `[nil] = ...`
--- RAISES "table index is nil" the moment an action is disabled, and two
--- actions sharing one lhs would silently collapse into a single entry. Keying
--- by action name and looking the lhs up per record has none of those
--- failure modes, and lets every binding go through keymaps.each like the rest
--- of the plugin.
local VISUAL_ACTIONS = {
  { action = "add_comment", type = nil },
  { action = "add_note", type = "note" },
  { action = "add_suggestion", type = "suggestion" },
  { action = "add_issue", type = "issue" },
  { action = "add_praise", type = "praise" },
}

--- Comment keys, installed on every diff pane and on the sidebar.
---
--- Cross-surface by design: an intent comment is added from a sidebar group
--- row, a line comment from a pane, and both surfaces need the export keys.
--- `tabpage` may be nil, in which case the actions resolve the current tabpage
--- when the key is pressed — which is always the right one for a
--- buffer-local mapping.
function M.install_comment_keymaps(buf, tabpage)
  if (require("intentdiff.config").options.comments or {}).enabled == false then
    return
  end
  local comments = require("intentdiff.comments")
  require("intentdiff.keymaps").install(buf, "comments", {
    add_comment = function() comments.add(tabpage) end,
    add_note = function() comments.add(tabpage, "note") end,
    add_suggestion = function() comments.add(tabpage, "suggestion") end,
    add_issue = function() comments.add(tabpage, "issue") end,
    add_praise = function() comments.add(tabpage, "praise") end,
    add_file_comment = function() comments.add_file(tabpage) end,
    edit_comment = function() comments.edit(tabpage) end,
    delete_comment = function() comments.delete(tabpage) end,
    list_comments = function() comments.list(tabpage) end,
    next_comment = function() comments.next(tabpage) end,
    prev_comment = function() comments.prev(tabpage) end,
    export_clipboard = function() comments.export_clipboard(tabpage) end,
    export_file = function() comments.export_file(tabpage) end,
    clear_comments = function() comments.clear(tabpage) end,
    export_and_close = function() comments.export_and_close(tabpage) end,
  }, M.COMMENT_DESCS)

  -- Visual-mode variants: the same add actions, over the selected range.
  local km = (require("intentdiff.config").options.keymaps or {}).comments or {}
  local each = require("intentdiff.keymaps").each
  for _, record in ipairs(VISUAL_ACTIONS) do
    local comment_type = record.type
    each(km[record.action], function(lhs)
      pcall(vim.keymap.set, "x", lhs, function()
        -- <Esc> FIRST: '< and '> hold the PREVIOUS selection until visual mode
        -- is left, so reading them from within visual mode records the wrong
        -- lines (or none at all, on the very first selection of a session).
        vim.cmd("normal! \27")
        comments.add(tabpage, comment_type, { visual = true })
      end, { buffer = buf, nowait = true, desc = M.COMMENT_DESCS[record.action] })
    end)
  end
end

--- Descriptions for the `keymaps.view` actions, shown in :map / which-key.
M.VIEW_DESCS = {
  toggle_sidebar = "intent-diff: show/hide the sidebar",
  show_help = "intent-diff: toggle this help",
  quit = "intent-diff: close",
  next_hunk = "intent-diff: next hunk in group",
  prev_hunk = "intent-diff: previous hunk in group",
}

--- Install the `keymaps.view` actions named in `handlers` on `buf`. Shared by
--- the diff panes and the whole-intent preview buffers, which need the same
--- keys installed from two different call sites.
function M.map_view_keys(buf, handlers)
  require("intentdiff.keymaps").install(buf, "view", handlers, M.VIEW_DESCS)
end

--- Buffer-local keymaps for preview buffers. They are fresh scratch buffers, so
--- they inherit nothing from codediff: without this, codediff's toggle key and
--- ]c/[c would fall through to their global meanings.
function M.install_preview_keymaps(tabpage, sess, hunk_lines)
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return
  end
  local cd_config = try("codediff.config")
  local keys = cd_config and cd_config.options and cd_config.options.keymaps
  local toggle_key = keys and keys.view and keys.view.toggle_layout
  -- Our own view keys are installed unconditionally, regardless of whether
  -- codediff's toggle_layout key is enabled — see the matching note in
  -- M.install_keymaps.
  local function hunk_step(step)
    return function()
      local win = vim.api.nvim_get_current_win()
      local cursor = vim.api.nvim_win_get_cursor(win)[1]
      local target
      if step == 1 then
        for _, lnum in ipairs(hunk_lines) do
          if lnum > cursor then target = lnum break end
        end
      else
        for i = #hunk_lines, 1, -1 do
          if hunk_lines[i] < cursor then target = hunk_lines[i] break end
        end
      end
      if target then
        pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
      end
    end
  end
  -- pane_bufs de-dupes (inline layout shares one buffer between both fields)
  -- and skips the nil hole a bare table literal would leave. Comment keys are
  -- deliberately NOT installed here: a preview buffer concatenates many files,
  -- so comments.context refuses to place a comment in one.
  for _, buf in ipairs(pane_bufs(session)) do
    if toggle_key then
      pcall(vim.keymap.set, "n", toggle_key, function()
        M.toggle_preview_layout(tabpage)
      end, { buffer = buf, nowait = true, desc = "intent-diff: toggle preview layout" })
    end
    M.map_view_keys(buf, {
      toggle_sidebar = function()
        require("intentdiff").toggle_sidebar(tabpage)
      end,
      show_help = function()
        require("intentdiff.keymap_help").toggle()
      end,
      quit = function()
        require("intentdiff").close(tabpage)
      end,
      next_hunk = hunk_step(1),
      prev_hunk = hunk_step(-1),
    })
  end
  M._preview_sess[tabpage] = sess
end

--- Toggle inline ↔ side-by-side while previewing.
---
--- codediff's toggle re-renders from the session's own path/revision fields,
--- which a preview deliberately blanks — so restore the last file first, toggle
--- on that (the only state codediff supports), then re-render the preview in
--- the new layout. Probe 3 steps 4-8 exercise exactly this sequence.
--- @return boolean whether a toggle was started
function M.toggle_preview_layout(tabpage)
  local group = M._preview_active[tabpage]
  local sess = M._preview_sess[tabpage]
  if not (group and sess) then
    return false
  end
  if not M.restore(sess) then
    return false
  end
  M.toggle_layout(tabpage, {
    on_done = function()
      M.show_preview(sess, group)
      -- A preview owns the panes again, so this is a no-op today (marks.refresh
      -- refuses while _preview_active is set). It is here so that the moment
      -- the preview is left — or the guard ever changes — the toggled layout's
      -- panes are re-signed like every other rebuild.
      refresh_comments(tabpage)
    end,
  })
  return true
end

--- Toggle inline ↔ side-by-side for an intent-diff tab, then re-apply the
--- group filter to whatever panes the new layout ended up with.
---
--- codediff's own toggle does the window normalization, the compact-mode
--- save/restore AND (thanks to mode="standalone") the re-render of the current
--- file; all it cannot do is re-apply our group folds, which is what the
--- when_diff_ready hook below is for.
---
--- Whole-file statuses (??/A/D) bypass cd.view.toggle_layout entirely: its
--- standalone rerender path (ui/view/toggle.lua rerender_current_file)
--- rebuilds a two-sided SessionConfig from session.original/session.modified
--- — but show_untracked_file/show_added_virtual_file/show_deleted_virtual_file
--- only ever populate ONE side, leaving the other path.empty(). codediff's
--- rerender resolves that empty Path via bufnr_exact("") — which matches
--- Neovim's shared buffer #1 — and does so ASYNCHRONOUSLY for "A"/"D"
--- (git.get_file_content), so it binds the pane's window to buffer #1 instead
--- of whatever show_file's earlier fix-up rendered. Flip session.layout and
--- re-render directly through show_whole_file_in_layout instead, which calls
--- the same single-file codediff entry points show_file uses (just picking
--- the one matching the NEW layout) — never codediff's two-sided rerender.
---
--- opts.on_done fires once the new layout has rendered (and, for a "real"
--- file, folds are re-applied) — M.toggle_preview_layout uses it to re-render
--- the preview only after the toggle it rode in on has actually finished.
--- @return boolean whether a toggle was performed
function M.toggle_layout(tabpage, opts)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  opts = opts or {}
  local function done()
    if opts.on_done then
      opts.on_done()
    end
  end
  local shown = M._last_shown[tabpage]
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  if shown then
    local status = shown.file_entry.status
    if status == "??" or status == "A" or status == "D" then
      local target_layout = session.layout == "inline" and "side-by-side" or "inline"
      local abs_path = shown.sess.git_root .. "/" .. shown.file_entry.path
      show_whole_file_in_layout(tabpage, shown.sess, shown.file_entry, abs_path, target_layout,
        function()
          -- Skip "D": see the comment on the equivalent branch in M.show_file.
          if shown.file_entry.status ~= "D" and shown.file_entry.hunks then
            M.apply_group_folds(tabpage, shown.file_entry.hunks, { context = 0 })
          end
          refresh_comments(tabpage)
          done()
        end)
      return true
    end
  end

  if not cd.view.toggle_layout(tabpage) then
    return false
  end
  if not shown then
    done()
    return true
  end
  local file_entry = shown.file_entry
  local abs_path = shown.sess.git_root .. "/" .. file_entry.path
  when_diff_ready(tabpage, abs_path, function()
    M.apply_group_folds(tabpage, file_entry.hunks)
    M.install_keymaps(tabpage)
    refresh_comments(tabpage)
    done()
  end)
  return true
end

--- Windows of the current diff panes (for keymap installation).
function M.diff_wins(tabpage)
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return {}
  end
  local wins = {}
  -- pane_windows, not a bare `{ session.original_win, session.modified_win }`
  -- literal: this had the exact ipairs-nil-hole bug pane_windows documents
  -- (pre-existing, not introduced by this task) — whole-file ??/A/D panes
  -- leave session.original_win nil, so this returned {} even with a valid
  -- modified_win, silently skipping ]c/[c keymap installation for them
  -- (navigation.lua's only caller).
  for _, w in ipairs(pane_windows(session)) do
    if vim.api.nvim_win_is_valid(w) then
      wins[#wins + 1] = w
    end
  end
  return wins
end

function M.get_session(tabpage)
  return cd.lifecycle.get_session(tabpage)
end

return M
