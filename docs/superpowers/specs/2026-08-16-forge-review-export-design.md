# Forge review export — design

Export intent-diff review comments to a pull request on a git hosting service,
starting with GitHub via the `gh` CLI. Sits beside the existing Markdown
exports; neither replaces the other.

## Motivation

Today a review ends with `<localleader>cy` (copy Markdown) or `<localleader>q`
(copy, then close), and the Markdown is pasted into an agent by hand. That works
when the agent runs on this machine. It does not when the agent runs in the
cloud or on another machine, where the pull request is the shared surface.

The plugin already knows everything a PR review needs — file, line, side, range,
type, and the intent each comment belongs to. What is missing is a way to put
that on the PR without leaving Neovim, and an end-of-review verdict.

## Scope

In scope:

- A service-neutral forge abstraction, with GitHub implemented against `gh`.
- Detection of whether the current branch is linked to a PR.
- One atomic review submission carrying inline comments, a body, and a verdict.
- A record of what has already been posted, so a second submit cannot duplicate.

Out of scope:

- Services not built on git (Jujutsu, Mercurial). The abstraction assumes a git
  remote, a branch, and commit SHAs.
- Reading PR comments back into the review, replying to threads, resolving
  threads.
- Creating pull requests. When a branch has no PR, the plugin says so and stops.
- Reviewing a PR that is not checked out locally.

## Principles

**Nothing is sent until the user asks.** The submit flow is reached only by an
explicit key or command, and posts only after a verdict is chosen. Cancelling at
any step posts nothing. No detection, preflight or payload step contacts the
service with a write.

**A comment lands on the right line or does not land inline at all.** Line
numbers in a dirty working tree mean something different from line numbers at
the PR head. Rather than post feedback onto a line the reader is not looking at,
the export degrades to a general comment and says why.

**One pattern, not two.** The forge layer mirrors `providers/` — a named module
under a directory, resolved through config, with a small documented interface —
so a reader who understands one understands the other.

## Architecture

```
lua/intentdiff/forges/init.lua        resolve, detect, preflight
lua/intentdiff/forges/github.lua      gh CLI implementation
lua/intentdiff/comments/payload.lua   pure: comments + model + mode -> payload
lua/intentdiff/comments/submit.lua    the interactive flow
```

`comments/init.lua` gains one thin entry point, `M.submit(tabpage)`, delegating
to `submit.lua`. It is already 809 lines; the flow does not go in it.

### The forge interface

A forge module implements four functions:

```lua
--- Does this forge serve `remote_url`?
--- @param remote_url string
--- @return boolean
function M.matches(remote_url)

--- Is `branch` linked to a review target on this service?
--- Calls cb(target|nil, err). Read-only.
--- @param git_root string
--- @param branch string
--- @param cb fun(target: intentdiff.forge.Target|nil, err: string|nil)
function M.detect(git_root, branch, cb)

--- What this service can express.
--- @return { inline: boolean, file_comments: boolean, verdicts: string[] }
function M.capabilities()

--- Post one review atomically. The only function that writes.
--- @param target intentdiff.forge.Target
--- @param payload intentdiff.forge.Payload
--- @param cb fun(result: { url: string }|nil, err: string|nil)
function M.submit(target, payload, cb)
```

### Service-neutral types

```lua
--- @class intentdiff.forge.Target
--- @field service string    "github"
--- @field id string         PR/MR number as a string
--- @field url string        web URL, for the success notification
--- @field title string
--- @field head_sha string   the commit the service's diff is against
--- @field base_ref string   target branch name, e.g. "main"

--- @class intentdiff.forge.Comment
--- @field path string
--- @field line integer      0 for a file-level comment
--- @field line_end integer|nil
--- @field side "old"|"new"
--- @field body string
--- @field file_level boolean

--- @class intentdiff.forge.Payload
--- @field verdict "approve"|"request_changes"|"comment"
--- @field body string             Markdown
--- @field comments intentdiff.forge.Comment[]   empty in general mode
```

The payload is deliberately expressed in intent-diff's own vocabulary
(`side = "old"|"new"`, `line_end`) rather than GitHub's. Translation to
`side = "LEFT"|"RIGHT"` and `start_line` happens inside `github.lua`, so a
future `gitlab.lua` translating to `position.old_line`/`new_line` and
`approve`/`unapprove` needs no change above it.

