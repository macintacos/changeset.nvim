---Draws each review comment's whole text as a block under its last line, and parks the cursor on a block a one-line
---move reaches, as if it were a line of the file.
local config = require("changeset.config")
local dialog = require("changeset.dialog")
local render = require("changeset.render")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.review_comment_blocks")

-- The review comment window's measure, so a block reads as that window collapsed.
local MAX_WIDTH = 72
local MIN_WIDTH = 20
local HINT = " <CR> edit · d delete "
local SOLID = { h = "─", v = "│" }
local DASHED = { h = "┄", v = "┆" }

---@class changeset.Block
---@field id integer The extmark drawing it.
---@field comment changeset.ReviewComment

---@class changeset.ParkedBlock
---@field win integer
---@field buf integer
---@field index integer Into the buffer's blocks.
---@field at integer The line the cursor waits on: the block's own line, or the one under it.
---@field cursorline boolean The window's 'cursorline' before parking.
---@field maps table<string, table> The buffer's own maps the block's keys stood in for.

---Whether blocks show; nil until first asked, then `review_comment.blocks` decides.
---@type boolean?
local shown

---Each buffer's blocks, in the order a cursor meets them.
---@type table<integer, changeset.Block[]>
local drawn = {}

---@type changeset.ParkedBlock?
local parked

---Each window's buffer and cursor as the last `CursorMoved` left them.
---@type table<integer, { buf: integer, pos: integer[] }>
local last = {}

---@param text string
---@return integer
local function cells(text)
  return vim.fn.strdisplaywidth(text)
end

---Whether review comments show as blocks.
---@return boolean
function M.shown()
  if shown == nil then
    shown = config.get().review_comment.blocks
  end
  return shown == true
end

---Shows review comments as blocks in every buffer, or as their marks alone.
---@param on boolean
function M.show(on)
  shown = on
  require("changeset.review_comments").redraw()
end

---Switches every buffer between blocks and marks.
function M.toggle()
  M.show(not M.shown())
end

---"line 4", or "lines 3-5" for a range.
---@param comment changeset.ReviewComment
---@return string
local function lines_label(comment)
  local first, last_line = comment.start_line or comment.line, comment.line
  return first < last_line and ("lines %d-%d"):format(first, last_line) or ("line %d"):format(last_line)
end

-- ponytail: one width per buffer, from its narrowest window; a block in a wider window stays that narrow.
---The widest box inside `buf`'s narrowest window, borders excluded.
---@param buf integer
---@return integer
local function measure(buf)
  local room = MAX_WIDTH
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    room = math.min(room, vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff - 2)
  end
  return math.max(room, MIN_WIDTH)
end

