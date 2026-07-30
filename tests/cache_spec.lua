local cache = require("intentdiff.cache")
local config = require("intentdiff.config")

describe("cache", function()
  before_each(function()
    config.setup({ cache_dir = vim.fn.tempname() })
  end)

  it("round-trips an entry", function()
    local entry = {
      groups = { { title = "T", hunk_ids = { "a.lua:1" } } },
      hunk_hashes = { ["a.lua:1"] = "h1" },
    }
    cache.save("deadbeef", entry)
    assert.same(entry, cache.load("deadbeef"))
  end)

  it("returns nil for missing or corrupt entries", function()
    assert.is_nil(cache.load("nope"))
    vim.fn.mkdir(config.options.cache_dir, "p")
    vim.fn.writefile({ "{not json" }, config.options.cache_dir .. "/bad.json")
    assert.is_nil(cache.load("bad"))
  end)

  it("delete removes the entry", function()
    cache.save("k", { groups = {}, hunk_hashes = {} })
    cache.delete("k")
    assert.is_nil(cache.load("k"))
  end)

  it("remembers the last classified diff hash per scope", function()
    assert.is_nil(cache.get_last_hash("/repo|"))
    cache.set_last_hash("/repo|", "hash-a")
    cache.set_last_hash("/repo|main...", "hash-b")
    assert.equals("hash-a", cache.get_last_hash("/repo|"))
    assert.equals("hash-b", cache.get_last_hash("/repo|main..."))
    -- Overwriting one scope leaves the others intact.
    cache.set_last_hash("/repo|", "hash-c")
    assert.equals("hash-c", cache.get_last_hash("/repo|"))
    assert.equals("hash-b", cache.get_last_hash("/repo|main..."))
    -- Survives a corrupt index file instead of erroring.
    vim.fn.writefile({ "{not json" }, config.options.cache_dir .. "/last_hashes.json")
    assert.is_nil(cache.get_last_hash("/repo|"))
    cache.set_last_hash("/repo|", "hash-d")
    assert.equals("hash-d", cache.get_last_hash("/repo|"))
  end)

  it("rematch keeps content-identical hunks, counts the rest stale", function()
    local entry = {
      groups = {
        { title = "A", hunk_ids = { "a.lua:1" } },
        { title = "B", hunk_ids = { "b.lua:1" } },
      },
      hunk_hashes = { ["a.lua:1"] = "same", ["b.lua:1"] = "old" },
    }
    local inventory = {
      hunks = {
        -- content unchanged but id shifted (hunk moved down the file)
        { id = "a.lua:2", content_hash = "same" },
        -- edited since classification
        { id = "b.lua:1", content_hash = "new" },
      },
    }
    local raw, stale = cache.rematch(entry, inventory)
    assert.same({ "a.lua:2" }, raw[1].hunk_ids)
    assert.same({}, raw[2].hunk_ids)
    assert.equals(1, stale)
  end)
end)
