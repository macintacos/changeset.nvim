---The window a review comment is written in, under the line it is about.

local help = require("changeset.help")

local M = {}

local MAX_WIDTH = 72
local HEIGHT = 6
local MIN_WIDTH = 20

---@class changeset.ReviewCommentWindowOpts
---@field line integer The current window's buffer line it opens under, 1-based.
---@field title string The whole title, e.g. "Review comment · line 42".
---@field footer string Names where a save goes, e.g. "pending review on #412".
---@field keys string[] Keys that save, in insert and normal mode.
---@field save_desc string Describes the save keys.
---@field close_desc string Describes the keys that close without saving.
---@field save fun(body: string, done: fun(err: string?)) Called with the buffer's lines joined by "\n"; the window closes once `done` gets no error.
---@field keep fun(body: string) Called with the buffer's lines joined by "\n", empty included, whenever the buffer goes (a close, an :e in the float, quitting) except after a taken save.
---@field body string? The text it opens with.

---Open the window under `opts.line` of the current window, focused, in insert mode.
---@param opts changeset.ReviewCommentWindowOpts
---@return integer win
function M.open(opts)
  local source = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  if opts.body then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.body, "\n"))
  end
  -- bufpos anchors at the first text column, so the gutter and the border both come out of
  -- the window's width.
  local room = vim.api.nvim_win_get_width(source) - vim.fn.getwininfo(source)[1].textoff - 2

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = source,
    bufpos = { opts.line - 1, 0 },
    width = math.max(math.min(MAX_WIDTH, room), MIN_WIDTH),
    height = HEIGHT,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "left",
    footer = " " .. opts.footer .. " ",
    footer_pos = "left",
  })
  -- Set once the float is current, so the user's FileType settings land on it.
  vim.bo[buf].filetype = "markdown"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function close_now()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function close()
    if vim.api.nvim_get_current_win() ~= win or not vim.api.nvim_get_mode().mode:find("^[iR]") then
      return close_now()
    end
    -- stopinsert only takes effect on the next loop iteration; closing before then leaves
    -- insert in the user's file, moving its cursor and firing its InsertLeave.
    -- Fires: insert mode ending in this float, after the stopinsert below.
    vim.api.nvim_create_autocmd("InsertLeave", { buffer = buf, once = true, callback = vim.schedule_wrap(close_now) })
    vim.cmd.stopinsert()
  end

  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local saved = false
  -- Fires: the float's buffer going any way (a close, :q, :e in the float, quitting); read now, as it is wiped next.
  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = buf,
    once = true,
    callback = function()
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
    saving = true
    opts.save(text(), function(err)
      saving = false
      if not err then
        saved = true
        close()
      end
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
  map("?", function()
    help.show(buf, own)
  end, "Show these keymaps")

  if opts.body then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    vim.cmd("startinsert!")
  else
    vim.cmd.startinsert()
  end
  return win
end

return M
