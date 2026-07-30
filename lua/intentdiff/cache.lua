local M = {}

local function path_for(diff_hash)
  return require("intentdiff.config").options.cache_dir .. "/" .. diff_hash .. ".json"
end

function M.save(diff_hash, entry)
  vim.fn.mkdir(require("intentdiff.config").options.cache_dir, "p")
  vim.fn.writefile({ vim.json.encode(entry) }, path_for(diff_hash))
end

function M.load(diff_hash)
  local file = path_for(diff_hash)
  if vim.fn.filereadable(file) == 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
  if ok and type(decoded) == "table" and type(decoded.groups) == "table" then
    return decoded
  end
  return nil
end

function M.delete(diff_hash)
  vim.fn.delete(path_for(diff_hash))
end

-- ------------------------------------------------------- last-hash index ----
--
-- Entries are keyed by diff hash, so a diff that changed by a single keystroke
-- misses the cache entirely. M.rematch exists to recover the previous
-- classification in that case, but it needs the PREVIOUS diff's hash, which
-- nothing in the process remembers across `:IntentDiff` invocations (let alone
-- across Neovim restarts). This tiny side index — scope key → the diff hash we
-- last classified for that scope — is what makes classify.run's
-- `opts.previous_hash` branch (and therefore the sidebar's
-- "stale — N unclassified" footer) reachable at all.
--
-- Scope key is caller-chosen; init.lua uses git_root .. "|" .. argline, so
-- `:IntentDiff` and `:IntentDiff main...` keep independent histories.

local function index_path()
  return require("intentdiff.config").options.cache_dir .. "/last_hashes.json"
end

local function read_index()
  local file = index_path()
  if vim.fn.filereadable(file) == 0 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
  return (ok and type(decoded) == "table") and decoded or {}
end

--- The diff hash last classified for `scope_key`, or nil.
function M.get_last_hash(scope_key)
  local hash = read_index()[scope_key]
  return type(hash) == "string" and hash or nil
end

--- Remember `hash` as the last classified diff for `scope_key`.
function M.set_last_hash(scope_key, hash)
  local index = read_index()
  if index[scope_key] == hash then
    return
  end
  index[scope_key] = hash
  vim.fn.mkdir(require("intentdiff.config").options.cache_dir, "p")
  vim.fn.writefile({ vim.json.encode(index) }, index_path())
end

--- Re-match a cached classification against a changed inventory. Hunks whose
--- content hash still exists keep their group (by new id); everything else is
--- left unassigned for reconcile() to sweep into Ungrouped.
--- @return table raw_groups, integer stale_count
function M.rematch(entry, inventory)
  local group_of_hash = {}
  for gi, g in ipairs(entry.groups) do
    for _, id in ipairs(g.hunk_ids or {}) do
      local hash = entry.hunk_hashes and entry.hunk_hashes[id]
      if hash then
        group_of_hash[hash] = gi
      end
    end
  end
  local raw = {}
  for gi, g in ipairs(entry.groups) do
    raw[gi] = { title = g.title, hunk_ids = {} }
  end
  local stale = 0
  for _, h in ipairs(inventory.hunks) do
    local gi = group_of_hash[h.content_hash]
    if gi then
      table.insert(raw[gi].hunk_ids, h.id)
    else
      stale = stale + 1
    end
  end
  return raw, stale
end

return M
