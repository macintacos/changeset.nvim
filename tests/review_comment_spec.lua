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
end)
