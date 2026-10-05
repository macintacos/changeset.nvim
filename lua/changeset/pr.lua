---`:Changeset pr`'s verbs: start, submit and abandon the pending review on the branch's open PR, add a review comment to it, edit one or reopen a draft, and delete a draft or one of its review comments.
local Git = require("changeset.git")
local Paths = require("changeset.paths")
local build = require("changeset.build")
local commentable = require("changeset.commentable")
local config = require("changeset.config")
local confirm = require("changeset.confirm")
local drafts = require("changeset.drafts")
local pending_review = require("changeset.pending_review")
local pending_state = require("changeset.pending_state")
local review_comment_window = require("changeset.review_comment_window")
local submit_window = require("changeset.submit_window")
local submittable = require("changeset.submittable")
local window = require("changeset.window")

local M = {}

---The repository to act on: the tree's when the command runs from the sidebar, whose own buffer
---names none, else the current buffer's, as `build` resolves it.
---@return string
local function root()
  local tree = build.current()
  if window.is_focused() and tree then
    return tree.root
  end
  return Paths.root(0)
end

---@param count integer
---@return string
local function review_comments(count)
  return count .. (count == 1 and " review comment" or " review comments")
end

---@param level integer
---@param text string
local function say(level, text, ...)
  vim.notify("Changeset: " .. text:format(...), level)
end

---Shows `text` as a running progress message, which UIs such as fidget draw as a spinner, until
---the returned function ends it.
---@param text string
---@return fun(err: string?) finish Ends it failed when given an error.
local function progress(text)
  local opts = { kind = "progress", source = "changeset", title = "Changeset", status = "running" }
  opts.id = vim.api.nvim_echo({ { text } }, false, opts)
  return function(err)
    opts.status = err and "failed" or "success"
    vim.api.nvim_echo({ { text } }, false, opts)
  end
end

---Changes the pending review: progress shows while `mutation` waits on gh, then it reports and refetches.
---@alias changeset.pr.Mutate fun(did: string, mutation: fun(done: fun(err: string?)))

---Finds the branch's PR and pending review and hands them to `act`, which may answer itself or
---change the review through `mutate`. `mutate` shows progress while `mutation` waits on gh, then
---reports and refetches, so the header always follows a change. Progress never runs while `act`
---waits on the user.
---@param verb string Reads between "can't" and "a pending review": "start", "abandon", "delete a review comment from".
---@param act fun(found: changeset.pending_review.Found, mutate: changeset.pr.Mutate)
local function on_pr(verb, act)
  local repository = root()
  local finish = progress("asking GitHub for the PR's pending review")
  pending_state.fetch(repository, function(err, found)
    finish(err)
    if not found then
      return say(vim.log.levels.WARN, "can't %s a pending review: %s", verb, err)
    end
    local number = found.pr.number
    act(found, function(did, mutation)
      local finish_mutation = progress(("asking GitHub to %s the pending review on #%d"):format(verb, number))
      mutation(function(mutation_err)
        finish_mutation(mutation_err)
        if mutation_err then
          say(vim.log.levels.ERROR, "can't %s the pending review: %s", verb, mutation_err)
        else
          say(vim.log.levels.INFO, "%s the pending review on #%d", did, number)
        end
        pending_state.fetch(repository)
      end)
    end)
  end)
end

---Starts a pending review on the branch's open PR, unless one is already under way.
function M.start()
  on_pr("start", function(found, mutate)
    if found.review then
      return say(vim.log.levels.INFO, "a pending review is already under way on #%d", found.pr.number)
    end
    mutate("started", function(done)
      pending_review.start(found.pr.id, done)
    end)
  end)
end

