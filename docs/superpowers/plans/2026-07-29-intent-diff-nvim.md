# intent-diff.nvim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Review git diffs grouped by LLM-classified *reason of change*: a sidebar of groups → files, each file opening in codediff.nvim with only that group's hunks unfolded.

**Architecture:** Companion plugin to codediff.nvim. We own diff collection (plain `git diff` parsing), classification (pluggable async provider, default `claude` CLI), caching, the sidebar, and group-scoped navigation. codediff renders the actual diffs; `lua/intentdiff/view.lua` is the only module allowed to require codediff internals, and applies our fold filter (own `foldexpr`, reusing codediff's pure `compute_visible_lines`).

**Tech Stack:** Lua (Neovim ≥ 0.10), codediff.nvim (pinned via lazy-lock), plenary.nvim busted-style tests run headless.

**Spec:** `docs/superpowers/specs/2026-07-29-intent-diff-design.md` — read it before starting.

## Global Constraints

- Only `lua/intentdiff/view.lua` may `require` any `codediff.*` module; every such require and function access is `pcall`-guarded; on mismatch notify `"intent-diff: codediff API mismatch — grouped view disabled"` and degrade, never error mid-review.
- Provider contract (exact): `provider(request, callback)` with `request = { diff_text: string|nil, hunks: {id, file, summary_lines}[] }`, `callback(result|nil, err|nil)` where `result = { groups = { {title: string, hunk_ids: string[]}[] } }`. Providers return an optional handle `{ cancel = function }`.
- Completeness invariant: after reconciliation, union of all groups + Ungrouped == the exact hunk inventory. Hallucinated IDs dropped, duplicates kept in first group only, missed hunks forced into Ungrouped. Never silently drop a hunk.
- The review flow must never block on the LLM: sidebar shows a flat file list while classifying and on provider failure.
- Defaults: provider `claude` CLI, model `haiku`, timeout 60000 ms, sidebar width 36, `max_full_diff_bytes` 102400, `max_hunks` 400, fold context lines = codediff's `diff.compact_context_lines` (falls back to 3).
- Cache location: `stdpath("cache") .. "/intentdiff/<diff_hash>.json"`.
- Hunk IDs are `"<new-path>:<n>"` with n = 1-based hunk index within that file, in diff order.
- All git/LLM subprocess work is async (`vim.system` / `jobstart`); callbacks that touch `vim.fn`/buffers must run inside `vim.schedule`.
- Commit after every task (each task ends with a commit step).

## File Structure

```
plugin/intentdiff.lua        -- :IntentDiff command registration (Task 11)
lua/intentdiff/
  init.lua                   -- setup(), session orchestration, public API
  config.lua                 -- defaults + setup merge
  hunks.lua                  -- git diff parsing + async collection → Inventory
  classify.lua               -- reconcile() + run() orchestration
  cache.lua                  -- diff-hash keyed persistence + stale re-match
  providers/claude_cli.lua   -- default provider factory
  sidebar.lua                -- group→file tree buffer (layout + window + keymaps)
  view.lua                   -- THE codediff adapter (open/show_file/folds/toggle)
  navigation.lua             -- group-scoped ]c/[c with cross-file rollover
tests/
  init.lua                   -- headless bootstrap (plenary + codediff on rtp)
  helpers.lua                -- fixture repo builder, fake provider bin
  run_tests.sh               -- test runner script
  *_spec.lua                 -- one spec file per module
```

### Shared types (used verbatim across tasks)

```lua
--- @class Hunk
--- @field id string           -- "src/foo.ts:1"
--- @field file string         -- new path (rename target)
--- @field old_path string?    -- rename source, nil unless renamed
--- @field status string       -- "M"|"A"|"D"|"??"
--- @field header string       -- "@@ -10,7 +10,8 @@"
--- @field original {start_line: integer, end_line: integer} -- 1-based, end EXCLUSIVE
--- @field modified {start_line: integer, end_line: integer}
--- @field text string         -- raw hunk text incl. header line
--- @field content_hash string -- vim.fn.sha256(text)

--- @class Inventory
--- @field hunks Hunk[]
--- @field files {path: string, status: string, old_path: string?}[] -- diff order
--- @field diff_text string
--- @field diff_hash string    -- sha256 over concatenated hunk content_hashes

--- @class Group
--- @field title string
--- @field hunks Hunk[]
--- @field files {path: string, status: string, old_path: string?, hunks: Hunk[]}[]
--- @field is_ungrouped boolean?
--- @field collapsed boolean?

--- @class Model                -- what the sidebar renders
--- @field state "loading"|"ready"|"error"
--- @field groups Group[]
--- @field total_hunks integer
--- @field grouped_hunks integer
--- @field stale_count integer?
--- @field provider_label string?
--- @field message string?     -- warning/notice line, nil when none
```

---

### Task 1: Scaffolding, config, test harness

**Files:**
- Create: `lua/intentdiff/config.lua`, `lua/intentdiff/init.lua`, `tests/init.lua`, `tests/helpers.lua`, `tests/run_tests.sh`, `tests/config_spec.lua`, `.gitignore`

**Interfaces:**
- Produces: `require("intentdiff.config").options` (merged config), `.setup(opts)`, `.defaults`; `require("intentdiff").setup(opts)`; test helpers `helpers.make_repo(files)`, `helpers.write_file(repo, path, content)`, `helpers.git(repo, ...)`.

- [ ] **Step 1: Write the failing test**

`tests/config_spec.lua`:

```lua
describe("config", function()
  it("merges user opts over defaults", function()
    local config = require("intentdiff.config")
    config.setup({ provider_opts = { model = "sonnet" }, sidebar_width = 50 })
    assert.equals("sonnet", config.options.provider_opts.model)
    assert.equals("claude", config.options.provider_opts.cmd) -- default preserved
    assert.equals(50, config.options.sidebar_width)
    assert.equals(60000, config.options.provider_opts.timeout_ms)
  end)

  it("setup twice starts from defaults, not previous merge", function()
    local config = require("intentdiff.config")
    config.setup({ sidebar_width = 50 })
    config.setup({})
    assert.equals(36, config.options.sidebar_width)
  end)
end)
```

- [ ] **Step 2: Create the test harness**

`tests/init.lua` (mirrors codediff's own harness):

```lua
vim.opt.shadafile = "NONE"
vim.opt.swapfile = false
local cwd = vim.fn.getcwd()
vim.opt.rtp:prepend(cwd)
package.path = package.path .. ";" .. cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua"

-- plenary: clone into data dir if missing
local plenary_dir = vim.fn.stdpath("data") .. "/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end
vim.opt.rtp:prepend(plenary_dir)

-- codediff: prefer the lazy.nvim install, else clone
local codediff_dir = vim.env.INTENTDIFF_CODEDIFF_DIR
  or (vim.fn.stdpath("data") .. "/lazy/codediff.nvim")
if vim.fn.isdirectory(codediff_dir) == 0 then
  codediff_dir = vim.fn.stdpath("data") .. "/codediff.nvim"
  if vim.fn.isdirectory(codediff_dir) == 0 then
    vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/esmuellert/codediff.nvim", codediff_dir })
  end
end
vim.opt.rtp:prepend(codediff_dir)
vim.cmd("runtime! plugin/*.lua")
pcall(function() require("codediff").setup() end)
```

`tests/run_tests.sh` (make executable, `chmod +x`):

```bash
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."
nvim --headless -u tests/init.lua \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/init.lua', sequential = true }"
```

`tests/helpers.lua`:

```lua
local M = {}

function M.git(repo, ...)
  local out = vim.fn.system({ "git", "-C", repo, ... })
  assert(vim.v.shell_error == 0, "git failed: " .. out)
  return out
end

function M.write_file(repo, path, content)
  local abs = repo .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
  vim.fn.writefile(vim.split(content, "\n"), abs)
end

--- Create a temp git repo with an initial commit of `files` ({[path]=content}).
function M.make_repo(files)
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  M.git(repo, "init", "-q")
  M.git(repo, "config", "user.email", "test@test")
  M.git(repo, "config", "user.name", "test")
  M.git(repo, "config", "commit.gpgsign", "false")
  for path, content in pairs(files) do
    M.write_file(repo, path, content)
  end
  M.git(repo, "add", "-A")
  M.git(repo, "commit", "-q", "-m", "initial")
  return repo
end

--- Wait until fn() is truthy or timeout (ms). Returns fn()'s value.
function M.wait_for(fn, timeout)
  local result
  vim.wait(timeout or 5000, function()
    result = fn()
    return result and true or false
  end, 10)
  return result
end

return M
```

`.gitignore`:

```
*.log
```

- [ ] **Step 3: Run test to verify it fails**

Run: `./tests/run_tests.sh` — Expected: FAIL (`module 'intentdiff.config' not found`)

- [ ] **Step 4: Write config.lua and init.lua**

`lua/intentdiff/config.lua`:

```lua
local M = {}

M.defaults = {
  provider = "claude_cli", -- name under intentdiff.providers.*, or a function(request, callback)
  provider_opts = {
    cmd = "claude",
    model = "haiku",
    timeout_ms = 60000,
  },
  context_lines = nil, -- nil = follow codediff's diff.compact_context_lines
  sidebar_width = 36,
  max_full_diff_bytes = 100 * 1024, -- above this, prompt gets per-hunk summaries only
  max_hunks = 400, -- above this, skip classification with a notice
  cache_dir = vim.fn.stdpath("cache") .. "/intentdiff",
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
```

`lua/intentdiff/init.lua` (grows in Task 11):

```lua
local M = {}

function M.setup(opts)
  require("intentdiff.config").setup(opts)
end

return M
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./tests/run_tests.sh` — Expected: PASS (2 tests)

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: scaffolding, config, plenary test harness"
```

---

### Task 2: Unified diff parsing (`hunks.parse`)

**Files:**
- Create: `lua/intentdiff/hunks.lua`, `tests/hunks_parse_spec.lua`

**Interfaces:**
- Produces: `hunks.parse(diff_text) -> Hunk[], files[]` and `hunks.untracked_hunk(path, lines) -> Hunk` (types per header). Ranges are 1-based, end-exclusive; a zero-length side (`,0`) becomes a zero-width anchor `{start_line = n+1, end_line = n+1}`.

- [ ] **Step 1: Write the failing tests**

`tests/hunks_parse_spec.lua`:

```lua
local hunks = require("intentdiff.hunks")

local DIFF = table.concat({
  "diff --git a/src/a.lua b/src/a.lua",
  "index 111..222 100644",
  "--- a/src/a.lua",
  "+++ b/src/a.lua",
  "@@ -10,3 +10,4 @@ local ctx",
  " keep",
  "-old",
  "+new",
  "+extra",
  "@@ -30,2 +31,2 @@",
  "-x",
  "+y",
  " keep",
  "diff --git a/old.lua b/renamed.lua",
  "similarity index 90%",
  "rename from old.lua",
  "rename to renamed.lua",
  "--- a/old.lua",
  "+++ b/renamed.lua",
  "@@ -1,1 +1,1 @@",
  "-a",
  "+b",
  "diff --git a/added.lua b/added.lua",
  "new file mode 100644",
  "--- /dev/null",
  "+++ b/added.lua",
  "@@ -0,0 +1,2 @@",
  "+l1",
  "+l2",
  "diff --git a/gone.lua b/gone.lua",
  "deleted file mode 100644",
  "--- a/gone.lua",
  "+++ /dev/null",
  "@@ -1,2 +0,0 @@",
  "-l1",
  "-l2",
}, "\n") .. "\n"

describe("hunks.parse", function()
  local parsed, files
  before_each(function() parsed, files = hunks.parse(DIFF) end)

  it("assigns per-file sequential ids", function()
    assert.equals("src/a.lua:1", parsed[1].id)
    assert.equals("src/a.lua:2", parsed[2].id)
    assert.equals("renamed.lua:1", parsed[3].id)
    assert.equals(5, #parsed)
  end)

  it("parses ranges end-exclusive", function()
    assert.same({ start_line = 10, end_line = 13 }, parsed[1].original)
    assert.same({ start_line = 10, end_line = 14 }, parsed[1].modified)
  end)

  it("normalizes zero-length ranges to zero-width anchors", function()
    assert.same({ start_line = 1, end_line = 1 }, parsed[4].original)  -- @@ -0,0
    assert.same({ start_line = 1, end_line = 1 }, parsed[5].modified)  -- +0,0
  end)

  it("detects rename, added, deleted statuses", function()
    assert.equals("old.lua", parsed[3].old_path)
    assert.equals("A", parsed[4].status)
    assert.equals("D", parsed[5].status)
    assert.same({ path = "added.lua", status = "A", old_path = nil }, files[3])
  end)

  it("captures raw hunk text and content hash", function()
    assert.truthy(parsed[1].text:find("^@@ %-10,3"))
    assert.truthy(parsed[1].text:find("%+extra\n"))
    assert.equals(vim.fn.sha256(parsed[1].text), parsed[1].content_hash)
  end)

  it("builds a whole-file hunk for untracked files", function()
    local h = hunks.untracked_hunk("nu.lua", { "a", "b", "c" })
    assert.equals("nu.lua:1", h.id)
    assert.equals("??", h.status)
    assert.same({ start_line = 1, end_line = 1 }, h.original)
    assert.same({ start_line = 1, end_line = 4 }, h.modified)
  end)
end)
```

- [ ] **Step 2: Run to verify failure** — `./tests/run_tests.sh` — Expected: FAIL (`module 'intentdiff.hunks' not found`)

- [ ] **Step 3: Implement**

`lua/intentdiff/hunks.lua`:

```lua
local M = {}

local function range(start, len)
  if len == 0 then
    return { start_line = start + 1, end_line = start + 1 } -- zero-width anchor
  end
  return { start_line = start, end_line = start + len } -- end exclusive
end

--- Parse unified `git diff` output.
--- @return Hunk[] hunks, table[] files
function M.parse(diff_text)
  local hunks, files = {}, {}
  local file, old_path, status
  local per_file = {}
  local current
  local function flush()
    if current then
      current.content_hash = vim.fn.sha256(current.text)
      hunks[#hunks + 1] = current
      current = nil
    end
  end
  for line in (diff_text .. "\n"):gmatch("(.-)\n") do
    local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
    if a then
      flush()
      file, old_path, status = b, (a ~= b) and a or nil, "M"
      files[#files + 1] = { path = file, status = "M", old_path = old_path }
    elseif line:match("^new file mode") then
      status = "A"
      files[#files].status = "A"
    elseif line:match("^deleted file mode") then
      status = "D"
      files[#files].status = "D"
    elseif line:match("^@@") then
      flush()
      local os_, ol, ms, ml = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      per_file[file] = (per_file[file] or 0) + 1
      current = {
        id = file .. ":" .. per_file[file],
        file = file,
        old_path = old_path,
        status = status,
        header = line,
        original = range(tonumber(os_), ol == "" and 1 or tonumber(ol)),
        modified = range(tonumber(ms), ml == "" and 1 or tonumber(ml)),
        text = line .. "\n",
      }
    elseif current then
      current.text = current.text .. line .. "\n"
    end
  end
  flush()
  return hunks, files
end

--- Whole-file synthetic hunk for an untracked file.
function M.untracked_hunk(path, lines)
  local text = ("@@ -0,0 +1,%d @@\n+%s\n"):format(#lines, table.concat(lines, "\n+"))
  return {
    id = path .. ":1",
    file = path,
    status = "??",
    header = ("@@ -0,0 +1,%d @@"):format(#lines),
    original = { start_line = 1, end_line = 1 },
    modified = { start_line = 1, end_line = math.max(1, #lines) + 1 },
    text = text,
    content_hash = vim.fn.sha256(text),
  }
end

return M
```

- [ ] **Step 4: Run to verify pass** — `./tests/run_tests.sh` — Expected: PASS

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: unified diff parsing into hunk inventory"`

---

### Task 3: Async diff collection (`hunks.collect`)

**Files:**
- Modify: `lua/intentdiff/hunks.lua`
- Create: `tests/hunks_collect_spec.lua`

**Interfaces:**
- Consumes: `hunks.parse`, `hunks.untracked_hunk`, `helpers.make_repo`.
- Produces: `hunks.collect(opts, callback)` — `opts = { git_root: string, base: string?, target: string? }`; base=nil → working tree vs HEAD + untracked; base only → working tree vs base + untracked; base+target → rev vs rev, no untracked. `callback(Inventory|nil, err|nil)` always on the main loop.

- [ ] **Step 1: Write the failing tests**

`tests/hunks_collect_spec.lua`:

```lua
local hunks = require("intentdiff.hunks")
local helpers = require("tests.helpers")

describe("hunks.collect", function()
  it("collects working-tree changes plus untracked files", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\ntwo\nthree" })
    helpers.write_file(repo, "a.lua", "one\nCHANGED\nthree")
    helpers.write_file(repo, "brand_new.lua", "hello")

    local inv, err
    hunks.collect({ git_root = repo }, function(i, e) inv, err = i, e end)
    helpers.wait_for(function() return inv or err end)

    assert.is_nil(err)
    assert.equals(2, #inv.hunks)
    assert.equals("a.lua:1", inv.hunks[1].id)
    assert.equals("brand_new.lua:1", inv.hunks[2].id)
    assert.equals("??", inv.hunks[2].status)
    assert.is_string(inv.diff_hash)
    assert.equals(64, #inv.diff_hash)
  end)

  it("diff hash changes when content changes", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\ntwo" })
    helpers.write_file(repo, "a.lua", "one\nX")
    local h1
    hunks.collect({ git_root = repo }, function(i) h1 = i.diff_hash end)
    helpers.wait_for(function() return h1 end)
    helpers.write_file(repo, "a.lua", "one\nY")
    local h2
    hunks.collect({ git_root = repo }, function(i) h2 = i.diff_hash end)
    helpers.wait_for(function() return h2 end)
    assert.not_equals(h1, h2)
  end)

  it("two-revision mode skips untracked and reports rev-vs-rev", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    helpers.write_file(repo, "a.lua", "two")
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-q", "-m", "second")
    helpers.write_file(repo, "untracked.lua", "x")
    local inv
    hunks.collect({ git_root = repo, base = "HEAD~1", target = "HEAD" }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)
    assert.equals(1, #inv.hunks)
    assert.equals("a.lua:1", inv.hunks[1].id)
  end)

  it("reports git errors", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local err
    hunks.collect({ git_root = repo, base = "no-such-rev" }, function(_, e) err = e end)
    helpers.wait_for(function() return err end)
    assert.truthy(err:find("git diff failed"))
  end)
end)
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL (`attempt to call field 'collect' (a nil value)`)

- [ ] **Step 3: Implement** (append to `lua/intentdiff/hunks.lua`, before `return M`)

```lua
--- Collect the diff to classify and display. See task interface for opts.
--- @param callback fun(inventory: Inventory|nil, err: string|nil)
function M.collect(opts, callback)
  local args = { "git", "-C", opts.git_root, "diff", "--no-color", "--no-ext-diff" }
  if opts.base and opts.target then
    vim.list_extend(args, { opts.base, opts.target })
  else
    args[#args + 1] = opts.base or "HEAD"
  end

  vim.system(args, { text = true }, function(diff_out)
    local function finish_with(untracked)
      -- Runs on main loop: vim.fn.* is safe here.
      if diff_out.code ~= 0 then
        return callback(nil, "git diff failed: " .. vim.trim(diff_out.stderr or ""))
      end
      local diff_text = diff_out.stdout or ""
      local hunks, files = M.parse(diff_text)
      for _, path in ipairs(untracked or {}) do
        local ok, lines = pcall(vim.fn.readfile, opts.git_root .. "/" .. path)
        if ok then
          files[#files + 1] = { path = path, status = "??" }
          hunks[#hunks + 1] = M.untracked_hunk(path, lines)
        end
      end
      local hashes = {}
      for i, h in ipairs(hunks) do hashes[i] = h.content_hash end
      callback({
        hunks = hunks,
        files = files,
        diff_text = diff_text,
        diff_hash = vim.fn.sha256(table.concat(hashes, "\n")),
      })
    end

    if opts.base and opts.target then
      return vim.schedule(function() finish_with(nil) end)
    end
    vim.system(
      { "git", "-C", opts.git_root, "ls-files", "--others", "--exclude-standard" },
      { text = true },
      function(ls_out)
        vim.schedule(function()
          local untracked = ls_out.code == 0
              and vim.split(vim.trim(ls_out.stdout or ""), "\n", { trimempty = true })
            or nil
          finish_with(untracked)
        end)
      end
    )
  end)
end
```

- [ ] **Step 4: Run to verify pass** — Expected: PASS

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: async git diff collection with untracked files"`

---

### Task 4: Reconciliation (`classify.reconcile`) — the completeness invariant

**Files:**
- Create: `lua/intentdiff/classify.lua`, `tests/classify_reconcile_spec.lua`

**Interfaces:**
- Consumes: Inventory (Tasks 2–3).
- Produces: `classify.reconcile(inventory, raw_groups) -> Group[]` and `classify.group_files(hunks, files) -> Group.files`. `raw_groups = { {title, hunk_ids}, ... }` (provider shape). Last group is `{ title = "Ungrouped", is_ungrouped = true }` iff any hunk was unassigned.

- [ ] **Step 1: Write the failing tests**

`tests/classify_reconcile_spec.lua`:

```lua
local classify = require("intentdiff.classify")

local function mk_hunk(file, n, line)
  return {
    id = file .. ":" .. n, file = file, status = "M",
    header = "@@", text = "@@\n", content_hash = tostring(line),
    original = { start_line = line, end_line = line + 1 },
    modified = { start_line = line, end_line = line + 1 },
  }
end

local function mk_inventory()
  return {
    hunks = { mk_hunk("a.lua", 1, 1), mk_hunk("a.lua", 2, 50), mk_hunk("b.lua", 1, 3) },
    files = { { path = "a.lua", status = "M" }, { path = "b.lua", status = "M" } },
    diff_text = "", diff_hash = "x",
  }
end

describe("classify.reconcile", function()
  it("assigns hunks, sweeps missed ones into Ungrouped", function()
    local groups = classify.reconcile(mk_inventory(), {
      { title = "Feature", hunk_ids = { "a.lua:1", "b.lua:1" } },
    })
    assert.equals(2, #groups)
    assert.equals("Feature", groups[1].title)
    assert.equals(2, #groups[1].hunks)
    assert.equals("Ungrouped", groups[2].title)
    assert.is_true(groups[2].is_ungrouped)
    assert.equals("a.lua:2", groups[2].hunks[1].id)
  end)

  it("drops hallucinated ids and deduplicates across groups", function()
    local groups = classify.reconcile(mk_inventory(), {
      { title = "G1", hunk_ids = { "a.lua:1", "ghost.lua:9" } },
      { title = "G2", hunk_ids = { "a.lua:1", "a.lua:2", "b.lua:1" } },
    })
    assert.equals(1, #groups[1].hunks) -- ghost dropped
    assert.equals(2, #groups[2].hunks) -- a.lua:1 kept in G1 only
  end)

  it("drops empty groups entirely", function()
    local groups = classify.reconcile(mk_inventory(), {
      { title = "Empty", hunk_ids = { "ghost:1" } },
      { title = "All", hunk_ids = { "a.lua:1", "a.lua:2", "b.lua:1" } },
    })
    assert.equals(1, #groups)
    assert.equals("All", groups[1].title)
  end)

  it("INVARIANT: union of groups == inventory for arbitrary assignments", function()
    local inv = mk_inventory()
    local cases = {
      {}, -- provider returned nothing
      { { title = "T", hunk_ids = {} } },
      { { title = "T" } }, -- hunk_ids missing entirely
      { { title = "A", hunk_ids = { "b.lua:1" } }, { title = "B", hunk_ids = { "b.lua:1", "zz:1" } } },
    }
    for _, raw in ipairs(cases) do
      local groups = classify.reconcile(inv, raw)
      local seen = {}
      for _, g in ipairs(groups) do
        for _, h in ipairs(g.hunks) do
          assert.is_nil(seen[h.id], "duplicate " .. h.id)
          seen[h.id] = true
        end
      end
      for _, h in ipairs(inv.hunks) do
        assert.is_true(seen[h.id], "missing " .. h.id)
      end
    end
  end)

  it("builds per-file entries ordered by diff order then start line", function()
    local groups = classify.reconcile(mk_inventory(), {
      { title = "T", hunk_ids = { "b.lua:1", "a.lua:2", "a.lua:1" } },
    })
    local files = groups[1].files
    assert.equals("a.lua", files[1].path)
    assert.equals(1, files[1].hunks[1].modified.start_line)
    assert.equals(50, files[1].hunks[2].modified.start_line)
    assert.equals("b.lua", files[2].path)
  end)
end)
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL (module not found)

- [ ] **Step 3: Implement**

`lua/intentdiff/classify.lua`:

```lua
local M = {}

--- Order a group's hunks by file (diff order), then by modified start line.
function M.group_files(hunks, files)
  local by_file = {}
  for _, h in ipairs(hunks) do
    by_file[h.file] = by_file[h.file] or {}
    table.insert(by_file[h.file], h)
  end
  local out = {}
  for _, f in ipairs(files) do
    local fh = by_file[f.path]
    if fh then
      table.sort(fh, function(x, y) return x.modified.start_line < y.modified.start_line end)
      out[#out + 1] = { path = f.path, status = f.status, old_path = f.old_path, hunks = fh }
    end
  end
  return out
end

--- Reconcile provider output against the inventory. Enforces the completeness
--- invariant: union of returned groups == inventory, exactly.
--- @return Group[]
function M.reconcile(inventory, raw_groups)
  local by_id, assigned = {}, {}
  for _, h in ipairs(inventory.hunks) do
    by_id[h.id] = h
  end
  local groups = {}
  for _, rg in ipairs(raw_groups or {}) do
    local hunks = {}
    for _, id in ipairs(rg.hunk_ids or {}) do
      if by_id[id] and not assigned[id] then -- drops hallucinated ids + duplicates
        assigned[id] = true
        hunks[#hunks + 1] = by_id[id]
      end
    end
    if #hunks > 0 then
      groups[#groups + 1] = { title = tostring(rg.title or "Untitled"), hunks = hunks }
    end
  end
  local ungrouped = {}
  for _, h in ipairs(inventory.hunks) do
    if not assigned[h.id] then
      ungrouped[#ungrouped + 1] = h
    end
  end
  if #ungrouped > 0 then
    groups[#groups + 1] = { title = "Ungrouped", hunks = ungrouped, is_ungrouped = true }
  end
  for _, g in ipairs(groups) do
    g.files = M.group_files(g.hunks, inventory.files)
  end
  return groups
end

return M
```

- [ ] **Step 4: Run to verify pass** — Expected: PASS

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: reconciliation with completeness invariant"`

---

### Task 5: Cache with stale re-match

**Files:**
- Create: `lua/intentdiff/cache.lua`, `tests/cache_spec.lua`

**Interfaces:**
- Consumes: `config.options.cache_dir`, Inventory.
- Produces: `cache.save(diff_hash, entry)`, `cache.load(diff_hash) -> entry|nil`, `cache.delete(diff_hash)`, `cache.rematch(entry, inventory) -> raw_groups, stale_count`. Entry shape: `{ groups = raw provider groups, hunk_hashes = { [hunk_id] = content_hash } }`.

- [ ] **Step 1: Write the failing tests**

`tests/cache_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL (module not found)

- [ ] **Step 3: Implement**

`lua/intentdiff/cache.lua`:

```lua
local M = {}

local function path_for(diff_hash)
  return require("intentdiff.config").options.cache_dir .. "/" .. diff_hash .. ".json"
end

function M.save(diff_hash, entry)
  vim.fn.mkdir(require("intentdiff.config").options.cache_dir, "p")
  vim.fn.writefile({ vim.json.encode(entry) }, path_for(diff_hash))
end

function M.load(diff_hash)
  local file = path_for(diff_hash)
  if vim.fn.filereadable(file) == 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
  if ok and type(decoded) == "table" and type(decoded.groups) == "table" then
    return decoded
  end
  return nil
end

function M.delete(diff_hash)
  vim.fn.delete(path_for(diff_hash))
end

--- Re-match a cached classification against a changed inventory. Hunks whose
--- content hash still exists keep their group (by new id); everything else is
--- left unassigned for reconcile() to sweep into Ungrouped.
--- @return table raw_groups, integer stale_count
function M.rematch(entry, inventory)
  local group_of_hash = {}
  for gi, g in ipairs(entry.groups) do
    for _, id in ipairs(g.hunk_ids or {}) do
      local hash = entry.hunk_hashes and entry.hunk_hashes[id]
      if hash then
        group_of_hash[hash] = gi
      end
    end
  end
  local raw = {}
  for gi, g in ipairs(entry.groups) do
    raw[gi] = { title = g.title, hunk_ids = {} }
  end
  local stale = 0
  for _, h in ipairs(inventory.hunks) do
    local gi = group_of_hash[h.content_hash]
    if gi then
      table.insert(raw[gi].hunk_ids, h.id)
    else
      stale = stale + 1
    end
  end
  return raw, stale
end

return M
```

- [ ] **Step 4: Run to verify pass** — Expected: PASS

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: diff-hash keyed cache with content-hash stale re-match"`

---

### Task 6: Default provider (`providers/claude_cli`)

**Files:**
- Create: `lua/intentdiff/providers/claude_cli.lua`, `tests/provider_claude_cli_spec.lua`
- Modify: `tests/helpers.lua` (add fake bin helper)

**Interfaces:**
- Consumes: provider contract from Global Constraints.
- Produces: `claude_cli.new(opts) -> provider_fn` (opts: `cmd`, `model`, `timeout_ms`); `claude_cli.build_prompt(request) -> string`; `claude_cli.parse_response(text) -> result|nil, err|nil`. Provider fn returns `{ cancel = function }`.

- [ ] **Step 1: Add fake-binary helper to `tests/helpers.lua`** (before `return M`)

```lua
--- Create an executable shell script named `name` that runs `body` (sh), and
--- prepend its dir to $PATH. Returns a restore function.
function M.fake_bin(name, body)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/" .. name
  vim.fn.writefile(vim.list_extend({ "#!/bin/sh" }, vim.split(body, "\n")), file)
  vim.fn.system({ "chmod", "+x", file })
  local old_path = vim.env.PATH
  vim.env.PATH = dir .. ":" .. old_path
  return function() vim.env.PATH = old_path end
end
```

- [ ] **Step 2: Write the failing tests**

`tests/provider_claude_cli_spec.lua`:

```lua
local claude_cli = require("intentdiff.providers.claude_cli")
local helpers = require("tests.helpers")

local REQUEST = {
  diff_text = "diff --git a/a.lua b/a.lua\n@@ -1,1 +1,1 @@\n-x\n+y\n",
  hunks = { { id = "a.lua:1", file = "a.lua", summary_lines = { "@@ -1,1 +1,1 @@", "-x", "+y" } } },
}

describe("claude_cli.build_prompt", function()
  it("includes ids, the JSON contract, and the diff", function()
    local prompt = claude_cli.build_prompt(REQUEST)
    assert.truthy(prompt:find("a.lua:1", 1, true))
    assert.truthy(prompt:find('"groups"', 1, true))
    assert.truthy(prompt:find("Full diff:", 1, true))
  end)

  it("omits diff body when diff_text is nil (summary mode)", function()
    local prompt = claude_cli.build_prompt({ diff_text = nil, hunks = REQUEST.hunks })
    assert.is_nil(prompt:find("Full diff:", 1, true))
  end)
end)

describe("claude_cli.parse_response", function()
  it("parses clean JSON", function()
    local r = claude_cli.parse_response('{"groups":[{"title":"T","hunk_ids":["a.lua:1"]}]}')
    assert.equals("T", r.groups[1].title)
  end)

  it("repairs fenced/prosed output", function()
    local r = claude_cli.parse_response('Sure!\n```json\n{"groups":[{"title":"T","hunk_ids":[]}]}\n```\n')
    assert.equals("T", r.groups[1].title)
  end)

  it("rejects garbage with an error", function()
    local r, err = claude_cli.parse_response("no json here")
    assert.is_nil(r)
    assert.truthy(err)
  end)
end)

describe("claude_cli provider", function()
  it("runs the CLI and returns parsed groups", function()
    local restore = helpers.fake_bin("claude", [[
cat > /dev/null
echo '{"groups":[{"title":"Fake","hunk_ids":["a.lua:1"]}]}']])
    local result, err
    claude_cli.new({ timeout_ms = 5000 })(REQUEST, function(r, e) result, err = r, e end)
    helpers.wait_for(function() return result or err end)
    restore()
    assert.is_nil(err)
    assert.equals("Fake", result.groups[1].title)
  end)

  it("reports non-zero exit as an error", function()
    local restore = helpers.fake_bin("claude", "cat > /dev/null\nexit 3")
    local err
    claude_cli.new({ timeout_ms = 5000 })(REQUEST, function(_, e) err = e end)
    helpers.wait_for(function() return err end)
    restore()
    assert.truthy(err:find("exited"))
  end)

  it("times out slow providers", function()
    local restore = helpers.fake_bin("claude", "sleep 30")
    local err
    claude_cli.new({ timeout_ms = 300 })(REQUEST, function(_, e) err = e end)
    helpers.wait_for(function() return err end, 5000)
    restore()
    assert.truthy(err:find("timed out"))
  end)

  it("cancel suppresses the callback", function()
    local restore = helpers.fake_bin("claude", "sleep 5\necho '{}'")
    local called = false
    local handle = claude_cli.new({ timeout_ms = 10000 })(REQUEST, function() called = true end)
    handle.cancel()
    vim.wait(500, function() return false end, 50)
    restore()
    assert.is_false(called)
  end)
end)
```

- [ ] **Step 3: Run to verify failure** — Expected: FAIL (module not found)

- [ ] **Step 4: Implement**

`lua/intentdiff/providers/claude_cli.lua`:

```lua
local M = {}

function M.build_prompt(request)
  local lines = {
    "You are grouping the hunks of a git diff by the REASON the change was made.",
    "Return ONLY JSON, no prose, exactly matching:",
    '{"groups":[{"title":"<short imperative reason>","hunk_ids":["<id>"]}]}',
    "Rules: every hunk id appears in exactly one group; prefer 2-8 groups;",
    "titles describe WHY (intent), not which files changed;",
    "use only the hunk ids listed below.",
    "",
    "Hunks:",
  }
  for _, h in ipairs(request.hunks) do
    lines[#lines + 1] = ("- %s"):format(h.id)
    for _, s in ipairs(h.summary_lines) do
      lines[#lines + 1] = "    " .. s
    end
  end
  if request.diff_text then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Full diff:"
    lines[#lines + 1] = request.diff_text
  end
  return table.concat(lines, "\n")
end

function M.parse_response(text)
  local body = text:match("({.*})") or text -- strips fences/prose; '.' spans newlines
  local ok, decoded = pcall(vim.json.decode, body)
  if ok and type(decoded) == "table" and type(decoded.groups) == "table" then
    return decoded
  end
  return nil, "provider returned unparseable output"
end

--- @return fun(request, callback): { cancel: function }
function M.new(opts)
  opts = opts or {}
  return function(request, callback)
    local finished = false
    local function finish(result, err)
      if not finished then
        finished = true
        callback(result, err)
      end
    end
    local stdout = {}
    local job = vim.fn.jobstart({ opts.cmd or "claude", "-p", "--model", opts.model or "haiku" }, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        stdout = data or {}
      end,
      on_exit = function(_, code)
        if code ~= 0 then
          return finish(nil, ("provider exited with code %d"):format(code))
        end
        finish(M.parse_response(table.concat(stdout, "\n")))
      end,
    })
    if job <= 0 then
      finish(nil, "could not start provider command '" .. (opts.cmd or "claude") .. "'")
      return { cancel = function() end }
    end
    vim.fn.chansend(job, M.build_prompt(request))
    vim.fn.chanclose(job, "stdin")
    vim.defer_fn(function()
      if not finished then
        vim.fn.jobstop(job)
        finish(nil, "provider timed out")
      end
    end, opts.timeout_ms or 60000)
    return {
      cancel = function()
        finished = true
        vim.fn.jobstop(job)
      end,
    }
  end
end

return M
```

- [ ] **Step 5: Run to verify pass** — Expected: PASS

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: claude CLI provider with timeout, repair, cancel"`

---

### Task 7: Classification orchestration (`classify.run`)

**Files:**
- Modify: `lua/intentdiff/classify.lua`
- Create: `tests/classify_run_spec.lua`

**Interfaces:**
- Consumes: `cache` (Task 5), `reconcile` (Task 4), provider contract, `config.options` (`max_full_diff_bytes`, `max_hunks`).
- Produces: `classify.build_request(inventory) -> request`; `classify.run(inventory, opts, callback)` where `opts = { provider: fun, force: boolean? }` and `callback(groups|nil, err|nil, info)` — `info = { cached: boolean?, stale_count: integer?, skipped: string? }`. Always called on main loop; a newer `run` supersedes (older callback never fires). Cache entry saved as `{ groups, hunk_hashes }`.

- [ ] **Step 1: Write the failing tests**

`tests/classify_run_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL (`attempt to call field 'run'`)

- [ ] **Step 3: Implement** (append to `lua/intentdiff/classify.lua`, before `return M`)

```lua
local run_token = 0

--- Build the provider request, honoring size thresholds.
function M.build_request(inventory)
  local cfg = require("intentdiff.config").options
  local hunks = {}
  for _, h in ipairs(inventory.hunks) do
    local all = vim.split(h.text, "\n", { trimempty = true })
    local summary = {}
    for i = 1, math.min(#all, 4) do
      summary[i] = all[i]
    end
    if #all > 4 then
      summary[#summary + 1] = ("… (%d more lines)"):format(#all - 4)
    end
    hunks[#hunks + 1] = { id = h.id, file = h.file, summary_lines = summary }
  end
  return {
    diff_text = #inventory.diff_text <= cfg.max_full_diff_bytes and inventory.diff_text or nil,
    hunks = hunks,
  }
end

--- Classify: cache → (rematch) → provider → reconcile. See task interface.
function M.run(inventory, opts, callback)
  local cache = require("intentdiff.cache")
  local cfg = require("intentdiff.config").options
  run_token = run_token + 1
  local token = run_token
  local function deliver(groups, err, info)
    vim.schedule(function()
      if token == run_token then
        callback(groups, err, info or {})
      end
    end)
  end

  if not opts.force then
    local entry = cache.load(inventory.diff_hash)
    if entry then
      return deliver(M.reconcile(inventory, entry.groups), nil, { cached = true })
    end
    if opts.previous_hash then
      local prev = cache.load(opts.previous_hash)
      if prev then
        local raw, stale = cache.rematch(prev, inventory)
        return deliver(M.reconcile(inventory, raw), nil, { cached = true, stale_count = stale })
      end
    end
  end

  if #inventory.hunks > cfg.max_hunks then
    return deliver(M.reconcile(inventory, {}), nil,
      { skipped = ("diff too large (%d hunks > %d)"):format(#inventory.hunks, cfg.max_hunks) })
  end

  opts.provider(M.build_request(inventory), function(result, err)
    vim.schedule(function()
      if token ~= run_token then
        return -- superseded by a newer run
      end
      if not result then
        return callback(nil, err or "provider failed", {})
      end
      local hunk_hashes = {}
      for _, h in ipairs(inventory.hunks) do
        hunk_hashes[h.id] = h.content_hash
      end
      cache.save(inventory.diff_hash, { groups = result.groups, hunk_hashes = hunk_hashes })
      callback(M.reconcile(inventory, result.groups), nil, {})
    end)
  end)
end
```

- [ ] **Step 4: Run to verify pass** — Expected: PASS

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: classification orchestration with cache, supersede, size caps"`

---

### Task 8: Sidebar

**Files:**
- Create: `lua/intentdiff/sidebar.lua`, `tests/sidebar_spec.lua`

**Interfaces:**
- Consumes: Model (types header), `config.options.sidebar_width`.
- Produces:
  - `sidebar.layout(model) -> lines: string[], meta: table[]` — pure; `meta[i] = { kind = "group"|"file"|"info"|"footer", group_i?, file_i? }`.
  - `sidebar.create(callbacks) -> handle` — opens the left split; `callbacks = { on_select = fun(group_i, file_i), on_toggle_group = fun(group_i), on_reclassify = fun(), on_close = fun(), on_next_group = fun(), on_prev_group = fun(), on_goto_file = fun(group_i, file_i) }`.
  - `handle.update(model)` re-renders; `handle.winid`, `handle.bufnr`; `handle.meta_at(lnum) -> meta`.
  - Sidebar keymaps: `<CR>` select, `za`/`h`/`l` toggle group, `r` reclassify, `gf` goto real file, `<Tab>`/`<S-Tab>` group jumps, `q` close.

- [ ] **Step 1: Write the failing tests**

`tests/sidebar_spec.lua`:

```lua
local sidebar = require("intentdiff.sidebar")

local function mk_model(overrides)
  local model = {
    state = "ready",
    total_hunks = 3,
    grouped_hunks = 3,
    provider_label = "claude:haiku",
    groups = {
      {
        title = "Add retry",
        hunks = { {}, {} },
        files = {
          { path = "src/http/client.lua", status = "M", hunks = { {} } },
          { path = "src/http/backoff.lua", status = "A", hunks = { {} } },
        },
      },
      {
        title = "Ungrouped", is_ungrouped = true,
        hunks = { {} },
        files = { { path = "misc.lua", status = "M", hunks = { {} } } },
      },
    },
  }
  return vim.tbl_deep_extend("force", model, overrides or {})
end

describe("sidebar.layout", function()
  it("renders group headers with counts and file children", function()
    local lines, meta = sidebar.layout(mk_model())
    assert.truthy(lines[1]:find("▾ Add retry"))
    assert.truthy(lines[1]:find("(2)", 1, true))
    assert.truthy(lines[2]:find("├ client.lua"))
    assert.truthy(lines[2]:find("src/http/", 1, true))
    assert.truthy(lines[3]:find("└ backoff.lua"))
    assert.same({ kind = "file", group_i = 1, file_i = 2 }, meta[3])
  end)

  it("collapses groups", function()
    local lines = sidebar.layout(mk_model({ groups = { [1] = { collapsed = true } } }))
    assert.truthy(lines[1]:find("▸ Add retry"))
    assert.truthy(lines[2]:find("▾ Ungrouped")) -- files of group 1 hidden
  end)

  it("shows loading state", function()
    local lines, meta = sidebar.layout({ state = "loading", groups = mk_model().groups,
      total_hunks = 3, grouped_hunks = 0 })
    assert.truthy(lines[1]:find("classifying"))
    assert.equals("info", meta[1].kind)
  end)

  it("shows footer with hunk accounting and provider", function()
    local lines = sidebar.layout(mk_model())
    local footer = lines[#lines]
    assert.truthy(footer:find("3/3 hunks", 1, true))
    assert.truthy(footer:find("claude:haiku", 1, true))
  end)

  it("shows warning message line when present", function()
    local lines = sidebar.layout(mk_model({ message = "classification failed: boom" }))
    assert.truthy(lines[1]:find("classification failed", 1, true))
  end)
end)

describe("sidebar.create", function()
  it("opens a split, renders, and routes <CR> to on_select", function()
    local selected
    local handle = sidebar.create({
      on_select = function(gi, fi) selected = { gi, fi } end,
      on_toggle_group = function() end, on_reclassify = function() end,
      on_close = function() end, on_next_group = function() end,
      on_prev_group = function() end, on_goto_file = function() end,
    })
    handle.update(mk_model())
    assert.is_true(vim.api.nvim_win_is_valid(handle.winid))
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 0 }) -- first file line
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert.same({ 1, 1 }, selected)
    vim.api.nvim_win_close(handle.winid, true)
  end)
end)
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL (module not found)

- [ ] **Step 3: Implement**

`lua/intentdiff/sidebar.lua`:

```lua
local M = {}

M.ns = vim.api.nvim_create_namespace("intentdiff_sidebar")

--- Pure layout: Model → buffer lines + per-line metadata.
function M.layout(model)
  local lines, meta = {}, {}
  local function add(text, m)
    lines[#lines + 1] = text
    meta[#lines] = m
  end
  if model.state == "loading" then
    add("⟳ classifying…", { kind = "info" })
  end
  if model.message then
    add("⚠ " .. model.message, { kind = "info" })
  end
  for gi, g in ipairs(model.groups or {}) do
    local marker = g.collapsed and "▸" or "▾"
    add(("%s %s  (%d)"):format(marker, g.title, #g.hunks), { kind = "group", group_i = gi })
    if not g.collapsed then
      for fi, f in ipairs(g.files) do
        local branch = fi == #g.files and "└" or "├"
        local name = f.path:match("([^/]+)$") or f.path
        local dir = f.path:sub(1, #f.path - #name)
        add(("  %s %s  %s%s"):format(branch, name, dir ~= "" and dir .. " " or "", f.status),
          { kind = "file", group_i = gi, file_i = fi })
      end
    end
  end
  if model.state == "ready" then
    local stale = (model.stale_count or 0) > 0
        and (" · stale — %d unclassified"):format(model.stale_count) or ""
    add(("%d/%d hunks · %s%s"):format(model.grouped_hunks, model.total_hunks,
      model.provider_label or "?", stale), { kind = "footer" })
  end
  return lines, meta
end

--- Open the sidebar split and wire keymaps. Returns a handle.
function M.create(callbacks)
  local width = require("intentdiff.config").options.sidebar_width
  vim.cmd("topleft " .. width .. "vsplit")
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "intentdiff"
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].winfixwidth = true
  vim.wo[winid].wrap = false

  local handle = { winid = winid, bufnr = bufnr, meta = {} }

  function handle.meta_at(lnum)
    return handle.meta[lnum]
  end

  function handle.update(model)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local lines, meta = M.layout(model)
    handle.meta = meta
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    for i, m in ipairs(meta) do
      local hl = ({ group = "Title", info = "WarningMsg", footer = "Comment" })[m.kind]
      if hl then
        vim.api.nvim_buf_set_extmark(bufnr, M.ns, i - 1, 0, { line_hl_group = hl })
      end
    end
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, nowait = true })
  end
  local function cursor_meta()
    return handle.meta_at(vim.api.nvim_win_get_cursor(winid)[1]) or {}
  end
  map("<CR>", function()
    local m = cursor_meta()
    if m.kind == "file" then
      callbacks.on_select(m.group_i, m.file_i)
    elseif m.kind == "group" then
      callbacks.on_toggle_group(m.group_i)
    end
  end)
  for _, key in ipairs({ "za", "h", "l" }) do
    map(key, function()
      local m = cursor_meta()
      if m.group_i then
        callbacks.on_toggle_group(m.group_i)
      end
    end)
  end
  map("r", callbacks.on_reclassify)
  map("q", callbacks.on_close)
  map("<Tab>", callbacks.on_next_group)
  map("<S-Tab>", callbacks.on_prev_group)
  map("gf", function()
    local m = cursor_meta()
    if m.kind == "file" then
      callbacks.on_goto_file(m.group_i, m.file_i)
    end
  end)

  return handle
end

return M
```

- [ ] **Step 4: Run to verify pass** — Expected: PASS

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: sidebar tree with layout, states, keymaps"`

---

### Task 9: codediff adapter (`view.lua`)

**Files:**
- Create: `lua/intentdiff/view.lua`, `tests/view_spec.lua`

This is the ONLY module that touches codediff. Verified against codediff's current internals:
- `codediff.ui.view` — `create(session_config, filetype, on_ready)`, `update(tabpage, session_config, jump)`, `toggle_layout(tabpage)`; `SessionConfig` needs `{ mode, git_root, original, modified, original_revision, modified_revision }`.
- `codediff.ui.view.compact.compute_visible_lines(changes, side, line_count, context_lines)` — pure; `changes[i] = { original = {start_line, end_line}, modified = {...} }` end-exclusive — exactly our Hunk ranges.
- `codediff.ui.lifecycle.get_session(tabpage)` → `{ original_win, modified_win, original_bufnr, modified_bufnr, stored_diff_result, modified = Path, original = Path, layout }`.
- `codediff.core.path.make_ref(rel_path, git_root)` → Path (`.absolute`).
- `codediff.core.git` — `resolve_revision(rev, git_root, cb)`, `get_merge_base(rev1, rev2, git_root, cb)`, `get_git_root_sync(file_path)`.
- Special statuses (mirroring `codediff.ui.explorer.render.on_file_select`): `??` → `side_by_side.show_untracked_file(tabpage, abs_path)`; `A` with base revision → `side_by_side.show_added_virtual_file(tabpage, git_root, path, target_revision)`; `D` → `side_by_side.show_deleted_virtual_file(tabpage, git_root, path, base_revision)`. These show the whole file (the whole file IS the change) — no folds applied.
- NOTE for implementer: `session_config.mode = "explorer"` is what codediff's own explorer passes to `view.update`; `panel.setup_explorer` no-ops without `explorer_data`. If that assumption fails in the integration test, use `mode = "standalone"` — decide by test result, do not add compat shims.

**Interfaces:**
- Consumes: Hunk ranges (Task 2), config `context_lines`.
- Produces:
  - `view.load() -> boolean` — pcall-require everything, verify function types, notify + return false on mismatch. Sets `view.available`.
  - `view.open_tab() -> tabpage` — `tabnew` returning new tabpage id.
  - `view.show_file(sess, file_entry, opts)` — `sess = { tabpage, git_root, base_revision, target_revision, view_created }`; renders the file diff (create on first call, update after), then applies group folds; `opts = { on_ready = fun()? }`.
  - `view.apply_group_folds(tabpage, hunks) -> boolean`
  - `view.foldexpr()` — referenced as `v:lua.require'intentdiff.view'.foldexpr()`.
  - `view.toggle_layout(sess, current_hunks)` — toggles and re-applies folds.
  - `view.close_tab(sess)`.

- [ ] **Step 1: Write the failing tests**

`tests/view_spec.lua`:

```lua
local helpers = require("tests.helpers")

describe("view adapter", function()
  local view

  before_each(function()
    package.loaded["intentdiff.view"] = nil
    view = require("intentdiff.view")
  end)

  it("loads codediff internals", function()
    assert.is_true(view.load())
    assert.is_true(view.available)
  end)

  it("shows a modified file and folds away non-group hunks", function()
    assert.is_true(view.load())
    -- 60-line file with two edits far apart → two hunks
    local lines = {}
    for i = 1, 60 do lines[i] = "line " .. i end
    local repo = helpers.make_repo({ ["big.lua"] = table.concat(lines, "\n") })
    lines[5] = "CHANGED 5"
    lines[55] = "CHANGED 55"
    helpers.write_file(repo, "big.lua", table.concat(lines, "\n"))

    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)
    assert.equals(2, #inv.hunks)

    local git = require("codediff.core.git")
    local base
    git.resolve_revision("HEAD", repo, function(_, hash) base = hash end)
    helpers.wait_for(function() return base end)

    local sess = { tabpage = view.open_tab(), git_root = repo, base_revision = base,
      target_revision = "WORKING" }
    local ready = false
    -- group = ONLY the first hunk (line 5 area)
    view.show_file(sess, { path = "big.lua", status = "M", hunks = { inv.hunks[1] } },
      { on_ready = function() ready = true end })
    helpers.wait_for(function() return ready end, 10000)

    local session = require("codediff.ui.lifecycle").get_session(sess.tabpage)
    assert.truthy(session)
    local win = session.modified_win
    assert.equals("expr", vim.wo[win].foldmethod)
    -- line 5 (group hunk) visible; line 55 (other hunk) folded
    assert.equals(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(5) end))
    assert.is_true(vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(55) end) > 0)
    view.close_tab(sess)
  end)

  it("apply_group_folds returns false without a codediff session", function()
    assert.is_true(view.load())
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    assert.is_false(view.apply_group_folds(tab, {}))
    vim.cmd("tabclose")
  end)
end)
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL (module not found)

- [ ] **Step 3: Implement**

`lua/intentdiff/view.lua`:

```lua
-- The ONLY module allowed to require codediff internals. Everything is
-- pcall-guarded; on any mismatch the plugin degrades instead of erroring.
local M = {}

M.available = false
local cd = {} -- loaded codediff modules

local function try(name)
  local ok, mod = pcall(require, name)
  return ok and mod or nil
end

--- Load and verify codediff internals. Call once at :IntentDiff time.
function M.load()
  cd.view = try("codediff.ui.view")
  cd.compact = try("codediff.ui.view.compact")
  cd.lifecycle = try("codediff.ui.lifecycle")
  cd.git = try("codediff.core.git")
  cd.path = try("codediff.core.path")
  cd.side_by_side = try("codediff.ui.view.side_by_side")
  M.available = cd.view ~= nil
    and type(cd.view.create) == "function"
    and type(cd.view.update) == "function"
    and type(cd.view.toggle_layout) == "function"
    and cd.compact ~= nil
    and type(cd.compact.compute_visible_lines) == "function"
    and cd.lifecycle ~= nil
    and type(cd.lifecycle.get_session) == "function"
    and cd.git ~= nil
    and cd.path ~= nil
    and type(cd.path.make_ref) == "function"
    and cd.side_by_side ~= nil
  if not M.available then
    vim.notify("intent-diff: codediff API mismatch — grouped view disabled", vim.log.levels.ERROR)
  end
  return M.available
end

function M.git()
  return cd.git
end

-- ---------------------------------------------------------------- folds ----

local visible_by_win = {}

function M.foldexpr()
  local visible = visible_by_win[vim.api.nvim_get_current_win()]
  if not visible then
    return "0"
  end
  return visible[vim.v.lnum] and "0" or "1"
end

local function context_lines()
  local ours = require("intentdiff.config").options.context_lines
  if ours then
    return ours
  end
  local cd_config = try("codediff.config")
  return cd_config and cd_config.options.diff.compact_context_lines or 3
end

--- Fold everything except `hunks`' ranges (+context) in both panes.
function M.apply_group_folds(tabpage, hunks)
  local session = cd.lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end
  local changes = {}
  for i, h in ipairs(hunks) do
    changes[i] = { original = h.original, modified = h.modified }
  end
  local ctx = context_lines()
  local panes = {
    { win = session.original_win, buf = session.original_bufnr, side = "original" },
    { win = session.modified_win, buf = session.modified_bufnr, side = "modified" },
  }
  for _, pane in ipairs(panes) do
    if pane.win and vim.api.nvim_win_is_valid(pane.win)
        and pane.buf and vim.api.nvim_buf_is_valid(pane.buf) then
      local line_count = vim.api.nvim_buf_line_count(pane.buf)
      visible_by_win[pane.win] =
        cd.compact.compute_visible_lines(changes, pane.side, line_count, ctx)
      vim.wo[pane.win].foldmethod = "expr"
      vim.wo[pane.win].foldexpr = "v:lua.require'intentdiff.view'.foldexpr()"
      vim.wo[pane.win].foldlevel = 0
      vim.wo[pane.win].foldminlines = 0
      vim.wo[pane.win].foldenable = true
    end
  end
  return true
end

-- ----------------------------------------------------------- view driving --

--- Poll until codediff has the diff for `abs_path` ready in `tabpage`.
local function when_diff_ready(tabpage, abs_path, cb, tries)
  tries = tries or 0
  local session = cd.lifecycle.get_session(tabpage)
  if session and session.stored_diff_result
      and ((session.modified and session.modified.absolute == abs_path)
        or (session.original and session.original.absolute == abs_path)) then
    return cb()
  end
  if tries > 60 then
    return -- give up after ~3s; folds simply not applied
  end
  vim.defer_fn(function()
    when_diff_ready(tabpage, abs_path, cb, tries + 1)
  end, 50)
end

function M.open_tab()
  vim.cmd("tabnew")
  return vim.api.nvim_get_current_tabpage()
end

function M.close_tab(sess)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab == sess.tabpage then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose")
      return
    end
  end
end

--- Render file_entry's diff and fold to its hunks.
--- sess = { tabpage, git_root, base_revision, target_revision, view_created }
function M.show_file(sess, file_entry, opts)
  opts = opts or {}
  local tabpage = sess.tabpage
  local abs_path = sess.git_root .. "/" .. file_entry.path

  -- Whole-file statuses: the entire file is the change — no folds needed.
  if file_entry.status == "??" then
    cd.side_by_side.show_untracked_file(tabpage, abs_path)
    if opts.on_ready then vim.schedule(opts.on_ready) end
    return
  end
  if file_entry.status == "A" then
    cd.side_by_side.show_added_virtual_file(
      tabpage, sess.git_root, file_entry.path, sess.target_revision or "WORKING")
    if opts.on_ready then vim.schedule(opts.on_ready) end
    return
  end
  if file_entry.status == "D" then
    cd.side_by_side.show_deleted_virtual_file(
      tabpage, sess.git_root, file_entry.path, sess.base_revision)
    if opts.on_ready then vim.schedule(opts.on_ready) end
    return
  end

  ---@type table SessionConfig (codediff)
  local session_config = {
    mode = "explorer",
    git_root = sess.git_root,
    original = cd.path.make_ref(file_entry.old_path or file_entry.path, sess.git_root),
    modified = cd.path.make_ref(file_entry.path, sess.git_root),
    original_revision = sess.base_revision,
    modified_revision = sess.target_revision or "WORKING",
  }
  if not sess.view_created then
    sess.view_created = true
    cd.view.create(session_config, nil, nil)
  else
    cd.view.update(tabpage, session_config, false)
  end
  when_diff_ready(tabpage, abs_path, function()
    M.apply_group_folds(tabpage, file_entry.hunks)
    if opts.on_ready then
      opts.on_ready()
    end
  end)
end

--- Toggle inline/side-by-side, then re-apply the group filter.
function M.toggle_layout(sess, current_hunks)
  cd.view.toggle_layout(sess.tabpage)
  vim.defer_fn(function()
    M.apply_group_folds(sess.tabpage, current_hunks or {})
  end, 100)
end

--- Windows of the current diff panes (for keymap installation).
function M.diff_wins(tabpage)
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return {}
  end
  local wins = {}
  for _, w in ipairs({ session.original_win, session.modified_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      wins[#wins + 1] = w
    end
  end
  return wins
end

function M.get_session(tabpage)
  return cd.lifecycle.get_session(tabpage)
end

return M
```

- [ ] **Step 4: Run to verify pass** — Expected: PASS. If the fold assertion fails because `view.create` opened windows unexpectedly, check the NOTE above (explorer vs standalone mode) before anything else.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: codediff adapter with group-filtered folds"`

---

### Task 10: Group-scoped navigation

**Files:**
- Create: `lua/intentdiff/navigation.lua`, `tests/navigation_spec.lua`

**Interfaces:**
- Consumes: `view.diff_wins`, `view.get_session`, Group/Model types.
- Produces:
  - `navigation.attach(tabpage, ctx)` — `ctx = { model: Model, group_i: integer, file_i: integer, select_file = fun(group_i, file_i, opts?) }`; stores per-tabpage state and installs `]c`/`[c` buffer-local maps on current diff pane buffers.
  - `navigation.next_hunk(tabpage)` / `navigation.prev_hunk(tabpage)` — jump between the CURRENT GROUP's hunks (modified-side start lines); past the last hunk of a file → `select_file` of the group's next file (and jump to its first hunk via `opts = { jump = "first" }`; prev wraps to previous file's last hunk with `{ jump = "last" }`). No wrap across groups.
  - `navigation.detach(tabpage)`.

- [ ] **Step 1: Write the failing tests** — pure-logic tests plus a jump test against fake windows:

`tests/navigation_spec.lua`:

```lua
local navigation = require("intentdiff.navigation")

local function mk_hunk(line)
  return { modified = { start_line = line, end_line = line + 1 },
           original = { start_line = line, end_line = line + 1 } }
end

describe("navigation.plan_move", function()
  -- plan_move(file_entries, file_i, cursor_line, dir) -> { line = n } | { file_i = n, jump = "first"|"last" } | nil
  local files = {
    { path = "a.lua", hunks = { mk_hunk(5), mk_hunk(50) } },
    { path = "b.lua", hunks = { mk_hunk(10) } },
  }

  it("moves to the next hunk within the file", function()
    assert.same({ line = 50 }, navigation.plan_move(files, 1, 5, 1))
  end)

  it("rolls over to the next file after the last hunk", function()
    assert.same({ file_i = 2, jump = "first" }, navigation.plan_move(files, 1, 50, 1))
  end)

  it("moves back within the file", function()
    assert.same({ line = 5 }, navigation.plan_move(files, 1, 50, -1))
  end)

  it("rolls back to the previous file before the first hunk", function()
    assert.same({ file_i = 1, jump = "last" }, navigation.plan_move(files, 2, 10, -1))
  end)

  it("returns nil at the group's boundaries", function()
    assert.is_nil(navigation.plan_move(files, 2, 10, 1))
    assert.is_nil(navigation.plan_move(files, 1, 5, -1))
  end)
end)
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL

- [ ] **Step 3: Implement**

`lua/intentdiff/navigation.lua`:

```lua
local M = {}

local state = {} -- [tabpage] = ctx

--- Decide the next move within a group. Pure.
--- @param file_entries table[] group.files
--- @param file_i integer current file index
--- @param cursor_line integer cursor line in the modified pane
--- @param dir 1|-1
--- @return { line: integer }|{ file_i: integer, jump: "first"|"last" }|nil
function M.plan_move(file_entries, file_i, cursor_line, dir)
  local hunks = file_entries[file_i].hunks
  if dir == 1 then
    for _, h in ipairs(hunks) do
      if h.modified.start_line > cursor_line then
        return { line = h.modified.start_line }
      end
    end
    if file_entries[file_i + 1] then
      return { file_i = file_i + 1, jump = "first" }
    end
  else
    for i = #hunks, 1, -1 do
      if hunks[i].modified.start_line < cursor_line then
        return { line = hunks[i].modified.start_line }
      end
    end
    if file_i > 1 then
      return { file_i = file_i - 1, jump = "last" }
    end
  end
  return nil
end

local function move(tabpage, dir)
  local ctx = state[tabpage]
  if not ctx then
    return
  end
  local group = ctx.model.groups[ctx.group_i]
  if not group then
    return
  end
  local session = require("intentdiff.view").get_session(tabpage)
  local win = session and session.modified_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  local plan = M.plan_move(group.files, ctx.file_i, cursor_line, dir)
  if not plan then
    return
  end
  if plan.line then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { plan.line, 0 })
  else
    ctx.file_i = plan.file_i
    ctx.select_file(ctx.group_i, plan.file_i, { jump = plan.jump })
  end
end

function M.next_hunk(tabpage)
  move(tabpage or vim.api.nvim_get_current_tabpage(), 1)
end

function M.prev_hunk(tabpage)
  move(tabpage or vim.api.nvim_get_current_tabpage(), -1)
end

--- Install per-tabpage state and buffer-local ]c/[c on the diff pane buffers.
function M.attach(tabpage, ctx)
  state[tabpage] = ctx
  for _, win in ipairs(require("intentdiff.view").diff_wins(tabpage)) do
    local buf = vim.api.nvim_win_get_buf(win)
    vim.keymap.set("n", "]c", function() M.next_hunk(tabpage) end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "[c", function() M.prev_hunk(tabpage) end, { buffer = buf, nowait = true })
  end
end

function M.detach(tabpage)
  state[tabpage] = nil
end

--- Update current position without reinstalling keymaps.
function M.set_position(tabpage, group_i, file_i)
  local ctx = state[tabpage]
  if ctx then
    ctx.group_i, ctx.file_i = group_i, file_i
  end
end

return M
```

- [ ] **Step 4: Run to verify pass** — Expected: PASS

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: group-scoped hunk navigation with cross-file rollover"`

---

### Task 11: `:IntentDiff` command and orchestration

**Files:**
- Create: `plugin/intentdiff.lua`, `tests/integration_spec.lua`
- Modify: `lua/intentdiff/init.lua`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `:IntentDiff` (working tree vs HEAD), `:IntentDiff <rev>` (working tree vs rev), `:IntentDiff <rev>...` (merge-base of rev and HEAD), `:IntentDiff <rev1> <rev2>`.
  - `require("intentdiff").open(argline)`; `require("intentdiff").close(tabpage)`.
  - `require("intentdiff")._session(tabpage)` for tests: `{ model, sess, sidebar }`.
  - `config.options.provider` may be a function (used directly as provider) — tests inject fakes this way.

- [ ] **Step 1: Write the failing integration test**

`tests/integration_spec.lua`:

```lua
local helpers = require("tests.helpers")

describe(":IntentDiff end-to-end", function()
  local repo

  local function fake_provider(groups)
    return function(_, cb)
      vim.schedule(function() cb({ groups = groups }) end)
      return { cancel = function() end }
    end
  end

  before_each(function()
    repo = helpers.make_repo({
      ["a.lua"] = table.concat(vim.fn.range(1, 40), "\n"),
      ["b.lua"] = "x",
    })
    helpers.write_file(repo, "a.lua",
      "CHANGED\n" .. table.concat(vim.fn.range(2, 39), "\n") .. "\nCHANGED")
    helpers.write_file(repo, "b.lua", "y")
    vim.cmd("cd " .. repo)
  end)

  after_each(function()
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if #vim.api.nvim_list_tabpages() > 1 then
        pcall(vim.cmd, "tabclose $")
      end
    end
  end)

  it("opens, classifies, groups the sidebar, and shows partial diffs", function()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({
        { title = "First edit", hunk_ids = { "a.lua:1", "b.lua:1" } },
        -- a.lua:2 intentionally missed → must land in Ungrouped
      }),
    })
    require("intentdiff").open("")

    local intentdiff = require("intentdiff")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = intentdiff._session(tab)
      return s and s.model.state == "ready" and s or nil
    end, 10000)

    assert.equals(2, #session.model.groups)
    assert.equals("First edit", session.model.groups[1].title)
    assert.equals("Ungrouped", session.model.groups[2].title)
    assert.equals(3, session.model.total_hunks)

    local lines = vim.api.nvim_buf_get_lines(session.sidebar.bufnr, 0, -1, false)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("First edit", 1, true))
    assert.truthy(text:find("Ungrouped", 1, true))
    assert.truthy(text:find("3/3 hunks", 1, true))
  end)

  it("provider failure degrades to flat list with a message", function()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = function(_, cb)
        vim.schedule(function() cb(nil, "boom") end)
        return { cancel = function() end }
      end,
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model.message and s or nil
    end, 10000)
    assert.truthy(session.model.message:find("boom", 1, true))
    -- flat fallback: single group containing every hunk
    assert.equals(1, #session.model.groups)
    assert.equals(3, #session.model.groups[1].hunks)
  end)
end)
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL (`attempt to call field 'open'`)

- [ ] **Step 3: Implement**

`plugin/intentdiff.lua`:

```lua
if vim.g.loaded_intentdiff then
  return
end
vim.g.loaded_intentdiff = true

vim.api.nvim_create_user_command("IntentDiff", function(cmd)
  require("intentdiff").open(cmd.args)
end, { nargs = "*", desc = "Grouped-by-reason diff review" })
```

Replace `lua/intentdiff/init.lua`:

```lua
local M = {}

local sessions = {} -- [tabpage] = { sess, model, sidebar, inventory }

function M.setup(opts)
  require("intentdiff.config").setup(opts)
end

function M._session(tabpage)
  return sessions[tabpage]
end

local function resolve_provider()
  local cfg = require("intentdiff.config").options
  if type(cfg.provider) == "function" then
    return cfg.provider, "custom"
  end
  local mod = require("intentdiff.providers." .. cfg.provider)
  local label = ("%s:%s"):format(cfg.provider_opts.cmd or cfg.provider, cfg.provider_opts.model or "?")
  return mod.new(cfg.provider_opts), label
end

--- Flat single-group model used while loading and on provider failure.
local function flat_model(inventory, state, message)
  local classify = require("intentdiff.classify")
  local groups = {}
  if #inventory.hunks > 0 then
    groups[1] = {
      title = "All changes",
      hunks = inventory.hunks,
      files = classify.group_files(inventory.hunks, inventory.files),
    }
  end
  return {
    state = state,
    groups = groups,
    total_hunks = #inventory.hunks,
    grouped_hunks = 0,
    message = message,
  }
end

local function grouped_model(inventory, groups, info, provider_label)
  local grouped = 0
  for _, g in ipairs(groups) do
    if not g.is_ungrouped then
      grouped = grouped + #g.hunks
    end
  end
  return {
    state = "ready",
    groups = groups,
    total_hunks = #inventory.hunks,
    grouped_hunks = grouped,
    stale_count = info and info.stale_count,
    provider_label = provider_label,
    message = info and info.skipped,
  }
end

--- Parse :IntentDiff args → collect opts. cb(collect_opts, base_for_view)
local function resolve_args(argline, git_root, cb)
  local view = require("intentdiff.view")
  local args = vim.split(vim.trim(argline or ""), "%s+", { trimempty = true })
  if #args == 0 then
    return cb({ git_root = git_root }, "HEAD")
  end
  if #args == 2 then
    return cb({ git_root = git_root, base = args[1], target = args[2] }, args[1], args[2])
  end
  local rev = args[1]
  local three_dot = rev:match("^(.-)%.%.%.$")
  if three_dot then
    view.git().get_merge_base(three_dot, "HEAD", git_root, function(err, mb)
      if err or not mb then
        return vim.schedule(function()
          vim.notify("intent-diff: cannot resolve merge-base of " .. three_dot, vim.log.levels.ERROR)
        end)
      end
      cb({ git_root = git_root, base = mb }, mb)
    end)
    return
  end
  cb({ git_root = git_root, base = rev }, rev)
end

local function classify_and_render(tabpage, opts)
  local classify = require("intentdiff.classify")
  local entry = sessions[tabpage]
  if not entry then
    return
  end
  local provider, label = resolve_provider()
  entry.model = flat_model(entry.inventory, "loading")
  entry.sidebar.update(entry.model)
  classify.run(entry.inventory, {
    provider = provider,
    force = opts and opts.force,
  }, function(groups, err, info)
    local current = sessions[tabpage]
    if not current or current.inventory ~= entry.inventory then
      return -- session closed or refreshed since
    end
    if not groups then
      current.model = flat_model(current.inventory, "ready",
        "classification failed: " .. tostring(err) .. " — flat list; r to retry")
    else
      current.model = grouped_model(current.inventory, groups, info, label)
    end
    current.sidebar.update(current.model)
  end)
end

local function select_file(tabpage, group_i, file_i, opts)
  local entry = sessions[tabpage]
  if not entry then
    return
  end
  local group = entry.model.groups[group_i]
  local file_entry = group and group.files[file_i]
  if not file_entry then
    return
  end
  local navigation = require("intentdiff.navigation")
  navigation.set_position(tabpage, group_i, file_i)
  require("intentdiff.view").show_file(entry.sess, file_entry, {
    on_ready = function()
      navigation.attach(tabpage, {
        model = entry.model,
        group_i = group_i,
        file_i = file_i,
        select_file = function(gi, fi, o)
          select_file(tabpage, gi, fi, o)
        end,
      })
      local session = require("intentdiff.view").get_session(tabpage)
      local win = session and session.modified_win
      if opts and opts.jump and win and vim.api.nvim_win_is_valid(win) and #file_entry.hunks > 0 then
        local h = opts.jump == "last" and file_entry.hunks[#file_entry.hunks] or file_entry.hunks[1]
        pcall(vim.api.nvim_win_set_cursor, win, { h.modified.start_line, 0 })
      end
    end,
  })
end

function M.close(tabpage)
  local entry = sessions[tabpage]
  if not entry then
    return
  end
  sessions[tabpage] = nil
  require("intentdiff.navigation").detach(tabpage)
  require("intentdiff.view").close_tab(entry.sess)
end

function M.open(argline)
  local view = require("intentdiff.view")
  if not view.load() then
    return
  end
  local git_root = view.git().get_git_root_sync(vim.fn.expand("%:p") ~= "" and vim.fn.expand("%:p")
    or vim.fn.getcwd())
  if not git_root then
    return vim.notify("intent-diff: not inside a git repository", vim.log.levels.ERROR)
  end

  resolve_args(argline, git_root, function(collect_opts, base_rev, target_rev)
    require("intentdiff.hunks").collect(collect_opts, function(inventory, err)
      if not inventory then
        return vim.notify("intent-diff: " .. err, vim.log.levels.ERROR)
      end
      if #inventory.hunks == 0 then
        return vim.notify("intent-diff: no changes", vim.log.levels.INFO)
      end
      view.git().resolve_revision(base_rev, git_root, function(rev_err, base_hash)
        vim.schedule(function()
          if rev_err then
            return vim.notify("intent-diff: " .. rev_err, vim.log.levels.ERROR)
          end
          local tabpage = view.open_tab()
          local sess = {
            tabpage = tabpage,
            git_root = git_root,
            base_revision = base_hash,
            target_revision = target_rev or "WORKING",
          }
          local sidebar = require("intentdiff.sidebar").create({
            on_select = function(gi, fi) select_file(tabpage, gi, fi) end,
            on_toggle_group = function(gi)
              local entry = sessions[tabpage]
              local g = entry and entry.model.groups[gi]
              if g then
                g.collapsed = not g.collapsed
                entry.sidebar.update(entry.model)
              end
            end,
            on_reclassify = function()
              local entry = sessions[tabpage]
              if entry then
                require("intentdiff.cache").delete(entry.inventory.diff_hash)
                classify_and_render(tabpage, { force = true })
              end
            end,
            on_close = function() M.close(tabpage) end,
            on_next_group = function()
              local entry = sessions[tabpage]
              if entry and entry.model.groups[1] then
                -- jump cursor to next group header line
                local cur = vim.api.nvim_win_get_cursor(entry.sidebar.winid)[1]
                for l = cur + 1, vim.api.nvim_buf_line_count(entry.sidebar.bufnr) do
                  if (entry.sidebar.meta_at(l) or {}).kind == "group" then
                    vim.api.nvim_win_set_cursor(entry.sidebar.winid, { l, 0 })
                    break
                  end
                end
              end
            end,
            on_prev_group = function()
              local entry = sessions[tabpage]
              if entry then
                local cur = vim.api.nvim_win_get_cursor(entry.sidebar.winid)[1]
                for l = cur - 1, 1, -1 do
                  if (entry.sidebar.meta_at(l) or {}).kind == "group" then
                    vim.api.nvim_win_set_cursor(entry.sidebar.winid, { l, 0 })
                    break
                  end
                end
              end
            end,
            on_goto_file = function(gi, fi)
              local entry = sessions[tabpage]
              local f = entry and entry.model.groups[gi] and entry.model.groups[gi].files[fi]
              if f then
                M.close(tabpage)
                vim.cmd("edit " .. vim.fn.fnameescape(git_root .. "/" .. f.path))
                if f.hunks[1] then
                  pcall(vim.api.nvim_win_set_cursor, 0, { f.hunks[1].modified.start_line, 0 })
                end
              end
            end,
          })
          sessions[tabpage] = { sess = sess, sidebar = sidebar, inventory = inventory }
          vim.cmd("wincmd l") -- focus the (future) diff area right of the sidebar
          classify_and_render(tabpage)
        end)
      end)
    end)
  end)
end

return M
```

- [ ] **Step 4: Run to verify pass** — `./tests/run_tests.sh` — Expected: ALL tests pass (all spec files).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: :IntentDiff command wiring sidebar, classify, view"`

---

### Task 12: README, dotfiles integration, manual smoke test

**Files:**
- Create: `README.md`
- Create: `/Users/jfojtl/.config/nvim/lua/plugins/intentdiff.lua`
- Modify: `/Users/jfojtl/.config/nvim/lua/plugins/codediff.lua` (remove the three diff keymaps, keep history)

- [ ] **Step 1: Write README.md**

Contents: what it is (one paragraph + sidebar ASCII art from the spec), requirements (Neovim ≥ 0.10, codediff.nvim, `claude` CLI on PATH), lazy.nvim install snippet, config defaults table (copy `config.defaults` with comments), provider-swap example (a custom `provider = function(request, callback) ... end`), keymap table (sidebar + `]c`/`[c`), and this manual smoke checklist:

```markdown
## Manual smoke test (real LLM)

1. In a repo with a multi-purpose dirty working tree, run `:IntentDiff`.
2. Sidebar shows flat "All changes" + `⟳ classifying…`, then regroups within ~5s.
3. Footer shows `N/N hunks` — total must equal the hunk count of `git diff HEAD` + untracked files.
4. Open a file in a group: unrelated hunks are folded; `zo` peeks at them.
5. `]c` at the last hunk of a file jumps to the group's next file.
6. Toggle inline view (codediff's key) — folds still filter to the group.
7. `r` re-classifies; a second `:IntentDiff` on the same diff is instant (cache).
```

- [ ] **Step 2: Create the lazy.nvim spec in dotfiles**

`/Users/jfojtl/.config/nvim/lua/plugins/intentdiff.lua`:

```lua
-- intent-diff.nvim — grouped-by-reason diff review on top of codediff.
-- Takes over the three diff keymaps from codediff (<leader>gVv/gVH/gVb);
-- codediff keeps history (<leader>gVh/gVl).
local function default_branch()
  local ref = vim.fn.systemlist("git rev-parse --abbrev-ref origin/HEAD")[1]
  if vim.v.shell_error == 0 and ref and ref ~= "" then
    return ref:gsub("^origin/", "")
  end
  for _, name in ipairs({ "main", "master", "develop" }) do
    vim.fn.system("git rev-parse --verify --quiet " .. name)
    if vim.v.shell_error == 0 then
      return name
    end
  end
  return "HEAD"
end

return {
  {
    dir = "~/dev/github.com/jfojtl/intent-diff.nvim",
    name = "intent-diff.nvim",
    dependencies = { "esmuellert/codediff.nvim" },
    cmd = "IntentDiff",
    opts = {},
    keys = {
      { "<leader>gVv", "<cmd>IntentDiff<cr>", desc = "IntentDiff: working tree" },
      { "<leader>gVH", "<cmd>IntentDiff HEAD~1<cr>", desc = "IntentDiff: vs previous commit" },
      {
        "<leader>gVb",
        function()
          vim.cmd("IntentDiff " .. default_branch() .. "...")
        end,
        desc = "IntentDiff: branch vs default (merge-base)",
      },
    },
  },
}
```

- [ ] **Step 3: Remove the three replaced keymaps from `codediff.lua`**

In `/Users/jfojtl/.config/nvim/lua/plugins/codediff.lua`, delete the `<leader>gVv`, `<leader>gVH`, and `<leader>gVb` entries from `keys` (keep `cmd = "CodeDiff"`, `opts`, and the three history keymaps). Update the header comment to note diff keymaps moved to intent-diff.

- [ ] **Step 4: Run the manual smoke checklist** from the README in a real repo with the real `claude` CLI. Fix whatever it surfaces before calling the task done.

- [ ] **Step 5: Commit both repos**

```bash
cd ~/dev/github.com/jfojtl/intent-diff.nvim && git add -A && git commit -m "docs: README with install, config, smoke checklist"
cd ~/.config/nvim && git add lua/plugins/intentdiff.lua lua/plugins/codediff.lua && git commit -m "feat: switch diff keymaps to intent-diff.nvim"
```

---

## Self-Review Notes

- Spec coverage: classifier (T6/T7), companion plugin + coupling boundary (T9), diff scopes incl. merge-base (T11), sidebar UX + loading/failure states (T8/T11), partial diffs via folds + inline toggle re-apply (T9), group navigation with rollover (T10), cache + stale re-match (T5/T7), completeness invariant (T4), size thresholds (T7), keymap replacement + history untouched (T12). Out-of-scope items from the spec are not implemented anywhere. ✓
- Deliberate deviations from spec wording: staleness is handled at `classify.run` time via `previous_hash` rematch (no live `[stale]` indicator on buffer edits mid-session — YAGNI for v1, re-run `:IntentDiff` or `r` instead); inline-toggle fold re-apply uses codediff's own toggle key on the pane plus `view.toggle_layout` for programmatic use.
- Type consistency: `Hunk.original/modified` end-exclusive ranges flow unchanged from `hunks.parse` → `compute_visible_lines` (verified same convention in codediff source) → `navigation.plan_move`. Provider shape `{groups=[{title,hunk_ids}]}` used identically in T6/T7/T11 tests. ✓
