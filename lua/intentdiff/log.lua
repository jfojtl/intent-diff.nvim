-- Diagnostics log: one human-readable, timestamped line per event, appended
-- to config.options.log_file (default vim.fn.stdpath("cache") ..
-- "/intentdiff/intentdiff.log"). Deliberately dependency-light — it only
-- touches `intentdiff.config` (for the default path) and plain Lua/vim.fn
-- file I/O — so callers (provider, classify) can require it without pulling
-- in the rest of the plugin, and tests can point it at a tempname.
local M = {}

-- Cap on-disk size: truncated to (approximately) this many trailing bytes
-- after every append, so the log can't grow unbounded across a long Neovim
-- session. "Approximately" because we always cut on a line boundary, never
-- mid-entry.
M.max_bytes = 200 * 1024

local function default_path()
  local ok, config = pcall(require, "intentdiff.config")
  return ok and config.options.log_file or nil
end

-- Keep every entry on exactly one physical line: multi-line samples (e.g.
-- captured stdout/stderr) get their newlines escaped rather than left raw,
-- which would otherwise split one event across several lines in the file.
local function serialize_value(v)
  if type(v) == "table" then
    local ok, s = pcall(vim.json.encode, v)
    return ok and s or tostring(v)
  end
  local s = tostring(v)
  s = s:gsub("\r\n", "\\n"):gsub("[\r\n]", "\\n")
  return s
end

--- Render one event table as a single log line (no trailing newline).
--- `event.kind` (default "event") is the leading token; every other key is
--- appended as `key=value`, sorted by key for stable, diffable output.
function M.format(event)
  event = event or {}
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local kind = event.kind or "event"
  local keys = {}
  for k in pairs(event) do
    if k ~= "kind" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  local parts = { ("[%s] %s"):format(ts, kind) }
  for _, k in ipairs(keys) do
    parts[#parts + 1] = ("%s=%s"):format(k, serialize_value(event[k]))
  end
  return table.concat(parts, " ")
end

--- Truncate `path` in place to at most `max_bytes`, keeping the tail (the
--- most recent entries) and cutting on a line boundary.
local function truncate_to(path, max_bytes)
  local f = io.open(path, "rb")
  if not f then
    return
  end
  local content = f:read("*a")
  f:close()
  if not content or #content <= max_bytes then
    return
  end
  local cut_from = #content - max_bytes + 1
  local nl = content:find("\n", cut_from, true)
  local trimmed = nl and content:sub(nl + 1) or content:sub(cut_from)
  local out = io.open(path, "wb")
  if out then
    out:write(trimmed)
    out:close()
  end
end

--- Append `event` (a table; see M.format) to the log file, then cap the
--- file's size. `log_file` overrides config.options.log_file (mainly for
--- tests). Silently no-ops if no path is configured or the file can't be
--- opened — logging must never be the reason classification breaks.
function M.append(event, log_file)
  local path = log_file or default_path()
  if not path or path == "" then
    return
  end
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "a")
  if not f then
    return
  end
  f:write(M.format(event) .. "\n")
  f:close()
  pcall(truncate_to, path, M.max_bytes)
end

--- Read back every line currently in the log file (empty list if the file
--- doesn't exist yet).
function M.read(log_file)
  local path = log_file or default_path()
  if not path or vim.fn.filereadable(path) == 0 then
    return {}
  end
  return vim.fn.readfile(path)
end

--- Provider invocation: cmd+args spawned, prompt size, hunk count, elapsed
--- ms, exit code, stdout/stderr samples, parse outcome.
function M.provider_invocation(fields)
  M.append(vim.tbl_extend("force", { kind = "provider_invocation" }, fields or {}))
end

--- Classification outcome: cache hit / rematch / skipped / provider success
--- or error.
function M.classification(fields)
  M.append(vim.tbl_extend("force", { kind = "classification" }, fields or {}))
end

--- Reconciliation stats: total inventory hunks, assigned, unrecognized
--- (hallucinated), duplicates, ungrouped.
function M.reconcile_stats(fields)
  M.append(vim.tbl_extend("force", { kind = "reconcile" }, fields or {}))
end

return M
