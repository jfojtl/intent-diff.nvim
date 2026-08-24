local has_telescope = pcall(require, "telescope")

describe("telescope extension", function()
  if not has_telescope then
    it("skips when telescope.nvim is absent", function()
      assert.is_true(true)
    end)
    return
  end

  it("registers an intents picker", function()
    require("telescope").load_extension("intentdiff")
    local ext = require("telescope").extensions.intentdiff
    assert.is_function(ext.intents)
  end)

  it("builds entries from a model without touching a real review", function()
    require("telescope").load_extension("intentdiff")
    local ext = require("telescope").extensions.intentdiff
    -- nil store, not {}: comment_icon treats any truthy store as a real one and
    -- calls store.get_for_file on it.
    local entry = ext._entry_maker({
      kind = "file",
      group_title = "Add retry logic",
      path = "src/a.lua",
      additions = 3,
      deletions = 1,
    }, nil)
    assert.equals("Add retry logic src/a.lua", entry.ordinal)
    assert.is_function(entry.display)
  end)
end)

describe("intentdiff.find without a review", function()
  it("returns false rather than erroring", function()
    assert.is_false(require("intentdiff").find())
  end)
end)
