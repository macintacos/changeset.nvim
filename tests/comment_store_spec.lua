local comment_store = require("changeset.comment_store")
local jsonfile = require("changeset.jsonfile")

local ROOT = "/repo"

---@param fields table?
local function comment(fields)
  return vim.tbl_extend("force", { path = "lua/a.lua", line = 7, start_line = 5, body = "hi" }, fields or {})
end

describe("changeset.comment_store", function()
  before_each(function()
    os.remove(comment_store.path())
  end)

  it("lists a kept comment for its repository", function()
    comment_store.keep(ROOT, comment())

    assert.same({ comment() }, comment_store.list(ROOT))
  end)

  it("lists nothing for another repository", function()
    comment_store.keep(ROOT, comment())

    assert.same({}, comment_store.list("/other"))
  end)

  it("replaces a comment kept again on the same path and range", function()
    comment_store.keep(ROOT, comment())
    comment_store.keep(ROOT, comment({ body = "again" }))

    assert.same({ comment({ body = "again" }) }, comment_store.list(ROOT))
  end)

  it("keeps a comment on another range of the same file beside it", function()
    comment_store.keep(ROOT, comment())
    comment_store.keep(ROOT, comment({ start_line = 6 }))

    assert.equal(2, #comment_store.list(ROOT))
  end)

  it("drops the comment at its range when kept with a blank body", function()
    comment_store.keep(ROOT, comment())
    comment_store.keep(ROOT, comment({ body = " \n " }))

    assert.same({}, comment_store.list(ROOT))
  end)

  it("writes nothing for a blank body with no comment to drop", function()
    assert.is_true(comment_store.keep(ROOT, comment({ body = "" })))

    assert.is_nil(io.open(comment_store.path(), "r"))
  end)

  it("drops only the matching comment", function()
    comment_store.keep(ROOT, comment())
    comment_store.keep(ROOT, comment({ line = 9, start_line = nil }))

    comment_store.drop(ROOT, comment())

    assert.same({ comment({ line = 9, start_line = nil }) }, comment_store.list(ROOT))
  end)

  it("drops every comment of a repository and leaves other repositories'", function()
    comment_store.keep(ROOT, comment())
    comment_store.keep("/other", comment())

    comment_store.drop_all(ROOT)

    assert.same({}, comment_store.list(ROOT))
    assert.same({ comment() }, comment_store.list("/other"))
    assert.is_nil(jsonfile.read(comment_store.path())[ROOT])
  end)

  it("keeps what another Neovim wrote between two saves", function()
    comment_store.keep(ROOT, comment())
    local data = jsonfile.read(comment_store.path())
    data["/other"] = { comment({ body = "elsewhere" }) }
    jsonfile.write(comment_store.path(), data)

    comment_store.keep(ROOT, comment({ line = 9, start_line = nil }))

    assert.same({ comment({ body = "elsewhere" }) }, comment_store.list("/other"))
    assert.equal(2, #comment_store.list(ROOT))
  end)

  it("lists a kept comment after a restart", function()
    comment_store.keep(ROOT, comment())

    package.loaded["changeset.comment_store"] = nil

    assert.same({ comment() }, require("changeset.comment_store").list(ROOT))
  end)

  local function record_with_comment(fields)
    return '{"/repo":[{"path":"a","body":"b",' .. fields .. "}]}"
  end
  for _, junk in ipairs({
    "[1,2]",
    '{"/repo":"y"}',
    '{"/repo":[{"path":"a","body":"b"}]}',
    record_with_comment('"line":3,"start_line":"1"'),
    record_with_comment('"line":0'),
    record_with_comment('"line":3,"start_line":3'),
    record_with_comment('"line":3,"start_line":4'),
  }) do
    it("lists nothing from a file holding " .. junk .. ", and keeps afterwards", function()
      vim.fn.mkdir(vim.fs.dirname(comment_store.path()), "p")
      vim.fn.writefile({ junk }, comment_store.path())

      assert.same({}, comment_store.list(ROOT))
      assert.is_true(comment_store.keep(ROOT, comment()))
      assert.same({ comment() }, comment_store.list(ROOT))
    end)
  end

  it("runs a subscriber once per write", function()
    local calls = 0
    comment_store.subscribe(function()
      calls = calls + 1
    end)

    comment_store.keep(ROOT, comment())
    comment_store.drop(ROOT, comment())

    assert.equal(2, calls)
  end)

  it("reports a comment that did not reach the disk", function()
    comment_store.keep(ROOT, comment())
    local dir = vim.fs.dirname(comment_store.path())
    vim.fn.setfperm(dir, "r-xr-xr-x")

    local written = comment_store.keep(ROOT, comment({ body = "lost" }))
    vim.fn.setfperm(dir, "rwxr-xr-x")

    assert.is_false(written)
  end)
end)
