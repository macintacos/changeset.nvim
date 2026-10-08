local review_text = require("changeset.review_text")

describe("changeset.review_text", function()
  ---@param path string
  ---@param first integer
  ---@param last integer
  local function read(path, first, last)
    if path == "gone.lua" then
      return nil
    end
    local out = {}
    for n = first, last do
      out[#out + 1] = path .. " " .. n
    end
    return out
  end

  it("writes one block per comment by path, then line, at its absolute path, its lines fenced", function()
    local text = review_text.text("/repo", {
      { path = "b.lua", line = 2, body = "second" },
      { path = "a.lua", line = 9, body = "later" },
      { path = "a.lua", line = 4, start_line = 3, body = "first\n\n" },
    }, read)

    assert.equal(
      table.concat({
        "/repo/a.lua:3-4",
        "```lua",
        "a.lua 3",
        "a.lua 4",
        "```",
        "first",
        "",
        "/repo/a.lua:9",
        "```lua",
        "a.lua 9",
        "```",
        "later",
        "",
        "/repo/b.lua:2",
        "```lua",
        "b.lua 2",
        "```",
        "second",
      }, "\n"),
      text
    )
  end)

  it("writes a range ahead of a line inside it", function()
    local text = review_text.text("/repo", {
      { path = "a.lua", line = 3, body = "line" },
      { path = "a.lua", line = 4, start_line = 2, body = "range" },
    }, read)

    assert.truthy(text:find("^/repo/a.lua:2%-4"))
  end)

  it("fences lines holding a fence with one more backtick than their longest run", function()
    local text = review_text.text("/repo", { { path = "a.md", line = 2, start_line = 1, body = "b" } }, function()
      return { "````lua", "x" }
    end)

    assert.equal("/repo/a.md:1-2\n`````markdown\n````lua\nx\n`````\nb", text)
  end)

  it("leaves the fence's language empty for a file type it can't tell", function()
    local text = review_text.text("/repo", { { path = "notes.zzqq", line = 1, body = "b" } }, read)

    assert.equal("/repo/notes.zzqq:1\n```\nnotes.zzqq 1\n```\nb", text)
  end)

  it("writes a whole file's comment as its absolute path and its text, ahead of its lines' comments", function()
    local text = review_text.text("/repo", {
      { path = "a.lua", line = 2, body = "a line" },
      { path = "a.lua", body = "the file" },
    }, read)

    assert.equal("/repo/a.lua\nthe file\n\n/repo/a.lua:2\n```lua\na.lua 2\n```\na line", text)
  end)

  it("writes no fence when the lines can't be read", function()
    assert.equal(
      "/repo/gone.lua:5\nwhy",
      review_text.text("/repo", { { path = "gone.lua", line = 5, body = "why" } }, read)
    )
  end)
end)
