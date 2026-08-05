describe("highlight", function()
  it("defines every documented group as a link", function()
    local hl = require("intentdiff.highlight")
    hl.ensure()
    for name, target in pairs(hl.links) do
      local def = vim.api.nvim_get_hl(0, { name = name })
      assert.equals(target, def.link, name .. " must link to " .. target)
    end
  end)

  it("covers the groups the sidebar and preview use", function()
    local hl = require("intentdiff.highlight")
    for _, name in ipairs({
      "IntentDiffGroupTitle", "IntentDiffGroupStats", "IntentDiffAdd",
      "IntentDiffDelete", "IntentDiffDirectory", "IntentDiffIndent",
      "IntentDiffStatusA", "IntentDiffStatusM", "IntentDiffStatusD",
      "IntentDiffStatusUntracked", "IntentDiffFileSeparator",
      "IntentDiffPreviewHunk", "IntentDiffFiller",
    }) do
      assert.is_string(hl.links[name], name .. " must be defined")
    end
  end)

  it("does not clobber a user override", function()
    local hl = require("intentdiff.highlight")
    vim.api.nvim_set_hl(0, "IntentDiffAdd", { fg = "#ff0000" })
    hl.ensure()
    local def = vim.api.nvim_get_hl(0, { name = "IntentDiffAdd" })
    assert.is_nil(def.link)
    -- Properly reset: use highlight clear then re-ensure to restore the link
    vim.cmd("highlight clear IntentDiffAdd")
    hl.ensure()
    local restored = vim.api.nvim_get_hl(0, { name = "IntentDiffAdd" })
    assert.equals("Added", restored.link, "IntentDiffAdd must be restored to Added after reset")
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
