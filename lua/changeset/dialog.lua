---Dialogs drawn as changeset's own floats: a question before a destructive action.
local render = require("changeset.render")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.dialog")

-- Prose reads at a short measure, so the body wraps here unless the editor is narrower.
local MEASURE = 44
-- Cells between the border and the text, either side.
local PAD = 2
-- Above other floats and the popup menu (100), under the command line and ui2's message windows (197-200).
local ZINDEX = 150
local QUOTE = "▎ "
local ELLIPSIS = "…"
-- The button that changes nothing, first and focused so a <CR> typed ahead lands on it.
local SAFE = "Keep"

---@class changeset.DialogBlock A paragraph of a dialog's body.
---@field text string
---@field hl? string Group for the text; the float's own when absent.
---@field quote? string Group of a bar drawn before each of its lines, marking it as quoted.
---@field max_lines? integer Lines it may take: past them it is cut, and its last line ends in "…".

---@class changeset.ConfirmOpts
---@field title string The action it asks about, e.g. "Abandon the review".
---@field body changeset.DialogBlock[]
---@field action string The verb on the button that goes ahead, e.g. "Abandon".

---Text and the group, or stacked groups, it is drawn in.
---@alias changeset.DialogChunk { [1]: string, [2]: string|string[]|nil }

---@alias changeset.DialogLine changeset.DialogChunk[]

---@class changeset.DialogState
---@field win integer
---@field buf integer
---@field opener integer The window current when it opened, which gets focus back.
---@field done boolean
---@field answer fun(value: any)

---@param text string
---@return integer
local function cells(text)
  return vim.fn.strdisplaywidth(text)
end

---The longest head of `text` at most `room` cells wide, and never less than its first character.
---@param text string
---@param room integer
---@return string
local function head(text, room)
  local n = vim.fn.strchars(text)
  while n > 1 and cells(vim.fn.strcharpart(text, 0, n)) > room do
    n = n - 1
  end
  return vim.fn.strcharpart(text, 0, n)
end

---`text` in lines at most `width` cells wide, broken between words, and inside a word wider than that.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
  local lines = {}
  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      if line ~= "" and cells(line .. " " .. word) <= width then
        line = line .. " " .. word
      else
        if line ~= "" then
          lines[#lines + 1] = line
        end
        while cells(word) > width do
          local piece = head(word, width)
          lines[#lines + 1] = piece
          word = word:sub(#piece + 1)
        end
        line = word
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

---The body's lines: each block wrapped at `width` cells, its quote bar included.
---@param blocks changeset.DialogBlock[]
---@param width integer
---@return changeset.DialogLine[]
function M._body(blocks, width)
  local lines = {}
  for _, block in ipairs(blocks) do
    local bar = block.quote and QUOTE or ""
    local measure = width - cells(bar)
    local texts = wrap((block.text:gsub("%s+$", "")), measure)
    if block.max_lines and #texts > block.max_lines then
      texts = vim.list_slice(texts, 1, block.max_lines)
      texts[#texts] = head(texts[#texts], measure - cells(ELLIPSIS)) .. ELLIPSIS
    end
    for _, text in ipairs(texts) do
      lines[#lines + 1] = block.quote and { { bar, block.quote }, { text, block.hl } } or { { text, block.hl } }
    end
  end
  return lines
end

---Cells the editor leaves a dialog's text: its width less the border and `pad` cells either side.
---@param pad integer
---@return integer
local function room(pad)
  return vim.o.columns - 2 - 2 * pad
end

---Writes `lines` into `buf`, colouring each chunk.
---@param buf integer
---@param lines changeset.DialogLine[]
local function paint(buf, lines)
  local texts, marks = {}, {}
  for i, line in ipairs(lines) do
    local parts, col = {}, 0
    for _, chunk in ipairs(line) do
      parts[#parts + 1] = chunk[1]
      if chunk[2] then
        marks[#marks + 1] = { i - 1, col, col + #chunk[1], chunk[2] }
      end
      col = col + #chunk[1]
    end
    texts[i] = table.concat(parts)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
end

---Closes the dialog, gives focus back to the window it opened from, then answers: in that order, so whatever the
---answer opens or focuses is not undone by the close.
---@param state changeset.DialogState
---@param value any
local function finish(state, value)
  if state.done then
    return
  end
  state.done = true
  if vim.api.nvim_win_is_valid(state.opener) then
    vim.api.nvim_set_current_win(state.opener)
  end
  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  vim.schedule(function()
    state.answer(value)
  end)
end

---Cells `line` takes.
---@param line changeset.DialogLine
---@return integer
local function line_cells(line)
  return cells(table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, line)))
end

---Opens and enters a float holding `lines`, `width` cells wide within the editor, centred on it.
---@param lines changeset.DialogLine[]
---@param title string
---@param width integer
---@param answer fun(value: any) Called once, with nil on a cancel.
---@return changeset.DialogState
local function open(lines, title, width, answer)
  width = math.min(math.max(width, cells(" " .. title .. " ")), vim.o.columns - 2)
  local height = math.min(#lines, math.max(vim.o.lines - vim.o.cmdheight - 4, 1))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  paint(buf, lines)
  local state = {
    buf = buf,
    opener = vim.api.nvim_get_current_win(),
    done = false,
    answer = answer,
  }
  state.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - vim.o.cmdheight - height - 2) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width - 2) / 2), 0),
    style = "minimal",
    border = "rounded",
    title = { { " " .. title .. " ", "FloatTitle" } },
    title_pos = "left",
    zindex = ZINDEX,
  })
  -- Fires: focus leaving the dialog other than through its keys, which cancels it: it is modal while open.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    desc = "changeset: cancel a dialog whose window is left",
    callback = function()
      -- Closing a window is not allowed while focus is leaving it.
      vim.schedule(function()
        finish(state, nil)
      end)
    end,
  })
  return state
