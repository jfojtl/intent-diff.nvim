local classify = require("intentdiff.classify")
local cache = require("intentdiff.cache")
local config = require("intentdiff.config")
local helpers = require("tests.helpers")

local function mk_inventory(hash)
  return {
    hunks = {
      { id = "a.lua:1", file = "a.lua", status = "M", content_hash = "c1", text = "@@ x\n",
        header = "@@", original = { start_line = 1, end_line = 2 }, modified = { start_line = 1, end_line = 2 } },
    },
    files = { { path = "a.lua", status = "M" } },
    diff_text = "small diff",
    diff_hash = hash or "hash1",
  }
end

local function provider_returning(groups)
  return function(_, cb)
    vim.schedule(function() cb({ groups = groups }) end)
    return { cancel = function() end }
  end
end

describe("classify.run", function()
  before_each(function()
    config.setup({ cache_dir = vim.fn.tempname() })
  end)

  it("calls provider, reconciles, caches", function()
    local groups, info
    classify.run(mk_inventory(), {
      provider = provider_returning({ { title = "T", hunk_ids = { "a.lua:1" } } }),
    }, function(g, _, i) groups, info = g, i end)
    helpers.wait_for(function() return groups end)
    assert.equals("T", groups[1].title)
    assert.is_nil(info.cached)
    assert.truthy(cache.load("hash1"))
  end)

  it("serves the cache without calling the provider", function()
    cache.save("hash1", {
      groups = { { title = "Cached", hunk_ids = { "a.lua:1" } } },
      hunk_hashes = { ["a.lua:1"] = "c1" },
    })
    local called = false
    local groups, info
    classify.run(mk_inventory(), {
      provider = function() called = true end,
    }, function(g, _, i) groups, info = g, i end)
    helpers.wait_for(function() return groups end)
    assert.is_false(called)
    assert.is_true(info.cached)
    assert.equals("Cached", groups[1].title)
  end)

  it("rematches a cache from a different diff hash via content hashes", function()
    cache.save("old-hash", {
      groups = { { title = "Kept", hunk_ids = { "a.lua:9" } } },
      hunk_hashes = { ["a.lua:9"] = "c1" },
    })
    local groups, info
    classify.run(mk_inventory("new-hash"), {
      provider = function() error("should not be called") end,
      previous_hash = "old-hash",
    }, function(g, _, i) groups, info = g, i end)
    helpers.wait_for(function() return groups end)
    assert.equals("Kept", groups[1].title)
    assert.equals(0, info.stale_count)
  end)

  it("force bypasses the cache", function()
    cache.save("hash1", { groups = { { title = "Cached", hunk_ids = { "a.lua:1" } } }, hunk_hashes = {} })
    local groups
    classify.run(mk_inventory(), {
      provider = provider_returning({ { title = "Fresh", hunk_ids = { "a.lua:1" } } }),
      force = true,
    }, function(g) groups = g end)
    helpers.wait_for(function() return groups end)
    assert.equals("Fresh", groups[1].title)
  end)

  it("propagates provider errors", function()
    local err
    classify.run(mk_inventory(), {
      provider = function(_, cb) vim.schedule(function() cb(nil, "boom") end) end,
    }, function(_, e) err = e end)
    helpers.wait_for(function() return err end)
    assert.equals("boom", err)
  end)

  it("a newer run supersedes an older in-flight run", function()
    local slow_cb
    local first_fired = false
    classify.run(mk_inventory("h-slow"), {
      provider = function(_, cb) slow_cb = cb return { cancel = function() end } end,
    }, function() first_fired = true end)
    local second
    classify.run(mk_inventory("h-fast"), {
      provider = provider_returning({ { title = "Second", hunk_ids = { "a.lua:1" } } }),
    }, function(g) second = g end)
    helpers.wait_for(function() return second end)
    slow_cb({ groups = { { title = "Late", hunk_ids = { "a.lua:1" } } } })
    vim.wait(200, function() return false end, 50)
    assert.is_false(first_fired)
  end)

  it("skips classification above max_hunks", function()
    config.setup({ cache_dir = vim.fn.tempname(), max_hunks = 0 })
    local groups, info
    classify.run(mk_inventory(), {
      provider = function() error("should not be called") end,
    }, function(g, _, i) groups, info = g, i end)
    helpers.wait_for(function() return groups end)
    assert.equals("Ungrouped", groups[1].title)
    assert.truthy(info.skipped)
  end)

  it("build_request drops diff_text above max_full_diff_bytes", function()
    config.setup({ max_full_diff_bytes = 3 })
    local req = classify.build_request(mk_inventory())
    assert.is_nil(req.diff_text)
    assert.equals("a.lua:1", req.hunks[1].id)
    assert.truthy(#req.hunks[1].summary_lines > 0)
  end)
end)
