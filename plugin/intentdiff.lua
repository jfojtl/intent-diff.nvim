if vim.g.loaded_intentdiff then
  return
end
vim.g.loaded_intentdiff = true

vim.api.nvim_create_user_command("IntentDiff", function(cmd)
  require("intentdiff").open(cmd.args)
end, { nargs = "*", desc = "Grouped-by-reason diff review" })

vim.api.nvim_create_user_command("IntentDiffLog", function()
  require("intentdiff").show_log()
end, { desc = "Show the intent-diff diagnostics log" })
