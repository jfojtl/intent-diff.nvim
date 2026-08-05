# Unified Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace codediff's per-file diff path and our own whole-intent preview with a single renderer intent-diff owns, so a file view is a render plan over one file and an intent view is a plan over several.

**Architecture:** Three new modules under `lua/intentdiff/render/`. `plan.lua` is pure — file entries carrying full content plus a visible-hunk set become paired rows, a sparse row→`(file, line, side)` map, highlight spans and fold ranges. `paint.lua` is impure — a plan becomes two scratch buffers with extmarks, folds and scrollbind. `content.lua` caches both sides of every file. `view.lua` shrinks to owning the tab and two windows and stops creating a codediff session entirely.

**Tech Stack:** Lua, Neovim 0.10+ API, plenary.nvim busted specs, codediff.nvim — consumed only through `lua/intentdiff/view.lua` and `lua/intentdiff/render/*`, and only its three leaf modules (`core.diff`, `core.git`, `ui.inline`/`ui.highlights` helpers).

**Spec:** `docs/superpowers/specs/2026-08-05-unified-renderer-design.md`

## Global Constraints

- Work directly on `master`. **Never push.**
- Commits are GPG-signed. The repo signs automatically; do not pass `-S` explicitly. End every commit message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` — this matches the existing history.
- Run the full suite with `tests/run_tests.sh`; it must report `Failed: 0` and `Errors: 0` in every spec file. **Baseline before this plan: 510 successes across 30 spec files.** Task 13 deliberately reduces the success count by deleting obsolete assertions; every task before it must keep the count at or above 510.
- `PlenaryBustedFile` does NOT work here — plenary spawns a child nvim with `--noplugin` and no `-u`, so codediff is off the runtimepath. For a fast loop use:
  `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/<file>_spec.lua')" -c qa`
- Only `lua/intentdiff/view.lua` and `lua/intentdiff/render/*.lua` may `require` codediff. Permitted modules and nothing else: `codediff.core.diff`, `codediff.core.git`, `codediff.ui.inline`, `codediff.ui.highlights`.
- Hunk ranges are 1-based and **end-exclusive**. A zero-length side is a zero-width anchor at `start + 1` (`hunks.lua:3-8`).
- `pane.map` is **sparse** by construction. Never walk it with `ipairs` — that stops at the first row addressing nothing. Walk `1 .. #pane.lines`.
- `rows_for` must be derived by *scanning* `map`, never accumulated alongside it. A second independently-built index is how the renderer and the comment store previously disagreed about a drifted comment.
- Never write `x and y or z` where `y` can legitimately be `false` or `""`. An empty source line is a real falsy middle term; this has cost three fix rounds in this repo.
- **Lua does not hoist `local`s.** `lua/intentdiff/init.lua` is one long chunk of locals; a function calling one defined later must use the file's existing forward-declaration pattern (`local close_entry`, `local select_file`, `local auto_open_first`).
- Tests never call a real LLM — fake provider functions or `helpers.fake_bin` only.

## File Structure

**Create:**
- `lua/intentdiff/render/plan.lua` — pure. Files + visible set → panes, map, spans, runs, folds.
- `lua/intentdiff/render/paint.lua` — impure. Plan + two windows → buffers, extmarks, folds, scrollbind.
- `lua/intentdiff/render/content.lua` — session-scoped `(revision, path) → lines` cache.
- `tests/render_plan_spec.lua`, `tests/render_paint_spec.lua`, `tests/render_content_spec.lua`
- `ATTRIBUTION.md`

**Modify:** `lua/intentdiff/hunks.lua` (binary detection), `highlight.lua` (groups), `view.lua` (gutted), `comments/init.lua`, `comments/marks.lua`, `navigation.lua`, `config.lua`, `init.lua`, `README.md`

**Delete:** `lua/intentdiff/preview.lua` (superseded by `render/plan.lua`), and the obsolete codediff-internals assertions in Task 13.

## Shared Interfaces

Every task depends on these exact shapes. They are defined here once so no task invents a variant.

```lua
--- A file entry handed to plan.build.
--- `original`/`modified` are FULL file content. Either may be nil, which puts
--- that file into hunks-only fallback (folds disabled for it).
file_entry = {
  path      = "src/auth.lua",
  old_path  = nil,          -- set only on rename
  status    = "M",          -- "M" | "A" | "D" | "??"
  filetype  = "lua",        -- resolved by plan.build's caller
  binary    = false,
  hunks     = { hunk, ... },-- from hunks.lua, ALL of the file's hunks
  original  = { "line", ... } or nil,
  modified  = { "line", ... } or nil,
}

--- A highlight span. col_end == -1 means the whole line.
span = { line = 1, col_start = 0, col_end = -1, hl = "IntentDiffAdd" }

--- One rendered pane.
pane = {
  lines = { "text", ... },
  spans = { span, ... },
  map   = { [row] = { file = "src/auth.lua", line = 42, side = "new" } },  -- SPARSE
}

--- The plan.
plan = {
  layout   = "side-by-side",     -- or "inline"
  original = pane,               -- in inline layout this is nil
  modified = pane,               -- both panes have EQUAL line counts
  files    = { { path, filetype, status, binary, fallback = false }, ... },
  runs     = {                   -- changed runs, for character refinement
    {
      file       = "src/auth.lua",
      minus      = { "old text", ... },
      plus       = { "new text", ... },
      minus_rows = { 12, 13 },   -- pane rows each minus line landed on
      plus_rows  = { 12, 14 },   -- pane rows each plus line landed on
    },
  },
  folds    = { { 2, 11 }, { 40, 88 } },  -- inclusive row ranges to close
}
```

```lua
plan.build(files, visible, layout, opts)
--- @param files    file_entry[]
--- @param visible  table  set of hunk ids: { ["src/auth.lua:1"] = true }
--- @param layout   string "inline" | "side-by-side"
--- @param opts     table|nil { context = 3, line_budget = 20000 }
--- @return plan

plan.target_at(pane, row)   --- @return table|nil { file, line, side }
plan.rows_for(pane, comment) --- @return integer[] ascending
```

---

### Task 1: Binary files are detected and marked

`git diff` emits `Binary files a/x and b/x differ` with no `@@`, so `hunks.lua` currently yields a file entry with zero hunks. That is harmless today because nothing renders it, but under full content we would `git show` a binary.

**Files:**
- Modify: `lua/intentdiff/hunks.lua` (`M.parse`, the `diff --git` and body branches)
- Test: `tests/hunks_parse_spec.lua`

**Interfaces:**
- Consumes: nothing
- Produces: `file_entry.binary` boolean on every entry returned by `hunks.parse`

- [ ] **Step 1: Write the failing test**

Append to `tests/hunks_parse_spec.lua`:

```lua
describe("hunks.parse binary files", function()
  it("marks a binary file and gives it no hunks", function()
    local diff = table.concat({
      "diff --git a/logo.png b/logo.png",
      "index 1111111..2222222 100644",
      "Binary files a/logo.png and b/logo.png differ",
      "diff --git a/src/a.lua b/src/a.lua",
      "index 3333333..4444444 100644",
      "--- a/src/a.lua",
      "+++ b/src/a.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
    }, "\n") .. "\n"
    local hunks, files = require("intentdiff.hunks").parse(diff)
    assert.equals(2, #files)
    assert.equals("logo.png", files[1].path)
    assert.is_true(files[1].binary)
    assert.equals("src/a.lua", files[2].path)
    assert.is_false(files[2].binary)
    -- Only the text file contributes hunks.
    assert.equals(1, #hunks)
    assert.equals("src/a.lua", hunks[1].file)
  end)

  it("marks a binary file added in this diff", function()
    local diff = table.concat({
      "diff --git a/img.bin b/img.bin",
      "new file mode 100644",
      "index 0000000..5555555",
      "Binary files /dev/null and b/img.bin differ",
    }, "\n") .. "\n"
    local _, files = require("intentdiff.hunks").parse(diff)
    assert.equals(1, #files)
    assert.is_true(files[1].binary)
    assert.equals("A", files[1].status)
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/hunks_parse_spec.lua')" -c qa`
Expected: FAIL — `files[1].binary` is nil, not `true`/`false`.

- [ ] **Step 3: Implement**

In `lua/intentdiff/hunks.lua`, in the `diff --git` branch of `M.parse`, add `binary = false` to the pushed file table:

```lua
      files[#files + 1] = { path = file, status = "M", old_path = old_path, binary = false }
```

Then add a branch alongside the existing `new file mode` / `deleted file mode` branches, before the `^@@` branch:

```lua
    elseif line:match("^Binary files ") then
      -- No @@ header follows, so `current` stays nil and this file
      -- contributes no hunks. Mark it so the renderer shows a marker row
      -- instead of trying to read the file's bytes as text.
      files[#files].binary = true
```

- [ ] **Step 4: Run tests and confirm they pass**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/hunks_parse_spec.lua')" -c qa`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`, successes ≥ 512.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/hunks.lua tests/hunks_parse_spec.lua
git commit -m "$(cat <<'EOF'
feat(hunks): detect and mark binary files

git diff reports binary files with no @@ header, so they already produced
zero hunks. Mark them explicitly: the unified renderer needs to show a
marker row rather than read their bytes as text.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `render/content.lua` fetches and caches both sides

**Files:**
- Create: `lua/intentdiff/render/content.lua`
- Test: `tests/render_content_spec.lua`

**Interfaces:**
- Consumes: `file_entry` fields `path`, `old_path`, `status`, `binary`
- Produces:
  - `content.ensure(sess, files, on_ready) -> boolean ready, table missing`
  - `content.get(sess, path, side) -> string[]|nil` where `side` is `"old"` or `"new"`
  - `content.invalidate(sess, path)` — drops the worktree side of one file

`sess` carries `git_root`, `base_revision`, `target_revision` (nil means the working tree).

Content sources:

| Status | old side | new side |
|---|---|---|
| `M` | `git show <base>:<old_path or path>` | worktree read, or `git show <target>:<path>` |
| `A` / `??` | `{}` (empty) | worktree read |
| `D` | `git show <base>:<path>` | `{}` (empty) |
| binary | `{}` | `{}` |

- [ ] **Step 1: Write the failing test**

Create `tests/render_content_spec.lua`:

```lua
local helpers = require("tests.helpers")
local content = require("intentdiff.render.content")

local function sess_for(repo, base)
  return { git_root = repo, base_revision = base, target_revision = nil }
end

describe("render.content", function()
  it("reads the base revision for the old side and the worktree for the new", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\ntwo\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "one\nTWO\nthree\n")

    local sess = sess_for(repo, base)
    local files = { { path = "a.lua", status = "M", binary = false } }
    local done = false
    content.ensure(sess, files, function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))

    assert.same({ "one", "two" }, content.get(sess, "a.lua", "old"))
    assert.same({ "one", "TWO", "three" }, content.get(sess, "a.lua", "new"))
  end)

  it("gives an added file an empty old side", function()
    local repo = helpers.make_repo({ ["a.lua"] = "x\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "new.lua", "fresh\n")

    local sess = sess_for(repo, base)
    local done = false
    content.ensure(sess, { { path = "new.lua", status = "??", binary = false } },
      function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))

    assert.same({}, content.get(sess, "new.lua", "old"))
    assert.same({ "fresh" }, content.get(sess, "new.lua", "new"))
  end)

  it("gives a deleted file an empty new side", function()
    local repo = helpers.make_repo({ ["gone.lua"] = "bye\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    os.remove(repo .. "/gone.lua")

    local sess = sess_for(repo, base)
    local done = false
    content.ensure(sess, { { path = "gone.lua", status = "D", binary = false } },
      function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))

    assert.same({ "bye" }, content.get(sess, "gone.lua", "old"))
    assert.same({}, content.get(sess, "gone.lua", "new"))
  end)

  it("gives a binary file both sides empty and never shells out", function()
    local repo = helpers.make_repo({ ["a.lua"] = "x\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))

    local sess = sess_for(repo, base)
    local ready = content.ensure(sess, { { path = "b.png", status = "M", binary = true } })
    -- Resolved synchronously: nothing to fetch.
    assert.is_true(ready)
    assert.same({}, content.get(sess, "b.png", "old"))
    assert.same({}, content.get(sess, "b.png", "new"))
  end)

  it("reports not-ready and lists what is missing before content lands", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))

    local sess = sess_for(repo, base)
    local ready, missing = content.ensure(sess, { { path = "a.lua", status = "M", binary = false } })
    assert.is_false(ready)
    assert.same({ "a.lua" }, missing)
  end)

  it("serves a second request from cache without refetching", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))

    local sess = sess_for(repo, base)
    local files = { { path = "a.lua", status = "M", binary = false } }
    local done = false
    content.ensure(sess, files, function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))

    -- Now resolved synchronously.
    assert.is_true(content.ensure(sess, files))
  end)

  it("re-reads the worktree side after invalidate but keeps the base side", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "two\n")

    local sess = sess_for(repo, base)
    local files = { { path = "a.lua", status = "M", binary = false } }
    local done = false
    content.ensure(sess, files, function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))
    assert.same({ "two" }, content.get(sess, "a.lua", "new"))

    helpers.write_file(repo, "a.lua", "three\n")
    content.invalidate(sess, "a.lua")
    assert.is_nil(content.get(sess, "a.lua", "new"))
    assert.same({ "one" }, content.get(sess, "a.lua", "old"), "base side survives invalidate")

    done = false
    content.ensure(sess, files, function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))
    assert.same({ "three" }, content.get(sess, "a.lua", "new"))
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_content_spec.lua')" -c qa`
Expected: FAIL — module `intentdiff.render.content` not found.

