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
  IntentDiffFileSeparator = "Title",
  IntentDiffFiller = "Comment",
  IntentDiffAddChar = "DiffText",
  IntentDiffDeleteChar = "DiffText",
  IntentDiffSignAdd = "Added",
  IntentDiffSignDelete = "Removed",
  IntentDiffCommentNote = "DiagnosticHint",
  IntentDiffCommentSuggestion = "DiagnosticInfo",
  IntentDiffCommentIssue = "DiagnosticWarn",
  IntentDiffCommentPraise = "DiagnosticOk",
  IntentDiffCommentNoteLine = "CursorLine",
  IntentDiffCommentSuggestionLine = "CursorLine",
  IntentDiffCommentIssueLine = "CursorLine",
  IntentDiffCommentPraiseLine = "CursorLine",
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

--- Sign and line highlight groups for a comment type, derived from its key so
--- a user-configured type needs no extra registration: "issue" →
--- IntentDiffCommentIssue / IntentDiffCommentIssueLine.
--- @return string sign_group, string line_group
function M.comment_groups(type_key)
  local key = tostring(type_key or "note")
  local name = "IntentDiffComment" .. key:sub(1, 1):upper() .. key:sub(2)
  return name, name .. "Line"
end

local function define()
  for name, target in pairs(M.links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  -- A user-configured type beyond the built-in four has no entry in M.links;
  -- point it at the note defaults so it still renders.
  local ok, config = pcall(require, "intentdiff.config")
  local types = ok and config.options and config.options.comments
    and config.options.comments.types or {}
  for _, t in ipairs(types) do
    local sign, line = M.comment_groups(t.key)
    if not M.links[sign] then
      local ok_sign = pcall(vim.api.nvim_set_hl, 0, sign, { link = "DiagnosticHint", default = true })
      local ok_line = pcall(vim.api.nvim_set_hl, 0, line, { link = "CursorLine", default = true })
      -- Both calls succeeded or both failed; log a warning if either fails, but continue.
      if not (ok_sign and ok_line) then
        vim.notify(
          "intent-diff: custom comment type '" .. tostring(t.key) .. "' has invalid group name",
          vim.log.levels.WARN
        )
      end
    end
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
