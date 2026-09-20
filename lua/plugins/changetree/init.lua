---A read-only sidebar mapping what this branch changed, nested by symbol.
---
---See README.md for the design. This file is the glue: it gathers the diff and
---the symbols, hands them to `tree` and `render`, and owns the window state
---machine. The thinking happens in the pure modules it calls.

local Git = require("helpers.git")
local Paths = require("helpers.paths")
local cache = require("plugins.changetree.cache")
local render = require("plugins.changetree.render")
local resolve = require("plugins.changetree.resolve")
local state = require("plugins.changetree.state")
local tree = require("plugins.changetree.tree")
local view = require("plugins.changetree.view")
local window = require("plugins.changetree.window")

-- gitsigns republishes on every sign refresh, several times per write. One
-- rebuild per burst is enough, and a rebuild mid-keypress is what the identity
-- re-anchoring exists to survive.
local REFRESH_DEBOUNCE_MS = 250

-- input() reads a line, so it can never hand one back: free to mean "cancelled".
local CANCELLED = "\r"

-- One write per burst of answers rather than one per file.
local SAVE_DEBOUNCE_MS = 1000

local M = {}

---@class changetree.Config
---@field gitsigns_base boolean Point gitsigns' base at the fork point while the sidebar is open, so `<leader>gP`'s gutter marks the whole branch.

---@type changetree.Config
local config = { gitsigns_base = true }

local ns = vim.api.nvim_create_namespace("changetree")
local augroup = vim.api.nvim_create_augroup("changetree", { clear = true })

---@class changetree.Session
---@field root string
---@field base string
---@field ref string Ref the fork point was measured against, e.g. "origin/trunk".
---@field branch string
---@field default_branch string
---@field files changetree.File[]
---@field symbols table<string, MiniPickers.Symbol[]> Absent key means "still resolving".
---@field rows changetree.Row[]
---@field visible changetree.Row[]
---@field st changetree.State
---@field query string
---@field cancel fun()?
---@field timer uv.uv_timer_t?

---@type changetree.Session?
local session

---Symbols read for the repo at `root`, carried between openings and to disk.
---@type { root: string, entries: table<string, changetree.CacheEntry> }?
local memo

---@type uv.uv_timer_t?
local save_timer

---Folds outlive a close, so reopening the sidebar looks like you left it.
---@type changetree.State
local folds = state.new()

local function save_soon()
  if save_timer then
    save_timer:stop()
  end
  save_timer = vim.defer_fn(function()
    if memo then
      cache.save(cache.path(memo.root), memo.entries)
    end
  end, SAVE_DEBOUNCE_MS)
end

---@param row changetree.Row
---@return string glyph, string hl
local function icon_for(row)
  local category, name = "lsp", "Text"
  if row.kind == "file" then
    category, name = "file", row.path
  elseif row.kind == "symbol" then
    name = row.symbol_kind or "Text"
  end
  local ok, glyph, hl = pcall(MiniIcons.get, category, name)
  if ok then
    return glyph, hl
  end
  return " ", "Normal"
end

---@return changetree.Row?
local function row_at_cursor()
  if not session then
    return nil
  end
  local win = window.win()
  if not win then
    return nil
  end
  return session.visible[vim.api.nvim_win_get_cursor(win)[1]]
end

local function preview_current()
  local row = row_at_cursor()
  if row and row.lnum and row.kind ~= "file" then
    -- Only a symbol row names its destination. An orphan hunk's own text is the
    -- changed line, which is not a place and does not read as one.
    window.preview(session.root .. "/" .. row.path, row.lnum, row.kind == "symbol" and row.name or nil)
  elseif row and row.kind == "file" and row.status ~= "deleted" then
    window.preview(session.root .. "/" .. row.path, 1)
  end
end

