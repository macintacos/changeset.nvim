local tree, on_tree, asks

package.loaded["changeset.build"] = {
  current = function()
    return tree
  end,
  subscribe = function(fn)
    on_tree = fn
  end,
}
package.loaded["changeset.pending_review"] = {
  find = function(root, cb)
    table.insert(asks, { root = root, cb = cb })
  end,
}

local pending_state = require("changeset.pending_state")

---A find answer for PR `number`, with a review of id `review` when given.
---@param number integer
---@param review string?
local function answer(number, review)
  return { pr = { id = "PR_" .. number, number = number }, review = review and { id = review, comments = {} } or nil }
end

local roots = 0

describe("pending_state", function()
  local root
  local notified = 0
  pending_state.subscribe(function()
    notified = notified + 1
  end)

  before_each(function()
    roots = roots + 1
    root = "/repo" .. roots
    tree = { root = root, branch = "a", pr = 1 }
    asks = {}
    notified = 0
  end)

  it("knows nothing before GitHub answers", function()
    assert.is_nil(pending_state.get(root, 1))
  end)

  it("keeps an answer with a review for the tree's PR", function()
    pending_state.fetch(root)
    local found = answer(1, "R1")
    asks[1].cb(nil, found)
    assert.are.equal(found, pending_state.get(root, 1))
    assert.are.equal(1, notified)
  end)

  it("keeps an answer without a review for the tree's PR", function()
    pending_state.fetch(root)
    local found = answer(1)
    asks[1].cb(nil, found)
    assert.are.equal(found, pending_state.get(root, 1))
    assert.are.equal(1, notified)
  end)

  it("keeps the last answer when an ask fails", function()
    pending_state.fetch(root)
    local found = answer(1, "R1")
    asks[1].cb(nil, found)
    pending_state.fetch(root)
    asks[2].cb("boom")
    assert.are.equal(found, pending_state.get(root, 1))
    assert.are.equal(2, notified)
  end)

  it("counts GitHub refusing the tree's PR as an answer", function()
    pending_state.fetch(root)
    assert.is_false(pending_state.answered(root, 1))
    asks[1].cb("boom")
    assert.is_true(pending_state.answered(root, 1))
    assert.are.equal(1, notified)
  end)

  it("drops an answer for a PR the tree has left", function()
    pending_state.fetch(root)
    tree = { root = root, branch = "b", pr = 2 }
    asks[1].cb(nil, answer(1))
    assert.is_nil(pending_state.get(root, 1))
    assert.are.equal(0, notified)
  end)

  it("drops an answer for a repository the tree has left", function()
    pending_state.fetch(root)
    tree = { root = root .. "-other", branch = "a", pr = 1 }
    asks[1].cb(nil, answer(1))
    assert.is_nil(pending_state.get(root, 1))
    assert.are.equal(0, notified)
  end)

  it("drops an answer when there is no tree", function()
    pending_state.fetch(root)
    tree = nil
    asks[1].cb(nil, answer(1))
    assert.is_nil(pending_state.get(root, 1))
    assert.are.equal(0, notified)
  end)

  it("keeps only the latest ask's answer", function()
    pending_state.fetch(root)
    pending_state.fetch(root)
    local latest = answer(1, "R2")
    asks[2].cb(nil, latest)
    asks[1].cb(nil, answer(1, "R1"))
    assert.are.equal(latest, pending_state.get(root, 1))
  end)

  it("keeps an answer while another repository's ask is in flight", function()
    pending_state.fetch(root)
    pending_state.fetch(root .. "-other")
    local found = answer(1)
    asks[1].cb(nil, found)
    assert.are.equal(found, pending_state.get(root, 1))
  end)

  it("hands fetch's callback the answer even when it is dropped", function()
    local got
    pending_state.fetch(root, function(err, found)
      got = { err = err, found = found }
    end)
    tree = nil
    local found = answer(1)
    asks[1].cb(nil, found)
    assert.are.same({ found = found }, got)
  end)

  describe("asks GitHub", function()
    it("once for a tree on a new branch, and not again on its rebuilds", function()
      on_tree()
      on_tree()
      assert.are.equal(1, #asks)
      assert.are.equal(root, asks[1].root)
    end)

    it("again when the tree's PR changes", function()
      on_tree()
      tree = { root = root, branch = "a", pr = 3 }
      on_tree()
      assert.are.equal(2, #asks)
    end)

    it("never for a tree with no PR", function()
      tree.pr = nil
      on_tree()
      assert.are.equal(0, #asks)
    end)

    it("again on coming back to a branch", function()
      on_tree()
      tree = { root = root, branch = "b", pr = 2 }
      on_tree()
      tree = { root = root, branch = "a", pr = 1 }
      on_tree()
      assert.are.equal(3, #asks)
    end)

    it("when Neovim regains focus", function()
      vim.api.nvim_exec_autocmds("FocusGained", {})
      assert.are.equal(1, #asks)
      assert.are.equal(root, asks[1].root)
    end)

    it("never on focus without a PR", function()
      tree.pr = nil
      vim.api.nvim_exec_autocmds("FocusGained", {})
      tree = nil
      vim.api.nvim_exec_autocmds("FocusGained", {})
      assert.are.equal(0, #asks)
    end)
  end)
end)
