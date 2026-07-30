local M = {}

--- Sessions are keyed by an internal token, NOT by tabpage.
---
--- codediff.ui.view.create() always opens its own tab (`tabnew`) rather than
--- rendering into the current one, so `sess.tabpage` is whatever tab codediff
--- decided to use — written by view.bootstrap(). If we keyed `sessions` by
--- tabpage directly, any future change to when/how that tab is (re)acquired
--- would silently orphan the entry under its old key. Keying by a stable
--- token — and looking up "the session for tabpage X" by scanning for
--- entry.sess.tabpage == X — means lookups keep working regardless.
local sessions = {} -- [token] = { sess, model, sidebar, inventory, scope_key, elapsed_timer }
local next_token = 0

function M.setup(opts)
  require("intentdiff.config").setup(opts)
end

--- Stop and clear `entry.elapsed_timer` if one is armed. Shared by every path
--- that can end a classification in flight (ready/error/skipped) or tear the
--- session down (close_entry, the TabClosed cleanup path): a timer that
--- outlives its session would keep firing vim.schedule_wrap callbacks against
--- a sidebar buffer/window that may no longer be valid.
local function stop_elapsed_timer(entry)
  if entry and entry.elapsed_timer then
    local timer = entry.elapsed_timer
    entry.elapsed_timer = nil
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
  end
end

--- Start a ~1s repeating timer that bumps `sessions[token].model.elapsed_s`
--- and re-renders the sidebar, for as long as a classification is in flight.
--- Purely cosmetic (sidebar.layout stays pure — it just renders elapsed_s
--- when present), so a missed tick or two is harmless; the guard below just
--- makes sure a stale timer from a previous run/session never mutates a
--- model or sidebar that has moved on.
local function start_elapsed_timer(token)
  local entry = sessions[token]
  if not entry then
    return
  end
  stop_elapsed_timer(entry)
  entry.model.elapsed_s = 0
  local timer = vim.uv.new_timer()
  entry.elapsed_timer = timer
  timer:start(1000, 1000, vim.schedule_wrap(function()
    local current = sessions[token]
    if not current or current.elapsed_timer ~= timer then
      pcall(function() timer:stop() end)
      pcall(function() timer:close() end)
      return
    end
    current.model.elapsed_s = (current.model.elapsed_s or 0) + 1
    current.sidebar.update(current.model)
  end))
end

--- :IntentDiffLog — open the diagnostics log in a scratch buffer, cursor at
--- the end so the newest entry is visible. A friendly one-liner instead of an
--- error when nothing has been logged yet.
function M.show_log()
  local lines = require("intentdiff.log").read()
  if #lines == 0 then
    lines = { "intent-diff: no log entries yet" }
  end
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "intentdifflog"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })
end

--- Find the session whose *current* tabpage is `tabpage`. Safe to call at any
--- point, including after view.show_file() has reconciled sess.tabpage away
--- from the tab :IntentDiff originally opened.
function M._session(tabpage)
  for _, entry in pairs(sessions) do
    if entry.sess.tabpage == tabpage then
      return entry
    end
  end
  return nil
end

local function resolve_provider()
  local cfg = require("intentdiff.config").options
  if type(cfg.provider) == "function" then
    return cfg.provider, "custom"
  end
  local mod = require("intentdiff.providers." .. cfg.provider)
  local label = ("%s:%s"):format(cfg.provider_opts.cmd or cfg.provider, cfg.provider_opts.model or "?")
  return mod.new(cfg.provider_opts), label
end

