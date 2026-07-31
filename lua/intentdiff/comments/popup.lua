-- The comment entry float: a one-line type selector above a multi-line text
-- area. Built with plain nvim_open_win rather than nui.nvim so the plugin
-- keeps codediff as its only dependency — same approach as keymap_help.lua.
--
-- submit/cancel are module functions rather than closures so they can be
-- driven from a test without synthesizing insert-mode keystrokes.
local M = {}

local config = require("intentdiff.config")

local WIDTH = 60
local TEXT_HEIGHT = 5

M._type_win, M._text_win, M._type_buf, M._text_buf = nil, nil, nil, nil
local state = nil

local function types()
  local list = (config.options.comments or {}).types or {}
  if #list == 0 then
    list = { { key = "note", name = "Note", icon = "✍" } }
  end
  return list
end

--- 1-based index one step forward, wrapping.
function M.cycle(index, count)
  if count <= 0 then
    return 1
  end
  return (index % count) + 1
end

--- The selector row. The selected type is bracketed; the row is truncated
--- with … when the configured types do not fit the float's width.
function M.type_line(list, index)
  local parts = {}
  for i, t in ipairs(list) do
    local label = ("%s %s"):format(t.icon or "●", t.name or t.key)
    parts[#parts + 1] = (i == index) and ("[" .. label .. "]") or (" " .. label .. " ")
  end
  local line = table.concat(parts, " ")
  if vim.fn.strdisplaywidth(line) > WIDTH - 2 then
    line = vim.fn.strcharpart(line, 0, WIDTH - 3) .. "…"
  end
  return line
end

local function render_type()
  if not (state and vim.api.nvim_buf_is_valid(M._type_buf)) then
    return
  end
  vim.bo[M._type_buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._type_buf, 0, -1, false, { M.type_line(state.types, state.index) })
  vim.bo[M._type_buf].modifiable = false
end

local function close_windows()
  for _, win in ipairs({ M._type_win, M._text_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  M._type_win, M._text_win = nil, nil
end

--- Finish the popup exactly once, restoring focus to where it was opened from.
local function finish(comment_type, text)
  if not state then
    return
  end
  local callback, prev_win = state.callback, state.prev_win
  state = nil
  close_windows()
  if prev_win and vim.api.nvim_win_is_valid(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end
  pcall(vim.cmd, "stopinsert")
  callback(comment_type, text)
end

function M.submit()
  if not state then
    return
  end
  local lines = vim.api.nvim_buf_is_valid(M._text_buf)
    and vim.api.nvim_buf_get_lines(M._text_buf, 0, -1, false) or {}
  local text = (table.concat(lines, "\n"):gsub("%s+$", ""))
  if text == "" then
    return finish(nil, nil)
  end
  finish(state.types[state.index].key, text)
end

function M.cancel()
  if state then
    finish(nil, nil)
  end
end

function M.cycle_type()
  if not state then
    return
  end
  state.index = M.cycle(state.index, #state.types)
  render_type()
end

local function float(buf, row, height, title)
  return vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = row,
    col = math.max(math.floor((vim.o.columns - WIDTH) / 2), 0),
    width = WIDTH,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
end

--- @param opts { type: string?, text: string? }
--- @param callback fun(comment_type: string|nil, text: string|nil)
function M.open(opts, callback)
  M.cancel()
  opts = opts or {}
  local list = types()
  local index = 1
  for i, t in ipairs(list) do
    if t.key == opts.type then
      index = i
      break
    end
  end

  M._type_buf = vim.api.nvim_create_buf(false, true)
  M._text_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M._type_buf].bufhidden = "wipe"
  vim.bo[M._text_buf].bufhidden = "wipe"

  state = {
    types = list,
    index = index,
    callback = callback,
    prev_win = vim.api.nvim_get_current_win(),
  }

  local total = 3 + TEXT_HEIGHT + 2
  local top = math.max(math.floor((vim.o.lines - total) / 2), 0)
  M._type_win = float(M._type_buf, top, 1, " Type (⇥ to switch) ")
  M._text_win = float(M._text_buf, top + 3, TEXT_HEIGHT, " Comment (^s submit) ")
  render_type()

  if opts.text and opts.text ~= "" then
    vim.api.nvim_buf_set_lines(M._text_buf, 0, -1, false, vim.split(opts.text, "\n"))
  end

  local km = (config.options.keymaps or {}).comments or {}
  local function map(modes, lhs, fn)
    if lhs then
      pcall(vim.keymap.set, modes, lhs, fn, { buffer = M._text_buf, nowait = true })
    end
  end
  map({ "i", "n" }, km.popup_cycle_type or "<Tab>", M.cycle_type)
  map({ "i", "n" }, km.popup_submit or "<C-s>", M.submit)
  map("n", "<CR>", M.submit)
  map("n", "<Esc>", M.cancel)
  map("n", km.popup_cancel or "q", M.cancel)

  vim.api.nvim_set_current_win(M._text_win)
  -- Only enter insert mode for a real interactive session: a headless test
  -- driving submit() directly must not be left in insert mode.
  if not opts.no_insert then
    vim.cmd("startinsert!")
  end
end

return M
