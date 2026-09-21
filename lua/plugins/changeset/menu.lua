---The popup that chooses which symbol kinds the tree shows.
---
---Docked against the sidebar's left edge rather than laid over it, because `x`
---redraws the tree behind the float and watching that happen is how the choice
---gets made. Toggling is immediate; the three save keys only decide where it is
---remembered, and closing without one puts back the set that is on disk.

local help = require("plugins.changeset.help")
local prefs = require("plugins.changeset.prefs")
local render = require("plugins.changeset.render")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.menu")

local MIN_WIDTH = 28
local MAX_HEIGHT = 14

---What the border says about where the shown set is remembered.
local FOOTER = {
  global = "set everywhere",
  repo = "set for this repo",
  branch = "set for this branch",
}

---@class changeset.MenuOpts
---@field root string       Repo root a repo-scoped save is filed under.
---@field branch string
---@field counts table<string, integer> Symbol rows per kind across the whole tree.
---@field hidden table<string, true>    Kinds the tree is hiding now.
---@field icon fun(kind: string): string, string Glyph and its highlight group.
---@field sidebar integer   Window the menu docks against.
---@field on_change fun(hidden: table<string, true>) Redraw the tree with this set.

---@class changeset.MenuState
---@field buf integer
---@field win integer
---@field width integer
---@field rows changeset.KindRow[]
---@field hidden table<string, true> The working set, as `x` leaves it.
---@field saved table<string, true>  The set on disk, which `q` goes back to.
---@field scope changeset.Scope?
---@field opts changeset.MenuOpts

---@type changeset.MenuState?
local menu

---One row per kind the branch touched, noisiest first.
---
---Weight rather than alphabet: the kind filling the tree with rows you did not
---want is the decision being made, so it is the one at the top. Ties break by
---name so the list does not shuffle between openings.
---@param counts table<string, integer> From `view.kind_counts`.
---@param hidden table<string, true>
---@return changeset.KindRow[]
function M._rows(counts, hidden)
  local rows = {}
  for kind, count in pairs(counts) do
    rows[#rows + 1] = { kind = kind, count = count, hidden = hidden[kind] == true }
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.kind < b.kind
  end)
  return rows
end

---What a save changed, in the words the key offered it in.
---@param kinds string[] Hidden kind names.
---@param where string Prose for the scope, e.g. "everywhere".
---@return string
function M._confirmation(kinds, where)
  if #kinds == 0 then
    return ("Showing every kind %s."):format(where)
  end
  return ("Hiding %s %s."):format(render.kind_list(kinds), where)
end

---The border's footer: where this set lives, or that it does not live anywhere yet.
---
---A working set that has drifted from the saved one says so, because `q` throws
---that drift away and a footer naming a scope would read as though it were safe.
---@param hidden table<string, true> Working set.
---@param saved table<string, true>  Set on disk.
---@param scope changeset.Scope?    Where `saved` came from.
---@return string
function M._footer(hidden, saved, scope)
  if not vim.deep_equal(hidden, saved) then
    return " unsaved changes "
  end
  if not scope then
    return " showing every kind "
  end
  return (" %s "):format(FOOTER[scope])
end

---@param scope changeset.Scope
---@param root string
---@param branch string
---@return string
local function where(scope, root, branch)
  if scope == "global" then
    return "everywhere"
  end
  if scope == "repo" then
    return "in " .. vim.fs.basename(root)
  end
  return "on " .. branch
end

