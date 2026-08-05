local M = {}

function M.git(repo, ...)
  local out = vim.fn.system({ "git", "-C", repo, ... })
  assert(vim.v.shell_error == 0, "git failed: " .. out)
  return out
end

function M.write_file(repo, path, content)
  local abs = repo .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
  vim.fn.writefile(vim.split(content, "\n"), abs)
end

--- Create a temp git repo with an initial commit of `files` ({[path]=content}).
function M.make_repo(files)
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  M.git(repo, "init", "-q")
  M.git(repo, "config", "user.email", "test@test")
  M.git(repo, "config", "user.name", "test")
  M.git(repo, "config", "commit.gpgsign", "false")
  for path, content in pairs(files) do
    M.write_file(repo, path, content)
  end
  M.git(repo, "add", "-A")
  M.git(repo, "commit", "-q", "-m", "initial")
  return repo
end

--- Make `require("intentdiff")._session(tab)` answer `entry`, so code that
--- resolves a review from a tabpage (comments.store_for, marks.refresh) can be
--- tested against a sentinel tab id with no real review behind it. Any other
--- tabpage still reaches the real registry. Returns a restore function; call it
--- from after_each.
function M.fake_session(tab, entry)
  local intentdiff = require("intentdiff")
  local real = intentdiff._session
  intentdiff._session = function(t)
    if t == tab then
      return entry
    end
    return real(t)
  end
  return function()
    intentdiff._session = real
  end
end

--- A synthetic painted pane showing lines 1..n of `file` on `side` — the shape
--- render/plan.lua produces and the comment layer consumes. `map` is sparse in
--- a real plan (separators and fillers address nothing); here every row
--- addresses a line, which is what a whole-file render of one file looks like.
function M.fake_pane(file, side, n)
  local pane = { lines = {}, spans = {}, map = {} }
  for i = 1, n do
    pane.lines[i] = "line " .. i
    pane.map[i] = { file = file, line = i, side = side }
  end
  return pane
end

--- Wait until fn() is truthy or timeout (ms). Returns fn()'s value.
function M.wait_for(fn, timeout)
  local result
  vim.wait(timeout or 5000, function()
    result = fn()
    return result and true or false
  end, 10)
  return result
end

--- Create an executable shell script named `name` that runs `body` (sh), and
--- prepend its dir to $PATH. Returns a restore function.
function M.fake_bin(name, body)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/" .. name
  vim.fn.writefile(vim.list_extend({ "#!/bin/sh" }, vim.split(body, "\n")), file)
  vim.fn.system({ "chmod", "+x", file })
  local old_path = vim.env.PATH
  vim.env.PATH = dir .. ":" .. old_path
  return function() vim.env.PATH = old_path end
end

return M
