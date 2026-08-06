-- Session-scoped cache of both sides of every file in a review.
--
-- The plugin otherwise never reads file content — it parses `git diff` output.
-- Full-content render plans need both sides in full, which is per-file I/O, so
-- everything here exists to make that cost once per file per review instead of
-- once per repaint.
--
-- The base revision's content is immutable for the life of a review, so it is
-- cached forever. The worktree side is dropped by `invalidate` when its file
-- changes on disk.
local M = {}

--- caches[sess_key] = { old = { [path] = lines }, new = { [path] = lines },
---                      inflight = { [path] = true }, stale = { [path] = true },
---                      failed = { [path] = true } }
---
--- `failed` is the NEGATIVE cache, and it is not an optimisation. A failed
--- fetch leaves `old[path]`/`new[path]` nil — indistinguishable, to `ensure`,
--- from "never fetched" — so without it a permanently-unfetchable file (a
--- status-`M` file since deleted from the worktree, an unresolvable path, a
--- permissions failure) was reported missing by every single `ensure` call,
--- and every debounced sidebar hover and every layout toggle scheduled another
--- synchronous `git show`/`readfile` for it, forever. Recording the failure is
--- also what makes the user-facing notice fire once per file instead of once
--- per repaint.
local caches = {}

local function key_of(sess)
  return table.concat({ sess.git_root or "", sess.base_revision or "",
    sess.target_revision or "WORKING" }, "\0")
end

local function cache_of(sess)
  local k = key_of(sess)
  if not caches[k] then
    caches[k] = { old = {}, new = {}, inflight = {}, stale = {}, failed = {} }
  end
  return caches[k]
end

--- `git show <revision>:<path>` as a line array, or nil on any failure.
--- Deliberately synchronous-per-call but driven from a scheduled worker below:
--- vim.system's async form would interleave callbacks with repaints, and the
--- cache is warmed ahead of navigation anyway.
local function git_show(git_root, revision, path)
  local out = vim.fn.systemlist({ "git", "-C", git_root, "show", revision .. ":" .. path })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out
end

local function read_worktree(git_root, path)
  local ok, lines = pcall(vim.fn.readfile, git_root .. "/" .. path)
  if not ok then
    return nil
  end
  return lines
end

--- Fetch both sides of one file into `cache`. Failures leave the side unset so
--- `get` answers nil and the caller falls back to the hunk bodies, and are
--- recorded in `cache.failed` so this file is never fetched again for this
--- review (see the `caches` doc above).
--- @return boolean whether this call newly marked `file.path` as failed
local function fetch(sess, cache, file)
  local path, status = file.path, file.status

  if file.binary then
    cache.old[path], cache.new[path] = {}, {}
    return false
  end

  -- Old side.
  if status == "A" or status == "??" then
    cache.old[path] = {}
  else
    cache.old[path] =
      git_show(sess.git_root, sess.base_revision, file.old_path or path) or nil
  end

  -- New side. "WORKING" is the plugin's sentinel for the working tree, not a
  -- revision: init.lua sets target_revision unconditionally once a review
  -- resolves, so a plain `:IntentDiff` arrives here with the string rather than
  -- with nil. `git show WORKING:path` always fails, which left every
  -- working-tree review's new side nil and every file rendering hunks-only.
  if status == "D" then
    cache.new[path] = {}
  elseif sess.target_revision and sess.target_revision ~= "WORKING" then
    cache.new[path] = git_show(sess.git_root, sess.target_revision, path) or nil
  else
    cache.new[path] = read_worktree(sess.git_root, path) or nil
  end

  -- Either side missing means this file cannot be rendered from content, so
  -- both sides count as a failure: `plan.build` needs the pair.
  if cache.old[path] == nil or cache.new[path] == nil then
    local was_failed = cache.failed[path] == true
    cache.failed[path] = true
    return not was_failed
  end
  cache.failed[path] = nil
  return false
end