---@param rows changeset.KindRow[]
---@param footer string
---@param room integer Cells between the editor's left edge and the sidebar.
---@return integer
local function width_for(rows, footer, room)
  local widest = MIN_WIDTH
  for _, row in ipairs(rows) do
    -- Rail, space, glyph, space, name, a space, count.
    widest = math.max(widest, 5 + vim.fn.strdisplaywidth(row.kind) + #tostring(row.count))
  end
  return math.min(math.max(widest, vim.fn.strdisplaywidth(footer) + 2), math.max(room, MIN_WIDTH))
end

local function draw()
  local lines = render.kind_lines(menu.rows, { icon = menu.opts.icon, width = menu.width })

  vim.bo[menu.buf].modifiable = true
  vim.api.nvim_buf_set_lines(
    menu.buf,
    0,
    -1,
    false,
    vim.tbl_map(function(line)
      return line.text
    end, lines)
  )
  vim.bo[menu.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(menu.buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    for _, mark in ipairs(line.marks) do
      vim.api.nvim_buf_set_extmark(menu.buf, ns, i - 1, mark.col, { end_col = mark.end_col, hl_group = mark.hl })
    end
  end

  local config = vim.api.nvim_win_get_config(menu.win)
  config.footer = M._footer(menu.hidden, menu.saved, menu.scope)
  vim.api.nvim_win_set_config(menu.win, config)
end

---Close the menu, leaving the tree showing whatever the working set is.
function M.close()
  if not menu then
    return
  end
  local win, buf = menu.win, menu.buf
  menu = nil
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function toggle()
  -- Read from the menu's own window rather than the current one: `?` hands the
  -- keys to a which-key float, and they still act on the row under this cursor.
  if not (menu and vim.api.nvim_win_is_valid(menu.win)) then
    return
  end
  local row = menu.rows[vim.api.nvim_win_get_cursor(menu.win)[1]]
  if not row then
    return
  end
  row.hidden = not row.hidden
  menu.hidden[row.kind] = row.hidden or nil
  draw()
  menu.opts.on_change(vim.deepcopy(menu.hidden))
end

---@param scope changeset.Scope
local function save(scope)
  if not menu then
    return
  end
  local file, opts = prefs.path(), menu.opts
  if not prefs.save(file, prefs.apply(prefs.load(file), scope, opts.root, opts.branch, menu.hidden)) then
    return vim.notify("Changeset: could not write " .. file, vim.log.levels.ERROR)
  end
  local hiding = vim.tbl_keys(menu.hidden)
  table.sort(hiding)
  M.close()
  vim.notify(M._confirmation(hiding, where(scope, opts.root, opts.branch)))
end

---Close, putting the tree back to the set that is on disk.
local function dismiss()
  if not menu then
    return
  end
  local restore, on_change = menu.saved, menu.opts.on_change
  M.close()
  on_change(vim.deepcopy(restore))
end

---@param buf integer
local function set_keymaps(buf)
  -- What `?` documents, collected as it is set — the same reason the sidebar does.
  local own = {}
  local function map(lhs, fn, desc)
    own[#own + 1] = lhs
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end

  map("x", toggle, "Hide or show this kind")
  map("<CR>", function()
    save("global")
  end, "Remember everywhere")
  map("r", function()
    save("repo")
  end, "Remember for this repository")
  map("b", function()
    save("branch")
  end, "Remember for this branch")
  map("q", dismiss, "Close, putting back the saved kinds")
  map("<Esc>", dismiss, "Close, putting back the saved kinds")
  map("?", function()
    help.show(buf, own)
  end, "Show these keymaps")
end

---Open the menu against the sidebar.
---@param opts changeset.MenuOpts
function M.open(opts)
  M.close()
  local saved, scope = prefs.resolve(prefs.load(prefs.path()), opts.root, opts.branch)
  local hidden = vim.deepcopy(opts.hidden)
  local rows = M._rows(opts.counts, hidden)
  if #rows == 0 then
    return vim.notify("Changeset: nothing to filter — no symbols in this branch's changes yet")
  end

  local footer = M._footer(hidden, saved, scope)
  local top, left = unpack(vim.api.nvim_win_get_position(opts.sidebar))
  local width = width_for(rows, footer, left - 2)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = false

  -- Placed in editor cells rather than against the sidebar's own corner, because a
  -- float's border is drawn outside the size it is given: only arithmetic that
  -- counts it lands the right border on the cell the sidebar starts after, which is
  -- what docks the two together instead of leaving a gap.
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = top + 1,
    col = math.max(left - width - 1, 1),
    width = width,
    height = math.min(#rows, MAX_HEIGHT),
    style = "minimal",
    border = "rounded",
    title = " Symbol kinds ",
    title_pos = "left",
    footer = footer,
    footer_pos = "left",
  })
  vim.wo[win].cursorline = true

  menu = {
    buf = buf,
    win = win,
    width = width,
    rows = rows,
    hidden = hidden,
    saved = saved,
    scope = scope,
    opts = opts,
  }
  draw()
  set_keymaps(buf)
end

return M
