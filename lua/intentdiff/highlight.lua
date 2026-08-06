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
  IntentDiffCommentNote = "DiagnosticHint",
  IntentDiffCommentSuggestion = "DiagnosticInfo",
  IntentDiffCommentIssue = "DiagnosticWarn",
  IntentDiffCommentPraise = "DiagnosticOk",
  IntentDiffCommentNoteLine = "CursorLine",
  IntentDiffCommentSuggestionLine = "CursorLine",
  IntentDiffCommentIssueLine = "CursorLine",
  IntentDiffCommentPraiseLine = "CursorLine",
}

-- Canonical GitHub-style hues, blended into the editor's own Normal
-- background's BRIGHTNESS (see `blended_tint` below) whenever a
-- colourscheme's own DiffAdd/DiffDelete either doesn't exist or doesn't
-- actually read as green/red — see `is_green`/`is_red`. Also used as the
-- last-resort fallback when even Normal's background is unavailable.
local CANONICAL = {
  add = { r = 0x3f, g = 0xb9, b = 0x50 }, -- GitHub-ish green, #3fb950
  delete = { r = 0xf8, g = 0x51, b = 0x49 }, -- GitHub-ish red, #f85149
}
-- How much canonical hue to mix into Normal's brightness. 0.3, not the more
-- visually subtle ~0.2 a GitHub-style tint would suggest, because the blend
-- must guarantee a passing is_green/is_red at BOTH ends of the brightness
-- range: mixing into a base that is itself pure white or pure black leaves
-- the least headroom, and 0.3 is the smallest round number with a
-- comfortable margin there (verified by sweeping brightness 0-255 against
-- both canonical colors — worst case is the green add tint on a
-- near-white base, margin ~9 out of 255 at this factor, ~1 and threatening
-- to invert at 0.2).
local BLEND_FACTOR = 0.3

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

--- Same idea as effective_bg, but for the cterm (256-color terminal) side,
--- where `reverse` is `hl.cterm.reverse` if set, else falls back to the gui
--- `hl.reverse` (colourschemes rarely bother setting cterm reverse
--- separately when gui reverse is already true).
local function effective_ctermbg(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or not hl then
    return nil
  end
  -- Not `(hl.cterm and hl.cterm.reverse) or hl.reverse`: if a colourscheme
  -- sets `cterm = { reverse = false }` explicitly (gui reverse true, cterm
  -- deliberately not), that pattern would silently fall through to
  -- `hl.reverse` and get it backwards.
  local cterm_reverse = hl.reverse
  if hl.cterm and hl.cterm.reverse ~= nil then
    cterm_reverse = hl.cterm.reverse
  end
  if cterm_reverse then
    return hl.ctermfg
  end
  return hl.ctermbg
end

local function to_rgb(color)
  return math.floor(color / 65536) % 256, math.floor(color / 256) % 256, color % 256
end

local function to_hex(r, g, b)
  return r * 65536 + g * 256 + b
end

--- Multiply a 0xRRGGBB color's channels by `factor`, clamped to 0-255.
local function adjust_brightness(color, factor)
  if not color then
    return nil
  end
  local r, g, b = to_rgb(color)
  r = math.min(255, math.floor(r * factor))
  g = math.min(255, math.floor(g * factor))
  b = math.min(255, math.floor(b * factor))
  return to_hex(r, g, b)
end

--- `canonical` mixed into `base`'s BRIGHTNESS (not `base` itself) by
--- BLEND_FACTOR, per channel. Blending from the editor's own background
--- brightness rather than a fixed hardcoded tint is what makes this adapt to
--- light vs. dark automatically while still pinning the hue: on a near-black
--- Normal it lands as a dark, muted red/green; on a near-white one, a pale
--- tint — the same relationship GitHub's own light/dark line colors have to
--- their respective page backgrounds.
---
--- Deliberately desaturates `base` to a single brightness value first,
--- rather than blending its actual R/G/B: several built-in colourschemes
--- (the one literally named `blue`, for one) tint `Normal` itself with a
--- strong hue, and blending a minority fraction of canonical red/green into
--- that base can still leave the *base's* hue dominant — exactly the
--- off-hue-result bug this function exists to prevent, just moved one level
--- up. A brightness-only base can't out-vote the canonical hue: for any
--- brightness 0-255, mixing at BLEND_FACTOR still passes is_green/is_red
--- (verified by sweeping the full range against both canonical colors).
local function blended_tint(base, canonical)
  local br, bg, bb = to_rgb(base)
  local brightness = (br + bg + bb) / 3
  local r = math.floor(brightness + (canonical.r - brightness) * BLEND_FACTOR)
  local g = math.floor(brightness + (canonical.g - brightness) * BLEND_FACTOR)
  local b = math.floor(brightness + (canonical.b - brightness) * BLEND_FACTOR)
  return to_hex(r, g, b)
end

-- How much a channel must clear the other two by to count as "meaningfully
-- dominant" — small enough that a real (if muted) green/red like habamax's
-- DiffAdd #273923 (G−R=18, G−B=22 in absolute terms, but proportionally
-- ~30-40% over both) still passes, large enough to reject a near-tie like
-- the classic-Vim DiffDelete #af5faf (R=175, B=175 — equal, so R can never
-- clear B by this ratio no matter how the margin is tuned).
local DOMINANCE_RATIO = 1.1

