local gh = require("support.gh")
local fixture = require("support.git")
local Git = require("changeset.git")
local fork_point = require("changeset.fork_point")

---@type { root: string, branch: string, point: changeset.ForkPoint }[]
local heard = {}
fork_point.subscribe(function(root, branch, point)
  table.insert(heard, { root = root, branch = branch, point = point })
end)

---@param root string
---@return { root: string, branch: string, point: changeset.ForkPoint }[]
local function heard_in(root)
  return vim.tbl_filter(function(h)
    return h.root == root
  end, heard)
end

---@param root string
---@param count integer
---@return boolean
local function await_heard(root, count)
  return vim.wait(5000, function()
    return #heard_in(root) >= count
  end)
end

---@param root string
---@param name string
---@return string
local function commit_file(root, name)
  vim.fn.writefile({ name }, root .. "/" .. name)
  return fixture.commit(name, root)
end

---A repository with `main`, then `parent` off it, then `feature` off that, checked out.
---@param source string? What `feature`'s reflog says it was created from: parent's tip commit, which names no
---parent, when absent.
---@return string root
---@return string default_base main's tip, where feature forked from main.
---@return string parent_base parent's tip.
local function stacked_repo(source)
  local root = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  fixture.init_repo("main", root)
  local default_base = commit_file(root, "main.txt")
  fixture.git({ "checkout", "-q", "-b", "parent" }, root)
  local parent_base = commit_file(root, "parent.txt")
  fixture.git({ "checkout", "-q", "-b", "feature", source or parent_base }, root)
  commit_file(root, "feature.txt")
  return root, default_base, parent_base
end

