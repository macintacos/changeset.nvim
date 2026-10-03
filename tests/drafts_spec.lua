local drafts = require("changeset.drafts")
local jsonfile = require("changeset.jsonfile")

local PR = { host = "github.com", owner = "acme", name = "widgets", number = 412, head = "aaa", target = "main" }

---@param fields table?
local function pr(fields)
  return vim.tbl_extend("force", PR, fields or {})
end

---@param fields table?
local function draft(fields)
  return vim.tbl_extend(
    "force",
    { path = "lua/a.lua", line = 7, start_line = 5, head = "aaa", body = "hi" },
    fields or {}
  )
end

describe("changeset.drafts", function()
  before_each(function()
    os.remove(drafts.path())
  end)

  it("lists a kept draft for its PR at its head", function()
    drafts.keep(PR, draft())

    assert.same({ draft() }, drafts.list(PR))
  end)

  it("lists nothing for another head of the same PR", function()
    drafts.keep(PR, draft())

    assert.same({}, drafts.list(pr({ head = "bbb" })))
  end)

  it("lists nothing for another PR", function()
    drafts.keep(PR, draft())

    assert.same({}, drafts.list(pr({ number = 413 })))
    assert.same({}, drafts.list(pr({ owner = "fork" })))
  end)

  it("replaces a draft kept again at the same path, range and head", function()
    drafts.keep(PR, draft())
    drafts.keep(PR, draft({ body = "again" }))

    assert.same({ draft({ body = "again" }) }, drafts.list(PR))
  end)

  it("drops the draft at its key when kept with a blank body", function()
    drafts.keep(PR, draft())
    drafts.keep(PR, draft({ body = " \n " }))

    assert.same({}, drafts.list(PR))
  end)

  it("writes nothing for a blank body with no draft to drop", function()
    assert.is_false(drafts.keep(PR, draft({ body = "" })))

    assert.is_nil(io.open(drafts.path(), "r"))
  end)

  it("drops only the matching draft", function()
    drafts.keep(PR, draft())
    drafts.keep(PR, draft({ line = 9, start_line = nil }))

    drafts.drop(PR, draft())

    assert.same({ draft({ line = 9, start_line = nil }) }, drafts.list(PR))
  end)

  it("drops every head's drafts of a PR and leaves other PRs'", function()
    local other = pr({ number = 413 })
    drafts.keep(PR, draft())
    drafts.keep(pr({ head = "bbb" }), draft({ head = "bbb" }))
    drafts.keep(other, draft())

    drafts.drop_all(PR)

    assert.same({}, drafts.list(PR))
    assert.same({}, drafts.list(pr({ head = "bbb" })))
    assert.same({ draft() }, drafts.list(other))
  end)

  it("keeps what another Neovim wrote between two saves", function()
    drafts.keep(PR, draft())
    local data = jsonfile.read(drafts.path())
    data["github.com/acme/other#1"] = { draft({ body = "elsewhere" }) }
    jsonfile.write(drafts.path(), data)

    drafts.keep(PR, draft({ line = 9, start_line = nil }))

    assert.same({ draft({ body = "elsewhere" }) }, jsonfile.read(drafts.path())["github.com/acme/other#1"])
    assert.equal(2, #drafts.list(PR))
  end)

  it("lists a kept draft after a restart", function()
    drafts.keep(PR, draft())

    package.loaded["changeset.drafts"] = nil

    assert.same({ draft() }, require("changeset.drafts").list(PR))
  end)

  for _, junk in ipairs({ "[1,2]", '{"x":"y"}', '{"github.com/acme/widgets#412":[{"path":"a","line":1,"body":"b"}]}' }) do
    it("lists nothing from a file holding " .. junk .. ", and keeps afterwards", function()
      vim.fn.mkdir(vim.fs.dirname(drafts.path()), "p")
      vim.fn.writefile({ junk }, drafts.path())

      assert.same({}, drafts.list(PR))
      assert.is_true(drafts.keep(PR, draft()))
      assert.same({ draft() }, drafts.list(PR))
    end)
  end

  it("runs a subscriber once per write", function()
    local calls = 0
    drafts.subscribe(function()
      calls = calls + 1
    end)

    drafts.keep(PR, draft())
    drafts.drop(PR, draft())

    assert.equal(2, calls)
  end)

  it("reports a draft that did not reach the disk", function()
    drafts.keep(PR, draft())
    local dir = vim.fs.dirname(drafts.path())
    vim.fn.setfperm(dir, "r-xr-xr-x")

    local written = drafts.keep(PR, draft({ body = "lost" }))
    vim.fn.setfperm(dir, "rwxr-xr-x")

    assert.is_false(written)
  end)
end)