--- Cached lines for one side, or nil if not fetched (or the fetch failed).
--- @param side string "old" | "new"
--- @return string[]|nil
function M.get(sess, path, side)
  local cache = caches[key_of(sess)]
  if not cache then
    return nil
  end
  return cache[side][path]
end

--- Drop the worktree side of `path`, keeping the immutable base side, and mark
--- it stale: its hunks (parsed from `git diff` before this call) describe a
--- file that has since changed underneath them, so pairing freshly-fetched
--- content against those hunk ranges could silently misalign every line after
--- the edit. `M.is_stale` is how a caller finds out it must not do that;
--- staleness sticks for the rest of this review's cache, since nothing here
--- re-diffs to clear it — that would be a full reclassification, out of scope
--- for a cache module.
function M.invalidate(sess, path)
  local cache = caches[key_of(sess)]
  if cache then
    cache.new[path] = nil
    cache.stale[path] = true
    -- Clear the negative cache too: this call means the file CHANGED on disk,
    -- which is exactly the event that can turn an unreadable path into a
    -- readable one. The permanent-failure case this cache exists for (a path
    -- git and the worktree both refuse) raises no write event, so it stays
    -- remembered.
    cache.failed[path] = nil
  end
end

--- Whether `path`'s worktree side was invalidated (e.g. by a write to the file
--- while its review was open) since this review's cache was created. A stale
--- file's hunks may no longer describe it; renderers must fall back to the
--- hunks' own frozen text rather than pairing it against fresh content.
function M.is_stale(sess, path)
  local cache = caches[key_of(sess)]
  return cache ~= nil and cache.stale[path] == true
end

--- Ensure both sides of every file are cached.
---
--- Returns `true` when everything is already resident, in which case `on_ready`
--- is NOT called — the caller can paint immediately. Otherwise returns `false`
--- plus the list of paths still missing, schedules the fetch, and calls
--- `on_ready` once when it completes. The caller paints what it can meanwhile.
---
--- A path whose fetch has already failed is "resident" for this purpose: it is
--- NOT reported missing and NOT re-fetched, so a permanently-unfetchable file
--- costs one `git show` per review rather than one per repaint. Its render
--- comes to rest on the hunk-body fallback, which is what the caller draws when
--- `M.get` answers nil.
--- @return boolean ready, string[] missing
function M.ensure(sess, files, on_ready)
  local cache = cache_of(sess)
  local missing = {}
  for _, file in ipairs(files) do
    if (cache.old[file.path] == nil or cache.new[file.path] == nil)
        and not cache.failed[file.path] then
      -- Binary files resolve without I/O, so settle them inline rather than
      -- reporting them missing and scheduling a worker for nothing.
      if file.binary then
        cache.old[file.path], cache.new[file.path] = {}, {}
      else
        missing[#missing + 1] = file.path
      end
    end
  end

  if #missing == 0 then
    return true, {}
  end

  local by_path = {}
  for _, file in ipairs(files) do
    by_path[file.path] = file
  end

  vim.schedule(function()
    local newly_failed = {}
    for _, path in ipairs(missing) do
      local file = by_path[path]
      if file and not cache.inflight[path] then
        cache.inflight[path] = true
        if fetch(sess, cache, file) then
          newly_failed[#newly_failed + 1] = path
        end
        cache.inflight[path] = nil
      end
    end
    -- Once per file, never per repaint: `fetch` only reports a path here on the
    -- transition into `cache.failed`, and `ensure` never asks for it again.
    if #newly_failed > 0 then
      vim.notify(
        "intent-diff: could not read file content, showing the diff hunks only:\n  "
          .. table.concat(newly_failed, "\n  "),
        vim.log.levels.WARN
      )
    end
    if on_ready then
      on_ready()
    end
  end)

  return false, missing
end

--- Drop everything cached for `sess`. Called when a review tab closes.
function M.reset(sess)
  caches[key_of(sess)] = nil
end

return M
