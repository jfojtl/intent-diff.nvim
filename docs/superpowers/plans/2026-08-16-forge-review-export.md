# Forge Review Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Submit intent-diff review comments to a GitHub pull request as one atomic review with inline comments and a verdict, through a service-neutral abstraction a GitLab implementation can slot into later.

**Architecture:** A `forges/` directory mirroring the existing `providers/` idiom: a named module per service, resolved through config, behind a four-function interface. Pure decision logic (preflight state machine, payload composition, line anchoring) lives in its own modules with no Neovim or network dependency; the `gh` process and the interactive flow are thin shells around them.

**Tech Stack:** Lua 5.1 / LuaJIT, Neovim API, `vim.fn.jobstart` for process spawning, `gh` CLI, plenary.nvim busted for tests.

**Spec:** `docs/superpowers/specs/2026-08-16-forge-review-export-design.md`

## Global Constraints

- **Nothing is sent to the service until the user picks a verdict.** No task may add a write call outside `forge.submit`, and `submit` is reached only after the verdict select.
- **No test contacts a network service.** Every process test uses `helpers.fake_bin("gh", …)`.
- **Run the whole suite, not a single file, with `PlenaryBustedFile`.** Use `tests/run_tests.sh`, or for one spec:
  `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/<spec>.lua { minimal_init = 'tests/init.lua' }"`.
  `PlenaryBustedFile` runs in the current process and gives false reds.
- **Hunk ranges are END-EXCLUSIVE** — `{ start_line = s, end_line = s + len }`, per `hunks.lua`'s `range()`. A line `l` is inside when `l >= start_line and l < end_line`.
- **Comment sides are `"old"` / `"new"` everywhere above `github.lua`.** Translation to `LEFT` / `RIGHT` happens only inside `github.lua`.
- **Every `vim.fn.systemlist` / `vim.fn.system` call is `pcall`-wrapped.** A missing binary raises E475 rather than returning an error value.
- **`comments/init.lua` is already 809 lines.** New logic goes in new modules; that file gains delegating one-liners only.
- Existing test files must keep passing untouched. `tests/comments_export_spec.lua` is the regression gate for Task 1.

---

## File Structure

| File | Responsibility |
|---|---|
| `lua/intentdiff/comments/export.lua` (modify) | Markdown generation; gains exported `bucket()` and `location()` |
| `lua/intentdiff/forges/init.lua` (create) | Forge registry, resolution, fact collection, pure `preflight()` |
| `lua/intentdiff/forges/github.lua` (create) | `matches` / `detect` / `capabilities` / `submit` over `gh` |
| `lua/intentdiff/comments/anchor.lua` (create) | Which comments GitHub will accept: local PR diff + pure predicate |
| `lua/intentdiff/comments/payload.lua` (create) | Pure: comments + model + mode → service-neutral payload |
| `lua/intentdiff/comments/submit.lua` (create) | The interactive flow |
| `lua/intentdiff/comments/marks.lua` (modify) | `· POSTED` header suffix on a posted box |
| `lua/intentdiff/comments/init.lua` (modify) | `M.submit(tabpage)` delegating one-liner |
| `lua/intentdiff/config.lua` (modify) | `forge`, `forge_opts`, `keymaps.comments.submit_review` |
| `lua/intentdiff/view.lua` (modify) | Bind `submit_review`, add its desc |
| `lua/intentdiff/keymap_help.lua` (modify) | Cheatsheet row |
| `plugin/intentdiff.lua` (modify) | `:IntentDiffCommentsSubmit` |
| `README.md` (modify) | `### Submitting to a pull request` |

Tests created: `tests/forges_preflight_spec.lua`, `tests/comments_payload_spec.lua`, `tests/forge_github_detect_spec.lua`, `tests/forge_github_submit_spec.lua`, `tests/forges_resolve_spec.lua`, `tests/comments_anchor_spec.lua`, `tests/comments_posted_spec.lua`, `tests/comments_submit_spec.lua`.

---

### Task 1: Shared bucketing in export.lua

Extract the grouping logic `payload.lua` needs, with byte-identical `generate()` output.

**Files:**
- Modify: `lua/intentdiff/comments/export.lua:36-63` (`group_index`), `:65-76` (`location`), `:104-218` (`generate`)
- Test: `tests/comments_export_spec.lua` (existing, must pass untouched), new cases appended

**Interfaces:**
- Consumes: nothing
- Produces:
  - `export.bucket(comments, model) -> { buckets, unmatched, groups, flat }` where `buckets` is a map from group index to `{ intents = Comment[], items = Comment[] }`, keyed `0` when `flat` is true; `unmatched` is a `Comment[]`; `groups` is `model.groups` or `{}`; `flat` is `#groups == 0`
  - `export.location(c) -> string` — `src/a.ts:12`, `src/a.ts:12-18`, `src/a.ts:~12`, or a bare path

- [ ] **Step 1: Write the failing test**

Append to `tests/comments_export_spec.lua`:

```lua
  it("buckets comments by the intent owning their line", function()
    local b = export.bucket({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "issue", text = "a" },
      { file = "src/http/client.ts", line = 44, side = "new", type = "note", text = "b" },
      { file = "nowhere.ts", line = 9, side = "new", type = "note", text = "c" },
      { intent_title = "Add retry logic to HTTP client", type = "note", text = "d" },
    }, model())
    assert.is_false(b.flat)
    assert.equals(1, #b.buckets[1].items)
    assert.equals("a", b.buckets[1].items[1].text)
    assert.equals(1, #b.buckets[2].items)
    assert.equals(1, #b.buckets[2].intents)
    assert.equals("d", b.buckets[2].intents[1].text)
    assert.equals(1, #b.unmatched)
    assert.equals("c", b.unmatched[1].text)
  end)

  it("buckets flat under key 0 when there are no groups", function()
    local b = export.bucket({
      { file = "a.ts", line = 1, side = "new", type = "note", text = "a" },
      { intent_title = "Gone", type = "note", text = "d" },
    }, { groups = {} })
    assert.is_true(b.flat)
    assert.equals(1, #b.buckets[0].items)
    assert.equals(1, #b.buckets[0].intents)
    assert.equals(0, #b.unmatched)
  end)

  it("renders a location for every comment shape", function()
    assert.equals("a.ts", export.location({ file = "a.ts", line = 0 }))
    assert.equals("a.ts:12", export.location({ file = "a.ts", line = 12, side = "new" }))
    assert.equals("a.ts:12-18",
      export.location({ file = "a.ts", line = 12, line_end = 18, side = "new" }))
    assert.equals("a.ts:~41", export.location({ file = "a.ts", line = 41, side = "old" }))
    assert.equals("a.ts:~12-~18",
      export.location({ file = "a.ts", line = 12, line_end = 18, side = "old" }))
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_export_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: FAIL — `attempt to call field 'bucket' (a nil value)`

- [ ] **Step 3: Write minimal implementation**

In `lua/intentdiff/comments/export.lua`, rename the local `location` to a module function and add `bucket`, then rewrite `generate` to call it. Replace lines 65-76 (`local function location(c)`) with:

```lua
--- `src/a.ts:12`, `src/a.ts:12-18`, `src/a.ts:~12`, `src/a.ts:~12-~18`, or a
--- bare path for a file-level comment.
---
--- Exported because the forge payload builder writes the same coordinates into
--- the PR review body's index, and two spellings of "where is this comment"
--- would drift.
function M.location(c)
  if (c.line or 0) == 0 then
    return c.file
  end
  local mark = (c.side == "old") and "~" or ""
  if c.line_end and c.line_end ~= c.line then
    return ("%s:%s%d-%s%d"):format(c.file, mark, c.line, mark, c.line_end)
  end
  return ("%s:%s%d"):format(c.file, mark, c.line)
end

