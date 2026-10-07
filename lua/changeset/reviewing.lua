---`:Changeset comment`, `delete`, `abandon`, `submit`, `next-comment`, `prev-comment`, `list` and `yank`, which write,
---delete, clear, paste into an agent's prompt, walk, list and copy the review comments kept on this machine, and the
---Comments rows' open and delete.
local Paths = require("changeset.paths")
local buffers = require("changeset.buffers")
local build = require("changeset.build")
local comment_store = require("changeset.comment_store")
local config = require("changeset.config")
local dialog = require("changeset.dialog")
local render = require("changeset.render")
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

local lines_label = review_comments.lines_label

---Where `comment` sits, as the Comments row and the pasted review name it: "a.lua:4", or "a.lua:3-5" for a range.
---@param comment changeset.ReviewComment
---@return string
local function location(comment)
  local first = comment.start_line or comment.line
  return first < comment.line and ("%s:%d-%d"):format(comment.path, first, comment.line)
    or ("%s:%d"):format(comment.path, comment.line)
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
    -- Scheduled: a save from the window's insert-mode keys picks writing back up first, and its -- INSERT -- would
    -- clear the error.
    vim.schedule(function()
      say(vim.log.levels.ERROR, "can't keep the review comment in %s", comment_store.path())
    end)
    return "not kept"
  end
end

-- Lines of a review comment's body the delete dialog quotes: enough to tell it apart, short of a wall of text.
local QUOTED = 4

---Why a verb that acts by line refuses in a modified buffer: extmarks move with edits while stored lines don't, so it
---could act on the wrong line.
M.UNSAVED = "save the file first: marks move with unsaved edits, review comments don't"

---Asks, then deletes `comment` of the current buffer's repository.
---@param comment changeset.ReviewComment
function M.ask_delete(comment)
  local repository = root()
  dialog.confirm({
    title = "Delete the review comment",
    body = {
      { text = location(comment), hl = render.META_HL, path = true },
      { text = comment.body, quote = render.REVIEW_COMMENT_HL, max_lines = QUOTED },
    },
    action = "Delete",
  }, function()
    drop(repository, comment)
  end)
end

---Notified, not echoed, so a notifier keeps it.
local function say_draft()
  -- Scheduled, so it comes after the message of a subcommand run from the window and replaces it, rather than
  -- stacking under it into a hit-enter prompt.
  vim.schedule(function()
    say(vim.log.levels.INFO, "kept the review comment as a draft")
  end)
end

---`comment` with `body`, saved, or a draft when `draft` is set.
---@param comment changeset.ReviewComment
---@param body string
---@param draft true?
---@return changeset.ReviewComment
local function with_body(comment, body, draft)
  return { path = comment.path, line = comment.line, start_line = comment.start_line, body = body, draft = draft }
end

