---`:Changeset comment`, `delete`, `abandon` and `submit`, which write, delete, clear and send to an agent the review
---comments kept on this machine, and the Comments rows' open and delete.
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
---@return string? err Why it wasn't kept, already reported.
local function keep(repository, comment)
  if not comment_store.keep(repository, comment) then
    say(vim.log.levels.ERROR, "can't keep the review comment in %s", comment_store.path())
    return "not kept"
  end
end

-- Extmarks move with edits while stored lines don't, so in a modified buffer a verb could act on the wrong line.
local UNSAVED = "save the file first: marks move with unsaved edits, review comments don't"

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
      done(keep(repository, vim.tbl_extend("force", comment, { body = body })))
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

---Opens the review comment window under line `last` of the current buffer, for lines `first` to `last`, or an
---existing comment to edit: for a range, the one on exactly that range; for one line, the narrowest covering it.
---Closing a new one keeps its text, so nothing typed is lost.
---@param first integer
---@param last integer
function M.comment(first, last)
  local repository = Paths.root(0)
  local path = file_path(repository)
  if not path then
    return say(vim.log.levels.WARN, "run `:Changeset comment` from a file in %s", repository)
  end
  if vim.bo.modified then
    return say(vim.log.levels.WARN, UNSAVED)
  end
  local existing
  if first < last then
    existing = vim.iter(comment_store.list(repository)):find(function(comment)
      return comment.path == path and comment.start_line == first and comment.line == last
    end)
  else
    existing = at(repository, path, last)
  end
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
      -- A blank keep would drop whatever was saved on this range meanwhile.
      if body:find("%S") then
        keep(repository, comment_of(body))
      end
    end,
    save = function(body, done)
      done(keep(repository, comment_of(body)))
    end,
  })
end

---Deletes the review comment on the cursor's line, the narrowest of those covering it.
function M.delete()
  if vim.bo.modified then
    return say(vim.log.levels.WARN, UNSAVED)
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

---Lines `first` to `last` of a file; nil when they can't all be read.
---@alias changeset.reviewing.ReadLines fun(path: string, first: integer, last: integer): string[]?

---The longest run of backticks in `lines`, at least 2, so a fence one longer is at least 3.
---@param lines string[]
---@return integer
local function longest_backticks(lines)
  local longest = 2
  for _, line in ipairs(lines) do
    for run in line:gmatch("`+") do
      longest = math.max(longest, #run)
    end
  end
  return longest
end

---One comment's block: its place, its lines fenced in the file's language, and its body.
---@param comment changeset.ReviewComment
---@param read changeset.reviewing.ReadLines
---@return string
local function block(comment, read)
  local first = comment.start_line or comment.line
  local location = first < comment.line and ("%s:%d-%d"):format(comment.path, first, comment.line)
    or ("%s:%d"):format(comment.path, comment.line)
  local parts = { location }
  local lines = read(comment.path, first, comment.line)
  if lines then
    local fence = ("`"):rep(longest_backticks(lines) + 1)
    parts[#parts + 1] = fence .. (vim.filetype.match({ filename = comment.path }) or "")
    vim.list_extend(parts, lines)
    parts[#parts + 1] = fence
  end
  parts[#parts + 1] = (comment.body:gsub("%s+$", ""))
  return table.concat(parts, "\n")
end

---The text a review is pasted as: a block per comment, by path, then line, a blank line between blocks.
---@param comments changeset.ReviewComment[]
---@param read changeset.reviewing.ReadLines
---@return string
function M._review_text(comments, read)
  local sorted = vim.list_slice(comments)
  table.sort(sorted, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.line < b.line
  end)
  return table.concat(
    vim.tbl_map(function(comment)
      return block(comment, read)
    end, sorted),
    "\n\n"
  )
end

---Reads lines of `repository`'s files from their loaded buffers, which hold unsaved edits, else from disk.
---@param repository string
---@return changeset.reviewing.ReadLines
local function reader(repository)
  return function(path, first, last)
    local full = vim.fs.joinpath(repository, path)
    -- Not `bufnr(full)`: it takes a pattern, and settles for another file whose name `full` prefixes.
    local buf = vim.iter(vim.api.nvim_list_bufs()):find(function(b)
      return vim.api.nvim_buf_is_loaded(b) and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == full
    end)
    local lines
    if buf then
      lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
    else
      local ok, read = pcall(vim.fn.readfile, full, "", last)
      lines = ok and vim.list_slice(read, first, last) or {}
    end
    if #lines == last - first + 1 then
      return lines
    end
  end
end

---Pastes the repository's review comments into an agent's prompt through herdr, then deletes the ones sent.
function M.submit()
  local repository = root()
  local comments = comment_store.list(repository)
  if #comments == 0 then
    return say(vim.log.levels.INFO, "no review comments to submit")
  end
  require("changeset.herdr").send(M._review_text(comments, reader(repository)), function(err, agent)
    if err then
      return say(vim.log.levels.WARN, "can't send the review: %s", err)
    end
    if not agent then
      return
    end
    local count = #comments == 1 and "1 comment" or ("%d comments"):format(#comments)
    -- Only what went: a comment written or edited while the pick was open stays.
    if not comment_store.drop_each(repository, comments) then
      return say(
        vim.log.levels.WARN,
        "sent the review's %s to %s, but they are still listed: can't remove them from %s",
        count,
        agent,
        comment_store.path()
      )
    end
    say(vim.log.levels.INFO, "sent the review's %s to %s", count, agent)
  end)
end

return M
