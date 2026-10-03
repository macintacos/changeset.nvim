local commentable = require("changeset.commentable")

-- Sandbox pull request 1's hunks, reduced to the `-U0` form `diff.lua` parses.
---@type changeset.Hunk[]
local ALPHA = {
  { lnum = 10, count = 1, added = 1, removed = 1, old_lnum = 10 },
  { lnum = 31, count = 2, added = 2, removed = 0, old_lnum = 30 },
}
---@type changeset.Hunk[]
local BETA = {
  { lnum = 3, count = 1, added = 1, removed = 1, old_lnum = 3 },
  { lnum = 16, count = 1, added = 1, removed = 0, old_lnum = 15 },
}
-- Sandbox pull request 2's pure deletion, `+31,0`.
---@type changeset.Hunk[]
local PR2 = {
  { lnum = 31, count = 0, added = 0, removed = 1, old_lnum = 30 },
}

---@param hunks changeset.Hunk[]
---@param range { [1]: integer, [2]: integer }
local function accepts(hunks, range)
  assert.is_nil(commentable.refusal(hunks, range, true))
end

---@param hunks changeset.Hunk[]
---@param range { [1]: integer, [2]: integer }
---@param pattern string
local function refuses(hunks, range, pattern)
  assert.matches(pattern, commentable.refusal(hunks, range, true))
end

describe("changeset.commentable.refusal", function()
  it("accepts an added line", function()
    accepts(ALPHA, { 31, 31 })
  end)

  it("accepts the first context line of a hunk", function()
    accepts(ALPHA, { 7, 7 })
  end)

  it("refuses the line before a hunk's context", function()
    refuses(ALPHA, { 6, 6 }, "line 6")
  end)

  it("accepts the last context line of a hunk", function()
    accepts(ALPHA, { 13, 13 })
  end)

  it("refuses the first line past a hunk's context", function()
    refuses(ALPHA, { 14, 14 }, "line 14")
  end)

  it("accepts a range over changed and context lines in one hunk", function()
    accepts(ALPHA, { 8, 10 })
  end)

  it("accepts a range over two hunks", function()
    accepts(ALPHA, { 10, 31 })
  end)

  it("refuses a range from outside a hunk into a changed line", function()
    refuses(ALPHA, { 4, 10 }, "line 4")
  end)

  it("refuses a range from a changed line out of its hunk", function()
    refuses(ALPHA, { 10, 20 }, "line 20")
  end)

  it("refuses a line deep outside any hunk", function()
    refuses(ALPHA, { 20, 20 }, "line 20")
  end)

  it("accepts an added line in a second file", function()
    accepts(BETA, { 16, 16 })
  end)

  it("accepts the first line a pure deletion predicts", function()
    accepts(PR2, { 29, 29 })
  end)

  it("accepts the last line a pure deletion predicts", function()
    accepts(PR2, { 34, 34 })
  end)

  it("refuses the line before a pure deletion's lines", function()
    refuses(PR2, { 28, 28 }, "line 28")
  end)

  it("refuses the line after a pure deletion's lines", function()
    refuses(PR2, { 35, 35 }, "line 35")
  end)

  it("refuses a line inside a hunk when the file differs from the PR's head", function()
    local refusal = commentable.refusal(ALPHA, { 31, 31 }, false)
    assert.matches("save", refusal)
    assert.matches("push", refusal)
    assert.matches("pull", refusal)
  end)

  it("refuses a line outside every hunk as stale when the file differs from the PR's head", function()
    local refusal = commentable.refusal(ALPHA, { 14, 14 }, false)
    assert.matches("save", refusal)
    assert.matches("push", refusal)
    assert.matches("pull", refusal)
  end)
end)
