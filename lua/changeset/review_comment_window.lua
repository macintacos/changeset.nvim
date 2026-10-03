---The window a review comment is written in, under the line it is about.

local help = require("changeset.help")

local M = {}

local MAX_WIDTH = 72
local HEIGHT = 6

---@class changeset.ReviewCommentWindow.Opts
---@field line integer The current window's buffer line it opens under, 1-based.
---@field title string Names the line or lines, e.g. "line 42", "lines 40-42".
---@field footer string Names where a save goes, e.g. "pending review on #412".
---@field keys string[] Keys that save, in insert and normal mode.
---@field save fun(body: string, done: fun(err: string?)) Called with the buffer's lines joined by "\n"; the window closes once `done` gets no error.

---Open the window under `opts.line` of the current window, focused, in insert mode.
---@param opts changeset.ReviewCommentWindow.Opts
---@return integer win
function M.open(opts)
  local source = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = source,
    bufpos = { opts.line - 1, 0 },
    -- Prose reads best at a short measure, and the border needs two more cells.
    width = math.max(math.min(MAX_WIDTH, vim.api.nvim_win_get_width(source) - 2), 20),
    height = HEIGHT,
    style = "minimal",
    border = "rounded",
    title = " Review comment · " .. opts.title .. " ",
    title_pos = "left",
    footer = " " .. opts.footer .. " ",
    footer_pos = "left",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function close()
    if vim.api.nvim_get_current_win() == win then
      -- Otherwise insert mode carries over to the user's file and the next keys edit it.
      vim.cmd.stopinsert()
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
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
