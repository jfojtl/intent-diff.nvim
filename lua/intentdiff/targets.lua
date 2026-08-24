-- Pure model → selectable-target list. No Neovim UI state and no vim API:
-- this is the seam every picker sits on, and keeping it pure is what lets the
-- whole navigation behaviour be tested without a UI (the same reason
-- sidebar.layout is pure).
--
-- Targets carry the intent TITLE and the file PATH, never array indices.
-- `:Telescope resume` replays a cached result set, and classification swaps
-- the whole model out (init.lua's flat_model → grouped_model), so an index
-- captured before a reclassify can address a different intent afterwards.
-- Identity survives that; indices do not.
local M = {}

local tree = require("intentdiff.tree")

--- True when `path` is at or beneath directory `prefix`.
local function under_dir(path, prefix)
  return path:sub(1, #prefix + 1) == prefix .. "/"
end

local function sum_stats(hunks)
  local additions, deletions = 0, 0
  for _, h in ipairs(hunks or {}) do
    additions = additions + (h.additions or 0)
    deletions = deletions + (h.deletions or 0)
  end
  return additions, deletions
end

--- Every hunk of every file at or beneath `prefix`, or of the whole group when
--- `prefix` is nil.
local function hunks_under(group, prefix)
  local out = {}
  for _, f in ipairs(group.files or {}) do
    if not prefix or under_dir(f.path, prefix) then
      vim.list_extend(out, f.hunks or {})
    end
  end
  return out
end

--- Flatten `model` into selectable targets, in sidebar order.
---
--- Fold state is deliberately ignored: tree.flatten is called with an empty
--- collapsed table, so a collapsed intent still yields its files. A fuzzy list
--- has no folds, and hiding matches behind the sidebar's current fold state
--- would make the picker's results depend on invisible UI state.
---
--- @param model table|nil { state, groups }
--- @param opts table|nil { include_dirs = boolean } — defaults to true
--- @return table[] targets
function M.list(model, opts)
  opts = opts or {}
  local include_dirs = opts.include_dirs ~= false
  local out = {}
  for _, g in ipairs(model and model.groups or {}) do
    local additions, deletions = sum_stats(hunks_under(g, nil))
    out[#out + 1] = {
      kind = "group",
      group_title = g.title,
      path = nil,
      additions = additions,
      deletions = deletions,
    }
    for _, row in ipairs(tree.flatten(tree.build(g.files or {}), {})) do
      if row.kind == "dir" then
        if include_dirs then
          local a, d = sum_stats(hunks_under(g, row.path))
          out[#out + 1] = {
            kind = "dir",
            group_title = g.title,
            path = row.path,
            additions = a,
            deletions = d,
          }
        end
      else
        out[#out + 1] = {
          kind = "file",
          group_title = g.title,
          path = row.path,
          additions = row.additions,
          deletions = row.deletions,
        }
      end
    end
  end
  return out
end

return M
