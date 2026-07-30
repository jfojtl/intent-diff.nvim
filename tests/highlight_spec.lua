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
      "IntentDiffStatusUntracked", "IntentDiffPreviewFile",
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
