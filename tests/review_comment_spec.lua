local review_comment = require("changeset.review_comment")

local LINE = { path = "a.lua", line = 4, body = "" }
local RANGE = { path = "a.lua", line = 5, start_line = 3, body = "" }
local FILE = { path = "a.lua", body = "" }

describe("changeset.review_comment", function()
  it("orders comments by path, then first line, then last line, a whole file's first", function()
    local sorted = {
      { path = "b.lua", line = 1, body = "" },
      { path = "a.lua", line = 9, start_line = 2, body = "" },
      { path = "a.lua", line = 4, body = "" },
      { path = "a.lua", body = "" },
      { path = "a.lua", line = 5, start_line = 2, body = "" },
    }
    table.sort(sorted, review_comment.before)

    assert.same({
      { path = "a.lua", body = "" },
      { path = "a.lua", line = 5, start_line = 2, body = "" },
      { path = "a.lua", line = 9, start_line = 2, body = "" },
      { path = "a.lua", line = 4, body = "" },
      { path = "b.lua", line = 1, body = "" },
    }, sorted)
  end)

  describe("same_range", function()
    it("matches a comment on the same path and lines, whatever its body", function()
      assert.is_true(review_comment.same_range(RANGE, { path = "a.lua", line = 5, start_line = 3, body = "x" }))
    end)

    it("tells apart another path, last line or first line", function()
      assert.is_false(review_comment.same_range(RANGE, { path = "b.lua", line = 5, start_line = 3, body = "" }))
      assert.is_false(review_comment.same_range(RANGE, { path = "a.lua", line = 6, start_line = 3, body = "" }))
      assert.is_false(review_comment.same_range(RANGE, { path = "a.lua", line = 5, body = "" }))
    end)
  end)

  describe("at", function()
    it("finds the narrowest comment covering a line", function()
      local wide = { path = "a.lua", line = 9, start_line = 1, body = "" }
      assert.equal(RANGE, review_comment.at({ wide, RANGE }, "a.lua", 4))
    end)

    it("gives a tie to the first listed", function()
      local twin = { path = "a.lua", line = 5, start_line = 3, body = "twin" }
      assert.equal(RANGE, review_comment.at({ RANGE, twin }, "a.lua", 4))
    end)

    it("skips a whole file's comment and another file's", function()
      assert.is_nil(review_comment.at({ FILE, { path = "b.lua", line = 4, body = "" } }, "a.lua", 4))
    end)
  end)

  it("answers a comment's first line, none for a whole file", function()
    assert.equal(4, review_comment.first(LINE))
    assert.equal(3, review_comment.first(RANGE))
    assert.is_nil(review_comment.first(FILE))
  end)

  it("labels a line, a range and a whole file", function()
    assert.equal("line 4", review_comment.lines_label(4, 4))
    assert.equal("lines 3-5", review_comment.lines_label(3, 5))
    assert.equal("whole file", review_comment.lines_label(nil, nil))
  end)

  it("spans a line, a range and none for a whole file", function()
    assert.equal("4", review_comment.span(LINE))
    assert.equal("3-5", review_comment.span(RANGE))
    assert.is_nil(review_comment.span(FILE))
  end)

  it("locates a comment by path and lines", function()
    assert.equal("a.lua:4", review_comment.location(LINE))
    assert.equal("a.lua:3-5", review_comment.location(RANGE))
    assert.equal("a.lua", review_comment.location(FILE))
  end)

  it("places a comment for a sentence", function()
    assert.equal("line 4 of a.lua", review_comment.place(LINE))
    assert.equal("lines 3-5 of a.lua", review_comment.place(RANGE))
    assert.equal("the whole of a.lua", review_comment.place(FILE))
  end)

  describe("moves", function()
    ---Lines "line 1" to "line `n`".
    ---@param n integer
    ---@return string[]
    local function lines(n)
      local out = {}
      for i = 1, n do
        out[i] = "line " .. i
      end
      return out
    end

    ---`list` with `values` put in at `at`, after the line before it.
    local function inserted(list, at, values)
      local out = vim.list_slice(list)
      for i, value in ipairs(values) do
        table.insert(out, at + i - 1, value)
      end
      return out
    end

    ---`list` without lines `first` to `last`.
    local function deleted(list, first, last)
      return vim.list_extend(vim.list_slice(list, 1, first - 1), vim.list_slice(list, last + 1))
    end

    local range = { path = "a.lua", line = 10, start_line = 8, body = "hi" }

    it("keeps a range on its first and last lines as lines are added above, inside and below it", function()
      local after = inserted(lines(20), 11, { "below" })
      after = inserted(after, 10, { "above the last" })
      after = inserted(after, 8, { "above the first" })

      assert.same(
        { { from = range, to = { path = "a.lua", line = 12, start_line = 9, body = "hi" } } },
        review_comment.moves(lines(20), after, { range })
      )
    end)

    it("puts a comment whose lines were all deleted on the line that followed them", function()
      assert.same(
        { { from = range, to = { path = "a.lua", line = 8, body = "hi" } } },
        review_comment.moves(lines(20), deleted(lines(20), 8, 10), { range })
      )
    end)

    it("keeps a range on its first line and the one before its last when the last is deleted", function()
      assert.same(
        { { from = range, to = { path = "a.lua", line = 9, start_line = 8, body = "hi" } } },
        review_comment.moves(lines(20), deleted(lines(20), 10, 10), { range })
      )
    end)

    it("puts a comment on the file's last line on the new last line when that line is deleted", function()
      local last = { path = "a.lua", line = 20, body = "hi" }
      assert.same(
        { { from = last, to = { path = "a.lua", line = 19, body = "hi" } } },
        review_comment.moves(lines(20), deleted(lines(20), 20, 20), { last })
      )
    end)

    it("leaves out a comment the edits didn't move", function()
      assert.same({}, review_comment.moves(lines(20), inserted(lines(20), 15, { "below" }), { range }))
    end)
  end)
  describe("step", function()
    local comments = {
      { path = "a.lua", line = 3, body = "" },
      { path = "a.lua", line = 9, start_line = 7, body = "" },
      { path = "b.lua", line = 50, body = "" },
    }

    ---@param path string?
    ---@param lnum integer
    local function at(path, lnum)
      return { path = path, lnum = lnum, lines = 20 }
    end

    it("finds the next comment after the line, and the one before it backwards", function()
      assert.same({ 2, false }, { review_comment.step(comments, at("a.lua", 3), 1) })
      assert.same({ 1, false }, { review_comment.step(comments, at("a.lua", 7), -1) })
    end)

    it("orders another file by its path", function()
      assert.same({ 3, false }, { review_comment.step(comments, at("a.lua", 8), 1) })
    end)

    it("wraps at either end", function()
      assert.same({ 1, true }, { review_comment.step(comments, at("c.lua", 1), 1) })
      assert.same({ 3, true }, { review_comment.step(comments, at("a.lua", 1), -1) })
    end)

    it("walks a count of comments, wrapping as often as it is longer than the list", function()
      assert.same({ 3, false }, { review_comment.step(comments, at("a.lua", 1), 3) })
      assert.same({ 1, true }, { review_comment.step(comments, at("a.lua", 1), 4) })
      assert.same({ 2, true }, { review_comment.step(comments, at("a.lua", 1), 8) })
    end)

    it("starts from the first or last from no file", function()
      assert.same({ 1, false }, { review_comment.step(comments, at(nil, 1), 1) })
      assert.same({ 3, false }, { review_comment.step(comments, at(nil, 1), -1) })
      assert.same({ 2, false }, { review_comment.step(comments, at(nil, 1), -2) })
    end)

    it("counts a comment past the file's end on its last line", function()
      local short = { { path = "b.lua", line = 50, body = "" } }
      assert.same({ 1, true }, { review_comment.step(short, at("b.lua", 20), 1) })
      assert.same({ 1, false }, { review_comment.step(short, at("b.lua", 19), 1) })
    end)
  end)
end)