local location = M.location
```

Then insert before `function M.generate`:

```lua
--- Split `comments` into per-intent buckets, exactly as the Markdown export
--- files them.
---
--- Shared with comments/payload.lua so the PR review body groups a comment
--- under the same intent the clipboard export does. Membership is COMPUTED, not
--- stored — see this file's header.
---
--- `flat` is the no-grouping fallback (classification still running, or it
--- failed): every comment lands in `buckets[0]` and `unmatched` stays empty,
--- because with no groups there is nothing for a comment to fail to match.
--- @return { buckets: table, unmatched: table[], groups: table[], flat: boolean }
function M.bucket(comments, model)
  local groups = (model and model.groups) or {}
  local flat = #groups == 0
  local buckets, unmatched = {}, {}
  local function place(key, c)
    buckets[key] = buckets[key] or { intents = {}, items = {} }
    if c.intent_title then
      table.insert(buckets[key].intents, c)
    else
      table.insert(buckets[key].items, c)
    end
  end
  for _, c in ipairs(comments or {}) do
    if flat then
      place(0, c)
    else
      local gi = group_index(c, model)
      if gi then
        place(gi, c)
      else
        unmatched[#unmatched + 1] = c
      end
    end
  end
  return { buckets = buckets, unmatched = unmatched, groups = groups, flat = flat }
end
```

Now replace `generate`'s inline bucketing (its `local groups = …` through the end of the `for _, c in ipairs(comments)` loop that fills `buckets`/`unmatched`) with:

```lua
  local b = M.bucket(comments, model)
  local groups, buckets, unmatched = b.groups, b.buckets, b.unmatched
```

Leave the rest of `generate` — the `has_old` scan, the header, `emit`, the group loop, the unmatched section, the trailing-blank trim — exactly as it is.

- [ ] **Step 4: Run tests to verify they pass**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_export_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: PASS, including every pre-existing case — that is the proof the refactor did not move `generate`'s output.

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/comments/export.lua tests/comments_export_spec.lua
git commit -m "refactor: extract export.bucket and export.location for reuse"
```

---

### Task 2: The preflight state machine

**Files:**
- Create: `lua/intentdiff/forges/init.lua`
- Test: `tests/forges_preflight_spec.lua`

**Interfaces:**
- Consumes: nothing
- Produces: `forges.preflight(state) -> { mode, reason, dirty }`
  - `state`: `{ branch, default_branch, target, head_sha, dirty_files, commented_files, forge_name, remote_url }`
  - `mode`: `"no_forge" | "default_branch" | "no_pr" | "inline" | "general"`
  - `reason`: human-readable string for every mode except `inline`
  - `dirty`: list of commented files with uncommitted changes, only in `general`
  - `target`: `{ service, id, url, title, head_sha, base_ref }`

- [ ] **Step 1: Write the failing test**

Create `tests/forges_preflight_spec.lua`:

```lua
local forges = require("intentdiff.forges")

local function target(over)
  return vim.tbl_extend("force", {
    service = "github", id = "123", url = "https://github.com/o/r/pull/123",
    title = "T", head_sha = "aaaa", base_ref = "main",
  }, over or {})
end

local function state(over)
  return vim.tbl_extend("force", {
    branch = "feat/x", default_branch = "main", target = target(),
    head_sha = "aaaa", dirty_files = {}, commented_files = { "a.ts" },
    forge_name = "github", remote_url = "git@github.com:o/r.git",
  }, over or {})
end

describe("forges.preflight", function()
  it("submits inline when HEAD matches the PR head and nothing is dirty", function()
    local r = forges.preflight(state())
    assert.equals("inline", r.mode)
  end)

  it("refuses when no forge serves the remote", function()
    local r = forges.preflight(state({ forge_name = nil }))
    assert.equals("no_forge", r.mode)
    assert.is_truthy(r.reason:match("no supported forge"))
  end)

  it("names the default branch before asking about a PR", function()
    -- target is nil here too: the default-branch message must win, not "no_pr".
    local r = forges.preflight(state({ branch = "main", target = nil }))
    assert.equals("default_branch", r.mode)
    assert.is_truthy(r.reason:match("main"))
  end)

  it("skips the default-branch check when the default branch is unknown", function()
    local r = forges.preflight(state({ default_branch = nil }))
    assert.equals("inline", r.mode)
  end)

  it("asks for a PR to be created when the branch has none", function()
    local r = forges.preflight(state({ target = nil }))
    assert.equals("no_pr", r.mode)
    assert.is_truthy(r.reason:match("gh pr create"))
  end)

  it("degrades to general when local HEAD is not the PR head", function()
    local r = forges.preflight(state({ head_sha = "bbbb" }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("bbbb"))
    assert.is_truthy(r.reason:match("aaaa"))
  end)

  it("degrades to general when a commented file is dirty", function()
    local r = forges.preflight(state({
      dirty_files = { "a.ts" }, commented_files = { "a.ts", "b.ts" },
    }))
    assert.equals("general", r.mode)
    assert.same({ "a.ts" }, r.dirty)
    assert.is_truthy(r.reason:match("1 of 2"))
  end)

  it("ignores a dirty file that carries no comment", function()
    local r = forges.preflight(state({
      dirty_files = { "unrelated.ts" }, commented_files = { "a.ts" },
    }))
    assert.equals("inline", r.mode)
  end)

  it("states both reasons when HEAD is stale and a file is dirty", function()
    local r = forges.preflight(state({ head_sha = "bbbb", dirty_files = { "a.ts" } }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("ahead"))
    assert.is_truthy(r.reason:match("uncommitted"))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/forges_preflight_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: FAIL — `module 'intentdiff.forges' not found`

- [ ] **Step 3: Write minimal implementation**

Create `lua/intentdiff/forges/init.lua`:

```lua
-- Exporting a review to the service hosting it — a GitHub PR today, a GitLab
-- MR the day someone writes forges/gitlab.lua.
--
-- Mirrors intentdiff.providers deliberately: a named module under a directory,
-- resolved through config, behind a small documented interface. A reader who
-- understands one understands the other.
--
-- The DECISION about what may be posted (preflight) is a pure function over
-- plain facts, separate from the git and `gh` calls that gather them, so every
-- branch is tested with no repository and no network.
local M = {}

--- Forges tried in order when `config.forge` is "auto".
local REGISTRY = { "github" }

--- Comments' files, as a set, for the dirty-file intersection.
local function set_of(list)
  local out = {}
  for _, v in ipairs(list or {}) do
    out[v] = true
  end
  return out
end

--- What may be posted, from plain facts. Pure — no git, no network, no Neovim
--- state.
---
--- The checks are ORDERED and the first match wins. `default_branch` is asked
--- before `no_pr` on purpose: sitting on `master` deserves "there is no PR to
--- comment on", not "create a PR for master first".
---
--- Only files that CARRY a comment count as dirty. An unrelated edit elsewhere
--- in the repo cannot move a line number in a commented file, and degrading the
--- whole export for it would be noise.
--- @return { mode: string, reason: string|nil, dirty: string[]|nil }
function M.preflight(state)
  state = state or {}
  if not state.forge_name then
    return {
      mode = "no_forge",
      reason = ("no supported forge for remote %s"):format(state.remote_url or "(none)"),
    }
  end
  if state.default_branch and state.branch == state.default_branch then
    return {
      mode = "default_branch",
      reason = ("you are on %s — no PR to comment on"):format(state.branch),
    }
  end
  if not state.target then
    return {
      mode = "no_pr",
      reason = ("no PR for branch %s — create one first (gh pr create)")
        :format(state.branch or "(unknown)"),
    }
  end

  local reasons = {}
  if state.head_sha ~= state.target.head_sha then
    reasons[#reasons + 1] = ("local HEAD is ahead of the PR head (%s vs %s)")
      :format(tostring(state.head_sha):sub(1, 8), tostring(state.target.head_sha):sub(1, 8))
  end
  local commented = state.commented_files or {}
  local dirty_set = set_of(state.dirty_files)
  local dirty = {}
  for _, path in ipairs(commented) do
    if dirty_set[path] then
      dirty[#dirty + 1] = path
    end
  end
  if #dirty > 0 then
    reasons[#reasons + 1] = ("%d of %d commented files have uncommitted changes")
      :format(#dirty, #commented)
  end
  if #reasons > 0 then
    return { mode = "general", reason = table.concat(reasons, "; "), dirty = dirty }
  end
  return { mode = "inline" }
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/forges_preflight_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: PASS (9 successes)

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/forges/init.lua tests/forges_preflight_spec.lua
git commit -m "feat: forge preflight state machine"
```

---

### Task 3: Payload composition

**Files:**
- Create: `lua/intentdiff/comments/payload.lua`
- Test: `tests/comments_payload_spec.lua`

**Interfaces:**
- Consumes: `export.bucket`, `export.location`, `export.generate` (Task 1)
- Produces: `payload.build(comments, model, mode, anchorable) -> { body, comments, demoted }`
  - `mode`: `"inline"` or `"general"`
  - `anchorable`: `fun(c: Comment): boolean`, or `nil` meaning everything anchors
  - returned `comments`: `{ path, line, line_end, side, body, file_level }[]`, empty in general mode
  - `demoted`: integer count of line comments that could not anchor

- [ ] **Step 1: Write the failing test**

Create `tests/comments_payload_spec.lua`:

```lua
local payload = require("intentdiff.comments.payload")

--- Two groups, matching tests/comments_export_spec.lua. Ranges END-EXCLUSIVE.
local function model()
  return {
    state = "ready",
    groups = {
      {
        title = "Rename UserService to AccountService",
        hunks = {
          { id = "src/api/routes.ts:1", file = "src/api/routes.ts",
            original = { start_line = 4, end_line = 6 },
            modified = { start_line = 4, end_line = 6 } },
          { id = "src/services/account.ts:1", file = "src/services/account.ts",
            original = { start_line = 40, end_line = 52 },
            modified = { start_line = 40, end_line = 50 } },
        },
        files = {
          { path = "src/api/routes.ts", status = "M" },
          { path = "src/services/account.ts", status = "M" },
        },
      },
      {
        title = "Add retry logic to HTTP client",
        hunks = {
          { id = "src/http/client.ts:1", file = "src/http/client.ts",
            original = { start_line = 40, end_line = 50 },
            modified = { start_line = 40, end_line = 56 } },
        },
        files = { { path = "src/http/client.ts", status = "M" } },
      },
    },
  }
end

local function comments()
  return {
    { file = "src/api/routes.ts", line = 5, side = "new", type = "issue",
      text = "This import still points at the old module." },
    { file = "src/services/account.ts", line = 41, side = "old", type = "suggestion",
      text = "The old implementation was cleaner." },
    { file = "src/http/client.ts", line = 0, type = "praise",
      text = "Good call keeping the timeout separate." },
    { file = "src/http/client.ts", line = 44, line_end = 51, side = "new", type = "note",
      text = "No jitter here — fine for now." },
    { intent_title = "Rename UserService to AccountService", type = "note",
      text = "This rename missed the DI container entirely." },
  }
end

describe("comments.payload", function()
  describe("inline mode", function()
    it("emits one inline comment per line comment, text only", function()
      local p = payload.build(comments(), model(), "inline")
      assert.equals(4, #p.comments)
      local first = p.comments[1]
      assert.equals("src/api/routes.ts", first.path)
      assert.equals(5, first.line)
      assert.equals("new", first.side)
      assert.equals("**[ISSUE]** This import still points at the old module.", first.body)
      -- The intent belongs in the body, never on the inline comment.
      assert.is_nil(first.body:match("Intent"))
    end)

    it("carries range, old side and file-level shape through", function()
      local p = payload.build(comments(), model(), "inline")
      local by_text = {}
      for _, c in ipairs(p.comments) do
        by_text[c.body] = c
      end
      local range = by_text["**[NOTE]** No jitter here — fine for now."]
      assert.equals(44, range.line)
      assert.equals(51, range.line_end)
      local old = by_text["**[SUGGESTION]** The old implementation was cleaner."]
      assert.equals("old", old.side)
      assert.equals(41, old.line)
      local file = by_text["**[PRAISE]** Good call keeping the timeout separate."]
      assert.is_true(file.file_level)
      assert.equals(0, file.line)
    end)

    it("indexes each inline comment under its intent in the body", function()
      local p = payload.build(comments(), model(), "inline")
      assert.is_truthy(p.body:match("## Rename UserService to AccountService"))
      assert.is_truthy(p.body:match("This rename missed the DI container entirely%."))
      assert.is_truthy(p.body:match("`src/api/routes%.ts:5` — ISSUE"))
      assert.is_truthy(p.body:match("`src/services/account%.ts:~41` — SUGGESTION"))
      assert.is_truthy(p.body:match("`src/http/client%.ts:44%-51` — NOTE"))
    end)

    it("does not repeat an inline comment's text in the body", function()
      local p = payload.build(comments(), model(), "inline")
      assert.is_nil(p.body:match("This import still points at the old module"))
    end)

    it("writes an unanchorable comment into the body in full", function()
      local anchorable = function(c)
        return not (c.file == "src/api/routes.ts" and c.line == 5)
      end
      local p = payload.build(comments(), model(), "inline", anchorable)
      assert.equals(3, #p.comments)
      assert.equals(1, p.demoted)
      assert.is_truthy(p.body:match("## Not attached to a line"))
      assert.is_truthy(p.body:match("This import still points at the old module%."))
      -- Demoted once, not also indexed under its intent.
      assert.is_nil(p.body:match("`src/api/routes%.ts:5` — ISSUE"))
    end)

    it("puts a comment matching no intent under the unattached heading", function()
      local p = payload.build({
        { file = "nowhere.ts", line = 9, side = "new", type = "note", text = "orphan" },
      }, model(), "inline")
      assert.is_truthy(p.body:match("## Not attached to a line"))
      assert.is_truthy(p.body:match("orphan"))
      -- Still posted inline: not matching an intent says nothing about whether
      -- GitHub can anchor it.
      assert.equals(1, #p.comments)
    end)

    it("degrades to a flat body when classification produced no groups", function()
      local p = payload.build(comments(), { groups = {} }, "inline")
      assert.is_nil(p.body:match("## Rename"))
      assert.is_truthy(p.body:match("This rename missed the DI container entirely%."))
      assert.equals(4, #p.comments)
    end)
  end)

  describe("general mode", function()
    it("posts the Markdown export as the body with no inline comments", function()
      local export = require("intentdiff.comments.export")
      local p = payload.build(comments(), model(), "general")
      assert.equals(0, #p.comments)
      assert.equals(export.generate(comments(), model()), p.body)
    end)

    it("ignores the anchorable predicate entirely", function()
      local p = payload.build(comments(), model(), "general", function() return false end)
      assert.equals(0, p.demoted)
    end)
  end)

  it("builds a verdict-only body when there are no comments", function()
    local p = payload.build({}, model(), "inline")
    assert.equals(0, #p.comments)
    assert.is_truthy(p.body:match("no new comments"))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_payload_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: FAIL — `module 'intentdiff.comments.payload' not found`

- [ ] **Step 3: Write minimal implementation**

Create `lua/intentdiff/comments/payload.lua`:

```lua
-- The service-neutral review payload: what goes inline, what goes in the body.
--
-- Pure — comments, a model and a mode in, a payload out — so every shape is
-- tested without a repository, a `gh`, or a review tab. Translation to a
-- particular service's JSON happens in forges/<service>.lua, never here.
--
-- The split is the whole point. An inline comment carries ONLY its type and
-- text, because GitHub shows it next to the line and the intent would be noise
-- there. The body carries the structure — which intent each comment sits under
-- — plus, in full, the comments that have nowhere else to live.
local M = {}

local export = require("intentdiff.comments.export")

local HEADER = "I reviewed your code and have the following comments. Please address them."
local TYPE_LEGEND = "Comment types: ISSUE (problems to fix), SUGGESTION (improvements),\n"
  .. "NOTE (observations), PRAISE (positive feedback)"
local UNATTACHED = "Not attached to a line"
local VERDICT_ONLY = "Submitted from intent-diff with no new comments."

local function typed(c)
  return ("**[%s]** %s"):format(tostring(c.type):upper(), c.text or "")
end

--- One inline comment, in the plugin's own vocabulary.
local function inline_of(c)
  return {
    path = c.file,
    line = c.line or 0,
    line_end = c.line_end,
    side = c.side or "new",
    body = typed(c),
    file_level = (c.line or 0) == 0,
  }
end

--- `- \`src/a.ts:5\` — ISSUE`
local function index_of(c)
  return ("- `%s` — %s"):format(export.location(c), tostring(c.type):upper())
end

--- Full text, for a comment the body has to carry itself.
local function full_of(c, n, out)
  out[#out + 1] = ("%d. **[%s]** `%s`"):format(n, tostring(c.type):upper(), export.location(c))
  for _, line in ipairs(vim.split(c.text or "", "\n")) do
    out[#out + 1] = "   " .. line
  end
  out[#out + 1] = ""
end

--- @param comments intentdiff.Comment[]
--- @param model table|nil
--- @param mode "inline"|"general"
--- @param anchorable fun(c: intentdiff.Comment): boolean|nil  nil = everything anchors
--- @return { body: string, comments: table[], demoted: integer }
function M.build(comments, model, mode, anchorable)
  comments = comments or {}

  -- General mode is the Markdown export, unchanged. The reason it is general
  -- rather than inline is shown in Neovim, not written into the PR: the reader
  -- of the PR cannot act on the state of someone else's working tree.
  if mode ~= "inline" then
    return { body = export.generate(comments, model), comments = {}, demoted = 0 }
  end

  if #comments == 0 then
    return { body = VERDICT_ONLY, comments = {}, demoted = 0 }
  end

  local can = anchorable or function() return true end
  local inline, demoted_list = {}, {}
  local is_demoted = {}
  for _, c in ipairs(comments) do
    if not c.intent_title then
      if can(c) then
        inline[#inline + 1] = inline_of(c)
      else
        demoted_list[#demoted_list + 1] = c
        is_demoted[c] = true
      end
    end
  end

  local b = export.bucket(comments, model)
  local out = { HEADER, "", TYPE_LEGEND, "" }

  --- Intent prose, then one index line per inline comment under it.
  local function emit(bucket)
    for _, c in ipairs(bucket.intents) do
      for _, line in ipairs(vim.split(c.text or "", "\n")) do
        out[#out + 1] = line
      end
      out[#out + 1] = ""
    end
    local any = false
    for _, c in ipairs(bucket.items) do
      if not is_demoted[c] then
        out[#out + 1] = index_of(c)
        any = true
      end
    end
    if any then
      out[#out + 1] = ""
    end
  end

  if b.flat and b.buckets[0] then
    -- No grouping available: no headings to hang an index under, so the body
    -- is just the intent prose plus the index.
    emit(b.buckets[0])
  end
  for gi, g in ipairs(b.groups) do
    if b.buckets[gi] then
      out[#out + 1] = "## " .. g.title
      out[#out + 1] = ""
      emit(b.buckets[gi])
    end
  end

  -- Everything the body must carry itself: comments GitHub cannot anchor, and
  -- comments matching no intent. An intent comment among the unmatched keeps
  -- its title, since no heading above it names one.
  local carried = {}
  for _, c in ipairs(b.unmatched) do
    if c.intent_title or not is_demoted[c] then
      carried[#carried + 1] = c
    end
  end
  for _, c in ipairs(demoted_list) do
    carried[#carried + 1] = c
  end
  local seen = {}
  local unique = {}
  for _, c in ipairs(carried) do
    if not seen[c] then
      seen[c] = true
      unique[#unique + 1] = c
    end
  end
  if #unique > 0 then
    out[#out + 1] = "## " .. UNATTACHED
    out[#out + 1] = ""
    local n = 0
    for _, c in ipairs(unique) do
      if c.intent_title then
        out[#out + 1] = ("_Intent: %s_"):format(c.intent_title)
        for _, line in ipairs(vim.split(c.text or "", "\n")) do
          out[#out + 1] = line
        end
        out[#out + 1] = ""
      else
        n = n + 1
        full_of(c, n, out)
      end
    end
  end

  while out[#out] == "" do
    table.remove(out)
  end
  return { body = table.concat(out, "\n"), comments = inline, demoted = #demoted_list }
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_payload_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: PASS (11 successes)

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/comments/payload.lua tests/comments_payload_spec.lua
git commit -m "feat: service-neutral review payload builder"
```

---

### Task 4: GitHub detection

**Files:**
- Create: `lua/intentdiff/forges/github.lua`
- Test: `tests/forge_github_detect_spec.lua`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `github.matches(remote_url) -> boolean`
  - `github.capabilities() -> { inline = true, file_comments = true, verdicts = { "approve", "request_changes", "comment" } }`
  - `github.detect(git_root, branch, cb)` → `cb(target|nil, err|nil)`; `cb(nil, nil)` means "no PR", which is not an error
  - `github.opts() -> { cmd, timeout_ms }` read from `config.options.forge_opts.github`

- [ ] **Step 1: Write the failing test**

Create `tests/forge_github_detect_spec.lua`:

```lua
local helpers = require("tests.helpers")
local github = require("intentdiff.forges.github")

local restore

describe("forges.github.detect", function()
  after_each(function()
    if restore then
      restore()
      restore = nil
    end
  end)

  it("matches github remotes in both URL forms", function()
    assert.is_true(github.matches("git@github.com:o/r.git"))
    assert.is_true(github.matches("https://github.com/o/r.git"))
    assert.is_false(github.matches("git@gitlab.com:o/r.git"))
    assert.is_false(github.matches(nil))
  end)

  it("returns a target for an open PR", function()
    restore = helpers.fake_bin("gh", [[
echo '{"number":123,"url":"https://github.com/o/r/pull/123","title":"Add retries","headRefOid":"aaaabbbb","baseRefName":"main","state":"OPEN"}'
]])
    local got, err, done
    github.detect(vim.fn.getcwd(), "feat/x", function(t, e)
      got, err, done = t, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_nil(err)
    assert.equals("github", got.service)
    assert.equals("123", got.id)
    assert.equals("aaaabbbb", got.head_sha)
    assert.equals("main", got.base_ref)
    assert.equals("https://github.com/o/r/pull/123", got.url)
  end)

  it("answers no-PR without an error when gh finds none", function()
    restore = helpers.fake_bin("gh", [[
echo "no pull requests found for branch \"feat/x\"" >&2
exit 1
]])
    local got, err, done
    github.detect(vim.fn.getcwd(), "feat/x", function(t, e)
      got, err, done = t, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_nil(got)
    assert.is_nil(err)
  end)

  it("treats a merged PR as nothing to review", function()
    restore = helpers.fake_bin("gh", [[
echo '{"number":9,"url":"u","title":"t","headRefOid":"a","baseRefName":"main","state":"MERGED"}'
]])
    local got, err, done
    github.detect(vim.fn.getcwd(), "feat/x", function(t, e)
      got, err, done = t, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_nil(got)
    assert.is_truthy(err:match("MERGED"))
  end)

  it("surfaces an authentication failure as a real error", function()
    restore = helpers.fake_bin("gh", [[
echo "gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN" >&2
exit 4
]])
    local got, err, done
    github.detect(vim.fn.getcwd(), "feat/x", function(t, e)
      got, err, done = t, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_nil(got)
    assert.is_truthy(err:match("GH_TOKEN"))
  end)

  it("reports a missing gh instead of raising", function()
    local old = vim.env.PATH
    vim.env.PATH = "/nonexistent"
    restore = function() vim.env.PATH = old end
    local got, err, done
    github.detect(vim.fn.getcwd(), "feat/x", function(t, e)
      got, err, done = t, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_nil(got)
    assert.is_truthy(err)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/forge_github_detect_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: FAIL — `module 'intentdiff.forges.github' not found`

- [ ] **Step 3: Write minimal implementation**

Create `lua/intentdiff/forges/github.lua`:

```lua
-- GitHub, over the `gh` CLI.
--
-- `gh` rather than raw HTTP because it already holds the user's credentials,
-- knows the host aliases and enterprise instances they have configured, and
-- resolves {owner}/{repo} from the checkout — none of which this plugin should
-- reimplement.
--
-- Only M.submit writes. detect and the repo lookups are read-only, so the
-- preflight can run freely before the user has chosen anything.
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

M._run = run
M._failure = failure
M._VERDICTS = VERDICTS

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/forge_github_detect_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: PASS (6 successes)

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/forges/github.lua tests/forge_github_detect_spec.lua
git commit -m "feat: detect the GitHub PR for the current branch"
```

---

### Task 5: GitHub submission

**Files:**
- Modify: `lua/intentdiff/forges/github.lua` (add `M.submit`)
- Test: `tests/forge_github_submit_spec.lua`

**Interfaces:**
- Consumes: `github._run`, `github._failure`, `github._VERDICTS` (Task 4); the payload shape from Task 3
- Produces: `github.submit(target, payload, cb)` → `cb({ url }|nil, err|nil, kind|nil)` where `kind` is `"self_approve"` when GitHub refused a self-approval, and `nil` otherwise

- [ ] **Step 1: Write the failing test**

Create `tests/forge_github_submit_spec.lua`:

```lua
local helpers = require("tests.helpers")
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
  return got, err, kind
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
    submit({
      verdict = "comment",
      body = "b",
      comments = {
        { path = "a.ts", line = 44, line_end = 51, side = "new", body = "r", file_level = false },
        { path = "b.ts", line = 41, side = "old", body = "o", file_level = false },
        { path = "c.ts", line = 0, side = "new", body = "f", file_level = true },
      },
    })
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
  end)

  it("omits the comments key entirely when there are none", function()
    restore = fake_gh([[echo '{"html_url":"u"}']])
    submit({ verdict = "approve", body = "b", comments = {} })
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/forge_github_submit_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: FAIL — `attempt to call field 'submit' (a nil value)`

- [ ] **Step 3: Write minimal implementation**

Append to `lua/intentdiff/forges/github.lua`, before `M._run = run`:

```lua
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
```

Note `target.git_root`: `submit.lua` sets it on the target before calling, so `gh` runs in the reviewed repository. Document that in the `Target` usage by adding to `M.detect`'s returned table nothing extra — the flow assigns it.

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/forge_github_submit_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: PASS (5 successes)

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/forges/github.lua tests/forge_github_submit_spec.lua
git commit -m "feat: submit one atomic GitHub review with inline comments"
```

---

### Task 6: Registry, resolution and fact collection

**Files:**
- Modify: `lua/intentdiff/forges/init.lua`
- Test: `tests/forges_resolve_spec.lua`

**Interfaces:**
- Consumes: `github.matches` (Task 4), `forges.preflight` (Task 2)
- Produces:
  - `forges.git_lines(git_root, ...) -> string[]|nil` — pcall-wrapped `git -C`, nil on any failure
  - `forges.remote_url(git_root) -> string|nil`
  - `forges.resolve(remote_url) -> mod|nil, name|nil, err|nil`
  - `forges.collect(git_root, commented_files, cb)` → `cb(state|nil, err|nil)` with the shape `preflight` consumes, plus `forge` (the module)

- [ ] **Step 1: Write the failing test**

Create `tests/forges_resolve_spec.lua`:

```lua
local helpers = require("tests.helpers")
local forges = require("intentdiff.forges")
local config = require("intentdiff.config")

local restore

describe("forges.resolve", function()
  before_each(function() config.setup({}) end)
  after_each(function()
    if restore then
      restore()
      restore = nil
    end
    config.setup({})
  end)

  it("picks github for a github remote under auto", function()
    local mod, name = forges.resolve("git@github.com:o/r.git")
    assert.equals("github", name)
    assert.is_function(mod.submit)
  end)

  it("finds no forge for an unknown host", function()
    local mod, name = forges.resolve("git@bitbucket.org:o/r.git")
    assert.is_nil(mod)
    assert.is_nil(name)
  end)

  it("honours an explicit forge name regardless of the remote", function()
    config.setup({ forge = "github" })
    local _, name = forges.resolve("git@example.invalid:o/r.git")
    assert.equals("github", name)
  end)

  it("uses a table forge as given", function()
    local custom = { submit = function() end, detect = function() end,
      matches = function() return true end, capabilities = function() return {} end }
    config.setup({ forge = custom })
    local mod, name = forges.resolve("anything")
    assert.equals(custom, mod)
    assert.equals("custom", name)
  end)

  it("reports a disabled forge distinctly from an unmatched one", function()
    config.setup({ forge = false })
    local mod, name, err = forges.resolve("git@github.com:o/r.git")
    assert.is_nil(mod)
    assert.is_nil(name)
    assert.is_truthy(err:match("disabled"))
  end)

  it("errors on a forge name with no module", function()
    config.setup({ forge = "nosuchforge" })
    local mod, _, err = forges.resolve("x")
    assert.is_nil(mod)
    assert.is_truthy(err:match("nosuchforge"))
  end)
end)

describe("forges.collect", function()
  after_each(function()
    if restore then
      restore()
      restore = nil
    end
  end)

  it("reads branch, head and dirty files from a real repo", function()
    local repo = helpers.make_repo({ ["a.ts"] = "one\n", ["b.ts"] = "two\n" })
    helpers.git(repo, "checkout", "-q", "-b", "feat/x")
    helpers.write_file(repo, "a.ts", "changed\n")
    restore = helpers.fake_bin("gh", [[
echo "no pull requests found" >&2
exit 1
]])
    local state, done
    forges.collect(repo, { "a.ts" }, function(s)
      state, done = s, true
    end)
    helpers.wait_for(function() return done end)
    assert.equals("feat/x", state.branch)
    assert.is_truthy(state.head_sha:match("^%x+$"))
    assert.same({ "a.ts" }, state.dirty_files)
    assert.is_nil(state.target)
  end)

  it("feeds preflight a state that produces no_pr", function()
    local repo = helpers.make_repo({ ["a.ts"] = "one\n" })
    helpers.git(repo, "checkout", "-q", "-b", "feat/x")
    helpers.git(repo, "remote", "add", "origin", "git@github.com:o/r.git")
    restore = helpers.fake_bin("gh", [[
echo "no pull requests found" >&2
exit 1
]])
    local state, done
    forges.collect(repo, { "a.ts" }, function(s)
      state, done = s, true
    end)
    helpers.wait_for(function() return done end)
    assert.equals("github", state.forge_name)
    assert.equals("no_pr", forges.preflight(state).mode)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/forges_resolve_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: FAIL — `attempt to call field 'resolve' (a nil value)`

- [ ] **Step 3: Write minimal implementation**

Add to `lua/intentdiff/forges/init.lua`, above `M.preflight`:

```lua
--- `git -C git_root <...>`'s output lines, or nil on any failure — including
--- git not being executable at all.
---
--- vim.fn.systemlist RAISES (E475) rather than returning an error value when
--- argv[0] cannot be found, so this must be pcall'd, not merely checked against
--- vim.v.shell_error.
--- @return string[]|nil
function M.git_lines(git_root, ...)
  local ok, out = pcall(vim.fn.systemlist, { "git", "-C", git_root, ... })
  if not ok or vim.v.shell_error ~= 0 then
    return nil
  end
  return out
end

local function git_first(git_root, ...)
  local out = M.git_lines(git_root, ...)
  local first = out and out[1]
  if not first or first == "" then
    return nil
  end
  return first
end

--- @return string|nil
function M.remote_url(git_root)
  return git_first(git_root, "remote", "get-url", "origin")
end

--- The default branch, without the `origin/` prefix, or nil when it cannot be
--- determined. nil is not an error: preflight simply skips its default-branch
--- check rather than blocking a submit over a missing symbolic ref.
--- @return string|nil
function M.default_branch(git_root)
  local ref = git_first(git_root, "rev-parse", "--abbrev-ref", "origin/HEAD")
  if not ref then
    return nil
  end
  return (ref:gsub("^origin/", ""))
end

--- Paths with uncommitted changes, from porcelain status. Renames report
--- `R  old -> new`; the NEW path is what a comment addresses.
--- @return string[]
function M.dirty_files(git_root)
  local out = {}
  for _, line in ipairs(M.git_lines(git_root, "status", "--porcelain") or {}) do
    local path = line:sub(4)
    local _, new = path:match("^(.+) %-> (.+)$")
    out[#out + 1] = new or path
  end
  return out
end

--- The forge serving this repository.
---
--- `false` disables the feature outright, which is NOT the same as no forge
--- matching the remote: one means the user turned it off, the other that they
--- are pushing somewhere this plugin cannot post to. They get different
--- messages, so they get different return shapes.
--- @return table|nil mod, string|nil name, string|nil err
function M.resolve(remote_url)
  local configured = require("intentdiff.config").options.forge
  if configured == false then
    return nil, nil, "review export is disabled (forge = false)"
  end
  if type(configured) == "table" then
    return configured, "custom"
  end
  if type(configured) == "string" and configured ~= "auto" then
    local ok, mod = pcall(require, "intentdiff.forges." .. configured)
    if not ok or type(mod) ~= "table" then
      return nil, nil, ("no forge named '%s'"):format(configured)
    end
    return mod, configured
  end
  for _, name in ipairs(REGISTRY) do
    local ok, mod = pcall(require, "intentdiff.forges." .. name)
    if ok and type(mod) == "table" and mod.matches(remote_url) then
      return mod, name
    end
  end
  return nil, nil
end

--- Everything preflight needs, gathered from git and the forge.
---
--- Detection is the only asynchronous part, so the git facts are read first and
--- the callback fires once the forge answers. A detection ERROR still calls back
--- with a state (target = nil) plus the error, so the caller reports the real
--- reason instead of the generic "no PR".
--- @param cb fun(state: table, err: string|nil)
function M.collect(git_root, commented_files, cb)
  local remote_url = M.remote_url(git_root)
  local forge, forge_name, err = M.resolve(remote_url)
  local state = {
    branch = git_first(git_root, "rev-parse", "--abbrev-ref", "HEAD"),
    head_sha = git_first(git_root, "rev-parse", "HEAD"),
    default_branch = M.default_branch(git_root),
    dirty_files = M.dirty_files(git_root),
    commented_files = commented_files or {},
    remote_url = remote_url,
    forge_name = forge_name,
    forge = forge,
    git_root = git_root,
  }
  if not forge then
    return cb(state, err)
  end
  forge.detect(git_root, state.branch, function(target, detect_err)
    state.target = target
    cb(state, detect_err)
  end)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/forges_resolve_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: PASS (8 successes)

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/forges/init.lua tests/forges_resolve_spec.lua
git commit -m "feat: forge registry, resolution and fact collection"
```

---

### Task 7: Local anchoring

**Files:**
- Create: `lua/intentdiff/comments/anchor.lua`
- Test: `tests/comments_anchor_spec.lua`

**Interfaces:**
- Consumes: `hunks.parse`, `forges.git_lines` (Task 6)
- Produces:
  - `anchor.covers(hunk_list, comment) -> boolean` — pure
  - `anchor.predicate(hunk_list) -> fun(c): boolean` — the `anchorable` argument `payload.build` takes
  - `anchor.pr_hunks(git_root, base_ref) -> hunks|nil, err` — synchronous; the diff is local and small

- [ ] **Step 1: Write the failing test**

Create `tests/comments_anchor_spec.lua`:

```lua
local helpers = require("tests.helpers")
local anchor = require("intentdiff.comments.anchor")

describe("comments.anchor", function()
  --- END-EXCLUSIVE, matching hunks.lua's range().
  local hunk_list = {
    { file = "a.ts", original = { start_line = 10, end_line = 20 },
      modified = { start_line = 10, end_line = 25 } },
    { file = "b.ts", original = { start_line = 1, end_line = 4 },
      modified = { start_line = 1, end_line = 4 } },
  }

  it("accepts a new-side line inside the modified range", function()
    assert.is_true(anchor.covers(hunk_list, { file = "a.ts", line = 24, side = "new" }))
  end)

  it("rejects a new-side line past the modified range", function()
    assert.is_false(anchor.covers(hunk_list, { file = "a.ts", line = 25, side = "new" }))
  end)

  it("resolves an old-side line against the original range", function()
    -- 22 is inside modified (10-25) but outside original (10-20): a correct
    -- implementation must not answer from the wrong side's range.
    assert.is_true(anchor.covers(hunk_list, { file = "a.ts", line = 19, side = "old" }))
    assert.is_false(anchor.covers(hunk_list, { file = "a.ts", line = 22, side = "old" }))
  end)

  it("requires every line of a range to be covered", function()
    assert.is_true(anchor.covers(hunk_list,
      { file = "a.ts", line = 12, line_end = 18, side = "new" }))
    assert.is_false(anchor.covers(hunk_list,
      { file = "a.ts", line = 12, line_end = 30, side = "new" }))
  end)

  it("accepts a file-level comment on any file in the diff", function()
    assert.is_true(anchor.covers(hunk_list, { file = "b.ts", line = 0 }))
    assert.is_false(anchor.covers(hunk_list, { file = "gone.ts", line = 0 }))
  end)

  it("rejects a file the diff does not touch", function()
    assert.is_false(anchor.covers(hunk_list, { file = "c.ts", line = 3, side = "new" }))
  end)

  it("never anchors an intent comment", function()
    assert.is_false(anchor.covers(hunk_list, { intent_title = "Some intent" }))
  end)

  it("parses the PR diff from a real repository", function()
    local repo = helpers.make_repo({ ["a.ts"] = "1\n2\n3\n4\n5\n" })
    helpers.git(repo, "branch", "-M", "main")
    helpers.git(repo, "checkout", "-q", "-b", "feat/x")
    helpers.write_file(repo, "a.ts", "1\n2\nCHANGED\n4\n5\n")
    helpers.git(repo, "commit", "-qam", "change")
    local hunks, err = anchor.pr_hunks(repo, "main")
    assert.is_nil(err)
    assert.is_true(#hunks > 0)
    assert.equals("a.ts", hunks[1].file)
    local can = anchor.predicate(hunks)
    assert.is_true(can({ file = "a.ts", line = 3, side = "new" }))
    assert.is_false(can({ file = "a.ts", line = 400, side = "new" }))
  end)

  it("reports a base ref it cannot resolve instead of guessing", function()
    local repo = helpers.make_repo({ ["a.ts"] = "1\n" })
    local hunks, err = anchor.pr_hunks(repo, "nosuchbranch")
    assert.is_nil(hunks)
    assert.is_truthy(err:match("nosuchbranch"))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_anchor_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: FAIL — `module 'intentdiff.comments.anchor' not found`

- [ ] **Step 3: Write minimal implementation**

Create `lua/intentdiff/comments/anchor.lua`:

```lua
-- Which comments the service will accept on a line, decided LOCALLY.
--
-- The GitHub reviews API is atomic: one comment on a line outside the diff
-- rejects the entire review, comments and verdict together. Discovering that
-- from a 422 costs the whole submit, so the same question is answered here
-- first, against the very diff the service is showing.
--
-- That is only sound in `inline` mode, where the preflight has already
-- established that the checkout IS the PR head with no uncommitted changes in
-- the commented files. Under those conditions `base...HEAD` locally is the
-- service's diff, byte for byte.
local M = {}

--- Context matching what GitHub renders around a hunk, so a comment on a
--- context line is accepted here exactly when the service would accept it.
local CONTEXT = 3

--- Is `line` inside `range`? Ranges are END-EXCLUSIVE — see hunks.lua range().
local function inside(range, line)
  if not range then
    return false
  end
  return line >= range.start_line and line < range.end_line
end

--- Can `comment` be posted on a line of the PR diff?
---
--- A range must be covered ENTIRELY: GitHub anchors a multi-line comment to
--- both endpoints, and half a range inside the diff is a 422 like any other.
--- A file-level comment needs only its file to appear in the diff, since
--- subject_type = "file" addresses no line.
--- @return boolean
function M.covers(hunk_list, comment)
  if comment.intent_title then
    return false
  end
  if (comment.line or 0) == 0 then
    for _, h in ipairs(hunk_list or {}) do
      if h.file == comment.file then
        return true
      end
    end
    return false
  end
  local side = comment.side or "new"
  local first = comment.line
  local last = comment.line_end or comment.line
  for line = first, last do
    local found = false
    for _, h in ipairs(hunk_list or {}) do
      if h.file == comment.file then
        local range = (side == "old") and h.original or h.modified
        if inside(range, line) then
          found = true
          break
        end
      end
    end
    if not found then
      return false
    end
  end
  return true
end

--- The `anchorable` predicate comments/payload.lua takes.
--- @return fun(c: intentdiff.Comment): boolean
function M.predicate(hunk_list)
  return function(c)
    return M.covers(hunk_list, c)
  end
end

--- The PR's diff, parsed into hunks.
---
--- Synchronous: this is `git diff` against local objects, not a network call,
--- and the flow is already mid-prompt when it runs. `merge-base` rather than a
--- plain two-dot diff, because the service diffs the PR against where the
--- branch DIVERGED, not against the tip of the base branch.
--- @return table[]|nil hunks, string|nil err
function M.pr_hunks(git_root, base_ref)
  local forges = require("intentdiff.forges")
  local base = nil
  -- The remote-tracking ref first: it is what the service actually has. A local
  -- branch of the same name may be behind or ahead of it.
  for _, ref in ipairs({ "origin/" .. base_ref, base_ref }) do
    local out = forges.git_lines(git_root, "merge-base", ref, "HEAD")
    if out and out[1] and out[1] ~= "" then
      base = out[1]
      break
    end
  end
  if not base then
    return nil, ("cannot resolve the merge base with %s"):format(base_ref)
  end
  local out = forges.git_lines(git_root, "diff", "-U" .. CONTEXT, base .. "...HEAD")
  if not out then
    return nil, ("cannot diff %s...HEAD"):format(base:sub(1, 8))
  end
  local hunk_list = require("intentdiff.hunks").parse(table.concat(out, "\n"))
  return hunk_list
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_anchor_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: PASS (9 successes)

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/comments/anchor.lua tests/comments_anchor_spec.lua
git commit -m "feat: decide locally which comments GitHub can anchor"
```

---

### Task 8: Posted state

**Files:**
- Modify: `lua/intentdiff/comments/store.lua` (add `self.mark_posted`)
- Modify: `lua/intentdiff/comments/marks.lua:65-86` (`build_box` header)
- Test: `tests/comments_posted_spec.lua`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `store.mark_posted(comment_list, stamp)` — sets `c.posted = stamp` on each and fires `on_change` once
  - `store.unposted() -> Comment[]`
  - `marks.build_box(text, type_name, hl_group, opts)` — `opts.posted` truthy appends ` · POSTED` inside the header brackets; `opts` is optional, so every existing call is unchanged

- [ ] **Step 1: Write the failing test**

Create `tests/comments_posted_spec.lua`:

```lua
local store = require("intentdiff.comments.store")
local storage = require("intentdiff.comments.storage")
local marks = require("intentdiff.comments.marks")
local config = require("intentdiff.config")

describe("posted state", function()
  it("stamps only the comments handed to it and fires one change", function()
    local st = store.new()
    local changes = 0
    st.on_change(function() changes = changes + 1 end)
    local a = st.add({ file = "a.ts", line = 1, side = "new", type = "note", text = "a" })
    local b = st.add({ file = "b.ts", line = 1, side = "new", type = "note", text = "b" })
    changes = 0
    st.mark_posted({ a }, { service = "github", target = "123", url = "u", at = 1 })
    assert.equals(1, changes)
    assert.equals("123", a.posted.target)
    assert.is_nil(b.posted)
  end)

  it("lists only unposted comments", function()
    local st = store.new()
    local a = st.add({ file = "a.ts", line = 1, side = "new", type = "note", text = "a" })
    st.add({ file = "b.ts", line = 1, side = "new", type = "note", text = "b" })
    st.mark_posted({ a }, { service = "github", target = "123", url = "u", at = 1 })
    local left = st.unposted()
    assert.equals(1, #left)
    assert.equals("b", left[1].text)
  end)

  it("survives a save and load round trip", function()
    config.setup({ cache_dir = vim.fn.tempname() })
    local key = "posted-round-trip"
    local st = store.new()
    st.attach(key)
    local a = st.add({ file = "a.ts", line = 1, side = "new", type = "note", text = "a" })
    st.mark_posted({ a }, { service = "github", target = "123", url = "u", at = 7 })
    local reloaded = storage.load(key)
    assert.equals(1, #reloaded)
    assert.equals("github", reloaded[1].posted.service)
    assert.equals(7, reloaded[1].posted.at)
    storage.clear(key)
    config.setup({})
  end)

  it("loads an older store with no posted field as unposted", function()
    config.setup({ cache_dir = vim.fn.tempname() })
    local key = "legacy-store"
    storage.save(key, { { file = "a.ts", line = 1, side = "new", type = "note", text = "a" } })
    local st = store.new()
    st.attach(key)
    assert.equals(1, #st.unposted())
    storage.clear(key)
    config.setup({})
  end)

  it("marks a posted box's header without changing an unposted one", function()
    local plain = marks.build_box("hi", "Issue", "Hl")
    assert.is_truthy(plain[1][1][1]:match("%[ISSUE%]"))
    assert.is_nil(plain[1][1][1]:match("POSTED"))
    local posted = marks.build_box("hi", "Issue", "Hl", { posted = true })
    assert.is_truthy(posted[1][1][1]:match("%[ISSUE · POSTED%]"))
    -- Widening the header must not break the box: every line the same width.
    local width = vim.fn.strdisplaywidth(posted[1][1][1])
    for _, line in ipairs(posted) do
      assert.equals(width, vim.fn.strdisplaywidth(line[1][1]))
    end
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_posted_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: FAIL — `attempt to call field 'mark_posted' (a nil value)`

- [ ] **Step 3: Write minimal implementation**

In `lua/intentdiff/comments/store.lua`, add before `function self.clear()`:

```lua
  --- Record that `posted_list` reached a review service.
  ---
  --- One change event for the whole batch, not one per comment: the listener
  --- writes the entire store to disk, and a 40-comment review would otherwise
  --- rewrite the file 40 times.
  ---
  --- Editing a stamped comment deliberately does NOT clear the stamp — see
  --- comments/submit.lua. The edit is local; the service still holds what was
  --- sent, and re-posting would open a second thread.
  function self.mark_posted(posted_list, stamp)
    if #(posted_list or {}) == 0 then
      return
    end
    for _, c in ipairs(posted_list) do
      c.posted = stamp
    end
    changed()
  end

  --- Comments not yet sent to a review service.
  --- @return intentdiff.Comment[]
  function self.unposted()
    local out = {}
    for _, c in ipairs(comments) do
      if not c.posted then
        out[#out + 1] = c
      end
    end
    return out
  end
```

In `lua/intentdiff/comments/marks.lua`, change `build_box`'s signature and header line:

```lua
--- @param opts { posted: boolean|nil }|nil
function M.build_box(text, type_name, hl_group, opts)
```

and replace the `local header = …` line with:

```lua
  -- `· POSTED` rides INSIDE the brackets so the header stays one token and the
  -- clamp below still measures the whole thing.
  local header = ("[%s]"):format(tostring(type_name):upper())
  if opts and opts.posted then
    header = ("[%s · POSTED]"):format(tostring(type_name):upper())
  end
```

Then at the two `M.build_box(c.text, info.name, sign_hl)` call sites (around lines 171 and 201), pass the flag:

```lua
  local box = M.build_box(c.text, info.name, sign_hl, { posted = c.posted ~= nil })
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_posted_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: PASS (5 successes)

Then run the comment render suite, which asserts on box geometry:
Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_render_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: PASS, unchanged

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/comments/store.lua lua/intentdiff/comments/marks.lua tests/comments_posted_spec.lua
git commit -m "feat: record which comments were posted to a review service"
```

---

### Task 9: The submit flow and its wiring

**Files:**
- Create: `lua/intentdiff/comments/submit.lua`
- Modify: `lua/intentdiff/comments/init.lua` (add `M.submit`)
- Modify: `lua/intentdiff/config.lua:3-24` (add `forge`, `forge_opts`), `:139-163` (add `submit_review`)
- Modify: `lua/intentdiff/view.lua:744-759` (bind the action), `:710-713` (desc)
- Modify: `lua/intentdiff/keymap_help.lua:113-129` (cheatsheet row)
- Modify: `plugin/intentdiff.lua` (add the command)
- Test: `tests/comments_submit_spec.lua`

**Interfaces:**
- Consumes: `forges.collect` / `forges.preflight` (Tasks 2, 6), `payload.build` (Task 3), `anchor.pr_hunks` / `anchor.predicate` (Task 7), `store.unposted` / `store.mark_posted` (Task 8), `forge.submit` (Task 5)
- Produces:
  - `submit.plan(state, pf, unposted_count, total_count) -> { ok, mode, message, verdict_only }` — pure; the text and shape of the confirmation
  - `comments.submit(tabpage)` — the interactive entry point

- [ ] **Step 1: Write the failing test**

Create `tests/comments_submit_spec.lua`:

```lua
local submit = require("intentdiff.comments.submit")

local function target()
  return { service = "github", id = "123", url = "u", title = "T",
    head_sha = "aaaa", base_ref = "main" }
end

describe("comments.submit.plan", function()
  it("refuses and explains when preflight says no PR", function()
    local p = submit.plan({ branch = "feat/x" },
      { mode = "no_pr", reason = "no PR for branch feat/x — create one first (gh pr create)" }, 2, 2)
    assert.is_false(p.ok)
    assert.is_truthy(p.message:match("gh pr create"))
  end)

  it("refuses on the default branch", function()
    local p = submit.plan({ branch = "main" },
      { mode = "default_branch", reason = "you are on main — no PR to comment on" }, 2, 2)
    assert.is_false(p.ok)
    assert.is_truthy(p.message:match("no PR to comment on"))
  end)

  it("announces an inline submit with the PR number", function()
    local p = submit.plan({ target = target() }, { mode = "inline" }, 3, 3)
    assert.is_true(p.ok)
    assert.equals("inline", p.mode)
    assert.is_truthy(p.message:match("#123"))
    assert.is_truthy(p.message:match("3 comment"))
    assert.is_false(p.verdict_only)
  end)

  it("states the reason when degrading to a general comment", function()
    local p = submit.plan({ target = target() },
      { mode = "general", reason = "2 of 3 commented files have uncommitted changes" }, 3, 3)
    assert.is_true(p.ok)
    assert.equals("general", p.mode)
    assert.is_truthy(p.message:match("uncommitted"))
    assert.is_truthy(p.message:match("not on individual lines"))
  end)

  it("reports how many were already posted", function()
    local p = submit.plan({ target = target() }, { mode = "inline" }, 2, 6)
    assert.is_truthy(p.message:match("4 of 6"))
    assert.is_truthy(p.message:match("2 new"))
  end)

  it("offers a verdict-only submit when everything is posted", function()
    local p = submit.plan({ target = target() }, { mode = "inline" }, 0, 6)
    assert.is_true(p.ok)
    assert.is_true(p.verdict_only)
    assert.is_truthy(p.message:match("already posted"))
  end)
end)

describe("comments.submit.verdict_choices", function()
  it("offers the three verdicts a forge advertises, plus cancel", function()
    local choices = submit.verdict_choices({
      verdicts = { "approve", "request_changes", "comment" },
    })
    assert.equals(4, #choices)
    assert.equals("approve", choices[1].verdict)
    assert.equals("request_changes", choices[2].verdict)
    assert.equals("comment", choices[3].verdict)
    assert.is_nil(choices[4].verdict)
    assert.is_truthy(choices[4].label:match("[Cc]ancel"))
  end)

  it("omits a verdict the forge cannot express", function()
    local choices = submit.verdict_choices({ verdicts = { "comment" } })
    assert.equals(2, #choices)
    assert.equals("comment", choices[1].verdict)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_submit_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: FAIL — `module 'intentdiff.comments.submit' not found`

- [ ] **Step 3: Write minimal implementation**

Create `lua/intentdiff/comments/submit.lua`:

```lua
-- Sending a review to the service hosting it.
--
-- NOTHING here contacts the service until the user has picked a verdict.
-- Everything before that point is local: git facts, a preflight decision, and a
-- payload built in memory. Cancelling at any prompt posts nothing.
--
-- The DECISIONS (what to say, what to offer) are pure functions at the top;
-- the vim.ui round trips that string them together are at the bottom. That is
-- what makes the wording and the mode logic testable without a review tab, a
-- repository, or a `gh`.
local M = {}

local VERDICT_LABELS = {
  approve = "Approve",
  request_changes = "Request changes",
  comment = "Comment (no verdict)",
}
local VERDICT_ORDER = { "approve", "request_changes", "comment" }

--- What the confirmation prompt says, and whether there is anything to confirm.
---
--- `unposted` vs `total` is what keeps a second submit from duplicating a
--- review: only the new comments are sent, and the prompt says how many are
--- being skipped so the count is never a surprise.
--- @return { ok: boolean, mode: string|nil, message: string, verdict_only: boolean }
function M.plan(state, pf, unposted, total)
  if pf.mode ~= "inline" and pf.mode ~= "general" then
    return { ok = false, mode = pf.mode, message = pf.reason or pf.mode, verdict_only = false }
  end
  local target = state.target
  local lines = {}
  local verdict_only = unposted == 0

  if verdict_only then
    lines[#lines + 1] = ("All %d comment(s) are already posted to PR #%s.")
      :format(total, target.id)
    lines[#lines + 1] = "Submit a verdict on its own?"
  else
    if unposted < total then
      lines[#lines + 1] = ("%d of %d comment(s) already posted to PR #%s — submitting the %d new one(s).")
        :format(total - unposted, total, target.id, unposted)
    else
      lines[#lines + 1] = ("Submitting %d comment(s) to PR #%s (%s).")
        :format(unposted, target.id, target.title or "")
    end
    if pf.mode == "general" then
      lines[#lines + 1] = pf.reason
      lines[#lines + 1] =
        "Comments will be posted as ONE general comment on the PR, not on individual lines."
    end
  end
  return {
    ok = true,
    mode = pf.mode,
    message = table.concat(lines, "\n"),
    verdict_only = verdict_only,
  }
end

--- The verdict picker's rows: what this forge can express, then Cancel.
---
--- Driven by capabilities rather than hardcoded, so a service that cannot
--- express "request changes" simply does not offer it.
--- @return { verdict: string|nil, label: string }[]
function M.verdict_choices(capabilities)
  local allowed = {}
  for _, v in ipairs((capabilities or {}).verdicts or VERDICT_ORDER) do
    allowed[v] = true
  end
  local out = {}
  for _, v in ipairs(VERDICT_ORDER) do
    if allowed[v] then
      out[#out + 1] = { verdict = v, label = VERDICT_LABELS[v] }
    end
  end
  out[#out + 1] = { verdict = nil, label = "Cancel — post nothing" }
  return out
end

local function notify(msg, level)
  vim.notify("intent-diff: " .. msg, level or vim.log.levels.INFO)
end

--- The distinct files the comments touch, for preflight's dirty intersection.
local function files_of(comment_list)
  local seen, out = {}, {}
  for _, c in ipairs(comment_list) do
    if c.file and not seen[c.file] then
      seen[c.file] = true
      out[#out + 1] = c.file
    end
  end
  return out
end

--- Post `payload`, stamp what landed, offer to close.
---
--- Stamping happens ONLY on success. The reviews API is atomic, so a failure
--- means nothing reached the service and marking anything posted would strand
--- real feedback with no way to resend it.
local function post(entry, tabpage, state, payload, sent_comments)
  state.target.git_root = state.git_root
  state.forge.submit(state.target, payload, function(result, err, kind)
    vim.schedule(function()
      if not result then
        if kind == "self_approve" then
          notify(err, vim.log.levels.WARN)
          local answer = vim.fn.confirm(
            "GitHub will not let you approve your own PR. Post the same review as a plain Comment?",
            "&Yes\n&No", 2)
          if answer == 1 then
            payload.verdict = "comment"
            return post(entry, tabpage, state, payload, sent_comments)
          end
          return
        end
        return notify(err or "submit failed", vim.log.levels.ERROR)
      end
      local st = entry.comment_store
      if st then
        st.mark_posted(sent_comments, {
          service = state.target.service,
          target = state.target.id,
          url = result.url,
          at = os.time(),
        })
      end
      require("intentdiff.comments.marks").refresh(tabpage)
      require("intentdiff.comments").refresh_sidebar(tabpage)
      notify(("submitted %d comment(s) to PR #%s — %s")
        :format(#sent_comments, state.target.id, result.url or ""))
      local answer = vim.fn.confirm("Close the review tab?", "&Yes\n&No", 2)
      if answer == 1 then
        require("intentdiff").close(tabpage)
      end
    end)
  end)
end

--- Ask for a verdict, build the payload, post.
local function choose_verdict(entry, tabpage, state, pf, to_send, model)
  local choices = M.verdict_choices(state.forge.capabilities())
  vim.ui.select(choices, {
    prompt = ("Submit review to PR #%s"):format(state.target.id),
    format_item = function(c) return c.label end,
  }, function(choice)
    if not (choice and choice.verdict) then
      return notify("cancelled — nothing was posted")
    end
    local anchorable = nil
    local mode = pf.mode
    if mode == "inline" then
      local hunk_list, err = require("intentdiff.comments.anchor")
        .pr_hunks(state.git_root, state.target.base_ref)
      if not hunk_list then
        -- No local view of the PR diff means no way to know which lines
        -- anchor. Degrade rather than gamble on a 422 that costs the review.
        notify((err or "cannot read the PR diff") .. " — posting as a general comment",
          vim.log.levels.WARN)
        mode = "general"
      else
        anchorable = require("intentdiff.comments.anchor").predicate(hunk_list)
      end
    end
    local payload = require("intentdiff.comments.payload")
      .build(to_send, model, mode, anchorable)
    payload.verdict = choice.verdict
    if payload.demoted > 0 then
      notify(("%d comment(s) could not be anchored and were added to the review body")
        :format(payload.demoted), vim.log.levels.WARN)
    end
    post(entry, tabpage, state, payload, to_send)
  end)
end

--- The whole flow, from a key press to a posted review.
function M.run(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = require("intentdiff")._session(tabpage)
  local st = entry and entry.comment_store
  if not st then
    return notify("no comments available in this tab", vim.log.levels.WARN)
  end
  local all = st.get_all()
  if #all == 0 then
    return notify("no comments to submit", vim.log.levels.WARN)
  end
  local git_root = entry.sess and entry.sess.git_root
  if not git_root then
    return notify("this review has no repository to submit to", vim.log.levels.WARN)
  end

  local forges = require("intentdiff.forges")
  forges.collect(git_root, files_of(all), function(state, err)
    vim.schedule(function()
      if err then
        return notify(err, vim.log.levels.WARN)
      end
      local pf = forges.preflight(state)
      local unposted = st.unposted()
      local plan = M.plan(state, pf, #unposted, #all)
      if not plan.ok then
        return notify(plan.message, vim.log.levels.WARN)
      end
      local answer = vim.fn.confirm(plan.message, "&Submit\n&Cancel", 2)
      if answer ~= 1 then
        return notify("cancelled — nothing was posted")
      end
      local model = entry.model or { groups = {} }
      choose_verdict(entry, tabpage, state, pf, plan.verdict_only and {} or unposted, model)
    end)
  end)
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedDirectory tests/comments_submit_spec.lua { minimal_init = 'tests/init.lua' }"`
Expected: PASS (8 successes)

- [ ] **Step 5: Wire the entry point, config, keymap, command and cheatsheet**

In `lua/intentdiff/comments/init.lua`, add after `M.export_and_close`:

```lua
--- Submit the review to the service hosting it — a GitHub PR today. The flow
--- lives in comments/submit.lua; this is the name the keymap and command bind
--- to.
function M.submit(tabpage)
  require("intentdiff.comments.submit").run(tabpage)
end
```

In `lua/intentdiff/config.lua`, add to `M.defaults` after `max_hunks`:

```lua
  -- Where a finished review can be sent, besides the clipboard and a file.
  -- "auto" resolves by the origin remote's host; a name loads
  -- intentdiff.forges.<name>; a table is used directly; false disables the
  -- feature entirely. Nothing is ever sent without an explicit verdict.
  forge = "auto",
  forge_opts = {
    github = { cmd = "gh", timeout_ms = 30000 },
  },
```

and to `M.defaults.keymaps.comments`, after `export_and_close`:

```lua
      -- Submit to the PR this branch is linked to. Distinct from the exports
      -- above because it leaves the machine: it prompts for a verdict and
      -- posts nothing until one is chosen.
      submit_review = "<localleader>cP",
```

In `lua/intentdiff/view.lua`, add to the comments handler table (after `export_and_close`):

```lua
    submit_review = function() comments.submit(tabpage) end,
```

and to the descs table near line 713:

```lua
  submit_review = "intent-diff: submit the review to the pull request",
```

In `lua/intentdiff/keymap_help.lua`, add after the `export_and_close` row:

```lua
      { ckm.submit_review, "Submit the review to the pull request" },
```

In `plugin/intentdiff.lua`, add after `IntentDiffCommentsClear`:

```lua
vim.api.nvim_create_user_command("IntentDiffCommentsSubmit", function()
  if comments_off() then
    return
  end
  require("intentdiff.comments").submit()
end, { desc = "intent-diff: submit the review to the pull request" })
```

- [ ] **Step 6: Run the whole suite**

Run: `./tests/run_tests.sh`
Expected: every spec passes, including `tests/config_spec.lua` and `tests/keymap_help_spec.lua`, which assert on the config and cheatsheet shapes.

- [ ] **Step 7: Commit**

```bash
git add lua/intentdiff/comments/submit.lua lua/intentdiff/comments/init.lua \
        lua/intentdiff/config.lua lua/intentdiff/view.lua \
        lua/intentdiff/keymap_help.lua plugin/intentdiff.lua \
        tests/comments_submit_spec.lua
git commit -m "feat: submit a review to the linked pull request"
```

---

### Task 10: Documentation

**Files:**
- Modify: `README.md:310-320` (the export table), `:185-241` (the keymap table), `:360+` (configuration block)

**Interfaces:**
- Consumes: everything above
- Produces: nothing code depends on

- [ ] **Step 1: Add the export table row**

In the `### Exporting` table, after the `<localleader>q` row:

```markdown
| `<localleader>cP` | `:IntentDiffCommentsSubmit` | Submit the review to the pull request this branch is linked to |
```

- [ ] **Step 2: Add the new subsection**

After the `### Exporting` section's sample export, add:

````markdown
### Submitting to a pull request

When the branch is linked to a GitHub pull request, `<localleader>cP`
(`:IntentDiffCommentsSubmit`) posts the review to it as **one atomic review** —
inline comments, a body, and a verdict together. Requires the
[`gh` CLI](https://cli.github.com), authenticated.

Nothing leaves your machine until you pick a verdict:

```
Approve  ·  Request changes  ·  Comment (no verdict)  ·  Cancel
```

**Two modes.** Which one you get is decided before anything is sent:

- **Inline** — when local `HEAD` *is* the PR head and no commented file has
  uncommitted changes. Each comment posts on its line: ranges as multi-line
  comments, old-side comments on the left, file-level comments on the file
  itself. The body carries the intent structure and an index of what went
  where.
- **General** — anything else. Line numbers in a dirty tree, or at a commit the
  PR has not seen, do not mean what they mean on GitHub, so the whole review
  posts as one general comment carrying the Markdown export. You are told which
  it will be, and why, before you confirm.

Other states refuse, each with its own reason: on the default branch there is
no PR to comment on; on a branch with no PR yet you are asked to create one
first; a remote that is not GitHub reports that no forge serves it.

Comments GitHub cannot anchor — a line outside the PR diff — are moved into the
review body under `## Not attached to a line` rather than dropped, and you are
told how many. This is worked out locally against the PR's own diff, because
the reviews API is atomic: one bad line would reject the entire review.

**Posted comments are remembered.** Each one that lands is stamped, its box
header reads `[ISSUE · POSTED]`, and a later submit offers only the comments
you have added since — so a second pass cannot duplicate the first. When every
comment is already posted, you are offered a verdict on its own. Editing a
posted comment does not clear the stamp: the edit is local, and the PR still
holds what was sent.

The abstraction behind this is service-neutral (`lua/intentdiff/forges/`), with
GitHub as the first implementation; the payload is expressed in the plugin's own
vocabulary so another git-based service can be added as one module.
````

- [ ] **Step 3: Document the configuration**

In the `## Configuration` block, after `max_hunks`:

```lua
  -- Where a finished review can be sent, besides the clipboard and a file.
  -- "auto" picks by the origin remote's host; "github" forces it; a table
  -- implementing the forge interface is used directly; false disables it.
  forge = "auto",
  forge_opts = {
    github = { cmd = "gh", timeout_ms = 30000 },
  },
```

And in the `keymaps.comments` block of that same sample:

```lua
      submit_review = "<localleader>cP",
```

- [ ] **Step 4: Add the keymap table row**

In the `## Keymaps` comments table, after the `<localleader>q` row:

```markdown
| `<localleader>cP` | Submit the review to the pull request |
```

- [ ] **Step 5: Verify and commit**

Run: `./tests/run_tests.sh`
Expected: full suite passes.

```bash
git add README.md
git commit -m "docs: submitting a review to a pull request"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: the forge interface and resolution → Tasks 4 and 6; preflight → Task 2; GitHub detect/submit → Tasks 4 and 5; local anchoring → Task 7; payload composition and the `export.bucket` refactor → Tasks 1 and 3; posted state → Task 8; the interactive flow, config, keys and command → Task 9; documentation → Task 10. The spec's `forge = false` distinction is covered by `forges.resolve` in Task 6 and its test. The verdict-only submit is covered by `submit.plan` in Task 9.

**Known deviation from the spec.** The spec illustrates the posted marker as `╭─ Issue · posted ─╮`. The real `marks.build_box` renders `[ISSUE]`, uppercased and bracketed, so Task 8 implements `[ISSUE · POSTED]` to match the existing format.

**Type consistency.** `payload.build(comments, model, mode, anchorable)` returns `{ body, comments, demoted }` and Task 9 sets `.verdict` on it before handing it to `forge.submit`, which reads `payload.verdict`, `payload.body` and `payload.comments` — consistent. Inline comment fields (`path`, `line`, `line_end`, `side`, `body`, `file_level`) are produced by Task 3 and consumed by Task 5's `api_comment` under exactly those names. `state.forge`, `state.target`, `state.git_root` are produced by Task 6's `collect` and consumed by Task 9. `store.mark_posted` / `store.unposted` are defined in Task 8 and called in Task 9.
