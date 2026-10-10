require("support.gh") -- a fake gh on PATH: never the real one, never the network
local Notify = require("support.notify")
local Paths = require("changeset.paths")
local base = require("changeset.base")
local fixture = require("support.git")
local fork_point = require("changeset.fork_point")

---Commit a file named `name` at `date`, which orders the branches whose tip it is.
---@param root string
---@param name string
---@param date string
---@return string sha
local function commit_at(root, name, date)
  vim.env.GIT_COMMITTER_DATE = date
  vim.fn.writefile({ name }, root .. "/" .. name)
  local sha = fixture.commit(name, root)
  vim.env.GIT_COMMITTER_DATE = nil
  return sha
end

---What the current branch is compared against now.
---@return string
local function against()
  return assert(fork_point.get(Paths.root(0), "feature")).against
end

describe(":Changeset base", function()
  local root, previous, notes, restore, real_select
  ---@type { items: string[], choose: fun(item: string?) }?
  local offered

  -- `main`, then `parent` off it, then `feature` off that, checked out, each tip a day newer; `origin/main` at the root
  -- commit, and `origin/HEAD` pointing at it.
  before_each(function()
    root, previous = fixture.enter_tempdir()
    vim.env.GIT_COMMITTER_DATE = "2026-01-01T00:00:00"
    local first = fixture.init_repo("main", root)
    commit_at(root, "main.txt", "2026-01-02T00:00:00")
    fixture.git({ "checkout", "-q", "-b", "parent" }, root)
    commit_at(root, "parent.txt", "2026-01-03T00:00:00")
    fixture.git({ "checkout", "-q", "-b", "feature" }, root)
    commit_at(root, "feature.txt", "2026-01-04T00:00:00")
    fixture.git({ "update-ref", "refs/remotes/origin/main", first }, root)
    fixture.git({ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" }, root)
    vim.cmd.edit("feature.txt")
    notes, restore = Notify.capture()
    real_select, offered = vim.ui.select, nil
    vim.ui.select = function(items, _, on_choice)
      offered = { items = items, choose = on_choice }
    end
  end)

  after_each(function()
    vim.ui.select = real_select
    restore()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous)
    vim.fn.delete(root, "rf")
  end)

  it("compares the current branch against the ref it is given", function()
    base.set("main")

    assert.equal("main", against())
  end)

  it("refuses a ref HEAD shares no history with, leaving the base as it was", function()
    base.set("nowhere")

    assert.equal(1, #Notify.messages(notes, vim.log.levels.ERROR))
    assert.equal("parent", against())
  end)

  it("refuses on a detached HEAD", function()
    fixture.git({ "checkout", "-q", "--detach" }, root)

    base.set("main")

    assert.equal(1, #Notify.messages(notes, vim.log.levels.ERROR))
  end)

  it("forgets the base set for the current branch", function()
    base.set("main")

    base.reset()

    assert.equal("parent", against())
  end)

  it("offers the other branches, local and remote, newest first", function()
    base.pick()

    assert.same({ "parent", "main", "origin/main" }, assert(offered).items)
  end)

  it("compares against the branch picked", function()
    base.pick()
    assert(offered).choose("main")

    assert.equal("main", against())
  end)

  it("leaves the base as it was when the picker is dismissed", function()
    base.set("main")

    base.pick()
    assert(offered).choose(nil)

    assert.equal("main", against())
  end)

  it("offers first to guess again while a base is set, and guesses again when that is picked", function()
    base.set("main")

    base.pick()
    local picker = assert(offered)
    picker.choose(picker.items[1])

    assert.equal("parent", against())
  end)
end)
