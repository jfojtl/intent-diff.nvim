-- GitHub, over the `gh` CLI.
--
-- `gh` rather than raw HTTP because it already holds the user's credentials,
-- knows the host aliases and enterprise instances they have configured, and
-- resolves {owner}/{repo} from the checkout — none of which this plugin should
-- reimplement.
--
-- Detecting and fetching are read-only. Submit, reply, and resolve/reopen only
-- run after an explicit UI action from the user.
local M = {}

local VERDICTS = { approve = "APPROVE", request_changes = "REQUEST_CHANGES", comment = "COMMENT" }

function M.matches(remote_url)
  if not remote_url then
    return false
  end
  return remote_url:match("github%.com") ~= nil
end

function M.capabilities()
  return {
    inline = true,
    file_comments = true,
    discussion = true,
    verdicts = { "approve", "request_changes", "comment" },
  }
end

--- Configured options, defaulted. Read at call time, not at require time, so
--- setup() ordering cannot matter.
function M.opts()
  local configured = ((require("intentdiff.config").options.forge_opts or {}).github) or {}
  return {
    cmd = configured.cmd or "gh",
    timeout_ms = configured.timeout_ms or 30000,
  }
end

--- Run `gh` in `git_root`, buffered, with a timeout. `stdin` is written and
--- the channel closed when given.
---
--- jobstart is used rather than vim.fn.system for the same reason
--- providers/claude_cli.lua uses it: a synchronous system() call freezes the
--- editor for however long the network takes.
--- @param cb fun(code: integer, stdout: string, stderr: string)
local function run(argv, git_root, stdin, cb)
  local opts = M.opts()
  local out, err = {}, {}
  local finished = false
  local function finish(code)
    if finished then
      return
    end
    finished = true
    cb(code, table.concat(out, "\n"), table.concat(err, "\n"))
  end
  local ok, job = pcall(vim.fn.jobstart, argv, {
    cwd = git_root,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data) out = data or {} end,
    on_stderr = function(_, data) err = data or {} end,
    on_exit = function(_, code) finish(code) end,
  })
  if not ok or job <= 0 then
    return finish(-1)
  end
  if stdin then
    pcall(vim.fn.chansend, job, stdin)
    pcall(vim.fn.chanclose, job, "stdin")
  end
  vim.defer_fn(function()
    if not finished then
      pcall(vim.fn.jobstop, job)
      finish(-2)
    end
  end, opts.timeout_ms)
end

--- Record one `gh` invocation to :IntentDiffLog. Never the comment text — the
--- log is a diagnostics file the user may paste into an issue.
local function record(fields)
  local ok, log = pcall(require, "intentdiff.log")
  if ok then
    log.append(vim.tbl_extend("force", { kind = "forge", service = "github" }, fields))
  end
end

local function failure(code, stderr, what)
  if code == -1 then
    return ("could not start '%s' — is the GitHub CLI installed?"):format(M.opts().cmd)
  end
  if code == -2 then
    return ("gh timed out while %s"):format(what)
  end
  local trimmed = vim.trim(stderr or "")
  if trimmed == "" then
    return ("gh exited with code %d while %s"):format(code, what)
  end
  return trimmed
end

local PR_FIELDS = "number,url,title,headRefOid,baseRefName,state"

--- Is `branch` linked to an open PR? Read-only.
---
--- "no pull requests found" is an ANSWER, not a failure: it means the branch
--- has no PR yet, which preflight turns into "create one first". Every other
--- non-zero exit is a real error and surfaces verbatim, because a missing or
--- unauthenticated gh must not read as "you have no PR".
--- @param cb fun(target: table|nil, err: string|nil)
function M.detect(git_root, branch, cb)
  local argv = { M.opts().cmd, "pr", "view", branch, "--json", PR_FIELDS }
  run(argv, git_root, nil, function(code, stdout, stderr)
    record({ event = "detect", exit_code = code })
    if code ~= 0 then
      if (stderr or ""):match("no pull requests found") then
        return cb(nil, nil)
      end
      return cb(nil, failure(code, stderr, "looking up the pull request"))
    end
    local ok, pr = pcall(vim.json.decode, stdout)
    if not ok or type(pr) ~= "table" or not pr.number then
      return cb(nil, "could not read gh's pull request JSON")
    end
    if pr.state and pr.state ~= "OPEN" then
      return cb(nil, ("PR #%d is %s — nothing to review"):format(pr.number, pr.state))
    end
    cb({
      service = "github",
      id = tostring(pr.number),
      url = pr.url,
      title = pr.title,
      head_sha = pr.headRefOid,
      base_ref = pr.baseRefName,
    })
  end)
end

