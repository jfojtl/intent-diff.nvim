-- Disk persistence for review comments, keyed by repository plus what is being
-- reviewed — NOT by the diff-text hash the classification cache uses. That
-- hash changes the moment a file is edited, which would drop comments exactly
-- when they still matter.
local M = {}

local config = require("intentdiff.config")

local function dir()
  return config.options.cache_dir .. "/comments"
end

--- The same cheap string hash review.nvim uses: enough to keep two repos
--- apart in a filename, not a security boundary.
local function hash(str)
  local h = 0
  for i = 1, #str do
    h = ((h * 31) + string.byte(str, i)) % 2147483647
  end
  return string.format("%x", h)
end

local function short_rev(rev)
  return (tostring(rev):gsub("%^+$", "")):sub(1, 8)
end

--- Storage key for a review. A revision range keys by both revisions; a
--- working-tree review keys by branch, so returning to the branch resumes.
--- @return string|nil
function M.key(git_root, base_revision, target_revision, branch)
  if not git_root or git_root == "" then
    return nil
  end
  local project = hash(git_root)
  if base_revision and target_revision then
    return ("%s-%s_%s"):format(project, short_rev(base_revision), short_rev(target_revision))
  end
  if not branch or branch == "" then
    return nil
  end
  return ("%s-%s"):format(project, (branch:gsub("[^%w%-_]", "_")))
end

--- @return string|nil
function M.path(key)
  if not key then
    return nil
  end
  return ("%s/%s.json"):format(dir(), key)
end

local warned = false

--- @return boolean whether the write landed
function M.save(key, comments)
  local path = M.path(key)
  if not path then
    return false
  end
  local ok_dir = pcall(vim.fn.mkdir, dir(), "p")
  local file = ok_dir and io.open(path, "w") or nil
  if not file then
    if not warned then
      warned = true
      vim.notify(
        "intent-diff: cannot write comments to " .. dir() .. " — they will not persist",
        vim.log.levels.WARN
      )
    end
    require("intentdiff.log").append({ kind = "comments", event = "save_failed", path = path })
    return false
  end
  local ok, encoded = pcall(vim.json.encode, comments)
  if not ok then
    file:close()
    return false
  end
  file:write(encoded)
  file:close()
  return true
end

--- @return intentdiff.Comment[]
function M.load(key)
  M.sweep()
  local path = M.path(key)
  if not path then
    return {}
  end
  local file = io.open(path, "r")
  if not file then
    return {}
  end
  local content = file:read("*a")
  file:close()
  if not content or content == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    require("intentdiff.log").append({ kind = "comments", event = "corrupt_store", path = path })
    return {}
  end
  return decoded
end

function M.clear(key)
  local path = M.path(key)
  if path then
    os.remove(path)
  end
end

local swept = false

--- Remove stored reviews older than comments.expire_days. Runs at most once
--- per Neovim session; `opts.force` is for tests.
function M.sweep(opts)
  if swept and not (opts and opts.force) then
    return
  end
  swept = true
  local days = config.options.comments and config.options.comments.expire_days
  if not days then
    return
  end
  local cutoff = os.time() - (days * 24 * 60 * 60)
  for _, path in ipairs(vim.fn.glob(dir() .. "/*.json", false, true)) do
    local mtime = vim.fn.getftime(path)
    if mtime > 0 and mtime < cutoff then
      os.remove(path)
    end
  end
end

return M