---`comment`'s box as virtual lines, at most `widest` cells inside its border.
---@param comment changeset.ReviewComment
---@param widest integer
---@param is_parked boolean
---@return [string, string][][]
local function box(comment, widest, is_parked)
  -- TODO: read `draft` off changeset.ReviewComment once the drafts branch declares it there.
  local edge = (comment --[[@as { draft: boolean? }]]).draft and DASHED or SOLID
  local border = is_parked and render.BLOCK_PARKED_HL or render.BLOCK_BORDER_HL
  local title = " Review comment · " .. lines_label(comment) .. " "
  local text = dialog.wrap(vim.trim(comment.body:gsub("\r\n", "\n")), widest - 2)
  local inner = cells(title) + 1
  for _, line in ipairs(text) do
    inner = math.max(inner, cells(line) + 2)
  end
  inner = math.min(inner, widest)
  local lines = {
    {
      { "╭", border },
      { title, is_parked and render.BLOCK_PARKED_HL or render.BLOCK_TITLE_HL },
      { edge.h:rep(math.max(inner - cells(title), 0)), border },
      { "╮", border },
    },
  }
  for _, line in ipairs(text) do
    local padded = " " .. line .. (" "):rep(inner - cells(line) - 1)
    lines[#lines + 1] = { { edge.v, border }, { padded, render.BLOCK_BODY_HL }, { edge.v, border } }
  end
  local bottom = { { "╰", border } }
  local rest = inner
  if is_parked and cells(HINT) < inner then
    bottom[#bottom + 1] = { HINT, render.BLOCK_HINT_HL }
    rest = inner - cells(HINT)
  end
  vim.list_extend(bottom, { { edge.h:rep(rest), border }, { "╯", border } })
  lines[#lines + 1] = bottom
  return lines
end

---@param buf integer
---@param index integer
---@param is_parked boolean
local function paint(buf, index, is_parked)
  local block = drawn[buf][index]
  vim.api.nvim_buf_set_extmark(buf, ns, block.comment.line - 1, 0, {
    id = block.id,
    virt_lines = box(block.comment, measure(buf), is_parked),
  })
end

---Gives back the buffer's own maps the parked block's keys stood in for.
---@param state changeset.ParkedBlock
local function unmap(state)
  for lhs, saved in pairs(state.maps) do
    pcall(vim.keymap.del, "n", lhs, { buffer = state.buf })
    if saved.buffer == 1 then
      vim.api.nvim_buf_call(state.buf, function()
        vim.fn.mapset("n", false, saved)
      end)
    end
  end
end

---Lets go of the parked block, if any.
local function unpark()
  local state = parked
  if not state then
    return
  end
  parked = nil
  if vim.api.nvim_buf_is_valid(state.buf) and drawn[state.buf] and drawn[state.buf][state.index] then
    paint(state.buf, state.index, false)
  end
  unmap(state)
  dialog.show_cursor()
  if vim.api.nvim_win_is_valid(state.win) then
    vim.wo[state.win].cursorline = state.cursorline
  end
end

---Scrolls `win` the least that shows the parked block whole, when it fits.
---@param state changeset.ParkedBlock
local function reveal(state)
  local line = drawn[state.buf][state.index].comment.line
  local below = state.at == line
  local text = vim.api.nvim_buf_get_lines(state.buf, line - 1, line, false)[1]
  vim.api.nvim_win_call(state.win, function()
    for _ = 1, vim.api.nvim_win_get_height(0) do
      if below then
        local next_line = math.min(line + 1, vim.api.nvim_buf_line_count(state.buf))
        local top = vim.fn.screenpos(0, line, 1).row
        if vim.fn.screenpos(0, next_line, 1).row > 0 or next_line == line or top <= vim.fn.win_screenpos(0)[1] then
          return
        end
        vim.cmd.normal({ vim.keycode("<C-e>"), bang = true })
      else
        local cur = vim.fn.screenpos(0, state.at, 1).row
        local bottom = vim.fn.win_screenpos(0)[1] + vim.api.nvim_win_get_height(0) - 1
        if vim.fn.screenpos(0, line, math.max(#text, 1)).row > 0 or cur >= bottom then
          return
        end
        vim.cmd.normal({ vim.keycode("<C-y>"), bang = true })
      end
    end
  end)
end

---@param lhs string
---@param rhs fun()
---@param desc string
---@param state changeset.ParkedBlock
local function map(state, lhs, rhs, desc)
  local saved = vim.api.nvim_buf_call(state.buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
  state.maps[lhs] = saved
  vim.keymap.set("n", lhs, rhs, { buffer = state.buf, nowait = true, desc = desc })
end

---Parks the cursor of `win` on `buf`'s block `index`, waiting on line `at`.
---@param win integer
---@param buf integer
---@param index integer
---@param at integer
local function park(win, buf, index, at)
  unpark()
  local state = { win = win, buf = buf, index = index, at = at, cursorline = vim.wo[win].cursorline, maps = {} }
  parked = state
  paint(buf, index, true)
  -- The block is what the cursor is on; the line it waits on would read as focused instead.
  dialog.hide_cursor()
  vim.wo[win].cursorline = false
  local comment = drawn[buf][index].comment
  local function edit()
    unpark()
    require("changeset.reviewing").open(comment)
  end
  map(state, "<CR>", edit, "Edit the review comment")
  map(state, "c", edit, "Edit the review comment")
  map(state, "d", function()
    unpark()
    require("changeset.reviewing").ask_delete(comment)
  end, "Delete the review comment")
  map(state, "<Esc>", unpark, "Step off the review comment")
  reveal(state)
end

---Indexes of `buf`'s blocks under line `line`, top first.
---@param buf integer
---@param line integer
---@return integer[]
local function under(buf, line)
  local found = {}
  for i, block in ipairs(drawn[buf] or {}) do
    if block.comment.line == line then
      found[#found + 1] = i
    end
  end
  return found
end

---@param win integer
---@param pos integer[]
local function put(win, pos)
  vim.api.nvim_win_set_cursor(win, pos)
  last[win].pos = pos
end

---Moves on from the parked block after the cursor moved `delta` lines off where it waited, to `pos`.
---@param state changeset.ParkedBlock
---@param delta integer
---@param pos integer[]
local function step_off(state, delta, pos)
  local line = drawn[state.buf][state.index].comment.line
  local stack = under(state.buf, line)
  local k = vim.fn.index(stack, state.index) + 1
  local neighbour = (delta == 1 or delta == -1) and stack[k + delta]
  if neighbour then
    put(state.win, { state.at, pos[2] })
    return park(state.win, state.buf, neighbour, state.at)
  end
  unpark()
  -- The cursor moved from where it waited, not from the block, so a step onto the far side's line is put right.
  if delta == 1 and state.at == line + 1 then
    put(state.win, { line + 1, pos[2] })
  elseif delta == -1 and state.at == line then
    put(state.win, { line, pos[2] })
  end
end

---Parks the cursor on a block a one-line move just crossed, or moves it on from the parked one.
---@param buf integer
local function moved(buf)
  local win = vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_cursor(win)
  local prev = last[win]
  last[win] = { buf = buf, pos = pos }
  if parked and parked.win == win then
    return step_off(parked, pos[1] - parked.at, pos)
  end
  if not (prev and prev.buf == buf and drawn[buf]) then
    return
  end
  local delta = pos[1] - prev.pos[1]
  local crossed = delta == 1 and under(buf, prev.pos[1]) or delta == -1 and under(buf, pos[1]) or {}
  if #crossed > 0 then
    put(win, prev.pos)
    park(win, buf, delta == 1 and crossed[1] or crossed[#crossed], prev.pos[1])
  end
end

---Draws `comments`, those of `buf`'s file, as blocks while blocks show, dropping the blocks drawn before.
---@param buf integer
---@param comments changeset.ReviewComment[]
function M.draw(buf, comments)
  if parked and parked.buf == buf then
    unpark()
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  drawn[buf] = nil
  if not M.shown() or #comments == 0 then
    return
  end
  local ordered = {}
  for i, comment in ipairs(comments) do
    ordered[i] = { i = i, comment = comment }
  end
  table.sort(ordered, function(a, b)
    return a.comment.line < b.comment.line or (a.comment.line == b.comment.line and a.i < b.i)
  end)
  local widest = measure(buf)
  drawn[buf] = vim.tbl_map(function(entry)
    return {
      comment = entry.comment,
      id = vim.api.nvim_buf_set_extmark(buf, ns, entry.comment.line - 1, 0, {
        virt_lines = box(entry.comment, widest, false),
      }),
    }
  end, ordered)
end

local group = vim.api.nvim_create_augroup("changeset.review_comment_blocks", { clear = true })

-- Fires: any cursor move, so a one-line move across a block parks on it and the next one moves on.
vim.api.nvim_create_autocmd("CursorMoved", {
  group = group,
  desc = "changeset: park the cursor on a review comment block a one-line move reaches",
  callback = function(args)
    if drawn[args.buf] or parked then
      moved(args.buf)
    else
      last[vim.api.nvim_get_current_win()] = { buf = args.buf, pos = vim.api.nvim_win_get_cursor(0) }
    end
  end,
})

-- Fires: anything else done while parked, which the block's keys don't cover, so the cursor steps off it.
vim.api.nvim_create_autocmd({ "ModeChanged", "WinLeave", "BufLeave", "TextChanged" }, {
  group = group,
  desc = "changeset: step off a review comment block on any other action",
  callback = unpark,
})

-- Fires: windows resized or a buffer shown in another, which changes the narrowest window a block fits.
vim.api.nvim_create_autocmd({ "WinResized", "BufWinEnter" }, {
  group = group,
  desc = "changeset: refit review comment blocks to their narrowest window",
  callback = function()
    for buf, blocks in pairs(drawn) do
      if vim.api.nvim_buf_is_valid(buf) then
        M.draw(
          buf,
          vim.tbl_map(function(block)
            return block.comment
          end, blocks)
        )
      end
    end
  end,
})

return M
