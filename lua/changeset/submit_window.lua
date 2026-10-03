---The preview a pending review is checked, given an event and a body, and submitted from.

local help = require("changeset.help")
local render = require("changeset.render")
local review_comment_window = require("changeset.review_comment_window")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.submit_window")

local MIN_WIDTH = 44
local MAX_WIDTH = 96

---What `<CR>` sends, for the footer.
local SENDS = { COMMENT = "comment on #%d", APPROVE = "approve #%d", REQUEST_CHANGES = "request changes on #%d" }

---Keys that choose an event, offered only when more than one event is, and only for those.
local CHOOSE = {
  { "c", "COMMENT", "Choose Comment" },
  { "a", "APPROVE", "Choose Approve" },
  { "r", "REQUEST_CHANGES", "Choose Request changes" },
}

---@class changeset.SubmitWindowOpts
---@field number integer The PR's number.
---@field events changeset.pending_review.Event[] The events offered, the first preselected.
---@field comments changeset.ReviewComment[] What the submit sends.
---@field drafts changeset.Draft[] Named as not included.
---@field keys string[] Keys that close the body window, from `review_comment.save`.
---@field submit fun(submission: { event: changeset.pending_review.Event, body: string? }, settled: fun(err: string?)) The window closes once `settled` gets no error.

---@param lines changeset.Line[]
---@return integer
local function widest(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line.text) + 1)
  end
  return width
end

---@type integer?
local open_win

---Open the preview centred in the editor, focused.
---@param opts changeset.SubmitWindowOpts
---@return integer win
function M.open(opts)
  if open_win and vim.api.nvim_win_is_valid(open_win) then
    vim.api.nvim_win_close(open_win, true)
  end
  local source = vim.api.nvim_get_current_win()
  local event, body = opts.events[1], nil ---@type changeset.pending_review.Event, string?
  local body_row, body_win, closed, submitting = 1, nil, false, false

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  local function info()
    return { events = opts.events, event = event, body = body, comments = opts.comments, drafts = opts.drafts }
  end
  local function footer()
    return " " .. SENDS[event]:format(opts.number) .. " "
  end
  local function fit(lines)
    return math.min(math.max(widest(lines), MIN_WIDTH), MAX_WIDTH, vim.o.columns - 4)
  end
  local first = render.submit_lines(info())
  local width = fit(first)
  local height = math.min(#first, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = (" Submit review · #%d "):format(opts.number),
    title_pos = "left",
    footer = "",
    footer_pos = "left",
  })
  vim.wo[win].wrap = false
  open_win = win

  local function draw()
    local lines
    lines, body_row = render.submit_lines(info())
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      vim.tbl_map(function(line)
        return line.text
      end, lines)
    )
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, line in ipairs(lines) do
      for _, mark in ipairs(line.marks) do
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, mark.col, { end_col = mark.end_col, hl_group = mark.hl })
      end
    end
    local config = vim.api.nvim_win_get_config(win)
    config.width = fit(lines)
    config.col = math.floor((vim.o.columns - config.width) / 2)
    config.footer = footer()
    vim.api.nvim_win_set_config(win, config)
  end

  local function close()
    if closed then
      return
    end
    closed = true
    local current = vim.api.nvim_get_current_win()
    local focused = current == win or current == body_win
    if body_win and vim.api.nvim_win_is_valid(body_win) then
      vim.api.nvim_win_close(body_win, true)
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Closing the body float left `prevwin` on the preview, so Neovim would land on the first window.
    if focused and vim.api.nvim_win_is_valid(source) then
      vim.api.nvim_set_current_win(source)
    end
  end
  -- Fires: the preview closing any way (a key, :q, <C-w>c), so the body float and focus follow it.
  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = close })

  local function take_body(text)
    -- The body float can outlive the preview; its keep must not redraw a wiped buffer.
    if closed then
      return
    end
    body = text:find("%S") and text or nil
    draw()
  end

  local function write_body()
    if submitting then
      return
    end
    if body_win and vim.api.nvim_win_is_valid(body_win) then
      return vim.api.nvim_set_current_win(body_win)
    end
    body_win = review_comment_window.open({
      line = body_row,
      title = "Review body",
      footer = "sent with the review on #" .. opts.number,
      keys = opts.keys,
      save_desc = "Keep this body",
      close_desc = "Keep this body",
      body = body,
      save = function(text, done)
        take_body(text)
        done(nil)
      end,
      keep = take_body,
    })
  end

  local function submit()
    if submitting then
      return
    end
    -- Closing runs its keep synchronously, so `body` is current below.
    if body_win and vim.api.nvim_win_is_valid(body_win) then
      vim.api.nvim_win_close(body_win, true)
    end
    submitting = true
    opts.submit({ event = event, body = body }, function(err)
      submitting = false
      if not err then
        close()
      end
    end)
  end

  local map, own = help.mapper(buf)
  map("<CR>", submit, "Submit the review")
  if #opts.events > 1 then
    for _, choice in ipairs(CHOOSE) do
      if vim.tbl_contains(opts.events, choice[2]) then
        map(choice[1], function()
          event = choice[2]
          draw()
        end, choice[3])
      end
    end
  end
  map("b", write_body, "Write the review's body")
  map("q", close, "Close without submitting")
  map("<Esc>", close, "Close without submitting")
  map("?", function()
    help.show(buf, own)
  end, "Show these keymaps")

  draw()
  return win
end

return M
