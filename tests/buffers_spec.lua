local buffers = require("changeset.buffers")

describe("changeset.buffers", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  describe("loaded", function()
    after_each(function()
      vim.cmd("silent! %bwipeout!")
    end)

    it("finds the loaded buffer of a file whose name reads as a pattern matching another's", function()
      local loaded = {}
      for _, name in ipairs({ "a1.lua", "a[1].lua" }) do
        local path = vim.fs.normalize(tmp .. "/" .. name)
        vim.fn.writefile({ "x" }, path)
        loaded[name] = assert(buffers.load(path))
      end

      assert.equal(loaded["a[1].lua"], buffers.loaded(vim.api.nvim_buf_get_name(loaded["a[1].lua"])))
    end)

    it("finds nothing for a file with no loaded buffer, though another's name starts with it", function()
      local path = vim.fs.normalize(tmp .. "/a.lua")
      vim.fn.writefile({ "x" }, path .. ".orig")
      assert(buffers.load(path .. ".orig"))

      assert.is_nil(buffers.loaded(path))
    end)
  end)

  describe("index", function()
    after_each(function()
      vim.cmd("silent! %bwipeout!")
    end)

    it("finds the buffer loaded finds", function()
      local path = vim.fs.normalize(tmp .. "/a.lua")
      vim.fn.writefile({ "x" }, path)
      local buf = assert(buffers.load(path))
      local name = vim.api.nvim_buf_get_name(buf)

      assert.equal(buf, buffers.loaded(name))
      assert.equal(buf, buffers.index()[name])
    end)

    it("finds nothing for a file with no loaded buffer", function()
      local path = vim.fs.normalize(tmp .. "/a.lua")
      vim.fn.writefile({ "x" }, path .. ".orig")
      assert(buffers.load(path .. ".orig"))

      assert.is_nil(buffers.index()[path])
    end)

    it("finds the first loaded of two buffers whose names normalise alike", function()
      local path = vim.fs.normalize(tmp .. "/a.lua")
      vim.fn.writefile({ "x" }, path)
      local name = vim.fn.resolve(path)
      local first = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(first, vim.fs.dirname(name) .. "/./a.lua")
      assert(buffers.load(path))

      assert.equal(first, buffers.loaded(name))
      assert.equal(first, buffers.index()[name])
    end)
  end)

  describe("lines", function()
    local path

    before_each(function()
      path = vim.fs.normalize(tmp .. "/a.lua")
      vim.fn.writefile({ "one", "two", "three" }, path)
      -- The name a buffer takes: the temporary directory can sit behind a symlink.
      path = vim.fn.resolve(path)
    end)

    after_each(function()
      vim.cmd("silent! %bwipeout!")
    end)

    it("reads a loaded buffer's unwritten edits over the file on disk", function()
      local buf = assert(buffers.load(path))
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "edited" })

      assert.same({ "edited", "three" }, buffers.lines(path, 2, 3))
    end)

    it("reads a file without a loaded buffer from disk", function()
      assert.same({ "two" }, buffers.lines(path, 2, 2))
    end)

    it("reads the lines there are of a range past the file's end", function()
      assert.same({ "three" }, buffers.lines(path, 3, 5))
    end)

    it("reads to the file's end without a last line", function()
      assert.same({ "two", "three" }, buffers.lines(path, 2))
    end)

    it("reads nothing of a file that is not there", function()
      assert.same({}, buffers.lines(tmp .. "/missing.lua", 1, 2))
    end)

    it("finds the buffer in an index taken before", function()
      local buf = assert(buffers.load(path))
      local index = buffers.index()
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "edited" })

      assert.same({ "edited" }, buffers.lines(path, 1, 1, index))
    end)
  end)

  describe("load", function()
    it("loads a file's contents without listing its buffer", function()
      local path = tmp .. "/a.lua"
      vim.fn.writefile({ "local x = 1", "return x" }, path)

      local buf = assert(buffers.load(path))

      assert.not_nil(buf)
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

    describe("with a review comment kept on the file", function()
      local comment_store = require("changeset.comment_store")
      local Fixture = require("support.git")
      local repo, previous_dir, path

      before_each(function()
        require("changeset.review_comments")
        repo, previous_dir = Fixture.enter_tempdir()
        Fixture.init_repo("trunk", repo)
        path = repo .. "/kept.txt"
        vim.fn.writefile({ "one", "two" }, path)
        os.remove(comment_store.path())
        comment_store.keep(require("changeset.paths").root(0), { path = "kept.txt", line = 2, body = "note" })
      end)

      after_each(function()
        os.remove(comment_store.path())
        vim.cmd("silent! %bwipeout!")
        vim.fn.chdir(previous_dir)
        vim.fn.delete(repo, "rf")
      end)

      ---@param buf integer
      ---@return integer
      local function marks(buf)
        local ns = vim.api.nvim_get_namespaces()["changeset.review_comments"]
        return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
      end

      it("draws the file's review comment marks once as it loads", function()
        local real, reads = comment_store.comments, 0
        comment_store.comments = function(...)
          reads = reads + 1
          return real(...)
        end

        local ok, buf = pcall(buffers.load, path)
        comment_store.comments = real

        assert(ok, buf)
        assert.are.equal(1, reads)
        assert.are.equal(1, marks(assert(buf)))
      end)

      it("draws the file's review comment marks when loaded from inside an autocommand", function()
        local buf
        vim.api.nvim_create_autocmd("User", {
          pattern = "ChangesetSpecLoad",
          once = true,
          callback = function()
            buf = buffers.load(path)
          end,
        })

        vim.api.nvim_exec_autocmds("User", { pattern = "ChangesetSpecLoad" })

        assert.are.equal(1, marks(assert(buf)))
      end)
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
    describe("with swap files on, as they are by default", function()
      local swapdir

      before_each(function()
        swapdir = tmp .. "/swap"
        vim.fn.mkdir(swapdir, "p")
        vim.fn.writefile({ "return 1" }, tmp .. "/mod.lua")
        vim.o.swapfile = true
        vim.o.directory = swapdir .. "//"
      end)

      after_each(function()
        vim.cmd("silent! %bwipeout!")
        vim.o.swapfile = false
      end)

      it("reads a file without leaving a swap file another Neovim would warn about", function()
        buffers.load(tmp .. "/mod.lua")

        assert.same({}, vim.fn.glob(swapdir .. "/*", true, true))
      end)

      it("gives the buffer its swap file once the user enters it", function()
        local buf = assert(buffers.load(tmp .. "/mod.lua"))

        vim.cmd.buffer(buf)

        assert.is_true(vim.bo[buf].swapfile)
        assert.equal(1, #vim.fn.glob(swapdir .. "/*", true, true))
      end)

      it("keeps a swap file off that the user's read autocommands turned off", function()
        vim.fn.writefile({ "secret" }, tmp .. "/notes.gpg")
        local group = vim.api.nvim_create_augroup("buffers_spec_noswap", { clear = true })
        -- As vim-gnupg does for the files it decrypts.
        vim.api.nvim_create_autocmd("BufReadPre", {
          group = group,
          pattern = "*.gpg",
          callback = function()
            vim.opt_local.swapfile = false
          end,
        })
        local buf = assert(buffers.load(tmp .. "/notes.gpg"))

        vim.cmd.buffer(buf)
        vim.api.nvim_del_augroup_by_id(group)

        assert.is_false(vim.bo[buf].swapfile)
        assert.same({}, vim.fn.glob(swapdir .. "/*", true, true))
      end)
    end)
  end)
end)