- [ ] **Step 3: Implement**

Create `lua/intentdiff/render/content.lua`:

```lua
-- Session-scoped cache of both sides of every file in a review.
--
-- The plugin otherwise never reads file content — it parses `git diff` output.
-- Full-content render plans need both sides in full, which is per-file I/O, so
-- everything here exists to make that cost once per file per review instead of
-- once per repaint.
--
-- The base revision's content is immutable for the life of a review, so it is
-- cached forever. The worktree side is dropped by `invalidate` when its file
-- changes on disk.
local M = {}

--- caches[sess_key] = { old = { [path] = lines }, new = { [path] = lines },
---                      inflight = { [path] = true } }
local caches = {}

local function key_of(sess)
  return table.concat({ sess.git_root or "", sess.base_revision or "",
    sess.target_revision or "WORKING" }, "\0")
end

local function cache_of(sess)
  local k = key_of(sess)
  if not caches[k] then
    caches[k] = { old = {}, new = {}, inflight = {} }
  end
  return caches[k]
end

--- `git show <revision>:<path>` as a line array, or nil on any failure.
--- Deliberately synchronous-per-call but driven from a scheduled worker below:
--- vim.system's async form would interleave callbacks with repaints, and the
--- cache is warmed ahead of navigation anyway.
local function git_show(git_root, revision, path)
  local out = vim.fn.systemlist({ "git", "-C", git_root, "show", revision .. ":" .. path })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out
end

local function read_worktree(git_root, path)
  local ok, lines = pcall(vim.fn.readfile, git_root .. "/" .. path)
  if not ok then
    return nil
  end
  return lines
end

--- Fetch both sides of one file into `cache`. Returns nothing; failures leave
--- the side unset so `get` answers nil and the caller falls back.
local function fetch(sess, cache, file)
  local path, status = file.path, file.status

  if file.binary then
    cache.old[path], cache.new[path] = {}, {}
    return
  end

  -- Old side.
  if status == "A" or status == "??" then
    cache.old[path] = {}
  else
    cache.old[path] =
      git_show(sess.git_root, sess.base_revision, file.old_path or path) or nil
  end

  -- New side.
  if status == "D" then
    cache.new[path] = {}
  elseif sess.target_revision then
    cache.new[path] = git_show(sess.git_root, sess.target_revision, path) or nil
  else
    cache.new[path] = read_worktree(sess.git_root, path) or nil
  end
end

--- Cached lines for one side, or nil if not fetched (or the fetch failed).
--- @param side string "old" | "new"
--- @return string[]|nil
function M.get(sess, path, side)
  local cache = caches[key_of(sess)]
  if not cache then
    return nil
  end
  return cache[side][path]
end

--- Drop the worktree side of `path`, keeping the immutable base side.
function M.invalidate(sess, path)
  local cache = caches[key_of(sess)]
  if cache then
    cache.new[path] = nil
  end
end

--- Ensure both sides of every file are cached.
---
--- Returns `true` when everything is already resident, in which case `on_ready`
--- is NOT called — the caller can paint immediately. Otherwise returns `false`
--- plus the list of paths still missing, schedules the fetch, and calls
--- `on_ready` once when it completes. The caller paints what it can meanwhile.
--- @return boolean ready, string[] missing
function M.ensure(sess, files, on_ready)
  local cache = cache_of(sess)
  local missing = {}
  for _, file in ipairs(files) do
    if cache.old[file.path] == nil or cache.new[file.path] == nil then
      -- Binary files resolve without I/O, so settle them inline rather than
      -- reporting them missing and scheduling a worker for nothing.
      if file.binary then
        cache.old[file.path], cache.new[file.path] = {}, {}
      else
        missing[#missing + 1] = file.path
      end
    end
  end

  if #missing == 0 then
    return true, {}
  end

  local by_path = {}
  for _, file in ipairs(files) do
    by_path[file.path] = file
  end

  vim.schedule(function()
    for _, path in ipairs(missing) do
      local file = by_path[path]
      if file and not cache.inflight[path] then
        cache.inflight[path] = true
        fetch(sess, cache, file)
        cache.inflight[path] = nil
      end
    end
    if on_ready then
      on_ready()
    end
  end)

  return false, missing
end

--- Drop everything cached for `sess`. Called when a review tab closes.
function M.reset(sess)
  caches[key_of(sess)] = nil
end

return M
```

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_content_spec.lua')" -c qa`
Expected: PASS, 7 successes.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/render/content.lua tests/render_content_spec.lua
git commit -m "$(cat <<'EOF'
feat(render): cache both sides of every file in a review

Full-content render plans need each file's original and modified content in
full, which the plugin has never read before. Cache it per session: the base
revision is immutable so it is fetched once, the worktree side is dropped by
invalidate when the file changes.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `render/plan.lua` builds side-by-side panes over full content

The core of the change. `preview.lua`'s `pair_body`, sparse `map`, `target_at` and `rows_for` move here essentially unchanged; what is new is walking **full file content** with hunks marking the changed stretches, rather than emitting hunk bodies alone.

**Files:**
- Create: `lua/intentdiff/render/plan.lua`
- Test: `tests/render_plan_spec.lua`

**Interfaces:**
- Consumes: `file_entry` (see Shared Interfaces), `hunks.lua` range semantics
- Produces: `plan.build`, `plan.target_at`, `plan.rows_for` — exact signatures in Shared Interfaces. Task 4 adds inline layout, Task 5 adds `folds`/`runs`/`line_budget`.

The walk, which every later task depends on being correct:

```
o, m = 1, 1
for each hunk in file order:
  while o < hunk.original.start_line:      -- unchanged stretch before it
    emit unchanged row (original[o], modified[m])
    o, m = o+1, m+1
  emit pair_body(body_of(hunk), o, m)      -- the hunk's own rows
  o = hunk.original.end_line               -- ranges are END-EXCLUSIVE
  m = hunk.modified.end_line
while o <= #original:                      -- trailing unchanged stretch
  emit unchanged row; o, m = o+1, m+1
```

A pure addition has a zero-width original anchor, so `o` does not advance across it; a pure deletion likewise leaves `m`. Both fall out of the end-exclusive ranges without special-casing.

- [ ] **Step 1: Write the failing test**

Create `tests/render_plan_spec.lua`:

```lua
local plan = require("intentdiff.render.plan")

--- A modified file: original 5 lines, line 3 replaced.
local function modified_file()
  return {
    path = "a.lua", status = "M", filetype = "lua", binary = false,
    original = { "one", "two", "three", "four", "five" },
    modified = { "one", "two", "THREE", "four", "five" },
    hunks = { {
      id = "a.lua:1", file = "a.lua", header = "@@ -3,1 +3,1 @@",
      text = "@@ -3,1 +3,1 @@\n-three\n+THREE\n",
      original = { start_line = 3, end_line = 4 },
      modified = { start_line = 3, end_line = 4 },
      additions = 1, deletions = 1,
    } },
  }
end

describe("plan.build side-by-side", function()
  it("renders the whole file, not just the hunk", function()
    local p = plan.build({ modified_file() }, { ["a.lua:1"] = true }, "side-by-side")
    -- separator + 5 content rows
    assert.equals(6, #p.original.lines)
    assert.equals(6, #p.modified.lines)
    assert.equals("one", p.original.lines[2])
    assert.equals("five", p.original.lines[6])
  end)

  it("keeps both panes the same length", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.equals(#p.original.lines, #p.modified.lines)
  end)

  it("shows the changed line differently on each side", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.equals("three", p.original.lines[4])
    assert.equals("THREE", p.modified.lines[4])
  end)

  it("maps each row to its real file coordinate", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.same({ file = "a.lua", line = 1, side = "old" }, p.original.map[2])
    assert.same({ file = "a.lua", line = 3, side = "old" }, p.original.map[4])
    assert.same({ file = "a.lua", line = 3, side = "new" }, p.modified.map[4])
    assert.same({ file = "a.lua", line = 5, side = "new" }, p.modified.map[6])
  end)

  it("gives the separator row no map entry", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.is_nil(p.original.map[1])
    assert.is_nil(p.modified.map[1])
  end)

  it("puts the path, status and totals on the separator", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local sep = p.modified.lines[1]
    assert.truthy(sep:find("a.lua", 1, true))
    assert.truthy(sep:find("M", 1, true))
    assert.truthy(sep:find("+1", 1, true))
    assert.truthy(sep:find("-1", 1, true))
  end)

  it("pads the short side with fillers on an uneven change", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "one", "two" },
      modified = { "one", "TWO", "EXTRA" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -2,1 +2,2 @@",
        text = "@@ -2,1 +2,2 @@\n-two\n+TWO\n+EXTRA\n",
        original = { start_line = 2, end_line = 3 },
        modified = { start_line = 2, end_line = 4 },
        additions = 2, deletions = 1,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.equals(#p.original.lines, #p.modified.lines)
    assert.equals("", p.original.lines[4], "filler row is empty text")
    assert.is_nil(p.original.map[4], "a filler addresses nothing")
    assert.equals("EXTRA", p.modified.lines[4])
    assert.same({ file = "a.lua", line = 3, side = "new" }, p.modified.map[4])
  end)

  it("renders an added file as all-fillers on the original side", function()
    local file = {
      path = "new.lua", status = "A", filetype = "lua", binary = false,
      original = {},
      modified = { "fresh", "code" },
      hunks = { {
        id = "new.lua:1", file = "new.lua", header = "@@ -0,0 +1,2 @@",
        text = "@@ -0,0 +1,2 @@\n+fresh\n+code\n",
        original = { start_line = 1, end_line = 1 },
        modified = { start_line = 1, end_line = 3 },
        additions = 2, deletions = 0,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.equals(3, #p.original.lines)
    assert.equals("", p.original.lines[2])
    assert.equals("", p.original.lines[3])
    assert.equals("fresh", p.modified.lines[2])
    assert.is_nil(p.original.map[2])
    assert.same({ file = "new.lua", line = 1, side = "new" }, p.modified.map[2])
  end)

  it("renders a deleted file as all-fillers on the modified side", function()
    local file = {
      path = "gone.lua", status = "D", filetype = "lua", binary = false,
      original = { "bye", "now" },
      modified = {},
      hunks = { {
        id = "gone.lua:1", file = "gone.lua", header = "@@ -1,2 +0,0 @@",
        text = "@@ -1,2 +0,0 @@\n-bye\n-now\n",
        original = { start_line = 1, end_line = 3 },
        modified = { start_line = 1, end_line = 1 },
        additions = 0, deletions = 2,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.equals("bye", p.original.lines[2])
    assert.equals("", p.modified.lines[2])
    assert.same({ file = "gone.lua", line = 1, side = "old" }, p.original.map[2])
    assert.is_nil(p.modified.map[2])
  end)

  it("concatenates several files in order, each with its own separator", function()
    local a = modified_file()
    local b = {
      path = "b.lua", status = "M", filetype = "lua", binary = false,
      original = { "x" }, modified = { "X" },
      hunks = { {
        id = "b.lua:1", file = "b.lua", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n-x\n+X\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
    local p = plan.build({ a, b }, {}, "side-by-side")
    assert.truthy(p.modified.lines[1]:find("a.lua", 1, true))
    assert.truthy(p.modified.lines[7]:find("b.lua", 1, true))
    assert.same({ file = "b.lua", line = 1, side = "new" }, p.modified.map[8])
    assert.equals(2, #p.files)
    assert.equals("a.lua", p.files[1].path)
  end)

  it("renders a binary file as one marker row addressing nothing", function()
    local file = { path = "logo.png", status = "M", filetype = "", binary = true,
                   original = {}, modified = {}, hunks = {} }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.equals(1, #p.modified.lines)
    assert.truthy(p.modified.lines[1]:find("binary", 1, true))
    assert.is_nil(p.modified.map[1])
  end)

  it("marks the add and delete rows with the right highlight groups", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local function hl_at(pane, row)
      for _, s in ipairs(pane.spans) do
        if s.line == row then return s.hl end
      end
    end
    assert.equals("IntentDiffDelete", hl_at(p.original, 4))
    assert.equals("IntentDiffAdd", hl_at(p.modified, 4))
    assert.equals("IntentDiffFileSeparator", hl_at(p.modified, 1))
    assert.is_nil(hl_at(p.modified, 2), "unchanged rows carry no line highlight")
  end)
end)

describe("plan.target_at and plan.rows_for", function()
  it("resolves a row to its coordinate", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.same({ file = "a.lua", line = 3, side = "new" },
      plan.target_at(p.modified, 4))
    assert.is_nil(plan.target_at(p.modified, 1))
  end)

  it("finds every row a multi-line comment covers", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local rows = plan.rows_for(p.modified, {
      file = "a.lua", line = 1, line_end = 3, side = "new",
    })
    assert.same({ 2, 3, 4 }, rows)
  end)

  it("is the exact inverse of target_at over the whole pane", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    for row = 1, #p.modified.lines do
      local t = plan.target_at(p.modified, row)
      if t then
        local rows = plan.rows_for(p.modified, { file = t.file, line = t.line, side = t.side })
        assert.truthy(vim.tbl_contains(rows, row),
          ("row %d maps to %s:%d but rows_for did not return it"):format(row, t.file, t.line))
      end
    end
  end)

  it("returns no rows for a file-level or intent comment", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.same({}, plan.rows_for(p.modified, { file = "a.lua", line = 0, side = "new" }))
    assert.same({}, plan.rows_for(p.modified,
      { file = "a.lua", line = 3, side = "new", intent_title = "Auth" }))
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_plan_spec.lua')" -c qa`
Expected: FAIL — module `intentdiff.render.plan` not found.