--- Flat single-group model used while loading and on provider failure.
---
--- grouped_hunks == total_hunks, NOT 0: the footer's "N/M hunks" is a
--- data-loss check ("is every hunk in the inventory reachable from the
--- sidebar?"), and the single "All changes" group holds all of them. The
--- provider-failure path renders with state="ready", so hardcoding 0 made the
--- footer read "0/3 hunks · ?" — as if the failure had dropped the diff,
--- while in fact nothing was lost. provider_label is left nil (the sidebar
--- footer omits the label rather than printing "?") because no provider
--- produced this grouping.
local function flat_model(inventory, state, message)
  local classify = require("intentdiff.classify")
  local groups = {}
  if #inventory.hunks > 0 then
    groups[1] = {
      title = "All changes",
      hunks = inventory.hunks,
      files = classify.group_files(inventory.hunks, inventory.files),
    }
  end
  return {
    state = state,
    groups = groups,
    total_hunks = #inventory.hunks,
    grouped_hunks = #inventory.hunks,
    message = message,
  }
end

local function grouped_model(inventory, groups, info, provider_label)
  -- NOTE (deviation from the task-11 skeleton): grouped_hunks sums EVERY
  -- group's hunks, including the synthetic "Ungrouped" group, not just the
  -- provider-named ones. reconcile()'s completeness invariant guarantees the
  -- union of all returned groups equals the full inventory, so this always
  -- equals total_hunks. That's the point: the sidebar footer's "N/N hunks" is
  -- a data-loss check ("nothing the provider mentioned — or failed to
  -- mention — got silently dropped"), not a "how many did the LLM
  -- classify" progress meter. A skeleton that only summed non-ungrouped
  -- hunks would render e.g. "2/3 hunks" whenever anything landed in
  -- Ungrouped, which both misrepresents the invariant and does not match
  -- the required integration behavior (a provider that misses one hunk out
  -- of three must still show "3/3 hunks").
  local grouped = 0
  for _, g in ipairs(groups) do
    grouped = grouped + #g.hunks
  end
  return {
    state = "ready",
    groups = groups,
    total_hunks = #inventory.hunks,
    grouped_hunks = grouped,
    stale_count = info and info.stale_count,
    provider_label = provider_label,
    message = info and info.skipped,
  }
end

-- Forward-declared: resolve_args' merge-base failure branch needs to close
-- the already-opened tab/session (defined further down, alongside M.close).
local close_entry

--- Parse :IntentDiff args → collect opts. cb(collect_opts, base_for_view, target_for_view)
--- `token` identifies the session opened by the caller, so the merge-base
--- failure branch can close it — resolve_args no longer just notifies and
--- silently returns without calling cb, which used to leak the opened
--- tab+sidebar stuck on "⟳ classifying…" forever.
local function resolve_args(argline, git_root, token, cb)
  local view = require("intentdiff.view")
  local args = vim.split(vim.trim(argline or ""), "%s+", { trimempty = true })
  if #args == 0 then
    return cb({ git_root = git_root }, "HEAD")
  end
  if #args == 2 then
    return cb({ git_root = git_root, base = args[1], target = args[2] }, args[1], args[2])
  end
  local rev = args[1]
  local three_dot = rev:match("^(.-)%.%.%.$")
  if three_dot then
    view.git().get_merge_base(three_dot, "HEAD", git_root, function(err, mb)
      if err or not mb then
        return vim.schedule(function()
          vim.notify("intent-diff: cannot resolve merge-base of " .. three_dot, vim.log.levels.ERROR)
          close_entry(token)
        end)
      end
      cb({ git_root = git_root, base = mb }, mb)
    end)
    return
  end
  cb({ git_root = git_root, base = rev }, rev)
end

--- Dispatch classification for `token`'s session and render whatever comes
--- back (loading → grouped/flat/error). Guards against the session having
--- been closed, or re-dispatched with a fresh inventory, while the (async)
--- classify.run() call was in flight.
--- Remember `inventory.diff_hash` as the last classified diff for this
--- session's scope, so the NEXT `:IntentDiff` on the same scope can re-match a
--- slightly-changed diff against it (classify.run's `previous_hash` branch)
--- instead of paying for a full reclassification.
---
--- Only for classifications that actually left a cache entry behind under this
--- diff hash: the rematch path (info.stale_count) and the too-large skip
--- (info.skipped) do not save one, so pointing the index at their hash would
--- break the chain — the next run would find no entry to re-match against and
--- lose the grouping entirely. Leaving the index on the older hash keeps
--- re-matching from the last real classification.
local function persist_last_hash(entry, info)
  if info and (info.stale_count or info.skipped) then
    return
  end
  require("intentdiff.cache").set_last_hash(entry.scope_key, entry.inventory.diff_hash)
end

-- Forward-declared: classify_and_render (below) auto-opens/refolds after
-- every model it renders (flat loading model, then grouped/flat-failure
-- ready model), but both helpers live further down the file — they depend on
-- select_file, which itself has to exist before open_file does.
local auto_open_first
local refold_shown_file

local function classify_and_render(token, opts)
  local classify = require("intentdiff.classify")
  local entry = sessions[token]
  if not entry or not entry.inventory then
    return
  end
  local inventory = entry.inventory
  local provider, label = resolve_provider()
  entry.model = flat_model(inventory, "loading")
  entry.sidebar.update(entry.model)
  -- Real content immediately instead of blank codediff placeholders: the
  -- flat "All changes" group holds every hunk, so its first file's diff is
  -- complete on its own even before classification groups anything.
  auto_open_first(token)
  start_elapsed_timer(token) -- live "⟳ classifying… Ns" counter while this run is in flight
  local previous_hash = require("intentdiff.cache").get_last_hash(entry.scope_key)
  classify.run(inventory, {
    provider = provider,
    force = opts and opts.force,
    -- nil when this is the first classification for the scope, or when the
    -- diff is byte-identical to the last one (the plain cache hit handles
    -- that case).
    previous_hash = previous_hash ~= inventory.diff_hash and previous_hash or nil,
    -- Scope run-supersession to THIS session: without a per-session key,
    -- classify.run's single module-global "latest run wins" counter meant a
    -- second concurrent :IntentDiff (or a reclassify in another tab) could
    -- supersede — and thus silently drop — this session's in-flight result.
    session_key = token,
    -- The inventory alone doesn't carry the repo location: thread it from
    -- the session so build_request can put it on request.repo, letting a
    -- provider's agentic lookup channel (see providers/claude_cli.lua) cwd
    -- into the right worktree and name the right revision range.
    repo = {
      git_root = entry.sess.git_root,
      base_revision = entry.sess.base_revision,
      target_revision = entry.sess.target_revision,
    },
  }, function(groups, err, info)
    local current = sessions[token]
    if not current or current.inventory ~= inventory then
      return -- session closed or dispatched again since this run started
    end
    stop_elapsed_timer(current) -- classification finished (ready/error/skipped): counter stops
    if not groups then
      current.model = flat_model(current.inventory, "ready",
        "classification failed: " .. tostring(err) .. " — flat list; r to retry")
    else
      current.model = grouped_model(current.inventory, groups, info, label)
      persist_last_hash(current, info)
    end
    current.sidebar.update(current.model)
    -- Resync any attached navigation ctx to the new model — otherwise ]c/[c
    -- keeps reading the stale pre-classify model until the user's next
    -- select_file, even though the sidebar is now showing the new one.
    require("intentdiff.navigation").update_model(current.sess.tabpage, current.model)
    -- Auto-open the first real group's first file — unless the user already
    -- picked their own file (manually or via ]c/[c) while this was running,
    -- in which case their view is left alone and just re-folded to match
    -- whichever group it now belongs to.
    if current.user_selected then
      refold_shown_file(token)
    else
      auto_open_first(token)
    end
  end)
end

-- Forward-declared: open_file's on_ready closure below wires ]c/[c-driven
-- navigation back through select_file (which marks entry.user_selected —
-- see below), so it has to exist before open_file is defined.
local select_file

--- group_i/file_i lookup shared by open_file (which needs a fresh one on
--- every call — entry.model may have moved on by the time it runs) and
--- auto_open_first (which needs one just to decide whether there's anything
--- to open, and whether it already matches what's on screen).
local function group_file(model, group_i, file_i)
  local group = model and model.groups and model.groups[group_i]
  local file_entry = group and group.files and group.files[file_i]
  return group, file_entry
end

--- Show `file_entry` (group_i/file_i in the CURRENT model) in the diff panes
--- and wire up navigation ctx. Shared by manual/navigation-driven selection
--- (select_file, below — which also marks entry.user_selected) and auto-open
--- (auto_open_first, further below — which must NOT mark it).
---
--- opts.auto: true only for auto-open call sites. When true, on_ready
--- re-checks entry.user_selected — which may have flipped true while
--- show_file() was asynchronously in flight, if the user made their own
--- selection in the meantime — and bails out entirely rather than clobbering
--- the navigation ctx or focus the user's own selection now owns. It also
--- returns focus to the sidebar once the auto-opened content is ready, so the
--- user can keep navigating group/file rows immediately (see task README /
--- report). Manual selection (opts.auto unset) leaves focus wherever
--- codediff's own render left it, unchanged from before this feature.
local function open_file(token, group_i, file_i, opts)
  local entry = sessions[token]
  if not entry then
    return
  end
  local _, file_entry = group_file(entry.model, group_i, file_i)
  if not file_entry then
    return
  end
  local navigation = require("intentdiff.navigation")
  navigation.set_position(entry.sess.tabpage, group_i, file_i)
  require("intentdiff.view").show_file(entry.sess, file_entry, {
    on_ready = function()
      local current = sessions[token]
      if not current then
        return -- closed while show_file() was in flight
      end
      if opts and opts.auto and current.user_selected then
        return -- user selected something else while this auto-open was in flight
      end
      -- Read sess.tabpage fresh: show_file() may have just reconciled it to
      -- the tab codediff actually created (see module-level note above).
      local tabpage = current.sess.tabpage
      navigation.attach(tabpage, {
        model = current.model,
        group_i = group_i,
        file_i = file_i,
        select_file = function(gi, fi, o)
          select_file(token, gi, fi, o)
        end,
      })
      local session = require("intentdiff.view").get_session(tabpage)
      local win = session and session.modified_win
      if opts and opts.jump and win and vim.api.nvim_win_is_valid(win) and #file_entry.hunks > 0 then
        local h = opts.jump == "last" and file_entry.hunks[#file_entry.hunks] or file_entry.hunks[1]
        pcall(vim.api.nvim_win_set_cursor, win, { h.modified.start_line, 0 })
      end
      if opts and opts.auto and vim.api.nvim_tabpage_is_valid(tabpage)
          and current.sidebar and vim.api.nvim_win_is_valid(current.sidebar.winid) then
        vim.api.nvim_set_current_win(current.sidebar.winid)
      end
    end,
  })
end

--- Manual (sidebar <CR>) or ]c/[c-driven selection. Marks entry.user_selected
--- so auto-open never overrides the user's own choice again for this
--- session — see open_file's opts.auto handling and auto_open_first below.
select_file = function(token, group_i, file_i, opts)
  local entry = sessions[token]
  if entry then
    entry.user_selected = true
  end
  open_file(token, group_i, file_i, opts)
end

--- True when `file_entry`'s hunks are exactly (same objects, same order)
--- what's already displayed for `tabpage` (view._last_shown, set
--- synchronously at the START of show_file — see view.lua — so this is
--- reliable even while that earlier show_file()'s own diff/render is still
--- asynchronously in flight). Hunks are shared objects between the flat and
--- grouped models (both ultimately index the same inventory.hunks — see
--- flat_model and classify.reconcile), so comparing by identity is exact,
--- not a content/heuristic match.
local function same_as_shown(tabpage, file_entry)
  local shown = require("intentdiff.view")._last_shown[tabpage]
  if not shown or shown.file_entry.path ~= file_entry.path then
    return false
  end
  local a, b = shown.file_entry.hunks, file_entry.hunks
  if #a ~= #b then
    return false
  end
  for i, h in ipairs(a) do
    if h ~= b[i] then
      return false
    end
  end
  return true
end

--- Auto-open the first file of the first group, when auto_open is enabled
--- and the user hasn't made a selection of their own yet. Two call sites:
--- the flat "All changes" model rendered while classification is still
--- running, and the real grouped model once it completes (see
--- classify_and_render). No-op — leaving whatever placeholder is on screen —
--- when there is nothing to open yet (no groups, or an (impossible in
--- practice, but guarded) group with no files).
---
--- De-dupe against an already-in-flight (or already-finished) render of the
--- SAME file with the SAME hunks — the mainstream case where the flat "All
--- changes" group's first file IS the first real group's first file (always
--- true for a single-file diff, and for any file whose hunks all land in one
--- group). Without this, the ready-phase call here would invoke open_file
--- again and trigger a second, wasted cd.view.update()/diff recompute
--- (codediff/ui/view/side_by_side.lua) on top of the loading-phase's
--- still-in-flight one — and which of the two fold applications "won" would
--- depend on poll-scheduling order, not on anything guaranteed. Because the
--- hunk sets are identical here, the fix doesn't need to out-race that
--- in-flight render at all: applying the SAME hunks directly is correct
--- regardless of whether the pending render has finished yet (a harmless
--- no-op if the diff isn't ready — session.stored_diff_result missing — or a
--- redundant-but-correct confirmation if it is), and if it's still pending,
--- that render's own on_ready reads entry.model fresh (see open_file above),
--- so it ends up wiring the correct (already-updated) grouped ctx on its
--- own. The result is invariant to poll ordering rather than depending on it.
auto_open_first = function(token)
  local cfg = require("intentdiff.config").options
  if not cfg.auto_open then
    return
  end
  local entry = sessions[token]
  if not entry or entry.user_selected then
    return
  end
  local _, file_entry = group_file(entry.model, 1, 1)
  if not file_entry then
    return
  end
  local tabpage = entry.sess.tabpage
  if same_as_shown(tabpage, file_entry) then
    require("intentdiff.view").apply_group_folds(tabpage, file_entry.hunks)
    return
  end
  open_file(token, 1, 1, { auto = true })
end

--- When classification completes and the user already has a file open
--- (manual or ]c/[c-driven selection), don't yank their view — but that
--- file's folds were computed against the flat "All changes" group (which
--- shows the WHOLE file — for added/untracked files, every sub-hunk from
--- hunks.split_added — with no group filtering), so if it also appears in
--- the real grouped model its folds are now wrong. Re-apply the correct
--- group's fold filter in place, without touching what's displayed or where
--- focus is — for "??"/"A" with `context = 0`, matching M.show_file's
--- whole-file branch (hunks.split_added's sub-hunks are adjacent partitions
--- of one continuous addition, so the usual context padding would leak the
--- next, unowned sub-hunk into view). "D" is excluded: it always carries a
--- single hunk spanning the whole file (nothing to fold), and applying group
--- folds to it can collapse the pane to line 1 in inline layout — see the
--- comment on the equivalent "D" skip in M.show_file. A shown file that the
--- new grouping doesn't mention at all (shouldn't happen given reconcile's
--- completeness invariant, but guarded per spec) is left alone rather than
--- guessed at.
refold_shown_file = function(token)
  local cfg = require("intentdiff.config").options
  if not cfg.auto_open then
    return
  end
  local entry = sessions[token]
  if not entry then
    return
  end
  local tabpage = entry.sess.tabpage
  if not (tabpage and vim.api.nvim_tabpage_is_valid(tabpage)) then
    return
  end
  local view = require("intentdiff.view")
  local shown = view._last_shown[tabpage]
  if not shown then
    return
  end
  local status = shown.file_entry.status
  if status == "D" then
    return -- see comment above: never fold a deleted whole-file pane
  end
  local fold_opts = (status == "??" or status == "A") and { context = 0 } or nil
  local path = shown.file_entry.path
  for _, g in ipairs(entry.model.groups or {}) do
    for _, f in ipairs(g.files or {}) do
      if f.path == path then
        view.apply_group_folds(tabpage, f.hunks, fold_opts)
        return
      end
    end
  end
end

--- Drop a session's bookkeeping WITHOUT touching windows/tabs. Shared by the
--- explicit close path and the TabClosed path (where the tab is already gone).
local function forget_entry(token)
  local entry = sessions[token]
  if not entry then
    return nil
  end
  sessions[token] = nil
  stop_elapsed_timer(entry) -- no timer may outlive its session
  require("intentdiff.classify").cancel(token) -- kill any in-flight provider
  require("intentdiff.navigation").detach(entry.sess.tabpage)
  return entry
end

close_entry = function(token)
  local entry = forget_entry(token)
  if not entry then
    return
  end
  require("intentdiff.view").close_tab(entry.sess)
end

function M.close(tabpage)
  for token, entry in pairs(sessions) do
    if entry.sess.tabpage == tabpage then
      return close_entry(token)
    end
  end
end

--- Sessions whose tab was closed behind our back (`:tabclose`, `:q` of the
--- last window in the tab, codediff's own `q` keymap) used to linger in
--- `sessions` forever: the entry kept the (dead) model, navigation kept its
--- per-tab ctx, and view kept _active_folds/_last_shown for the tab, so a
--- recycled tab id could inherit stale fold state. TabClosed fires after the
--- tab is gone and only reports its NUMBER, so match by validity instead.
local tab_augroup
local function ensure_tab_augroup()
  if tab_augroup then
    return
  end
  tab_augroup = vim.api.nvim_create_augroup("IntentDiffTabs", { clear = true })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = tab_augroup,
    callback = function()
      for token, entry in pairs(sessions) do
        local tabpage = entry.sess.tabpage
        if not vim.api.nvim_tabpage_is_valid(tabpage) then
          forget_entry(token)
          require("intentdiff.view").cleanup_tab_state(tabpage)
        end
      end
    end,
  })
