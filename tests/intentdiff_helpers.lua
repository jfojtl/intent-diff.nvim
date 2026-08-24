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

--- Write raw bytes to `path`, NUL bytes included.
---
--- Not M.write_file: vim.fn.writefile is line-oriented and rewrites NUL, so a
--- binary fixture has to go through io to survive the round trip.
function M.write_bytes(repo, path, bytes)
  local abs = repo .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
  local fh = assert(io.open(abs, "wb"))
  fh:write(bytes)
  fh:close()
  return abs
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

--- Back the `+` and `*` registers with an in-process table. Returns a restore
--- function.
---
--- Any test that reads a register back needs this. A bare headless Neovim
--- cannot: with no clipboard tool on PATH (CI's ubuntu-latest has none) the
--- provider resolves to nothing, every write to those registers is dropped and
--- `getreg` answers "" — which fails even the `setreg` in a test's own setup.
--- A macOS dev box passes off `pbcopy`, so the gap only ever shows up in CI.
---
--- `g:clipboard` is checked ahead of every built-in provider, so this makes the
--- registers real and deterministic everywhere, with no clipboard tool,
--- `$DISPLAY` or `xvfb` involved. It also keeps `+` and `*` genuinely
--- independent (distinct copy functions), so asserting both is two assertions
--- rather than one written twice.
function M.fake_clipboard()
  local board = { ["+"] = { {}, "v" }, ["*"] = { {}, "v" } }
  local previous = vim.g.clipboard
  -- The provider is resolved once, when its autoload file is first sourced,
  -- and the answer cached in g:loaded_clipboard_provider. Setting g:clipboard
  -- afterwards changes nothing until that runs again.
  local function reload()
    vim.g.loaded_clipboard_provider = nil
    vim.cmd("runtime autoload/provider/clipboard.vim")
  end
  vim.g.clipboard = {
    name = "intentdiff-test",
    copy = {
      ["+"] = function(lines, regtype) board["+"] = { lines, regtype } end,
      ["*"] = function(lines, regtype) board["*"] = { lines, regtype } end,
    },
    paste = {
      ["+"] = function() return board["+"] end,
      ["*"] = function() return board["*"] end,
    },
  }
  reload()
  return function()
    vim.g.clipboard = previous
    reload()
  end
end

return M