local function draw()
  local buf, win = window.buf(), window.win()
  if not (buf and win and vim.api.nvim_buf_is_valid(buf)) then
    return
  end

  local wanted = (row_at_cursor() or {}).id
  local previous_line = vim.api.nvim_win_get_cursor(win)[1]

  local shown = tree.compress(view.filter(session.rows, session.query), function(id)
    return state.is_chain_open(session.st, id)
  end)

  -- `render.lines` walks the tree for its guides, so it is the one place that
  -- decides which rows are on screen; each line carries its row back, which is
  -- how a cursor line maps to a row without re-deriving that walk here.
  local lines = render.lines(shown, {
    icon = icon_for,
    collapsed = function(id)
      return state.is_collapsed(session.st, id)
    end,
    width = vim.api.nvim_win_get_width(win),
  })

  session.visible = vim.tbl_map(function(line)
    return line.row
  end, lines)

  local text = vim.tbl_map(function(line)
    return line.text
  end, lines)
  if #text == 0 then
    text = {
      render.empty_message({
        on_default_branch = session.branch == session.default_branch,
        branch = session.branch,
        ref = session.ref,
      }),
    }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    for _, mark in ipairs(line.marks or {}) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, mark.col or 0, {
        end_col = mark.end_col,
        hl_group = mark.hl,
        virt_text = mark.virt_text,
        virt_text_pos = mark.pos,
        priority = 199,
      })
    end
  end

  local ids = vim.tbl_map(function(row)
    return row.id
  end, session.visible)
  vim.api.nvim_win_set_cursor(win, { state._reanchor(ids, wanted, previous_line), 0 })

  local added, removed = 0, 0
  for _, file in ipairs(session.files) do
    added, removed = added + (file.added or 0), removed + (file.removed or 0)
  end
  vim.wo[win].winbar = render.winbar({
    base_ref = session.ref,
    files = #session.files,
    added = added,
    removed = removed,
  })
end

---Text of a changed line, for captioning an orphan hunk.
---
---Prefers the buffer, which holds unwritten changes the file does not. Reading
---symbols is what loads a file, so a file answered from the cache has no buffer
---and is read from disk instead.
---@param path string
---@param lnum integer
---@return string?
local function line_text(path, lnum)
  if lnum < 1 then
    return nil
  end
  local full = session.root .. "/" .. path
  local buf = vim.fn.bufnr(full)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
  end
  local ok, lines = pcall(vim.fn.readfile, full, "", lnum)
  return ok and lines[lnum] or nil
end

local function rebuild()
  session.rows = tree.build(session.files, session.symbols, line_text)
  draw()
end

---@param row changetree.Row
---@param open boolean
local function set_open(row, open)
  -- A compressed chain hides intermediate rows; a folded row hides its children.
  -- `l` on a compressed row means the first, so it wins while the chain is shut.
  if row.chain and not state.is_chain_open(session.st, row.id) and open then
    state.set_chain_open(session.st, row.id, true)
  elseif row.chain and state.is_chain_open(session.st, row.id) and not open then
    state.set_chain_open(session.st, row.id, false)
  else
    state.set_collapsed(session.st, row.id, not open)
  end
  draw()
end

---@param how "reuse"|"vsplit"|"split"|"tab"
local function commit(how)
  local row = row_at_cursor()
  if not row then
    return
  end
  if row.kind == "file" and row.status == "deleted" then
    return vim.notify(row.path .. " was deleted on this branch — :CodeDiff to read it", vim.log.levels.INFO)
  end
  window.commit(session.root .. "/" .. row.path, row.lnum or 1, how)
end

