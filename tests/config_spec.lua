describe("config", function()
  it("merges user opts over defaults", function()
    local config = require("intentdiff.config")
    config.setup({ provider_opts = { model = "sonnet" }, sidebar_width = 50 })
    assert.equals("sonnet", config.options.provider_opts.model)
    assert.equals("claude", config.options.provider_opts.cmd) -- default preserved
    assert.equals(50, config.options.sidebar_width)
    assert.equals(180000, config.options.provider_opts.timeout_ms)
  end)

  it("setup twice starts from defaults, not previous merge", function()
    local config = require("intentdiff.config")
    config.setup({ sidebar_width = 50 })
    config.setup({})
    assert.equals(40, config.options.sidebar_width)
  end)

  it("default provider timeout is 180000ms", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.equals(180000, config.options.provider_opts.timeout_ms)
  end)

  it("uses Codex-specific defaults when codex_cli is selected", function()
    local config = require("intentdiff.config")
    config.setup({ provider = "codex_cli" })
    assert.equals("codex", config.options.provider_opts.cmd)
    assert.equals("gpt-5.6-luna", config.options.provider_opts.model)
    assert.equals("read-only", config.options.provider_opts.sandbox)
    assert.is_true(config.options.provider_opts.ephemeral)
    assert.is_nil(config.options.provider_opts.allowed_tools)
  end)

  it("merges user options over the selected provider's defaults", function()
    local config = require("intentdiff.config")
    config.setup({ provider = "codex_cli", provider_opts = { model = "gpt-custom" } })
    assert.equals("gpt-custom", config.options.provider_opts.model)
    assert.equals("codex", config.options.provider_opts.cmd)
    assert.equals("read-only", config.options.provider_opts.sandbox)
  end)

  it("auto_open defaults to true and can be turned off", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.equals(true, config.options.auto_open)
    config.setup({ auto_open = false })
    assert.equals(false, config.options.auto_open)
  end)
end)

describe("config UX pass defaults", function()
  it("defaults added_file_split and raises max_hunks", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.is_true(config.options.added_file_split.enabled)
    assert.equals(60, config.options.added_file_split.min_lines)
    assert.equals(40, config.options.added_file_split.target_lines)
    assert.equals(600, config.options.max_hunks)
  end)
end)

describe("config sidebar defaults", function()
  it("widens the sidebar and enables icons", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.equals(40, config.options.sidebar_width)
    assert.is_true(config.options.icons)
  end)
end)

describe("config navigation defaults", function()
  it("previews on hover, debounced", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.is_true(config.options.preview.enabled)
    assert.equals(120, config.options.preview.debounce_ms)
  end)
end)

describe("config keymaps", function()
  local config = require("intentdiff.config")

  it("namespaces keymaps by surface, matching codediff's defaults", function()
    config.setup({})
    -- Same lhs codediff binds to keymaps.view.toggle_explorer: the sidebar is
    -- that explorer's counterpart.
    assert.equals("<leader>b", config.options.keymaps.view.toggle_sidebar)
    assert.equals("g?", config.options.keymaps.view.show_help)
    assert.equals("R", config.options.keymaps.sidebar.reclassify)
    -- zA is codediff's fold_toggle_recursive, NOT the old expand/collapse-all.
    assert.equals("zA", config.options.keymaps.sidebar.fold_toggle_recursive)
    assert.equals("zR", config.options.keymaps.sidebar.fold_open_all)
    assert.equals("zM", config.options.keymaps.sidebar.fold_close_all)
    assert.is_false(config.options.keymaps.sidebar.fold_toggle_all)
  end)

  it("keeps h/l as aliases of the fold open/close keys", function()
    config.setup({})
    assert.same({ "zo", "l" }, config.options.keymaps.sidebar.fold_open)
    assert.same({ "zc", "h" }, config.options.keymaps.sidebar.fold_close)
  end)

  it("lets a keymap be disabled with false", function()
    config.setup({ keymaps = { sidebar = { fold_toggle = false } } })
    assert.is_false(config.options.keymaps.sidebar.fold_toggle)
    -- Its neighbours survive: a surface override merges, it does not replace.
    assert.equals("zA", config.options.keymaps.sidebar.fold_toggle_recursive)
  end)

  it("replaces a list-valued action outright instead of merging indices", function()
    -- vim.tbl_deep_extend would leave "l" behind at index 2, making the
    -- default alias impossible to drop.
    config.setup({ keymaps = { sidebar = { fold_open = { "zo" } } } })
    assert.same({ "zo" }, config.options.keymaps.sidebar.fold_open)
  end)

  it("migrates the pre-namespacing flat keys", function()
    config.setup({ keymaps = { toggle_sidebar = "<leader>gVt", toggle_all = "zA" } })
    assert.equals("<leader>gVt", config.options.keymaps.view.toggle_sidebar)
    assert.equals("zA", config.options.keymaps.sidebar.fold_toggle_all)
  end)

  it("lets an explicit surface win over the migration shim", function()
    config.setup({
      keymaps = { toggle_sidebar = "<leader>gVt", view = { toggle_sidebar = "<leader>x" } },
    })
    assert.equals("<leader>x", config.options.keymaps.view.toggle_sidebar)
  end)

  it("does not leak keymaps between setup calls", function()
    config.setup({ keymaps = { sidebar = { reclassify = "gr" } } })
    config.setup({})
    assert.equals("R", config.options.keymaps.sidebar.reclassify)
  end)
end)

