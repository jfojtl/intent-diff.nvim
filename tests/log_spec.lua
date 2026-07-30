local log = require("intentdiff.log")
local config = require("intentdiff.config")

describe("intentdiff.log", function()
  it("writes and reads back entries at a temp log_file", function()
    local path = vim.fn.tempname()
    log.append({ kind = "classification", outcome = "cache_hit" }, path)
    log.append({ kind = "classification", outcome = "provider_success" }, path)
    local lines = log.read(path)
    assert.equals(2, #lines)
    assert.truthy(lines[1]:find("classification", 1, true))
    assert.truthy(lines[1]:find("outcome=cache_hit", 1, true))
    assert.truthy(lines[2]:find("outcome=provider_success", 1, true))
  end)

  it("uses config.options.log_file when no explicit path is given", function()
    local path = vim.fn.tempname()
    config.setup({ log_file = path })
    log.append({ kind = "classification", outcome = "cache_hit" })
    local lines = log.read()
    assert.equals(1, #lines)
    assert.truthy(lines[1]:find("outcome=cache_hit", 1, true))
  end)

  it("returns an empty list when the log file does not exist", function()
    local lines = log.read(vim.fn.tempname())
    assert.same({}, lines)
  end)

  it("truncates to bound the file size while retaining the newest entry", function()
    local path = vim.fn.tempname()
    local old_max = log.max_bytes
    log.max_bytes = 500
    for i = 1, 200 do
      log.append({ kind = "classification", outcome = "provider_success", n = i,
        note = string.rep("x", 40) }, path)
    end
    log.max_bytes = old_max

    local size = vim.fn.getfsize(path)
    assert.is_true(size > 0)
    assert.is_true(size <= 500, "log file not bounded: " .. size .. " bytes")

    local lines = log.read(path)
    assert.truthy(lines[#lines]:find("n=200", 1, true), "newest entry missing after truncation")
  end)
end)

describe(":IntentDiffLog", function()
  after_each(function()
    -- Close any scratch buffer/window the command opened.
    pcall(vim.cmd, "silent! bwipeout!")
  end)

  it("shows a friendly message when no log exists yet", function()
    config.setup({ log_file = vim.fn.tempname() })
    vim.cmd("IntentDiffLog")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local text = table.concat(lines, "\n")
    assert.truthy(text:lower():find("no.*entries", 1, false), "unexpected buffer content: " .. text)
  end)

  it("opens a buffer containing a written entry, cursor at the end", function()
    local path = vim.fn.tempname()
    config.setup({ log_file = path })
    log.append({ kind = "classification", outcome = "provider_success" })
    log.append({ kind = "reconcile", total_hunks = 3, unrecognized = 1 })
    vim.cmd("IntentDiffLog")
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("provider_success", 1, true))
    assert.truthy(text:find("unrecognized=1", 1, true))
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equals(#lines, cursor[1])
    assert.equals("nofile", vim.bo[buf].buftype)
  end)
end)
