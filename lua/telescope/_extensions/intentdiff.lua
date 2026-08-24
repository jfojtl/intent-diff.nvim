-- Telescope extension for intent-diff.
--
-- This file is INERT without Telescope. It lives on the runtimepath, but Lua
-- loads a module only when something requires it, and the only thing that ever
-- requires this one is Telescope's own load_extension. With Telescope absent
-- it is never read.
--
-- Registered as a named extension rather than calling telescope.pickers
-- directly, because that is what buys the conventions: `:Telescope resume`,
-- and per-picker prompt history under telescope-smart-history, which keys
-- history by picker name and cwd and therefore needs a named picker.
local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  error("intent-diff: this telescope extension requires telescope.nvim")
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")
local entry_display = require("telescope.pickers.entry_display")

local M = {}

local displayer = entry_display.create({
  separator = " ",
  items = {
    { width = 2 },   -- devicon
    { remaining = true },
    { width = 9 },   -- +N -M
    { width = 2 },   -- comment marker
  },
})

--- Devicon for `path`, mirroring sidebar.lua's guard: absent devicons or
--- `icons = false` yields an empty string rather than an error.
local function file_icon(path)
  if not path or not require("intentdiff.config").options.icons then
    return "", nil
  end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return "", nil
  end
  local icon, icon_hl = devicons.get_icon(path, nil, { default = true })
  return icon or "", icon_hl
end

--- Comment count for one target, using the same accessors the sidebar sign
--- uses. Intent rows count intent-level comments only — line comments inside
--- the intent's files are not rolled up, matching comments/marks.lua's
--- render_sidebar. `store` is nil when comments are disabled.
local function comment_icon(store, target)
  if not store then
    return ""
  end
  local comments
  if target.kind == "group" then
    comments = store.get_for_intent(target.group_title)
  elseif target.kind == "file" then
    comments = store.get_for_file(target.path, nil)
  else
    comments = {}
    for _, c in ipairs(store.get_all()) do
      if c.file and not c.intent_title and c.file:sub(1, #target.path + 1) == target.path .. "/" then
        comments[#comments + 1] = c
      end
    end
  end
  if #comments == 0 then
    return ""
  end
  for _, t in ipairs(require("intentdiff.config").options.comments.types) do
    if t.key == comments[1].type then
      return t.icon
    end
  end
  return "*"
end

--- Exposed for testing: a target plus its comment store becomes a Telescope
--- entry. The ordinal joins the intent's prose and the path so one prompt
--- matches both "retry" and "config.lua".
function M._entry_maker(target, store)
  local label = target.kind == "group" and target.group_title
    or (target.group_title .. " → " .. target.path)
  local stats = ("+%d -%d"):format(target.additions, target.deletions)
  local icon, icon_hl = file_icon(target.kind == "file" and target.path or nil)
  return {
    value = target,
    ordinal = target.group_title .. " " .. (target.path or ""),
    display = function()
      return displayer({
        { icon, icon_hl },
        label,
        { stats, "Comment" },
        comment_icon(store, target),
      })
    end,
  }
end

--- Unified diff for `target`, straight out of the hunks already in memory.
--- Every hunk carries its own raw diff text including the @@ header, so this
--- is a concat, not a render. Capped: without a cap, moving the cursor onto a
--- large intent re-renders thousands of lines on every keystroke.
local function preview_lines_for(model, target, cap)
  local lines = {}
  for _, g in ipairs(model and model.groups or {}) do
    if g.title == target.group_title then
      for _, f in ipairs(g.files or {}) do
        local under = target.kind == "group"
          or (target.kind == "file" and f.path == target.path)
          or (target.kind == "dir" and f.path:sub(1, #target.path + 1) == target.path .. "/")
        if under then
          for _, h in ipairs(f.hunks or {}) do
            for line in (h.text or ""):gmatch("(.-)\n") do
              lines[#lines + 1] = line
            end
          end
        end
      end
      break
    end
  end
  if #lines > cap then
    local trimmed = vim.list_slice(lines, 1, cap)
    trimmed[#trimmed + 1] = ("… %d more lines"):format(#lines - cap)
    return trimmed
  end
  return lines
end

local function intents(opts)
  opts = opts or {}
  local cfg = require("intentdiff.config").options
  local tabpage = vim.api.nvim_get_current_tabpage()
  local entry = require("intentdiff")._session(tabpage)
  if not entry then
    vim.notify("intent-diff: no review in this tab", vim.log.levels.WARN)
    return
  end
  local model = entry.model
  local store = require("intentdiff.config").comments_enabled()
    and require("intentdiff.comments").store_for(tabpage) or nil
  local list = require("intentdiff.targets").list(model,
    { include_dirs = cfg.telescope.include_dirs })

  pickers.new(opts, {
    prompt_title = "Intents",
    finder = finders.new_table({
      results = list,
      entry_maker = function(target) return M._entry_maker(target, store) end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Diff",
      define_preview = function(self, entry_)
        local lines = preview_lines_for(model, entry_.value, cfg.telescope.preview_lines)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "diff"
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selected = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selected then
          require("intentdiff").select(tabpage, selected.value)
        end
      end)
      return true
    end,
  }):find()
end

return telescope.register_extension({ exports = { intents = intents, _entry_maker = M._entry_maker } })
