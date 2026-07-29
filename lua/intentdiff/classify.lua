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
--- @return Group[]
function M.reconcile(inventory, raw_groups)
  local by_id, assigned = {}, {}
  for _, h in ipairs(inventory.hunks) do
    by_id[h.id] = h
  end
  local groups = {}
  for _, rg in ipairs(raw_groups or {}) do
    local hunks = {}
    for _, id in ipairs(rg.hunk_ids or {}) do
      if by_id[id] and not assigned[id] then -- drops hallucinated ids + duplicates
        assigned[id] = true
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
  return groups
end

return M