### Resolution

`config.forge` accepts:

- `"auto"` (default) — read `git remote get-url origin`, ask each registered
  forge's `matches()` in registration order, take the first.
- a name, e.g. `"github"` — load `intentdiff.forges.<name>`.
- a table implementing the interface — used directly.
- `false` — the feature is off. The submit command reports
  `review export is disabled (forge = false)` and stops before any fact is
  gathered. This is distinct from `no_forge`, which means the feature is on but
  the remote is not served by any registered forge.

## Preflight

`forges.preflight(state)` is a pure function over plain facts:

```lua
--- @param state { branch: string|nil, default_branch: string|nil,
---                target: intentdiff.forge.Target|nil, head_sha: string|nil,
---                dirty_files: string[], commented_files: string[],
---                forge_name: string|nil, remote_url: string|nil }
--- @return { mode: string, reason: string|nil, dirty: string[]|nil }
```

`mode` is one of:

| mode | Condition | Message |
|---|---|---|
| `no_forge` | no remote, or no forge matches it | `no supported forge for remote <url>` |
| `default_branch` | `branch == default_branch` | `you are on <branch> — no PR to comment on` |
| `no_pr` | branch, `target == nil` | `no PR for branch <branch> — create one first (gh pr create)` |
| `inline` | target found, `head_sha == target.head_sha`, no commented file dirty | — |
| `general` | target found, anything else | states which: `local HEAD is ahead of PR head (<a> vs <b>)`, and/or `N of M commented files have uncommitted changes` |

Checks are ordered as listed; the first match wins. `default_branch` is checked
before `no_pr` so being on `master` gets its own message rather than the generic
"create a PR" one.

Only files carrying comments are considered for dirtiness. An unrelated dirty
file elsewhere in the repo does not affect line numbers in a commented file, and
degrading the whole export for it would be noise.

Facts are gathered by a thin async collector in `forges/init.lua`:

- `branch` — `git rev-parse --abbrev-ref HEAD`
- `head_sha` — `git rev-parse HEAD`
- `default_branch` — `git rev-parse --abbrev-ref origin/HEAD`, stripped of the
  `origin/` prefix; when that ref is absent, `gh repo view --json
  defaultBranchRef`; when both fail, `nil`, which simply skips the
  `default_branch` check rather than blocking the submit.
- `dirty_files` — `git status --porcelain`
- `target` — the forge's `detect()`

Every git call goes through the existing pcall-wrapped pattern in
`comments/init.lua`'s `git_rev` (`vim.fn.systemlist` raises E475 when the binary
is missing), which moves to a shared helper.

## GitHub implementation

`detect` runs:

```
gh pr view --json number,url,title,headRefOid,baseRefName,state --jq …
```

A non-zero exit with `no pull requests found` is not an error — it answers
`nil, nil`, which preflight reads as `no_pr`. A missing `gh`, an
unauthenticated `gh`, or any other non-zero exit is a real error and surfaces
verbatim. A PR whose `state` is not `OPEN` is treated as no PR, with its own
message: `PR #<n> is <state> — nothing to review`.

`submit` posts one review:

```
gh api --method POST repos/{owner}/{repo}/pulls/{id}/reviews --input -
```

with a JSON body on stdin:

```json
{
  "commit_id": "<target.head_sha>",
  "event": "REQUEST_CHANGES",
  "body": "<markdown>",
  "comments": [
    { "path": "src/api/routes.ts", "line": 5, "side": "RIGHT", "body": "**[ISSUE]** …" },
    { "path": "src/svc/acct.ts", "start_line": 41, "line": 48,
      "start_side": "LEFT", "side": "LEFT", "body": "**[SUGGESTION]** …" },
    { "path": "src/http/client.ts", "subject_type": "file", "body": "**[PRAISE]** …" }
  ]
}
```

`commit_id` is pinned to the detected head SHA so the service validates against
the commit that was reviewed, not whatever has landed since.

Verdict mapping: `approve` → `APPROVE`, `request_changes` → `REQUEST_CHANGES`,
`comment` → `COMMENT`.

`owner/repo` comes from `gh repo view --json nameWithOwner`, not from parsing
the remote URL, so SSH, HTTPS, and `gh`'s own host aliases all work.

