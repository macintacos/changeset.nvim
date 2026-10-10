require("support.gh") -- a fake gh on PATH: never the real one, never the network
local Notify = require("support.notify")
local Paths = require("changeset.paths")
local base = require("changeset.base")
local fixture = require("support.git")
local present = require("support.present")
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

---The ref each item names, in order.
---@param items changeset.BaseItem[]
---@return string[]
local function refs(items)
  return vim.tbl_map(function(item)
    return item.ref
  end, items)
end

---What the current branch is compared against now.
---@return string
local function against()
  return present((fork_point.get(Paths.root(0), "feature"))).against
end

describe(":Changeset base", function()
  local root ---@type string
  local previous ---@type string
  local notes ---@type support.notify.Note[]
  local restore ---@type fun()
  local real_select
  ---@type { items: changeset.BaseItem[], choose: fun(item: changeset.BaseItem?), format: fun(item: changeset.BaseItem): string }?
  local offered
  ---Each commit's short hash, by the file it added.
  ---@type table<string, string>
  local short

  -- `main`, then `parent` off it, then `feature` off that, checked out, each tip a day newer; `origin/main` at the root
  -- commit, and `origin/HEAD` pointing at it. Tag `v1` is on main's tip, `v2` on parent's.
  before_each(function()
    root, previous = fixture.enter_tempdir()
    vim.env.GIT_COMMITTER_DATE = "2026-01-01T00:00:00"
    local first = fixture.init_repo("main", root)
    local main = commit_at(root, "main.txt", "2026-01-02T00:00:00")
    fixture.git({ "checkout", "-q", "-b", "parent" }, root)
    local parent = commit_at(root, "parent.txt", "2026-01-03T00:00:00")
    fixture.git({ "checkout", "-q", "-b", "feature" }, root)
    local feature = commit_at(root, "feature.txt", "2026-01-04T00:00:00")
    fixture.git({ "update-ref", "refs/remotes/origin/main", first }, root)
    fixture.git({ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" }, root)
    fixture.git({ "tag", "v1", main }, root)
    fixture.git({ "tag", "v2", parent }, root)
    short = {}
    for name, sha in pairs({ root = first, ["main.txt"] = main, ["parent.txt"] = parent, ["feature.txt"] = feature }) do
      short[name] = fixture.git({ "rev-parse", "--short", sha }, root)
    end
    vim.cmd.edit("feature.txt")
    notes, restore = Notify.capture()
    real_select, offered = vim.ui.select, nil
    vim.ui.select = function(items, opts, on_choice)
      offered = { items = items, choose = on_choice, format = present(opts.format_item) }
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

  it("offers the other branches, local and remote, the one committed to last first", function()
    base.pick("branch")

    assert.same({ "parent", "main", "origin/main" }, refs(present(offered).items))
  end)

  it("offers the tags, the newest first", function()
    base.pick("tag")

    assert.same({ "v2", "v1" }, refs(present(offered).items))
  end)

  it("says there are no tags rather than offering none", function()
    fixture.git({ "tag", "-d", "v1", "v2" }, root)

    base.pick("tag")

    assert.is_nil(offered)
    assert.equal(1, #Notify.messages(notes, vim.log.levels.WARN))
  end)

  it("offers HEAD's commits, the newest first", function()
    base.pick("commit")

    assert.same(
      { short["feature.txt"], short["parent.txt"], short["main.txt"], short.root },
      refs(present(offered).items)
    )
  end)

  it("names a commit by its hash and subject", function()
    base.pick("commit")
    local picker = present(offered)

    assert.equal(short["feature.txt"] .. " feature.txt", picker.format(present(picker.items[1])))
  end)

  it("compares against the branch picked", function()
    base.pick("branch")
    local picker = present(offered)
    picker.choose(picker.items[2])

    assert.equal("main", against())
  end)

  it("compares against the tag picked", function()
    base.pick("tag")
    local picker = present(offered)
    picker.choose(picker.items[2])

    assert.equal("v1", against())
  end)

  it("compares against the commit picked", function()
    base.pick("commit")
    local picker = present(offered)
    picker.choose(picker.items[3])

    assert.equal(short["main.txt"], against())
  end)

  it("leaves the base as it was when the picker is dismissed", function()
    base.set("main")

    base.pick("branch")
    present(offered).choose(nil)

    assert.equal("main", against())
  end)
end)
