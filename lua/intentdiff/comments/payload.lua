-- The service-neutral review payload: what goes inline, what goes in the body.
--
-- Pure — comments, a model and a mode in, a payload out — so every shape is
-- tested without a repository, a `gh`, or a review tab. Translation to a
-- particular service's JSON happens in forges/<service>.lua, never here.
--
-- The split is the whole point. An inline comment carries ONLY its type and
-- text, because GitHub shows it next to the line and the intent would be noise
-- there. The body carries the structure — which intent each comment sits under
-- — plus, in full, the comments that have nowhere else to live.
local M = {}

local export = require("intentdiff.comments.export")

local HEADER = "I reviewed your code and have the following comments. Please address them."
local TYPE_LEGEND = "Comment types: ISSUE (problems to fix), SUGGESTION (improvements),\n"
  .. "NOTE (observations), PRAISE (positive feedback)"
-- Two headings, two different failures, deliberately not merged. A comment can
-- match no intent yet post perfectly well on its line (index it, its text is
-- inline); or it can be impossible to anchor and have nowhere but the body to
-- live (print it in full). Merging them would either repeat an inline comment's
-- text or silently drop a demoted one.
local NO_INTENT = "Not attached to an intent"
local NO_LINE = "Not attached to a line"
local VERDICT_ONLY = "Submitted from intent-diff with no new comments."

local function typed(c)
  return ("**[%s]** %s"):format(tostring(c.type):upper(), c.text or "")
end

--- One inline comment, in the plugin's own vocabulary.
local function inline_of(c)
  return {
    path = c.file,
    line = c.line or 0,
    line_end = c.line_end,
    side = c.side or "new",
    body = typed(c),
    file_level = (c.line or 0) == 0,
  }
end

--- `- \`src/a.ts:5\` — ISSUE`
local function index_of(c)
  return ("- `%s` — %s"):format(export.location(c), tostring(c.type):upper())
end

--- Full text, for a comment the body has to carry itself.
local function full_of(c, n, out)
  out[#out + 1] = ("%d. **[%s]** `%s`"):format(n, tostring(c.type):upper(), export.location(c))
  for _, line in ipairs(vim.split(c.text or "", "\n")) do
    out[#out + 1] = "   " .. line
  end
  out[#out + 1] = ""
end

--- @param comments intentdiff.Comment[]
--- @param model table|nil
--- @param mode "inline"|"general"
--- @param anchorable fun(c: intentdiff.Comment): boolean|nil  nil = everything anchors
--- @return { body: string, comments: table[], demoted: integer }
function M.build(comments, model, mode, anchorable)
  comments = comments or {}

  -- Nothing to say, in EITHER mode, and this check has to come first. A
  -- verdict-only submit reaches general mode as readily as inline — the
  -- comments were posted in an earlier sitting, the user has since edited a
  -- commented file, and they come back to approve — and general mode would
  -- otherwise fall through to export.generate({}), whose empty-list output is
  -- the literal "No comments yet.". That is the body of a real approval on a
  -- real PR.
  if #comments == 0 then
    return { body = VERDICT_ONLY, comments = {}, demoted = 0 }
  end

  -- General mode is the Markdown export, unchanged. The reason it is general
  -- rather than inline is shown in Neovim, not written into the PR: the reader
  -- of the PR cannot act on the state of someone else's working tree.
  if mode ~= "inline" then
    return { body = export.generate(comments, model), comments = {}, demoted = 0 }
  end

  local can = anchorable or function() return true end
  local inline, demoted_list = {}, {}
  local is_demoted = {}
  for _, c in ipairs(comments) do
    if not c.intent_title then
      if can(c) then
        inline[#inline + 1] = inline_of(c)
      else
        demoted_list[#demoted_list + 1] = c
        is_demoted[c] = true
      end
    end
  end

  local b = export.bucket(comments, model)
  local out = { HEADER, "", TYPE_LEGEND, "" }

  --- Intent prose, then one index line per inline comment under it.
  ---
  --- `has_heading` says whether a `## <title>` line is about to sit above these
  --- comments. When one is, the heading IS the anchor. When there is none — the
  --- flat fallback — the title has to travel WITH the comment, exactly as
  --- export.generate does it, or the prose reads as a document preamble.
  local function emit(bucket, has_heading)
    for _, c in ipairs(bucket.intents) do
      if not has_heading and c.intent_title then
        out[#out + 1] = ("_Intent: %s_"):format(c.intent_title)
      end
      for _, line in ipairs(vim.split(c.text or "", "\n")) do
        out[#out + 1] = line
      end
      out[#out + 1] = ""
    end
    local any = false
    for _, c in ipairs(bucket.items) do
      if not is_demoted[c] then
        out[#out + 1] = index_of(c)
        any = true
      end
    end
    if any then
      out[#out + 1] = ""
    end
  end

  --- Would `emit` write anything for this bucket?
  ---
  --- A bucket EXISTS as soon as one comment lands in it, but every one of its
  --- line comments may then have been demoted into `## Not attached to a
  --- line`, leaving a `## <title>` heading over nothing. The `## Not attached
  --- to an intent` section below already gates itself this way; the group loop
  --- has to as well, or the PR body carries stray empty sections.
  local function has_content(bucket)
    if #bucket.intents > 0 then
      return true
    end
    for _, c in ipairs(bucket.items) do
      if not is_demoted[c] then
        return true
      end
    end
    return false
  end

  if b.flat and b.buckets[0] then
    -- No grouping available: no headings to hang an index under, so the body
    -- is just the intent prose plus the index.
    emit(b.buckets[0], false)
  end
  for gi, g in ipairs(b.groups) do
    if b.buckets[gi] and has_content(b.buckets[gi]) then
      out[#out + 1] = "## " .. g.title
      out[#out + 1] = ""
      emit(b.buckets[gi], true)
    end
  end

  -- Matched no intent, but posts inline perfectly well: an index line, and an
  -- orphaned intent comment as prose carrying its own title, since no heading
  -- above it names one.
  local no_intent = {}
  for _, c in ipairs(b.unmatched) do
    if not is_demoted[c] then
      no_intent[#no_intent + 1] = c
    end
  end
  if #no_intent > 0 then
    out[#out + 1] = "## " .. NO_INTENT
    out[#out + 1] = ""
    for _, c in ipairs(no_intent) do
      if c.intent_title then
        out[#out + 1] = ("_Intent: %s_"):format(c.intent_title)
        for _, line in ipairs(vim.split(c.text or "", "\n")) do
          out[#out + 1] = line
        end
        out[#out + 1] = ""
      else
        out[#out + 1] = index_of(c)
      end
    end
    if out[#out] ~= "" then
      out[#out + 1] = ""
    end
  end

  -- Could not be anchored: the body is the only place left, so print it whole.
  if #demoted_list > 0 then
    out[#out + 1] = "## " .. NO_LINE
    out[#out + 1] = ""
    for n, c in ipairs(demoted_list) do
      full_of(c, n, out)
    end
  end

  while out[#out] == "" do
    table.remove(out)
  end
  return { body = table.concat(out, "\n"), comments = inline, demoted = #demoted_list }
end

return M