---Asks, then deletes the pending review on the branch's open PR, every review comment in it, and the PR's drafts.
function M.abandon()
  on_pr("abandon", function(found, mutate)
    local number, review = found.pr.number, found.review
    if not review then
      return say(vim.log.levels.INFO, "no pending review on #%d", number)
    end
    local question = ("Abandon the pending review on #%d and its %s?"):format(number, review_comments(#review.comments))
    confirm.ask(question, function()
      mutate("abandoned", function(done)
        pending_review.delete(review.id, function(err)
          if not err then
            drafts.drop_all(found.pr)
          end
          done(err)
        end)
      end)
    end)
  end)
end

---Previews the pending review on the branch's open PR, then submits it with the event and body chosen there.
function M.submit()
  on_pr("submit", function(found, mutate)
    local review = found.review
    if not review then
      return say(vim.log.levels.INFO, "no pending review on #%d", found.pr.number)
    end
    submit_window.open({
      number = found.pr.number,
      events = submittable.events(found.pr.viewer_did_author),
      comments = review.comments,
      drafts = drafts.list(found.pr),
      keys = config.get().review_comment.save,
      submit = function(submission, settled)
        local reason = submittable.refusal(submission, #review.comments)
        if reason then
          say(vim.log.levels.WARN, "can't submit the pending review: %s", reason)
          return settled(reason)
        end
        mutate("submitted", function(done)
          pending_review.submit(review.id, submission, function(err)
            settled(err)
            done(err)
          end)
        end)
      end,
    })
  end)
end

---"line 4", or "lines 3-5" for a range.
---@param first integer
---@param last integer
---@return string
local function lines_label(first, last)
  return first < last and ("lines %d-%d"):format(first, last) or ("line %d"):format(last)
end

---Where `spanned` sits, for a sentence: "line 4 of a.lua", or "a.lua" when it has no line.
---@param spanned changeset.Spanned
---@return string
local function place(spanned)
  local last = spanned.line
  if not last then
    return spanned.path
  end
  return ("%s of %s"):format(lines_label(spanned.start_line or last, last), spanned.path)
end

---Deletes `draft` of `pr` from this machine.
---@param pr changeset.Pr
---@param draft changeset.Draft
local function drop(pr, draft)
  -- GitHub holds nothing to refetch; the drafts subscription redraws the mark.
  if not drafts.drop(pr, draft) then
    return say(vim.log.levels.ERROR, "can't delete the draft in %s", drafts.path())
  end
  say(vim.log.levels.INFO, "deleted the draft on %s", place(draft))
end

---Deletes `listed`: a draft of `found.pr` at once, or a review comment of its pending review through `mutate`.
---@param found changeset.pending_review.Found
---@param mutate changeset.pr.Mutate
---@param listed changeset.Listed
local function remove(found, mutate, listed)
  if listed.draft then
    return drop(found.pr, listed.draft)
  end
  local id = assert(listed.review_comment, "changeset: nothing listed to delete").id
  mutate("deleted a review comment from", function(done)
    pending_review.delete_comment(id, done)
  end)
end

---Asks, then deletes `listed`, a draft of the branch's open PR or a review comment of its pending review. A draft
---is keyed by the PR in GitHub's last answer, the one the Comments section was drawn from, so gh needn't answer.
---@param listed changeset.Listed
function M.delete_listed(listed)
  local what = listed.draft and "draft" or "review comment"
  local spanned = listed.draft or listed.review_comment --[[@as changeset.Spanned]]
  local question = ("Delete the %s on %s?"):format(what, place(spanned))
  local tree = build.current()
  local held = tree and tree.pr and pending_state.get(tree.root, tree.pr)
  confirm.ask(question, function()
    if listed.draft and held then
      return drop(held.pr, listed.draft)
    end
    on_pr("delete a review comment from", function(found, mutate)
      remove(found, mutate, listed)
    end)
  end)
end

---Deletes the draft on the cursor's line, else the review comment there in the pending review on the branch's open PR.
function M.delete()
  -- Extmarks move with edits while review comment lines don't, so a modified buffer could delete the wrong one.
  if vim.bo.modified then
    return say(vim.log.levels.WARN, "save the file first: marks move with unsaved edits, review comments don't")
  end
  local path = vim.fs.relpath(root(), vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  on_pr("delete a review comment from", function(found, mutate)
    local draft = path and require("changeset.review_comments").at(drafts.list(found.pr), path, lnum)
    if draft then
      return remove(found, mutate, { draft = draft })
    end
    if not found.review then
      return say(vim.log.levels.INFO, "no pending review on #%d", found.pr.number)
    end
    local comment = path and require("changeset.review_comments").at(found.review.comments, path, lnum)
    if not comment then
      return say(vim.log.levels.INFO, "no review comment on line %d", lnum)
    end
    remove(found, mutate, { review_comment = comment })
  end)
end

---The hunks the tree holds for `path`; none for a deleted file, whose one hunk at line 0 would read as
---taking review comments on lines 1-3.
---@param tree changeset.Tree
---@param path string
---@return changeset.Hunk[]
local function hunks(tree, path)
  for _, file in ipairs(tree.files) do
    if file.path == path and file.status ~= "deleted" then
      return file.hunks
    end
  end
  return {}
end

---Hands a pending review's node ID, or why there is none, to `cb` once GitHub has answered.
---@alias changeset.pr.Review fun(cb: fun(err: string?, review_id: string?))

---Hands `cb` GitHub's last answer for the tree's PR, asking first when there is none yet.
---@param tree changeset.Tree
---@param cb fun(found: changeset.pending_review.Found)
local function with_found(tree, cb)
  local found = pending_state.get(tree.root, tree.pr)
  if found then
    return cb(found)
  end
  local finish = progress("asking GitHub for the PR's pending review")
  pending_state.fetch(tree.root, function(err)
    finish(err)
    found = pending_state.get(tree.root, tree.pr)
    if not found then
      return say(vim.log.levels.WARN, "can't add a review comment: %s", err or "try again in a moment")
    end
    cb(found)
  end)
end

---Starts a pending review on `pr` behind a review comment being written. GitHub refuses a second
---pending review, so a refusal may mean one was started meanwhile, which is then saved into instead.
---@param repository string
---@param pr changeset.pending_review.Pr
---@return changeset.pr.Review
local function start_behind(repository, pr)
  local answer, waiting = nil, {}
  ---@param err string?
  ---@param id string?
  local function settle(err, id)
    answer = { err = err, id = id }
    for _, cb in ipairs(waiting) do
      cb(err, id)
    end
  end
  local finish = progress(("asking GitHub to start the pending review on #%d"):format(pr.number))
  pending_review.start(pr.id, function(err, review)
    if review then
      finish()
      say(vim.log.levels.INFO, "started the pending review on #%d", pr.number)
      settle(nil, review.id)
      return pending_state.fetch(repository)
    end
    pending_state.fetch(repository, function()
      local found = pending_state.get(repository, pr.number)
      if found and found.review then
        finish()
        return settle(nil, found.review.id)
      end
      finish(err)
      say(vim.log.levels.ERROR, "can't start the pending review: %s", err)
      settle(err)
    end)
  end)
  return function(cb)
    if answer then
      return cb(answer.err, answer.id)
    end
    table.insert(waiting, cb)
  end
end

---Opens the review comment window under line `last` of the current buffer, for lines `first` to `last`,
---unless the pending review can't take a review comment there. With no pending review, it asks to
---start one. Opening asks GitHub nothing unless it has yet to answer for the PR.
---A draft reopens instead, on its own lines and unchecked: `reopen`, else the one on line `last`.
---@param first integer
---@param last integer
---@param reopen changeset.Draft?
function M.comment(first, last, reopen)
  local buf, tree = vim.api.nvim_get_current_buf(), build.current()
  if not tree then
    return say(vim.log.levels.WARN, "open the sidebar on this file's repository first, so the PR's diff is read")
  end
  local name = vim.api.nvim_buf_get_name(buf)
  -- relpath prefixes the cwd to a relative name, so a non-file buffer would pass from inside the repo.
  local path = vim.bo[buf].buftype == "" and name ~= "" and vim.fs.relpath(tree.root, vim.fs.normalize(name))
  if not path then
    return say(vim.log.levels.WARN, "run `:Changeset pr comment` from a file in %s", tree.root)
  end
  if not tree.collected then
    return say(vim.log.levels.WARN, "still reading the diff; try again in a moment")
  end
  if not tree.pr then
    return say(vim.log.levels.WARN, "the diff isn't measured against an open PR, so there's no review to add to")
  end
  with_found(tree, function(found)
    -- The window opens in the current one, which a wait on GitHub may have moved away.
    if vim.api.nvim_get_current_buf() ~= buf then
      return
    end
    local draft = reopen or require("changeset.review_comments").at(drafts.list(found.pr), path, last)
    if draft then
      -- Its lines passed the gates below when it was written at this head; a save GitHub rejects keeps it.
      first, last = draft.start_line or draft.line, draft.line
    else
      local matches_head = Git.matches_commit(tree.root, found.pr.head, path)
      if matches_head == nil then
        return say(
          vim.log.levels.WARN,
          "the PR's head, %s, isn't in this clone; fetch it first",
          found.pr.head:sub(1, 7)
        )
      end
      local refusal = commentable.refusal(hunks(tree, path), { first, last }, matches_head and not vim.bo[buf].modified)
      if refusal then
        return say(vim.log.levels.WARN, "can't add a review comment here: %s", refusal)
      end
    end
    ---@param body string
    ---@return changeset.Draft
    local function draft_of(body)
      return { path = path, line = last, start_line = first < last and first or nil, head = found.pr.head, body = body }
    end
    local number = found.pr.number
    ---@param review changeset.pr.Review The pending review a save goes into.
    local function open(review)
      review_comment_window.open({
        line = last,
        title = "Review comment · " .. lines_label(first, last),
        save_desc = "Save into the pending review",
        close_desc = "Close, keeping the text as a draft",
        footer = ("pending review on #%d"):format(number),
        keys = config.get().review_comment.save,
        body = draft and draft.body,
        keep = function(body)
          if not drafts.keep(found.pr, draft_of(body)) then
            say(vim.log.levels.ERROR, "can't keep the draft in %s", drafts.path())
          end
        end,
        save = function(body, done)
          ---@param err string?
          local function saved(err)
            if err then
              -- Now rather than on close: the window stays open, and may never close.
              if drafts.keep(found.pr, draft_of(body)) then
                say(vim.log.levels.ERROR, "can't save the review comment, so kept it as a draft: %s", err)
              else
                say(vim.log.levels.ERROR, "can't save the review comment, nor keep it in %s: %s", drafts.path(), err)
              end
            else
              -- A reopened draft, or one a close kept while this save was in flight.
              drafts.drop(found.pr, draft_of(body))
              say(vim.log.levels.INFO, "added a review comment to the pending review on #%d", number)
              pending_state.fetch(tree.root)
            end
            done(err)
          end
          review(function(err, review_id)
            if err then
              return saved(err)
            end
            local new = { path = path, line = last, start_line = first < last and first or nil, body = body }
            pending_review.add_comment(review_id, new, saved)
          end)
        end,
      })
    end
    if found.review then
      local id = found.review.id
      return open(function(saving)
        saving(nil, id)
      end)
    end
    confirm.ask(("Start a pending review on #%d?"):format(number), function()
      -- Answering can move the cursor too, and the window opens in the current one.
      if vim.api.nvim_get_current_buf() ~= buf then
        return
      end
      open(start_behind(tree.root, found.pr))
    end)
  end)
end

---Opens the window under `comment`'s lines of the current buffer, holding its text: a save updates it in the
---pending review, and closing it blank asks to delete it. Closing it otherwise drops the edit, never keeping a
---draft: one would reopen through `M.comment` as a second review comment on those lines.
---@param comment changeset.ReviewComment
local function edit(comment)
  local buf, tree = vim.api.nvim_get_current_buf(), assert(build.current(), "changeset: no tree built yet")
  with_found(tree, function(found)
    -- The window opens in the current one, which a wait on GitHub may have moved away.
    if vim.api.nvim_get_current_buf() ~= buf then
      return
    end
    local number = found.pr.number
    local last = assert(comment.line, "changeset: a review comment with no line can't be edited under it")
    review_comment_window.open({
      line = last,
      title = "Edit review comment · " .. lines_label(comment.start_line or last, last),
      save_desc = "Update the review comment in the pending review",
      close_desc = "Close, dropping the edit",
      footer = ("edit in pending review on #%d"):format(number),
      keys = config.get().review_comment.save,
      body = comment.body,
      keep = function(body)
        if not body:find("%S") then
          -- Scheduled: the question opens a window, and this one is still closing.
          return vim.schedule(function()
            M.delete_listed({ review_comment = comment })
          end)
        end
        if body ~= comment.body then
          say(vim.log.levels.INFO, "closed without updating, so the review comment keeps its saved text")
        end
      end,
      save = function(body, done)
        pending_review.update_comment(comment.id, body, function(err)
          if err then
            say(vim.log.levels.ERROR, "can't update the review comment: %s", err)
          else
            say(vim.log.levels.INFO, "updated a review comment in the pending review on #%d", number)
            pending_state.fetch(tree.root)
          end
          done(err)
        end)
      end,
    })
  end)
end

---Opens `listed` under its lines of the current buffer: a draft reopens as `M.comment` reopens one, and a
---review comment opens editable. One with no line, outdated or on the whole file, opens nothing.
---@param listed changeset.Listed
function M.open_listed(listed)
  local draft = listed.draft
  if draft then
    return M.comment(draft.start_line or draft.line, draft.line, draft)
  end
  local comment = assert(listed.review_comment, "changeset: nothing listed to open")
  if not comment.line then
    local why = comment.outdated and "it's outdated, its line changed since it was written" or "it's on the whole file"
    return say(vim.log.levels.INFO, "the review comment on %s has no line to open under: %s", comment.path, why)
  end
  edit(comment)
end

return M