describe("comments config", function()
  local config = require("intentdiff.config")

  it("defaults to enabled with the four built-in types", function()
    config.setup({})
    assert.is_true(config.options.comments.enabled)
    local keys = {}
    for _, t in ipairs(config.options.comments.types) do
      keys[#keys + 1] = t.key
    end
    assert.same({ "note", "suggestion", "issue", "praise" }, keys)
    assert.equals(".intentdiff-review.md", config.options.comments.export_path)
    assert.equals(7, config.options.comments.expire_days)
  end)

  it("replaces the types list outright instead of merging by index", function()
    config.setup({ comments = { types = { { key = "issue", name = "Issue", icon = "!" } } } })
    assert.equals(1, #config.options.comments.types)
    assert.equals("issue", config.options.comments.types[1].key)
  end)

  it("keeps default types when the user overrides another comments field", function()
    config.setup({ comments = { export_path = "review.md" } })
    assert.equals(4, #config.options.comments.types)
    assert.equals("review.md", config.options.comments.export_path)
  end)

  it("exposes a comments keymap surface a user can override per action", function()
    config.setup({ comments = {}, keymaps = { comments = { add_issue = "<leader>i" } } })
    assert.equals("<leader>i", config.options.keymaps.comments.add_issue)
    assert.equals("<localleader>cc", config.options.keymaps.comments.add_comment)
  end)

  it("lets an action be disabled with false", function()
    config.setup({ keymaps = { comments = { add_praise = false } } })
    assert.is_false(config.options.keymaps.comments.add_praise)
  end)
end)

describe("config keymap isolation", function()
  it("does not let an in-place mutation reach the defaults", function()
    local config = require("intentdiff.config")
    config.setup({})
    table.insert(config.options.keymaps.sidebar.fold_open, "zzz")
    config.setup({})
    assert.same({ "zo", "l" }, config.options.keymaps.sidebar.fold_open)
  end)
end)

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

describe("telescope options", function()
  it("defaults to directory rows on and a 500-line preview cap", function()
    require("intentdiff.config").setup({})
    local opts = require("intentdiff.config").options
    assert.is_true(opts.telescope.include_dirs)
    assert.equals(500, opts.telescope.preview_lines)
  end)

  it("lets a user turn directory rows off without losing preview_lines", function()
    require("intentdiff.config").setup({ telescope = { include_dirs = false } })
    local opts = require("intentdiff.config").options
    assert.is_false(opts.telescope.include_dirs)
    assert.equals(500, opts.telescope.preview_lines)
  end)

  it("binds find on both the view and the sidebar", function()
    require("intentdiff.config").setup({})
    local km = require("intentdiff.config").options.keymaps
    assert.equals("<leader>f", km.view.find)
    assert.equals("<leader>f", km.sidebar.find)
  end)

  it("honours false to disable the find key", function()
    require("intentdiff.config").setup({ keymaps = { view = { find = false } } })
    local km = require("intentdiff.config").options.keymaps
    assert.is_false(km.view.find)
    assert.equals("q", km.view.quit) -- sibling actions survive the override
  end)
end)
