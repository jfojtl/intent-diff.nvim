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

--- Whether the review-comment feature is on. Every comment hook in this file
--- is gated on it, so a disabled feature attaches no store and leaves no marks.
local function comments_enabled()
  return (require("intentdiff.config").options.comments or {}).enabled ~= false
end

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

-- Forward-declared: forget_entry (defined further down) tears down the hover
-- timer, but the timer helper itself lives near apply_hover/schedule_hover,
-- below forget_entry in this file.
local stop_hover_timer

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

-- Forward-declared: classify_and_render re-derives an on-screen hover preview
-- from each newly rendered model, but the hover machinery (apply_hover and the
-- sidebar-cursor plumbing it reads) lives further down the file.
local rerender_preview

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
  -- `r` (reclassify) can land here with a preview already on screen — the key
  -- is a sidebar mapping, so the cursor is typically sitting on the very group
  -- row that raised it. The sidebar has just been redrawn as the flat loading
  -- model; re-derive the preview from it so the panes agree with the row the
  -- cursor is on. No-op when nothing is previewed (the first-open case).
  rerender_preview(token)
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
    --
    -- A hover preview owning the panes counts as "leave the view alone" too,
    -- and this is the DEFAULT first-use path: auto-open returns focus to the
    -- sidebar, the user presses `j` onto a group row, a preview appears, and
    -- the provider answers a second later. Rendering a file into the panes
    -- here would replace that preview while the sidebar cursor still sits on a
    -- group row — and apply_hover's hover_key de-dupe makes re-entering that
    -- same row a no-op, so the cursor would name one intent while the panes
    -- showed another, with no way back. Refold instead (view.rebind_shown_file
    -- defers it to the eventual restore, since the file is off screen), then
    -- re-derive the preview itself from the new grouping.
    if current.user_selected or require("intentdiff.view")._preview_active[current.sess.tabpage] then
      refold_shown_file(token)
    else
      auto_open_first(token)
    end
    rerender_preview(token)
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

