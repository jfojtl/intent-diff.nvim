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

vim.api.nvim_create_user_command("IntentDiffToggleAll", function()
  require("intentdiff").toggle_all()
end, { desc = "Collapse or expand every intent in the sidebar" })

vim.api.nvim_create_user_command("IntentDiffSidebar", function()
  require("intentdiff").toggle_sidebar()
end, { desc = "Show or hide the intent-diff sidebar" })

--- Review-comment commands. Registered unconditionally — this file runs long
--- before setup() decides whether comments are enabled — but each one refuses
--- to do anything while `comments.enabled = false`, so the feature really is
--- inert when it is turned off.
local function comments_off()
  if not require("intentdiff.config").comments_enabled() then
    vim.notify("intent-diff: review comments are disabled", vim.log.levels.WARN)
    return true
  end
  return false
end

vim.api.nvim_create_user_command("IntentDiffCommentsYank", function()
  if comments_off() then
    return
  end
  require("intentdiff.comments").export_clipboard()
end, { desc = "intent-diff: copy review comments as Markdown" })

vim.api.nvim_create_user_command("IntentDiffCommentsWrite", function(opts)
  if comments_off() then
    return
  end
  require("intentdiff.comments").export_file(nil, opts.args)
end, { nargs = "?", complete = "file", desc = "intent-diff: write review comments to a file" })

vim.api.nvim_create_user_command("IntentDiffCommentsList", function()
  if comments_off() then
    return
  end
  require("intentdiff.comments").list()
end, { desc = "intent-diff: list review comments" })

vim.api.nvim_create_user_command("IntentDiffCommentsClear", function()
  if comments_off() then
    return
  end
  require("intentdiff.comments").clear()
end, { desc = "intent-diff: delete every review comment" })

vim.api.nvim_create_user_command("IntentDiffCommentsSubmit", function()
  if comments_off() then
    return
  end
  require("intentdiff.comments").submit()
end, { desc = "intent-diff: submit the review to the pull request" })