describe("fork_point", function()
  local real_pr, asks
  local roots = {}

  before_each(function()
    asks = 0
    real_pr = Git.pr
    Git.pr = function(...)
      asks = asks + 1
      return real_pr(...)
    end
  end)

  after_each(function()
    Git.pr = real_pr
    vim.env.FAKE_GH_PR = nil
    vim.env.FAKE_GH_DELAY = nil
    for _, root in ipairs(roots) do
      vim.fn.delete(root, "rf")
    end
    roots = {}
  end)

  ---@param source string?
  local function repo(source)
    local root, default_base, parent_base = stacked_repo(source)
    table.insert(roots, root)
    return root, default_base, parent_base
  end

  it("measures against the default branch on a branch with no PR", function()
    local root, default_base = repo()

    local point = assert(fork_point.get(root, "feature"))

    assert.equal(default_base, point.base)
    assert.equal("main", point.against)
    assert.equal("main", point.default_branch)
    assert.is_nil(point.pr)
  end)

  it("measures against the branch it was created from without waiting on gh", function()
    local root, _, parent_base = repo("parent")

    local point = assert(fork_point.get(root, "feature"))

    assert.equal(parent_base, point.base)
    assert.equal("parent", point.against)
    assert.equal("parent", point.ref)
    assert.is_nil(point.pr)
  end)

  it("keeps the branch it was created from while its fork point is the default branch's", function()
    local root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    table.insert(roots, root)
    fixture.init_repo("main", root)
    local fork = commit_file(root, "main.txt")
    fixture.git({ "checkout", "-q", "-b", "parent" }, root)
    fixture.git({ "checkout", "-q", "-b", "feature", "parent" }, root)
    commit_file(root, "feature.txt")

    local point = assert(fork_point.get(root, "feature"))

    assert.equal(fork, point.base)
    assert.equal("parent", point.against)
  end)

  it("moves to the default branch once the branch is rebased onto it past a squash-merged parent", function()
    local root = repo("parent")
    fixture.git({ "checkout", "-q", "main" }, root)
    fixture.git({ "merge", "-q", "--squash", "parent" }, root)
    local squashed = fixture.commit("squash parent", root)
    fixture.git({ "rebase", "-q", "--onto", "main", "parent", "feature" }, root)

    local point = assert(fork_point.get(root, "feature"))

    assert.equal(squashed, point.base)
    assert.equal("main", point.against)
  end)

  it("keeps the PR whose target is the branch it was created from", function()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent", number = 7 })
    local root, _, parent_base = repo("parent")

    fork_point.get(root, "feature")
    assert.is_true(await_heard(root, 1))
    local point = heard_in(root)[1].point

    assert.equal(parent_base, point.base)
    assert.equal(7, point.pr)
  end)

  it("stays on the branch it was created from, without the PR, when the PR targets another", function()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "main", number = 7 })
    local root, _, parent_base = repo("parent")

    fork_point.get(root, "feature")
    assert.is_true(await_heard(root, 1))
    local point = heard_in(root)[1].point
    local again = fork_point.get(root, "feature")

    for _, p in ipairs({ point, again }) do
      assert.equal(parent_base, p.base)
      assert.equal("parent", p.against)
      assert.is_nil(p.pr)
    end
  end)

  it("keeps the PR into the default branch once the parent is merged into it", function()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "main", number = 7 })
    local root = repo("parent")
    fixture.git({ "checkout", "-q", "main" }, root)
    fixture.git({ "merge", "-q", "--no-ff", "-m", "merge parent", "parent" }, root)
    fixture.git({ "checkout", "-q", "feature" }, root)

    fork_point.get(root, "feature")
    assert.is_true(await_heard(root, 1))

    assert.equal(7, heard_in(root)[1].point.pr)
  end)

  it("keeps the PR into the default branch when the parent has no commits of its own", function()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "main", number = 7 })
    local root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    table.insert(roots, root)
    fixture.init_repo("main", root)
    commit_file(root, "main.txt")
    fixture.git({ "checkout", "-q", "-b", "parent" }, root)
    fixture.git({ "checkout", "-q", "-b", "feature", "parent" }, root)
    commit_file(root, "feature.txt")

    fork_point.get(root, "feature")
    assert.is_true(await_heard(root, 1))

    assert.equal(7, heard_in(root)[1].point.pr)
  end)

  it("moves a branch created from the default branch to its PR's target", function()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent", number = 7 })
    local root = repo("main")

    fork_point.get(root, "feature")
    assert.is_true(await_heard(root, 1))
    local point = heard_in(root)[1].point

    assert.equal("parent", point.against)
    assert.equal(7, point.pr)
  end)

  it("moves to the PR's target once gh answers, and keeps that answer", function()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent", number = 7 })
    local root, default_base, parent_base = repo()

    local first, asking = fork_point.get(root, "feature")
    assert(first)
    assert.equal(default_base, first.base)
    assert.is_true(asking)

    assert.is_true(await_heard(root, 1))
    local point = heard_in(root)[1].point
    assert.equal(parent_base, point.base)
    assert.equal("parent", point.against)
    assert.equal(7, point.pr)

    local again, still_asking = fork_point.get(root, "feature")
    assert.same(point, again)
    assert.is_false(still_asking)
  end)

  it("stays on the default base when the PR's target shares no fork point", function()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "gone", number = 7 })
    local root, default_base = repo()

    fork_point.get(root, "feature")
    assert.is_true(await_heard(root, 1))
    local point = heard_in(root)[1].point
    local again = fork_point.get(root, "feature")

    for _, p in ipairs({ point, again }) do
      assert.equal(default_base, p.base)
      assert.equal("gone", p.skipped)
    end
  end)

  it("stays on the default base for a PR that is not open", function()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent", number = 7, state = "MERGED" })
    local root, default_base = repo()

    fork_point.get(root, "feature")
    assert.is_true(await_heard(root, 1))

    assert.equal(default_base, heard_in(root)[1].point.base)
    assert.is_nil(heard_in(root)[1].point.pr)
  end)

  it("answers the default base when gh is not installed", function()
    local root, default_base = repo()

    gh.without(fork_point.get, root, "feature")

    assert.is_true(await_heard(root, 1))
    assert.equal(default_base, heard_in(root)[1].point.base)
  end)

  it("asks gh once while an answer is in flight, and again after an answer of no PR", function()
    vim.env.FAKE_GH_DELAY = "0.2"
    local root = repo()

    fork_point.get(root, "feature")
    fork_point.get(root, "feature")
    assert.equal(1, asks)

    assert.is_true(await_heard(root, 1))
    fork_point.get(root, "feature")
    assert.equal(2, asks)
  end)

  it("keeps separate answers for two repositories on the same branch", function()
    vim.env.FAKE_GH_PR = gh.pr_view({ baseRefName = "parent", number = 7 })
    local stacked, _, parent_base = repo()
    fork_point.get(stacked, "feature")
    assert.is_true(await_heard(stacked, 1))
    vim.env.FAKE_GH_PR = nil
    local plain, default_base = repo()

    local point, asking = fork_point.get(plain, "feature")
    assert(point)

    assert.equal(default_base, point.base)
    assert.is_true(asking)
    assert.equal(parent_base, fork_point.get(stacked, "feature").base)
  end)

  it("returns nil outside a repository and asks gh nothing", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    table.insert(roots, dir)

    assert.is_nil(fork_point.get(dir, "feature"))
    assert.equal(0, asks)
  end)
end)
