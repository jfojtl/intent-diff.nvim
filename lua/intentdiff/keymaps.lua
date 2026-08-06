-- Installing buffer-local keys from the namespaced `config.keymaps` table.
--
-- Both surfaces (the sidebar and the diff panes) bind keys the same way: look
-- an action up by name, skip it when it is false/nil, and accept either a
-- single lhs or a list of them. This module is that one way, so the
-- list/disabled handling can't drift between call sites.
local M = {}

--- Call `fn` for each lhs an action is configured with. `spec` is a single
--- lhs, a list of them, or false/nil to bind nothing.
function M.each(spec, fn)
  if not spec then
    return
  end
  for _, lhs in ipairs(type(spec) == "table" and spec or { spec }) do
    if lhs then
      fn(lhs)
    end
  end
end

--- Bind `handlers` (action name → function) on `buf` from the `surface` table
--- of config.keymaps. `descs` supplies the `desc` shown in :map and which-key.
---
--- Binding is pcall'd: a user lhs that Neovim rejects should cost that one key,
--- not the rest of the review tab's keymaps.
function M.install(buf, surface, handlers, descs)
  local km = (require("intentdiff.config").options.keymaps or {})[surface] or {}
  for action, fn in pairs(handlers) do
    M.each(km[action], function(lhs)
      pcall(vim.keymap.set, "n", lhs, fn,
        { buffer = buf, nowait = true, desc = (descs or {})[action] })
    end)
  end
end

return M
