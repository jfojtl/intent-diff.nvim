-- Highlight groups for the sidebar and the intent preview.
--
-- Every group is defined with `default = true`, so an explicit user definition
-- (before or after setup) always wins. Re-applied on ColorScheme because
-- `:colorscheme` clears user highlight definitions.
local M = {}

M.links = {
  IntentDiffGroupTitle = "Title",
  IntentDiffGroupStats = "Comment",
  IntentDiffAdd = "Added",
  IntentDiffDelete = "Removed",
  IntentDiffDirectory = "Directory",
  IntentDiffIndent = "Comment",
  IntentDiffStatusA = "Added",
  IntentDiffStatusM = "Changed",
  IntentDiffStatusD = "Removed",
  IntentDiffStatusUntracked = "Added",
  IntentDiffPreviewFile = "Title",
  IntentDiffPreviewHunk = "Comment",
  IntentDiffFiller = "Comment",
}

--- Status letter → highlight group, for the sidebar's status gutter and the
--- preview's file separators.
function M.status_group(status)
  if status == "A" then
    return "IntentDiffStatusA"
  elseif status == "D" then
    return "IntentDiffStatusD"
  elseif status == "??" then
    return "IntentDiffStatusUntracked"
  end
  return "IntentDiffStatusM"
end

--- The single character shown in the status gutter.
function M.status_char(status)
  return status == "??" and "?" or (status or "M")
end

local function define()
  for name, target in pairs(M.links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

local augroup

--- Define the groups and keep them defined across colorscheme changes.
function M.ensure()
  define()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("IntentDiffHighlight", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = define })
end

return M
