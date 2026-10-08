local comment_store = require("changeset.comment_store")
local jsonfile = require("changeset.jsonfile")

local ROOT = "/repo"

---@param fields table?
local function comment(fields)
  return vim.tbl_extend("force", { path = "lua/a.lua", line = 7, start_line = 5, body = "hi" }, fields or {})
end

---Takes `comments` as a batch submitted to claude at `at`, 0 when nil.
---@param root string
---@param comments table[]
---@param at integer?
local function take(root, comments, at)
  return comment_store.take(root, { comments = comments, at = at or 0, to = "claude" })
end

---Restores batch `n` as `submitted` lists it for `root`, or a batch it never kept when there is none.
---@param root string
---@param n integer
local function restore(root, n)
  return comment_store.restore(root, (comment_store.submitted(root) or {})[n] or { comments = {} })
end

describe("changeset.comment_store", function()
  before_each(function()
    os.remove(comment_store.path())
  end)

  it("lists what it wrote though the file's stat can't tell it from the last write", function()
    comment_store.keep(ROOT, comment({ body = "one" }))
    comment_store.list(ROOT)
    -- As on a filesystem whose timestamps are coarser than two quick writes, and which reuses the freed inode.
    local real, stat = vim.uv.fs_stat, vim.uv.fs_stat(comment_store.path())
    vim.uv.fs_stat = function(path)
      return path == comment_store.path() and stat or real(path)
    end
    local ok, err = pcall(comment_store.keep, ROOT, comment({ line = 9, start_line = 8, body = "two" }))
    local listed = comment_store.list(ROOT)
    vim.uv.fs_stat = real
    assert(ok, err)

    assert.same(
      { "one", "two" },
      vim.tbl_map(function(c)
        return c.body
      end, listed)
    )
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

  it("lists a comment on a whole file, which names no line", function()
    comment_store.keep(ROOT, { path = "lua/a.lua", body = "hi" })

    assert.same({ { path = "lua/a.lua", body = "hi" } }, comment_store.list(ROOT))
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

  it("reports whether drop took a comment out", function()
    comment_store.keep(ROOT, comment())

    assert.same({ true, true }, { comment_store.drop(ROOT, comment()) })
    assert.same({ true, false }, { comment_store.drop(ROOT, comment()) })
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

  ---Writes `text` as the record, as a hand edit would.
  local function write_record(text)
    vim.fn.mkdir(vim.fs.dirname(comment_store.path()), "p")
    vim.fn.writefile({ text }, comment_store.path())
  end

  for _, junk in ipairs({ "[1,2]", '{"/repo":[1,}', '"text"' }) do
    it("lists nothing from a record holding " .. junk .. ", and refuses to write over it", function()
      write_record(junk)

      assert.same({}, comment_store.list(ROOT))
      assert.is_false(comment_store.keep(ROOT, comment()))
      assert.is_false(comment_store.drop_all(ROOT))
      assert.is_nil(restore(ROOT, 1))
      assert.same({ junk }, vim.fn.readfile(comment_store.path()))
    end)
  end

  it("refuses to write over a record it can't open", function()
    comment_store.keep(ROOT, comment())
    local before = vim.fn.readfile(comment_store.path())
    vim.fn.setfperm(comment_store.path(), "---------")

    local written = comment_store.keep(ROOT, comment({ line = 9, start_line = nil }))
    vim.fn.setfperm(comment_store.path(), "rw-r--r--")

    assert.is_false(written)
    assert.same(before, vim.fn.readfile(comment_store.path()))
  end)

  for _, entry in ipairs({
    '{"path":"a","body":"b","start_line":1}',
    '{"path":"a","body":"b","line":3,"start_line":"1"}',
    '{"path":"a","body":"b","line":0}',
    '{"path":"a","body":"b","line":3,"start_line":3}',
  }) do
    it("skips the entry " .. entry .. " in a list, and keeps it through a write", function()
      write_record('{"/repo":[' .. entry .. "]}")

      assert.same({}, comment_store.list(ROOT))
      assert.is_true(comment_store.keep(ROOT, comment()))
      assert.same({ comment() }, comment_store.list(ROOT))
      assert.same(vim.json.decode(entry), jsonfile.read(comment_store.path())[ROOT][1])
    end)
  end

  it("lists a comment a hand edit marked draft false as saved", function()
    write_record('{"/repo":[{"path":"lua/a.lua","line":7,"start_line":5,"body":"hi","draft":false}]}')

    assert.same({ comment() }, comment_store.list(ROOT))
  end)

  it("moves a comment a hand edit marked draft false", function()
    write_record('{"/repo":[{"path":"lua/a.lua","line":7,"start_line":5,"body":"hi","draft":false}]}')

    comment_store.move(ROOT, { { from = comment(), to = comment({ line = 9, start_line = 7 }) } })

    assert.same({ comment({ line = 9, start_line = 7 }) }, comment_store.list(ROOT))
  end)

  it("lists a draft as one", function()
    comment_store.keep(ROOT, comment({ draft = true }))

    assert.same({ comment({ draft = true }) }, comment_store.list(ROOT))
  end)

  it("replaces a draft with the comment saved on its range", function()
    comment_store.keep(ROOT, comment({ draft = true }))
    comment_store.keep(ROOT, comment({ body = "saved" }))

    assert.same({ comment({ body = "saved" }) }, comment_store.list(ROOT))
  end)

  it("reads a null start_line as a single-line comment", function()
    write_record('{"/repo":[{"path":"a","body":"b","line":3,"start_line":null}]}')

    assert.same({ { path = "a", body = "b", line = 3 } }, comment_store.list(ROOT))
  end)

  it("takes out exactly the comments it is given in one write, leaving one edited since", function()
    comment_store.keep(ROOT, comment())
    comment_store.keep(ROOT, comment({ line = 9, start_line = nil }))
    comment_store.keep(ROOT, comment({ line = 12, start_line = nil, body = "edited" }))
    local writes = 0
    comment_store.subscribe(function()
      writes = writes + 1
    end)

    local written =
      take(ROOT, { comment(), comment({ line = 9, start_line = nil }), comment({ line = 12, start_line = nil }) })

    assert.is_true(written)
    assert.equal(1, writes)
    assert.same({ comment({ line = 12, start_line = nil, body = "edited" }) }, comment_store.list(ROOT))
  end)

  describe("reading again", function()
    ---How often the record is decoded while `fn` runs.
    ---@param fn fun()
    ---@return integer
    local function decodes(fn)
      local real, count = vim.json.decode, 0
      vim.json.decode = function(...)
        count = count + 1
        return real(...)
      end
      local ok, err = pcall(fn)
      vim.json.decode = real
      assert(ok, err)
      return count
    end

    it("decodes the record once for reads it was not written between", function()
      comment_store.keep(ROOT, comment())
      take(ROOT, { comment({ line = 9, start_line = 9 }) })

      assert.equal(
        1,
        decodes(function()
          comment_store.list(ROOT)
          comment_store.comments(ROOT)
          comment_store.submitted(ROOT)
        end)
      )
    end)

    it("reads a record written behind its back", function()
      comment_store.keep(ROOT, comment())
      comment_store.list(ROOT)
      local data = assert(jsonfile.read_object(comment_store.path()))
      data[ROOT][1].body = "changed"

      jsonfile.write(comment_store.path(), data)

      assert.same({ comment({ body = "changed" }) }, comment_store.list(ROOT))
    end)

    it("hands out comments whose changes the next read does not see", function()
      take(ROOT, { comment() })
      local batch = assert(comment_store.submitted(ROOT))[1]

      batch.comments[1].body = "changed"

      assert.same({ comment() }, assert(comment_store.submitted(ROOT))[1].comments)
      assert.same({ comment() }, select(2, comment_store.comments(ROOT))[1].comments)
    end)
  end)

  describe("submitted", function()
    local one, two = { path = "lua/a.lua", line = 3, body = "one" }, comment({ body = "two" })

    it("lists every batch taken, newest first, with when and to whom", function()
      comment_store.keep(ROOT, one)
      take(ROOT, { one }, 10)
      comment_store.keep(ROOT, two)
      take(ROOT, { two }, 20)

      assert.same({
        { comments = { two }, at = 20, to = "claude" },
        { comments = { one }, at = 10, to = "claude" },
      }, comment_store.submitted(ROOT))
    end)

    it("keeps the last 10 batches, forgetting older ones", function()
      for at = 1, 11 do
        local each = comment({ line = 10 + at, start_line = nil })
        comment_store.keep(ROOT, each)
        take(ROOT, { each }, at)
      end

      local batches = assert(comment_store.submitted(ROOT))

      assert.equal(10, #batches)
      assert.same({ 11, 2 }, { batches[1].at, batches[10].at })
    end)

    it("lists the one batch a store kept before it kept several, with no time or agent, and keeps it", function()
      vim.fn.mkdir(vim.fs.dirname(comment_store.path()), "p")
      jsonfile.write(comment_store.path(), { submitted = { [ROOT] = { [""] = { one } } } })

      assert.same({ { comments = { one } } }, comment_store.submitted(ROOT))
      take(ROOT, { two }, 20)
      assert.same({
        { comments = { two }, at = 20, to = "claude" },
        { comments = { one } },
      }, comment_store.submitted(ROOT))
    end)

    it("skips a malformed batch, and keeps it through a write", function()
      take(ROOT, { one }, 10)
      local data = jsonfile.read(comment_store.path())
      table.insert(data.submitted[ROOT][""], 1, { comments = "x" })
      jsonfile.write(comment_store.path(), data)

      assert.same({ { comments = { one }, at = 10, to = "claude" } }, comment_store.submitted(ROOT))
      take(ROOT, { two }, 20)
      assert.same({ comments = "x" }, jsonfile.read(comment_store.path()).submitted[ROOT][""][2])
    end)

    it("reads a list of comments as the one batch a store kept before, whatever its first entry", function()
      vim.fn.mkdir(vim.fs.dirname(comment_store.path()), "p")
      jsonfile.write(comment_store.path(), { submitted = { [ROOT] = { [""] = { { path = 1 }, one } } } })

      assert.same({ { comments = { one } } }, comment_store.submitted(ROOT))
    end)

    it("lists nothing from an unreadable record", function()
      vim.fn.mkdir(vim.fs.dirname(comment_store.path()), "p")
      vim.fn.writefile({ "[1,2]" }, comment_store.path())

      assert.is_nil(comment_store.submitted(ROOT))
    end)
  end)

  describe("restore", function()
    local one, two = { path = "lua/a.lua", line = 3, body = "one" }, comment({ body = "two" })

    it("brings back the batch it is given as saved comments, once", function()
      comment_store.keep(ROOT, one)
      comment_store.keep(ROOT, two)
      take(ROOT, { one, two })

      assert.same({ 2, 0 }, { restore(ROOT, 1) })
      assert.same({ one, two }, comment_store.list(ROOT))
      assert.same({ 0, 0 }, { restore(ROOT, 1) })
      assert.same({ one, two }, comment_store.list(ROOT))
    end)

    it("brings back the batch it is given though another was submitted since it was listed", function()
      comment_store.keep(ROOT, one)
      take(ROOT, { one }, 10)
      local listed = assert(comment_store.submitted(ROOT))[1]
      comment_store.keep(ROOT, two)
      take(ROOT, { two }, 20)

      assert.same({ 1, 0 }, { comment_store.restore(ROOT, listed) })
      assert.same({ one }, comment_store.list(ROOT))
    end)

    it("brings back the batch it is given though a write moved its comments since it was listed", function()
      comment_store.keep(ROOT, one)
      take(ROOT, { one }, 10)
      local listed = assert(comment_store.submitted(ROOT))[1]
      local moved = vim.tbl_extend("force", one, { line = 4 })
      comment_store.move(ROOT, { { from = one, to = moved } })

      assert.same({ 1, 0 }, { comment_store.restore(ROOT, listed) })
      assert.same({ moved }, comment_store.list(ROOT))
    end)

    it("brings back nothing for a batch no longer submitted", function()
      comment_store.keep(ROOT, one)
      take(ROOT, { one }, 10)
      local listed = assert(comment_store.submitted(ROOT))[1]
      restore(ROOT, 1)
      comment_store.drop(ROOT, one)

      assert.same({ 0, 0 }, { comment_store.restore(ROOT, listed) })
      assert.same({}, comment_store.list(ROOT))
    end)

    it("brings back an older batch, leaving the others", function()
      comment_store.keep(ROOT, one)
      take(ROOT, { one }, 10)
      comment_store.keep(ROOT, two)
      take(ROOT, { two }, 20)

      assert.same({ 1, 0 }, { restore(ROOT, 2) })

      assert.same({ one }, comment_store.list(ROOT))
      assert.same({ { comments = { two }, at = 20, to = "claude" } }, comment_store.submitted(ROOT))
    end)

    it("keeps a comment on a range holding a newer one in its batch, for a later restore", function()
      local since = comment({ body = "since", draft = true })
      comment_store.keep(ROOT, one)
      comment_store.keep(ROOT, two)
      take(ROOT, { one, two }, 10)
      comment_store.keep(ROOT, since)

      assert.same({ 1, 1 }, { restore(ROOT, 1) })
      assert.same({ since, one }, comment_store.list(ROOT))
      assert.same({ { comments = { two }, at = 10, to = "claude" } }, comment_store.submitted(ROOT))
      comment_store.drop(ROOT, since)
      assert.same({ 1, 0 }, { restore(ROOT, 1) })
      assert.same({ one, two }, comment_store.list(ROOT))
    end)

    it("counts a malformed comment in the batch as neither restored nor kept", function()
      comment_store.keep(ROOT, one)
      take(ROOT, { one })
      local data = jsonfile.read(comment_store.path())
      table.insert(data.submitted[ROOT][""][1].comments, { path = 1 })
      jsonfile.write(comment_store.path(), data)

      assert.same({ 1, 0 }, { restore(ROOT, 1) })
    end)

    it("brings back the batch taken after every listed comment is dropped", function()
      comment_store.keep(ROOT, one)
      take(ROOT, { one })
      comment_store.keep(ROOT, two)

      comment_store.drop_all(ROOT)

      assert.same({ 1, 0 }, { restore(ROOT, 1) })
      assert.same({ one }, comment_store.list(ROOT))
    end)

    it("brings back another repository's comments only there", function()
      comment_store.keep(ROOT, one)
      take(ROOT, { one })

      assert.same({ 0, 0 }, { restore("/other", 1) })
      assert.same({ 1, 0 }, { restore(ROOT, 1) })
    end)
  end)

  it("lists the comments and the submitted batches in one read", function()
    comment_store.keep(ROOT, comment({ body = "sent" }))
    take(ROOT, { comment({ body = "sent" }) }, 10)
    comment_store.keep(ROOT, comment({ body = "listed" }))

    local listed, batches = comment_store.comments(ROOT)

    assert.same({ comment({ body = "listed" }) }, listed)
    assert.same({ { comments = { comment({ body = "sent" }) }, at = 10, to = "claude" } }, batches)
  end)

  describe("move", function()
    it("moves the comments of every batch submitted as it moves the listed ones", function()
      local sent, listed = comment({ body = "sent" }), comment({ line = 12, start_line = nil, body = "listed" })
      comment_store.keep(ROOT, sent)
      take(ROOT, { sent }, 10)
      comment_store.keep(ROOT, listed)

      comment_store.move(ROOT, {
        { from = sent, to = comment({ line = 9, start_line = 7, body = "sent" }) },
        { from = listed, to = comment({ line = 14, start_line = nil, body = "listed" }) },
      })

      assert.same({ comment({ line = 14, start_line = nil, body = "listed" }) }, comment_store.list(ROOT))
      assert.same(
        { { comments = { comment({ line = 9, start_line = 7, body = "sent" }) }, at = 10, to = "claude" } },
        comment_store.submitted(ROOT)
      )
    end)
  end)

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

describe("changeset.comment_store across branches", function()
  local Fixture = require("support.git")
  local root, worktree

  ---@param ... string
  local function git(...)
    Fixture.git({ ... }, root)
  end

  ---Writes `entries` as the repository's record, as a store from before branches were recorded left it.
  local function write_entries(entries)
    jsonfile.write(comment_store.path(), { [root] = entries })
  end

  before_each(function()
    os.remove(comment_store.path())
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    root = vim.fs.normalize(assert(vim.uv.fs_realpath(root)))
    Fixture.init_repo("main", root)
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
    if worktree then
      vim.fn.delete(worktree, "rf")
      worktree = nil
    end
    os.remove(comment_store.path())
  end)

  it("lists only the comments written on the branch checked out", function()
    comment_store.keep(root, comment({ body = "on main" }))
    git("switch", "-q", "-c", "other")

    assert.same({}, comment_store.list(root))
    comment_store.keep(root, comment({ line = 9, body = "on other" }))
    assert.same({ comment({ line = 9, body = "on other" }) }, comment_store.list(root))

    git("switch", "-q", "main")
    assert.same({ comment({ body = "on main" }) }, comment_store.list(root))
  end)

  it("lists a comment stored without a branch on every branch", function()
    write_entries({ comment() })

    assert.same({ comment() }, comment_store.list(root))
    git("switch", "-q", "-c", "other")
    assert.same({ comment() }, comment_store.list(root))
  end)

  it("keeps another branch's comment on the range a comment is kept on", function()
    comment_store.keep(root, comment({ body = "on main" }))
    git("switch", "-q", "-c", "other")
    comment_store.keep(root, comment({ body = "on other" }))
    comment_store.drop(root, comment())

    git("switch", "-q", "main")
    assert.same({ comment({ body = "on main" }) }, comment_store.list(root))
  end)

  it("drops the branch's comments and those stored without one when all are dropped", function()
    write_entries({ comment({ body = "before branches" }) })
    comment_store.keep(root, comment({ line = 9, body = "on main" }))
    git("switch", "-q", "-c", "other")
    comment_store.keep(root, comment({ line = 12, body = "on other" }))

    comment_store.drop_all(root)

    assert.same({}, comment_store.list(root))
    git("switch", "-q", "main")
    assert.same({ comment({ line = 9, body = "on main" }) }, comment_store.list(root))
  end)

  it("takes each given comment of the branch only", function()
    comment_store.keep(root, comment())
    git("switch", "-q", "-c", "other")
    comment_store.keep(root, comment())

    take(root, { comment() })

    git("switch", "-q", "main")
    assert.same({ comment() }, comment_store.list(root))
  end)

  it("restores the comments taken on the branch checked out", function()
    comment_store.keep(root, comment())
    take(root, { comment() })
    git("switch", "-q", "-c", "other")

    assert.same({ 0, 0 }, { restore(root, 1) })
    git("switch", "-q", "main")
    assert.same({ 1, 0 }, { restore(root, 1) })
    assert.same({ comment() }, comment_store.list(root))
  end)

  it("lists a worktree's comments by the branch checked out there", function()
    worktree = vim.fn.tempname()
    git("worktree", "add", "-q", worktree, "-b", "feature")
    worktree = vim.fs.normalize(assert(vim.uv.fs_realpath(worktree)))
    comment_store.keep(worktree, comment())

    Fixture.git({ "switch", "-q", "-c", "other" }, worktree)

    assert.same({}, comment_store.list(worktree))
  end)

  it("keeps a detached HEAD's comments to its commit", function()
    comment_store.keep(root, comment({ body = "on main" }))
    git("switch", "-q", "--detach")

    assert.same({}, comment_store.list(root))
    comment_store.keep(root, comment({ line = 9, body = "detached" }))
    git("switch", "-q", "main")
    assert.same({ comment({ body = "on main" }) }, comment_store.list(root))
    git("switch", "-q", "--detach")
    assert.same({ comment({ line = 9, body = "detached" }) }, comment_store.list(root))
  end)

  it("files a reftable repository's comments under no branch, whose HEAD file names none", function()
    git("refs", "migrate", "--ref-format=reftable")
    comment_store.keep(root, comment())

    git("refs", "migrate", "--ref-format=files")
    git("switch", "-q", "-c", "other")

    assert.same({ comment() }, comment_store.list(root))
  end)

  it("lists the comments of the branch a stopped rebase rewrites", function()
    vim.fn.writefile({ "x" }, root .. "/f")
    Fixture.commit("f", root)
    comment_store.keep(root, comment())

    vim.fn.system({ "git", "-C", root, "rebase", "--exec", "false", "HEAD~1" })

    assert.truthy(vim.uv.fs_stat(root .. "/.git/rebase-merge"))
    assert.same({ comment() }, comment_store.list(root))
  end)
end)

describe("changeset.comment_store relocating", function()
  local relocate = comment_store._relocate

  ---@param line integer
  ---@param fields table?
  local function at(line, fields)
    return vim.tbl_extend("force", { path = "a.lua", line = line, body = "b" .. line }, fields or {})
  end

  ---@param from table
  ---@param line integer
  local function move(from, line)
    return { from = from, to = vim.tbl_extend("force", from, { line = line }) }
  end

  it("puts an entry equal to a move's from on its to's lines, filing one without a branch under the branch", function()
    local list, merged = relocate({ at(5), at(9, { branch = "main" }) }, { move(at(5), 6) }, "main")

    assert.same({ at(6, { body = "b5", branch = "main" }), at(9, { branch = "main" }) }, list)
    assert.same({}, merged)
  end)

  it("moves an entry only while its body and draft are those the move was made from", function()
    local entries = { at(5, { body = "edited", branch = "main" }), at(7, { draft = true, branch = "main" }) }

    local list = relocate(entries, { move(at(5), 6), move(at(7), 8) }, "main")

    assert.same(entries, list)
  end)

  it("merges entries brought onto one range into the first listed, a draft when either was, and answers it", function()
    local entries = { at(5, { branch = "main" }), at(6, { draft = true, branch = "main" }) }

    local list, merged = relocate(entries, { move(at(6, { draft = true }), 5) }, "main")

    local into = at(5, { body = "b5\n\nb6", draft = true, branch = "main" })
    assert.same({ into }, list)
    assert.same({ { comment = into, count = 2 } }, merged)
  end)

  it("leaves another branch's entries and malformed ones where they are, merging none of them", function()
    local entries = { at(5, { branch = "other" }), "junk", at(6, { branch = "main" }) }

    local list, merged = relocate(entries, { move(at(6), 5) }, "main")

    assert.same({ at(5, { branch = "other" }), "junk", at(5, { body = "b6", branch = "main" }) }, list)
    assert.same({}, merged)
  end)

  it("changes none of the entries it is given", function()
    local entries = { at(5, { branch = "main" }), at(6, { branch = "main" }) }

    relocate(entries, { move(at(6), 5) }, "main")

    assert.same({ at(5, { branch = "main" }), at(6, { branch = "main" }) }, entries)
  end)
end)
