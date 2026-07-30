local classify = require("intentdiff.classify")
local cache = require("intentdiff.cache")
local config = require("intentdiff.config")
local log = require("intentdiff.log")
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

--- Multi-hunk inventory (two files, three hunks) for exercising compact-id
--- numbering end-to-end through classify.run.
local function mk_multi_inventory(hash)
  local function h(file, n, line)
    return {
      id = file .. ":" .. n, file = file, status = "M", content_hash = file .. n,
      text = "@@ x\n", header = "@@",
      original = { start_line = line, end_line = line + 1 },
      modified = { start_line = line, end_line = line + 1 },
    }
  end
  return {
    hunks = { h("a.lua", 1, 1), h("a.lua", 2, 5), h("b.lua", 1, 1) },
    files = { { path = "a.lua", status = "M" }, { path = "b.lua", status = "M" } },
    diff_text = "multi diff",
    diff_hash = hash or "multi-hash",
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

  it("runs with different session_keys do not supersede each other", function()
    local first, second
    classify.run(mk_inventory("h-key-a"), {
      session_key = "session-a",
      provider = provider_returning({ { title = "A", hunk_ids = { "a.lua:1" } } }),
    }, function(g) first = g end)
    classify.run(mk_inventory("h-key-b"), {
      session_key = "session-b",
      provider = provider_returning({ { title = "B", hunk_ids = { "a.lua:1" } } }),
    }, function(g) second = g end)
    helpers.wait_for(function() return first and second end)
    assert.equals("A", first[1].title)
    assert.equals("B", second[1].title)
  end)

  it("a newer run with the SAME session_key supersedes the older in-flight run", function()
    local slow_cb
    local first_fired = false
    classify.run(mk_inventory("h-key-slow"), {
      session_key = "session-c",
      provider = function(_, cb) slow_cb = cb return { cancel = function() end } end,
    }, function() first_fired = true end)
    local second
    classify.run(mk_inventory("h-key-fast"), {
      session_key = "session-c",
      provider = provider_returning({ { title = "Second", hunk_ids = { "a.lua:1" } } }),
    }, function(g) second = g end)
    helpers.wait_for(function() return second end)
    slow_cb({ groups = { { title = "Late", hunk_ids = { "a.lua:1" } } } })
    vim.wait(200, function() return false end, 50)
    assert.is_false(first_fired)
  end)

  it("cancels the superseded provider run instead of leaving it running", function()
    local cancelled = 0
    classify.run(mk_inventory("h-cancel-1"), {
      session_key = "session-cancel",
      provider = function() return { cancel = function() cancelled = cancelled + 1 end } end,
    }, function() end)
    assert.equals(0, cancelled)

    -- Same session, newer run ⇒ the first provider's job is now pointless.
    local second
    classify.run(mk_inventory("h-cancel-2"), {
      session_key = "session-cancel",
      provider = provider_returning({ { title = "Second", hunk_ids = { "a.lua:1" } } }),
    }, function(g) second = g end)
    helpers.wait_for(function() return second end)
    assert.equals(1, cancelled)

    -- Closing the session cancels whatever is still in flight.
    local third_cancelled = 0
    classify.run(mk_inventory("h-cancel-3"), {
      session_key = "session-cancel",
      provider = function() return { cancel = function() third_cancelled = third_cancelled + 1 end } end,
    }, function() end)
    assert.is_true(classify.cancel("session-cancel"))
    assert.equals(1, third_cancelled)
    assert.is_false(classify.cancel("session-cancel")) -- nothing left to cancel
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

  it("build_request numbers hunks 1..N in inventory order and exposes numbering", function()
    local req = classify.build_request(mk_multi_inventory())
    assert.equals(1, req.hunks[1].n)
    assert.equals(2, req.hunks[2].n)
    assert.equals(3, req.hunks[3].n)
    assert.same({ [1] = "a.lua:1", [2] = "a.lua:2", [3] = "b.lua:1" }, req.numbering)
  end)

  it("build_request omits request.repo when opts carries none", function()
    local req = classify.build_request(mk_inventory())
    assert.is_nil(req.repo)
  end)

  it("build_request threads opts.repo onto request.repo", function()
    local req = classify.build_request(mk_inventory(), {
      repo = { git_root = "/tmp/repo", base_revision = "abc123", target_revision = "WORKING" },
    })
    assert.same({ git_root = "/tmp/repo", base_revision = "abc123", target_revision = "WORKING" }, req.repo)
  end)

  describe("compact-id provider responses end to end", function()
    --- Wraps a provider so it can assert on the request it was handed
    --- (specifically request.numbering) before replying with compact ids.
    local function compact_id_provider(ids_by_group)
      return function(request, cb)
        assert.truthy(request.numbering, "provider did not receive a numbering map")
        local groups = {}
        for _, entry in ipairs(ids_by_group) do
          groups[#groups + 1] = { title = entry.title, ids = entry.ids }
        end
        vim.schedule(function() cb({ groups = groups }) end)
        return { cancel = function() end }
      end
    end

    it("a provider returning compact ids covering only some hunks leaves the rest Ungrouped", function()
      local groups, info
      classify.run(mk_multi_inventory("compact-partial"), {
        provider = compact_id_provider({ { title = "First", ids = "1" } }),
      }, function(g, _, i) groups, info = g, i end)
      helpers.wait_for(function() return groups end)
      assert.equals(2, #groups)
      assert.equals("First", groups[1].title)
      assert.equals(1, #groups[1].hunks)
      assert.equals("a.lua:1", groups[1].hunks[1].id)
      assert.equals("Ungrouped", groups[2].title)
      assert.equals(2, #groups[2].hunks)
      assert.is_nil(info.cached)
    end)

    it("a provider returning garbage compact ids puts everything in Ungrouped", function()
      local groups
      classify.run(mk_multi_inventory("compact-garbage"), {
        provider = compact_id_provider({ { title = "Garbage", ids = "not-a-number,999,-1" } }),
      }, function(g) groups = g end)
      helpers.wait_for(function() return groups end)
      assert.equals(1, #groups)
      assert.equals("Ungrouped", groups[1].title)
      assert.equals(3, #groups[1].hunks)
    end)

    it("a provider returning a full range covers every hunk with no Ungrouped group", function()
      local groups
      classify.run(mk_multi_inventory("compact-full"), {
        provider = compact_id_provider({ { title = "Everything", ids = "1-3" } }),
      }, function(g) groups = g end)
      helpers.wait_for(function() return groups end)
      assert.equals(1, #groups)
      assert.equals("Everything", groups[1].title)
      assert.equals(3, #groups[1].hunks)
    end)

    it("a legacy provider returning hunk_ids arrays keeps working identically", function()
      local groups
      classify.run(mk_multi_inventory("legacy-shape"), {
        provider = provider_returning({
          { title = "Legacy", hunk_ids = { "a.lua:1", "b.lua:1" } },
        }),
      }, function(g) groups = g end)
      helpers.wait_for(function() return groups end)
      assert.equals(2, #groups)
      assert.equals("Legacy", groups[1].title)
      assert.equals(2, #groups[1].hunks)
      assert.equals("Ungrouped", groups[2].title)
      assert.equals(1, #groups[2].hunks)
      assert.equals("a.lua:2", groups[2].hunks[1].id)
    end)

    it("mixes legacy hunk_ids and compact ids across groups in the SAME response", function()
      local groups
      classify.run(mk_multi_inventory("mixed-shapes"), {
        provider = function(_, cb)
          vim.schedule(function()
            cb({ groups = {
              { title = "Legacy", hunk_ids = { "a.lua:1" } },
              { title = "Compact", ids = "3" },
            } })
          end)
          return { cancel = function() end }
        end,
      }, function(g) groups = g end)
      helpers.wait_for(function() return groups end)
      -- a.lua:1 -> Legacy, b.lua:1 -> Compact, a.lua:2 unmentioned -> Ungrouped.
      assert.equals(3, #groups)
      assert.equals("Legacy", groups[1].title)
      assert.equals("Compact", groups[2].title)
      assert.equals("Ungrouped", groups[3].title)
    end)

    it("records the mapping-failure count in the diagnostics log", function()
      local log_file = vim.fn.tempname()
      config.setup({ cache_dir = vim.fn.tempname(), log_file = log_file })
      local groups
      classify.run(mk_multi_inventory("log-mapping-failures"), {
        provider = compact_id_provider({ { title = "T", ids = "1,999,-4" } }), -- 999 and -4 unmappable
      }, function(g) groups = g end)
      helpers.wait_for(function() return groups end)

      local lines = log.read(log_file)
      local reconcile_line
      for _, line in ipairs(lines) do
        if line:find("reconcile", 1, true) then
          reconcile_line = line
        end
      end
      assert.truthy(reconcile_line, "no reconcile log entry found:\n" .. table.concat(lines, "\n"))
      assert.truthy(reconcile_line:find("id_mapping_failures=2", 1, true),
        "mapping-failure count missing from reconcile entry: " .. reconcile_line)
    end)
  end)
end)
