-- Pure directory-tree model for a single group's files. No Neovim UI state:
-- build() turns a flat file list into nodes, flatten() turns nodes into
-- renderable rows. The sidebar owns all presentation.
local M = {}

--- Collapse chains of single-child directories into one node, so
--- `app/ -> api/ -> integrations/` renders as one `app/api/integrations` row.
--- The synthetic root is never collapsed — its children ARE the top level.
local function compress(node)
  for _, child in ipairs(node.children or {}) do
    if child.kind == "dir" then
      while #child.children == 1 and child.children[1].kind == "dir" do
        local grandchild = child.children[1]
        child.name = child.name .. "/" .. grandchild.name
        child.path = grandchild.path
        child.children = grandchild.children
      end
      compress(child)
    end
  end
end

local function sort_tree(node)
  table.sort(node.children, function(a, b)
    if a.kind ~= b.kind then
      return a.kind == "dir" -- directories first
    end
    return a.name < b.name
  end)
  for _, child in ipairs(node.children) do
    if child.kind == "dir" then
      sort_tree(child)
    end
  end
end

--- Build a directory tree from a group's file entries.
--- @param files table[] { path, status, old_path, hunks }, as classify.group_files returns
--- @return table[] roots
function M.build(files)
  local root = { kind = "dir", name = "", path = "", children = {}, index = {} }
  for file_i, f in ipairs(files) do
    local segments = vim.split(f.path, "/", { plain = true, trimempty = true })
    local node = root
    for i = 1, #segments - 1 do
      local segment = segments[i]
      local child = node.index[segment]
      if not child then
        child = {
          kind = "dir",
          name = segment,
          path = node.path == "" and segment or (node.path .. "/" .. segment),
          children = {},
          index = {},
        }
        node.index[segment] = child
        node.children[#node.children + 1] = child
      end
      node = child
    end
    node.children[#node.children + 1] = {
      kind = "file",
      name = segments[#segments],
      path = f.path,
      file = f,
      file_i = file_i,
    }
  end
  compress(root)
  sort_tree(root)
  return root.children
end

--- Every directory path in `nodes`, for the recursive fold keys.
---
--- With `under`, only that directory and its descendants; without it, all of
--- them. Paths are post-compression — the same strings flatten() puts on dir
--- rows and `collapsed_dirs` is keyed by — so a compressed chain like
--- `src/http` contributes exactly one path, not one per segment.
--- @param nodes table[] roots from M.build
--- @param under? string directory path to restrict to (inclusive)
--- @return string[]
function M.dir_paths(nodes, under)
  local out = {}
  local function walk(list, inside)
    for _, node in ipairs(list) do
      if node.kind == "dir" then
        local hit = inside or under == nil or node.path == under
        if hit then
          out[#out + 1] = node.path
        end
        walk(node.children, hit)
      end
    end
  end
  walk(nodes, false)
  return out
end

local function file_stats(f)
  local additions, deletions = 0, 0
  for _, h in ipairs(f.hunks or {}) do
    additions = additions + (h.additions or 0)
    deletions = deletions + (h.deletions or 0)
  end
  return additions, deletions
end

--- Flatten nodes into ordered rows, skipping collapsed subtrees.
--- @param nodes table[] roots from M.build
--- @param collapsed table<string, boolean> keyed by directory path
--- @return table[] rows
function M.flatten(nodes, collapsed)
  collapsed = collapsed or {}
  local rows = {}
  local function walk(list, depth)
    for i, node in ipairs(list) do
      local last = i == #list
      if node.kind == "dir" then
        local is_collapsed = collapsed[node.path] == true
        rows[#rows + 1] = {
          kind = "dir",
          depth = depth,
          name = node.name,
          path = node.path,
          collapsed = is_collapsed,
          last = last,
        }
        if not is_collapsed then
          walk(node.children, depth + 1)
        end
      else
        local additions, deletions = file_stats(node.file)
        rows[#rows + 1] = {
          kind = "file",
          depth = depth,
          name = node.name,
          path = node.path,
          status = node.file.status,
          additions = additions,
          deletions = deletions,
          file_i = node.file_i,
          last = last,
        }
      end
    end
  end
  walk(nodes, 0)
  return rows
end

return M
