local M = {}

M.defaults = {
  provider = "claude_cli", -- name under intentdiff.providers.*, or a function(request, callback)
  provider_opts = {
    cmd = "claude",
    model = "haiku",
    timeout_ms = 180000,
    -- Tool restrictions passed to `claude -p` as --disallowedTools /
    -- --allowedTools: the process runs pointed at the user's (possibly
    -- uncommitted) working tree, so it must not be able to edit it. An
    -- empty/nil list omits the corresponding flag entirely rather than
    -- passing an empty value.
    disallowed_tools = { "Edit", "Write", "NotebookEdit" },
    allowed_tools = {
      "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
      "Bash(git blame:*)", "Bash(git status:*)", "Read", "Grep", "Glob",
    },
    -- Let the model run read-only git commands / read files in the repo
    -- (cwd is set to git_root) to understand WHY a change was made, instead
    -- of us pre-stuffing commit messages/log output into the prompt. Set to
    -- false to keep the prompt fully self-contained.
    agentic = true,
  },
  context_lines = 3, -- lines of context kept around each visible hunk when folding
  -- Above this many lines on either side, a file falls back to hunks-only
  -- rendering instead of the whole file, stating why on its separator.
  -- Replaces the old preview.max_lines, which capped a preview's total
  -- output length instead of any one file's size.
  line_budget = 20000,
  sidebar_width = 40,
  -- Wrap long lines in the diff panes. OFF, because the whole side-by-side
  -- design rests on row N left being row N right: a changed line that is 40
  -- characters on one side and 200 on the other occupies one screen row against
  -- three at the SAME width, and everything below it reads at a different
  -- height in each pane. Set true to wrap anyway and give up that alignment.
  pane_wrap = false,
  icons = true, -- file icons from nvim-web-devicons when it is installed
  -- Auto-open the first file worth looking at, instead of leaving the panes
  -- empty until the user presses <CR>: the first file of the flat
  -- "All changes" group while classification is still running, then
  -- the first file of the first real group once it completes — but only if
  -- the user hasn't already selected (or navigated to) a file of their own.
  -- Set to false to keep the sidebar-only-until-<CR> behavior.
  auto_open = true,
  max_full_diff_bytes = 100 * 1024, -- above this, prompt gets per-hunk summaries only
  max_hunks = 600, -- above this, skip classification with a notice
  -- Added and untracked files arrive from git as a single whole-file hunk, so
  -- they could only ever belong to one intent. Splitting them at blank-line
  -- boundaries lets different parts of one new file land in different intents,
  -- and makes the group fold filter meaningful for them. Set enabled = false
  -- to restore one-hunk-per-added-file.
  added_file_split = { enabled = true, min_lines = 60, target_lines = 40 },
  cache_dir = vim.fn.stdpath("cache") .. "/intentdiff",
  log_file = vim.fn.stdpath("cache") .. "/intentdiff/intentdiff.log", -- diagnostics log; see :IntentDiffLog
  -- Cursor-driven preview: putting the cursor on a group, directory or file
  -- row in the sidebar shows that row's diff in the diff panes without a key
  -- press — a file row renders its own diff, a group/directory row renders
  -- every file it touches, each preceded by a separator. debounce_ms is what
  -- keeps this cheap: holding `j` through a large tree never settles, so it
  -- renders once, at rest, instead of thrashing the panes on every row.
  preview = { enabled = true, debounce_ms = 120 },
  -- Review comments attached to diff lines and to whole intents, exported as
  -- Markdown for an agent to act on. See :IntentDiffCommentsYank / …Write.
  comments = {
    enabled = true,
    -- The order the popup cycles them in. A type's highlight groups are
    -- derived from its key — see highlight.comment_groups.
    types = {
      { key = "note", name = "Note", icon = "✍" },
      { key = "suggestion", name = "Suggestion", icon = "💡" },
      { key = "issue", name = "Issue", icon = "⚠" },
      { key = "praise", name = "Praise", icon = "✨" },
    },
    -- Days before a stored review is swept. false disables the sweep.
    expire_days = 7,
    -- Default path offered by :IntentDiffCommentsWrite, relative to git root.
    export_path = ".intentdiff-review.md",
  },
  -- Buffer-local keys the plugin installs inside a review tab, namespaced by
  -- surface the way codediff namespaces its own (keymaps.view / .explorer /
  -- .history / .conflict). Set any action to false to install nothing,
  -- exactly as the plugin already handles codediff's toggle_layout key being
  -- disabled. An action may also be a LIST of keys, all bound to it.
  keymaps = {
    -- The diff panes — one file or a whole intent, they are the same buffers.
    view = {
      quit = "q",
      -- Named after codediff's keymaps.view.toggle_explorer, and deliberately
      -- sharing its default: our sidebar is that explorer's counterpart.
      -- Installed on the sidebar too, since a sidebar-local key would be
      -- unreachable once the sidebar is hidden.
      toggle_sidebar = "<leader>b",
      next_hunk = "]c", -- group-scoped: only the current intent's hunks
      prev_hunk = "[c",
      show_help = "g?",
      -- Panes are read-only scratch buffers now; this is the only way from
      -- one into the real, editable file, at the cursor's exact line. Opens
      -- in a new tab, identically for a single-file and a whole-intent view.
      -- No collision on the pane buffers: sidebar's own `gf` (goto_file) is a
      -- different surface/buffer entirely.
      open_file = "gf",
    },
    -- The intent sidebar.
    sidebar = {
      select = "<CR>",
      quit = "q",
      reclassify = "R", -- was `r`; `R` is what codediff's explorer uses
      goto_file = "gf",
      next_group = "<Tab>",
      prev_group = "<S-Tab>",
      show_help = "g?",
      -- Vim-style folds, matching codediff's explorer set. On a directory row
      -- these act on that directory; anywhere else in an intent (title, stats
      -- line, file row) they act on the enclosing intent. "Recursive" means
      -- the row plus every directory beneath it. `h`/`l` are kept as the
      -- nvim-tree-style aliases they have always been, now split across
      -- close/open rather than both toggling.
      fold_open = { "zo", "l" },
      fold_open_recursive = "zO",
      fold_close = { "zc", "h" },
      fold_close_recursive = "zC",
      fold_toggle = "za",
      fold_toggle_recursive = "zA",
      -- Whole-sidebar: expand / collapse every intent. Per-directory state is
      -- deliberately preserved, so re-expanding restores the tree the user had
      -- arranged (see M.fold_all).
      fold_open_all = "zR",
      fold_close_all = "zM",
      -- The pre-namespacing `zA` behavior — collapse every intent if any is
      -- expanded, else expand every one. `zA` now means fold_toggle_recursive
      -- (codediff's meaning), so this is unbound by default and reachable as
      -- :IntentDiffToggleAll.
      fold_toggle_all = false,
    },
    -- Review comments. Cross-surface by nature: installed on the diff panes
    -- AND the sidebar, since an intent comment is added from a group row and a
    -- line comment from a pane row.
    comments = {
      add_comment = "<localleader>cc", -- pick the type in the popup
      add_note = "<localleader>cn",
      add_suggestion = "<localleader>cs",
      add_issue = "<localleader>ci",
      add_praise = "<localleader>cp",
      add_file_comment = "<localleader>cf",
      edit_comment = "<localleader>ce",
      delete_comment = "<localleader>cd",
      list_comments = "<localleader>cl",
      next_comment = "]n",
      prev_comment = "[n",
      export_clipboard = "<localleader>cy",
      export_file = "<localleader>cw",
      clear_comments = "<localleader>cx",
      -- The review.nvim end-of-review flow: copy, then close. Plain `q` still
      -- closes without touching the clipboard.
      export_and_close = "<localleader>q",
      -- Popup-local keys for the comment entry float (comments/popup.lua),
      -- buffer-local to its text area rather than installed tab-wide. Not
      -- listed in the g? cheatsheet, which only covers tab-wide surfaces.
      popup_cycle_type = "<Tab>",
      popup_submit = "<C-s>",
      popup_cancel = "q",
    },
  },
}

