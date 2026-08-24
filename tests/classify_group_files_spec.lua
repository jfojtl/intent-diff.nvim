local classify = require("intentdiff.classify")
local hunks = require("intentdiff.hunks")

--- The sidebar is built from group.files, and group.files comes from
--- group_files. A file missing here is a file missing from the review.
describe("classify.group_files completeness", function()
  local function inventory_of(lines)
    local hs, files = hunks.parse(table.concat(lines, "\n") .. "\n")
    return hs, files
  end

  local function paths_of(grouped)
    local out = {}
    for _, f in ipairs(grouped) do
      out[#out + 1] = f.path
    end
    table.sort(out)
    return out
  end

  it("keeps a binary file alongside the text files it changed with", function()
    local hs, files = inventory_of({
      "diff --git a/logo.png b/logo.png",
      "index 111..222 100644",
      "Binary files a/logo.png and b/logo.png differ",
      "diff --git a/a.lua b/a.lua",
      "index 333..444 100644",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
    })
    assert.same({ "a.lua", "logo.png" }, paths_of(classify.group_files(hs, files)))
  end)

  it("keeps a pure rename", function()
    local hs, files = inventory_of({
      "diff --git a/moved.txt b/renamed.txt",
      "similarity index 100%",
      "rename from moved.txt",
      "rename to renamed.txt",
    })
    assert.same({ "renamed.txt" }, paths_of(classify.group_files(hs, files)))
  end)

  it("keeps a mode-only change", function()
    local hs, files = inventory_of({
      "diff --git a/run.sh b/run.sh",
      "old mode 100644",
      "new mode 100755",
    })
    assert.same({ "run.sh" }, paths_of(classify.group_files(hs, files)))
  end)

  it("accounts for every file git named", function()
    local hs, files = inventory_of({
      "diff --git a/logo.png b/logo.png",
      "index 111..222 100644",
      "Binary files a/logo.png and b/logo.png differ",
      "diff --git a/moved.txt b/renamed.txt",
      "similarity index 100%",
      "rename from moved.txt",
      "rename to renamed.txt",
      "diff --git a/run.sh b/run.sh",
      "old mode 100644",
      "new mode 100755",
      "diff --git a/a.lua b/a.lua",
      "index 333..444 100644",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
    })
    assert.equals(#files, #classify.group_files(hs, files))
  end)
end)
