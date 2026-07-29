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
