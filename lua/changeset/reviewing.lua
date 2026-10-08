---`:Changeset comment new`, `del`, `draft`, `next`, `prev`, `last` and `list` and `:Changeset review submit`,
---`restore`, `yank` and `abandon`, which write, delete, draft or save, walk, reopen, list, paste into an agent's prompt,
---bring back, copy and clear the review comments kept on this machine, and the Comments rows' open and delete.
local Paths = require("changeset.paths")
local buffers = require("changeset.buffers")
local build = require("changeset.build")
local comment_store = require("changeset.comment_store")
local config = require("changeset.config")
local dialog = require("changeset.dialog")
local icons = require("changeset.icons")
local render = require("changeset.render")
local review_comment_blocks = require("changeset.review_comment_blocks")
local review_comment_window = require("changeset.review_comment_window")
local review_comments = require("changeset.review_comments")
local window = require("changeset.window")

local M = {}

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

---Where `comment` sits, as the Comments row and the pasted review name it: "a.lua:4", "a.lua:3-5" for a range, or
---"a.lua" for the whole file.
---@param comment changeset.ReviewComment
---@return string
local function location(comment)
  if not comment.line then
    return comment.path
  end
  local first = comment.start_line or comment.line
  return first < comment.line and ("%s:%d-%d"):format(comment.path, first, comment.line)
    or ("%s:%d"):format(comment.path, comment.line)
end

---Where `comment` sits, for a sentence: "line 4 of a.lua", or "the whole of a.lua".
---@param comment changeset.ReviewComment
---@return string
local function place(comment)
  if not comment.line then
    return "the whole of " .. comment.path
  end
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

---Whether `path` of `repository` has unsaved edits, so a verb that acts by line must refuse; warns `M.UNSAVED` when so.
---@param repository string
---@param path string
---@return boolean
function M.unsaved(repository, path)
  local buf = buffers.loaded(vim.fs.joinpath(repository, path))
  if buf and vim.bo[buf].modified then
    say(vim.log.levels.WARN, M.UNSAVED)
    return true
  end
  return false
end

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

---The glyph heading `comment`'s window: the file's icon for a whole file's, else the bubble that marks its lines, so
---the two read apart.
---@param comment changeset.ReviewComment
---@return [string, string]
local function icon_of(comment)
  if not comment.line then
    return { icons.get("file", comment.path) }
  end
  return { review_comments.glyph(comment) }
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

---Defined with the subcommands that run from the window.
---@type fun(open: changeset.ReviewCommentWindow)
local delete_open

