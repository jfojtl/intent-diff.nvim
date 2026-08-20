local github = require("intentdiff.forges.github")
local helpers = require("tests.helpers")

describe("forges.github discussion mutations", function()
  local restore, capture

  after_each(function()
    if restore then restore() restore = nil end
  end)

  local function fake_gh(response)
    capture = vim.fn.tempname()
    restore = helpers.fake_bin("gh", ([=[
printf '%%s\n' "$@" > %s.args
case "$*" in
  *--input*) cat > %s.stdin ;;
  *) : > %s.stdin ;;
esac
echo '%s'
]=]):format(capture, capture, capture, response))
  end

  local function target()
    return { id = "9", git_root = vim.fn.getcwd() }
  end

  it("posts a reply to the root review comment with the body on stdin", function()
    fake_gh('{"id":12,"body":"thanks"}')
    local result, err, done
    github.reply(target(), { remote_id = "10" }, "thanks\nall fixed", function(r, e)
      result, err, done = r, e, true
    end)
    assert.truthy(helpers.wait_for(function() return done end))
    assert.is_nil(err)
    assert.equals(12, result.id)
    local args = table.concat(vim.fn.readfile(capture .. ".args"), "\n")
    assert.truthy(args:find("repos/{owner}/{repo}/pulls/9/comments/10/replies", 1, true))
    local input = vim.json.decode(table.concat(vim.fn.readfile(capture .. ".stdin"), "\n"))
    assert.equals("thanks\nall fixed", input.body)
  end)

  it("resolves and reopens a GraphQL review thread", function()
    fake_gh('{"data":{"resolveReviewThread":{"thread":{"id":"T1","isResolved":true}}}}')
    local result, err, done
    github.resolve_thread(target(), { thread_id = "T1" }, true, function(r, e)
      result, err, done = r, e, true
    end)
    assert.truthy(helpers.wait_for(function() return done end))
    assert.is_nil(err)
    assert.truthy(result.data.resolveReviewThread)
    local args = table.concat(vim.fn.readfile(capture .. ".args"), "\n")
    assert.truthy(args:find("resolveReviewThread", 1, true))
    assert.truthy(args:find("threadId=T1", 1, true))

    restore()
    restore = nil
    fake_gh('{"data":{"unresolveReviewThread":{"thread":{"id":"T1","isResolved":false}}}}')
    done = nil
    github.resolve_thread(target(), { thread_id = "T1" }, false, function(r, e)
      result, err, done = r, e, true
    end)
    assert.truthy(helpers.wait_for(function() return done end))
    args = table.concat(vim.fn.readfile(capture .. ".args"), "\n")
    assert.truthy(args:find("unresolveReviewThread", 1, true))
  end)
end)
