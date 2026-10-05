local changeset = require("changeset")
local draw = require("changeset.draw")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")
local gh = require("support.gh")

---A branch with an open PR into `trunk` whose pending review comments on alpha.txt.
---@return string tmp
---@return string previous_dir
local function setup_repo()
  local tmp, previous_dir = Fixture.enter_tempdir()
  Fixture.init_repo("trunk", tmp)
  vim.fn.writefile({ "local M = {}", "return M" }, "other.lua")
  Fixture.commit("other", tmp)
  Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
  local lines = {}
  for i = 1, 40 do
    lines[i] = "alpha " .. i
  end
  vim.fn.writefile(lines, "alpha.txt")
  vim.fn.writefile({ "local M = {}", "M.x = 1", "return M" }, "other.lua")
  Fixture.commit("alpha", tmp)
  vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "trunk", number = 1 })
  gh.fixture("find-pending-review")
  gh.fixture("review-comments-paginate-slurp")
  return tmp, previous_dir
end

describe("a restored session", function()
  local tmp, previous_dir

  after_each(function()
    changeset.close()
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    vim.g.ChangesetPosition = nil
    vim.env.FAKE_GH_PR = nil
    vim.env.FAKE_GH_DELAY = nil
  end)

  for _, case in ipairs({
    { "a Comments row, with GitHub slow to answer", "0.3", "#comments\0PRRC_kwDOU6Rmbc74w1gd", "alpha.txt" },
    { "a Comments row, with GitHub answering at once", "0", "#comments\0PRRC_kwDOU6Rmbc74w1gd", "alpha.txt" },
    { "a file row", "0", "#implementation\0other.lua", "other.lua" },
  }) do
    it("puts the sidebar's cursor back on " .. case[1], function()
      tmp, previous_dir = setup_repo()
      vim.env.FAKE_GH_DELAY = case[2]
      vim.cmd.edit("alpha.txt")
      local leftover = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(leftover, "changeset://tree")
      vim.api.nvim_open_win(leftover, false, { split = "right", win = -1, width = 44 })
      vim.g.ChangesetPosition = vim.json.encode({ row = { id = case[3], path = case[4] } })

      changeset.restore()
      assert.is_true(vim.wait(10000, function()
        return vim.iter(Sidebar.lines()):any(function(line)
          return line:find("alpha.txt:13", 1, true) ~= nil
        end)
      end, 25))
      Sidebar.settle()

      local row = draw.row_at_cursor()
      assert.equal(case[3], row and row.id)
    end)
  end
end)
