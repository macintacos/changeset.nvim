local Fixture = require("support.git")
local comment_store = require("changeset.comment_store")
require("changeset.review_comments")

describe("review comments in a buffer after a branch switch", function()
  local dir, buf

  ---@return integer[] rows Each mark's first row.
  local function marked_rows()
    local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
    return vim.tbl_map(function(mark)
      return mark[2]
    end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
  end

  ---@return boolean
  local function hover_attached()
    return #vim.lsp.get_clients({ bufnr = buf, name = "changeset" }) > 0
  end

  ---@param ... string
  local function git(...)
    Fixture.git({ ... }, dir)
  end

  before_each(function()
    os.remove(comment_store.path())
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.fs.normalize(assert(vim.uv.fs_realpath(dir)))
    Fixture.init_repo("main", dir)
    vim.fn.writefile(vim.split(("x"):rep(10, "\n"), "\n"), dir .. "/a.lua")
    Fixture.commit("a", dir)
    vim.cmd.edit(dir .. "/a.lua")
    buf = vim.api.nvim_get_current_buf()
    comment_store.keep(dir, { path = "a.lua", line = 4, body = "on main" })
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    for _, client in ipairs(vim.lsp.get_clients({ name = "changeset" })) do
      client:stop(true)
    end
    vim.fn.delete(dir, "rf")
    os.remove(comment_store.path())
  end)

  it("takes the marks and hover of another branch's comments away on regaining focus, and back on returning", function()
    git("switch", "-q", "-c", "other")
    vim.api.nvim_exec_autocmds("FocusGained", {})

    assert.same({}, marked_rows())
    assert.is_false(hover_attached())

    git("switch", "-q", "main")
    vim.api.nvim_exec_autocmds("FocusGained", {})

    assert.same({ 3 }, marked_rows())
    assert.is_true(hover_attached())
  end)

  it("redraws the marks when gitsigns sees HEAD move", function()
    git("switch", "-q", "-c", "other")
    vim.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate" })

    assert.same({}, marked_rows())
  end)
end)
