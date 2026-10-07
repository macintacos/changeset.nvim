---The markdown window a review comment is written in, under the line it is about.

local help = require("changeset.help")

local M = {}

local MAX_WIDTH = 72
local HEIGHT = 6
local MIN_WIDTH = 20
-- The float's rows and its top and bottom border.
local BOX = HEIGHT + 2

local ns = vim.api.nvim_create_namespace("changeset.review_comment_window")

---Blank virtual lines, as tall as the box, that the float lies on so it covers no text.
local PADDING = {}
for i = 1, BOX do
  PADDING[i] = { { "" } }
end

---@class changeset.ReviewCommentWindowOpts
---@field line integer The current window's buffer line it opens under, 1-based.
---@field title string The whole title, e.g. "Review comment · line 42".
---@field footer string Names where a save goes, e.g. "kept until :Changeset review submit".
---@field keys string[] Keys that save, in insert and normal mode.
---@field save_desc string The save keys' `desc`, which `?` lists.
---@field close_desc string The `desc` of the keys that close without saving, which `?` lists.
---@field save fun(body: string, done: fun(err: string?)) Called with the buffer's lines joined by "\n", never only whitespace; the window closes once `done` gets no error.
---@field keep fun(body: string) Called with the buffer's lines joined by "\n", empty included, whenever the buffer goes (a close, an :e in the float, quitting) except after a taken save.
---@field body string? The text it opens with.
---@field comment changeset.ReviewComment The comment it is about, as `current` reports it; a new one's body is "".

---The window as `current` reports it, with what can be done to it.
---@class changeset.ReviewCommentWindow
---@field source integer The window it opened from.
---@field source_buf integer The buffer it opened on.
---@field comment changeset.ReviewComment
---@field text fun(): string Its lines joined by "\n".
---@field save fun() As its save keys do.
---@field close fun(after: fun()?) As `q` does, keeping the text, then calls `after` once it has gone and insert mode with it.
---@field discard fun(after: fun()?) Closes it keeping nothing, then calls `after` as `close` does.
---@field resume fun() Picks writing back up where a default key typed in insert mode left it, when that key's command leaves the window open.
---@field hold fun(opens: fun()) Leaves insert mode, then calls `opens`, keeping the window open while focus is in the window that opens, until focus comes back to it and its mode.

---Each open window's report, by window.
---@type table<integer, changeset.ReviewCommentWindow>
local open_windows = {}

---Called as each window opens and closes, with its report and whether it opened.
---@type fun(window: changeset.ReviewCommentWindow, opened: boolean)[]
local watchers = {}

---Calls `fn` as each window opens and closes, with its report and whether it opened. For changeset's own modules.
---@param fn fun(window: changeset.ReviewCommentWindow, opened: boolean)
function M.watch(fn)
  table.insert(watchers, fn)
end

---@param window changeset.ReviewCommentWindow
---@param opened boolean
local function tell(window, opened)
  for _, fn in ipairs(watchers) do
    fn(window, opened)
  end
end

---Where insert mode left the cursor in each window as a default key was typed there, until the key's command has
---run.
---@type table<integer, integer[]>
local typed_at = {}

---Notes where insert mode is in the current window, for the default key being typed there.
function M._typed()
  local win = vim.api.nvim_get_current_win()
  typed_at[win] = vim.api.nvim_win_get_cursor(win)
  vim.schedule(function()
    typed_at[win] = nil
  end)
end

---The review comment window, when it is the current window.
---@return changeset.ReviewCommentWindow?
function M.current()
  return open_windows[vim.api.nvim_get_current_win()]
end

---The default `<C-g>` keys `plugin/changeset.lua` mapped in normal mode, each with its subcommand and `desc`; none
---while the default keys are off.
---@return { lhs: string, name: string, desc: string }[]
local function default_keys()
  return vim.g.changeset_window_keys or {}
end

