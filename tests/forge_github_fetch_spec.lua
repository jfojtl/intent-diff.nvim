local github = require("intentdiff.forges.github")
local helpers = require("tests.helpers")

describe("forges.github pull request discussion", function()
  local restore

  after_each(function()
    if restore then restore() restore = nil end
  end)

  it("normalizes inline threads, replies, outdated coordinates, and general discussion", function()
    local got = github.normalize_discussion({
      {
        id = 10, in_reply_to_id = vim.NIL, path = "src/a.lua", line = 8,
        start_line = 6, side = "RIGHT",
        body = "root", created_at = "2026-08-18T10:00:00Z", html_url = "inline-url",
        user = { login = "alice" },
      },
      {
        id = 11, in_reply_to_id = 10, path = "src/a.lua", line = 8, side = "RIGHT",
        body = "reply", created_at = "2026-08-18T11:00:00Z", user = { login = "bob" },
      },
      {
        id = 20, path = "old.lua", line = vim.NIL, original_line = 40,
        original_start_line = 39, original_side = "LEFT", body = "old",
        created_at = "2026-08-17T10:00:00Z", user = { login = "carol" },
      },
    }, {
      { id = 30, body = "general", created_at = "2026-08-19T10:00:00Z",
        html_url = "general-url", user = { login = "dave" } },
    }, {
      { id = 40, body = "summary", state = "CHANGES_REQUESTED",
        submitted_at = "2026-08-19T09:00:00Z", user = { login = "erin" } },
      { id = 41, body = "", state = "APPROVED", user = { login = "frank" } },
    })

    assert.equals(4, got.comment_count)
    assert.equals(2, got.thread_count)
    assert.equals(2, #got.inline)
    assert.equals(2, #got.general)

    local old, thread
    for _, c in ipairs(got.inline) do
      if c.file == "old.lua" then old = c else thread = c end
    end
    assert.equals(39, old.line)
    assert.equals(40, old.line_end)
    assert.equals("old", old.side)
    assert.truthy(old.display_name:find("outdated", 1, true))
    assert.equals("@alice\nroot\n\n↳ @bob\nreply", thread.text)
    assert.equals(1, thread.reply_count)
    assert.equals("root", thread.original_body)
    assert.equals("review", got.general[1].remote_kind)
    assert.truthy(got.general[1].display_name:find("changes requested", 1, true))
    assert.equals("general", got.general[2].text)
  end)

  it("fetches all three paginated GitHub resources", function()
    restore = helpers.fake_bin("gh", [=[
case "$4" in
  */pulls/*/comments)
    echo '[[{"id":1,"path":"a.lua","line":3,"side":"RIGHT","body":"inline","created_at":"2026-01-01T00:00:00Z","user":{"login":"a"}}]]'
    ;;
  */issues/*/comments)
    echo '[[{"id":2,"body":"general","created_at":"2026-01-02T00:00:00Z","user":{"login":"b"}}]]'
    ;;
  */pulls/*/reviews)
    echo '[[{"id":3,"body":"review","state":"APPROVED","submitted_at":"2026-01-03T00:00:00Z","user":{"login":"c"}}]]'
    ;;
esac
]=])
    local result, err, done
    github.fetch_comments({ id = "9", git_root = vim.fn.getcwd() }, function(r, e)
      result, err, done = r, e, true
    end)
    assert.truthy(helpers.wait_for(function() return done end))
    assert.is_nil(err)
    assert.equals(1, result.thread_count)
    assert.equals(2, #result.general)
    assert.equals(3, #result.comments)
  end)

  it("surfaces an endpoint failure without returning partial discussion", function()
    restore = helpers.fake_bin("gh", [[
echo 'not authorized' >&2
exit 4
]])
    local result, err, done
    github.fetch_comments({ id = "9", git_root = vim.fn.getcwd() }, function(r, e)
      result, err, done = r, e, true
    end)
    assert.truthy(helpers.wait_for(function() return done end))
    assert.is_nil(result)
    assert.truthy(err:find("not authorized", 1, true))
  end)
end)
