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

--- Index of the first group titled `title`, or nil.
local function group_by_title(model, title)
  for gi, g in ipairs(model.groups) do
    if g.title == title then
      return gi
    end
  end
end

--- Where `target`'s path sits inside `group`, or nil when it is not there.
--- A file target answers with its file index; a directory target only has to
--- prove the subtree is non-empty, so it answers with `true`.
local function locate_in_group(group, target)
  if target.kind == "file" then
    for fi, f in ipairs(group.files or {}) do
      if f.path == target.path then
        return fi
      end
    end
  elseif target.kind == "dir" then
    for _, f in ipairs(group.files or {}) do
      if under_dir(f.path, target.path) then
        return true
      end
    end
  end
end

--- Locate `target` in `model` by IDENTITY — intent title and file path — and
--- return what to render.
---
--- Re-resolving on every call is what makes `:Telescope resume` safe: resume
--- replays a cached result set, and a reclassification between the original
--- pick and the resume would otherwise have moved the indices under it.
---
--- PATH FIRST, title only as a tie-breaker. The obvious reading — the title
--- names the intent, so find the intent and then the file inside it — is the
--- trap. Two things break under it:
---
---   * Intent titles are LLM-generated prose and are rewritten on every
---     reclassify, so the title is the LESS stable half of a target's
---     identity. Title-first would make a mere rewording report a file that is
---     plainly still on disk as "no longer in this review" — which is exactly
---     the resume-after-reclassify case this identity design exists for.
---   * Titles are not unique: classify.lua defaults a missing one to
---     "Untitled", so two title-less groups collide. Title-first stops at the
---     first of them and silently renders the wrong intent, making every row
---     of the second one unreachable.
---
--- A file moving to a different intent is the rare case, and searching every
--- group still finds it. The title is not discarded, though: when more than one
--- group holds the path, the title-matched group wins, so a file listed under
--- two intents opens the one the user actually picked.
---
--- Degrades toward LESS specific, never toward a different target: a file or
--- directory that is gone falls back to its intent, and a missing intent
--- resolves to nil so the caller can say so rather than opening something
--- arbitrary. A degraded result carries `degraded_from` — the path that could
--- not be found — so the caller can tell it apart from a genuine intent pick
--- and say what happened instead of rendering an intent out of nowhere.
---
--- @param model table|nil
--- @param target table|nil one entry from M.list
--- @return table|nil { kind = "file", group_i, file_i }
---   | { kind = "group", group_i, degraded_from? } | { kind = "dir", group_i, dir_path }
function M.resolve(model, target)
  if not (model and model.groups and target) then
    return nil
  end

  if target.path and (target.kind == "file" or target.kind == "dir") then
    local fallback_gi, fallback_fi
    for gi, g in ipairs(model.groups) do
      local hit = locate_in_group(g, target)
      if hit then
        if g.title == target.group_title then
          -- The tie-breaker: this is the intent the user picked from.
          return target.kind == "file"
            and { kind = "file", group_i = gi, file_i = hit }
            or { kind = "dir", group_i = gi, dir_path = target.path }
        end
        if not fallback_gi then
          fallback_gi, fallback_fi = gi, hit
        end
      end
    end
    if fallback_gi then
      -- The path exists, but under a differently titled intent — the file
      -- moved, or its intent was reworded. Follow the path.
      return target.kind == "file"
        and { kind = "file", group_i = fallback_gi, file_i = fallback_fi }
        or { kind = "dir", group_i = fallback_gi, dir_path = target.path }
    end
    -- The path is nowhere in the model. Degrade to the intent if it survives.
    local group_i = group_by_title(model, target.group_title)
    if not group_i then
      return nil
    end
    return { kind = "group", group_i = group_i, degraded_from = target.path }
  end

  -- A group target: the title is the only identity it has.
  local group_i = group_by_title(model, target.group_title)
  if not group_i then
    return nil
  end
  return { kind = "group", group_i = group_i }
end

return M