- [ ] **Step 3: Implement**

Create `lua/intentdiff/render/plan.lua`:

```lua
-- Pure renderer. Files carrying their FULL content plus a set of hunk ids to
-- leave unfolded become paired rows, highlight spans, a row -> coordinate map,
-- character-refinement runs and fold ranges. No Neovim UI state: paint.lua
-- puts the result into buffers.
--
-- Both panes always have the SAME line count, padded with real filler rows.
-- That is what makes a fold range identical on both sides and lets plain
-- scrollbind hold the panes together.
--
-- `map` is row -> { file, line, side }, the real coordinate the row displays.
-- It is what makes every surface commentable without a preview ever becoming a
-- storage concept. Rows that display no line of any file (separators, fillers)
-- have no entry, so `map` is a SPARSE array: never walk it with ipairs, which
-- stops at the first hole. Walk `1 .. #pane.lines`.
--
-- `M.rows_for` is the inverse direction, derived by SCANNING that same array
-- rather than being built alongside it, so the two can never disagree about
-- where a comment lives.
local M = {}

local WHOLE_LINE = -1

-- ------------------------------------------------------------- hunk bodies --

--- Body lines of a hunk, without its @@ header and without the
--- "\ No newline at end of file" marker (metadata, not content).
local function body_of(hunk)
  local body = {}
  for line in hunk.text:gmatch("(.-)\n") do
    if not line:match("^@@") and line:sub(1, 1) ~= "\\" then
      body[#body + 1] = line
    end
  end
  return body
end

local function file_stats(file)
  local additions, deletions = 0, 0
  for _, h in ipairs(file.hunks or {}) do
    additions = additions + (h.additions or 0)
    deletions = deletions + (h.deletions or 0)
  end
  return additions, deletions
end

local function separator(file)
  if file.binary then
    return ("── %s   %s   binary"):format(file.path, file.status or "M")
  end
  local additions, deletions = file_stats(file)
  return ("── %s   %s   +%d -%d")
    :format(file.path, file.status or "M", additions, deletions)
end

--- Pair a hunk body into aligned original/modified rows, carrying the real
--- line number each half addresses. A context line emits on both sides; a run
--- of deletions and the addition run that follows it emit
--- max(#deletions, #additions) rows, paired by index, with a filler row on the
--- shorter side.
---
--- One row is `{ left, right, old_line, new_line, changed, run }`. `left`/`right`
--- are nil exactly on a filler — the row exists only to keep the two panes the
--- same height, and addresses nothing, so `old_line`/`new_line` is nil there
--- too. `changed` says the row came from a deletion/addition run rather than
--- from context, which content alone cannot tell: an ordinary 1-for-1
--- replacement has real text on both sides. `run` is the index of the changed
--- run the row belongs to, so the caller can collect character-refinement runs.
---
--- Deliberately NOT written with `x and y or z` anywhere: `left` is legitimately
--- an empty string for a blank source line, and this codebase has already paid
--- three times for that idiom collapsing a falsy-but-real middle term.
local function pair_body(body, old_start, new_start, runs, file_path)
  local rows = {}
  local minus, plus = {}, {}
  local old_line, new_line = old_start, new_start
  local function flush()
    if #minus == 0 and #plus == 0 then
      return
    end
    local run = {
      file = file_path,
      minus = {}, plus = {},
      minus_rows = {}, plus_rows = {},
    }
    runs[#runs + 1] = run
    local run_i = #runs
    for i = 1, math.max(#minus, #plus) do
      local m, p = minus[i], plus[i]
      local row = { changed = true, run = run_i, run_index = i }
      if m then
        row.left, row.old_line = m.text, m.line
        run.minus[#run.minus + 1] = m.text
      end
      if p then
        row.right, row.new_line = p.text, p.line
        run.plus[#run.plus + 1] = p.text
      end
      rows[#rows + 1] = row
    end
    minus, plus = {}, {}
  end
  for _, line in ipairs(body) do
    local kind = line:sub(1, 1)
    if kind == "-" then
      minus[#minus + 1] = { text = line:sub(2), line = old_line }
      old_line = old_line + 1
    elseif kind == "+" then
      plus[#plus + 1] = { text = line:sub(2), line = new_line }
      new_line = new_line + 1
    else
      flush()
      rows[#rows + 1] = {
        left = line:sub(2), right = line:sub(2),
        old_line = old_line, new_line = new_line, changed = false,
      }
      old_line = old_line + 1
      new_line = new_line + 1
    end
  end
  flush()
  return rows
end

-- ------------------------------------------------------------- the row walk --

--- Every row of one file, over its FULL content, with hunks marking the
--- changed stretches. Returns the rows plus `hunk_spans`, the row index range
--- each hunk occupies (relative to the returned array, 1-based inclusive).
---
--- Hunk ranges are END-EXCLUSIVE and a zero-length side is a zero-width anchor
--- at `start + 1`, so a pure addition never advances `o` and a pure deletion
--- never advances `m` — both fall out of the arithmetic with no special case.
local function file_rows(file, runs)
  local orig = file.original or {}
  local mod = file.modified or {}
  local rows, spans = {}, {}
  local o, m = 1, 1

  local function unchanged()
    rows[#rows + 1] = {
      left = orig[o], right = mod[m],
      old_line = o, new_line = m, changed = false,
    }
    o, m = o + 1, m + 1
  end

  for _, h in ipairs(file.hunks or {}) do
    while o < h.original.start_line and o <= #orig do
      unchanged()
    end
    local first = #rows + 1
    for _, row in ipairs(pair_body(body_of(h), o, m, runs, file.path)) do
      rows[#rows + 1] = row
    end
    spans[h.id] = { first, #rows }
    o = h.original.end_line
    m = h.modified.end_line
  end

  while o <= #orig do
    unchanged()
  end
  -- A file whose modified side is longer than any hunk accounted for (which
  -- cannot happen for well-formed diffs, but a truncated `git show` would do
  -- it) still renders its tail rather than silently dropping lines.
  while m <= #mod do
    rows[#rows + 1] = { right = mod[m], new_line = m, changed = false }
    m = m + 1
  end

  return rows, spans
end

--- Rows for a file whose content could not be fetched: the hunk bodies alone,
--- exactly as the old preview rendered them. Folds are disabled for such a
--- file by the caller, because the rows are not the whole file.
local function fallback_rows(file, runs)
  local rows, spans = {}, {}
  for _, h in ipairs(file.hunks or {}) do
    local first = #rows + 1
    local o = (h.original or {}).start_line or 1
    local m = (h.modified or {}).start_line or 1
    for _, row in ipairs(pair_body(body_of(h), o, m, runs, file.path)) do
      rows[#rows + 1] = row
    end
    spans[h.id] = { first, #rows }
  end
  return rows, spans
end

-- ------------------------------------------------------------------- panes --

local function new_pane()
  local pane = { lines = {}, spans = {}, map = {} }
  function pane.add(text, group, target)
    pane.lines[#pane.lines + 1] = text
    if group then
      pane.spans[#pane.spans + 1] =
        { line = #pane.lines, col_start = 0, col_end = WHOLE_LINE, hl = group }
    end
    if target then
      pane.map[#pane.lines] = target
    end
    return #pane.lines
  end
  return pane
end

-- --------------------------------------------------------------- public API --

--- The row of `pane` the cursor at `row` addresses, or nil when that row
--- displays no line of any file (separator, filler, binary marker).
--- @return table|nil { file, line, side }
function M.target_at(pane, row)
  if not (pane and pane.map and row) then
    return nil
  end
  return pane.map[row]
end

--- The rows of `pane` that comment `c` covers, ascending.
---
--- The INVERSE of `pane.map`, derived by scanning it rather than accumulated
--- alongside it: a second, independently-built index is exactly how the
--- renderer and the store came to disagree about a drifted comment once
--- already. Whatever `target_at` answers for a row is what this answers with.
---
--- File-level (line 0) and intent comments address no line and yield none.
--- @return integer[] rows
function M.rows_for(pane, c)
  local out = {}
  if not (pane and pane.map and c and c.file) then
    return out
  end
  local first = c.line
  if not first or first == 0 or c.intent_title then
    return out
  end
  local last = c.line_end or first
  local side = c.side or "new"
  -- Numeric loop, NOT ipairs: `map` is sparse by construction and ipairs would
  -- stop at the first row that addresses nothing.
  for row = 1, #pane.lines do
    local t = pane.map[row]
    if t and t.file == c.file and t.side == side and t.line >= first and t.line <= last then
      out[#out + 1] = row
    end
  end
  return out
end

--- Build a render plan.
--- @param files table[] file entries carrying full content and ALL their hunks
--- @param visible table set of hunk ids to leave unfolded
--- @param layout string "inline" | "side-by-side"
--- @param opts table|nil { context = integer, line_budget = integer }
--- @return table plan
function M.build(files, visible, layout, opts)
  opts = opts or {}
  visible = visible or {}
  local original, modified = new_pane(), new_pane()
  local runs, meta = {}, {}

  for _, file in ipairs(files or {}) do
    local sep = separator(file)
    original.add(sep, "IntentDiffFileSeparator")
    modified.add(sep, "IntentDiffFileSeparator")

    if file.binary then
      meta[#meta + 1] = { path = file.path, filetype = file.filetype,
                          status = file.status, binary = true, fallback = false }
    else
      local has_content = file.original ~= nil and file.modified ~= nil
      local rows
      if has_content then
        rows = file_rows(file, runs)
      else
        rows = fallback_rows(file, runs)
      end
      meta[#meta + 1] = { path = file.path, filetype = file.filetype,
                          status = file.status, binary = false,
                          fallback = not has_content }

      for _, row in ipairs(rows) do
        local left_hl, right_hl
        if row.changed then
          if row.left == nil then
            left_hl = "IntentDiffFiller"
          else
            left_hl = "IntentDiffDelete"
          end
          if row.right == nil then
            right_hl = "IntentDiffFiller"
          else
            right_hl = "IntentDiffAdd"
          end
        end
        local left_target, right_target
        if row.old_line then
          left_target = { file = file.path, line = row.old_line, side = "old" }
        end
        if row.new_line then
          right_target = { file = file.path, line = row.new_line, side = "new" }
        end
        local lrow = original.add(row.left or "", left_hl, left_target)
        local rrow = modified.add(row.right or "", right_hl, right_target)
        -- Record where each run's lines landed, for character refinement.
        if row.run then
          local run = runs[row.run]
          if row.left ~= nil then
            run.minus_rows[#run.minus_rows + 1] = lrow
          end
          if row.right ~= nil then
            run.plus_rows[#run.plus_rows + 1] = rrow
          end
        end
      end
    end
  end

  return {
    layout = "side-by-side",
    original = original,
    modified = modified,
    files = meta,
    runs = runs,
    folds = {},
  }
end

return M
```

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_plan_spec.lua')" -c qa`
Expected: PASS, 17 successes.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/render/plan.lua tests/render_plan_spec.lua
git commit -m "$(cat <<'EOF'
feat(render): build side-by-side panes over full file content

The pure half of the unified renderer. Walks each file's complete content
with hunks marking the changed stretches, rather than emitting hunk bodies
alone, so one plan serves a single-file view and a whole-intent view alike.

Both panes are padded to equal line counts with real filler rows, which is
what will let a fold range be identical on both sides.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `render/plan.lua` gains the inline layout

In inline layout one pane holds everything, so a row's side comes from its kind: a deletion row shows a line of the original file, addition and context rows show the modified one. Context consumes a line on both sides and is addressed as new — the same rule the old preview followed (`preview.lua:107-110`).

**Files:**
- Modify: `lua/intentdiff/render/plan.lua` (`M.build`)
- Test: `tests/render_plan_spec.lua`

**Interfaces:**
- Consumes: `file_rows`, `pair_body`, `new_pane` from Task 3
- Produces: `plan.layout == "inline"` with `plan.original == nil` and `plan.modified` holding every row

- [ ] **Step 1: Write the failing test**

Append to `tests/render_plan_spec.lua`:

```lua
describe("plan.build inline", function()
  it("puts every row in one pane and leaves the original pane empty", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    assert.equals("inline", p.layout)
    assert.is_nil(p.original)
    -- separator + 2 context + delete + add + 2 context
    assert.equals(7, #p.modified.lines)
  end)

  it("shows the deletion and the addition as separate rows", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    assert.equals("three", p.modified.lines[4])
    assert.equals("THREE", p.modified.lines[5])
  end)

  it("addresses a deletion row to the old side and everything else to new", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    assert.same({ file = "a.lua", line = 2, side = "new" }, p.modified.map[3])
    assert.same({ file = "a.lua", line = 3, side = "old" }, p.modified.map[4])
    assert.same({ file = "a.lua", line = 3, side = "new" }, p.modified.map[5])
    assert.same({ file = "a.lua", line = 4, side = "new" }, p.modified.map[6])
  end)

  it("emits no filler rows at all", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "one", "two" },
      modified = { "one", "TWO", "EXTRA" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -2,1 +2,2 @@",
        text = "@@ -2,1 +2,2 @@\n-two\n+TWO\n+EXTRA\n",
        original = { start_line = 2, end_line = 3 },
        modified = { start_line = 2, end_line = 4 },
        additions = 2, deletions = 1,
      } },
    }
    local p = plan.build({ file }, {}, "inline")
    for _, s in ipairs(p.modified.spans) do
      assert.not_equals("IntentDiffFiller", s.hl)
    end
    -- separator, context "one", "-two", "+TWO", "+EXTRA"
    assert.equals(5, #p.modified.lines)
  end)

  it("records run rows in inline coordinates", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    assert.equals(1, #p.runs)
    assert.same({ 4 }, p.runs[1].minus_rows)
    assert.same({ 5 }, p.runs[1].plus_rows)
  end)

  it("is still the exact inverse of target_at", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    for row = 1, #p.modified.lines do
      local t = plan.target_at(p.modified, row)
      if t then
        local rows = plan.rows_for(p.modified, { file = t.file, line = t.line, side = t.side })
        assert.truthy(vim.tbl_contains(rows, row))
      end
    end
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_plan_spec.lua')" -c qa`
Expected: FAIL — `p.layout` is `"side-by-side"` and `p.original` is not nil.

- [ ] **Step 3: Implement**

In `lua/intentdiff/render/plan.lua`, extract the per-file row emission so both layouts share the walk, then branch. Replace the body of `M.build` with:

```lua
function M.build(files, visible, layout, opts)
  opts = opts or {}
  visible = visible or {}
  local inline = layout == "inline"
  local original = inline and nil or new_pane()
  local modified = new_pane()
  local runs, meta = {}, {}

  for _, file in ipairs(files or {}) do
    local sep = separator(file)
    if original then
      original.add(sep, "IntentDiffFileSeparator")
    end
    modified.add(sep, "IntentDiffFileSeparator")

    if file.binary then
      meta[#meta + 1] = { path = file.path, filetype = file.filetype,
                          status = file.status, binary = true, fallback = false }
    else
      local has_content = file.original ~= nil and file.modified ~= nil
      local rows
      if has_content then
        rows = file_rows(file, runs)
      else
        rows = fallback_rows(file, runs)
      end
      meta[#meta + 1] = { path = file.path, filetype = file.filetype,
                          status = file.status, binary = false,
                          fallback = not has_content }

      for _, row in ipairs(rows) do
        if inline then
          -- One buffer, so a row's SIDE comes from its kind. A filler row has
          -- no content on either side and simply is not emitted here: inline
          -- has no second pane to stay level with.
          if row.left ~= nil and row.right ~= nil and not row.changed then
            local r = modified.add(row.right, nil,
              { file = file.path, line = row.new_line, side = "new" })
            _ = r
          else
            if row.left ~= nil then
              local r = modified.add(row.left, "IntentDiffDelete",
                { file = file.path, line = row.old_line, side = "old" })
              if row.run then
                local run = runs[row.run]
                run.minus_rows[#run.minus_rows + 1] = r
              end
            end
            if row.right ~= nil then
              local r = modified.add(row.right, "IntentDiffAdd",
                { file = file.path, line = row.new_line, side = "new" })
              if row.run then
                local run = runs[row.run]
                run.plus_rows[#run.plus_rows + 1] = r
              end
            end
          end
        else
          local left_hl, right_hl
          if row.changed then
            if row.left == nil then
              left_hl = "IntentDiffFiller"
            else
              left_hl = "IntentDiffDelete"
            end
            if row.right == nil then
              right_hl = "IntentDiffFiller"
            else
              right_hl = "IntentDiffAdd"
            end
          end
          local left_target, right_target
          if row.old_line then
            left_target = { file = file.path, line = row.old_line, side = "old" }
          end
          if row.new_line then
            right_target = { file = file.path, line = row.new_line, side = "new" }
          end
          local lrow = original.add(row.left or "", left_hl, left_target)
          local rrow = modified.add(row.right or "", right_hl, right_target)
          if row.run then
            local run = runs[row.run]
            if row.left ~= nil then
              run.minus_rows[#run.minus_rows + 1] = lrow
            end
            if row.right ~= nil then
              run.plus_rows[#run.plus_rows + 1] = rrow
            end
          end
        end
      end
    end
  end

  return {
    layout = inline and "inline" or "side-by-side",
    original = original,
    modified = modified,
    files = meta,
    runs = runs,
    folds = {},
  }
end
```

Note the ordering inside a changed run in inline layout: **all** deletions of the run come out before its additions, because `pair_body` returns them paired by index. The loop above emits `row.left` then `row.right` for each paired row, which interleaves them. That is deliberate and matches how the old preview read: `-old` immediately above `+new` for a 1-for-1 replacement.

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_plan_spec.lua')" -c qa`
Expected: PASS, 23 successes.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/render/plan.lua tests/render_plan_spec.lua
git commit -m "$(cat <<'EOF'
feat(render): add the inline layout to the plan builder

One pane holds everything, so a row's side comes from its kind: deletions
address the original file, additions and context the modified one. No filler
rows — there is no second pane to stay level with.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Folds, the line budget, and the hunks-only fallback

**Files:**
- Modify: `lua/intentdiff/render/plan.lua` (`M.build`, `file_rows` callers)
- Test: `tests/render_plan_spec.lua`

**Interfaces:**
- Consumes: `hunk_spans` returned by `file_rows`/`fallback_rows` (Task 3)
- Produces: `plan.folds` — array of `{first_row, last_row}` inclusive ranges, valid for **both** panes; `plan.files[i].fallback` true when a file rendered hunks-only

Rules:
- A row is *visible* when it lies inside a visible hunk's span, or within `opts.context` rows of one. Default context 3.
- Everything else folds. Fold ranges are maximal runs of non-visible rows.
- A file in `fallback` contributes **no** fold ranges: its rows are not the whole file, so folding them would hide real content with nothing to unfold to.
- A file exceeding `opts.line_budget` (default 20000) renders hunks-only, is marked `fallback = true`, and says so in its separator.
- Separator rows are never folded.

- [ ] **Step 1: Write the failing test**

Append to `tests/render_plan_spec.lua`:

```lua
--- A 20-line file with two one-line hunks, at lines 5 and 15.
local function two_hunk_file()
  local orig, mod = {}, {}
  for i = 1, 20 do
    orig[i] = "line" .. i
    mod[i] = "line" .. i
  end
  mod[5] = "CHANGED5"
  mod[15] = "CHANGED15"
  return {
    path = "a.lua", status = "M", filetype = "lua", binary = false,
    original = orig, modified = mod,
    hunks = {
      { id = "a.lua:1", file = "a.lua", header = "@@ -5,1 +5,1 @@",
        text = "@@ -5,1 +5,1 @@\n-line5\n+CHANGED5\n",
        original = { start_line = 5, end_line = 6 },
        modified = { start_line = 5, end_line = 6 },
        additions = 1, deletions = 1 },
      { id = "a.lua:2", file = "a.lua", header = "@@ -15,1 +15,1 @@",
        text = "@@ -15,1 +15,1 @@\n-line15\n+CHANGED15\n",
        original = { start_line = 15, end_line = 16 },
        modified = { start_line = 15, end_line = 16 },
        additions = 1, deletions = 1 },
    },
  }
end

local function is_folded(p, row)
  for _, range in ipairs(p.folds) do
    if row >= range[1] and row <= range[2] then return true end
  end
  return false
end

describe("plan.build folds", function()
  it("leaves a visible hunk and its context unfolded", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    -- row 1 is the separator; file line N is row N+1
    assert.is_false(is_folded(p, 6), "the changed line itself")
    assert.is_false(is_folded(p, 4), "2 lines of context above")
    assert.is_false(is_folded(p, 8), "2 lines of context below")
  end)

  it("folds everything outside the visible hunk", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    assert.is_true(is_folded(p, 2), "far above the hunk")
    assert.is_true(is_folded(p, 16), "the other hunk is not visible")
    assert.is_true(is_folded(p, 21), "far below")
  end)

  it("never folds a separator row", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    assert.is_false(is_folded(p, 1))
  end)

  it("keeps both hunks open when both are visible", function()
    local p = plan.build({ two_hunk_file() },
      { ["a.lua:1"] = true, ["a.lua:2"] = true }, "side-by-side", { context = 2 })
    assert.is_false(is_folded(p, 6))
    assert.is_false(is_folded(p, 16))
    assert.is_true(is_folded(p, 10), "the stretch between them still folds")
  end)

  it("folds nothing when no hunk is visible", function()
    local p = plan.build({ two_hunk_file() }, {}, "side-by-side", { context = 2 })
    assert.same({}, p.folds)
  end)

  it("produces fold ranges valid for both panes", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    assert.equals(#p.original.lines, #p.modified.lines)
    for _, range in ipairs(p.folds) do
      assert.is_true(range[2] <= #p.original.lines)
      assert.is_true(range[1] >= 1)
    end
  end)
end)

describe("plan.build fallback", function()
  it("renders hunks only when content is missing and disables its folds", function()
    local file = two_hunk_file()
    file.original, file.modified = nil, nil
    local p = plan.build({ file }, { ["a.lua:1"] = true }, "side-by-side", { context = 2 })
    assert.is_true(p.files[1].fallback)
    assert.same({}, p.folds, "a partial render must not fold")
    -- separator + the two hunks' rows only, not 20 lines
    assert.is_true(#p.modified.lines < 10)
  end)

  it("falls back and says so when a file exceeds the line budget", function()
    local file = two_hunk_file()
    local p = plan.build({ file }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2, line_budget = 5 })
    assert.is_true(p.files[1].fallback)
    assert.truthy(p.modified.lines[1]:find("budget", 1, true),
      "the separator states why it fell back")
    assert.same({}, p.folds)
  end)

  it("does not fall back when the file fits the budget", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2, line_budget = 20000 })
    assert.is_false(p.files[1].fallback)
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_plan_spec.lua')" -c qa`
Expected: FAIL — `p.folds` is always `{}`.

- [ ] **Step 3: Implement**

In `lua/intentdiff/render/plan.lua`:

Add the budget check and a fold-tracking structure. Change `separator` to take a `fallback_reason`:

```lua
local function separator(file, fallback_reason)
  if file.binary then
    return ("── %s   %s   binary"):format(file.path, file.status or "M")
  end
  local additions, deletions = file_stats(file)
  local base = ("── %s   %s   +%d -%d")
    :format(file.path, file.status or "M", additions, deletions)
  if fallback_reason then
    return base .. "   (" .. fallback_reason .. ")"
  end
  return base
end
```

Inside `M.build`, replace the `has_content`/`rows` selection with:

```lua
      local budget = opts.line_budget or 20000
      local has_content = file.original ~= nil and file.modified ~= nil
      local over_budget = has_content
        and (#file.original > budget or #file.modified > budget)
      local fallback_reason
      if not has_content then
        fallback_reason = "content unavailable"
      elseif over_budget then
        fallback_reason = "over line budget"
      end

      local rows, hunk_spans
      if fallback_reason then
        rows, hunk_spans = fallback_rows(file, runs)
      else
        rows, hunk_spans = file_rows(file, runs)
      end
```

and emit the separator using it (move the separator `add` calls to after this block so the reason is known, keeping the binary branch's own separator where it is).

Track, per emitted row, whether it is visible. Before the row loop:

```lua
      local first_row = #modified.lines + 1  -- first content row of this file
```

After the row loop, if `not fallback_reason`, mark visible rows and collect folds. Add these helpers near the top of the file:

```lua
--- Rows to keep open: every visible hunk's span, grown by `context` on each
--- side. `spans` is hunk id -> {first, last} in file-relative row indices;
--- `offset` converts those to pane rows.
local function visible_rows(spans, visible, context, offset, keep)
  for id, span in pairs(spans) do
    if visible[id] then
      local from = math.max(1, span[1] - context)
      local to = span[2] + context
      for r = from, to do
        keep[r + offset] = true
      end
    end
  end
end

--- Maximal runs of rows in `1..total` that are neither kept nor protected.
local function fold_ranges(total, keep, protected)
  local ranges, start = {}, nil
  for row = 1, total do
    local hidden = not keep[row] and not protected[row]
    if hidden and not start then
      start = row
    elseif not hidden and start then
      ranges[#ranges + 1] = { start, row - 1 }
      start = nil
    end
  end
  if start then
    ranges[#ranges + 1] = { start, total }
  end
  return ranges
end
```

In `M.build`, accumulate `keep`, `protected` (separator rows) and an `any_visible` flag across files, then at the end:

```lua
  local folds = {}
  if any_visible and not any_fallback then
    folds = fold_ranges(#modified.lines, keep, protected)
  end
```

`any_fallback` is true when any file fell back — a plan mixing full and partial files must not fold, because a fold range spans the whole pane.

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_plan_spec.lua')" -c qa`
Expected: PASS, 32 successes.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/render/plan.lua tests/render_plan_spec.lua
git commit -m "$(cat <<'EOF'
feat(render): fold to the visible hunks, with a stated line budget

Fold ranges are computed once and are valid for both panes, because equal
line counts mean identical row ranges. A file that fell back to hunks-only
contributes no folds: its rows are not the whole file, so folding them would
hide content with nothing to unfold to.

The line budget replaces preview.max_lines and says why it fired, where
max_lines truncated silently.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Highlight groups for the unified renderer

**Files:**
- Modify: `lua/intentdiff/highlight.lua`
- Test: `tests/highlight_spec.lua`

**Interfaces:**
- Consumes: nothing
- Produces: `IntentDiffFileSeparator`, `IntentDiffAddChar`, `IntentDiffDeleteChar`, `IntentDiffSignAdd`, `IntentDiffSignDelete`. `IntentDiffPreviewFile` and `IntentDiffPreviewHunk` are removed.

- [ ] **Step 1: Write the failing test**

Append to `tests/highlight_spec.lua`:

```lua
describe("highlight groups for the unified renderer", function()
  it("defines the separator, character and sign groups", function()
    require("intentdiff.highlight").setup()
    for _, name in ipairs({
      "IntentDiffFileSeparator",
      "IntentDiffAddChar", "IntentDiffDeleteChar",
      "IntentDiffSignAdd", "IntentDiffSignDelete",
    }) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      assert.truthy(hl and next(hl) ~= nil, name .. " is not defined")
    end
  end)

  it("no longer defines the preview-only groups", function()
    require("intentdiff.highlight").setup()
    for _, name in ipairs({ "IntentDiffPreviewFile", "IntentDiffPreviewHunk" }) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      assert.is_true(hl == nil or next(hl) == nil, name .. " should be gone")
    end
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/highlight_spec.lua')" -c qa`
Expected: FAIL — `IntentDiffFileSeparator` is not defined.

- [ ] **Step 3: Implement**

In `lua/intentdiff/highlight.lua`, in the defaults table: rename `IntentDiffPreviewFile` to `IntentDiffFileSeparator`, delete `IntentDiffPreviewHunk`, and add:

```lua
  IntentDiffAddChar = "DiffText",
  IntentDiffDeleteChar = "DiffText",
  IntentDiffSignAdd = "Added",
  IntentDiffSignDelete = "Removed",
```

`DiffText` is Neovim's built-in group for the changed part of a changed line, so both character groups inherit a colourscheme-appropriate emphasis without hardcoding colours.

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/highlight_spec.lua')" -c qa`
Expected: PASS.

- [ ] **Step 5: Fix the remaining references**

Run: `grep -rn "IntentDiffPreviewFile\|IntentDiffPreviewHunk" lua/ tests/`
Replace each `IntentDiffPreviewFile` with `IntentDiffFileSeparator`. `IntentDiffPreviewHunk` references live in `preview.lua` (deleted in Task 10) and its specs; leave those alone — Task 10 and 13 remove them.

- [ ] **Step 6: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`.

- [ ] **Step 7: Commit**

```bash
git add lua/intentdiff/highlight.lua tests/highlight_spec.lua
git commit -m "$(cat <<'EOF'
feat(highlight): groups for separators, character ranges and signs

IntentDiffPreviewFile becomes IntentDiffFileSeparator now that "preview"
stops being a concept, IntentDiffPreviewHunk goes with the @@ header rows,
and character/sign groups arrive for the unified renderer.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `render/paint.lua` puts a plan into buffers

**Files:**
- Create: `lua/intentdiff/render/paint.lua`
- Test: `tests/render_paint_spec.lua`

**Interfaces:**
- Consumes: `plan` (Tasks 3–5), highlight groups (Task 6)
- Produces:
  - `paint.render(plan, wins) -> table painted` where `wins = { original = win|nil, modified = win }` and `painted = { bufs = { [side] = bufnr }, plan = plan }`
  - `paint.retire(bufs)` — deletes a previous generation's buffers one tick later
  - `paint.ns` — the extmark namespace, exported for tests and for `marks.lua` to avoid

Buffers are `nofile`, `bufhidden = "hide"` (never `"wipe"`: a window may still be swapping off them), `modifiable = false` after the lines are set.

- [ ] **Step 1: Write the failing test**

Create `tests/render_paint_spec.lua`:

```lua
local plan = require("intentdiff.render.plan")
local paint = require("intentdiff.render.paint")

local function modified_file()
  return {
    path = "a.lua", status = "M", filetype = "lua", binary = false,
    original = { "one", "two", "three" },
    modified = { "one", "TWO", "three" },
    hunks = { {
      id = "a.lua:1", file = "a.lua", header = "@@ -2,1 +2,1 @@",
      text = "@@ -2,1 +2,1 @@\n-two\n+TWO\n",
      original = { start_line = 2, end_line = 3 },
      modified = { start_line = 2, end_line = 3 },
      additions = 1, deletions = 1,
    } },
  }
end

--- Two windows in a scratch tab.
local function two_wins()
  vim.cmd("tabnew")
  local a = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit")
  local b = vim.api.nvim_get_current_win()
  return { original = a, modified = b }, vim.api.nvim_get_current_tabpage()
end

describe("paint.render", function()
  local wins, tab
  before_each(function() wins, tab = two_wins() end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(tab) then
      vim.cmd("tabclose!")
    end
  end)

  it("puts the plan's lines into both panes", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local painted = paint.render(p, wins)
    local orig = vim.api.nvim_buf_get_lines(painted.bufs.original, 0, -1, false)
    local mod = vim.api.nvim_buf_get_lines(painted.bufs.modified, 0, -1, false)
    assert.same(p.original.lines, orig)
    assert.same(p.modified.lines, mod)
  end)

  it("makes the buffers read-only scratch buffers", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local painted = paint.render(p, wins)
    for _, buf in pairs(painted.bufs) do
      assert.equals("nofile", vim.bo[buf].buftype)
      assert.is_false(vim.bo[buf].modifiable)
      assert.equals("hide", vim.bo[buf].bufhidden)
    end
  end)

  it("displays the buffers in the given windows", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local painted = paint.render(p, wins)
    assert.equals(painted.bufs.original, vim.api.nvim_win_get_buf(wins.original))
    assert.equals(painted.bufs.modified, vim.api.nvim_win_get_buf(wins.modified))
  end)

  it("places a line highlight for every span", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local painted = paint.render(p, wins)
    local marks = vim.api.nvim_buf_get_extmarks(
      painted.bufs.modified, paint.ns, 0, -1, { details = true })
    local found = false
    for _, m in ipairs(marks) do
      if m[4].line_hl_group == "IntentDiffAdd" and m[2] == 2 then
        found = true
      end
    end
    assert.is_true(found, "the added line has no IntentDiffAdd line highlight")
  end)

  it("binds the two panes together for scrolling", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    paint.render(p, wins)
    assert.is_true(vim.wo[wins.original].scrollbind)
    assert.is_true(vim.wo[wins.modified].scrollbind)
    assert.is_true(vim.wo[wins.original].cursorbind)
  end)

  it("uses one window and no scrollbind in inline layout", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    local painted = paint.render(p, { modified = wins.modified })
    assert.is_nil(painted.bufs.original)
    assert.is_false(vim.wo[wins.modified].scrollbind)
  end)

  it("closes the plan's fold ranges", function()
    local orig, mod = {}, {}
    for i = 1, 20 do orig[i] = "line" .. i; mod[i] = "line" .. i end
    mod[15] = "CHANGED"
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = orig, modified = mod,
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -15,1 +15,1 @@",
        text = "@@ -15,1 +15,1 @@\n-line15\n+CHANGED\n",
        original = { start_line = 15, end_line = 16 },
        modified = { start_line = 15, end_line = 16 },
        additions = 1, deletions = 1,
      } },
    }
    local p = plan.build({ file }, { ["a.lua:1"] = true }, "side-by-side", { context = 2 })
    paint.render(p, wins)
    vim.api.nvim_win_call(wins.modified, function()
      -- Row 3 is far above the hunk and must be inside a closed fold.
      assert.is_true(vim.fn.foldclosed(3) > 0, "row 3 should be folded away")
      -- The changed row itself must be visible.
      assert.equals(-1, vim.fn.foldclosed(16))
    end)
  end)

  it("retires a previous generation's buffers", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local first = paint.render(p, wins)
    local old = first.bufs.modified
    paint.render(p, wins)
    paint.retire(first.bufs)
    vim.wait(50, function() return not vim.api.nvim_buf_is_valid(old) end)
    assert.is_false(vim.api.nvim_buf_is_valid(old))
  end)

  it("never deletes a buffer still displayed in a window", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local painted = paint.render(p, wins)
    paint.retire(painted.bufs)
    vim.wait(50)
    assert.is_true(vim.api.nvim_buf_is_valid(painted.bufs.modified),
      "retiring a displayed buffer would close its window and could close the tab")
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_paint_spec.lua')" -c qa`
Expected: FAIL — module `intentdiff.render.paint` not found.

- [ ] **Step 3: Implement**

Create `lua/intentdiff/render/paint.lua`:

```lua
-- Puts a render plan into buffers. The impure half of the renderer: plan.lua
-- decides what the panes contain, this decides nothing and only draws it.
local M = {}

M.ns = vim.api.nvim_create_namespace("intentdiff_render")

--- Per-window visible-row sets, read by M.foldexpr.
local folded_by_win = {}

--- Fold expression: 1 inside a fold range, 0 outside. Registered per window by
--- M.render. Reads a per-window set rather than the plan so a recycled window
--- id can never answer with a stale plan's ranges.
function M.foldexpr()
  local win = vim.api.nvim_get_current_win()
  local set = folded_by_win[win]
  if not set then
    return "0"
  end
  return set[vim.v.lnum] and "1" or "0"
end

--- A fresh scratch buffer holding `pane`.
---
--- bufhidden is deliberately "hide", not "wipe": a window may still be being
--- swapped off this buffer when the next generation arrives, and "wipe" would
--- delete it mid-swap, leaving a caller reading an already-invalid buffer id.
--- M.retire cleans up afterwards instead.
local function pane_buf(pane)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, pane.lines)
  vim.bo[buf].modifiable = false
  for _, s in ipairs(pane.spans) do
    if s.col_end == -1 then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, s.line - 1, 0,
        { line_hl_group = s.hl })
    else
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, s.line - 1, s.col_start,
        { end_col = s.col_end, hl_group = s.hl })
    end
  end
  return buf
end

--- True when `buf` is the current buffer of any window, in any tabpage.
local function buf_is_displayed(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      return true
    end
  end
  return false
end

--- Delete a previous generation's buffers one event-loop tick from now, once
--- whatever replaced them in their windows has settled.
---
--- Never deletes a buffer still displayed: nvim_buf_delete with force closes
--- every window showing it, and takes the tabpage with it if that was the last
--- window — exactly the window-closing this whole mechanism exists to avoid.
function M.retire(bufs)
  if not bufs then
    return
  end
  vim.schedule(function()
    for _, buf in pairs(bufs) do
      if buf and vim.api.nvim_buf_is_valid(buf) and not buf_is_displayed(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)
end

--- Apply `plan.folds` to `win`, or clear folding when there is nothing to fold.
local function apply_folds(win, plan)
  if #plan.folds == 0 then
    folded_by_win[win] = nil
    vim.wo[win].foldenable = false
    return
  end
  local set = {}
  for _, range in ipairs(plan.folds) do
    for row = range[1], range[2] do
      set[row] = true
    end
  end
  folded_by_win[win] = set
  vim.wo[win].foldmethod = "expr"
  vim.wo[win].foldexpr = "v:lua.require'intentdiff.render.paint'.foldexpr()"
  vim.wo[win].foldlevel = 0
  vim.wo[win].foldminlines = 0
  vim.wo[win].foldenable = true
end

--- Render `plan` into `wins`.
--- @param wins table { original = win|nil, modified = win }
--- @return table { bufs = { original = bufnr|nil, modified = bufnr }, plan = plan }
function M.render(plan, wins)
  -- Drop entries for windows that no longer exist, so foldexpr never answers
  -- for a recycled window id.
  for win in pairs(folded_by_win) do
    if not vim.api.nvim_win_is_valid(win) then
      folded_by_win[win] = nil
    end
  end

  local bufs = {}
  local two_pane = plan.original ~= nil
    and wins.original ~= nil
    and wins.original ~= wins.modified
    and vim.api.nvim_win_is_valid(wins.original)

  if two_pane then
    bufs.original = pane_buf(plan.original)
    vim.api.nvim_win_set_buf(wins.original, bufs.original)
  end
  bufs.modified = pane_buf(plan.modified)
  vim.api.nvim_win_set_buf(wins.modified, bufs.modified)

  for side, win in pairs({ original = wins.original, modified = wins.modified }) do
    if (side ~= "original" or two_pane) and win and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].scrollbind = two_pane
      vim.wo[win].cursorbind = two_pane
      apply_folds(win, plan)
    end
  end

  if two_pane then
    vim.api.nvim_win_call(wins.modified, function()
      vim.cmd("syncbind")
    end)
  end

  return { bufs = bufs, plan = plan }
end

return M
```

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_paint_spec.lua')" -c qa`
Expected: PASS, 9 successes.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/render/paint.lua tests/render_paint_spec.lua
git commit -m "$(cat <<'EOF'
feat(render): paint a plan into scratch buffers with folds and scrollbind

The impure half: plan.lua decides what the panes contain, paint.lua only
draws it. Equal line counts mean one fold set serves both windows and plain
scrollbind holds them together.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Syntax highlighting, per `(file, side)`

`compute_syntax_highlights` parses its input as a single document, so it must only see coherent content. A pane row range is **not** coherent: in inline layout the rows interleave deletion lines (original file) with addition and context lines (modified file). So syntax is computed per `(file, side)` over full content and looked up per row through `map`.

**Files:**
- Modify: `lua/intentdiff/render/paint.lua`
- Test: `tests/render_paint_spec.lua`

**Interfaces:**
- Consumes: `codediff.ui.inline.compute_syntax_highlights(lines, filetype)`, returning `{ [1-based line] = { {start_col, end_col, hl_group}, ... } }` with `start_col` 1-based inclusive and `end_col` exclusive
- Produces: `paint.render` additionally places syntax extmarks. New parameter `content` on `paint.render(plan, wins, content)` where `content = { [path] = { old = string[], new = string[] } }`

- [ ] **Step 1: Write the failing test**

Append to `tests/render_paint_spec.lua`:

```lua
describe("paint syntax highlighting", function()
  local wins, tab
  before_each(function() wins, tab = two_wins() end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(tab) then vim.cmd("tabclose!") end
  end)

  local function syntax_marks(buf, row)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(
        buf, paint.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      if m[4].hl_group and m[4].hl_group:sub(1, 1) == "@" then
        out[#out + 1] = m[4].hl_group
      end
    end
    return out
  end

  it("highlights an unchanged row from the file's own parse", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "local x = 1", "return x" },
      modified = { "local x = 2", "return x" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n-local x = 1\n+local x = 2\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
    local content = { ["a.lua"] = { old = file.original, new = file.modified } }
    local p = plan.build({ file }, {}, "side-by-side")
    local painted = paint.render(p, wins, content)
    -- Row 3 is "return x" on the modified side.
    assert.is_true(#syntax_marks(painted.bufs.modified, 3) > 0,
      "an unchanged row got no treesitter highlights")
  end)

  it("highlights an inline deletion row from the ORIGINAL parse", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "local removed = 1" },
      modified = { "local added = 2" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n-local removed = 1\n+local added = 2\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
    local content = { ["a.lua"] = { old = file.original, new = file.modified } }
    local p = plan.build({ file }, {}, "inline")
    local painted = paint.render(p, { modified = wins.modified }, content)
    -- Row 2 is the deletion (original content), row 3 the addition.
    assert.is_true(#syntax_marks(painted.bufs.modified, 2) > 0,
      "the deletion row must be highlighted from the original file's parse")
    assert.is_true(#syntax_marks(painted.bufs.modified, 3) > 0)
  end)

  it("leaves separators and fillers unhighlighted", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "local x = 1" },
      modified = { "local x = 1", "local y = 2" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,0 +2,1 @@",
        text = "@@ -1,0 +2,1 @@\n+local y = 2\n",
        original = { start_line = 2, end_line = 2 },
        modified = { start_line = 2, end_line = 3 },
        additions = 1, deletions = 0,
      } },
    }
    local content = { ["a.lua"] = { old = file.original, new = file.modified } }
    local p = plan.build({ file }, {}, "side-by-side")
    local painted = paint.render(p, wins, content)
    assert.same({}, syntax_marks(painted.bufs.modified, 1), "separator row")
    assert.same({}, syntax_marks(painted.bufs.original, 3), "filler row")
  end)

  it("survives a filetype with no parser", function()
    local file = {
      path = "a.weird", status = "M", filetype = "definitely_not_a_language",
      binary = false,
      original = { "a" }, modified = { "b" },
      hunks = { {
        id = "a.weird:1", file = "a.weird", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n-a\n+b\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
    local content = { ["a.weird"] = { old = file.original, new = file.modified } }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.has_no.errors(function() paint.render(p, wins, content) end)
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_paint_spec.lua')" -c qa`
Expected: FAIL — no `@`-prefixed extmarks are placed.

- [ ] **Step 3: Implement**

In `lua/intentdiff/render/paint.lua`, add near the top:

```lua
local function cd_inline()
  local ok, mod = pcall(require, "codediff.ui.inline")
  if ok then
    return mod
  end
  return nil
end
```

Add the syntax pass:

```lua
--- Treesitter highlights for every (file, side) the plan draws, keyed
--- syntax[path][side][file_line] = { {start_col, end_col, hl_group}, ... }.
---
--- Computed per (file, side) rather than per pane row range because
--- compute_syntax_highlights parses its input as ONE document: an inline pane
--- interleaves deletion rows (original content) with addition and context rows
--- (modified content), and parsing that mixture would produce garbage at every
--- changed run.
local function compute_syntax(plan, content)
  local inline = cd_inline()
  if not inline or not content then
    return {}
  end
  local syntax = {}
  for _, file in ipairs(plan.files) do
    local per_file = content[file.path]
    if per_file and file.filetype and file.filetype ~= "" then
      syntax[file.path] = {
        old = inline.compute_syntax_highlights(per_file.old or {}, file.filetype),
        new = inline.compute_syntax_highlights(per_file.new or {}, file.filetype),
      }
    end
  end
  return syntax
end

--- Place syntax extmarks on every row of `pane` that addresses a real line.
--- Separators and fillers have no map entry and so get nothing.
local function paint_syntax(buf, pane, syntax)
  for row = 1, #pane.lines do
    local t = pane.map[row]
    if t then
      local per_file = syntax[t.file]
      local per_side = per_file and per_file[t.side]
      local hls = per_side and per_side[t.line]
      if hls then
        local text = pane.lines[row]
        for _, hl in ipairs(hls) do
          -- compute_syntax_highlights returns 1-based inclusive start_col and
          -- an exclusive end_col; extmarks want 0-based start and exclusive end.
          local sc = math.max(0, hl.start_col - 1)
          local ec = math.min(hl.end_col, #text)
          if ec > sc then
            pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row - 1, sc,
              { end_col = ec, hl_group = hl.hl_group, priority = 90 })
          end
        end
      end
    end
  end
end
```

Change `M.render`'s signature to `function M.render(plan, wins, content)` and call `paint_syntax` after each `pane_buf`:

```lua
  local syntax = compute_syntax(plan, content)
  if two_pane then
    bufs.original = pane_buf(plan.original)
    paint_syntax(bufs.original, plan.original, syntax)
    vim.api.nvim_win_set_buf(wins.original, bufs.original)
  end
  bufs.modified = pane_buf(plan.modified)
  paint_syntax(bufs.modified, plan.modified, syntax)
  vim.api.nvim_win_set_buf(wins.modified, bufs.modified)
```

Priority 90 puts syntax **below** the character highlights added in Task 9 (priority 100) and above the line highlights, which use `line_hl_group` and are not priority-ranked against `hl_group` spans.

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_paint_spec.lua')" -c qa`
Expected: PASS, 13 successes.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/render/paint.lua tests/render_paint_spec.lua
git commit -m "$(cat <<'EOF'
feat(render): syntax highlighting computed per (file, side)

compute_syntax_highlights parses its input as one document, so it must only
see coherent content. An inline pane interleaves deletion rows from the
original file with context rows from the modified one, so parsing a row range
would produce garbage at every changed run. Parse each side of each file once
and look the result up per row through the map.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Character-level highlighting inside changed runs

**Files:**
- Modify: `lua/intentdiff/render/paint.lua`
- Test: `tests/render_paint_spec.lua`

**Interfaces:**
- Consumes: `codediff.core.diff.compute_diff(original_lines, modified_lines, opts)` returning `{ changes = { { original = LineRange, modified = LineRange, inner_changes = { { original = CharRange, modified = CharRange } } } } }`, where `CharRange` is `{ start_line, start_col, end_line, end_col }` with **1-based UTF-16 columns**, `end_col` exclusive; and `codediff.ui.inline`'s UTF-16 conversion
- Produces: character extmarks with `IntentDiffAddChar` / `IntentDiffDeleteChar` at priority 100

`utf16_col_to_byte_col` is a **local** function in `codediff/ui/inline.lua`, not exported. Reimplement it in `paint.lua` (five lines, using `vim.str_byteindex`) rather than reaching into codediff's internals — the Global Constraints permit only `compute_syntax_highlights` from that module.

- [ ] **Step 1: Write the failing test**

Append to `tests/render_paint_spec.lua`:

```lua
describe("paint character highlighting", function()
  local wins, tab
  before_each(function() wins, tab = two_wins() end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(tab) then vim.cmd("tabclose!") end
  end)

  local function char_marks(buf, row, group)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(
        buf, paint.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      if m[4].hl_group == group then
        out[#out + 1] = { m[3], m[4].end_col }
      end
    end
    return out
  end

  local function one_word_changed()
    return {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "local alpha = 1" },
      modified = { "local omega = 1" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n-local alpha = 1\n+local omega = 1\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
  end

  it("highlights only the changed word, not the whole line", function()
    local p = plan.build({ one_word_changed() }, {}, "side-by-side")
    local painted = paint.render(p, wins, nil)
    local adds = char_marks(painted.bufs.modified, 2, "IntentDiffAddChar")
    assert.is_true(#adds > 0, "no character highlight on the changed line")
    local start_col, end_col = adds[1][1], adds[1][2]
    assert.is_true(start_col >= 6, "highlight should start at 'omega', not column 0")
    assert.is_true(end_col <= #"local omega = 1")
  end)

  it("highlights the deleted word on the original side", function()
    local p = plan.build({ one_word_changed() }, {}, "side-by-side")
    local painted = paint.render(p, wins, nil)
    assert.is_true(#char_marks(painted.bufs.original, 2, "IntentDiffDeleteChar") > 0)
  end)

  it("places character highlights in inline layout too", function()
    local p = plan.build({ one_word_changed() }, {}, "inline")
    local painted = paint.render(p, { modified = wins.modified }, nil)
    assert.is_true(#char_marks(painted.bufs.modified, 2, "IntentDiffDeleteChar") > 0)
    assert.is_true(#char_marks(painted.bufs.modified, 3, "IntentDiffAddChar") > 0)
  end)

  it("converts UTF-16 columns to byte columns", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { '-- 日本語 alpha' },
      modified = { '-- 日本語 omega' },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n--- 日本語 alpha\n+-- 日本語 omega\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    local painted = paint.render(p, wins, nil)
    local adds = char_marks(painted.bufs.modified, 2, "IntentDiffAddChar")
    assert.is_true(#adds > 0)
    -- "-- 日本語 " is 3 + 9 + 1 = 13 bytes, so a byte-correct highlight starts
    -- at or after 13. A raw UTF-16 column would land near 6.
    assert.is_true(adds[1][1] >= 10,
      "UTF-16 column was not converted to a byte column")
  end)

  it("degrades to no character highlights when the C library is unavailable", function()
    local real = package.loaded["codediff.core.diff"]
    package.loaded["codediff.core.diff"] = nil
    package.preload["codediff.core.diff"] = function() error("unavailable") end
    package.loaded["intentdiff.render.paint"] = nil
    local fresh = require("intentdiff.render.paint")
    local p = plan.build({ one_word_changed() }, {}, "side-by-side")
    assert.has_no.errors(function() fresh.render(p, wins, nil) end)
    package.preload["codediff.core.diff"] = nil
    package.loaded["codediff.core.diff"] = real
    package.loaded["intentdiff.render.paint"] = nil
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_paint_spec.lua')" -c qa`
Expected: FAIL — no `IntentDiffAddChar` extmarks.

- [ ] **Step 3: Implement**

In `lua/intentdiff/render/paint.lua`, add:

```lua
local function cd_diff()
  local ok, mod = pcall(require, "codediff.core.diff")
  if ok then
    return mod
  end
  return nil
end

--- compute_diff returns 1-based UTF-16 columns (VSCode semantics); extmarks
--- want 0-based byte columns. Reimplemented here rather than reaching for
--- codediff's local of the same name, which is not exported.
local function utf16_to_byte(line, col16)
  if not line or col16 <= 1 then
    return 0
  end
  local ok, byte = pcall(vim.str_byteindex, line, col16 - 1, true)
  if ok then
    return math.min(byte, #line)
  end
  return math.min(col16 - 1, #line)
end

--- Character ranges inside each changed run, placed on the rows plan.lua
--- recorded for that run. compute_diff only ever runs INSIDE a region git
--- already decided is changed, so the two algorithms can never disagree about
--- line pairing.
local function paint_chars(bufs, plan)
  local diff = cd_diff()
  if not diff then
    return
  end
  for _, run in ipairs(plan.runs) do
    if #run.minus > 0 and #run.plus > 0 then
      local ok, result = pcall(diff.compute_diff, run.minus, run.plus, {})
      if ok and result and result.changes then
        for _, change in ipairs(result.changes) do
          for _, inner in ipairs(change.inner_changes or {}) do
            -- Original side.
            local o = inner.original
            local orow = run.minus_rows[o.start_line]
            if orow and o.start_line == o.end_line then
              local target_buf, target_pane
              if plan.layout == "inline" then
                target_buf, target_pane = bufs.modified, plan.modified
              else
                target_buf, target_pane = bufs.original, plan.original
              end
              if target_buf and target_pane then
                local text = target_pane.lines[orow]
                local sc = utf16_to_byte(text, o.start_col)
                local ec = utf16_to_byte(text, o.end_col)
                if ec > sc then
                  pcall(vim.api.nvim_buf_set_extmark, target_buf, M.ns, orow - 1, sc,
                    { end_col = ec, hl_group = "IntentDiffDeleteChar", priority = 100 })
                end
              end
            end
            -- Modified side.
            local m = inner.modified
            local mrow = run.plus_rows[m.start_line]
            if mrow and m.start_line == m.end_line and bufs.modified then
              local text = plan.modified.lines[mrow]
              local sc = utf16_to_byte(text, m.start_col)
              local ec = utf16_to_byte(text, m.end_col)
              if ec > sc then
                pcall(vim.api.nvim_buf_set_extmark, bufs.modified, M.ns, mrow - 1, sc,
                  { end_col = ec, hl_group = "IntentDiffAddChar", priority = 100 })
              end
            end
          end
        end
      end
    end
  end
end
```

Call it in `M.render` after both panes exist and before the window options are set:

```lua
  paint_chars(bufs, plan)
```

Multi-line inner changes are skipped (`start_line == end_line` guard): they are rare, and a partial highlight is worse than none.

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/render_paint_spec.lua')" -c qa`
Expected: PASS, 19 successes.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/render/paint.lua tests/render_paint_spec.lua
git commit -m "$(cat <<'EOF'
feat(render): character-level highlighting inside changed runs

libvscode-diff runs only inside a region git already decided is changed, so
the two algorithms can never disagree about line pairing. Degrades to
line-level highlighting when the C library is unavailable.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: `view.lua` renders through the plan — one path for both surfaces

The swap. After this task the plugin is usable end-to-end and worth dogfooding.

**Files:**
- Modify: `lua/intentdiff/view.lua`, `lua/intentdiff/init.lua`, `lua/intentdiff/comments/init.lua`, `lua/intentdiff/comments/marks.lua`
- Delete: `lua/intentdiff/preview.lua`
- Test: `tests/view_spec.lua`, `tests/view_preview_spec.lua`, `tests/comments_preview_spec.lua`

**Interfaces:**
- Consumes: everything from Tasks 2–9
- Produces:
  - `view.show(sess, files, visible, opts)` — the single render entry point
  - `view.current_plan(tabpage) -> plan|nil`
  - `view.pane_for_buf(tabpage, bufnr) -> pane|nil`
  - `view.open_tab()`, `view.close_tab(sess)`, `view.diff_wins(tabpage)` keep their current signatures

`view._preview_active`, `_preview_sess`, `_preview_bufs`, `_preview_maps` are all deleted and replaced by one `view._painted[tabpage] = { bufs, plan, sess }`.

- [ ] **Step 1: Write the failing test**

Create the new entry-point tests in `tests/view_spec.lua`:

```lua
describe("view.show renders both surfaces through one path", function()
  it("renders a single file as a plan over one file", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\ntwo\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "one\nTWO\n")

    local view = require("intentdiff.view")
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()

    local hunks = require("intentdiff.hunks")
    local diff = helpers.git(repo, "diff")
    local hs, files = hunks.parse(diff)
    files[1].hunks = hs

    local shown = false
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local plan = view.current_plan(sess.tabpage)
    assert.truthy(plan)
    assert.equals(1, #plan.files)
    assert.equals("a.lua", plan.files[1].path)
    view.close_tab(sess)
  end)

  it("renders an intent as a plan over several files, same call", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\n", ["b.lua"] = "x\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "ONE\n")
    helpers.write_file(repo, "b.lua", "X\n")

    local view = require("intentdiff.view")
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()

    local hunks = require("intentdiff.hunks")
    local hs, files = hunks.parse(helpers.git(repo, "diff"))
    for _, f in ipairs(files) do
      f.hunks = vim.tbl_filter(function(h) return h.file == f.path end, hs)
    end

    local visible = {}
    for _, h in ipairs(hs) do visible[h.id] = true end

    local shown = false
    view.show(sess, files, visible, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local plan = view.current_plan(sess.tabpage)
    assert.equals(2, #plan.files)
    -- One buffer holds both files: the map proves it.
    local paths = {}
    for row = 1, #plan.modified.lines do
      local t = plan.modified.map[row]
      if t then paths[t.file] = true end
    end
    assert.is_true(paths["a.lua"])
    assert.is_true(paths["b.lua"])
    view.close_tab(sess)
  end)

  it("has no preview-mode state left", function()
    local view = require("intentdiff.view")
    assert.is_nil(view._preview_active)
    assert.is_nil(view._preview_maps)
    assert.is_nil(view._preview_bufs)
    assert.is_nil(view._preview_sess)
  end)

  it("never creates a codediff session", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "ONE\n")

    local view = require("intentdiff.view")
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local hunks = require("intentdiff.hunks")
    local hs, files = hunks.parse(helpers.git(repo, "diff"))
    files[1].hunks = hs
    local shown = false
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
    if ok then
      assert.is_nil(lifecycle.get_session(sess.tabpage),
        "intent-diff must no longer register a codediff session")
    end
    view.close_tab(sess)
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/view_spec.lua')" -c qa`
Expected: FAIL — `view.show` does not exist.

- [ ] **Step 3: Rewrite `view.lua`**

Replace `lua/intentdiff/view.lua` wholesale. It keeps: `M.load` (narrowed to `codediff.core.diff`, `codediff.core.git`, `codediff.ui.inline` — a missing one degrades rather than aborting), `M.git`, `M.open_tab`, `M.close_tab`, `M.diff_wins`, `M.install_keymaps`, `M.install_comment_keymaps`, `M.map_view_keys`, `M.toggle_layout`, `M.foldexpr` (delegating to `paint.foldexpr`).

It gains:

```lua
--- The painted generation per tabpage: { bufs, plan, sess, files, visible }.
M._painted = {}

--- Filetype for a path, without loading the file.
local function filetype_of(path)
  local ft = vim.filetype.match({ filename = path })
  return ft or ""
end

--- Render `files` with `visible` hunks unfolded. THE render entry point:
--- a single file and a whole intent differ only in how many entries `files`
--- has.
--- @param opts table|nil { layout = "inline"|"side-by-side", on_ready = fun() }
function M.show(sess, files, visible, opts)
  opts = opts or {}
  local tabpage = sess.tabpage
  local wins = M.diff_wins(tabpage)
  if not (wins and wins.modified and vim.api.nvim_win_is_valid(wins.modified)) then
    return false
  end

  local content = require("intentdiff.render.content")
  local ready = content.ensure(sess, files, function()
    -- Content landed after we painted a fallback; repaint with the real thing.
    if M._painted[tabpage] then
      M.show(sess, files, visible, opts)
    end
  end)

  local entries, by_path = {}, {}
  for _, f in ipairs(files) do
    local entry = {
      path = f.path, old_path = f.old_path, status = f.status,
      filetype = filetype_of(f.path), binary = f.binary or false,
      hunks = f.hunks or {},
      original = content.get(sess, f.path, "old"),
      modified = content.get(sess, f.path, "new"),
    }
    entries[#entries + 1] = entry
    by_path[f.path] = { old = entry.original, new = entry.modified }
  end

  local layout = opts.layout or M._layout[tabpage] or "side-by-side"
  M._layout[tabpage] = layout

  local cfg = require("intentdiff.config").options
  local plan = require("intentdiff.render.plan").build(entries, visible, layout, {
    context = cfg.context_lines or 3,
    line_budget = cfg.line_budget or 20000,
  })

  local prior = M._painted[tabpage]
  local painted = require("intentdiff.render.paint").render(plan, wins, by_path)
  M._painted[tabpage] = {
    bufs = painted.bufs, plan = plan, sess = sess,
    files = files, visible = visible,
  }
  if prior then
    require("intentdiff.render.paint").retire(prior.bufs)
  end

  M.install_keymaps(tabpage)
  local ok_comments = pcall(function()
    require("intentdiff.comments").refresh(tabpage)
  end)
  _ = ok_comments

  if opts.on_ready and ready then
    opts.on_ready()
  elseif opts.on_ready then
    -- Painted a fallback; report ready anyway so callers are not left hanging.
    vim.schedule(opts.on_ready)
  end
  return true
end

--- The plan currently painted in `tabpage`, or nil.
function M.current_plan(tabpage)
  local p = M._painted[tabpage]
  return p and p.plan or nil
end

--- The pane `bufnr` displays, or nil when it is not one of ours.
function M.pane_for_buf(tabpage, bufnr)
  local p = M._painted[tabpage]
  if not p then
    return nil
  end
  if p.bufs.modified == bufnr then
    return p.plan.modified
  end
  if p.bufs.original == bufnr then
    return p.plan.original
  end
  return nil
end

--- Re-render the current generation in the other layout.
function M.toggle_layout(tabpage)
  local p = M._painted[tabpage]
  if not p then
    return false
  end
  local next_layout = (M._layout[tabpage] == "inline") and "side-by-side" or "inline"
  return M.show(p.sess, p.files, p.visible, { layout = next_layout })
end
```

`M._layout` is a new per-tabpage table. `M.open_tab` creates the tab and both windows itself (`tabnew` then `rightbelow vsplit`) rather than adopting one codediff made.

- [ ] **Step 4: Point the comment surfaces at the plan**

In `lua/intentdiff/comments/init.lua`: delete `preview_context` and the `view._preview_active[tabpage]` branch at line ~354. Every surface now resolves through the plan:

```lua
  local pane = view.pane_for_buf(tabpage, bufnr)
  if not pane then
    return nil, "put the cursor in a diff pane to comment"
  end
  local t = require("intentdiff.render.plan").target_at(pane, row)
```

Delete the two refusals at lines ~597-598 (`"comments are not shown in an intent preview"`) and the `_preview_active` guard at ~711 — they guarded a mode that no longer exists.

In `lua/intentdiff/comments/marks.lua`: delete `preview_placements` and `render_preview_buffer`; the file-diff path now takes a `pane` and uses `plan.rows_for` for every surface.

- [ ] **Step 5: Delete `preview.lua` and repoint its requires**

```bash
git rm lua/intentdiff/preview.lua
grep -rn 'require("intentdiff.preview")' lua/ tests/
```

Replace each with `require("intentdiff.render.plan")`.

- [ ] **Step 6: Run the affected specs**

Run each of:
```
nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/view_spec.lua')" -c qa
nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/comments_preview_spec.lua')" -c qa
nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/view_preview_spec.lua')" -c qa
```
Expected: PASS. Failures asserting on codediff internals are expected here — move those assertions to Task 13's deletion list rather than propping them up.

- [ ] **Step 7: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`. If a spec fails only because it asserts on codediff session state, note it for Task 13 and delete it now.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(view): one render path for files and intents

view.show(sess, files, visible) is the single entry point: a file view is a
plan over one file, an intent view a plan over several. intent-diff no longer
creates a codediff session at all, which retires bootstrap, the keymap
re-assert, virtual-file polling and all four _preview_* tables.

Comments resolve through the plan's map on every surface, so the two refusals
inside an intent preview simply stop existing.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Navigation from the plan, and the edit escape hatch

**Files:**
- Modify: `lua/intentdiff/navigation.lua`, `lua/intentdiff/view.lua` (keymaps), `lua/intentdiff/config.lua`
- Test: `tests/navigation_spec.lua`

**Interfaces:**
- Consumes: `view.current_plan`, `view.pane_for_buf`, `plan.target_at`
- Produces: `navigation.next_hunk(tabpage)`, `navigation.prev_hunk(tabpage)`, `view.open_real_file(tabpage)`; config key `keymaps.view.open_file` defaulting to `"gf"`

- [ ] **Step 1: Write the failing test**

Append to `tests/navigation_spec.lua`:

```lua
describe("the edit escape hatch", function()
  it("opens the real file at the row's coordinate", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\ntwo\nthree\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "one\nTWO\nthree\n")

    local view = require("intentdiff.view")
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local hunks = require("intentdiff.hunks")
    local hs, files = hunks.parse(helpers.git(repo, "diff"))
    files[1].hunks = hs
    local shown = false
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local wins = view.diff_wins(sess.tabpage)
    local plan = view.current_plan(sess.tabpage)
    -- Find the row showing modified line 2.
    local target_row
    for row = 1, #plan.modified.lines do
      local t = plan.modified.map[row]
      if t and t.line == 2 and t.side == "new" then target_row = row end
    end
    assert.truthy(target_row)
    vim.api.nvim_win_set_cursor(wins.modified, { target_row, 0 })
    view.open_real_file(sess.tabpage)

    local buf = vim.api.nvim_get_current_buf()
    assert.equals(repo .. "/a.lua", vim.api.nvim_buf_get_name(buf))
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
    assert.is_true(vim.bo[buf].modifiable, "the real file must be editable")
    view.close_tab(sess)
  end)

  it("does nothing on a row that addresses no line", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "ONE\n")

    local view = require("intentdiff.view")
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local hunks = require("intentdiff.hunks")
    local hs, files = hunks.parse(helpers.git(repo, "diff"))
    files[1].hunks = hs
    local shown = false
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local wins = view.diff_wins(sess.tabpage)
    vim.api.nvim_win_set_cursor(wins.modified, { 1, 0 })  -- the separator row
    local before = vim.api.nvim_get_current_buf()
    view.open_real_file(sess.tabpage)
    assert.equals(before, vim.api.nvim_get_current_buf())
    view.close_tab(sess)
  end)
end)

describe("navigation reads hunk ranges from the plan", function()
  it("jumps between the visible hunks only", function()
    local orig, mod = {}, {}
    for i = 1, 30 do orig[i] = "line" .. i; mod[i] = "line" .. i end
    mod[5] = "A"; mod[15] = "B"; mod[25] = "C"
    local repo = helpers.make_repo({ ["a.lua"] = table.concat(orig, "\n") .. "\n" })
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-m", "base")
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", table.concat(mod, "\n") .. "\n")

    local view = require("intentdiff.view")
    local nav = require("intentdiff.navigation")
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local hunks = require("intentdiff.hunks")
    local hs, files = hunks.parse(helpers.git(repo, "diff"))
    files[1].hunks = hs
    assert.equals(3, #hs)

    -- Only the first and third hunks are in this intent.
    local visible = { [hs[1].id] = true, [hs[3].id] = true }
    local shown = false
    view.show(sess, files, visible, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local wins = view.diff_wins(sess.tabpage)
    vim.api.nvim_win_set_cursor(wins.modified, { 1, 0 })
    nav.next_hunk(sess.tabpage)
    local first = vim.api.nvim_win_get_cursor(wins.modified)[1]
    nav.next_hunk(sess.tabpage)
    local second = vim.api.nvim_win_get_cursor(wins.modified)[1]
    nav.next_hunk(sess.tabpage)
    local third = vim.api.nvim_win_get_cursor(wins.modified)[1]

    assert.is_true(second > first)
    assert.equals(second, third, "must not jump to the unowned middle hunk")
    view.close_tab(sess)
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/navigation_spec.lua')" -c qa`
Expected: FAIL — `view.open_real_file` does not exist.

- [ ] **Step 3: Implement the escape hatch**

In `lua/intentdiff/view.lua`:

```lua
--- Open the real file the cursor's row addresses, at that line, in a normal
--- editable window. Works identically in a single-file and an intent view,
--- because both resolve through the same map.
function M.open_real_file(tabpage)
  local win = vim.api.nvim_get_current_win()
  local pane = M.pane_for_buf(tabpage, vim.api.nvim_win_get_buf(win))
  if not pane then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local t = require("intentdiff.render.plan").target_at(pane, row)
  if not t then
    return false
  end
  local painted = M._painted[tabpage]
  local abs = painted.sess.git_root .. "/" .. t.file
  -- A new tab, so the review tab's two-pane layout is left intact.
  vim.cmd("tabedit " .. vim.fn.fnameescape(abs))
  pcall(vim.api.nvim_win_set_cursor, 0, { t.line, 0 })
  return true
end
```

Add the plan's hunk row ranges. In `plan.lua`, record them in `M.build`'s return:

```lua
    hunk_rows = hunk_rows,  -- { {first_row, last_row}, ... } for VISIBLE hunks, ascending
```

built from the same `hunk_spans` the folds use, filtered to `visible[id]` and sorted by `first_row`.

In `lua/intentdiff/navigation.lua`, replace the codediff-based jump with:

```lua
local function jump(tabpage, forward)
  local view = require("intentdiff.view")
  local plan = view.current_plan(tabpage)
  if not plan or #plan.hunk_rows == 0 then
    return false
  end
  local win = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local target
  if forward then
    for _, range in ipairs(plan.hunk_rows) do
      if range[1] > row then target = range[1]; break end
    end
  else
    for i = #plan.hunk_rows, 1, -1 do
      if plan.hunk_rows[i][1] < row then target = plan.hunk_rows[i][1]; break end
    end
  end
  if not target then
    return false
  end
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  return true
end

function M.next_hunk(tabpage) return jump(tabpage, true) end
function M.prev_hunk(tabpage) return jump(tabpage, false) end
```

- [ ] **Step 4: Add the keymap**

In `lua/intentdiff/config.lua`, in `keymaps.view`:

```lua
      -- Panes are read-only scratch buffers; this opens the real file at the
      -- cursor's exact (file, line), in a new tab.
      open_file = "gf",
```

Bind it in `view.install_keymaps` alongside the existing view keys.

- [ ] **Step 5: Run the spec and confirm it passes**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/navigation_spec.lua')" -c qa`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(view): plan-driven navigation and an edit escape hatch

]c/[c read hunk row ranges from the plan, so they are group-scoped by
construction rather than by fighting codediff's all-hunks defaults. gf opens
the real file at the cursor's exact (file, line) — identically in a
single-file and an intent view, which hover_opens_files could never do.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Configuration, README and ATTRIBUTION

**Files:**
- Modify: `lua/intentdiff/config.lua`, `README.md`
- Create: `ATTRIBUTION.md`
- Test: `tests/config_spec.lua`

**Interfaces:**
- Consumes: nothing
- Produces: `config.options.line_budget`; `preview.max_lines` and `preview.hover_opens_files` removed

- [ ] **Step 1: Write the failing test**

Append to `tests/config_spec.lua`:

```lua
describe("config after the renderer unification", function()
  it("exposes a line budget and no preview truncation", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.equals(20000, config.options.line_budget)
    assert.is_nil((config.options.preview or {}).max_lines)
    assert.is_nil((config.options.preview or {}).hover_opens_files)
  end)

  it("binds the edit escape hatch in the view surface", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.equals("gf", config.options.keymaps.view.open_file)
  end)

  it("owns context_lines outright", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.equals(3, config.options.context_lines)
  end)
end)
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `nvim --headless -u tests/init.lua -c "lua require('plenary.busted').run('$PWD/tests/config_spec.lua')" -c qa`
Expected: FAIL — `line_budget` is nil.

- [ ] **Step 3: Implement**

In `lua/intentdiff/config.lua`:
- Change `context_lines = nil` to `context_lines = 3` and drop the comment about following codediff's `diff.compact_context_lines`.
- Add `line_budget = 20000` with a comment naming what it replaces.
- Remove `preview.max_lines` and `preview.hover_opens_files`.
- Keep the `preview` table only if other keys remain; otherwise remove it and update any reader.

Run `grep -rn "max_lines\|hover_opens_files" lua/ tests/ README.md` and remove every reader.

- [ ] **Step 4: Write `ATTRIBUTION.md`**

```markdown
# Attribution

intent-diff.nvim builds on other people's work. This file records what, and
under which licence. We are grateful to all of them.

---

## codediff.nvim

**License:** MIT
**Copyright:** Copyright (c) 2025 Yanuo Ma
**Source:** https://github.com/esmuellert/codediff.nvim
**Purpose:** intent-diff depends on codediff.nvim at runtime for its diff
engine and two rendering helpers.

Specifically, intent-diff uses:

- `codediff.core.diff` — the LuaJIT FFI binding to `libvscode-diff`, and the
  installer that fetches its prebuilt binary. This is what gives intent-diff
  character-level highlighting inside changed lines.
- `codediff.core.git` — revision resolution and file content fetching.
- `codediff.ui.inline.compute_syntax_highlights` — treesitter highlights for an
  arbitrary array of lines, which is what lets intent-diff syntax-highlight
  synthetic multi-file buffers.

**If you want a general-purpose diff, merge and git-history tool for Neovim,
install codediff.nvim directly — it is excellent, and intent-diff is not a
replacement for it.** intent-diff does one narrow thing: it groups a diff by
*intent* and gives you a review surface over those groups.

---

## Microsoft Visual Studio Code

**License:** MIT
**Copyright:** Copyright (c) Microsoft Corporation
**Source:** https://github.com/microsoft/vscode
**Purpose:** `libvscode-diff`, which intent-diff reaches through codediff.nvim,
is a C port of VSCode's `defaultLinesDiffComputer` — the Myers diff
implementation, its line-level optimisation heuristics, and the character-level
refinement that produces intra-line highlighting.

See codediff.nvim's own `ATTRIBUTION.md` for the full component list and
licence text.

---

## utf8proc

**License:** MIT
**Copyright:** Copyright (c) 2014-2021 Steven G. Johnson, Jiahao Chen, Tony
Kelman, Jonas Fonseca, and other contributors
**Source:** https://github.com/JuliaStrings/utf8proc
**Purpose:** Bundled inside the `libvscode-diff` binary for Unicode string
processing.

---

## plenary.nvim

**License:** MIT
**Maintainers:** nvim-lua community
**Source:** https://github.com/nvim-lua/plenary.nvim
**Purpose:** Test framework (development only).

---

## Acknowledgments

- **Yanuo Ma** and the codediff.nvim contributors, whose C port of VSCode's
  diff algorithm is what makes intent-diff's rendering possible at all.
- **Microsoft Corporation** and the VSCode team for open-sourcing that
  algorithm.
- **review.nvim** by georgeguimaraes, whose review-comment UX intent-diff's
  comments are modelled on.

---

*intent-diff.nvim is distributed under the MIT License. See LICENSE.*
```

- [ ] **Step 5: Add the README "Built on" section**

Immediately after the README's opening description, before any installation or
feature section, insert:

```markdown
## Built on codediff.nvim

intent-diff renders diffs using **[codediff.nvim](https://github.com/esmuellert/codediff.nvim)**
by Yanuo Ma (MIT). Its `libvscode-diff` — a C port of VSCode's own
`defaultLinesDiffComputer` — is what gives intent-diff character-level
highlighting inside changed lines, and its treesitter helper is what lets
intent-diff syntax-highlight the synthetic buffers it builds.

**If you want a general-purpose diff, merge and git-history tool for Neovim,
install [codediff.nvim](https://github.com/esmuellert/codediff.nvim) directly.**
It is excellent and intent-diff does not replace it. intent-diff does one
narrow thing: it groups a diff by *intent* and gives you a review surface over
those groups.

Full credits in [ATTRIBUTION.md](ATTRIBUTION.md).
```

Also update the README's configuration table: remove `preview.max_lines` and
`preview.hover_opens_files`, add `line_budget` and the `gf` keymap, and note
that diff panes are read-only scratch buffers with `gf` as the way into the
real file.

- [ ] **Step 6: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
docs: credit codediff.nvim up front, retire preview config

The diff engine and the treesitter helper are codediff.nvim's work, and
vendoring was rejected precisely so users install it by name. Say so at the
top of the README, not in a footer, and recommend it for the general-purpose
job intent-diff does not do.

preview.max_lines and preview.hover_opens_files go: folds handle size, and
gf opens the real file on every surface.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Delete the obsolete codediff-internals assertions

**Files:**
- Modify: `tests/integration_spec.lua`, `tests/view_spec.lua`, `tests/view_preview_spec.lua`, `tests/hover_spec.lua`, `tests/sidebar_toggle_spec.lua`, `tests/comments_actions_spec.lua`, `tests/view_added_file_spec.lua`, `tests/config_spec.lua`, `tests/sidebar_spec.lua`, `tests/init.lua`

**Interfaces:**
- Consumes: everything
- Produces: a suite that asserts on intent-diff's own plan and painted buffers

This task **reduces** the success count. That is expected and correct: these tests guard behaviours that no longer exist.

- [ ] **Step 1: Inventory what to delete**

Run: `grep -rn "codediff" tests/`

Delete tests asserting on any of:
- `codediff.ui.lifecycle.get_session` / `stored_diff_result` / `session.layout`
- the keymap re-assert after `TabLeave`/`TabEnter`
- `CodeDiff N.N` placeholder buffers
- `codediff.config.options.keymaps.view.toggle_layout` being rebound by us
- codediff's `]c` all-hunks default being overridden
- `codediff://` virtual file URIs

Keep `tests/init.lua`'s codediff clone: it is still a runtime dependency.

- [ ] **Step 2: Replace, don't just delete, where the behaviour survives**

Three behaviours still matter and need assertions against the new implementation:

```lua
-- Was: "codediff's layout toggle key re-renders and re-applies the group folds"
it("the layout toggle re-renders and keeps the group folds", function()
  -- ... set up a review, note view.current_plan(tab).folds
  require("intentdiff.view").toggle_layout(tab)
  local plan = require("intentdiff.view").current_plan(tab)
  assert.equals("inline", plan.layout)
  assert.is_true(#plan.hunk_rows > 0, "the visible hunks survived the toggle")
end)

-- Was: "]c must be group-scoped (intentdiff's own attach), not codediff's default"
it("]c is group-scoped by construction", function()
  -- assert plan.hunk_rows contains only the visible hunks' rows
end)

-- Was: the sidebar reaching "ready" with two empty codediff placeholders
it("the panes hold real content as soon as the review is ready", function()
  local plan = require("intentdiff.view").current_plan(tab)
  assert.is_true(#plan.modified.lines > 1)
end)
```

- [ ] **Step 3: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `Failed: 0`, `Errors: 0`. The success count will be **below** 510 — record the new baseline in the commit message.

- [ ] **Step 4: Verify the coupling really shrank**

Run: `grep -rn 'require("codediff' lua/`
Expected: matches only in `lua/intentdiff/view.lua` and `lua/intentdiff/render/*.lua`, and only for `codediff.core.diff`, `codediff.core.git`, `codediff.ui.inline`.

Run: `wc -l lua/intentdiff/view.lua`
Expected: well under 1385 — the spec projects ~400.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
test: delete assertions guarding behaviours that no longer exist

Most codediff references in the suite existed to verify that our workarounds
survived its session, keymap and placeholder-buffer behaviour. There is no
codediff session any more, so they are deleted rather than ported. Three
behaviours that still matter get assertions against the plan instead.

New baseline: <N> successes across <M> spec files.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage.** Every section of the design maps to a task: unified concept → 3–5, 10; chunking → 3, 9; `plan.lua` → 3–5; `paint.lua` → 7–9; `content.lua` → 2; `view.lua` → 10; rendering details (fillers, markers, A/D/?? files) → 3, 4, 6; navigation and escape hatch → 11; error handling → 1 (binary), 2 (fetch failure), 5 (budget, fallback), 8 (missing parser), 9 (library unavailable), 7 (closed pane); testing → every task plus 13; highlight groups → 6; configuration → 12; attribution → 12.

**Known deviations from the spec, deliberate:**
- The spec's `plan.files` entries gain a `fallback` flag and the plan gains `hunk_rows`; both are needed by Tasks 5 and 11 and were implicit in the spec.
- `paint.render` takes a third `content` argument the spec did not name, because syntax highlighting needs the full per-side content the plan does not carry.
- `utf16_col_to_byte_col` is reimplemented rather than imported: it is a file-local in codediff and not exported, so importing it would violate the Global Constraints.
- `open_real_file` uses `tabedit` rather than reusing a window, so the review tab's two-pane layout survives.

**Type consistency.** `plan.build`, `plan.target_at`, `plan.rows_for`, `content.ensure`, `content.get`, `content.invalidate`, `paint.render`, `paint.retire`, `paint.ns`, `paint.foldexpr`, `view.show`, `view.current_plan`, `view.pane_for_buf`, `view.open_real_file`, `navigation.next_hunk`/`prev_hunk` are each defined once and used consistently. `pane` is `{lines, spans, map}` throughout — note this renames `preview.lua`'s `highlights` field to `spans`, applied from Task 3 onward.

**Risk noted for execution:** Task 10 is the largest and touches four files at once. It is not splittable — the moment `view.show` replaces `show_file`/`show_preview`, the comment surfaces must resolve through the plan or every comment test fails. Expect to iterate there, and lean on the fact that Tasks 1–9 are independently green before starting it.
