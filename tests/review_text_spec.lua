local review_text = require("changeset.review_text")

describe("changeset.review_text", function()
  it("writes one block per comment by path, then line, at its backticked absolute path and lines", function()
    local text = review_text.text("/repo", {
      { path = "b.lua", line = 2, body = "second" },
      { path = "a.lua", line = 9, body = "later" },
      { path = "a.lua", line = 4, start_line = 3, body = "first\n\n" },
    })

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
    })

    assert.truthy(text:find("^`/repo/a.lua:L2%-L4`"))
  end)

  it("writes a whole file's comment as its bare absolute path, ahead of its lines' comments", function()
    local text = review_text.text("/repo", {
      { path = "a.lua", line = 2, body = "a line" },
      { path = "a.lua", body = "the file" },
    })

    assert.equal("`/repo/a.lua`\nFeedback: the file\n\n`/repo/a.lua:L2`\nFeedback: a line", text)
  end)

  it("prefixes only a multi-line body's first line with Feedback:", function()
    assert.equal(
      "`/repo/a.lua:L1`\nFeedback: one\ntwo",
      review_text.text("/repo", { { path = "a.lua", line = 1, body = "one\ntwo" } })
    )
  end)
end)
