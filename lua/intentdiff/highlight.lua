-- Highlight groups for the sidebar and the intent preview.
--
-- Every group is defined with `default = true`, so an explicit user definition
-- (before or after setup) always wins. Re-applied on ColorScheme because
-- `:colorscheme` clears user highlight definitions.
local M = {}

-- IntentDiffAdd/Delete/AddChar/DeleteChar are NOT in this table: a plain link
-- to a foreground group (the old `Added`/`Removed`/`DiffText` links) is wrong
-- for them — a changed row needs a tinted BACKGROUND so treesitter's own
-- foreground survives, and the two Char groups need to actually differ from
-- each other. They are derived colors instead; see M.diff_colors below.
M.links = {
  IntentDiffGroupTitle = "Title",
  IntentDiffGroupStats = "Comment",
  IntentDiffDirectory = "Directory",
  IntentDiffIndent = "Comment",
  IntentDiffStatusA = "Added",
  IntentDiffStatusM = "Changed",
  IntentDiffStatusD = "Removed",
  IntentDiffStatusUntracked = "Added",
  IntentDiffFileSeparator = "Title",
  -- Deliberately fg-only (no bg): filler rows carry no text, so this group's
  -- only visible job is to stay inert — Normal's background shows through,
  -- which now reads as clearly distinct from a real changed row's tint.
  IntentDiffFiller = "Comment",
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

-- GitHub-PR-style fallback tints, used only when the active colourscheme
-- defines neither DiffAdd nor DiffDelete (rare, but must degrade to
-- something legible rather than an invisible/undefined group).
local FALLBACK = {
  dark = { add = 0x033a16, delete = 0x67060c },
  light = { add = 0xe6ffec, delete = 0xffebe9 },
}

--- Read a highlight group's effective GUI background as a 0xRRGGBB integer,
--- or nil when the group defines neither `bg` nor (via `reverse`) `fg`.
--- Some colourschemes (the built-in `sorbet`, for one) define DiffAdd /
--- DiffDelete as `fg` + `reverse = true`; Neovim's renderer swaps fg<->bg at
--- draw time, so the visually-correct "background" comes from `fg` there.
local function effective_bg(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or not hl then
    return nil
  end
  if hl.reverse then
    return hl.fg
  end
  return hl.bg
end

--- Multiply a 0xRRGGBB color's channels by `factor`, clamped to 0-255.
local function adjust_brightness(color, factor)
  if not color then
    return nil
  end
  local r = math.floor(color / 65536) % 256
  local g = math.floor(color / 256) % 256
  local b = color % 256
  r = math.min(255, math.floor(r * factor))
  g = math.min(255, math.floor(g * factor))
  b = math.min(255, math.floor(b * factor))
  return r * 65536 + g * 256 + b
end

--- The four diff-tint groups: a whole-row background for IntentDiffAdd /
--- IntentDiffDelete (derived from the colourscheme's own DiffAdd / DiffDelete
--- background — falling back to a GitHub-PR-style tint chosen by
--- 'background' when the scheme defines neither), and a stronger, same-hue
--- background for IntentDiffAddChar / IntentDiffDeleteChar so the actually
--- changed words stand out inside the tinted row.
---
--- The Char groups are NOT derived from the scheme's DiffText: DiffText is a
--- single group, so both sides deriving from it is exactly today's bug (an
--- add and a delete char highlight that are identical). Instead each Char
--- group is its own line color pushed further from the UI background by a
--- fixed factor — brighter on a dark background, darker on a light one.
--- Either direction reads as "more saturated than the row it sits in",
--- which is how GitHub relates its own line/word diff colors in both themes
--- (e.g. light line #e6ffec vs. word #abf2bc: the word is *darker*; dark line
--- #033a16 vs. word #196c2e: the word is *lighter* — both more saturated
--- than their line). Same shape of derivation as
--- codediff.ui.highlights.setup's char_insert/char_delete, reused here
--- rather than required — see the task report for why.
function M.diff_colors()
  local variant = vim.o.background == "light" and "light" or "dark"
  local fallback = FALLBACK[variant]

  local line_add = effective_bg("DiffAdd") or fallback.add
  local line_delete = effective_bg("DiffDelete") or fallback.delete
  local factor = variant == "light" and 0.92 or 1.4

  return {
    IntentDiffAdd = { bg = line_add },
    IntentDiffDelete = { bg = line_delete },
    IntentDiffAddChar = { bg = adjust_brightness(line_add, factor) },
    IntentDiffDeleteChar = { bg = adjust_brightness(line_delete, factor) },
  }
end

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
  for name, def in pairs(M.diff_colors()) do
    def.default = true
    vim.api.nvim_set_hl(0, name, def)
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
