local review_text = require("changeset.review_text")

describe("changeset.review_text", function()
  local UNFRAMED = { header = "", footer = "" }
  local ONE_COMMENT = { { path = "a.lua", line = 1, body = "b" } }
  local BLOCK = "`/repo/a.lua:L1`\nFeedback: b"

  it("writes one block per comment by path, then line, at its backticked absolute path and lines", function()
    local text = review_text.text("/repo", {
      { path = "b.lua", line = 2, body = "second" },
      { path = "a.lua", line = 9, body = "later" },
      { path = "a.lua", line = 4, start_line = 3, body = "first\n\n" },
    }, UNFRAMED)

    assert.equal(
      table.concat({
        "`/repo/a.lua:L3-L4`",
        "Feedback: first",
        "",
        "`/repo/a.lua:L9`",
        "Feedback: later",
        "",
        "`/repo/b.lua:L2`",
        "Feedback: second",
      }, "\n"),
      text
    )
  end)

  it("writes a range ahead of a line inside it", function()
    local text = review_text.text("/repo", {
      { path = "a.lua", line = 3, body = "line" },
      { path = "a.lua", line = 4, start_line = 2, body = "range" },
    }, UNFRAMED)

    assert.truthy((text:find("^`/repo/a.lua:L2%-L4`")))
  end)

  it("writes a whole file's comment as its bare absolute path, ahead of its lines' comments", function()
    local text = review_text.text("/repo", {
      { path = "a.lua", line = 2, body = "a line" },
      { path = "a.lua", body = "the file" },
    }, UNFRAMED)

    assert.equal("`/repo/a.lua`\nFeedback: the file\n\n`/repo/a.lua:L2`\nFeedback: a line", text)
  end)

  it("prefixes only a multi-line body's first line with Feedback:", function()
    assert.equal(
      "`/repo/a.lua:L1`\nFeedback: one\ntwo",
      review_text.text("/repo", { { path = "a.lua", line = 1, body = "one\ntwo" } }, UNFRAMED)
    )
  end)

  it("puts a header above the blocks and a footer below, a blank line apart", function()
    assert.equal("H\n\n" .. BLOCK, review_text.text("/repo", ONE_COMMENT, { header = "H", footer = "" }))
    assert.equal(BLOCK .. "\n\nF", review_text.text("/repo", ONE_COMMENT, { header = "", footer = "F" }))
    assert.equal("H\n\n" .. BLOCK .. "\n\nF", review_text.text("/repo", ONE_COMMENT, { header = "H\n", footer = "F" }))
  end)

  it("takes a blank header or footer as unset", function()
    assert.equal(BLOCK, review_text.text("/repo", ONE_COMMENT, { header = " \n ", footer = "\n" }))
  end)
end)
