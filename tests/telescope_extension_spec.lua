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
    -- Actually call it, so the nil-store path comment_icon takes runs for
    -- real, not just the file_icon call _entry_maker already made eagerly.
    -- The displayer's fixed-width columns resolve their width against a real
    -- picker's results window (telescope.state.get_status(bufnr).layout...),
    -- which doesn't exist outside an active picker, so fake just enough of
    -- that state for the current buffer/window to let the real column-width
    -- math run instead of erroring. `displayer` returns `string, highlights`;
    -- asserting on just the first return is enough.
    require("telescope.state").set_status(vim.api.nvim_get_current_buf(), {
      layout = { results = { winid = vim.api.nvim_get_current_win() } },
      picker = { selection_caret = "> " },
    })
    assert.is_string(entry.display(entry))
  end)
end)

describe("intentdiff.find without a review", function()
  it("returns false rather than erroring", function()
    assert.is_false(require("intentdiff").find())
  end)
end)
