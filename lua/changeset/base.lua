---`:Changeset base`: compares the current branch against a ref of the user's choosing, named or picked from its
---branches, tags or commits, or against the base it guesses again.
local Git = require("changeset.git")
local Paths = require("changeset.paths")
local cells = require("changeset.cells")
local base_preview = require("changeset.base_preview")
local fork_point = require("changeset.fork_point")
local highlights = require("changeset.highlights")
local pick_preview = require("changeset.pick_preview")
local render = require("changeset.render")

local M = {}

local ns = vim.api.nvim_create_namespace("changeset.base")

---@class changeset.BaseItem
---@field text string What a query matches: the ref, and a commit's subject after it.
---@field ref string What the branch is compared against once it is picked.
---@field date string When it was last committed to, as git says it.
---@field kind changeset.RefKind

---@class changeset.base.Source
---@field noun string
---@field none string? What the picker says instead of opening on nothing; absent for a source that streams.
---@field command string[] Prints a candidate per line: its ref, its date and, for a commit, its subject, split by tabs.
---@field stream boolean? Whether its items arrive as git prints them, rather than before the picker opens: a commit's
---source is HEAD's whole history.

---@type table<changeset.RefKind, changeset.base.Source>
local SOURCES = {
  branch = {
    noun = "a branch",
    none = "no other branches",
    command = {
      "git",
      "for-each-ref",
      "--sort=-committerdate",
      -- A symbolic ref, as `origin/HEAD` is, prints an empty line.
      "--format=%(if)%(symref)%(then)%(else)%(refname:short)%09%(committerdate:relative)%(end)",
      "refs/heads",
      "refs/remotes",
    },
  },
  tag = {
    noun = "a tag",
    none = "no tags",
    command = {
      "git",
      "for-each-ref",
      "--sort=-creatordate",
      "--format=%(refname:short)%09%(creatordate:relative)",
      "refs/tags",
    },
  },
  commit = { noun = "a commit", command = { "git", "log", "--format=%h%x09%cr%x09%s", "HEAD" }, stream = true },
}

---The current buffer's repository and the branch checked out there, or nothing, having said why.
---@return string? root
---@return string? branch
local function current()
  local root = Paths.root(0)
  local branch = Git.head(root)
  if branch and branch ~= "HEAD" then
    return root, branch
  end
  vim.notify("Changeset: a base is set per branch, and HEAD is on none", vim.log.levels.ERROR)
end

---Measure `branch` at `root` from `ref`, or guess again when it is nil.
---@param root string
---@param branch string
---@param ref string?
local function pin(root, branch, ref)
  if ref and not Git.merge_base(root, ref) then
    return vim.notify(("Changeset: HEAD shares no history with %s"):format(ref), vim.log.levels.ERROR)
  end
  if not fork_point.pin(root, branch, ref) then
    vim.notify("Changeset: could not save the base", vim.log.levels.ERROR)
  end
end

---The candidates `SOURCES[kind].command` printed, less `branch` itself.
---@param kind changeset.RefKind
---@param branch string
---@param lines string[]
---@return changeset.BaseItem[]
local function parse(kind, branch, lines)
  local items = {}
  for _, entry in ipairs(lines) do
    local ref, date, subject = entry:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
    if ref and not (kind == "branch" and ref == branch) then
      items[#items + 1] = { ref = ref, date = date, kind = kind, text = subject == "" and ref or ref .. " " .. subject }
    end
  end
  return items
end

---`source.show`: each item under its kind's glyph, a remote or a hash dimmed so the name leads, and its date at the
---right edge wherever that leaves the name whole.
---@param buf integer
---@param items changeset.BaseItem[]
---@param query string[]
local function show(buf, items, query)
  local glyphs = vim.tbl_map(function(item)
    return render.REF_ICONS[item.kind] .. " "
  end, items)
  local lines = vim
    .iter(ipairs(items))
    :map(function(i, item)
      return glyphs[i] .. item.text
    end)
    :totable()
  require("mini.pick").default_show(buf, lines, query)
  local win = vim.fn.bufwinid(buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or 80
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, item in ipairs(items) do
    local dim = item.kind == "commit" and item.ref or item.ref:match("^origin/") or ""
    for _, mark in ipairs({
      { 0, #glyphs[i], "Directory" },
      { #glyphs[i], #glyphs[i] + #dim, "Comment" },
    }) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, mark[1], { end_col = mark[2], hl_group = mark[3], priority = 199 })
    end
    local date = item.date .. " "
    -- mini.pick's own column of padding, and a cell between the name and the date.
    if cells.width(" " .. lines[i]) + 1 + cells.width(date) <= width then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = { { date, highlights.META_HL } },
        virt_text_pos = "right_align",
        priority = 199,
      })
    end
  end
end

M._show = show

---Compare the current branch against `ref`, a branch, tag or commit, until it is reset.
---@param ref string
function M.set(ref)
  local root, branch = current()
  if root and branch then
    pin(root, branch, ref)
  end
end

---Compare the current branch against the base it guesses again.
function M.reset()
  local root, branch = current()
  if root and branch then
    pin(root, branch, nil)
  end
end

---Pick a ref of `kind` to compare the current branch against: with mini.pick when it is set up, beside a preview of
---what the sidebar would hold against it, and `vim.ui.select` otherwise.
---@param kind changeset.RefKind
function M.pick(kind)
  local root, branch = current()
  if not (root and branch) then
    return
  end
  local source = SOURCES[kind]
  local title = "Compare against " .. source.noun
  ---@param lines string[]
  local function items(lines)
    return parse(kind, branch, lines)
  end
  ---@param item changeset.BaseItem?
  local function choose(item)
    if item then
      pin(root, branch, item.ref)
    end
  end
  local listed = not source.stream and items(Git.lines(source.command, root)) or nil
  if listed and #listed == 0 then
    return vim.notify(("Changeset: %s to compare against"):format(source.none), vim.log.levels.WARN)
  end
  -- `require` first so a lazy-loading manager can load and set mini.pick up; then `MiniPick`, which only `setup()`
  -- creates.
  local ready = pcall(require, "mini.pick") and MiniPick
  if not ready then
    return vim.ui.select(listed or items(Git.lines(source.command, root)), {
      prompt = title,
      format_item = function(item)
        return item.text
      end,
    }, choose)
  end
  highlights.define_highlights()
  pick_preview.setup()
  require("mini.pick").start({
    source = {
      items = listed or function()
        require("mini.pick").set_picker_items_from_cli(
          source.command,
          { postprocess = items, spawn_opts = { cwd = root } }
        )
      end,
      name = title,
      show = show,
      preview = function(buf, item)
        base_preview.show(buf, root, item.ref, item.kind)
      end,
      choose = choose,
    },
    window = pick_preview.window(),
  })
end

return M
