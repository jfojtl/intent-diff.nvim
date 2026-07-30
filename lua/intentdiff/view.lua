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

--- Hunks currently applied per tabpage via M.apply_group_folds, so the
--- TabEnter handler below can re-assert them. Set on success in
--- apply_group_folds, cleared in M.close_tab.
M._active_folds = {}

--- Last { sess, file_entry } rendered per tabpage. Two uses:
---   * M.toggle_layout needs to know WHICH file to re-render after codediff
---     has flipped the layout (codediff's own rerender path is explorer-only
---     and we deliberately register no explorer — see M.toggle_layout);
---   * the TabEnter re-assert below uses it as the "this is an intent-diff
---     tab" marker, so it also fires for whole-file statuses that never
---     applied group folds.
M._last_shown = {}

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
  if M._active_folds[tab] then
    M.apply_group_folds(tab, M._active_folds[tab])
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
function M.apply_group_folds(tabpage, hunks)
  ensure_folds_augroup()
  local session = cd.lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end
  local changes = {}
  for i, h in ipairs(hunks) do
    changes[i] = { original = h.original, modified = h.modified }
  end
  local ctx = context_lines()
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
  M._active_folds[tabpage] = hunks
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

--- Render the whole-file pane for a "??"/"A"/"D" status in side-by-side
--- layout. Requires an already-registered codediff session for `tabpage`
--- (show_*_file no-ops otherwise) — see M.bootstrap. These helpers
--- self-normalize windows from ANY prior window configuration (inline's
--- single shared window, or side-by-side with only one side populated) by
--- reading lifecycle.get_windows and closing whichever pane isn't kept, so
--- no separate normalize step is needed before calling them — unlike
--- show_whole_file_inline below.
local function show_whole_file(tabpage, sess, file_entry, abs_path)
  if file_entry.status == "??" then
    cd.side_by_side.show_untracked_file(tabpage, abs_path)
  elseif file_entry.status == "A" then
    cd.side_by_side.show_added_virtual_file(
      tabpage, sess.git_root, file_entry.path, sess.target_revision or "WORKING")
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
  local status = file_entry.status
  if status == "??" then
    cd.inline_view.show_single_file(tabpage, abs_path, { side = "modified" })
  elseif status == "A" then
    cd.inline_view.show_single_file(tabpage, file_entry.path, {
      revision = sess.target_revision or "WORKING",
      git_root = sess.git_root,
      rel_path = file_entry.path,
      side = "modified",
    })
  elseif status == "D" then
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
--- above). Shared by M.show_file (always side-by-side, matching the
--- pre-existing behavior of a fresh sidebar selection) and M.toggle_layout
--- (whichever layout the user just toggled to) so the status dispatch and
--- the async-ready wait live in exactly one place.
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
  if file_entry.status == "??" then
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

  -- Whole-file statuses: the entire file is the change — no folds needed.
  if file_entry.status == "??" or file_entry.status == "A" or file_entry.status == "D" then
    show_whole_file_in_layout(tabpage, sess, file_entry, abs_path, "side-by-side", opts.on_ready)
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
  when_diff_ready(tabpage, abs_path, function()
    M.apply_group_folds(tabpage, file_entry.hunks)
    M.install_keymaps(tabpage)
    if opts.on_ready then
      opts.on_ready()
    end
  end)
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
  if not key then
    return -- user disabled codediff's toggle key; don't invent one
  end
  for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.keymap.set, "n", key, function()
        M.toggle_layout(tabpage)
      end, { buffer = buf, nowait = true, desc = "intent-diff: toggle layout (keeps group folds)" })
    end
  end
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
--- @return boolean whether a toggle was performed
function M.toggle_layout(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
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
      show_whole_file_in_layout(tabpage, shown.sess, shown.file_entry, abs_path, target_layout)
      return true
    end
  end

  if not cd.view.toggle_layout(tabpage) then
    return false
  end
  if not shown then
    return true
  end
  local file_entry = shown.file_entry
  local abs_path = shown.sess.git_root .. "/" .. file_entry.path
  when_diff_ready(tabpage, abs_path, function()
    M.apply_group_folds(tabpage, file_entry.hunks)
    M.install_keymaps(tabpage)
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
  for _, w in ipairs({ session.original_win, session.modified_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      wins[#wins + 1] = w
    end
  end
  return wins
end

function M.get_session(tabpage)
  return cd.lifecycle.get_session(tabpage)
end

return M
