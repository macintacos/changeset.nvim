local changeset = require("changeset")
local render = require("changeset.render")
local window = require("changeset.window")
local Fixture = require("support.git")
local gh = require("support.gh")

describe("changeset header circle", function()
  local tmp, previous_dir

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    Fixture.init_repo("trunk", tmp)
    Fixture.git({ "checkout", "-q", "-b", "parent" }, tmp)
    vim.fn.writefile({ "return 1" }, "parent.lua")
    Fixture.commit("parent change", tmp)
    Fixture.git({ "checkout", "-q", "-b", "child" }, tmp)
    vim.fn.writefile({ "return 2" }, "child.lua")
    Fixture.commit("child change", tmp)
    vim.cmd.edit("child.lua")
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent", number = 1 })
  end)

  after_each(function()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    vim.env.FAKE_GH_PR = nil
    vim.env.FAKE_GH_DELAY = nil
    gh.reset()
  end)

  ---@return { str: string, highlights: table[] }
  local function winbar()
    local win = assert(window.win())
    return vim.api.nvim_eval_statusline(vim.wo[win].winbar, { use_winbar = true, winid = win, highlights = true })
  end

  ---The group drawing the circle, or nil when the header shows none.
  ---@return string?
  local function circle_group()
    local shown = winbar()
    local at = shown.str:find("●", 1, true)
    if not at then
      return nil
    end
    local found
    for _, mark in ipairs(shown.highlights) do
      if mark.start <= at - 1 then
        found = mark.group
      end
    end
    return found
  end

  it("follows the PR's pending review as GitHub answers, and keeps it when an ask fails", function()
    vim.env.FAKE_GH_DELAY = "0.3"
    gh.fixture("find-pending-review-empty")
    changeset.open()

    assert.is_true(vim.wait(10000, function()
      return window.win() ~= nil and winbar().str:find("#1", 1, true) ~= nil
    end, 10))
    assert.is_nil(circle_group())
    assert.is_true(vim.wait(10000, function()
      return circle_group() == render.HEADER_NOT_PENDING_HL
    end, 25))
    vim.env.FAKE_GH_DELAY = nil

    gh.fixture("find-pending-review-rest-created")
    gh.fixture("review-comments-paginate-slurp")
    vim.api.nvim_exec_autocmds("FocusGained", {})
    assert.is_true(vim.wait(10000, function()
      return circle_group() == render.HEADER_PENDING_HL
    end, 25))

    vim.api.nvim_exec_autocmds("FocusGained", {})
    assert.is_false(vim.wait(500, function()
      return circle_group() ~= render.HEADER_PENDING_HL
    end, 25))

    local before = #gh.calls()
    vim.fn.writefile({ "return 3" }, "child.lua")
    vim.api.nvim_exec_autocmds("BufWritePost", { pattern = vim.fn.fnamemodify("child.lua", ":p") })
    assert.is_false(vim.wait(500, function()
      return #gh.calls() > before
    end, 25))
  end)
end)
