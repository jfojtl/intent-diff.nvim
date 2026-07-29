if vim.g.loaded_intentdiff then
  return
end
vim.g.loaded_intentdiff = true

vim.api.nvim_create_user_command("IntentDiff", function(cmd)
  require("intentdiff").open(cmd.args)
end, { nargs = "*", desc = "Grouped-by-reason diff review" })
