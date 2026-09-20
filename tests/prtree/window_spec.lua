local window = require("plugins.prtree.window")

---A `usable` predicate that accepts only the listed windows.
---@param ok integer[]
---@return fun(win: integer): boolean
local function only(ok)
  return function(win)
    return vim.tbl_contains(ok, win)
  end
end

describe("prtree.window", function()
  describe("_clamp", function()
    it("keeps a line that is already inside the buffer", function()
      assert.equal(12, window._clamp(12, 40))
    end)

    it("pulls a line past the end back to the last one", function()
      assert.equal(40, window._clamp(88, 40))
    end)

    it("never lands on line zero when the buffer reports no lines", function()
      assert.equal(1, window._clamp(1, 0))
    end)

    it("never lands on line zero for a deletion hunk reported at the top of a file", function()
      assert.equal(1, window._clamp(0, 40))
    end)
  end)

  describe("_pick_target", function()
    it("keeps previewing into the window pinned at open", function()
      assert.equal(7, window._pick_target(7, { 3, 7 }, only({ 3, 7 })))
    end)

    it("falls back to the most recent usable window once the pinned one is gone", function()
      assert.equal(3, window._pick_target(7, { 3, 9 }, only({ 3, 9 })))
    end)

    it("skips candidates holding a special buffer", function()
      assert.equal(9, window._pick_target(7, { 3, 9 }, only({ 9 })))
    end)

    it("asks for a new split when no window can hold a preview", function()
      assert.is_nil(window._pick_target(7, { 3, 9 }, only({})))
    end)
  end)
end)
