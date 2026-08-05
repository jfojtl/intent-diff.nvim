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
---                      inflight = { [path] = true } }
local caches = {}

local function key_of(sess)
  return table.concat({ sess.git_root or "", sess.base_revision or "",
    sess.target_revision or "WORKING" }, "\0")
end

local function cache_of(sess)
  local k = key_of(sess)
  if not caches[k] then
    caches[k] = { old = {}, new = {}, inflight = {} }
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

--- Fetch both sides of one file into `cache`. Returns nothing; failures leave
--- the side unset so `get` answers nil and the caller falls back.
local function fetch(sess, cache, file)
  local path, status = file.path, file.status

  if file.binary then
    cache.old[path], cache.new[path] = {}, {}
    return
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

--- Drop the worktree side of `path`, keeping the immutable base side.
function M.invalidate(sess, path)
  local cache = caches[key_of(sess)]
  if cache then
    cache.new[path] = nil
  end
end

--- Ensure both sides of every file are cached.
---
--- Returns `true` when everything is already resident, in which case `on_ready`
--- is NOT called — the caller can paint immediately. Otherwise returns `false`
--- plus the list of paths still missing, schedules the fetch, and calls
--- `on_ready` once when it completes. The caller paints what it can meanwhile.
--- @return boolean ready, string[] missing
function M.ensure(sess, files, on_ready)
  local cache = cache_of(sess)
  local missing = {}
  for _, file in ipairs(files) do
    if cache.old[file.path] == nil or cache.new[file.path] == nil then
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
    for _, path in ipairs(missing) do
      local file = by_path[path]
      if file and not cache.inflight[path] then
        cache.inflight[path] = true
        fetch(sess, cache, file)
        cache.inflight[path] = nil
      end
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