--- The reverse of group_file: where does `file_entry` live in `model`?
---
--- Object identity first, then path. Both matter, and for different callers:
--- a render whose model has NOT moved on finds its own entry by identity,
--- while a classification landing mid-render replaces every file entry object
--- wholesale (grouped_model/reconcile build new ones — see hover_spec's
--- "re-points the deferred restore" test, which pins that they are distinct
--- objects), so the file that is literally on screen is then only findable by
--- path. First group wins for the path fallback: a file whose hunks straddle
--- two intents appears twice, and refold_shown_file has always resolved such a
--- file to its first group — keeping ]c/[c and the fold filter naming the same
--- one.
--- @return integer|nil group_i, integer|nil file_i
local function locate_in_model(model, file_entry)
  if not (model and model.groups and file_entry) then
    return nil
  end
  local path_gi, path_fi
  for gi, g in ipairs(model.groups) do
    for fi, f in ipairs(g.files or {}) do
      if f == file_entry then
        return gi, fi
      end
      if not path_gi and f.path == file_entry.path then
        path_gi, path_fi = gi, fi
      end
    end
  end
  return path_gi, path_fi
end

--- Move focus to the diff pane of `tabpage`. Prefers the modified side; falls
--- back to the original, which is the only populated side for a deleted file.
--- @return boolean whether focus moved
local function focus_diff_pane(tabpage)
  local session = require("intentdiff.view").get_session(tabpage)
  if not session then
    return false
  end
  -- Deliberately NOT `ipairs({ modified_win, original_win })`: ipairs stops at
  -- the first nil, and a deleted file populates only the original side. That
  -- exact nil-hole has already shipped twice in this codebase.
  local win = (session.modified_win and vim.api.nvim_win_is_valid(session.modified_win)
      and session.modified_win)
    or (session.original_win and vim.api.nvim_win_is_valid(session.original_win)
      and session.original_win)
  if not win then
    return false
  end
  vim.api.nvim_set_current_win(win)
  return true
end

--- Show `file_entry` (group_i/file_i in the CURRENT model) in the diff panes
--- and wire up navigation ctx. Shared by manual/navigation-driven selection
--- (select_file, below — which also marks entry.user_selected) and auto-open
--- (auto_open_first, further below — which must NOT mark it).
---
--- on_ready runs against two independent questions, and conflating them has
--- produced a stale-ctx bug in each of the last three review rounds. They are
--- now answered by one mechanism each:
---
---  * IDENTITY — "is this render still what the panes are showing?" Answered
---    by `view._last_shown[tabpage].file_entry == file_entry`, since
---    show_file sets _last_shown synchronously at its top (view.lua) and
---    nothing but a NEWER show_file — or rebind_shown_file re-pointing it at
---    a freshly classified entry — can move it on. Everything that describes
---    the CONTENT of the panes (navigation.attach, opts.jump) is gated on it,
---    because installing either against content that is no longer on screen
---    is simply wrong. This replaces the previous opts.auto-only
---    `superseded`/`still_current` pair, which left every non-auto (hover)
---    render's attach ungated: an "A"/"D" virtual file's on_ready fires from
---    a buffer-scoped User autocmd (view.lua's wait_for_virtual_file) and so
---    can still land long after a newer hover has taken the panes.
---    It keeps the case that pair existed for: select_file's same_as_shown
---    short-circuit skips its own show_file() call, so an in-flight
---    auto-open's on_ready is the only place that will ever attach navigation
---    for that file — and _last_shown still names exactly this file_entry
---    there, so the gate passes (integration_spec's "attaches OUR ]c/[c
---    navigation when a same-file <CR> races a still-pending auto-open").
---
---  * RECENCY — "has anyone made a newer decision about WHERE FOCUS BELONGS?"
---    Answered by entry.render_seq (below). Only the focus effects are gated
---    on it.
---
--- opts.auto marks the auto-open call sites. It no longer participates in
--- either gate; it only asks for the focus restore to the sidebar, so the
--- user can keep navigating group/file rows immediately once the auto-opened
--- content is ready (see task README / report). Manual selection (opts.auto
--- unset) leaves focus wherever codediff's own render left it, unless
--- opts.focus_diff or opts.restore_focus says otherwise.
---
--- entry.render_seq: bumped by every open_file() call AND by select_file's
--- same_as_shown short-circuit (which decides focus without calling
--- open_file at all). on_ready captures its own call's number (`my_seq`) and
--- only applies WINDOW-focus-changing effects (opts.focus_diff, the
--- restore-to-sidebar tail) if it is still the most recent one — a hover's
--- open_file(restore_focus=true) can still be in flight when <CR> on that
--- SAME row takes the short-circuit path; without this, the hover's own
--- on_ready firing afterward unconditionally restores focus to the sidebar,
--- undoing the short-circuit's focus_diff_pane.
---
--- Deliberately NOT gated on is_latest: navigation.attach and the opts.jump
--- cursor placement, which answer the IDENTITY question instead (above). jump
--- is orthogonal to WHICH window has focus — ]c/[c's roll-to-next-file
--- (navigation.lua's `move`) opens the new file with jump="first" specifically
--- so the cursor lands on its first hunk; gating that on is_latest would
--- silently drop the cursor placement (leaving it at line 1) whenever a
--- same-row <CR> short-circuit's focus_diff_pane races ahead of that render's
--- own on_ready, even though the short-circuit itself has no opinion on cursor
--- position within the file.
local function open_file(token, group_i, file_i, opts)
  local entry = sessions[token]
  if not entry then
    return
  end
  local _, file_entry = group_file(entry.model, group_i, file_i)
  if not file_entry then
    return
  end
  entry.render_seq = (entry.render_seq or 0) + 1
  local my_seq = entry.render_seq
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
      local is_latest = current.render_seq == my_seq
      local view = require("intentdiff.view")
      -- IDENTITY gate (see the doc comment above): is this render still what
      -- the panes are showing? False exactly when a newer show_file() — or a
      -- classification re-pointing the deferred restore via
      -- rebind_shown_file — has moved _last_shown on, which is precisely when
      -- attaching this render's ctx, or placing its cursor, would name
      -- content that is no longer on screen.
      local shown = view._last_shown[tabpage]
      if not (shown and shown.file_entry == file_entry) then
        return
      end
      -- Re-derive the indices against the CURRENT model rather than trusting
      -- the ones this call was made with: a classification can complete
      -- between show_file() and this on_ready (the >=50ms when_diff_ready
      -- poll leaves a wide window, and an "A"/"D" virtual file waits on an
      -- autocmd instead), replacing entry.model wholesale. The captured
      -- group_i/file_i index into the model that is gone — attaching them
      -- against current.model is what produced ]c's "Invalid cursor line: out
      -- of range". The file on screen has not changed (the gate above just
      -- proved it), so its position in the new model is the answer.
      local gi, fi = locate_in_model(current.model, file_entry)
      if not gi then
        return -- the current model doesn't mention this file at all
      end
      local _, current_entry = group_file(current.model, gi, fi)
      navigation.attach(tabpage, {
        model = current.model,
        group_i = gi,
        file_i = fi,
        select_file = function(g, f, o)
          select_file(token, g, f, o)
        end,
      })
      local session = view.get_session(tabpage)
      local win = session and session.modified_win
      -- Cursor placement, NOT gated on is_latest — see entry.render_seq's
      -- doc comment above. Uses the CURRENT model's entry, for the same
      -- reason the indices above do: after a mid-render classification the
      -- pane has already been re-folded to that entry's hunks
      -- (refold_shown_file), so jumping to one of the flat model's would risk
      -- landing inside a closed fold.
      local hunks = current_entry and current_entry.hunks or file_entry.hunks
      if opts and opts.jump and win and vim.api.nvim_win_is_valid(win) and #hunks > 0 then
        local h = opts.jump == "last" and hunks[#hunks] or hunks[1]
        pcall(vim.api.nvim_win_set_cursor, win, { h.modified.start_line, 0 })
      end
      -- Also a CONTENT effect, not a focus one (see the doc comment above), so
      -- it sits with opts.jump on the identity side of the gate: the caller
      -- asked to be told when THIS file is on screen, and it now is.
      if opts and opts.on_shown then
        opts.on_shown()
      end
      -- Everything below IS a window-focus-changing effect: skip it once a
      -- newer render_seq exists, since a newer caller (another open_file, or
      -- a select_file short-circuit) has already made — and is entitled to
      -- keep — its own, more recent focus decision. See entry.render_seq
      -- above.
      if not is_latest then
        return
      end
      if opts and opts.focus_diff then
        focus_diff_pane(tabpage)
      end
      -- `auto` and `restore_focus` are deliberately separate flags: a
      -- hover-open must restore focus to the sidebar without being an
      -- auto-open (auto-opens are additionally suppressed by
      -- auto_open_first's own user_selected check, which a hover must not
      -- trip — it sets user_selected itself).
      --
      -- An auto-open that a same-file <CR> short-circuit has overtaken must
      -- NOT yank focus back to the sidebar: that newer selection already
      -- decided where focus belongs (focus_diff_pane, just above). The
      -- short-circuit bumps render_seq precisely so `is_latest` above is
      -- false here — which is why this no longer needs its own guard.
      if opts and (opts.auto or opts.restore_focus)
          and vim.api.nvim_tabpage_is_valid(tabpage)
          and current.sidebar and current.sidebar.winid
          and vim.api.nvim_win_is_valid(current.sidebar.winid) then
        vim.api.nvim_set_current_win(current.sidebar.winid)
      end
    end,
  })
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

--- Manual (sidebar <CR>) or ]c/[c-driven selection. Marks entry.user_selected
--- so auto-open never overrides the user's own choice again for this
--- session — see open_file's opts.auto handling and auto_open_first below.
select_file = function(token, group_i, file_i, opts)
  local entry = sessions[token]
  if entry then
    entry.user_selected = true
    -- The panes now show a file; the next hover onto a file row must be a
    -- no-op rather than a restore of something older.
    -- Per-file, matching apply_hover's key: a flat "file" key made every file
    -- row the same hover target, which was right when they all did the same
    -- thing and is wrong now that each renders its own diff.
    entry.hover_key = ("f%d:%d"):format(group_i, file_i)
  end
  -- <CR> on the file the cursor already rendered is a pure focus change: the
  -- panes are already correct, so re-rendering would spend a codediff diff to
  -- produce identical output.
  --
  -- Guarded on NOT _preview_active: same_as_shown reads view._last_shown,
  -- which a hover PREVIEW never touches (show_preview swaps the pane buffers
  -- without updating it — see view.show_preview). With a preview up,
  -- _last_shown still names whatever file was rendered before the preview
  -- took over, so without this guard same_as_shown would report "already
  -- shown" for it, the short-circuit would fire, hover_key would already be
  -- set to this row (above) so the pending debounced hover never renders the
  -- file either, and focus_diff_pane would move focus INTO the preview
  -- buffer instead of a real diff pane — the file is never actually shown.
  -- auto_open_first (below) already guards the identical hazard; on defaults
  -- (debounce_ms = 120) this is reachable just by pressing `j` onto a file
  -- row and Enter before the hover fires.
  if opts and opts.focus_diff and entry
      and not require("intentdiff.view")._preview_active[entry.sess.tabpage] then
    local _, file_entry = group_file(entry.model, group_i, file_i)
    -- Navigation (]c/[c) for this file is already attached, or will be: if a
    -- same-file render is still in flight (same_as_shown true, but that
    -- render's own on_ready hasn't run yet), this short-circuit leaves
    -- view._last_shown naming exactly that render's file_entry, so its
    -- on_ready still passes open_file's IDENTITY gate and attaches once ready
    -- — this short-circuit only needs to move focus.
    if file_entry and same_as_shown(entry.sess.tabpage, file_entry) then
      -- Bump render_seq even though we're not calling open_file: this IS a
      -- fresh, authoritative focus decision, and a same-file render that's
      -- still in flight (e.g. a hover's restore_focus=true open_file call)
      -- must not undo it once ITS on_ready eventually fires — see
      -- entry.render_seq's doc comment on open_file above.
      entry.render_seq = (entry.render_seq or 0) + 1
      focus_diff_pane(entry.sess.tabpage)
      -- The panes already show this file, so it IS "shown" — the callback must
      -- still fire here, or M.open_path's caller would silently never place
      -- its cursor whenever the file happened to be on screen already.
      if opts.on_shown then
        opts.on_shown()
      end
      return
    end
  end
  open_file(token, group_i, file_i, opts)
end

--- Open `path`'s diff in `tabpage`'s panes and call `on_shown()` once it has
--- actually rendered.
---
--- Deliberately the SAME route the sidebar's <CR> takes (select_file →
--- open_file), so the file arrives folded to its intent, with ]c/[c attached
--- and focus in the diff — the caller gets a properly opened file, not a
--- buffer swap. The comment list picker is the caller: jumping to a comment in
--- a file that is not on screen has to open that file first.
---
--- Resolves `path` against the CURRENT model, first group wins — the same
--- convention refold_shown_file uses for a file whose hunks straddle two
--- intents, so both name the same one.
--- @return boolean whether the model has a file at `path` (on_shown never
---   fires when this is false, or when a newer render supersedes this one)
function M.open_path(tabpage, path, on_shown)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  for token, entry in pairs(sessions) do
    if entry.sess.tabpage == tabpage then
      local group_i, file_i = locate_in_model(entry.model, { path = path })
      if not group_i then
        return false
      end
      select_file(token, group_i, file_i, { focus_diff = true, on_shown = on_shown })
      return true
    end
  end
  return false
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
  -- A hover preview owns the panes: auto-open must never yank it out from
  -- under the sidebar cursor. Both branches below would: the de-dupe branch
  -- would fold the preview buffers, the open_file branch would silently
  -- replace the preview with a file. classify_and_render's completion handler
  -- routes around this case explicitly, but the LOADING-phase call above (and
  -- any future caller) reaches it with a preview up whenever `r` is pressed
  -- from a group row, so the guard belongs here too.
  if require("intentdiff.view")._preview_active[tabpage] then
    return
  end
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
---
--- It ALSO re-points ]c/[c at the shown file's new position, which is not
--- optional bookkeeping: navigation.update_model has just run (see
--- classify_and_render) and clamped the stale flat-model file_i to 1, so
--- without this the navigation ctx names a file the panes are not showing and
--- the very first ]c throws "Invalid cursor line: out of range". Reachable on
--- default settings with the cursor alone — moving onto a file row during the
--- loading phase renders it AND sets user_selected (apply_hover), which is
--- what routes classification completion here instead of to auto_open_first.
--- That resync is deliberately NOT gated on auto_open: the fold half is (its
--- caller is auto_open_first's else-branch), but a file put on screen by a
--- hover or <CR> with auto_open = false goes just as stale.
refold_shown_file = function(token)
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
  local group_i, file_i = locate_in_model(entry.model, shown.file_entry)
  if not group_i then
    return
  end
  local f = entry.model.groups[group_i].files[file_i]
  require("intentdiff.navigation").set_position(tabpage, group_i, file_i)
  if not require("intentdiff.config").options.auto_open then
    return
  end
  local status = shown.file_entry.status
  if status == "D" then
    return -- see comment above: never fold a deleted whole-file pane
  end
  local fold_opts = (status == "??" or status == "A") and { context = 0 } or nil
  if view._preview_active[tabpage] then
    -- The shown file is NOT on screen — a hover preview is. Folding now would
    -- fold the preview's buffers (view.apply_group_folds refuses, by design),
    -- so hand the new hunk set to the deferred restore instead: leaving the
    -- preview re-renders the file, and it must do so with the classified
    -- group's filter rather than the flat "All changes" one it was opened
    -- with.
    view.rebind_shown_file(tabpage, f)
  else
    view.apply_group_folds(tabpage, f.hunks, fold_opts)
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
  stop_hover_timer(entry)
  if entry.hover_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, entry.hover_augroup)
  end
  require("intentdiff.classify").cancel(token) -- kill any in-flight provider
  require("intentdiff.navigation").detach(entry.sess.tabpage)
  -- Stop persisting to this review's key, drop its comments from memory and
  -- wipe their marks. Anything the user added is already on disk (the store
  -- saves on every change), so the next review of the same range loads it back.
  if comments_enabled() then
    require("intentdiff.comments").detach_session()
  end
  -- The sidebar buffer is bufhidden="hide" so it can survive being hidden;
  -- nothing reclaims it automatically, so the session that created it owns
  -- deleting it. Without this the plugin leaks one buffer per review.
  if entry.sidebar and entry.sidebar.bufnr
      and vim.api.nvim_buf_is_valid(entry.sidebar.bufnr) then
    pcall(vim.api.nvim_buf_delete, entry.sidebar.bufnr, { force = true })
  end
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

