local M = {}

-- A range this wide almost certainly came from a garbled/adversarial `ids`
-- string (or a huge/negative number typo'd into a range boundary), not a
-- genuine hunk range: real diffs are capped by config.max_hunks (400 by
-- default). Iterating it anyway would hang normalize_raw_groups on a single
-- malformed response instead of just dropping it, so ranges wider than this
-- are skipped outright (counted as one dropped token, not one per number).
local MAX_RANGE_SPAN = 20000

--- Expand a compact `ids` value into inventory hunk id strings via
--- `numbering` (integer → inventory hunk id, as built by build_request).
--- Accepts a string ("1-4,7,12-15", tolerant of whitespace, "1 - 4",
--- trailing/duplicate commas, reversed ranges), a JSON array of numbers (or
--- numeric strings), or a bare number. Never throws; anything that can't be
--- parsed as a number, or maps to no entry in `numbering` (out of range,
--- non-numeric, unmappable), is silently dropped.
--- @return string[] hunk_ids, integer dropped
local function expand_ids(ids, numbering)
  local numbers, unmapped_ranges = {}, 0
  local function add_number(n)
    if type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge then -- reject NaN/inf
      numbers[#numbers + 1] = math.floor(n)
    end
  end

  if type(ids) == "number" then
    add_number(ids)
  elseif type(ids) == "string" then
    for token in (ids .. ","):gmatch("([^,]*),") do
      token = vim.trim(token)
      if token ~= "" then
        local a, b = token:match("^(-?%d+)%s*-%s*(-?%d+)$")
        if a and b then
          a, b = math.floor(tonumber(a)), math.floor(tonumber(b))
          if a > b then
            a, b = b, a
          end
          if b - a + 1 <= MAX_RANGE_SPAN then
            for i = a, b do
              add_number(i)
            end
          else
            -- Absurdly wide range: don't iterate it (would hang), but still
            -- surface it as one mapping failure rather than silently
            -- vanishing from the diagnostics.
            unmapped_ranges = unmapped_ranges + 1
          end
        else
          local n = tonumber(token)
          if n then
            add_number(n)
          end
        end
      end
    end
  elseif type(ids) == "table" then
    for _, v in ipairs(ids) do
      if type(v) == "number" then
        add_number(v)
      elseif type(v) == "string" then
        local n = tonumber(vim.trim(v))
        if n then
          add_number(n)
        end
      end
    end
  end

  local out, seen, dropped = {}, {}, unmapped_ranges
  for _, n in ipairs(numbers) do
    local id = numbering and numbering[n]
    if id then
      if not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    else
      dropped = dropped + 1
    end
  end
  return out, dropped
end

--- Normalize provider output into canonical raw_groups (`{title, hunk_ids}`)
--- ready for M.reconcile. Accepts BOTH the legacy `hunk_ids` array-of-ids
--- shape and the new compact `ids` shape (string with ranges, array of
--- numbers, or a bare number) — both may appear in the same response, even
--- on the same group. `numbering` is the number→id map from build_request;
--- may be nil (e.g. a rematch/cache path with no live request), in which
--- case every `ids` number is dropped as unmappable. Never throws.
--- @return table raw_groups, integer id_mapping_failures
function M.normalize_raw_groups(raw_groups, numbering)
  local out, total_dropped = {}, 0
  for _, rg in ipairs(raw_groups or {}) do
    local hunk_ids, seen = {}, {}
    for _, id in ipairs((type(rg) == "table" and rg.hunk_ids) or {}) do
      if type(id) == "string" and not seen[id] then
        seen[id] = true
        hunk_ids[#hunk_ids + 1] = id
      end
    end
    if type(rg) == "table" and rg.ids ~= nil then
      local expanded, dropped = expand_ids(rg.ids, numbering)
      total_dropped = total_dropped + dropped
      for _, id in ipairs(expanded) do
        if not seen[id] then
          seen[id] = true
          hunk_ids[#hunk_ids + 1] = id
        end
      end
    end
    out[#out + 1] = { title = type(rg) == "table" and rg.title or nil, hunk_ids = hunk_ids }
  end
  return out, total_dropped
end

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
--- @param opts { repo: { git_root: string, base_revision: string?, target_revision: string? } }|nil
---   `opts.repo`, when given, is threaded straight onto `request.repo` so
---   providers can point read-only git commands at the right worktree and
---   revision range (see providers/claude_cli.lua's agentic-lookup channel).
---   Optional and additive: callers that pass no `opts` (or omit `repo`) get
---   exactly today's request shape, just with `n`/`numbering` added.
function M.build_request(inventory, opts)
  local cfg = require("intentdiff.config").options
  local hunks, numbering = {}, {}
  for i, h in ipairs(inventory.hunks) do
    local all = vim.split(h.text, "\n", { trimempty = true })
    local summary = {}
    for j = 1, math.min(#all, 4) do
      summary[j] = all[j]
    end
    if #all > 4 then
      summary[#summary + 1] = ("… (%d more lines)"):format(#all - 4)
    end
    hunks[#hunks + 1] = { id = h.id, n = i, file = h.file, summary_lines = summary }
    numbering[i] = h.id
  end
  local request = {
    diff_text = #inventory.diff_text <= cfg.max_full_diff_bytes and inventory.diff_text or nil,
    hunks = hunks,
    -- number (as used in a provider's compact `ids` response) → inventory
    -- hunk id. Every provider gets this, not just claude_cli, so any custom
    -- provider can adopt the compact-id contract too.
    numbering = numbering,
  }
  local repo = opts and opts.repo
  if repo and (repo.git_root or repo.base_revision or repo.target_revision) then
    request.repo = repo
  end
  return request
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
  local function reconcile_and_log(raw_groups, extra_stats)
    local groups, stats = M.reconcile(inventory, raw_groups)
    log.reconcile_stats(vim.tbl_extend("force", stats, extra_stats or {}))
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
        local matched = #inventory.hunks - stale
        -- A rematch that recovered NOTHING is a cache miss, not an answer.
        -- It happens whenever the previous classification describes a diff
        -- that has since been replaced wholesale (work committed, branch
        -- switched, a different feature started): no content hash survives,
        -- so every hunk lands in "Ungrouped". Serving that was doubly bad —
        -- the user saw an unclassified diff, AND the state was sticky:
        -- init.lua's persist_last_hash deliberately does not advance
        -- last_hash on the rematch path, so the scope stayed pinned to the
        -- dead entry and EVERY later run took this same branch. The provider
        -- was never called again for that scope short of a forced `r`.
        if matched > 0 then
          log.classification({
            outcome = "rematch",
            diff_hash = inventory.diff_hash,
            previous_hash = opts.previous_hash,
            matched = matched,
            stale_count = stale,
          })
          return deliver(reconcile_and_log(raw), nil, { cached = true, stale_count = stale })
        end
        log.classification({
          outcome = "rematch_miss",
          diff_hash = inventory.diff_hash,
          previous_hash = opts.previous_hash,
          matched = 0,
          stale_count = stale,
          reason = "no cached hunk survived; classifying from scratch",
        })
      end
    end
  end

  if #inventory.hunks > cfg.max_hunks then
    local reason = ("diff too large (%d hunks > %d)"):format(#inventory.hunks, cfg.max_hunks)
    log.classification({ outcome = "skipped", reason = reason })
    return deliver(reconcile_and_log({}), nil, { skipped = reason })
  end

  local request = M.build_request(inventory, opts)
  run_handles[session_key] = opts.provider(request, function(result, err)
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
      -- Normalize BEFORE caching and reconciling: both legacy `hunk_ids`
      -- arrays and the new compact `ids` (ranges/numbers, via
      -- request.numbering) collapse to the same canonical shape here, so
      -- everything downstream — cache entries, rematch, reconcile — only
      -- ever deals with plain inventory hunk ids, regardless of which shape
      -- this provider (or a cached response saved by an older version of
      -- this plugin) used.
      local raw_groups, id_mapping_failures = M.normalize_raw_groups(result.groups, request.numbering)
      local hunk_hashes = {}
      for _, h in ipairs(inventory.hunks) do
        hunk_hashes[h.id] = h.content_hash
      end
      cache.save(inventory.diff_hash, { groups = raw_groups, hunk_hashes = hunk_hashes })
      callback(reconcile_and_log(raw_groups, { id_mapping_failures = id_mapping_failures }), nil, {})
    end)
  end)
end

return M
