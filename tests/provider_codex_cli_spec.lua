local codex_cli = require("intentdiff.providers.codex_cli")
local helpers = require("tests.intentdiff_helpers")

local REQUEST = {
  diff_text = "diff --git a/a.lua b/a.lua\n@@ -1,1 +1,1 @@\n-x\n+y\n",
  hunks = {
    { id = "a.lua:1", n = 1, file = "a.lua", summary_lines = { "@@ -1,1 +1,1 @@", "-x", "+y" } },
  },
}

local function fake_codex_capturing(argv_file, prompt_file)
  return helpers.fake_bin("codex", ([[
printf '%%s\n' "$@" > %s
cat > %s
echo '{"groups":[{"title":"Fake","ids":"1"}]}'
]]):format(argv_file, prompt_file))
end

describe("codex_cli provider", function()
  it("runs codex exec with Luna, an explicit read-only sandbox, and an ephemeral session", function()
    local argv_file = vim.fn.tempname()
    local prompt_file = vim.fn.tempname()
    local restore = fake_codex_capturing(argv_file, prompt_file)
    local result, err
    codex_cli.new({ timeout_ms = 5000 })(REQUEST, function(r, e) result, err = r, e end)
    helpers.wait_for(function() return result or err end)
    restore()

    assert.is_nil(err)
    assert.equals("Fake", result.groups[1].title)
    assert.same({
      "exec", "--model", "gpt-5.6-luna", "--sandbox", "read-only",
      "--color", "never", "--ephemeral", "-",
    }, vim.fn.readfile(argv_file))
    local prompt = table.concat(vim.fn.readfile(prompt_file), "\n")
    assert.truthy(prompt:find('"groups"', 1, true))
    assert.truthy(prompt:find("- 1  a.lua", 1, true))
  end)

  it("honors model, sandbox, and session-persistence overrides", function()
    local argv_file = vim.fn.tempname()
    local prompt_file = vim.fn.tempname()
    local restore = fake_codex_capturing(argv_file, prompt_file)
    local result
    codex_cli.new({
      cmd = "codex",
      model = "gpt-custom",
      sandbox = "workspace-write",
      ephemeral = false,
      timeout_ms = 5000,
    })(REQUEST, function(r) result = r end)
    helpers.wait_for(function() return result end)
    restore()

    assert.same({
      "exec", "--model", "gpt-custom", "--sandbox", "workspace-write",
      "--color", "never", "-",
    }, vim.fn.readfile(argv_file))
  end)

  it("runs in the reviewed repository", function()
    local repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    local pwd_file = vim.fn.tempname()
    local restore = helpers.fake_bin("codex",
      ("cat > /dev/null\npwd > %s\necho '{\"groups\":[]}'"):format(pwd_file))
    local result
    codex_cli.new({ timeout_ms = 5000 })(vim.tbl_extend("force", REQUEST, {
      repo = { git_root = repo },
    }), function(r) result = r end)
    helpers.wait_for(function() return result end)
    restore()

    local captured = vim.trim(table.concat(vim.fn.readfile(pwd_file), "\n"))
    assert.equals(vim.uv.fs_realpath(repo), vim.uv.fs_realpath(captured))
  end)
end)