--- True when `color` genuinely reads as green: G meaningfully greater than
--- BOTH R and B. G alone being the largest channel isn't enough — e.g. cyan
--- (G and B both high, R low) would pass a same-channel-only check.
local function is_green(color)
  local r, g, b = to_rgb(color)
  return g > r * DOMINANCE_RATIO and g > b * DOMINANCE_RATIO
end

--- True when `color` genuinely reads as red: R meaningfully greater than
--- BOTH G and B. This is what rejects classic-Vim's DiffDelete #af5faf
--- (R=175, G=95, B=175): R clears G easily, but R == B, so R can never
--- clear B by any positive margin — magenta, not red.
local function is_red(color)
  local r, g, b = to_rgb(color)
  return r > g * DOMINANCE_RATIO and r > b * DOMINANCE_RATIO
end

--- The bg for one side's line tint: the colourscheme's own DiffAdd/DiffDelete
--- background when it exists AND actually has the right hue, else the
--- canonical hue blended into the editor's own Normal background — never a
--- flat hardcoded color, so it still adapts to the active colourscheme even
--- on the fallback path.
local function line_bg(source_group, hue_ok, canonical)
  local from_scheme = effective_bg(source_group)
  if from_scheme and hue_ok(from_scheme) then
    return from_scheme
  end
  local normal_bg = effective_bg("Normal")
    or (vim.o.background == "light" and 0xffffff or 0x000000)
  return blended_tint(normal_bg, canonical)
end

--- The four diff-tint groups: a whole-row background for IntentDiffAdd /
--- IntentDiffDelete (derived from the colourscheme's own DiffAdd / DiffDelete
--- background when — and only when — it actually reads as green/red; a
--- canonical hue blended into Normal's background otherwise, see `line_bg`
--- above), and a stronger, same-hue background for IntentDiffAddChar /
--- IntentDiffDeleteChar so the actually changed words stand out inside the
--- tinted row.
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
---
--- ctermbg is copied straight from the scheme's own DiffAdd/DiffDelete (not
--- re-derived from the gui color — a full RGB→256-cube mapping is more than
--- this needs) so a `termguicolors = false` user gets *a* color rather than
--- none; the Char groups reuse the same index, since a real distinct 256-color
--- shade isn't worth the complexity here.
function M.diff_colors()
  local variant = vim.o.background == "light" and "light" or "dark"
  local line_add = line_bg("DiffAdd", is_green, CANONICAL.add)
  local line_delete = line_bg("DiffDelete", is_red, CANONICAL.delete)
  local factor = variant == "light" and 0.92 or 1.4
  local ctermbg_add = effective_ctermbg("DiffAdd") or 2 -- ANSI green
  local ctermbg_delete = effective_ctermbg("DiffDelete") or 1 -- ANSI red

  return {
    IntentDiffAdd = { bg = line_add, ctermbg = ctermbg_add },
    IntentDiffDelete = { bg = line_delete, ctermbg = ctermbg_delete },
    IntentDiffAddChar = { bg = adjust_brightness(line_add, factor), ctermbg = ctermbg_add },
    IntentDiffDeleteChar = { bg = adjust_brightness(line_delete, factor), ctermbg = ctermbg_delete },
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
