local changeset = require("changeset")
local draw = require("changeset.draw")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")
local comment_store = require("changeset.comment_store")

---A branch off `trunk` changing alpha.txt and other.lua.
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
  end)

  for _, case in ipairs({
    { "a Comments row", "#comments\0alpha.txt:13-13", "alpha.txt" },
    { "a file row", "#implementation\0other.lua", "other.lua" },
  }) do
    it("puts the sidebar's cursor back on " .. case[1], function()
      tmp, previous_dir = setup_repo()
      vim.cmd.edit("alpha.txt")
      os.remove(comment_store.path())
      comment_store.keep(require("changeset.paths").root(0), { path = "alpha.txt", line = 13, body = "check this" })
      local leftover = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(leftover, "changeset://tree")
      vim.api.nvim_open_win(leftover, false, { split = "right", win = -1, width = 44 })
      vim.g.ChangesetPosition = vim.json.encode({ row = { id = case[2], path = case[3] } })

      changeset.restore()
      assert.is_true(vim.wait(10000, function()
        return vim.iter(Sidebar.lines()):any(function(line)
          return line:find("alpha.txt:13", 1, true) ~= nil
        end)
      end, 25))
      Sidebar.settle()

      local row = draw.row_at_cursor()
      assert.equal(case[2], row and row.id)
    end)
  end
end)