The `gh` process is spawned with `vim.fn.jobstart`, `cwd = git_root`, buffered
stdout/stderr and a `timeout_ms` guard, following `providers/claude_cli.lua`.
Every invocation is recorded to the diagnostics log (`:IntentDiffLog`) with
argv, exit code, and a truncated stderr sample — never the comment text.

### Errors worth naming

- **422 from an unanchorable line.** The reviews API is atomic: one invalid
  comment rejects the entire review. Prevention is local (below); if one still
  lands, nothing was posted, and the flow offers a general-comment retry.
- **"Can not approve your own pull request".** Expected whenever the PR is the
  user's own, which is the common case when an agent pushes to the user's
  branch. Reported plainly, with an offer to re-post the identical review as a
  plain `COMMENT`.
- **`gh` missing or unauthenticated.** Reported with the failing command.

## Choosing anchorable lines locally

In `inline` mode the local checkout is, by definition, at the PR head with no
uncommitted changes in the commented files. The PR's diff is therefore
reproducible locally:

```
git merge-base origin/<base_ref> HEAD
git diff <merge-base>...HEAD -U3
```

`hunks.lua` already parses that output into per-file ranges. Each comment's
`(path, line, side)` is tested against those ranges — `new` against the modified
range, `old` against the original — using the same end-exclusive convention
`export.lua`'s `hunk_covers` uses. `-U3` matches the context GitHub renders, so
a comment on a context line is accepted exactly when GitHub would accept it.

Comments that fail the test are demoted into the review body before the POST,
and the count appears in the confirmation prompt. If the merge base cannot be
computed (no `origin/<base_ref>` locally), the whole submit degrades to
`general` mode with that as the stated reason, rather than guessing.

File-level comments are never tested: they post with `subject_type: "file"`,
which needs only the path to be in the diff.

## Payload composition

`comments/payload.lua` is pure — comments, model, mode, and the anchorable-set
predicate in, a `Payload` out — and holds no Neovim or network dependency.

**Inline mode.** Each anchorable comment becomes an inline comment whose body is
`**[TYPE]** <text>` and nothing more. The review body is the map:

```markdown
I reviewed your code and have the following comments. Please address them.

Comment types: ISSUE (problems to fix), SUGGESTION (improvements),
NOTE (observations), PRAISE (positive feedback)

## Rename UserService to AccountService

This rename missed the DI container entirely — see the inline comments.

- `src/api/routes.ts:5` — ISSUE
- `src/services/account.ts:~41` — SUGGESTION

## Add retry logic to HTTP client

- `src/http/client.ts` — PRAISE

## Not attached to a line

1. **[NOTE]** `src/http/client.ts:44-51`
   No jitter here — fine for now.
```

Whole-intent comments are prose under their heading; they address no line and
cannot be inline. Line comments contribute a one-line index entry only — their
text lives inline, and repeating it would show every comment twice on the PR.
Demoted and unmatched comments appear in full under `## Not attached to a line`,
since there is nowhere else for them to go. The `~` old-side notation and the
`file:line-line` range notation are `export.lua`'s, unchanged.

**General mode.** `body` is `export.generate(comments, model)` verbatim — the
Markdown the clipboard export already produces — and `comments` is empty. The
banner explaining why is shown in Neovim, not written into the PR.

### Refactor: shared bucketing

`export.lua`'s `group_index`, `hunk_covers` and the intents/items split are
local. `payload.lua` needs the same grouping. Rather than copy it:

```lua
--- @return { buckets: table<integer, { intents: Comment[], items: Comment[] }>,
---           unmatched: Comment[], flat: boolean }
function export.bucket(comments, model)
```

`export.generate` is rewritten to call it, with no change to its output — the
existing `comments_export_spec.lua` is the regression test for that, and must
pass untouched.

## Posted state

A successful submit stamps every comment it posted:

```lua
c.posted = { service = "github", target = "123", url = "<review url>", at = os.time() }
```

The store's existing `on_change` listener persists it — `storage.lua` encodes
whole comment tables with `vim.json.encode`, so no format change is needed and
older stores load unchanged (a comment with no `posted` field is unposted).

Consequences:

- A later submit offers only unposted comments, reporting
  `4 of 6 comments already posted to PR #123. Submit the 2 new ones?`.