end

function M.open(argline)
  local view = require("intentdiff.view")
  if not view.load() then
    return
  end
  local git_root = view.git().get_git_root_sync(vim.fn.expand("%:p") ~= "" and vim.fn.expand("%:p")
    or vim.fn.getcwd())
  if not git_root then
    return vim.notify("intent-diff: not inside a git repository", vim.log.levels.ERROR)
  end

  -- Bootstrap the codediff session and the sidebar synchronously, before any
  -- of the async work below (git diff collection, revision resolution,
  -- classification). Two reasons:
  --
  --  * the rest of this function is entirely async (vim.system, provider
  --    calls), so deferring tab creation until the first async step completed
  --    would mean nvim_get_current_tabpage() called right after M.open()
  --    returns (which callers — including tests — legitimately do) would
  --    observe the PREVIOUS tab, not this session's;
  --  * the codediff session must exist BEFORE the sidebar, because
  --    codediff.ui.view.create() opens its own tab. Creating the sidebar
  --    first (in a placeholder tab) meant the first file selection had to
  --    close that tab — wiping the sidebar's window and (bufhidden=wipe)
  --    buffer, after which handle.update() silently no-op'd and no further
  --    file or group could be selected. Now the sidebar is a plain
  --    `topleft vsplit` INSIDE codediff's tab and survives every selection.
  local sess = { git_root = git_root }
  if not view.bootstrap(sess) then
    return vim.notify("intent-diff: codediff failed to open a diff view", vim.log.levels.ERROR)
  end
  local tabpage = sess.tabpage
  next_token = next_token + 1
  local token = next_token
  ensure_tab_augroup()

  local sidebar = require("intentdiff.sidebar").create({
    on_select = function(gi, fi) select_file(token, gi, fi) end,
    on_toggle_group = function(gi)
      local entry = sessions[token]
      local g = entry and entry.model.groups[gi]
      if g then
        g.collapsed = not g.collapsed
        entry.sidebar.update(entry.model)
      end
    end,
    on_toggle_dir = function(gi, dir_path)
      local entry = sessions[token]
      local g = entry and entry.model.groups[gi]
      if g then
        g.collapsed_dirs = g.collapsed_dirs or {}
        g.collapsed_dirs[dir_path] = not g.collapsed_dirs[dir_path] or nil
        entry.sidebar.update(entry.model)
      end
    end,
    on_reclassify = function()
      local entry = sessions[token]
      if entry and entry.inventory then
        require("intentdiff.cache").delete(entry.inventory.diff_hash)
        classify_and_render(token, { force = true })
      end
    end,
    on_close = function() close_entry(token) end,
    on_next_group = function()
      local entry = sessions[token]
      if entry and entry.model.groups[1] then
        -- jump cursor to next group header line
        local cur = vim.api.nvim_win_get_cursor(entry.sidebar.winid)[1]
        for l = cur + 1, vim.api.nvim_buf_line_count(entry.sidebar.bufnr) do
          if (entry.sidebar.meta_at(l) or {}).group_head then
            vim.api.nvim_win_set_cursor(entry.sidebar.winid, { l, 0 })
            break
          end
        end
      end
    end,
    on_prev_group = function()
      local entry = sessions[token]
      if entry then
        local cur = vim.api.nvim_win_get_cursor(entry.sidebar.winid)[1]
        for l = cur - 1, 1, -1 do
          if (entry.sidebar.meta_at(l) or {}).group_head then
            vim.api.nvim_win_set_cursor(entry.sidebar.winid, { l, 0 })
            break
          end
        end
      end
    end,
    on_goto_file = function(gi, fi)
      local entry = sessions[token]
      local f = entry and entry.model.groups[gi] and entry.model.groups[gi].files[fi]
      if f then
        close_entry(token)
        vim.cmd("edit " .. vim.fn.fnameescape(git_root .. "/" .. f.path))
        if f.hunks[1] then
          pcall(vim.api.nvim_win_set_cursor, 0, { f.hunks[1].modified.start_line, 0 })
        end
      end
    end,
  })

  sessions[token] = {
    sess = sess,
    sidebar = sidebar,
    inventory = nil,
    -- Scope for the cache's last-hash index: same repo + same revision args ⇒
    -- same review scope, so `:IntentDiff` and `:IntentDiff main...` keep
    -- independent re-match chains.
    scope_key = git_root .. "|" .. vim.trim(argline or ""),
  }
  sessions[token].model = flat_model({ hunks = {} }, "loading")
  sidebar.update(sessions[token].model)
  vim.cmd("wincmd l") -- focus codediff's panes, right of the sidebar

  resolve_args(argline, git_root, token, function(collect_opts, base_rev, target_rev)
    require("intentdiff.hunks").collect(collect_opts, function(inventory, err)
      if not inventory then
        vim.notify("intent-diff: " .. err, vim.log.levels.ERROR)
        return close_entry(token)
      end
      if #inventory.hunks == 0 then
        vim.notify("intent-diff: no changes", vim.log.levels.INFO)
        return close_entry(token)
      end
      view.git().resolve_revision(base_rev, git_root, function(rev_err, base_hash)
        vim.schedule(function()
          local current = sessions[token]
          if not current then
            return -- user closed the sidebar (e.g. pressed q) while loading
          end
          if rev_err then
            vim.notify("intent-diff: " .. rev_err, vim.log.levels.ERROR)
            return close_entry(token)
          end
          current.sess.base_revision = base_hash
          current.sess.target_revision = target_rev or "WORKING"
          current.inventory = inventory
          classify_and_render(token)
        end)
      end)
    end)
  end)
end

return M
