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
--- with … when the configured types do not fit the float's width. Truncation
--- walks characters summing DISPLAY width (not codepoint count): the default
--- icons are double-width, so cutting by codepoint (strcharpart) can still
--- overflow the float once a user's type list is long enough to trigger it.
function M.type_line(list, index)
  local parts = {}
  for i, t in ipairs(list) do
    local label = ("%s %s"):format(t.icon or "●", t.name or t.key)
    parts[#parts + 1] = (i == index) and ("[" .. label .. "]") or (" " .. label .. " ")
  end
  local line = table.concat(parts, " ")
  if vim.fn.strdisplaywidth(line) > WIDTH - 2 then
    local budget = WIDTH - 3 -- leave room for the trailing "…"
    local out, width = {}, 0
    for _, char in ipairs(vim.fn.split(line, [[\zs]])) do
      local w = vim.fn.strdisplaywidth(char)
      if width + w > budget then
        break
      end
      out[#out + 1] = char
      width = width + w
    end
    line = table.concat(out) .. "…"
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
  M._type_buf, M._text_buf = nil, nil
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

--- First lhs of a keymap action spec (a single lhs or a list of them), or
--- nil when the action is false/nil — used so the float titles can never
--- show a hint for a key that isn't actually bound.
local function first_lhs(spec)
  if not spec then
    return nil
  end
  if type(spec) == "table" then
    return spec[1]
  end
  return spec
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

  -- Read the popup-local keys once so both the titles and the bindings
  -- below are built from the SAME config read — a rebound or disabled key
  -- shows up rebound or not at all, in the title as much as in the buffer.
  local km = (config.options.keymaps or {}).comments or {}
  local cycle_hint = first_lhs(km.popup_cycle_type)
  local submit_hint = first_lhs(km.popup_submit)
  local type_title = cycle_hint and (" Type (" .. cycle_hint .. " to switch) ") or " Type "
  local text_title = submit_hint and (" Comment (" .. submit_hint .. " submit) ") or " Comment "

  local total = 3 + TEXT_HEIGHT + 2
  local top = math.max(math.floor((vim.o.lines - total) / 2), 0)
  M._type_win = float(M._type_buf, top, 1, type_title)
  M._text_win = float(M._text_buf, top + 3, TEXT_HEIGHT, text_title)
  render_type()

  if opts.text and opts.text ~= "" then
    -- opts.text is a previously-stored, possibly hand-edited comment (the
    -- edit_comment path) — user data, so guard it like every other API call
    -- here that can fail on user input.
    pcall(function()
      vim.api.nvim_buf_set_lines(M._text_buf, 0, -1, false, vim.split(opts.text, "\n"))
    end)
  end

  -- Bind every key an action is configured with. `spec` is a single lhs, a
  -- list of them, or false/nil to install nothing — the shared helper is
  -- what keeps that handling from drifting between call sites (see
  -- keymaps.lua). No `or "<Tab>"`-style fallback here: M.options is always
  -- deep-copied from defaults at setup(), so a fallback would be redundant
  -- when the key is set and actively wrong (unignorable) when it is false.
  local function bind(modes, spec, fn)
    require("intentdiff.keymaps").each(spec, function(lhs)
      for _, mode in ipairs(modes) do
        pcall(vim.keymap.set, mode, lhs, fn, { buffer = M._text_buf, nowait = true })
      end
    end)
  end
  bind({ "i", "n" }, km.popup_cycle_type, M.cycle_type)
  bind({ "i", "n" }, km.popup_submit, M.submit)
  pcall(vim.keymap.set, "n", "<CR>", M.submit, { buffer = M._text_buf, nowait = true })
  -- Unconditional: <Esc> is a hard escape hatch, not a configurable action.
  pcall(vim.keymap.set, "n", "<Esc>", M.cancel, { buffer = M._text_buf, nowait = true })
  bind({ "n" }, km.popup_cancel, M.cancel)

  vim.api.nvim_set_current_win(M._text_win)
  -- Only enter insert mode for a real interactive session: a headless test
  -- driving submit() directly must not be left in insert mode.
  if not opts.no_insert then
    vim.cmd("startinsert!")
  end
end

return M
