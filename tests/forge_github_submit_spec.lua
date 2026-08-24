local helpers = require("tests.intentdiff_helpers")
local github = require("intentdiff.forges.github")

local restore, capture

--- A fake `gh` that writes its stdin to `capture` and echoes a review object.
local function fake_gh(body)
  capture = vim.fn.tempname()
  return helpers.fake_bin("gh", ([[
cat > %s
%s
]]):format(capture, body))
end

local function sent()
  local content = table.concat(vim.fn.readfile(capture), "\n")
  return vim.json.decode(content)
end

local function target()
  return {
    service = "github", id = "123", url = "https://github.com/o/r/pull/123",
    title = "T", head_sha = "aaaabbbb", base_ref = "main",
  }
end

local function submit(payload)
  local got, err, kind, done
  github.submit(target(), payload, function(r, e, k)
    got, err, kind, done = r, e, k, true
  end)
  helpers.wait_for(function() return done end)
  return got, err, kind, done
end

describe("forges.github.submit", function()
  after_each(function()
    if restore then
      restore()
      restore = nil
    end
  end)

  it("posts one review pinned to the PR head", function()
    restore = fake_gh([[echo '{"html_url":"https://github.com/o/r/pull/123#pullrequestreview-1"}']])
    local got, err = submit({
      verdict = "request_changes",
      body = "the body",
      comments = {
        { path = "src/api/routes.ts", line = 5, side = "new",
          body = "**[ISSUE]** x", file_level = false },
      },
    })
    assert.is_nil(err)
    assert.equals("https://github.com/o/r/pull/123#pullrequestreview-1", got.url)
    local json = sent()
    assert.equals("aaaabbbb", json.commit_id)
    assert.equals("REQUEST_CHANGES", json.event)
    assert.equals("the body", json.body)
    assert.equals(1, #json.comments)
    assert.equals("src/api/routes.ts", json.comments[1].path)
    assert.equals(5, json.comments[1].line)
    assert.equals("RIGHT", json.comments[1].side)
    assert.equals("**[ISSUE]** x", json.comments[1].body)
  end)

  it("translates a range, the old side and a file-level comment", function()
    restore = fake_gh([[echo '{"html_url":"u"}']])
    local _, _, _, done = submit({
      verdict = "comment",
      body = "b",
      comments = {
        { path = "a.ts", line = 44, line_end = 51, side = "new", body = "r", file_level = false },
        { path = "b.ts", line = 41, side = "old", body = "o", file_level = false },
        { path = "c.ts", line = 0, side = "new", body = "f", file_level = true },
        { path = "d.ts", line = 12, line_end = 12, side = "new", body = "s", file_level = false },
      },
    })
    assert.is_true(done)
    local c = sent().comments
    assert.equals(44, c[1].start_line)
    assert.equals(51, c[1].line)
    assert.equals("RIGHT", c[1].start_side)
    assert.equals("RIGHT", c[1].side)
    assert.equals("LEFT", c[2].side)
    assert.equals(41, c[2].line)
    assert.is_nil(c[2].start_line)
    assert.equals("file", c[3].subject_type)
    assert.is_nil(c[3].line)
    assert.is_nil(c[3].side)
    -- line_end == line is a single-line comment, not a zero-length range:
    -- payload.lua passes line_end through unnormalized, so this input is
    -- reachable, and a degenerate start_line == line is a 422.
    assert.equals(12, c[4].line)
    assert.is_nil(c[4].start_line)
    assert.is_nil(c[4].start_side)
    assert.equals("RIGHT", c[4].side)
  end)

  it("omits the comments key entirely when there are none", function()
    restore = fake_gh([[echo '{"html_url":"u"}']])
    local _, _, _, done = submit({ verdict = "approve", body = "b", comments = {} })
    assert.is_true(done)
    local json = sent()
    assert.equals("APPROVE", json.event)
    -- An empty Lua table encodes as {} — GitHub rejects that for an array
    -- field, so the key must be absent rather than empty.
    assert.is_nil(json.comments)
  end)

  it("flags GitHub refusing a self-approval", function()
    restore = fake_gh([[
echo '{"message":"Unprocessable Entity","errors":["Can not approve your own pull request"]}' >&2
exit 1
]])
    local got, err, kind = submit({ verdict = "approve", body = "b", comments = {} })
    assert.is_nil(got)
    assert.equals("self_approve", kind)
    assert.is_truthy(err:match("own pull request"))
  end)

  it("reports an unanchorable line without inventing a partial success", function()
    restore = fake_gh([[
echo '{"message":"Validation Failed","errors":[{"message":"line must be part of the diff"}]}' >&2
exit 1
]])
    local got, err, kind = submit({
      verdict = "comment", body = "b",
      comments = { { path = "a.ts", line = 9999, side = "new", body = "x", file_level = false } },
    })
    assert.is_nil(got)
    assert.is_nil(kind)
    assert.is_truthy(err:match("line must be part of the diff"))
  end)
end)