--- The whole-sidebar fold keys (zR / zM / an opted-in fold_toggle_all) and
--- :IntentDiffToggleAll — expand or collapse every intent at once.
---
--- `action` is "open", "close", or "toggle"; toggle means any expanded intent
--- ⇒ collapse everything, otherwise expand everything.
---
--- Per-directory state (g.collapsed_dirs) is deliberately untouched by ALL
--- three, so re-expanding restores the tree the user had arranged. The
--- recursive per-node keys (zO / zC / zA) are the ones that reach into
--- directories.
function M.fold_all(tabpage, action)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = M._session(tabpage)
  if not (entry and entry.model and entry.model.groups) then
    return
  end
  local collapsed
  if action == "open" then
    collapsed = false
  elseif action == "close" then
    collapsed = true
  else
    collapsed = false
    for _, g in ipairs(entry.model.groups) do
      if not g.collapsed then
        collapsed = true
        break
      end
    end
  end
  for _, g in ipairs(entry.model.groups) do
    g.collapsed = collapsed or nil
  end
  entry.sidebar.update(entry.model)
end

--- :IntentDiffToggleAll — collapse every intent, or expand every intent.
function M.toggle_all(tabpage)
  return M.fold_all(tabpage, "toggle")
end

--- :IntentDiffSidebar / the toggle_sidebar key — show or hide the sidebar.
--- Hiding keeps the buffer and the session; only the window goes away.
function M.toggle_sidebar(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = M._session(tabpage)
  if not (entry and entry.sidebar) then
    return
  end
  if entry.sidebar.visible then
    entry.sidebar.hide()
  else
    entry.sidebar.show(entry.model)
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

--- A group restricted to the files under `dir_path`, so hovering a directory
--- row previews only that subtree. Hunks are recomputed from the kept files so
--- the preview's separators and totals stay consistent.
local function subtree_group(group, dir_path)
  local files, hunks = {}, {}
  local prefix = dir_path .. "/"
  for _, f in ipairs(group.files or {}) do
    if f.path:sub(1, #prefix) == prefix then
      files[#files + 1] = f
      vim.list_extend(hunks, f.hunks or {})
    end
  end
  return { title = dir_path, files = files, hunks = hunks }
end

--- Stop and clear `entry.hover_timer` if one is armed.
stop_hover_timer = function(entry)
  if entry and entry.hover_timer then
    local timer = entry.hover_timer
    entry.hover_timer = nil
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
  end
end

--- Act on the row the cursor has settled on. Identical consecutive targets are
--- a no-op, so cursor jitter inside one wrapped group header costs nothing.
local function apply_hover(token)
  local entry = sessions[token]
  if not entry or not entry.sidebar then
    return
  end
  if not (entry.sidebar.winid and vim.api.nvim_win_is_valid(entry.sidebar.winid)) then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(entry.sidebar.winid)[1]
  local m = entry.sidebar.meta_at(lnum)
  if not m then
    return
  end
  local view = require("intentdiff.view")
  local key
  if m.kind == "group" then
    key = "g" .. m.group_i
  elseif m.kind == "dir" then
    key = ("d%d:%s"):format(m.group_i, m.dir_path)
  elseif m.kind == "file" then
    key = ("f%d:%d"):format(m.group_i, m.file_i)
  else
    return
  end
  if entry.hover_key == key then
    return
  end
  entry.hover_key = key

  if m.kind == "file" then
    if not require("intentdiff.config").options.preview.hover_opens_files then
      view.restore(entry.sess)
      return
    end
    -- Opening on the cursor marks the selection: a classification completing
    -- while the user browses must re-fold their current file in place
    -- (refold_shown_file), not yank them to the first group. Hovering a GROUP
    -- deliberately does not set this — rerender_preview handles that path.
    entry.user_selected = true
    open_file(token, m.group_i, m.file_i, { restore_focus = true })
    return
  end
  local group = entry.model and entry.model.groups and entry.model.groups[m.group_i]
  if not group then
    return
  end
  view.show_preview(entry.sess, m.kind == "dir" and subtree_group(group, m.dir_path) or group)
end

--- Re-derive an already-on-screen hover preview from the CURRENT model.
---
--- Called after every model swap (classification starting and completing).
--- The sidebar has just been redrawn, so the row the cursor sits on may now
--- mean a different intent — and apply_hover's hover_key de-dupe would make
--- re-entering that same row a no-op, freezing the panes on the previous
--- model's grouping. Dropping hover_key first is exactly what makes the
--- re-derive possible; the row itself, not a remembered key, is the source of
--- truth for what the panes should show.
---
--- No-op unless a preview is actually up: with a file in the panes, the model
--- swap is handled by refold_shown_file/auto_open_first and re-running the
--- hover would be a spurious render.
rerender_preview = function(token)
  local entry = sessions[token]
  if not entry or not entry.sess then
    return
  end
  if not require("intentdiff.view")._preview_active[entry.sess.tabpage] then
    return
  end
  entry.hover_key = nil
  apply_hover(token)
end

--- Debounced CursorMoved handler on the sidebar buffer.
local function schedule_hover(token)
  local entry = sessions[token]
  if not entry then
    return
  end
  local debounce = require("intentdiff.config").options.preview.debounce_ms
  stop_hover_timer(entry)
  local timer = vim.uv.new_timer()
  entry.hover_timer = timer
  timer:start(debounce, 0, vim.schedule_wrap(function()
    local current = sessions[token]
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
    if current and current.hover_timer == timer then
      current.hover_timer = nil
      apply_hover(token)
    end
  end))
end

--- Watch the sidebar's cursor, if previews are enabled.
local function attach_hover(token)
  if not require("intentdiff.config").options.preview.enabled then
    return
  end
  local entry = sessions[token]
  local group = vim.api.nvim_create_augroup("IntentDiffHover_" .. token, { clear = true })
  entry.hover_augroup = group
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = entry.sidebar.bufnr,
    callback = function()
      schedule_hover(token)
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
    -- <CR> renders if needed and then moves focus INTO the diff, so the user
    -- can scroll and search it. The cursor alone renders in place and leaves
    -- focus in the sidebar for continued browsing.
    on_select = function(gi, fi) select_file(token, gi, fi, { focus_diff = true }) end,
    -- One entry point for every per-node fold key. `dir_path` nil ⇒ the whole
    -- intent; `recursive` additionally reaches the directories beneath the
    -- row. `action` is "open" | "close" | "toggle".
    on_fold = function(gi, dir_path, action, recursive)
      local entry = sessions[token]
      local g = entry and entry.model.groups[gi]
      if not g then
        return
      end
      local function resolve(current)
        if action == "open" then
          return false
        elseif action == "close" then
          return true
        end
        return not current
      end
      local tree = require("intentdiff.tree")
      if dir_path then
        g.collapsed_dirs = g.collapsed_dirs or {}
        local collapsed = resolve(g.collapsed_dirs[dir_path])
        local paths = recursive
            and tree.dir_paths(tree.build(g.files or {}), dir_path)
          or { dir_path }
        for _, p in ipairs(paths) do
          g.collapsed_dirs[p] = collapsed or nil
        end
      else
        local collapsed = resolve(g.collapsed)
        g.collapsed = collapsed or nil
        if recursive then
          g.collapsed_dirs = g.collapsed_dirs or {}
          for _, p in ipairs(tree.dir_paths(tree.build(g.files or {}))) do
            g.collapsed_dirs[p] = collapsed or nil
          end
        end
      end
      entry.sidebar.update(entry.model)
    end,
    on_fold_all = function(action)
      local entry = sessions[token]
      if entry then
        M.fold_all(entry.sess.tabpage, action)
      end
    end,
    on_toggle_sidebar = function()
      local entry = sessions[token]
      if entry then
        M.toggle_sidebar(entry.sess.tabpage)
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
      if not (entry and entry.sidebar.winid
          and vim.api.nvim_win_is_valid(entry.sidebar.winid)) then
        return
      end
      if entry.model.groups[1] then
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
      if not (entry and entry.sidebar.winid
          and vim.api.nvim_win_is_valid(entry.sidebar.winid)) then
        return
      end
      local cur = vim.api.nvim_win_get_cursor(entry.sidebar.winid)[1]
      for l = cur - 1, 1, -1 do
        if (entry.sidebar.meta_at(l) or {}).group_head then
          vim.api.nvim_win_set_cursor(entry.sidebar.winid, { l, 0 })
          break
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
  attach_hover(token)
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
          -- Load this review's stored comments HERE, and not one line earlier:
          -- attach_session decides between branch keying (a working-tree
          -- review) and revision-pair keying by reading exactly the two fields
          -- just assigned above. Attaching back where `sess` is first created
          -- would see neither, treat every review as a working-tree one, and a
          -- `:IntentDiff HEAD~1` review would load the working-tree review's
          -- comments — then persist them back under the wrong key. Nothing
          -- renders between here and classify_and_render below, so there is no
          -- window in which the comments are missing from a drawn pane.
          if comments_enabled() then
            require("intentdiff.comments").attach_session(current)
          end
          current.inventory = inventory
          classify_and_render(token)
        end)
      end)
    end)
  end)
end

return M