---Opens the window under `comment`'s lines of the current buffer, holding its text: a save replaces it, a blank
---save or close asks to delete it, and a close with changed text keeps it as a draft.
---@param comment changeset.ReviewComment
function M.open(comment)
  local repository = Paths.root(0)
  local last = comment.line
  local kind = comment.draft and "Edit draft review comment · " or "Edit review comment · "
  review_comment_window.open({
    line = last,
    title = kind .. lines_label(comment.start_line or last, last),
    save_desc = "Save the review comment",
    close_desc = "Close, keeping the text as a draft",
    footer = FOOTER,
    keys = config.get().review_comment.save,
    body = comment.body,
    comment = comment,
    keep = function(body)
      if not body:find("%S") then
        -- Scheduled: the question opens a window, and this one is still closing.
        return vim.schedule(function()
          M.ask_delete(comment)
        end)
      end
      if body ~= comment.body and not keep(repository, with_body(comment, body, true)) then
        say_draft()
      end
    end,
    save = function(body, done)
      done(keep(repository, with_body(comment, body)))
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

---`buf`'s path in its repository; nil for a buffer that isn't a file there.
---@param repository string
---@param buf integer
---@return string?
local function file_path(repository, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  -- relpath prefixes the cwd to a relative name, so a non-file buffer would pass from inside the repo.
  return vim.bo[buf].buftype == "" and name ~= "" and vim.fs.relpath(repository, vim.fs.normalize(name)) or nil
end

---Opens the review comment window under line `last` of the current buffer, for lines `first` to `last`, or an
---existing comment to edit: for a range, the one on exactly that range; for one line, the narrowest covering it.
---Closing a new one keeps its text, so nothing typed is lost.
---@param first integer
---@param last integer
function M.comment(first, last)
  local repository = Paths.root(0)
  local path = file_path(repository, 0)
  if not path then
    return say(vim.log.levels.WARN, "run `:Changeset comment` from a file in %s", repository)
  end
  if vim.bo.modified then
    return say(vim.log.levels.WARN, M.UNSAVED)
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
    save_desc = "Save the review comment",
    close_desc = "Close, keeping the text as a draft",
    footer = FOOTER,
    keys = config.get().review_comment.save,
    comment = comment_of(""),
    keep = function(body)
      -- A blank keep would drop whatever was saved on this range meanwhile.
      if body:find("%S") then
        local draft = comment_of(body)
        draft.draft = true
        if not keep(repository, draft) then
          say_draft()
        end
      end
    end,
    save = function(body, done)
      done(keep(repository, comment_of(body)))
    end,
  })
end

---Deletes the comment being written in `open`: asks first when it is stored or holds text, else just closes.
---@param open changeset.ReviewCommentWindow
local function delete_open(open)
  local repository = Paths.root(vim.api.nvim_win_get_buf(open.source))
  local stored = vim.iter(comment_store.list(repository)):find(function(comment)
    return comment.path == open.comment.path
      and comment.line == open.comment.line
      and comment.start_line == open.comment.start_line
  end)
  local text = open.text()
  if not stored and not text:find("%S") then
    return open.discard()
  end
  open.hold(function()
    dialog.confirm({
      title = "Delete the review comment",
      body = {
        { text = location(open.comment), hl = render.META_HL, path = true },
        { text = text:find("%S") and text or stored.body, quote = render.REVIEW_COMMENT_HL, max_lines = QUOTED },
      },
      action = "Delete",
    }, function()
      -- Once the window has gone, so insert mode ending in it doesn't clear the notice.
      open.discard(function()
        if stored then
          drop(repository, stored)
        end
      end)
    end)
  end)
end

---The repository's review comment saved last: the store appends on every keep, so its last saved entry.
---@param repository string
---@return changeset.ReviewComment?
local function last_saved(repository)
  local comments = comment_store.list(repository)
  for i = #comments, 1, -1 do
    if not comments[i].draft then
      return comments[i]
    end
  end
end

---Runs subcommand `name` from the review comment window `open`: `comment` saves it, `delete` deletes it, and any
---other closes it, keeping a draft, then calls `run` from the comment's first line in the window it opened from.
---@param open changeset.ReviewCommentWindow
---@param name string
---@param run fun()
function M.from_window(open, name, run)
  if name == "comment" then
    return open.save()
  end
  if name == "delete" then
    return delete_open(open)
  end
  if name == "last-comment" then
    local last = last_saved(Paths.root(vim.api.nvim_win_get_buf(open.source)))
    if
      last
      and last.path == open.comment.path
      and last.line == open.comment.line
      and last.start_line == open.comment.start_line
    then
      open.resume()
      -- After insert mode restarts, whose -- INSERT -- would clear it.
      return vim.schedule(function()
        vim.api.nvim_echo({ { "already editing the review comment saved last" } }, false, {})
      end)
    end
  end
  open.close(function()
    if not vim.api.nvim_win_is_valid(open.source) then
      return
    end
    vim.api.nvim_set_current_win(open.source)
    local lnum = math.min(open.comment.start_line or open.comment.line, vim.api.nvim_buf_line_count(0))
    vim.api.nvim_win_set_cursor(open.source, { lnum, 0 })
    run()
  end)
end

---Deletes the review comment on the cursor's line, the narrowest of those covering it.
function M.delete()
  if vim.bo.modified then
    return say(vim.log.levels.WARN, M.UNSAVED)
  end
  local repository = Paths.root(0)
  local path = file_path(repository, 0)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local comment = path and at(repository, path, lnum)
  if not comment then
    return say(vim.log.levels.INFO, "no review comment on line %d", lnum)
  end
  drop(repository, comment)
end

---"1 draft", "2 drafts".
---@param n integer
---@return string
local function drafts_label(n)
  return n == 1 and "1 draft" or ("%d drafts"):format(n)
end

---`comments` split into the saved ones and how many are drafts.
---@param comments changeset.ReviewComment[]
---@return changeset.ReviewComment[] saved, integer drafts
local function split_drafts(comments)
  local saved = vim.tbl_filter(function(comment)
    return not comment.draft
  end, comments)
  return saved, #comments - #saved
end

---Asks, then deletes every review comment of the repository.
function M.abandon()
  local repository = root()
  local comments = comment_store.list(repository)
  local count, drafts = #comments, select(2, split_drafts(comments))
  if count == 0 then
    return say(vim.log.levels.INFO, "no review to abandon in %s", repository)
  end
  local name = vim.fs.basename(repository)
  dialog.confirm({
    title = "Abandon the review",
    body = {
      {
        text = count == 1 and ("Deletes the %sreview comment in %s. It can't be brought back."):format(
          drafts == 1 and "draft " or "",
          name
        ) or ("Deletes all %d review comments in %s%s. They can't be brought back."):format(
          count,
          name,
          drafts == 0 and "" or ("; %d %s a draft"):format(drafts, drafts == 1 and "is" or "are")
        ),
      },
    },
    action = "Abandon",
  }, function()
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
  local parts = { location(comment) }
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

---The loaded buffer of the file at `full`, if any.
---@param full string
---@return integer?
local function loaded(full)
  -- Not `bufnr(full)`: it takes a pattern, and settles for another file whose name `full` prefixes.
  return vim.iter(vim.api.nvim_list_bufs()):find(function(b)
    return vim.api.nvim_buf_is_loaded(b) and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == full
  end)
end

---Reads lines of `repository`'s files from their loaded buffers, which hold unsaved edits, else from disk.
---@param repository string
---@return changeset.reviewing.ReadLines
local function reader(repository)
  return function(path, first, last)
    local full = vim.fs.joinpath(repository, path)
    local buf = loaded(full)
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

---Pastes the repository's saved review comments into an agent's prompt through herdr, then deletes the ones pasted.
---Drafts stay.
function M.submit()
  local repository = root()
  local comments, drafts = split_drafts(comment_store.list(repository))
  if #comments == 0 then
    if drafts > 0 then
      return say(vim.log.levels.INFO, "nothing saved to submit, only %s", drafts_label(drafts))
    end
    return say(vim.log.levels.INFO, "no review comments to submit")
  end
  local staying = drafts > 0 and ("; %s %s"):format(drafts_label(drafts), drafts == 1 and "stays" or "stay") or ""
  require("changeset.herdr").send(M._review_text(comments, reader(repository)), function(err, agent)
    if err then
      return say(vim.log.levels.WARN, "can't submit the review: %s", err)
    end
    if not agent then
      return
    end
    local count = #comments == 1 and "1 comment waits" or ("%d comments wait"):format(#comments)
    -- Only what went: a comment written or edited while the pick was open stays.
    if not comment_store.drop_each(repository, comments) then
      return say(
        vim.log.levels.WARN,
        "submitted the review to %s: its %s in the prompt, but they are still listed: can't remove them from %s",
        agent,
        count,
        comment_store.path()
      )
    end
    say(vim.log.levels.INFO, "submitted the review to %s: its %s in the prompt%s", agent, count, staying)
  end)
end

---@param comment changeset.ReviewComment
---@return integer
local function first_line(comment)
  return comment.start_line or comment.line
end

---`comments` by path, then first line, the order the Comments section lists them in.
---@param comments changeset.ReviewComment[]
---@return changeset.ReviewComment[]
local function in_order(comments)
  local sorted = vim.list_slice(comments)
  table.sort(sorted, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return first_line(a) < first_line(b)
  end)
  return sorted
end

---Where `comment` starts against line `lnum` of `path`, `count` lines long, in the order of `in_order`: 1 after,
----1 before, 0 there. A comment past the end starts on the last line, where a jump to it lands.
---@param comment changeset.ReviewComment
---@param path string
---@param lnum integer
---@param count integer
---@return integer
local function side(comment, path, lnum, count)
  if comment.path ~= path then
    return comment.path > path and 1 or -1
  end
  local first = math.min(first_line(comment), count)
  return first > lnum and 1 or first < lnum and -1 or 0
end

---Index of the comment `step` away from the cursor in `comments`, and whether it wrapped. From no file, the first
---or last.
---@param comments changeset.ReviewComment[]
---@param path string?
---@param lnum integer
---@param count integer `path`'s line count.
---@param step 1|-1
---@return integer index, boolean wrapped
local function neighbour(comments, path, lnum, count, step)
  local from, to = 1, #comments
  if step == -1 then
    from, to = to, from
  end
  if not path then
    return from, false
  end
  for i = from, to, step do
    if side(comments[i], path, lnum, count) == step then
      return i, false
    end
  end
  return from, true
end

---Whether `win` is a window a jump can show a file in: a file's, not floating, its buffer free to change.
---@param win integer
---@return boolean
local function file_window(win)
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
    and vim.api.nvim_win_get_config(win).relative == ""
    and not vim.wo[win].winfixbuf
end

---The window a comment jump goes in: the current one when it holds a file, else the one before it when that does.
---@return integer?
local function jump_window()
  if file_window(0) then
    return vim.api.nvim_get_current_win()
  end
  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if previous ~= 0 and file_window(previous) then
    return previous
  end
end

---Where a comment jump starts: the window it goes in, whether that is the sidebar's, and the repository. Warns, naming
---`command`, and returns nil from a window it can't jump from.
---@param command string
---@return integer? win, boolean from_sidebar, string repository
local function jump_from(command)
  local from_sidebar = window.is_focused()
  local win = from_sidebar and vim.api.nvim_get_current_win() or jump_window()
  if not win then
    say(vim.log.levels.WARN, "run `:Changeset %s` from a file", command)
    return nil, from_sidebar, ""
  end
  return win, from_sidebar, from_sidebar and root() or Paths.root(vim.api.nvim_win_get_buf(win))
end

---Puts `comment`'s first line in `win`, through the sidebar's commit from the sidebar. Refuses, saying why, when
---either file has unsaved edits or the file can't be opened.
---@param win integer
---@param from_sidebar boolean
---@param repository string
---@param comment changeset.ReviewComment
---@return boolean landed
local function land(win, from_sidebar, repository, comment)
  local full = vim.fs.joinpath(repository, comment.path)
  local target = loaded(full)
  if target and vim.bo[target].modified then
    say(vim.log.levels.WARN, M.UNSAVED)
    return false
  end
  local lnum = first_line(comment)
  if from_sidebar then
    return window.commit(full, lnum, "reuse")
  end
  local file = buffers.load(full)
  if not file then
    say(vim.log.levels.WARN, "can't open %s", full)
    return false
  end
  vim.api.nvim_set_current_win(win)
  vim.bo[file].buflisted = true
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_buf(win, file)
  vim.api.nvim_win_set_cursor(win, { math.min(lnum, vim.api.nvim_buf_line_count(file)), 0 })
  return true
end

---`repository`'s comments whose files are there, in the order of `in_order`.
---@param repository string
---@return changeset.ReviewComment[]
local function reachable(repository)
  return vim.tbl_filter(function(comment)
    return vim.uv.fs_stat(vim.fs.joinpath(repository, comment.path)) ~= nil
  end, comment_store.list(repository))
end

---Jumps to the review comment `count` away from the cursor, forward for a positive `count`, wrapping at either
---end. From a window that holds no file, it jumps in the window before it.
---@param count integer
local function jump(count)
  local step = count > 0 and 1 or -1
  local win, from_sidebar, repository = jump_from(step == 1 and "next-comment" or "prev-comment")
  if not win then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local comments = in_order(reachable(repository))
  if #comments == 0 then
    return say(vim.log.levels.INFO, "no review comments in %s", repository)
  end
  if not from_sidebar and vim.bo[buf].modified then
    return say(vim.log.levels.WARN, M.UNSAVED)
  end
  local path = not from_sidebar and file_path(repository, buf) or nil
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local i, wrapped = neighbour(comments, path, cursor, vim.api.nvim_buf_line_count(buf), step)
  for _ = 2, math.abs(count) do
    i = i + step
    if i < 1 or i > #comments then
      i, wrapped = (i - 1) % #comments + 1, true
    end
  end
  if not land(win, from_sidebar, repository, comments[i]) then
    return
  end
  -- Echoed like a search count, not notified, so notifier plugins don't toast every jump.
  local text = ("review comment %d of %d"):format(i, #comments)
  vim.api.nvim_echo({ { wrapped and text .. ", wrapped" or text } }, false, {})
end

---Jumps to the repository's review comment saved last and opens it to edit.
function M.last_comment()
  local win, from_sidebar, repository = jump_from("last-comment")
  if not win then
    return
  end
  local last = last_saved(repository)
  if not last then
    return say(vim.log.levels.INFO, "no saved review comment in %s", repository)
  end
  if not vim.uv.fs_stat(vim.fs.joinpath(repository, last.path)) then
    return say(vim.log.levels.WARN, "the review comment saved last is on %s, which is gone", last.path)
  end
  if not from_sidebar and vim.bo[vim.api.nvim_win_get_buf(win)].modified then
    return say(vim.log.levels.WARN, M.UNSAVED)
  end
  if land(win, from_sidebar, repository, last) then
    M.open(last)
  end
end

---Jumps `count` review comments forward in the repository.
---@param count integer
function M.next_comment(count)
  jump(count)
end

---Jumps `count` review comments back in the repository.
---@param count integer
function M.prev_comment(count)
  jump(-count)
end

local QF_TITLE = "Changeset review comments"

---Puts the repository's review comments in the quickfix list, replacing the one this made last if still current.
function M.list()
  local repository = root()
  local comments = in_order(comment_store.list(repository))
  if #comments == 0 then
    return say(vim.log.levels.INFO, "no review comments in %s", repository)
  end
  local items = vim.tbl_map(function(comment)
    local body = vim.split(comment.body, "\n")
    return {
      filename = vim.fs.joinpath(repository, comment.path),
      lnum = first_line(comment),
      end_lnum = comment.line,
      text = (comment.draft and "[draft] " or "") .. (#body > 1 and body[1] .. " …" or body[1]),
    }
  end, comments)
  local action = vim.fn.getqflist({ title = 0 }).title == QF_TITLE and "r" or " "
  vim.fn.setqflist({}, action, { title = QF_TITLE, items = items })
  vim.cmd.copen()
end

---Copies the review's saved comments, as `submit` would paste them, as `Paths.put` does, keeping the comments.
function M.yank()
  local repository = root()
  local comments, drafts = split_drafts(comment_store.list(repository))
  if #comments == 0 then
    if drafts > 0 then
      return say(vim.log.levels.INFO, "nothing saved to copy, only %s", drafts_label(drafts))
    end
    return say(vim.log.levels.INFO, "no review comments to copy")
  end
  local where = Paths.put(M._review_text(comments, reader(repository)))
  local count = #comments == 1 and "1 comment" or #comments .. " comments"
  local left_out = drafts > 0 and ("; %s left out"):format(drafts_label(drafts)) or ""
  say(vim.log.levels.INFO, "copied the review's %s%s%s", count, where, left_out)
end

return M
