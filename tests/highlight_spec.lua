describe("highlight", function()
  it("defines every documented group as a link", function()
    local hl = require("intentdiff.highlight")
    hl.ensure()
    for name, target in pairs(hl.links) do
      local def = vim.api.nvim_get_hl(0, { name = name })
      assert.equals(target, def.link, name .. " must link to " .. target)
    end
  end)

  it("covers the groups the sidebar and the renderer use", function()
    local hl = require("intentdiff.highlight")
    for _, name in ipairs({
      "IntentDiffGroupTitle", "IntentDiffGroupStats",
      "IntentDiffDirectory", "IntentDiffIndent",
      "IntentDiffStatusA", "IntentDiffStatusM", "IntentDiffStatusD",
      "IntentDiffStatusUntracked", "IntentDiffFileSeparator",
      "IntentDiffFiller",
    }) do
      assert.is_string(hl.links[name], name .. " must be defined")
    end
    -- IntentDiffAdd/Delete are derived colors, not links — see the
    -- "diff-tint groups" describe block below.
    assert.is_nil(hl.links.IntentDiffAdd)
    assert.is_nil(hl.links.IntentDiffDelete)
  end)

  it("does not clobber a user override", function()
    local hl = require("intentdiff.highlight")
    vim.api.nvim_set_hl(0, "IntentDiffAdd", { fg = "#ff0000" })
    hl.ensure()
    local def = vim.api.nvim_get_hl(0, { name = "IntentDiffAdd" })
    assert.equals(0xff0000, def.fg)
    assert.is_nil(def.bg)
    -- Properly reset: use highlight clear then re-ensure to restore the
    -- derived background.
    vim.cmd("highlight clear IntentDiffAdd")
    hl.ensure()
    local restored = vim.api.nvim_get_hl(0, { name = "IntentDiffAdd" })
    assert.is_nil(restored.fg, "IntentDiffAdd must be background-only after reset")
    assert.equals(hl.diff_colors().IntentDiffAdd.bg, restored.bg,
      "IntentDiffAdd must be restored to the derived background after reset")
  end)

  it("is idempotent", function()
    local hl = require("intentdiff.highlight")
    hl.ensure()
    hl.ensure()
    assert.equals(1, #vim.api.nvim_get_autocmds({ group = "IntentDiffHighlight" }))
  end)
end)

describe("highlight comments", function()
  it("derives sign and line groups from a type key", function()
    local hl = require("intentdiff.highlight")
    local sign, line = hl.comment_groups("issue")
    assert.equals("IntentDiffCommentIssue", sign)
    assert.equals("IntentDiffCommentIssueLine", line)
  end)

  it("derives groups for a custom type key too", function()
    local hl = require("intentdiff.highlight")
    local sign, line = hl.comment_groups("question")
    assert.equals("IntentDiffCommentQuestion", sign)
    assert.equals("IntentDiffCommentQuestionLine", line)
  end)

  it("defines the four built-in comment groups as default links", function()
    local hl = require("intentdiff.highlight")
    hl.ensure()
    local got = vim.api.nvim_get_hl(0, { name = "IntentDiffCommentIssue" })
    assert.is_true(got.default)
    assert.equals("DiagnosticWarn", got.link)
  end)

  it("registers fallback groups for custom well-formed comment types", function()
    local hl = require("intentdiff.highlight")
    local config = require("intentdiff.config")
    config.setup({
      comments = {
        types = {
          { key = "question", name = "Question", icon = "?" },
        },
      },
    })
    hl.ensure()
    local sign = vim.api.nvim_get_hl(0, { name = "IntentDiffCommentQuestion" })
    local line = vim.api.nvim_get_hl(0, { name = "IntentDiffCommentQuestionLine" })
    assert.is_true(sign.default)
    assert.equals("DiagnosticHint", sign.link)
    assert.is_true(line.default)
    assert.equals("CursorLine", line.link)
  end)

  it("does not error when a custom type has a malformed key", function()
    local hl = require("intentdiff.highlight")
    local config = require("intentdiff.config")
    config.setup({
      comments = {
        types = {
          { key = "bad type", name = "Bad Type", icon = "X" },
        },
      },
    })
    -- This should not raise an error, even though the key has a space
    assert.has_no_errors(function()
      hl.ensure()
    end)
  end)
end)

describe("highlight groups for the unified renderer", function()
  it("defines the separator, character and sign groups", function()
    require("intentdiff.highlight").ensure()
    for _, name in ipairs({
      "IntentDiffFileSeparator",
      "IntentDiffAddChar", "IntentDiffDeleteChar",
      "IntentDiffSignAdd", "IntentDiffSignDelete",
    }) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      assert.truthy(hl and next(hl) ~= nil, name .. " is not defined")
    end
  end)

  it("no longer defines the old preview-file group", function()
    require("intentdiff.highlight").ensure()
    local hl = vim.api.nvim_get_hl(0, { name = "IntentDiffPreviewFile" })
    assert.is_true(hl == nil or next(hl) == nil, "IntentDiffPreviewFile should be gone")
  end)
end)

-- GitHub-PR-style diff tint: a whole-row background on IntentDiffAdd /
-- IntentDiffDelete (no fg, so treesitter's own foreground survives), and a
-- darker/stronger, same-hue background on the Char variants so the words
-- that actually changed stand out inside the tinted row.
describe("diff-tint groups (IntentDiffAdd/Delete/AddChar/DeleteChar)", function()
  local hl

  before_each(function()
    hl = require("intentdiff.highlight")
    -- An earlier spec in this file configures a custom (some deliberately
    -- malformed) comment type and never resets it; that state is shared
    -- module state, not per-test, so it leaks here too. `:colorscheme`
    -- fires our ColorScheme autocmd synchronously as part of the command
    -- itself, and unlike a plain hl.ensure() call, a pcall-caught error
    -- inside that callback still surfaces as a failing `:colorscheme` —
    -- reset before every case here so a leaked bad type from another spec
    -- can't turn "switch colorscheme" into an error.
    require("intentdiff.config").setup({})
    -- `:colorscheme` itself runs `highlight clear` before reloading, which
    -- wipes any IntentDiffAdd override a previous spec in this file left
    -- behind; every case below switches scheme as its first step anyway, but
    -- land on a known one here too so that holds even for a case that
    -- doesn't.
    vim.cmd("colorscheme default")
  end)

  --- Every group in `names` has a `bg` but no `fg`, both from nvim_get_hl
  --- (what actually renders) and from hl.diff_colors() (what we compute).
  local function assert_bg_only(names)
    local computed = hl.diff_colors()
    for _, name in ipairs(names) do
      assert.is_number(computed[name].bg, name .. " must derive a bg")
      assert.is_nil(computed[name].fg, name .. " must not derive a fg")
      local resolved = vim.api.nvim_get_hl(0, { name = name, link = false })
      assert.equals(computed[name].bg, resolved.bg, name .. " resolved bg must match the derivation")
      assert.is_nil(resolved.fg, name .. " must render with no fg, so treesitter's survives")
    end
  end

  --- `bg` (a 0xRRGGBB int) actually reads as `hue` ("green" or "red"): the
  --- named channel meaningfully clears BOTH other channels — not just one,
  --- which is what let classic-Vim's DiffDelete #af5faf (R=175, G=95,
  --- B=175) read as "red" before: R clears G easily, but R == B, so it's
  --- magenta, not red. Same shape of check the implementation itself uses
  --- (DOMINANCE_RATIO in highlight.lua), asserted here black-box against
  --- what nvim_get_hl actually resolved — this is the maintainer's original
  --- complaint category ("is it actually red/green"), which the group's
  --- mere existence or its bg-vs-fg shape says nothing about.
  local function assert_hue(bg, hue, label)
    local r = math.floor(bg / 65536) % 256
    local g = math.floor(bg / 256) % 256
    local b = bg % 256
    local detail = (" (resolved to r=%d g=%d b=%d)"):format(r, g, b)
    if hue == "green" then
      assert.is_true(g > r * 1.1 and g > b * 1.1, label .. " must read as green" .. detail)
    else
      assert.is_true(r > g * 1.1 and r > b * 1.1, label .. " must read as red" .. detail)
    end
  end

  it("derives a bg-only line tint and a distinct, stronger bg-only char tint (dark scheme)", function()
    vim.cmd("colorscheme habamax")
    hl.ensure()
    assert_bg_only({ "IntentDiffAdd", "IntentDiffDelete", "IntentDiffAddChar", "IntentDiffDeleteChar" })
    local c = hl.diff_colors()
    assert.not_equals(c.IntentDiffAdd.bg, c.IntentDiffAddChar.bg, "AddChar must differ from its line group")
    assert.not_equals(c.IntentDiffDelete.bg, c.IntentDiffDeleteChar.bg, "DeleteChar must differ from its line group")
    assert.not_equals(c.IntentDiffAddChar.bg, c.IntentDiffDeleteChar.bg, "AddChar and DeleteChar must differ from each other")
    -- habamax's own DiffAdd/DiffDelete are already genuinely green/red, so
    -- this exercises the "use the scheme's own color" path.
    assert_hue(c.IntentDiffAdd.bg, "green", "IntentDiffAdd on habamax")
    assert_hue(c.IntentDiffDelete.bg, "red", "IntentDiffDelete on habamax")
    assert_hue(c.IntentDiffAddChar.bg, "green", "IntentDiffAddChar on habamax")
    assert_hue(c.IntentDiffDeleteChar.bg, "red", "IntentDiffDeleteChar on habamax")
  end)

  it("derives a bg-only line tint and a distinct, stronger bg-only char tint (light scheme)", function()
    vim.cmd("colorscheme morning")
    hl.ensure()
    assert_bg_only({ "IntentDiffAdd", "IntentDiffDelete", "IntentDiffAddChar", "IntentDiffDeleteChar" })
    local c = hl.diff_colors()
    assert.not_equals(c.IntentDiffAdd.bg, c.IntentDiffAddChar.bg, "AddChar must differ from its line group")
    assert.not_equals(c.IntentDiffDelete.bg, c.IntentDiffDeleteChar.bg, "DeleteChar must differ from its line group")
    assert.not_equals(c.IntentDiffAddChar.bg, c.IntentDiffDeleteChar.bg, "AddChar and DeleteChar must differ from each other")
    -- morning is classic-Vim family: its own DiffDelete is #af5faf, which is
    -- magenta (R == B), not red. This is the exact case the hue check
    -- exists for — IntentDiffDelete must NOT resolve to that magenta; it
    -- must fall back to the blended canonical red instead, and still read
    -- as red. DiffAdd (#5f875f) is genuinely green already, so that side
    -- exercises the "keep the scheme's own color" path in the same test.
    assert.not_equals(0xaf5faf, c.IntentDiffDelete.bg,
      "IntentDiffDelete must not be morning's own magenta DiffDelete")
    assert_hue(c.IntentDiffAdd.bg, "green", "IntentDiffAdd on morning")
    assert_hue(c.IntentDiffDelete.bg, "red", "IntentDiffDelete on morning")
    assert_hue(c.IntentDiffAddChar.bg, "green", "IntentDiffAddChar on morning")
    assert_hue(c.IntentDiffDeleteChar.bg, "red", "IntentDiffDeleteChar on morning")
  end)

  it("handles a DiffAdd/DiffDelete defined via fg + reverse (e.g. the built-in sorbet)", function()
    vim.cmd("colorscheme sorbet")
    hl.ensure()
    assert_bg_only({ "IntentDiffAdd", "IntentDiffDelete", "IntentDiffAddChar", "IntentDiffDeleteChar" })
  end)

  it("falls back to a legible, correctly-hued tint when the scheme defines none of DiffAdd/DiffDelete/DiffText", function()
    vim.cmd("colorscheme habamax")
    vim.cmd("highlight clear DiffAdd")
    vim.cmd("highlight clear DiffDelete")
    vim.cmd("highlight clear DiffText")
    -- `default = true` only takes when the target group is itself
    -- undefined; habamax's own colorscheme autocmd already gave
    -- IntentDiffAdd &c. real values above, so those need clearing too
    -- before hl.ensure() will recompute them from the now-cleared sources.
    vim.cmd("highlight clear IntentDiffAdd")
    vim.cmd("highlight clear IntentDiffDelete")
    vim.cmd("highlight clear IntentDiffAddChar")
    vim.cmd("highlight clear IntentDiffDeleteChar")
    hl.ensure()
    assert_bg_only({ "IntentDiffAdd", "IntentDiffDelete", "IntentDiffAddChar", "IntentDiffDeleteChar" })
    local c = hl.diff_colors()
    assert.not_equals(c.IntentDiffAdd.bg, c.IntentDiffDelete.bg, "add and delete fallbacks must differ")
    assert_hue(c.IntentDiffAdd.bg, "green", "IntentDiffAdd fallback")
    assert_hue(c.IntentDiffDelete.bg, "red", "IntentDiffDelete fallback")
    assert_hue(c.IntentDiffAddChar.bg, "green", "IntentDiffAddChar fallback")
    assert_hue(c.IntentDiffDeleteChar.bg, "red", "IntentDiffDeleteChar fallback")
  end)

  it("re-derives on ColorScheme instead of freezing to the scheme active at setup", function()
    vim.cmd("colorscheme habamax")
    hl.ensure()
    local dark = vim.api.nvim_get_hl(0, { name = "IntentDiffAdd", link = false }).bg
    vim.cmd("colorscheme morning")
    local light = vim.api.nvim_get_hl(0, { name = "IntentDiffAdd", link = false }).bg
    assert.not_equals(dark, light, "IntentDiffAdd must track the active colorscheme")
  end)

  --- A termguicolors=false user gets *some* color, not none: before this
  --- derivation existed, these four groups linked to Added/Removed/DiffText,
  --- which carry a ctermbg/ctermfg via the active colorscheme; a plain
  --- `{ bg = ... }` table with no ctermbg would have silently dropped that.
  it("sets a ctermbg on all four groups, from the scheme when available", function()
    vim.cmd("colorscheme habamax")
    hl.ensure()
    local c = hl.diff_colors()
    for _, name in ipairs({ "IntentDiffAdd", "IntentDiffDelete", "IntentDiffAddChar", "IntentDiffDeleteChar" }) do
      assert.is_number(c[name].ctermbg, name .. " must have a ctermbg")
    end
    -- habamax's own DiffAdd/DiffDelete carry ctermbg 22/52; the derived
    -- groups must reuse those, not invent their own.
    assert.equals(22, c.IntentDiffAdd.ctermbg)
    assert.equals(22, c.IntentDiffAddChar.ctermbg)
    assert.equals(52, c.IntentDiffDelete.ctermbg)
    assert.equals(52, c.IntentDiffDeleteChar.ctermbg)
  end)

  it("still sets a ctermbg when DiffAdd/DiffDelete are cleared", function()
    vim.cmd("colorscheme habamax")
    vim.cmd("highlight clear DiffAdd")
    vim.cmd("highlight clear DiffDelete")
    hl.ensure()
    local c = hl.diff_colors()
    for _, name in ipairs({ "IntentDiffAdd", "IntentDiffDelete", "IntentDiffAddChar", "IntentDiffDeleteChar" }) do
      assert.is_number(c[name].ctermbg, name .. " must have a ctermbg even on the fallback path")
    end
  end)
end)
