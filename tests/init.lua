vim.opt.shadafile = "NONE"
vim.opt.swapfile = false
-- Sandbox stdpath("cache") for the whole test run so intentdiff's
-- stdpath-derived defaults (cache_dir, log_file) never touch the real
-- machine's cache directory for specs that don't explicitly override them
-- (this must run before anything requires intentdiff.config, which computes
-- these defaults once at require-time).
vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local cwd = vim.fn.getcwd()
vim.opt.rtp:prepend(cwd)
package.path = package.path .. ";" .. cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua"

-- plenary: clone into data dir if missing
local plenary_dir = vim.fn.stdpath("data") .. "/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end
vim.opt.rtp:prepend(plenary_dir)

-- codediff: prefer the lazy.nvim install, else clone
local codediff_dir = vim.env.INTENTDIFF_CODEDIFF_DIR
  or (vim.fn.stdpath("data") .. "/lazy/codediff.nvim")
if vim.fn.isdirectory(codediff_dir) == 0 then
  codediff_dir = vim.fn.stdpath("data") .. "/codediff.nvim"
  if vim.fn.isdirectory(codediff_dir) == 0 then
    vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/esmuellert/codediff.nvim", codediff_dir })
  end
end
vim.opt.rtp:prepend(codediff_dir)
vim.cmd("runtime! plugin/*.lua")
pcall(function() require("codediff").setup() end)
