vim.opt.rtp:prepend(require("support.deps").path("mini.pick"))
vim.opt.rtp:prepend(require("support.deps").path("mini.icons"))
require("mini.pick").setup()
require("mini.icons").setup()
require("support.gh")

local Fixture = require("support.git")
local present = require("support.present")
local Paths = require("changeset.paths")
local base = require("changeset.base")
local fork_point = require("changeset.fork_point")

describe("the base pickers with mini.pick", function()
  local root ---@type string
  local previous ---@type string

  -- `trunk`, then `feature` off it, checked out, and `other` off trunk, committed to last.
  before_each(function()
    root, previous = Fixture.enter_tempdir()
    Fixture.feature_one_file(root)
    Fixture.git({ "branch", "other", "trunk" }, root)
    vim.cmd.edit("mod.lua")
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous)
    vim.fn.delete(root, "rf")
  end)

  it("compares against the item chosen once the list has loaded", function()
    local function step()
      if not (present(MiniPick).is_picker_active() and #(present(MiniPick).get_picker_items() or {}) == 2) then
        return vim.defer_fn(step, 20)
      end
      vim.api.nvim_feedkeys("other" .. vim.keycode("<CR>"), "t", false)
    end
    vim.defer_fn(step, 20)

    base.pick("branch")

    assert.equal("other", present((fork_point.get(Paths.root(0), "feature"))).against)
  end)

  it("draws each item under its glyph, with when it was last committed to at the right edge", function()
    local buf = vim.api.nvim_create_buf(false, true)

    base._show(buf, { { text = "origin/main", ref = "origin/main", date = "5 hours ago", kind = "branch" } }, {})

    local line = present(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1])
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    local right = vim.iter(marks):find(function(mark)
      return mark[4].virt_text_pos == "right_align"
    end)
    assert.truthy(vim.endswith(line, " origin/main"), line)
    assert.equal("5 hours ago", vim.trim(present(right)[4].virt_text[1][1]))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("leaves out a date that would cover the name", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = 24, height = 2 })
    local long = "origin/feat/session-refresh-endpoint"

    base._show(buf, { { text = long, ref = long, date = "3 days ago", kind = "branch" } }, {})

    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    assert.is_false(vim.iter(marks):any(function(mark)
      return mark[4].virt_text_pos == "right_align"
    end))
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