--- One payload comment as the reviews API wants it.
---
--- A file-level comment uses subject_type = "file" and carries NO line or side:
--- sending either alongside it is a validation error. A range sends start_line
--- plus line, both on the same side — GitHub has no cross-side range.
local function api_comment(c)
  local side = (c.side == "old") and "LEFT" or "RIGHT"
  if c.file_level then
    return { path = c.path, subject_type = "file", body = c.body }
  end
  local out = { path = c.path, line = c.line, side = side, body = c.body }
  if c.line_end and c.line_end ~= c.line then
    out.start_line = c.line
    out.start_side = side
    out.line = c.line_end
  end
  return out
end

--- GitHub's refusal to let you approve your own PR, which is the common case
--- when an agent pushes to your branch. Worth its own kind so the flow can
--- offer the identical review as a plain COMMENT instead of just failing.
local function is_self_approve(stderr)
  return (stderr or ""):match("[Cc]an ?not approve your own pull request") ~= nil
end

--- Post ONE review: body, verdict and every inline comment, atomically.
---
--- Atomic is the API's choice, not ours — a single invalid line rejects the
--- whole review. That is why comments/anchor.lua filters locally first, and why
--- a failure here means NOTHING was posted, so no comment may be stamped.
---
--- `commit_id` pins the review to the head the preflight saw, so a push landing
--- between preflight and submit fails loudly instead of attaching the review to
--- a commit nobody reviewed.
--- @param cb fun(result: { url: string }|nil, err: string|nil, kind: string|nil)
function M.submit(target, payload, cb)
  local body = {
    commit_id = target.head_sha,
    event = VERDICTS[payload.verdict] or "COMMENT",
    body = payload.body,
  }
  -- Only when non-empty: vim.json.encode turns an empty Lua table into `{}`,
  -- and GitHub rejects an object where it expects an array of comments.
  if payload.comments and #payload.comments > 0 then
    local list = {}
    for _, c in ipairs(payload.comments) do
      list[#list + 1] = api_comment(c)
    end
    body.comments = list
  end

  local ok, encoded = pcall(vim.json.encode, body)
  if not ok then
    return cb(nil, "could not encode the review payload")
  end

  local path = ("repos/{owner}/{repo}/pulls/%s/reviews"):format(target.id)
  local argv = { M.opts().cmd, "api", "--method", "POST", path, "--input", "-" }
  run(argv, target.git_root, encoded, function(code, stdout, stderr)
    record({
      event = "submit",
      exit_code = code,
      verdict = body.event,
      comment_count = #(payload.comments or {}),
    })
    if code ~= 0 then
      if is_self_approve(stderr) then
        return cb(nil, failure(code, stderr, "submitting the review"), "self_approve")
      end
      return cb(nil, failure(code, stderr, "submitting the review"))
    end
    local decoded_ok, review = pcall(vim.json.decode, stdout)
    local url = decoded_ok and type(review) == "table" and review.html_url or target.url
    cb({ url = url })
  end)
end

--- Decode `gh api --paginate --slurp`: an array of pages, each containing an
--- array of objects. Accept a flat array too, which makes this tolerant of a
--- custom/fake gh and of a future CLI mode that returns a single page flat.
local function decode_pages(stdout)
  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  local out = {}
  for _, item in ipairs(decoded) do
    if type(item) == "table" and item[1] ~= nil then
      for _, nested in ipairs(item) do
        if type(nested) == "table" then
          out[#out + 1] = nested
        end
      end
    elseif type(item) == "table" then
      out[#out + 1] = item
    end
  end
  return out
end

--- PullRequestReviewThread metadata is GraphQL-only. Key it by the REST
--- database id of the thread's first comment, which is the bridge between the
--- two APIs and lets REST remain the source for fully-paginated comment bodies.
local function decode_thread_pages(stdout)
  local ok, pages = pcall(vim.json.decode, stdout)
  if not ok or type(pages) ~= "table" then return nil end
  -- --slurp wraps every GraphQL response page; tolerate an unwrapped response
  -- for custom gh shims in the same way decode_pages does for REST.
  if pages.data then pages = { pages } end
  local out = {}
  for _, page in ipairs(pages) do
    local connection = type(page) == "table" and page.data
      and page.data.repository and page.data.repository.pullRequest
      and page.data.repository.pullRequest.reviewThreads
    for _, thread in ipairs(connection and connection.nodes or {}) do
      local first = thread.comments and thread.comments.nodes and thread.comments.nodes[1]
      if first and first.fullDatabaseId then
        out[tostring(first.fullDatabaseId)] = thread
      end
    end
  end
  return out
end

local function present(value)
  if value == nil or value == vim.NIL then return nil end
  return value
end

local function login_of(item)
  local user = type(item.user) == "table" and item.user or nil
  return user and present(user.login) or "unknown"
end

local function nonempty(value)
  return type(value) == "string" and vim.trim(value) ~= ""
end

--- Turn GitHub's three conversation resources into service-neutral records.
--- Inline replies are collapsed into their root thread so one diff line gets
--- one readable box. General issue comments and review summaries have no line;
--- the comment list presents those in a Markdown float.
function M.normalize_discussion(review_comments, issue_comments, reviews, thread_metadata)
  thread_metadata = thread_metadata or {}
  local by_id, threads = {}, {}
  for _, item in ipairs(review_comments or {}) do
    by_id[tostring(item.id)] = item
  end
  for _, item in ipairs(review_comments or {}) do
    local root_id = tostring(present(item.in_reply_to_id) or item.id)
    threads[root_id] = threads[root_id] or {}
    threads[root_id][#threads[root_id] + 1] = item
  end

  local inline = {}
  for root_id, items in pairs(threads) do
    table.sort(items, function(a, b)
      local at, bt = tostring(a.created_at or ""), tostring(b.created_at or "")
      if at == bt then
        return tostring(a.id) < tostring(b.id)
      end
      return at < bt
    end)
    local root = by_id[root_id] or items[1]
    local metadata = thread_metadata[root_id] or {}
    local anchor = root
    if not present(anchor.path) then
      for _, item in ipairs(items) do
        if present(item.path) then anchor = item break end
      end
    end
    if anchor and present(anchor.path) then
      local last = present(anchor.line) or present(anchor.original_line)
      local first = present(anchor.start_line) or present(anchor.original_start_line) or last
      local side_name = present(anchor.side) or present(anchor.original_side)
      local text = {}
      for i, item in ipairs(items) do
        local prefix = (i == 1 and "@" or "↳ @") .. login_of(item)
        text[#text + 1] = prefix
        text[#text + 1] = nonempty(item.body) and item.body or "_(empty comment)_"
        if i < #items then text[#text + 1] = "" end
      end
      local author = login_of(root)
      local label = "GitHub · @" .. author
      if not present(anchor.line) and present(anchor.original_line) then
        label = label .. " · outdated"
      end
      if metadata.isResolved then
        label = label .. " · resolved"
      end
      inline[#inline + 1] = {
        remote = true,
        remote_kind = "inline",
        remote_id = root_id,
        type = "note",
        display_name = label,
        author = author,
        text = table.concat(text, "\n"),
        original_body = present(root.body),
        file = present(anchor.path),
        line = anchor.subject_type == "file" and 0 or first,
        line_end = (last and first and last ~= first) and last or nil,
        side = side_name == "LEFT" and "old" or "new",
        url = present(root.html_url),
        created_at = present(root.created_at),
        reply_count = math.max(0, #items - 1),
        thread_id = present(metadata.id),
        is_resolved = metadata.isResolved == true,
        is_outdated = metadata.isOutdated == true
          or (not present(anchor.line) and present(anchor.original_line) ~= nil),
        viewer_can_reply = metadata.viewerCanReply,
        viewer_can_resolve = metadata.viewerCanResolve,
        viewer_can_unresolve = metadata.viewerCanUnresolve,
        resolved_by = type(metadata.resolvedBy) == "table"
          and present(metadata.resolvedBy.login) or nil,
      }
    end
  end
  table.sort(inline, function(a, b)
    local at, bt = tostring(a.created_at or ""), tostring(b.created_at or "")
    if at == bt then return tostring(a.remote_id) < tostring(b.remote_id) end
    return at < bt
  end)

  local general = {}
  for _, item in ipairs(issue_comments or {}) do
    if nonempty(item.body) then
      local author = login_of(item)
      general[#general + 1] = {
        remote = true,
        remote_kind = "general",
        remote_id = "issue:" .. tostring(item.id),
        type = "note",
        display_name = "GitHub PR comment · @" .. author,
        author = author,
        text = item.body,
        url = present(item.html_url),
        created_at = present(item.created_at),
      }
    end
  end
  for _, item in ipairs(reviews or {}) do
    if nonempty(item.body) then
      local author = login_of(item)
      local state = tostring(item.state or "commented"):lower():gsub("_", " ")
      general[#general + 1] = {
        remote = true,
        remote_kind = "review",
        remote_id = "review:" .. tostring(item.id),
        type = "note",
        display_name = ("GitHub review · @%s · %s"):format(author, state),
        author = author,
        text = item.body,
        url = present(item.html_url),
        created_at = present(item.submitted_at) or present(item.created_at),
      }
    end
  end
  table.sort(general, function(a, b)
    return tostring(a.created_at or "") < tostring(b.created_at or "")
  end)

  local comments = {}
  vim.list_extend(comments, inline)
  vim.list_extend(comments, general)
  return {
    comments = comments,
    inline = inline,
    general = general,
    comment_count = #(review_comments or {}) + #(issue_comments or {}),
    thread_count = #inline,
  }
end

--- Fetch inline review comments/replies, general PR comments, and review
--- summaries. The three REST GETs and GraphQL metadata lookup run concurrently;
--- a slow endpoint does not make the others wait in series.
--- @param cb fun(discussion: table|nil, err: string|nil)
function M.fetch_comments(target, cb)
  local specs = {
    review_comments = ("repos/{owner}/{repo}/pulls/%s/comments"):format(target.id),
    issue_comments = ("repos/{owner}/{repo}/issues/%s/comments"):format(target.id),
    reviews = ("repos/{owner}/{repo}/pulls/%s/reviews"):format(target.id),
  }
  local remaining, results, completed = 4, {}, false
  local function complete_one()
    remaining = remaining - 1
    if remaining == 0 and not completed then
      completed = true
      cb(M.normalize_discussion(results.review_comments, results.issue_comments,
        results.reviews, results.thread_metadata))
    end
  end
  for key, path in pairs(specs) do
    local argv = { M.opts().cmd, "api", "--paginate", "--slurp", path }
    run(argv, target.git_root, nil, function(code, stdout, stderr)
      record({ event = "fetch", endpoint = key, exit_code = code })
      if completed then return end
      if code ~= 0 then
        completed = true
        return cb(nil, failure(code, stderr, "fetching pull request discussion"))
      end
      local decoded = decode_pages(stdout)
      if not decoded then
        completed = true
        return cb(nil, "could not read gh's pull request discussion JSON")
      end
      results[key] = decoded
      complete_one()
    end)
  end

  local thread_query = [[
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        nodes {
          id isResolved isOutdated viewerCanReply viewerCanResolve viewerCanUnresolve
          resolvedBy { login }
          comments(first: 1) { nodes { fullDatabaseId } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
]]
  local graph_argv = {
    M.opts().cmd, "api", "graphql", "--paginate", "--slurp",
    "-F", "owner={owner}", "-F", "repo={repo}",
    "-F", "number=" .. tostring(target.id), "-f", "query=" .. thread_query,
  }
  run(graph_argv, target.git_root, nil, function(code, stdout)
    record({ event = "fetch", endpoint = "thread_metadata", exit_code = code })
    if completed then return end
    -- Metadata enriches the REST discussion with resolve permissions and ids.
    -- A GraphQL failure must not discard readable REST comments, especially
    -- on an Enterprise host whose schema may lag github.com.
    results.thread_metadata = code == 0 and decode_thread_pages(stdout) or {}
    if not results.thread_metadata then results.thread_metadata = {} end
    complete_one()
  end)
end

--- Reply to the top-level comment anchoring an inline review thread.
function M.reply(target, thread, body, cb)
  local path = ("repos/{owner}/{repo}/pulls/%s/comments/%s/replies")
    :format(target.id, thread.remote_id)
  local ok, encoded = pcall(vim.json.encode, { body = body })
  if not ok then return cb(nil, "could not encode the reply") end
  run({ M.opts().cmd, "api", "--method", "POST", path, "--input", "-" },
    target.git_root, encoded, function(code, stdout, stderr)
      record({ event = "reply", exit_code = code, thread = thread.remote_id })
      if code ~= 0 then
        return cb(nil, failure(code, stderr, "replying to the review thread"))
      end
      local decoded_ok, reply = pcall(vim.json.decode, stdout)
      cb(decoded_ok and type(reply) == "table" and reply or {})
    end)
end

--- Resolve or unresolve an inline review thread through GraphQL.
function M.resolve_thread(target, thread, resolve, cb)
  local mutation = resolve and "resolveReviewThread" or "unresolveReviewThread"
  local query = ("mutation($threadId: ID!) { %s(input: {threadId: $threadId}) "
    .. "{ thread { id isResolved } } }"):format(mutation)
  local argv = {
    M.opts().cmd, "api", "graphql", "-f", "query=" .. query,
    "-F", "threadId=" .. tostring(thread.thread_id),
  }
  run(argv, target.git_root, nil, function(code, stdout, stderr)
    record({ event = resolve and "resolve" or "unresolve", exit_code = code })
    if code ~= 0 then
      local action = resolve and "resolving" or "reopening"
      return cb(nil, failure(code, stderr, action .. " the review thread"))
    end
    local decoded_ok, result = pcall(vim.json.decode, stdout)
    cb(decoded_ok and type(result) == "table" and result or {})
  end)
end

M._run = run
M._failure = failure
M._VERDICTS = VERDICTS
M._decode_pages = decode_pages
M._decode_thread_pages = decode_thread_pages

return M