end

---Maps `lhs` in the dialog's buffer.
---@param state changeset.DialogState
---@param lhs string[]
---@param rhs fun()
---@param desc string
local function map(state, lhs, rhs, desc)
  for _, key in ipairs(lhs) do
    vim.keymap.set("n", key, rhs, { buffer = state.buf, nowait = true, desc = desc })
  end
end

---A row of pills, one per label, the last drawn as destructive and the focused one lit; and the byte range each
---takes on the line, for a click.
---@param labels string[]
---@param focus integer
---@return changeset.DialogLine chunks
---@return [integer, integer][] ranges
local function buttons(labels, focus)
  local chunks, ranges, col = {}, {}, 0
  for i, label in ipairs(labels) do
    if i > 1 then
      chunks[#chunks + 1] = { "  " }
      col = col + 2
    end
    local danger = i == #labels
    local hl = danger and (i == focus and render.BUTTON_DANGER_FOCUS_HL or render.BUTTON_DANGER_HL)
      or (i == focus and render.BUTTON_FOCUS_HL or render.BUTTON_HL)
    vim.list_extend(chunks, {
      { "  ", hl },
      { label:sub(1, 1), { hl, render.BUTTON_KEY_HL } },
      { label:sub(2) .. "  ", hl },
    })
    ranges[i] = { col, col + #label + 4 }
    col = col + #label + 4
  end
  return chunks, ranges
end

---Asks before a destructive action, calling `yes` only once its button is pressed. Focus starts on Keep, so a
---<CR> typed ahead declines; leaving the window any other way declines too. `yes` runs scheduled, once the dialog
---has closed and focus is back on the window it opened from.
---@param opts changeset.ConfirmOpts
---@param yes fun()
function M.confirm(opts, yes)
  local labels = { SAFE, opts.action }
  local body = M._body(opts.body, math.min(MEASURE, room(PAD)))
  local row, ranges = buttons(labels, 1)
  local width = line_cells(row)
  for _, line in ipairs(body) do
    width = math.max(width, line_cells(line))
  end
  local margin = { (" "):rep(PAD) }
  local indent = { (" "):rep(PAD + width - ranges[#ranges][2]) }

  ---@param focus integer
  ---@return changeset.DialogLine[]
  local function lines(focus)
    local out = { {} }
    for _, line in ipairs(body) do
      out[#out + 1] = vim.list_extend({ margin }, line)
    end
    out[#out + 1] = {}
    out[#out + 1] = vim.list_extend({ indent }, (buttons(labels, focus)))
    out[#out + 1] = {}
    return out
  end

  local focus = 1
  local state = open(lines(focus), opts.title, width + 2 * PAD, function(ok)
    if ok then
      yes()
    end
  end)
  local buttons_line = #body + 3

  ---@param to integer
  local function move(to)
    focus = to
    paint(state.buf, lines(focus))
    vim.api.nvim_win_set_cursor(state.win, { buttons_line, #indent[1] + ranges[focus][1] + 2 })
  end
  ---@param i integer
  local function press(i)
    finish(state, i == #labels)
  end
  move(focus)

  map(state, { "<Tab>" }, function()
    move(focus % #labels + 1)
  end, "Focus the next button")
  map(state, { "<S-Tab>" }, function()
    move((focus - 2) % #labels + 1)
  end, "Focus the previous button")
  map(state, { "h", "<Left>" }, function()
    move(math.max(focus - 1, 1))
  end, "Focus the button to the left")
  map(state, { "l", "<Right>" }, function()
    move(math.min(focus + 1, #labels))
  end, "Focus the button to the right")
  map(state, { "<CR>", "<Space>" }, function()
    press(focus)
  end, "Press the focused button")
  for i, label in ipairs(labels) do
    map(state, { label:sub(1, 1):lower() }, function()
      press(i)
    end, label)
  end
  map(state, { "q", "<Esc>" }, function()
    press(1)
  end, SAFE)
  map(state, { "<LeftRelease>" }, function()
    local pos = vim.fn.getmousepos()
    if pos.winid ~= state.win or pos.line ~= buttons_line then
      return
    end
    local col = pos.column - 1 - #indent[1]
    for i, range in ipairs(ranges) do
      if col >= range[1] and col < range[2] then
        return press(i)
      end
    end
  end, "Press the button clicked")
end

return M
