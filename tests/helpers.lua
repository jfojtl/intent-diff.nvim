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
