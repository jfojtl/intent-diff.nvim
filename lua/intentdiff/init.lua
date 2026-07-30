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
local sessions = {} -- [token] = { sess, model, sidebar, inventory, scope_key }
local next_token = 0

function M.setup(opts)
  require("intentdiff.config").setup(opts)
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
  }, function(groups, err, info)
    local current = sessions[token]
    if not current or current.inventory ~= inventory then
      return -- session closed or dispatched again since this run started
    end
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
  end)
end

local function select_file(token, group_i, file_i, opts)
  local entry = sessions[token]
  if not entry then
    return
  end
  local group = entry.model.groups[group_i]
  local file_entry = group and group.files[file_i]
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
    end,
  })
end

--- Drop a session's bookkeeping WITHOUT touching windows/tabs. Shared by the
--- explicit close path and the TabClosed path (where the tab is already gone).
local function forget_entry(token)
  local entry = sessions[token]
  if not entry then
    return nil
  end
  sessions[token] = nil
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
          if (entry.sidebar.meta_at(l) or {}).kind == "group" then
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
          if (entry.sidebar.meta_at(l) or {}).kind == "group" then
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
