local changeset = require("changeset")
local build = require("changeset.build")
local window = require("changeset.window")
local Fixture = require("support.git")
local Sidebar = require("support.sidebar")
local gh = require("support.gh")

---@param tree changeset.Tree?
---@return string[]
local function paths_of(tree)
  return vim.tbl_map(function(file)
    return file.path
  end, tree and tree.files or {})
end

---@param path string
---@param timeout integer? Milliseconds.
---@return boolean
local function wait_for_file(path, timeout)
  return vim.wait(timeout or 10000, function()
    return vim.tbl_contains(paths_of(build.current()), path)
  end, 25)
end

describe("changeset tree", function()
  local tmp, previous_dir

  -- The tree resolves its repo from the current buffer, which falls back to the
  -- process cwd, so the fixture has to be entered rather than merely pointed at.
  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
  end)

  after_each(function()
    changeset.close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  describe("on a branch forked from trunk", function()
    before_each(function()
      Fixture.feature_one_file(tmp)
      vim.cmd.edit("mod.lua")
    end)

    it("builds without opening a window", function()
      local window_count = #vim.api.nvim_list_wins()

      assert.is_true(build.build())

      assert.is_true(wait_for_file("mod.lua"))
      assert.is_nil(window.win())
      assert.equal(window_count, #vim.api.nvim_list_wins())
    end)

    it("hands over each file row's path, name, stats and place in the tree on the first ask", function()
      local tree, err = changeset.rows()

      assert.is_nil(err)
      tree = assert(tree)
      assert.equal(1, #tree.rows)
      assert.is_string(tree.root)
      assert.equal("trunk", tree.ref)
      local row = tree.rows[1]
      assert.is_string(row.id)
      assert.is_table(row.children)
      assert.same({
        kind = "file",
        path = "mod.lua",
        name = "mod.lua",
        depth = 1,
        lnum = 1,
        added = 1,
        removed = 1,
        ancestor = false,
        status = "modified",
      }, {
        kind = row.kind,
        path = row.path,
        name = row.name,
        depth = row.depth,
        lnum = row.lnum,
        added = row.added,
        removed = row.removed,
        ancestor = row.ancestor,
        status = row.status,
      })
    end)

    it("keeps the tree it already built for the same fork point", function()
      build.build()
      local tree = build.current()

      build.build()

      assert.equal(tree, build.current())
    end)

    it("draws the built tree when the sidebar opens", function()
      build.build()
      assert.is_true(wait_for_file("mod.lua"))

      changeset.open()

      assert.truthy(Sidebar.text():find("mod.lua", 1, true))
    end)

    it("keeps the tree after the sidebar closes", function()
      changeset.open()
      local tree = assert(build.current())

      changeset.close()

      assert.equal(tree, build.current())
    end)

    it("rebuilds the tree for another branch at the same fork point", function()
      build.build()
      local tree = build.current()

      Fixture.git({ "checkout", "-q", "-b", "feature2" }, tmp)
      build.build()

      assert.not_equal(tree, build.current())
      assert.equal("feature2", build.current().branch)
    end)

    it("rebuilds the tree when gitsigns sees HEAD land on another branch", function()
      build.build()
      local tree = build.current()

      Fixture.git({ "checkout", "-q", "-b", "feature2" }, tmp)
      vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })

      assert.is_true(vim.wait(2000, function()
        return build.current().branch == "feature2"
      end, 25))
      assert.not_equal(tree, build.current())
    end)

    it("refreshes the tree when gitsigns sees HEAD stay on its branch", function()
      build.build()
      assert.is_true(wait_for_file("mod.lua"))
      local tree = build.current()

      local refreshed = false
      build.subscribe(function(event)
        refreshed = refreshed or event == "diff"
      end)
      vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })

      assert.is_true(vim.wait(2000, function()
        return refreshed
      end, 25))
      assert.equal(tree, build.current())
    end)

    it("refreshes the tree when gitsigns sees HEAD detach", function()
      build.build()
      assert.is_true(wait_for_file("mod.lua"))
      local tree = build.current()

      Fixture.git({ "checkout", "-q", "--detach" }, tmp)
      local refreshed = false
      build.subscribe(function(event)
        refreshed = refreshed or event == "diff"
      end)
      vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })

      assert.is_true(vim.wait(2000, function()
        return refreshed
      end, 25))
      assert.equal(tree, build.current())
    end)

    it("rebuilds the tree once the fork point moves", function()
      build.build()
      local tree = assert(build.current())

      Fixture.git({ "checkout", "-q", "trunk" }, tmp)
      vim.fn.writefile({ "return 1" }, "other.lua")
      Fixture.commit("trunk moves on", tmp)
      Fixture.git({ "checkout", "-q", "-b", "later" }, tmp)
      build.build()

      assert.not_equal(tree, build.current())
      assert.not_equal(tree.base, assert(build.current()).base)
    end)

    it("leaves the sidebar blank until the diff is read", function()
      changeset.open()

      assert.equal("", Sidebar.text())
      assert.is_true(vim.wait(10000, function()
        return Sidebar.text():find("mod.lua", 1, true) ~= nil
      end, 25))
    end)

    it("re-reads the diff when the sidebar reopens on a kept tree", function()
      build.build()
      assert.is_true(wait_for_file("mod.lua"))

      vim.fn.writefile({ "return 3" }, "new.lua")
      changeset.open()

      assert.is_true(wait_for_file("new.lua"))
    end)

    it("refreshes when gitsigns reports HEAD moved, while the sidebar is closed", function()
      build.build()
      assert.is_true(wait_for_file("mod.lua"))

      vim.fn.writefile({ "return 3" }, "new.lua")
      vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })

      assert.is_true(wait_for_file("new.lua"))
    end)

    it("refreshes once a buffer is written", function()
      build.build()
      assert.is_true(wait_for_file("mod.lua"))

      vim.cmd.edit("new.lua")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 3" })
      vim.cmd("silent write")

      assert.is_true(wait_for_file("new.lua"))
    end)

    for _, event in ipairs({ "FileChangedShellPost", "FocusGained" }) do
      it("refreshes on " .. event .. ", when a change made outside Neovim can surface", function()
        build.build()
        assert.is_true(wait_for_file("mod.lua"))

        vim.fn.writefile({ "return 3" }, "new.lua")
        vim.api.nvim_exec_autocmds(event, {})

        assert.is_true(wait_for_file("new.lua"))
      end)
    end

    describe("while its symbols are being read", function()
      local symbols = require("support.symbols")
      ---@type support.symbols.Ask[]
      local asks
      ---@type fun()
      local restore

      ---@param count integer
      local function wait_for_asks(count)
        assert.is_true(vim.wait(10000, function()
          return #asks == count
        end, 25))
      end

      before_each(function()
        local source = symbols.install()
        asks, restore = source.asks, source.restore
      end)

      after_each(function()
        restore()
      end)

      it("keeps what a replaced refresh read, so the next one does not ask again", function()
        build.build()
        wait_for_asks(1)
        build.refresh()
        wait_for_asks(2)

        asks[1].answer("mod.lua", {
          { name = "M", kind = "Variable", depth = 0, lnum = 1, range_lnum = 1, range_end_lnum = 1 },
        })
        build.refresh()
        wait_for_asks(3)

        assert.same({}, asks[3].paths)
      end)
    end)

    -- gitsigns fires a buffer's update on attach and on every hunk change while typing,
    -- none of which moves the diff git reads from disk.
    it("keeps the diff it has through a gitsigns update for one buffer", function()
      build.build()
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
      vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent", number = 1 })
    end)

    after_each(function()
      vim.env.FAKE_GH_PR = nil
    end)

    it("diffs against the PR's target once gh names it", function()
      build.build()

      assert.is_true(vim.wait(10000, function()
        local tree = build.current()
        return tree ~= nil and tree.ref == "parent" and vim.deep_equal({ "child.lua" }, paths_of(tree))
      end, 25))
    end)

    it("redraws the open sidebar on the tree gh's answer builds", function()
      changeset.open()

      assert.is_true(vim.wait(10000, function()
        local text = Sidebar.text()
        return text:find("child.lua", 1, true) ~= nil and not text:find("parent.lua", 1, true)
      end, 25))
    end)
  end)

  describe("on a branch whose open PR targets the branch it forked from", function()
    before_each(function()
      Fixture.feature_one_file(tmp)
      vim.cmd.edit("mod.lua")
      vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "trunk", number = 7 })
    end)

    after_each(function()
      vim.env.FAKE_GH_PR = nil
    end)

    it("names the PR in the open sidebar's header", function()
      changeset.open()

      assert.is_true(vim.wait(10000, function()
        local win = window.win()
        return win ~= nil and vim.wo[win].winbar:find("#7", 1, true) ~= nil
      end, 25))
    end)
  end)

  describe("when the diff cannot be read", function()
    local collect, notify

    before_each(function()
      Fixture.feature_one_file(tmp)
      vim.cmd.edit("mod.lua")
      collect, notify = require("changeset.diff").collect, vim.notify
    end)

    after_each(function()
      require("changeset.diff").collect, vim.notify = collect, notify
    end)

    it("drops a restored position waiting on it", function()
      local sidebar_state = require("changeset.sidebar_state")
      build.build()
      assert.is_true(vim.wait(10000, function()
        return assert(build.current()).collected
      end, 25))
      local position = assert(sidebar_state.current()).position
      position:restore({ here = { path = "mod.lua", lnum = 5 } }, require("changeset.draw").view(), function()
        return false
      end)
      require("changeset.diff").collect = function(_, _, callback)
        callback(nil, "boom")
      end
      vim.notify = function() end

      build.refresh()

      assert.not_nil(position:saved(nil))
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
      local tree = build.current()

      assert.is_false(build.build())

      assert.equal(tree, build.current())
      assert.equal(0, notified)
    end)

    it("builds nothing, silently, in a repository with no default branch", function()
      Fixture.init_repo("work", tmp)
      local tree = build.current()

      assert.is_false(build.build())

      assert.equal(tree, build.current())
      assert.equal(0, notified)
    end)
  end)
end)