---Opens the window under `comment`'s lines of the current buffer, or under the cursor's line for a whole file's or
---from the sidebar, holding its text: a save replaces it, a blank save or close asks to delete it, and a close with
---changed text keeps it as a draft.
---@param comment changeset.ReviewComment
function M.open(comment)
  local repository = root()
  local last = comment.line
  local kind = comment.draft and "Edit draft review comment · " or "Edit review comment · "
  review_comment_window.open({
    line = last and not window.is_focused() and last or vim.api.nvim_win_get_cursor(0)[1],
    title = kind .. lines_label(comment.start_line or last, last),
    icon = icon_of(comment),
    save_desc = "Save the review comment",
    close_desc = "Close, keeping the text as a draft, and select its block",
    keys = config.get().review_comment.save,
    body = comment.body,
    comment = comment,
    keep = function(body, draft)
      if not body:find("%S") then
        -- Scheduled: the question opens a window, and this one is still closing.
        return vim.schedule(function()
          M.ask_delete(comment)
        end)
      end
      if
        (body ~= comment.body or draft and not comment.draft) and not keep(repository, with_body(comment, body, true))
      then
        say_draft()
      end
    end,
    save = function(body, done)
      done(keep(repository, with_body(comment, body)))
    end,
    blank = function(open)
      delete_open(open)
    end,
    back = function()
      review_comment_blocks.select(comment)
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

---The comment `comment new` on lines `first` to `last` of `path` opens to edit: for a range, the one on exactly that
---range; for one line, the narrowest covering it.
---@param repository string
---@param path string
---@param first integer
---@param last integer
---@return changeset.ReviewComment?
local function existing_on(repository, path, first, last)
  if first == last then
    return at(repository, path, last)
  end
  return vim.iter(comment_store.list(repository)):find(function(comment)
    return comment.path == path and comment.start_line == first and comment.line == last
  end)
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

---Opens the review comment window under line `line` of the current window for `comment`, new, its body "". Closing
---it keeps its text, so nothing typed is lost.
---@param repository string
---@param comment changeset.ReviewComment
---@param line integer
local function open_new(repository, comment, line)
  review_comment_window.open({
    line = line,
    title = "Review comment · " .. lines_label(comment.start_line or comment.line, comment.line),
    icon = icon_of(comment),
    save_desc = "Save the review comment",
    close_desc = "Close, keeping the text as a draft, and select its block",
    keys = config.get().review_comment.save,
    comment = comment,
    keep = function(body)
      -- A blank keep would drop whatever was saved on this range meanwhile.
      if body:find("%S") and not keep(repository, with_body(comment, body, true)) then
        say_draft()
      end
    end,
    save = function(body, done)
      done(keep(repository, with_body(comment, body)))
    end,
    back = function()
      review_comment_blocks.select(comment)
    end,
  })
end

---The file the sidebar's cursor row stands for: a file's row, or a Comments row listing a whole file's comment.
---@return string? path
local function sidebar_file()
  local row = require("changeset.draw").row_at_cursor()
  if row and (row.kind == "file" or row.review_comment and not row.review_comment.line) then
    return row.path
  end
end

---The comment on the whole of `path`.
---@param repository string
---@param path string
---@return changeset.ReviewComment?
local function on_file(repository, path)
  return vim.iter(comment_store.list(repository)):find(function(comment)
    return comment.path == path and not comment.line
  end)
end

---Opens the review comment window under the cursor's line for the whole of `path`, or its comment to edit.
---@param repository string
---@param path string
local function comment_on_file(repository, path)
  local existing = on_file(repository, path)
  if existing then
    return M.open(existing)
  end
  open_new(repository, { path = path, body = "" }, vim.api.nvim_win_get_cursor(0)[1])
end

---The lines sidebar row `row` stands for: a symbol's line, as `<CR>` opens it, a change's lines, or those of the
---comment a Comments row lists; none for a file's row or a whole file's comment, which stand for the whole file.
---@param row changeset.Row
---@return integer? first
---@return integer? last
local function row_lines(row)
  local comment = row.review_comment
  if comment then
    return comment.start_line or comment.line, comment.line
  end
  if row.kind == "orphan" then
    return row.range[1], row.range[2]
  end
  if row.kind ~= "file" then
    return row.lnum, row.lnum
  end
end

---Opens the review comment window under the sidebar's cursor row for what the row stands for, or the comment already
---there to edit, found as from the file.
local function comment_row()
  local repository = root()
  local row = require("changeset.draw").row_at_cursor()
  if not row or row.kind == "section" then
    return say(
      vim.log.levels.WARN,
      "run `:Changeset comment new` on a file's, a symbol's or a change's row, or from a file in %s",
      repository
    )
  end
  local first, last = row_lines(row)
  if not (first and last) then
    return comment_on_file(repository, row.path)
  end
  local file = buffers.loaded(vim.fs.joinpath(repository, row.path))
  if file and vim.bo[file].modified then
    return say(vim.log.levels.WARN, M.UNSAVED)
  end
  local existing = existing_on(repository, row.path, first, last)
  if existing then
    return M.open(existing)
  end
  local comment = { path = row.path, line = last, start_line = first < last and first or nil, body = "" }
  open_new(repository, comment, vim.api.nvim_win_get_cursor(0)[1])
end

---The current buffer's path in `repository`, when a review comment can be written there; else warns and returns nil.
---@param repository string
---@return string?
local function commentable(repository)
  local path = file_path(repository, 0)
  if not path then
    return say(vim.log.levels.WARN, "run `:Changeset comment new` from a file in %s", repository)
  end
  if vim.bo.modified then
    return say(vim.log.levels.WARN, M.UNSAVED)
  end
  return path
end

---Opens the review comment window under line `last` of the current buffer, for lines `first` to `last`, or an
---existing comment there to edit. From the sidebar, it is for what the cursor's row stands for. Closing a new one
---keeps its text, so nothing typed is lost.
---@param first integer
---@param last integer
function M.comment(first, last)
  if window.is_focused() then
    return comment_row()
  end
  local repository = Paths.root(0)
  local path = commentable(repository)
  if not path then
    return
  end
  local existing = existing_on(repository, path, first, last)
  if existing then
    return M.open(existing)
  end
  open_new(repository, { path = path, line = last, start_line = first < last and first or nil, body = "" }, last)
end

---Opens the review comment window for the cursor's line as `comment` does, but for the whole file on its first line.
function M.comment_here()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if lnum ~= 1 or window.is_focused() then
    return M.comment(lnum, lnum)
  end
  local repository = Paths.root(0)
  local path = commentable(repository)
  if path then
    comment_on_file(repository, path)
  end
end

---The comment stored on `comment`'s path and range, as it is now.
---@param repository string
---@param comment changeset.ReviewComment
---@return changeset.ReviewComment?
local function stored_as(repository, comment)
  return vim.iter(comment_store.list(repository)):find(function(each)
    return each.path == comment.path and each.line == comment.line and each.start_line == comment.start_line
  end)
end

---Deletes the comment being written in `open`: asks first when it is stored or holds text, else just closes.
---@param open changeset.ReviewCommentWindow
function delete_open(open)
  local repository = vim.api.nvim_win_call(open.source, root)
  local stored = stored_as(repository, open.comment)
  local text = open.text()
  if not stored and not text:find("%S") then
    return open.discard()
  end
  open.hold(function()
    dialog.confirm({
      title = "Delete the review comment",
      body = {
        { text = location(open.comment), hl = render.META_HL, path = true },
        {
          text = text:find("%S") and text or assert(stored).body,
          quote = render.REVIEW_COMMENT_HL,
          max_lines = QUOTED,
        },
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

---The repository's review comment saved last on lines: the store appends on every keep, so its last such saved entry.
---@param repository string
---@return changeset.ReviewComment?
local function last_saved(repository)
  local comments = comment_store.list(repository)
  for i = #comments, 1, -1 do
    if not comments[i].draft and comments[i].line then
      return comments[i]
    end
  end
end

---Runs subcommand `name` from the review comment window `open`: `comment new` saves it, `comment del` deletes it,
---`comment draft` keeps it as a draft, and any other closes it, keeping a draft, then calls `run` in the window it
---opened from, from the comment's first line, or for a whole file's, from where that window's cursor is.
---@param open changeset.ReviewCommentWindow
---@param name string
---@param run fun()
function M.from_window(open, name, run)
  if name == "comment new" then
    return open.save()
  end
  if name == "comment del" then
    return delete_open(open)
  end
  if name == "comment draft" then
    return open.draft()
  end
  if name == "comment last" then
    local last = last_saved(vim.api.nvim_win_call(open.source, root))
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
    local last = open.comment.line
    -- Under a sidebar row, the comment's line is not one of the window's.
    if last and vim.bo[open.source_buf].buftype == "" then
      local lnum = math.min(open.comment.start_line or last, vim.api.nvim_buf_line_count(0))
      vim.api.nvim_win_set_cursor(open.source, { lnum, 0 })
    end
    run()
  end)
end

---Deletes the comment on the whole of `path`.
---@param repository string
---@param path string
local function delete_on_file(repository, path)
  local comment = on_file(repository, path)
  if not comment then
    return say(vim.log.levels.INFO, "no review comment on the whole of %s", path)
  end
  drop(repository, comment)
end

---Deletes the comment on the whole file the sidebar's cursor row stands for.
local function delete_file()
  local path = sidebar_file()
  if not path then
    return say(vim.log.levels.WARN, "run `:Changeset comment del` from a file, or on a file's row")
  end
  delete_on_file(root(), path)
end

---The review comment on the current window's cursor line, the narrowest of those covering it; on the file's first line
---the one on the whole file when there is one. Warns and returns nil in a modified buffer, else says when there is
---none.
---@param repository string
---@return changeset.ReviewComment?
local function on_cursor_line(repository)
  if vim.bo.modified then
    return say(vim.log.levels.WARN, M.UNSAVED)
  end
  local path = file_path(repository, 0)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local comment = path and (lnum == 1 and on_file(repository, path) or at(repository, path, lnum))
  if not comment then
    return say(vim.log.levels.INFO, "no review comment on line %d", lnum)
  end
  return comment
end

---Deletes the review comment on the cursor's line, the narrowest of those covering it; on the file's first line the one
---on the whole file when there is one; from the sidebar on a file's row, the one on the whole file.
function M.delete()
  if window.is_focused() then
    return delete_file()
  end
  local repository = Paths.root(0)
  local comment = on_cursor_line(repository)
  if comment then
    drop(repository, comment)
  end
end

---Keeps `comment` as a draft when saved, else saved, and says which.
---@param repository string
---@param comment changeset.ReviewComment
local function switch_draft(repository, comment)
  local draft = not comment.draft or nil
  if keep(repository, with_body(comment, comment.body, draft)) then
    return
  end
  say(
    vim.log.levels.INFO,
    draft and "kept the review comment on %s as a draft" or "saved the review comment on %s",
    place(comment)
  )
end

---The review comment the sidebar's cursor row lists, or the one on the whole file a file's row stands for, as stored
---now; warns or says why when there is none.
---@param repository string
---@return changeset.ReviewComment?
local function on_sidebar_row(repository)
  local row = require("changeset.draw").row_at_cursor()
  if row and row.review_comment then
    return stored_as(repository, row.review_comment)
      or say(vim.log.levels.INFO, "no review comment on %s now", place(row.review_comment))
  end
  if not (row and row.kind == "file") then
    return say(vim.log.levels.WARN, "run `:Changeset comment draft` on a Comments row or a file's row, or from a file")
  end
  return on_file(repository, row.path) or say(vim.log.levels.INFO, "no review comment on the whole of %s", row.path)
end

---Makes the review comment `delete` would delete a draft, or saves it when it is one; from the sidebar, the one a
---Comments row lists or the one on the whole file a file's row stands for.
function M.draft()
  local repository = root()
  local comment
  if window.is_focused() then
    comment = on_sidebar_row(repository)
  else
    comment = on_cursor_line(repository)
  end
  if comment then
    switch_draft(repository, comment)
  end
end

---"1 draft", "2 drafts".
---@param n integer
---@return string
local function drafts_label(n)
  return n == 1 and "1 draft" or ("%d drafts"):format(n)
end

---"1 review comment", "2 review comments".
---@param n integer
---@return string
local function comments_label(n)
  return n == 1 and "1 review comment" or ("%d review comments"):format(n)
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

---0 for a whole file's comment, which sorts ahead of its lines'.
---@param comment changeset.ReviewComment
---@return integer
local function first_line(comment)
  return comment.start_line or comment.line or 0
end

---`comments` in the order every view lists them in.
---@param comments changeset.ReviewComment[]
---@return changeset.ReviewComment[]
local function in_order(comments)
  local sorted = vim.list_slice(comments)
  table.sort(sorted, comment_store.before)
  return sorted
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

---One comment's block: its place by absolute path, its lines fenced in the file's language, and its body. A whole
---file's quotes none.
---@param repository string
---@param comment changeset.ReviewComment
---@param read changeset.reviewing.ReadLines
---@return string
local function block(repository, comment, read)
  local parts = { vim.fs.joinpath(repository, location(comment)) }
  local last = comment.line
  local lines = last and read(comment.path, comment.start_line or last, last)
  if lines then
    local fence = ("`"):rep(longest_backticks(lines) + 1)
    parts[#parts + 1] = fence .. (vim.filetype.match({ filename = comment.path }) or "")
    vim.list_extend(parts, lines)
    parts[#parts + 1] = fence
  end
  parts[#parts + 1] = (comment.body:gsub("%s+$", ""))
  return table.concat(parts, "\n")
end

---The text a review is pasted as: a block per comment, in `comment_store.before`'s order, a blank line
---between blocks.
---@param repository string
---@param comments changeset.ReviewComment[]
---@param read changeset.reviewing.ReadLines
---@return string
function M._review_text(repository, comments, read)
  local sorted = vim.list_slice(comments)
  table.sort(sorted, comment_store.before)
  return table.concat(
    vim.tbl_map(function(comment)
      return block(repository, comment, read)
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
    local buf = buffers.loaded(full)
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

---Pastes the repository's saved review comments into an agent's prompt through herdr, then takes the ones pasted out
---of the store, where `restore` can bring them back. Drafts stay.
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
  local count = comments_label(#comments)
  local text = M._review_text(repository, comments, reader(repository))
  require("changeset.herdr").send(text, { title = "Submit " .. count, root = repository }, function(err, agent)
    if err then
      return say(vim.log.levels.WARN, "can't submit the review: %s", err)
    end
    if not agent then
      return
    end
    -- Only what went: a comment written or edited while the pick was open stays.
    if not comment_store.take(repository, { comments = comments, at = os.time(), to = agent }) then
      return say(
        vim.log.levels.WARN,
        "pasted %s into %s's prompt, but %s still listed: can't remove %s from %s",
        count,
        agent,
        #comments == 1 and "it is" or "they are",
        #comments == 1 and "it" or "them",
        comment_store.path()
      )
    end
    say(
      vim.log.levels.INFO,
      "submitted %s to %s; :Changeset review restore brings %s back%s",
      count,
      agent,
      #comments == 1 and "it" or "them",
      staying
    )
  end)
end

---Brings back `batch`, one the repository's branch submitted, and says how it went.
---@param repository string
---@param batch changeset.SubmittedBatch
local function restore_batch(repository, batch)
  local restored, kept = comment_store.restore(repository, batch)
  if not restored then
    return say(vim.log.levels.ERROR, "can't restore the review comments in %s", comment_store.path())
  end
  if restored + kept == 0 then
    return say(vim.log.levels.INFO, "that batch is no longer submitted in %s", repository)
  end
  if kept == 0 then
    return say(vim.log.levels.INFO, "restored %s", comments_label(restored))
  end
  local staying = kept == 1 and "stays submitted: its lines hold a newer one"
    or "stay submitted: their lines hold newer ones"
  if restored == 0 then
    return say(vim.log.levels.INFO, "%s %s", comments_label(kept), staying)
  end
  say(vim.log.levels.INFO, "restored %s; %d %s", comments_label(restored), kept, staying)
end

---A row of the restore picker: when `batch` went and to whom, how many it holds, and its first comment.
---@param batch changeset.SubmittedBatch
---@return changeset.DialogItem
local function batch_row(batch)
  local first = in_order(batch.comments)[1]
  return {
    cells = {
      {
        batch.at and os.date("%b %d %H:%M", batch.at) --[[@as string]] or "",
        render.META_HL,
      },
      { batch.to or "" },
      { comments_label(#batch.comments) },
      { first and ("%s  %s"):format(location(first), first.body:match("^[^\r\n]*")) or "" },
    },
  }
end

---Brings back a batch of review comments the repository's branch submitted, as saved ones, leaving out any on lines
---that hold a review comment now: the only one, or the one picked, newest first.
function M.restore()
  local repository = root()
  local batches = comment_store.submitted(repository)
  if not batches then
    return say(vim.log.levels.ERROR, "can't restore the review comments in %s", comment_store.path())
  end
  if #batches == 0 then
    return say(vim.log.levels.INFO, "no submitted review comments to restore in %s", repository)
  end
  if #batches == 1 then
    return restore_batch(repository, batches[1])
  end
  dialog.choose({
    title = "Restore submitted review comments",
    items = vim.tbl_map(batch_row, batches),
    action = "restore",
  }, function(index)
    if index then
      restore_batch(repository, batches[index])
    end
  end)
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
  if M.unsaved(repository, comment.path) then
    return false
  end
  local full = vim.fs.joinpath(repository, comment.path)
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

---`repository`'s comments on lines of files that are there, in the order of `in_order`.
---@param repository string
---@return changeset.ReviewComment[]
local function reachable(repository)
  return vim.tbl_filter(function(comment)
    return comment.line ~= nil and vim.uv.fs_stat(vim.fs.joinpath(repository, comment.path)) ~= nil
  end, comment_store.list(repository))
end

---Jumps to the review comment `count` away from the cursor, forward for a positive `count`, wrapping at either
---end. From a window that holds no file, it jumps in the window before it.
---@param count integer
local function jump(count)
  local step = count > 0 and 1 or -1
  local win, from_sidebar, repository = jump_from(step == 1 and "comment next" or "comment prev")
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
  local win, from_sidebar, repository = jump_from("comment last")
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
  local where = Paths.put(M._review_text(repository, comments, reader(repository)))
  local left_out = drafts > 0 and ("; %s left out"):format(drafts_label(drafts)) or ""
  say(vim.log.levels.INFO, "copied %s%s%s", comments_label(#comments), where, left_out)
end

return M
