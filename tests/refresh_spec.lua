local comment_store = require("changeset.comment_store")
local Fixture = require("support.git")
local Paths = require("changeset.paths")

vim.cmd("runtime plugin/changeset.lua")

describe(":Changeset refresh", function()
  local tmp, previous_dir, notify, notes

  ---`changeset.build` as it loads fresh, holding no tree.
  ---@return table
  local function build()
    return require("changeset.build")
  end

  before_each(function()
    -- A fresh load holds no tree, so each case starts before any was built.
    package.loaded["changeset.build"], package.loaded.changeset = nil, nil
    tmp, previous_dir = Fixture.enter_tempdir()
    os.remove(comment_store.path())
    notify, notes = vim.notify, {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = notify
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
    os.remove(comment_store.path())
  end)

  it("says why when there is no tree and none can be built", function()
    vim.cmd("Changeset refresh")

    assert.is_nil(build().current())
    assert.same({ { msg = "Changeset: no merge base with the default branch", level = vim.log.levels.WARN } }, notes)
  end)

  it("builds the tree of the current buffer's repository when none is built", function()
    Fixture.feature_one_file(tmp)
    vim.cmd.edit("mod.lua")

    vim.cmd("Changeset refresh")

    assert.equal(Paths.root(0), assert(build().current()).root)
  end)

  it("marks the review comments of the files open when it builds the tree", function()
    Fixture.feature_one_file(tmp)
    vim.cmd.edit("mod.lua")
    comment_store.keep(Paths.root(0), { path = "mod.lua", line = 1, body = "here" })

    vim.cmd("Changeset refresh")

    local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
    assert.truthy(ns)
    assert.equal(1, #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}))
  end)
end)
