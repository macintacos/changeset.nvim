---`:Changeset comment`, `delete` and `abandon`, which write, delete and clear the review comments kept on this
---machine, and the Comments rows' open and delete.
local Paths = require("changeset.paths")
local build = require("changeset.build")
local comment_store = require("changeset.comment_store")
local config = require("changeset.config")
local confirm = require("changeset.confirm")
local review_comment_window = require("changeset.review_comment_window")
local review_comments = require("changeset.review_comments")
local window = require("changeset.window")

local M = {}

local FOOTER = "kept until :Changeset submit"

---The repository to act on: the tree's when the command runs from the sidebar, whose own buffer
---names none, else the current buffer's.
---@return string
local function root()
  local tree = build.current()
  if window.is_focused() and tree then
    return tree.root
  end
  return Paths.root(0)
end

---@param level integer
---@param text string
local function say(level, text, ...)
  vim.notify("Changeset: " .. text:format(...), level)
end

---"line 4", or "lines 3-5" for a range.
---@param first integer
---@param last integer
---@return string
local function lines_label(first, last)
  return first < last and ("lines %d-%d"):format(first, last) or ("line %d"):format(last)
end

---Where `comment` sits, for a sentence: "line 4 of a.lua".
---@param comment changeset.ReviewComment
---@return string
local function place(comment)
  return ("%s of %s"):format(lines_label(comment.start_line or comment.line, comment.line), comment.path)
end

---@param repository string
---@param comment changeset.ReviewComment
local function drop(repository, comment)
  if not comment_store.drop(repository, comment) then
    return say(vim.log.levels.ERROR, "can't delete the review comment in %s", comment_store.path())
  end
  say(vim.log.levels.INFO, "deleted the review comment on %s", place(comment))
end

---@param repository string
---@param comment changeset.ReviewComment
local function keep(repository, comment)
  if not comment_store.keep(repository, comment) then
    say(vim.log.levels.ERROR, "can't keep the review comment in %s", comment_store.path())
  end
end

---Asks, then deletes `comment` of the current buffer's repository.
---@param comment changeset.ReviewComment
function M.ask_delete(comment)
  local repository = root()
  confirm.ask(("Delete the review comment on %s?"):format(place(comment)), function()
    drop(repository, comment)
  end)
end

---Opens the window under `comment`'s lines of the current buffer, holding its text: a save replaces it, and a
---blank save or close asks to delete it. Closing it otherwise drops the edit.
---@param comment changeset.ReviewComment
function M.open(comment)
  local repository = Paths.root(0)
  local last = comment.line
  ---@param body string
  local function asked_blank(body)
    if body:find("%S") then
      return false
    end
    -- Scheduled: the question opens a window, and this one is still closing.
    vim.schedule(function()
      M.ask_delete(comment)
    end)
    return true
  end
  review_comment_window.open({
    line = last,
    title = "Edit review comment · " .. lines_label(comment.start_line or last, last),
    save_desc = "Update the review comment",
    close_desc = "Close, dropping the edit",
    footer = FOOTER,
    keys = config.get().review_comment.save,
    body = comment.body,
    keep = function(body)
      if not asked_blank(body) and body ~= comment.body then
        say(vim.log.levels.INFO, "closed without updating, so the review comment keeps its saved text")
      end
    end,
    save = function(body, done)
      keep(repository, vim.tbl_extend("force", comment, { body = body }))
      done()
    end,
  })
end

---The comment at the current buffer's file and line `lnum`, the narrowest of those covering it.
---@param repository string
---@param path string
---@param lnum integer
---@return changeset.ReviewComment?
local function at(repository, path, lnum)
  return review_comments.at(comment_store.list(repository), path, lnum)
end

---The current buffer's path in its repository; nil for a buffer that isn't a file there.
---@param repository string
---@return string?
local function file_path(repository)
  local name = vim.api.nvim_buf_get_name(0)
  -- relpath prefixes the cwd to a relative name, so a non-file buffer would pass from inside the repo.
  return vim.bo.buftype == "" and name ~= "" and vim.fs.relpath(repository, vim.fs.normalize(name)) or nil
end

---Opens the review comment window under line `last` of the current buffer, for lines `first` to `last`, or the
---comment already covering line `last` to edit it. Closing a new one keeps its text, so nothing typed is lost.
---@param first integer
---@param last integer
function M.comment(first, last)
  local repository = Paths.root(0)
  local path = file_path(repository)
  if not path then
    return say(vim.log.levels.WARN, "run `:Changeset comment` from a file in %s", repository)
  end
  local existing = at(repository, path, last)
  if existing then
    return M.open(existing)
  end
  ---@param body string
  ---@return changeset.ReviewComment
  local function comment_of(body)
    return { path = path, line = last, start_line = first < last and first or nil, body = body }
  end
  review_comment_window.open({
    line = last,
    title = "Review comment · " .. lines_label(first, last),
    save_desc = "Keep the review comment",
    close_desc = "Close, keeping the text",
    footer = FOOTER,
    keys = config.get().review_comment.save,
    keep = function(body)
      keep(repository, comment_of(body))
    end,
    save = function(body, done)
      keep(repository, comment_of(body))
      done()
    end,
  })
end

---Deletes the review comment on the cursor's line, the narrowest of those covering it.
function M.delete()
  -- Extmarks move with edits while stored lines don't, so a modified buffer could delete the wrong one.
  if vim.bo.modified then
    return say(vim.log.levels.WARN, "save the file first: marks move with unsaved edits, review comments don't")
  end
  local repository = Paths.root(0)
  local path = file_path(repository)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local comment = path and at(repository, path, lnum)
  if not comment then
    return say(vim.log.levels.INFO, "no review comment on line %d", lnum)
  end
  drop(repository, comment)
end

---Asks, then deletes every review comment of the repository.
function M.abandon()
  local repository = root()
  local count = #comment_store.list(repository)
  if count == 0 then
    return say(vim.log.levels.INFO, "no review to abandon in %s", repository)
  end
  local question = ("Abandon the review and its %d review comment%s?"):format(count, count == 1 and "" or "s")
  confirm.ask(question, function()
    if not comment_store.drop_all(repository) then
      return say(vim.log.levels.ERROR, "can't abandon the review in %s", comment_store.path())
    end
    say(vim.log.levels.INFO, "abandoned the review")
  end)
end

return M