---What a default key does in the window, as `?` lists it.
---@param key { name: string, desc: string }
---@return string
local function window_desc(key)
  if key.name == "comment new" then
    return "Save the review comment"
  end
  if key.name == "comment del" then
    return "Delete this review comment"
  end
  return "Keep a draft, then: " .. key.desc
end

---Where a save goes on the left, `hint` on the right, the border between them; `hint` only
---when both fit in `width`.
---@param where string
---@param hint string
---@param width integer
---@return [string, string][]
local function footer(where, hint, width)
  local left, right = " " .. where .. " ", " " .. hint .. " "
  local gap = width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right)
  if gap < 1 then
    return { { left, "FloatFooter" } }
  end
  return { { left, "FloatFooter" }, { ("─"):rep(gap), "FloatBorder" }, { right, "FloatFooter" } }
end

---Rows `line` takes in `win` once wrapped, less the virtual lines above it.
---@param win integer
---@param line integer
---@return integer
local function rows(win, line)
  local height = vim.api.nvim_win_text_height(win, { start_row = line - 1, end_row = line - 1 })
  return height.all - height.fill
end

---Whether the row under `line`'s last row, where the box starts, is inside `win`.
---@param win integer
---@param line integer
---@return boolean
local function under_in_view(win, line)
  local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), line - 1, line, false)[1]
  local row = vim.fn.screenpos(win, line, math.max(#text, 1)).row
  return row > 0 and row < vim.fn.win_screenpos(win)[1] + vim.api.nvim_win_get_height(win) - 1
end

---Scroll `win` the least that shows `line` with the box under it, moving its cursor to `line` if it must scroll.
---@param win integer
---@param line integer
local function reveal(win, line)
  vim.api.nvim_win_call(win, function()
    local topline = vim.fn.winsaveview().topline
    local top = math.min(topline, line)
    local height = vim.api.nvim_win_get_height(0)
    while
      top < line and vim.api.nvim_win_text_height(0, { start_row = top - 1, end_row = line - 1 }).all + BOX > height
    do
      top = top + 1
    end
    if top ~= topline then
      -- Neovim scrolls any window back to its cursor, current or not.
      vim.fn.winrestview({ topline = top, topfill = 0, lnum = line })
    end
  end)
end

---Make a floating `win` taller by the box, since it has no neighbours to scroll past.
---@param win integer
---@return integer grown The rows it grew, 0 for a split.
local function grow(win)
  if vim.api.nvim_win_get_config(win).relative == "" then
    return 0
  end
  local before = vim.api.nvim_win_get_height(win)
  vim.api.nvim_win_set_config(win, { height = before + BOX })
  return vim.api.nvim_win_get_height(win) - before
end

---Open the window under `opts.line` of the current window, focused, in insert mode.
---@param opts changeset.ReviewCommentWindowOpts
---@return integer win
function M.open(opts)
  local source = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_win_get_buf(source)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  if opts.body then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.body, "\n"))
  end
  local hint = vim.fn.keytrans(vim.keycode(opts.keys[1])) .. " save · q draft"

  ---Its line, held to the source's end should edits there shorten it.
  local function line()
    return math.min(opts.line, vim.api.nvim_buf_line_count(source_buf))
  end
  local mark = vim.api.nvim_buf_set_extmark(source_buf, ns, line() - 1, 0, { virt_lines = PADDING })
  local grown = grow(source)
  reveal(source, line())

  ---The float on the padding under its line, as wide as the source now has room for.
  local function placement()
    -- bufpos anchors at the first text column, so the gutter and the border both come out of
    -- the window's width.
    local room = vim.api.nvim_win_get_width(source) - vim.fn.getwininfo(source)[1].textoff - 2
    local width = math.max(math.min(MAX_WIDTH, room), MIN_WIDTH)
    return {
      relative = "win",
      win = source,
      bufpos = { line() - 1, 0 },
      -- bufpos is the line's first row; a wrapped line's other rows come before the box.
      row = rows(source, line()),
      col = 0,
      width = width,
      -- One footer_pos per float, so the hint shares the footer, pushed right by border.
      footer = footer(opts.footer, hint, width),
      -- A float is never clipped to its anchor window: off its line, it would cover other text.
      hide = not under_in_view(source, line()),
    }
  end

  local win = vim.api.nvim_open_win(
    buf,
    true,
    vim.tbl_extend("error", placement(), {
      height = HEIGHT,
      style = "minimal",
      border = "rounded",
      title = " " .. opts.title .. " ",
      title_pos = "left",
      footer_pos = "left",
    })
  )
  -- Set once the float is current, so the user's FileType settings land on it.
  vim.bo[buf].filetype = "markdown"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  -- An `:e` here would leave the float showing a file.
  vim.wo[win].winfixbuf = true

  ---@param after fun()?
  local function close_now(after)
    -- Deleting the buffer closes every window on it, a `:split` of the float's among them.
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if after then
      after()
    end
  end

  ---Whether the float is current in insert or replace mode.
  local function inserting()
    return vim.api.nvim_get_current_win() == win and vim.api.nvim_get_mode().mode:find("^[iR]") ~= nil
  end

  ---Calls `after` once insert mode has ended in the float, at once when it isn't on.
  ---@param after fun()
  local function leave_insert(after)
    if not inserting() then
      return after()
    end
    -- stopinsert only takes effect on the next loop iteration; acting before then leaves
    -- insert in whatever window is current next, moving its cursor and firing its InsertLeave.
    -- Fires: insert mode ending in this float, after the stopinsert below.
    vim.api.nvim_create_autocmd("InsertLeave", { buffer = buf, once = true, callback = vim.schedule_wrap(after) })
    vim.cmd.stopinsert()
  end

  ---@param after fun()?
  local function close(after)
    leave_insert(function()
      close_now(after)
    end)
  end

  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function attached()
    return vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_is_valid(source)
      and vim.api.nvim_win_get_buf(source) == source_buf
  end

  local function place()
    if attached() then
      vim.api.nvim_buf_set_extmark(source_buf, ns, line() - 1, 0, { id = mark, virt_lines = PADDING })
      vim.api.nvim_win_set_config(win, placement())
    end
  end

  local group = vim.api.nvim_create_augroup("changeset.review_comment_window." .. buf, {})
  -- Fires: any window scrolling or resizing, the source among them; its pattern names only the
  -- first window that changed.
  vim.api.nvim_create_autocmd("WinScrolled", { group = group, callback = place })
  ---Picks writing back up at `cursor`, where insert mode left off.
  ---@param cursor integer[]
  local function restart_insert(cursor)
    vim.api.nvim_win_set_cursor(win, cursor)
    local row = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ""
    vim.cmd(cursor[2] >= #row and "startinsert!" or "startinsert")
  end

  ---Picks writing back up after a default key typed in insert mode that left the window open.
  local function resume_typing()
    if typed_at[win] and vim.api.nvim_get_current_win() == win then
      restart_insert(typed_at[win])
    end
  end

  local held = false
  ---Where to pick writing back up on return from a window it held for, if it was writing.
  ---@type integer[]?
  local resume
  -- Fires: focus coming back from a window it held for, and a new window entered while it shows this buffer.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      if vim.api.nvim_get_current_win() ~= win then
        return
      end
      held = false
      if resume then
        local cursor = resume
        resume = nil
        restart_insert(cursor)
      end
    end,
  })
  -- Fires: focus leaving the float for any window. Checked once the move lands, since a window can't close while
  -- focus is leaving it.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = vim.schedule_wrap(function()
      -- The command-line window is a detour from the float, and nothing can close while it is open.
      if not held and vim.fn.getcmdwintype() == "" and vim.api.nvim_get_current_win() ~= win then
        close_now()
      end
    end),
  })
  local gone = false
  -- Edits carry the padding with the text, and replacing every line carries it to the end,
  -- while the float stays on its line number.
  vim.api.nvim_buf_attach(source_buf, false, {
    on_lines = function()
      if gone then
        return true
      end
      vim.schedule(place)
    end,
  })

  ---Takes back the room made under its line.
  local function unpad()
    gone = true
    local report = open_windows[win]
    open_windows[win] = nil
    if report then
      tell(report, false)
    end
    vim.api.nvim_del_augroup_by_id(group)
    if vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_del_extmark(source_buf, ns, mark)
    end
    if grown > 0 and vim.api.nvim_win_is_valid(source) then
      vim.api.nvim_win_set_config(source, { height = vim.api.nvim_win_get_height(source) - grown })
    end
  end

  local saved = false
  -- Fires: the float's buffer going any way (a close, :q, :e in the float, quitting); read now, as it is wiped next.
  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = buf,
    once = true,
    callback = function()
      unpad()
      if not saved then
        opts.keep(text())
      end
    end,
  })

  local saving = false
  local function save()
    -- A double press must not add the review comment twice.
    if saving then
      return
    end
    -- Blank text never reaches `save`; the close hands it to `keep` instead.
    if not text():find("%S") then
      return close()
    end
    saving = true
    opts.save(text(), function(err)
      saving = false
      if err then
        return resume_typing()
      end
      saved = true
      close()
    end)
  end

  local map, own = help.mapper(buf)
  for _, lhs in ipairs(opts.keys) do
    vim.keymap.set("i", lhs, save, { buffer = buf, desc = opts.save_desc })
    map(lhs, save, opts.save_desc)
  end
  vim.keymap.set("i", "<S-Esc>", close, { buffer = buf, desc = opts.close_desc })
  map("<S-Esc>", close, opts.close_desc)
  map("q", close, opts.close_desc)
  ---@param lhs string
  ---@return boolean
  local function saves(lhs)
    return vim.iter(opts.keys):any(function(key)
      return vim.keycode(key) == vim.keycode(lhs)
    end)
  end
  -- A key the user maps in insert mode, at startup or since, keeps doing what they mapped, here as anywhere. Asked
  -- before any is mapped here, and counting the markdown maps already on this buffer.
  local keys = vim.tbl_filter(function(key)
    return not saves(key.lhs)
  end, default_keys())
  local free = {}
  for _, key in ipairs(keys) do
    free[key.lhs] = vim.fn.mapcheck(key.lhs, "i") == ""
  end
  for _, key in ipairs(keys) do
    local desc = window_desc(key)
    local command = ("<Cmd>Changeset %s<CR>"):format(key.name)
    -- Not `map`: its nowait would end `<C-g>c` before `<C-g>cn` could follow.
    vim.keymap.set("n", key.lhs, command, { buffer = buf, desc = desc })
    own[#own + 1] = key.lhs
    if free[key.lhs] then
      -- Typed mid-sentence, so they work in insert mode too. They leave insert mode in their own keys, so the command
      -- runs, and a dialog it opens is open, before any key typed after them.
      -- The cursor is noted from a <Cmd> of its own: an <expr> map reads it before typeahead has moved it.
      local note = "<Cmd>lua require('changeset.review_comment_window')._typed()<CR>"
      vim.keymap.set("i", key.lhs, note .. "<C-\\><C-n>" .. command, { buffer = buf, desc = desc })
    end
  end
  map("?", function()
    help.show(buf, own)
    -- A help window that takes focus is a look at the keys, not a move away.
    held = vim.api.nvim_get_current_win() ~= win
  end, "Show these keymaps")

  open_windows[win] = {
    source = source,
    source_buf = source_buf,
    comment = opts.comment,
    text = text,
    save = save,
    close = close,
    discard = function(after)
      saved = true
      close(after)
    end,
    resume = resume_typing,
    hold = function(opens)
      held = true
      resume = inserting() and vim.api.nvim_win_get_cursor(win) or typed_at[win]
      leave_insert(opens)
    end,
  }
  tell(open_windows[win], true)

  if opts.body then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    vim.cmd("startinsert!")
  else
    vim.cmd.startinsert()
  end
  return win
end

return M