- With nothing unposted, the flow offers a **verdict-only** submit — a review
  carrying the chosen verdict, a body stating it adds no new comments, and an
  empty `comments` array — or Cancel. Approving a PR whose comments were all
  posted in an earlier pass is the normal end of a two-sitting review, and
  stopping dead there would send the user to the browser for one click.
- `marks.build_box` renders a posted comment's header as `Issue · posted`. The
  suffix is appended by `marks`, from the presence of `c.posted`; box geometry
  is unchanged beyond the wider header.
- Editing a posted comment does **not** clear the stamp. The edit is local; the
  PR still holds what was sent. Re-posting an edited comment would create a
  second thread, which is worse than a stale local edit. The box keeps its
  `· posted` marker, which is the honest state.

## Interactive flow

```
<localleader>cP  /  :IntentDiffCommentsSubmit
  1. store exists and has comments      else: "no comments to submit"
  2. forge not disabled                 else: "review export is disabled"
  3. collect facts, detect target       errors surface verbatim
  4. preflight                          refuse on no_forge/default_branch/no_pr
  5. filter already-posted              "N of M already posted…";
                                        all posted -> verdict-only submit
  6. mode banner + confirm              inline, or general with the reason
  7. verdict select                     Approve / Request changes / Comment / Cancel
  8. POST                               one atomic review
  9. stamp posted, refresh marks, notify with the review URL
 10. "Close review tab?"                y closes via intentdiff.close(tabpage)
```

Steps 6 and 7 use `vim.ui.select`, matching `comments/init.lua`'s existing
pickers. Cancelling at 6, 7 or 10 leaves everything as it was.

`<localleader>q` (`export_and_close`) is untouched: it still copies Markdown and
closes. The GitHub path is reached only through the new key or command.

## Configuration

```lua
{
  -- Review-export target. "auto" resolves by remote host; a name loads
  -- intentdiff.forges.<name>; a table is used directly; false disables.
  forge = "auto",
  forge_opts = {
    github = { cmd = "gh", timeout_ms = 30000 },
  },
  keymaps = {
    comments = {
      submit_review = "<localleader>cP",
    },
  },
}
```

`forge_opts` is keyed by forge name so a second service's options do not collide
with GitHub's, and merges with `vim.tbl_deep_extend` like the rest of the
config. The new keymap is installed on the same surfaces as every other comment
key (panes and sidebar) and appears in the `g?` cheatsheet.

`:IntentDiffCommentsSubmit` is registered in `plugin/intentdiff.lua` behind the
same `comments_off()` guard as the other comment commands.

## Testing

All tests run offline. No test contacts a network service.

**Pure specs.**

- `forges_preflight_spec.lua` — every mode, the ordering of the checks, dirty
  files that carry no comment being ignored, a `nil` default branch skipping its
  check rather than blocking.
- `comments_payload_spec.lua` — inline vs general shape; the body index; ranges;
  old-side `~` notation; file-level comments; demoted comments appearing in full
  exactly once; a whole-intent comment as prose; the flat fallback when
  classification produced no groups.
- `comments_export_spec.lua` — unchanged, proving the `export.bucket` refactor
  did not move `generate`'s output.

**Process specs**, using the existing `helpers.fake_bin`:

- A fake `gh` recording argv and stdin to a temp file, asserting the exact JSON
  posted to `/pulls/N/reviews`: `commit_id`, `event`, comment shapes for a plain
  line, a range, an old-side line, and a file-level comment.
- `detect` against a fake `gh` answering: an open PR; `no pull requests found`;
  a closed PR; a non-zero exit with other stderr; a `gh` that does not exist.
- `submit` against a fake `gh` exiting non-zero with GitHub's
  "Can not approve your own pull request" body, asserting the COMMENT re-post
  offer.
- A 422 from an unanchorable line, asserting nothing is stamped `posted`.

**Anchoring spec** — a real temp repo via `helpers.make_repo`, a commit and a
branch, asserting which comments the local-diff test accepts and which are
demoted.

**Posted-state spec** — a stamped comment surviving a save/load round trip
through `storage.lua`, and a second submit offering only the unposted ones.

## Documentation

`README.md` gains a `### Submitting to a pull request` subsection under
`## Review comments`, covering the key and command, the two modes and what
triggers each, the four verdicts, the posted marker, and the `forge` /
`forge_opts` config. The existing Markdown export table is extended with the new
row. The keymap table under `## Keymaps` gains `<localleader>cP`.
