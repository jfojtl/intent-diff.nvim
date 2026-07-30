local M = {}

--- Order a group's hunks by file (diff order), then by modified start line.
function M.group_files(hunks, files)
  local by_file = {}
  for _, h in ipairs(hunks) do
    by_file[h.file] = by_file[h.file] or {}
    table.insert(by_file[h.file], h)
  end
  local out = {}
  for _, f in ipairs(files) do
    local fh = by_file[f.path]
    if fh then
      table.sort(fh, function(x, y) return x.modified.start_line < y.modified.start_line end)
      out[#out + 1] = { path = f.path, status = f.status, old_path = f.old_path, hunks = fh }
    end
  end
  return out
end

--- Reconcile provider output against the inventory. Enforces the completeness
--- invariant: union of returned groups == inventory, exactly.
--- @return Group[], { total_hunks: integer, assigned: integer, unrecognized: integer, duplicates: integer, ungrouped: integer }
---   The second return is additive (existing callers that only capture the
---   first return, e.g. `local groups = M.reconcile(...)`, are unaffected):
---   `unrecognized` counts hunk ids the provider returned that aren't in the
---   inventory at all (hallucinated); `duplicates` counts ids that named a
---   hunk already claimed by an earlier group; `ungrouped` is how many hunks
---   fell through to the synthetic "Ungrouped" bucket.
function M.reconcile(inventory, raw_groups)
  local by_id, assigned = {}, {}
  for _, h in ipairs(inventory.hunks) do
    by_id[h.id] = h
  end
  local groups = {}
  local unrecognized, duplicates, assigned_count = 0, 0, 0
  for _, rg in ipairs(raw_groups or {}) do
    local hunks = {}
    for _, id in ipairs(rg.hunk_ids or {}) do
      if not by_id[id] then
        unrecognized = unrecognized + 1 -- hallucinated: not in the inventory
      elseif assigned[id] then
        duplicates = duplicates + 1 -- already claimed by an earlier group
      else
        assigned[id] = true
        assigned_count = assigned_count + 1
        hunks[#hunks + 1] = by_id[id]
      end
    end
    if #hunks > 0 then
      groups[#groups + 1] = { title = tostring(rg.title or "Untitled"), hunks = hunks }
    end
  end
  local ungrouped = {}
  for _, h in ipairs(inventory.hunks) do
    if not assigned[h.id] then
      ungrouped[#ungrouped + 1] = h
    end
  end
  if #ungrouped > 0 then
    groups[#groups + 1] = { title = "Ungrouped", hunks = ungrouped, is_ungrouped = true }
  end
  for _, g in ipairs(groups) do
    g.files = M.group_files(g.hunks, inventory.files)
  end
  local stats = {
    total_hunks = #inventory.hunks,
    assigned = assigned_count,
    unrecognized = unrecognized,
    duplicates = duplicates,
    ungrouped = #ungrouped,
  }
  return groups, stats
end

-- Latest in-flight run token PER session_key, not a single module-global
-- counter. A module-global counter meant starting run N+1 for ANY session
-- (e.g. a second concurrent :IntentDiff, or a reclassify in one tab while
-- another tab is still loading) silently superseded run N's callback even
-- when the two runs belonged to different sessions — the older session's
-- sidebar would then be stuck on "classifying…" forever, since its callback
-- would never fire. Keying the token per session_key (default: a single
-- shared key, so callers that never pass session_key keep today's
-- single-session supersede-the-previous-run-in-THIS-session semantics)
-- scopes supersession to "a newer run in the same session", which is the
-- actual invariant we want.
local run_tokens = {}
local DEFAULT_SESSION_KEY = {} -- sentinel identity object

-- Cancel handle returned by the provider for the run currently in flight per
-- session_key. Superseding a run only stopped us from DELIVERING the old
-- result; the provider job (a `claude -p` process for the default provider)
-- kept running to completion, burning tokens and a job slot for an answer
-- nobody would ever read. Mashing `r` therefore piled up one live CLI process
-- per press. Keep the handle so the next run — and session close, via
-- M.cancel — can kill it.
local run_handles = {}

--- Cancel the in-flight provider run for `session_key`, if any.
function M.cancel(session_key)
  local handle = run_handles[session_key or DEFAULT_SESSION_KEY]
  run_handles[session_key or DEFAULT_SESSION_KEY] = nil
  if type(handle) == "table" and type(handle.cancel) == "function" then
    pcall(handle.cancel)
    return true
  end
  return false
end

--- Build the provider request, honoring size thresholds.
function M.build_request(inventory)
  local cfg = require("intentdiff.config").options
  local hunks = {}
  for _, h in ipairs(inventory.hunks) do
    local all = vim.split(h.text, "\n", { trimempty = true })
    local summary = {}
    for i = 1, math.min(#all, 4) do
      summary[i] = all[i]
    end
    if #all > 4 then
      summary[#summary + 1] = ("… (%d more lines)"):format(#all - 4)
    end
    hunks[#hunks + 1] = { id = h.id, file = h.file, summary_lines = summary }
  end
  return {
    diff_text = #inventory.diff_text <= cfg.max_full_diff_bytes and inventory.diff_text or nil,
    hunks = hunks,
  }
end

--- Classify: cache → (rematch) → provider → reconcile. See task interface.
function M.run(inventory, opts, callback)
  local cache = require("intentdiff.cache")
  local cfg = require("intentdiff.config").options
  local log = require("intentdiff.log")
  local session_key = opts.session_key or DEFAULT_SESSION_KEY
  M.cancel(session_key) -- this run supersedes any provider still in flight
  run_tokens[session_key] = (run_tokens[session_key] or 0) + 1
  local token = run_tokens[session_key]
  local function deliver(groups, err, info)
    vim.schedule(function()
      if token == run_tokens[session_key] then
        callback(groups, err, info or {})
      end
    end)
  end
  local function reconcile_and_log(raw_groups)
    local groups, stats = M.reconcile(inventory, raw_groups)
    log.reconcile_stats(stats)
    return groups
  end

  if not opts.force then
    local entry = cache.load(inventory.diff_hash)
    if entry then
      log.classification({ outcome = "cache_hit", diff_hash = inventory.diff_hash })
      return deliver(reconcile_and_log(entry.groups), nil, { cached = true })
    end
    if opts.previous_hash then
      local prev = cache.load(opts.previous_hash)
      if prev then
        local raw, stale = cache.rematch(prev, inventory)
        log.classification({ outcome = "rematch", stale_count = stale, diff_hash = inventory.diff_hash })
        return deliver(reconcile_and_log(raw), nil, { cached = true, stale_count = stale })
      end
    end
  end

  if #inventory.hunks > cfg.max_hunks then
    local reason = ("diff too large (%d hunks > %d)"):format(#inventory.hunks, cfg.max_hunks)
    log.classification({ outcome = "skipped", reason = reason })
    return deliver(reconcile_and_log({}), nil, { skipped = reason })
  end

  run_handles[session_key] = opts.provider(M.build_request(inventory), function(result, err)
    vim.schedule(function()
      if token ~= run_tokens[session_key] then
        return -- superseded by a newer run in the same session
      end
      run_handles[session_key] = nil -- this run is done; nothing to cancel
      if not result then
        log.classification({ outcome = "provider_error", error = tostring(err or "provider failed") })
        return callback(nil, err or "provider failed", {})
      end
      log.classification({ outcome = "provider_success" })
      local hunk_hashes = {}
      for _, h in ipairs(inventory.hunks) do
        hunk_hashes[h.id] = h.content_hash
      end
      cache.save(inventory.diff_hash, { groups = result.groups, hunk_hashes = hunk_hashes })
      callback(reconcile_and_log(result.groups), nil, {})
    end)
  end)
end

return M