---@param delta integer
local function step(delta)
  local win = window.win()
  if not (session and win) then
    return
  end
  local lnum = math.max(1, math.min(vim.api.nvim_win_get_cursor(win)[1] + delta, #session.visible))
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  preview_current()
end

---@param buf integer
local function set_keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end

  map("<CR>", function()
    commit("reuse")
  end, "Go to this change")
  map("<C-v>", function()
    commit("vsplit")
  end, "Go to this change in a vertical split")
  map("<C-x>", function()
    commit("split")
  end, "Go to this change in a split")
  map("<C-t>", function()
    commit("tab")
  end, "Go to this change in a new tab")
  map("q", M.close, "Close the tree")
  map("l", function()
    local row = row_at_cursor()
    if row then
      set_open(row, true)
    end
  end, "Expand")
  map("h", function()
    local row = row_at_cursor()
    if row then
      set_open(row, false)
    end
  end, "Collapse")
  map("zR", function()
    state.expand_all(session.st)
    draw()
  end, "Expand every file")
  map("zM", function()
    state.collapse_all(
      session.st,
      vim.tbl_map(function(row)
        return row.id
      end, session.rows)
    )
    draw()
  end, "Collapse every file")
  map("R", M.refresh, "Rebuild the tree")
  map("y", function()
    local row = row_at_cursor()
    if row then
      Paths.copy(row.lnum and ("%s:%d"):format(row.path, row.lnum) or row.path, "relative path:line")
    end
  end, "Yank path:line")
  map("?", function()
    require("plugins.changetree.help").show(buf)
  end, "Show these keymaps")
  map("/", function()
    local previous = session.query
    local group = vim.api.nvim_create_augroup("changetree.filter", { clear = true })
    -- input() edits on the command line, so every keystroke is a CmdlineChanged
    -- — which is what lets the tree narrow as it is typed rather than at <CR>.
    vim.api.nvim_create_autocmd("CmdlineChanged", {
      group = group,
      desc = "changetree: filter the tree on each keystroke of the filter prompt",
      callback = function()
        session.query = vim.fn.getcmdline()
        draw()
        vim.cmd("redraw")
      end,
    })

    local ok, typed = pcall(vim.fn.input, {
      prompt = "Filter changes: ",
      default = previous,
      cancelreturn = CANCELLED,
    })
    vim.api.nvim_del_augroup_by_id(group)

    session.query = (ok and typed ~= CANCELLED) and typed or previous
    draw()
  end, "Filter the tree")
end

---Gather the diff, then let symbols fill in behind it.
function M.refresh()
  if not session then
    return
  end
  if session.cancel then
    session.cancel()
    session.cancel = nil
  end

  local diff = require("plugins.changetree.diff")
  diff.collect(session.base, session.root, function(files, err)
    if not session then
      return
    end
    if not files then
      return vim.notify("Change Tree: " .. (err or "git failed"), vim.log.levels.ERROR)
    end
    session.files = files

    -- Stamped before the request rather than after: a file edited while its
    -- symbols are being read then fails this check next time, instead of
    -- leaving behind an answer for content that has already moved on.
    local stamps = {}
    local known, unknown = cache.fresh(memo.entries, files, function(path)
      stamps[path] = cache.stamp(session.root .. "/" .. path)
      return stamps[path]
    end)
    session.symbols = known

    -- Down to what this diff needs: the file caches the branch being read, not
    -- every file whose symbols have ever been asked for.
    memo.entries = {}
    for path, symbols in pairs(known) do
      memo.entries[path] = { stamp = stamps[path], symbols = symbols }
    end
    rebuild()

    -- A server that answers nothing is "resolved with no symbols", which is what
    -- turns every hunk in an unsupported file into an orphan row. Leaving the key
    -- absent would instead read as "still resolving", forever.
    session.cancel = resolve.start(session.root, unknown, function(path, items)
      if session then
        session.symbols[path] = items or {}
        if stamps[path] then
          memo.entries[path] = { stamp = stamps[path], symbols = cache.project(items or {}) }
          save_soon()
        end
        rebuild()
      end
    end)
  end)
end

---Point the gutter at the same fork point the tree is measured against, so the
---signs cover the branch rather than just uncommitted work.
---
---Only ever switched on. A close is not a dismissal: the gutter is the user's
---to put back with `:PRReview` when they are done with it.
---@param gitsigns table? The plugin's module, absent when it is not installed.
---@param base string Fork point from the default branch.
---@param wanted boolean
function M._review_gutter(gitsigns, base, wanted)
  if gitsigns and wanted then
    gitsigns.change_base(base, true)
  end
end

function M.open()
  if session then
    M.close()
  end
  local base, _, ref = Git.merge_base()
  if not base then
    return vim.notify("Change Tree: no merge base with the default branch", vim.log.levels.WARN)
  end

  local ok, gitsigns = pcall(require, "gitsigns")
  M._review_gutter(ok and gitsigns or nil, base, config.gitsigns_base)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "changetree"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = false

  local root = Paths.root(0)
  if not memo or memo.root ~= root then
    memo = { root = root, entries = cache.load(cache.path(root)) }
  end

  local default_branch = Git.default_base()
  session = {
    root = root,
    base = base,
    ref = ref or default_branch,
    branch = Git.lines({ "git", "rev-parse", "--abbrev-ref", "HEAD" })[1] or "HEAD",
    default_branch = default_branch,
    files = {},
    symbols = {},
    rows = {},
    visible = {},
    st = folds,
    query = "",
  }

  render.define_highlights()
  window.open(buf)
  set_keymaps(buf)

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = buf,
    desc = "changetree: preview the row under the cursor without leaving the sidebar",
    callback = preview_current,
  })
  -- Advance the selection from the file you are reading, so a whole branch can be
  -- reviewed without ever putting the cursor in the sidebar. Not <C-n>/<C-p>:
  -- plugin/multicursor.lua owns those, and shadowing them would mean deleting a
  -- user mapping on close. `h` is free across mini.bracketed's targets.
  vim.keymap.set("n", "]h", function()
    step(1)
  end, { desc = "Next change (Change Tree)" })
  vim.keymap.set("n", "[h", function()
    step(-1)
  end, { desc = "Previous change (Change Tree)" })

  M.refresh()
