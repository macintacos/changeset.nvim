local jsonfile = require("changeset.jsonfile")

describe("changeset.jsonfile", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("reads back what it wrote", function()
    local file = dir .. "/kept.json"

    assert.is_true(jsonfile.write(file, { kinds = { "Class" } }))
    assert.same({ kinds = { "Class" } }, jsonfile.read(file))
  end)

  it("reads an absent file as empty", function()
    assert.same({}, jsonfile.read(dir .. "/never-written.json"))
  end)

  it("reads a truncated file as empty", function()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ '{"kinds": ["Cla' }, dir .. "/torn.json")

    assert.same({}, jsonfile.read(dir .. "/torn.json"))
  end)

  it("reads a file holding a bare JSON null as empty", function()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "null" }, dir .. "/null.json")

    assert.same({}, jsonfile.read(dir .. "/null.json"))
  end)

  it("reports a write it could not make", function()
    vim.fn.mkdir(dir, "p")
    vim.fn.setfperm(dir, "r-xr-xr-x")
    local ok = jsonfile.write(dir .. "/refused.json", { a = 1 })
    vim.fn.setfperm(dir, "rwxr-xr-x")

    assert.is_false(ok)
  end)

  it("leaves the last good file in place when the new one cannot be written", function()
    local file = dir .. "/kept.json"
    jsonfile.write(file, { kinds = { "Class" } })
    vim.fn.setfperm(dir, "r-xr-xr-x")

    jsonfile.write(file, { kinds = { "Field" } })
    vim.fn.setfperm(dir, "rwxr-xr-x")

    assert.same({ kinds = { "Class" } }, jsonfile.read(file))
  end)
end)