--- Pre-namespacing keys that lived flat on `keymaps`, and where they moved.
local LEGACY_KEYMAPS = {
  toggle_sidebar = { "view", "toggle_sidebar" },
  toggle_all = { "sidebar", "fold_toggle_all" },
}

--- Rewrite a user `keymaps` table that still uses the flat pre-namespacing
--- keys into the namespaced shape, returning the rewritten table and a list of
--- human-readable moves for the deprecation notice. A surface the user spelled
--- out explicitly always wins over what the shim derived.
local function migrate_keymaps(km)
  local explicit, derived, moved = {}, {}, {}
  for key, value in pairs(km) do
    local target = LEGACY_KEYMAPS[key]
    -- type(value) ~= "table" distinguishes the legacy scalar `toggle_sidebar =
    -- "<leader>gVt"` from a namespaced surface that happens to share the name.
    if target and type(value) ~= "table" then
      derived[target[1]] = derived[target[1]] or {}
      derived[target[1]][target[2]] = value
      moved[#moved + 1] = ("keymaps.%s → keymaps.%s.%s"):format(key, target[1], target[2])
    else
      explicit[key] = value
    end
  end
  local out = {}
  for surface, actions in pairs(derived) do
    out[surface] = actions
  end
  for surface, actions in pairs(explicit) do
    if type(actions) == "table" and type(out[surface]) == "table" then
      out[surface] = vim.tbl_extend("force", out[surface], actions)
    else
      out[surface] = actions
    end
  end
  return out, moved
end

--- Merge keymap surfaces one action at a time. vim.tbl_deep_extend would
--- recurse INTO a list-valued action, so overriding `fold_open = { "zo", "l" }`
--- with `{ "zo" }` would leave "l" behind at index 2 — a user key that is
--- impossible to remove. Shallow-per-surface means a user value always
--- replaces the default outright.
local function merge_keymaps(defaults, override)
  local out = {}
  for surface, actions in pairs(defaults) do
    -- deepcopy, not a shallow copy: a list-valued action shallow-copied would
    -- hand M.options a reference to M.defaults' own list, so mutating
    -- options.keymaps.sidebar.fold_open in place would corrupt the defaults
    -- for every later setup() call.
    out[surface] = vim.deepcopy(actions)
  end
  for surface, actions in pairs(override) do
    if type(actions) == "table" and type(out[surface]) == "table" then
      out[surface] = vim.tbl_extend("force", out[surface], actions)
    else
      out[surface] = actions
    end
  end
  return out
end

M.options = vim.deepcopy(M.defaults)

--- Whether the review-comment feature is on.
---
--- The single spelling of this check. It lives here because every surface asks
--- it — the panes and the sidebar before installing keys, the mark refresh
--- after every pane rebuild, the g? cheatsheet, the session lifecycle, and the
--- :IntentDiffComments* commands — and five copies of
--- `(options.comments or {}).enabled ~= false` are five chances for one of them
--- to drift into meaning something subtly different.
---
--- `~= false`, not `== true`: an explicit `false` disables the feature, and
--- anything else (including a `comments` table a user replaced wholesale
--- without an `enabled` key) leaves it on, matching the default.
function M.comments_enabled()
  return (M.options.comments or {}).enabled ~= false
end

function M.setup(opts)
  opts = opts or {}
  -- Keymaps are merged separately from everything else: see merge_keymaps.
  local keymaps, moved = migrate_keymaps(opts.keymaps or {})
  opts = vim.tbl_extend("force", {}, opts)
  opts.keymaps = nil
  -- comments.types is a LIST, and vim.tbl_deep_extend merges lists by index:
  -- a user supplying two types would silently inherit defaults at 3 and 4.
  -- Pull it out, deep-extend everything else, then put it back wholesale.
  local types = opts.comments and opts.comments.types
  if types then
    opts.comments = vim.tbl_extend("force", {}, opts.comments)
    opts.comments.types = nil
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if types then
    M.options.comments.types = vim.deepcopy(types)
  end
  M.options.keymaps = merge_keymaps(M.defaults.keymaps, keymaps)
  if #moved > 0 then
    vim.notify(
      "intent-diff: keymaps are now namespaced by surface; migrated "
        .. table.concat(moved, ", "),
      vim.log.levels.WARN
    )
  end
end

return M