end

function M.close()
  if session then
    if session.cancel then
      session.cancel()
    end
    if session.timer then
      session.timer:stop()
    end
  end
  session = nil
  pcall(vim.keymap.del, "n", "]h")
  pcall(vim.keymap.del, "n", "[h")
  vim.api.nvim_clear_autocmds({ group = augroup })
  window.close()
end

---Fill the window a restored session left standing where the sidebar was.
---
---A session records the layout but not a scratch buffer's contents, so the
---sidebar comes back empty. Filling that window is also what keeps the next
---`<leader>gp` from opening a second one beside it.
function M.restore()
  local placeholder = window.placeholder()
  if not placeholder then
    return
  end
  M.open()
  if not window.is_visible() then
    vim.api.nvim_win_close(placeholder, true)
  end
end

---@param opts changetree.Config?
function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
end

---What `<leader>gp` does next, given where the sidebar and the cursor are.
---@param st { visible: boolean, focused: boolean }
---@return "open"|"focus"|"close"
function M._next_action(st)
  if not st.visible then
    return "open"
  end
  return st.focused and "close" or "focus"
end

---Open, focus, or dismiss the sidebar, depending on where the cursor is.
function M.toggle()
  local action = M._next_action({ visible = window.is_visible(), focused = window.is_focused() })
  if action == "open" then
    M.open()
    window.focus()
  elseif action == "focus" then
    window.focus()
  else
    M.close()
  end
end

-- The meta highlight is mixed from Comment's foreground, which a new colorscheme
-- replaces. Same idiom as lua/config/highlights.lua.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("changetree.highlights", { clear = true }),
  desc = "changetree: rebuild the dim label colour against the new palette",
  callback = render.define_highlights,
})

-- gitsigns publishes this on every sign refresh, so it doubles as a "the diff
-- may have moved" hook — a commit, a write, or a checkout made outside Neovim.
vim.api.nvim_create_autocmd("User", {
  pattern = "GitSignsUpdate",
  group = vim.api.nvim_create_augroup("changetree.watch", { clear = true }),
  desc = "changetree: rebuild the tree after the working tree or branch changes",
  callback = function()
    if not session then
      return
    end
    if session.timer then
      session.timer:stop()
    end
    session.timer = vim.defer_fn(function()
      if session then
        M.refresh()
      end
    end, REFRESH_DEBOUNCE_MS)
  end,
})

return M
