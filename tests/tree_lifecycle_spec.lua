local changeset = require("changeset")
local window = require("changeset.window")
local Fixture = require("support.git")
require("support.gh")

---@param tree changeset.Session?
---@return string[]
local function paths_of(tree)
  return vim.tbl_map(function(file)
    return file.path
  end, tree and tree.files or {})
end

---@return string
local function sidebar_text()
  return table.concat(vim.api.nvim_buf_get_lines(assert(window.buf()), 0, -1, false), "\n")
end

---@param path string
---@param timeout integer? Milliseconds.
---@return boolean
local function wait_for_file(path, timeout)
  return vim.wait(timeout or 10000, function()
    return vim.tbl_contains(paths_of(changeset._tree()), path)
  end, 25)
end

describe("changeset tree", function()
  local tmp, previous_dir

  -- The tree resolves its repo from the current buffer, which falls back to the
  -- process cwd, so the fixture has to be entered rather than merely pointed at.
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    previous_dir = vim.fn.chdir(tmp)
    assert(previous_dir ~= "", "could not enter the fixture directory")
  end)

  after_each(function()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  describe("on a branch forked from trunk", function()
    before_each(function()
      Fixture.init_repo("trunk", tmp)
      vim.fn.writefile({ "return 1" }, "mod.lua")
      Fixture.commit("base", tmp)
      Fixture.git({ "checkout", "-q", "-b", "feature" }, tmp)
      vim.fn.writefile({ "return 2" }, "mod.lua")
      Fixture.commit("change", tmp)
      vim.cmd.edit("mod.lua")
    end)

    it("builds without opening a window", function()
      local window_count = #vim.api.nvim_list_wins()

      assert.is_true(changeset.build())

      assert.is_true(wait_for_file("mod.lua"))
      assert.is_nil(window.win())
      assert.equal(window_count, #vim.api.nvim_list_wins())
    end)

    it("hands over the file rows on the first ask, before any build", function()
      local tree, err = changeset.rows()

      assert.is_nil(err)
      assert.same(
        { "mod.lua" },
        vim.tbl_map(function(row)
          return row.path
        end, assert(tree).rows)
      )
    end)

    it("keeps the tree it already built for the same fork point", function()
      changeset.build()
      local tree = changeset._tree()

      changeset.build()

      assert.equal(tree, changeset._tree())
    end)

    it("draws the built tree when the sidebar opens, and keeps it when it closes", function()
      changeset.build()
      assert.is_true(wait_for_file("mod.lua"))
      local tree = changeset._tree()

      changeset.open()
      local text = sidebar_text()
      changeset.close()

      assert.truthy(text:find("mod.lua", 1, true))
      assert.equal(tree, changeset._tree())
      assert.same({ "mod.lua" }, paths_of(changeset._tree()))
    end)

    it("rebuilds the tree for another branch at the same fork point", function()
      changeset.build()
      local tree = changeset._tree()

      Fixture.git({ "checkout", "-q", "-b", "feature2" }, tmp)
      changeset.build()

      assert.not_equal(tree, changeset._tree())
      assert.equal("feature2", changeset._tree().branch)
    end)

    it("rebuilds the tree once the fork point moves", function()
      changeset.build()
      local tree = assert(changeset._tree())

      Fixture.git({ "checkout", "-q", "trunk" }, tmp)
      vim.fn.writefile({ "return 1" }, "other.lua")
      Fixture.commit("trunk moves on", tmp)
      Fixture.git({ "checkout", "-q", "-b", "later" }, tmp)
      changeset.build()

      assert.not_equal(tree, changeset._tree())
      assert.not_equal(tree.base, assert(changeset._tree()).base)
    end)

    it("leaves the sidebar blank until the diff is read", function()
      changeset.open()

      assert.equal("", sidebar_text())
      assert.is_true(vim.wait(10000, function()
        return sidebar_text():find("mod.lua", 1, true) ~= nil
      end, 25))
    end)

    it("re-reads the diff when the sidebar reopens on a kept tree", function()
      changeset.build()
      assert.is_true(wait_for_file("mod.lua"))

      vim.fn.writefile({ "return 3" }, "new.lua")
      changeset.open()

      assert.is_true(wait_for_file("new.lua"))
    end)

    it("refreshes when gitsigns reports HEAD moved, while the sidebar is closed", function()
      changeset.build()
      assert.is_true(wait_for_file("mod.lua"))

      vim.fn.writefile({ "return 3" }, "new.lua")
      vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })

      assert.is_true(wait_for_file("new.lua"))
    end)

    it("refreshes once a buffer is written", function()
      changeset.build()
      assert.is_true(wait_for_file("mod.lua"))

      vim.cmd.edit("new.lua")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 3" })
      vim.cmd("silent write")

      assert.is_true(wait_for_file("new.lua"))
    end)

    for _, event in ipairs({ "FileChangedShellPost", "FocusGained" }) do
      it("refreshes on " .. event .. ", when a change made outside Neovim can surface", function()
        changeset.build()
        assert.is_true(wait_for_file("mod.lua"))

        vim.fn.writefile({ "return 3" }, "new.lua")
        vim.api.nvim_exec_autocmds(event, {})

        assert.is_true(wait_for_file("new.lua"))
      end)
    end

    describe("while its symbols are being read", function()
      local resolve = require("changeset.resolve")
      local real_start = resolve.start
      ---@type { paths: string[], answer: fun(path: string, items: table[]?) }[]
      local asks

      ---@param count integer
      local function wait_for_asks(count)
        assert.is_true(vim.wait(10000, function()
          return #asks == count
        end, 25))
      end

      before_each(function()
        asks = {}
        resolve.start = function(_, files, on_file)
          asks[#asks + 1] = {
            paths = vim.tbl_map(function(file)
              return file.path
            end, files),
            answer = on_file,
          }
          return function() end
        end
      end)

      after_each(function()
        resolve.start = real_start
      end)

      it("keeps what a replaced refresh read, so the next one does not ask again", function()
        changeset.build()
        wait_for_asks(1)
        changeset.refresh()
        wait_for_asks(2)

        asks[1].answer("mod.lua", {
          { name = "M", kind = "Variable", depth = 0, lnum = 1, range_lnum = 1, range_end_lnum = 1 },
        })
        changeset.refresh()
        wait_for_asks(3)

        assert.same({}, asks[3].paths)
      end)
    end)

    -- gitsigns fires a buffer's update on attach and on every hunk change while typing,
    -- none of which moves the diff git reads from disk.
    it("keeps the diff it has through a gitsigns update for one buffer", function()
      changeset.build()
      assert.is_true(wait_for_file("mod.lua"))

      vim.fn.writefile({ "return 3" }, "new.lua")
      vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = 0 } })

      assert.is_false(wait_for_file("new.lua", 600))
    end)
  end)

  describe("on a branch whose open PR targets another branch", function()
    before_each(function()
      Fixture.init_repo("trunk", tmp)
      Fixture.git({ "checkout", "-q", "-b", "parent" }, tmp)
      vim.fn.writefile({ "return 1" }, "parent.lua")
      Fixture.commit("parent change", tmp)
      Fixture.git({ "checkout", "-q", "-b", "child" }, tmp)
      vim.fn.writefile({ "return 2" }, "child.lua")
      Fixture.commit("child change", tmp)
      vim.cmd.edit("child.lua")
      vim.env.FAKE_GH_PR = '{"baseRefName":"parent","state":"OPEN"}'
    end)

    after_each(function()
      vim.env.FAKE_GH_PR = nil
    end)

    it("diffs against the PR's target once gh names it", function()
      changeset.build()

      assert.is_true(vim.wait(10000, function()
        local tree = changeset._tree()
        return tree ~= nil and tree.ref == "parent" and vim.deep_equal({ "child.lua" }, paths_of(tree))
      end, 25))
    end)
  end)

  describe("with nothing to diff against", function()
    local notify, notified

    before_each(function()
      notify, notified = vim.notify, 0
      vim.notify = function()
        notified = notified + 1
      end
    end)

    after_each(function()
      vim.notify = notify
    end)

    it("builds nothing, silently, outside a repository", function()
      local tree = changeset._tree()

      assert.is_false(changeset.build())

      assert.equal(tree, changeset._tree())
      assert.equal(0, notified)
    end)

    it("builds nothing, silently, in a repository with no default branch", function()
      Fixture.init_repo("work", tmp)
      local tree = changeset._tree()

      assert.is_false(changeset.build())

      assert.equal(tree, changeset._tree())
      assert.equal(0, notified)
    end)
  end)
end)
