local buffers = require("plugins.changeset.buffers")

describe("changeset.buffers", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  describe("load", function()
    it("loads a file's contents without listing its buffer", function()
      local path = tmp .. "/a.lua"
      vim.fn.writefile({ "local x = 1", "return x" }, path)

      local buf = buffers.load(path)

      assert.is_not_nil(buf)
      assert.is_true(vim.api.nvim_buf_is_loaded(buf))
      assert.is_false(vim.bo[buf].buflisted)
      assert.same({ "local x = 1", "return x" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("leaves a buffer the user already has open in their buffer list", function()
      local path = tmp .. "/open.lua"
      vim.fn.writefile({ "local x = 1" }, path)
      vim.cmd.edit(path)
      local open = vim.api.nvim_get_current_buf()

      assert.equal(open, buffers.load(path))
      assert.is_true(vim.bo[open].buflisted)
    end)

    -- The sidebar previews from a `CursorMoved` callback, and autocommands do
    -- not nest: the read `bufload` performs there skips the `BufRead` chain
    -- that would otherwise name the filetype.
    it("detects the filetype even when called from inside an autocommand", function()
      local path = tmp .. "/a.lua"
      vim.fn.writefile({ "local x = 1" }, path)
      local buf

      vim.api.nvim_create_autocmd("User", {
        pattern = "ChangesetBuffersSpec",
        once = true,
        callback = function()
          buf = buffers.load(path)
        end,
      })
      vim.api.nvim_exec_autocmds("User", { pattern = "ChangesetBuffersSpec" })

      assert.equal("lua", vim.bo[buf].filetype)
    end)

    it("leaves a file no rule matches without one", function()
      local path = tmp .. "/notes.wwwww"
      vim.fn.writefile({ "hello" }, path)

      assert.equal("", vim.bo[buffers.load(path)].filetype)
    end)

    it("reports nothing for a path that is not a readable file", function()
      assert.is_nil(buffers.load(tmp .. "/missing.lua"))
      assert.is_nil(buffers.load(tmp))
    end)
  end)
end)
