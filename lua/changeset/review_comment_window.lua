---The window a review comment is written in, under the line it is about.

local help = require("changeset.help")

local M = {}

local MAX_WIDTH = 72
local HEIGHT = 6
local MIN_WIDTH = 20

---@class changeset.ReviewCommentWindowOpts
---@field line integer The current window's buffer line it opens under, 1-based.
---@field title string Names the line or lines, e.g. "line 42", "lines 40-42".
---@field footer string Names where a save goes, e.g. "pending review on #412".
---@field keys string[] Keys that save, in insert and normal mode.
---@field save fun(body: string, done: fun(err: string?)) Called with the buffer's lines joined by "\n"; the window closes once `done` gets no error.

---Open the window under `opts.line` of the current window, focused, in insert mode.
---@param opts changeset.ReviewCommentWindowOpts
---@return integer win
function M.open(opts)
  local source = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
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
    title = " Review comment · " .. opts.title .. " ",
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

  local in_flight = false
  local function save()
    -- A double press must not add the review comment twice.
    if in_flight then
      return
    end
    in_flight = true
    opts.save(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), function(err)
      in_flight = false
      if not err then
        close()
      end
    end)
  end

  local map, own = help.mapper(buf)
  for _, lhs in ipairs(opts.keys) do
    vim.keymap.set("i", lhs, save, { buffer = buf, desc = "Save into the pending review" })
    map(lhs, save, "Save into the pending review")
  end
  map("q", close, "Close without saving")
  map("?", function()
    help.show(buf, own)
  end, "Show these keymaps")

  vim.cmd.startinsert()
  return win
end

return M
