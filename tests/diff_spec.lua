local diff = require("changeset.diff")
local Fixture = require("support.git")
local present = require("support.present")

-- Real `git diff --numstat -M -z <base>` output. A rename's two paths follow an empty path field;
-- binary files report `-` for both counts.
local NUMSTAT = table.concat({
  "0\t0\t\0docs/guide/intro.md\0docs/tutorial/intro.md\0",
  "4\t0\tfresh.lua\0",
  "0\t6\tlegacy.lua\0",
  "-\t-\tlogo.png\0",
  "1\t1\t\0old_name.lua\0new_name.lua\0",
  "3\t2\tnotes.txt\0",
  "2\t3\tsrc/session.lua\0",
})

-- Real `git diff --name-status -M -z <base>` output for the same change as NUMSTAT.
local NAME_STATUS = table.concat({
  "R100\0docs/guide/intro.md\0docs/tutorial/intro.md\0",
  "A\0fresh.lua\0",
  "D\0legacy.lua\0",
  "M\0logo.png\0",
  "R088\0old_name.lua\0new_name.lua\0",
  "M\0notes.txt\0",
  "M\0src/session.lua\0",
})

describe("changeset.diff._parse_numstat", function()
  local stats ---@type table<string, changeset.diff.Stat>

  before_each(function()
    stats = diff._parse_numstat(NUMSTAT)
  end)

  it("reads added and removed counts per path", function()
    assert.same({ added = 2, removed = 3 }, stats["src/session.lua"])
    assert.same({ added = 4, removed = 0 }, stats["fresh.lua"])
    assert.same({ added = 0, removed = 6 }, stats["legacy.lua"])
  end)

  it("keys a rename by its new path", function()
    assert.same({ added = 1, removed = 1 }, stats["new_name.lua"])
    assert.is_nil(stats["old_name.lua"])
  end)

  it("counts a binary file's `-` placeholders as zero", function()
    assert.same({ added = 0, removed = 0 }, stats["logo.png"])
  end)

  it("returns an empty table for an empty diff", function()
    assert.same({}, diff._parse_numstat(""))
  end)
end)

describe("changeset.diff._parse_name_status", function()
  local statuses ---@type table<string, changeset.diff.Entry>

  before_each(function()
    statuses = diff._parse_name_status(NAME_STATUS)
  end)

  it("maps A, M and D to added, modified and deleted", function()
    assert.same({ status = "added" }, statuses["fresh.lua"])
    assert.same({ status = "modified" }, statuses["src/session.lua"])
    assert.same({ status = "deleted" }, statuses["legacy.lua"])
  end)

  it("keys a rename by its new path and remembers the old one", function()
    assert.same({ status = "renamed", oldpath = "old_name.lua" }, statuses["new_name.lua"])
    assert.is_nil(statuses["old_name.lua"])
  end)

  it("returns an empty table for an empty diff", function()
    assert.same({}, diff._parse_name_status(""))
  end)
end)

-- Real `git diff --unified=0 -M <base>` output for the same change as NUMSTAT.
local HUNKS = vim.split(
  [[
diff --git a/docs/guide/intro.md b/docs/tutorial/intro.md
similarity index 100%
rename from docs/guide/intro.md
rename to docs/tutorial/intro.md
diff --git a/fresh.lua b/fresh.lua
new file mode 100644
index 0000000..31a748f
--- /dev/null
+++ b/fresh.lua
@@ -0,0 +1,4 @@
+fresh 1
+fresh 2
+fresh 3
+fresh 4
diff --git a/legacy.lua b/legacy.lua
deleted file mode 100644
index e73f76f..0000000
--- a/legacy.lua
+++ /dev/null
@@ -1,6 +0,0 @@
-legacy 1
-legacy 2
-legacy 3
-legacy 4
-legacy 5
-legacy 6
diff --git a/logo.png b/logo.png
index b437676..cb657e0 100644
Binary files a/logo.png and b/logo.png differ
diff --git a/lua/a/x.lua b/lua/x.lua
similarity index 100%
rename from lua/a/x.lua
rename to lua/x.lua
diff --git a/old_name.lua b/new_name.lua
similarity index 88%
rename from old_name.lua
rename to new_name.lua
index 776f00f..82aa908 100644
--- a/old_name.lua
+++ b/new_name.lua
@@ -5 +5 @@ rename me 4
-rename me 5
+rename me edited
diff --git a/notes.txt b/notes.txt
index 0beef3f..32fc541 100644
--- a/notes.txt
+++ b/notes.txt
@@ -8,2 +7,0 @@ notes 7
-notes 8
-notes 9
@@ -17,0 +16,3 @@ notes 17
+added one
+added two
+added three
diff --git a/src/session.lua b/src/session.lua
index ac9837c..777b3b3 100644
--- a/src/session.lua
+++ b/src/session.lua
@@ -3 +3 @@ line 2
-line 3
+line three changed
@@ -10 +10 @@ line 9
-line 10
+line ten changed
@@ -25 +24,0 @@ line 24
-line 25
]],
  "\n",
  { trimempty = true }
)

-- git pads the ---/+++ lines with a trailing tab when the path contains a space.
local HUNKS_SPACED_PATH = {
  "diff --git a/my notes.txt b/my notes.txt",
  "index 4cb29ea..ddc897f 100644",
  "--- a/my notes.txt\t",
  "+++ b/my notes.txt\t",
  "@@ -2 +2 @@ one",
  "-two",
  "+TWO",
}

describe("changeset.diff._parse_hunks", function()
  local hunks ---@type table<string, changeset.Hunk[]>

  before_each(function()
    hunks = diff._parse_hunks(HUNKS)
  end)

  it("reads every hunk of a file that has several", function()
    assert.same({
      { lnum = 3, count = 1, added = 1, removed = 1, old_lnum = 3 },
      { lnum = 10, count = 1, added = 1, removed = 1, old_lnum = 10 },
      { lnum = 24, count = 0, added = 0, removed = 1, old_lnum = 25 },
    }, hunks["src/session.lua"])
  end)

  it("records a pure deletion at the line it followed, with a zero count", function()
    assert.same({ lnum = 7, count = 0, added = 0, removed = 2, old_lnum = 8 }, hunks["notes.txt"][1])
  end)

  it("records a pure addition as the new lines it spans", function()
    assert.same({ lnum = 16, count = 3, added = 3, removed = 0, old_lnum = 17 }, hunks["notes.txt"][2])
  end)

  it("spans the whole file for a newly added one", function()
    assert.same({ { lnum = 1, count = 4, added = 4, removed = 0, old_lnum = 0 } }, hunks["fresh.lua"])
  end)

  it("records a deleted file as one pure deletion", function()
    assert.same({ { lnum = 0, count = 0, added = 0, removed = 6, old_lnum = 1 } }, hunks["legacy.lua"])
  end)

  it("keeps the first line the hunk covers on the old side", function()
    local parsed =
      diff._parse_hunks({ "diff --git a/a.lua b/a.lua", "--- a/a.lua", "+++ b/a.lua", "@@ -12,3 +12,2 @@" })

    assert.equal(12, present(parsed["a.lua"][1]).old_lnum)
  end)

  it("attributes a renamed file's hunks to its new path", function()
    assert.same({ { lnum = 5, count = 1, added = 1, removed = 1, old_lnum = 5 } }, hunks["new_name.lua"])
    assert.is_nil(hunks["old_name.lua"])
  end)

  it("keeps the spaces in a path", function()
    local spaced = diff._parse_hunks(HUNKS_SPACED_PATH)
    assert.same({ { lnum = 2, count = 1, added = 1, removed = 1, old_lnum = 2 } }, spaced["my notes.txt"])
  end)

  it("unquotes a path git quoted because it holds a quote character", function()
    local quoted = diff._parse_hunks({
      'diff --git "a/quo\\"te.txt" "b/quo\\"te.txt"',
      '--- "a/quo\\"te.txt"',
      '+++ "b/quo\\"te.txt"',
      "@@ -1 +1 @@",
    })

    assert.same({ { lnum = 1, count = 1, added = 1, removed = 1, old_lnum = 1 } }, quoted['quo"te.txt'])
  end)

  it("keys a path whose directory name ends in ' b'", function()
    local parsed = diff._parse_hunks({
      "diff --git a/my b/f.txt b/my b/f.txt",
      "--- a/my b/f.txt\t",
      "+++ b/my b/f.txt\t",
      "@@ -1 +1 @@",
    })

    assert.same({ "my b/f.txt" }, vim.tbl_keys(parsed))
  end)

  it("keys a rename's hunks by its new path when git quotes only that side", function()
    local parsed = diff._parse_hunks({
      'diff --git a/plain.txt "b/pl\\tain.txt"',
      "--- a/plain.txt",
      '+++ "b/pl\\tain.txt"',
      "@@ -3 +3 @@",
    })

    assert.same({ "pl\tain.txt" }, vim.tbl_keys(parsed))
  end)

  it("reads a removed line that starts with dashes as a line, not a file header", function()
    local parsed = diff._parse_hunks({
      "diff --git a/a.lua b/a.lua",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1 +0,0 @@",
      "--- note",
      "@@ -5 +4 @@",
    })

    assert.equal(2, #parsed["a.lua"])
  end)

  it("drops a hunk header that arrives before any file header", function()
    assert.same({}, diff._parse_hunks({ "@@ -1 +1 @@" }))
  end)

  it("returns an empty table for an empty diff", function()
    assert.same({}, diff._parse_hunks({}))
  end)
end)

describe("changeset.diff._assemble", function()
  ---@type changeset.diff.Parts
  local NO_PARTS = { numstat = {}, statuses = {}, hunks = {}, untracked = {} }

  ---@param overrides table
  local function assemble(overrides)
    local parts = vim.tbl_extend("force", NO_PARTS, overrides)
    ---@cast parts changeset.diff.Parts
    return diff._assemble(parts)
  end

  it("joins a tracked path's status, counts and hunks into one file", function()
    local hunk = { lnum = 5, count = 1, added = 1, removed = 1 }
    local files = assemble({
      numstat = { ["new.lua"] = { added = 1, removed = 1 } },
      statuses = { ["new.lua"] = { status = "renamed", oldpath = "old.lua" } },
      hunks = { ["new.lua"] = { hunk } },
    })

    assert.same({
      { path = "new.lua", oldpath = "old.lua", status = "renamed", added = 1, removed = 1, hunks = { hunk } },
    }, files)
  end)

  it("reports an untracked file as one hunk over all of its lines", function()
    local files = assemble({ untracked = { ["scratch.txt"] = 3 } })

    assert.same({
      {
        path = "scratch.txt",
        status = "untracked",
        added = 3,
        removed = 0,
        hunks = { { lnum = 1, count = 3, added = 3, removed = 0, old_lnum = 0 } },
      },
    }, files)
  end)

  it("gives an empty untracked file no hunk", function()
    local files = assemble({ untracked = { ["empty.txt"] = 0 } })

    assert.same({}, present(files[1]).hunks)
  end)

  it("orders tracked and untracked files together", function()
    local files = assemble({
      statuses = { ["b.lua"] = { status = "modified" }, ["d.lua"] = { status = "added" } },
      untracked = { ["a.txt"] = 1, ["c.txt"] = 1 },
    })

    local paths = vim.tbl_map(function(file)
      return file.path
    end, files)
    assert.same({ "a.txt", "b.lua", "c.txt", "d.lua" }, paths)
  end)

  it("orders files by directory, then filename, a directory's own files first", function()
    local files = assemble({ untracked = { ["a/z.lua"] = 1, ["a/b/c.lua"] = 1, ["a/a.lua"] = 1, ["root.lua"] = 1 } })

    local paths = vim.tbl_map(function(file)
      return file.path
    end, files)
    assert.same({ "root.lua", "a/a.lua", "a/z.lua", "a/b/c.lua" }, paths)
  end)

  it("zero-fills a tracked path the other git calls did not report", function()
    local files = assemble({ statuses = { ["edited-mid-run.lua"] = { status = "modified" } } })

    assert.same({
      { path = "edited-mid-run.lua", status = "modified", added = 0, removed = 0, hunks = {} },
    }, files)
  end)

  it("returns an empty list when nothing changed", function()
    assert.same({}, assemble({}))
  end)
end)

describe("changeset.diff._parse_check_attr", function()
  it("marks paths whose attribute is any value but unset, false or unspecified", function()
    assert.same(
      { a = true, b = true, f = true },
      diff._parse_check_attr(
        "a\0linguist-generated\0set\0b\0linguist-generated\0true\0f\0linguist-generated\0yes\0"
          .. "c\0linguist-generated\0unset\0d\0linguist-generated\0false\0"
          .. "e\0linguist-generated\0unspecified\0"
      )
    )
  end)

  it("marks nothing for empty output", function()
    assert.same({}, diff._parse_check_attr(""))
  end)
end)

describe("changeset.diff._generated_header", function()
  ---@param text string
  ---@return boolean
  local function is_generated(text)
    return diff._generated_header(vim.gsplit(text, "\n", { plain = true }))
  end

  it("reads a Code generated line before the package clause", function()
    assert.is_true(is_generated("// Code generated by protoc-gen-go. DO NOT EDIT.\n\npackage api"))
  end)

  it("reads the marker after a license comment block", function()
    assert.is_true(
      is_generated("// Copyright 2026\n// Licensed MIT\n\n// Code generated by x. DO NOT EDIT.\npackage api")
    )
  end)

  it("ignores the marker after the package clause", function()
    assert.is_false(is_generated("package api\n// Code generated by x. DO NOT EDIT."))
  end)

  it("reads a CRLF marker line", function()
    assert.is_true(is_generated("// Code generated by x. DO NOT EDIT.\r\n\r\npackage api\r"))
  end)

  it("requires the final period", function()
    assert.is_false(is_generated("// Code generated by x. DO NOT EDIT\npackage api"))
  end)

  it("is false without a header", function()
    assert.is_false(is_generated("package api\n\nfunc F() {}"))
  end)
end)

---@type string[]
local TWELVE_LINES =
  { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve" }

---Run `diff.collect` and block until its callback fires, returning what it passed.
---@param base string
---@param cwd string
---@return changeset.File[]? files
---@return string? err
---@return integer? commits
local function await_collect(base, cwd)
  local files, err, commits, done
  diff.collect(base, cwd, function(...)
    files, err, commits = ...
    done = true
  end)
  assert.is_true(
    vim.wait(10000, function()
      return done
    end, 10),
    "collect never called back"
  )
  return files, err, commits
end

---Run `diff.collect` and block until its callback fires, failing on timeout or git error.
---@param base string
---@param cwd string
---@return changeset.File[]
local function collect(base, cwd)
  local files, err = await_collect(base, cwd)
  return present(files, err)
end

---The sorted paths `diff.collect` marks generated.
---@param base string
---@param cwd string
---@return string[]
local function generated(base, cwd)
  local marked = {}
  for _, file in ipairs(collect(base, cwd)) do
    if file.section == "generated" then
      table.insert(marked, file.path)
    end
  end
  table.sort(marked)
  return marked
end

describe("changeset.diff.collect", function()
  local tmp ---@type string

  -- Deliberately never entered: Neovim stays in the real repository, so a
  -- `collect` that ignored its `cwd` argument would measure this checkout and
  -- every assertion below would fail.
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  ---@param name string Relative to the fixture repo.
  ---@param lines string[]
  local function write(name, lines)
    vim.fn.writefile(lines, vim.fs.joinpath(tmp, name))
  end

  it("keeps two edits three lines apart in separate hunks", function()
    Fixture.init_repo("trunk", tmp)
    write("notes.txt", TWELVE_LINES)
    local base = Fixture.commit("seed", tmp)
    local edited = vim.list_slice(TWELVE_LINES)
    edited[4], edited[8] = "FOUR", "EIGHT"
    write("notes.txt", edited)

    assert.same({
      {
        path = "notes.txt",
        status = "modified",
        section = "implementation",
        added = 2,
        removed = 2,
        hunks = {
          { lnum = 4, count = 1, added = 1, removed = 1, old_lnum = 4 },
          { lnum = 8, count = 1, added = 1, removed = 1, old_lnum = 8 },
        },
      },
    }, collect(base, tmp))
  end)

  it("keeps two edits three lines apart in separate hunks under a wider diff.interHunkContext", function()
    Fixture.init_repo("trunk", tmp)
    Fixture.git({ "config", "diff.interHunkContext", "5" }, tmp)
    write("notes.txt", TWELVE_LINES)
    local base = Fixture.commit("seed", tmp)
    local edited = vim.list_slice(TWELVE_LINES)
    edited[4], edited[8] = "FOUR", "EIGHT"
    write("notes.txt", edited)

    assert.same({
      { lnum = 4, count = 1, added = 1, removed = 1, old_lnum = 4 },
      { lnum = 8, count = 1, added = 1, removed = 1, old_lnum = 8 },
    }, present(collect(base, tmp)[1]).hunks)
  end)

  ---Seed a one-file repo and edit it, returning the base commit.
  ---@param cwd string
  ---@return string
  local function seed_edited_file(cwd)
    Fixture.init_repo("trunk", cwd)
    write("notes.txt", TWELVE_LINES)
    local base = Fixture.commit("seed", cwd)
    local edited = vim.list_slice(TWELVE_LINES)
    edited[4] = "FOUR"
    write("notes.txt", edited)
    return base
  end

  it("reads hunks when the user config reshapes the diff header", function()
    local base = seed_edited_file(tmp)
    -- Each of these rewrites the `diff --git a/x b/x` line `_parse_hunks` keys
    -- on, and a developer can have any of them in ~/.gitconfig.
    Fixture.git({ "config", "diff.noprefix", "true" }, tmp)
    Fixture.git({ "config", "diff.mnemonicPrefix", "true" }, tmp)
    Fixture.git({ "config", "color.diff", "always" }, tmp)

    assert.same({ { lnum = 4, count = 1, added = 1, removed = 1, old_lnum = 4 } }, present(collect(base, tmp)[1]).hunks)
  end)

  it("reads hunks when the user config installs an external diff driver", function()
    local base = seed_edited_file(tmp)
    -- An external driver replaces git's own diff output wholesale, so the
    -- parser sees no hunk headers at all.
    Fixture.git({ "config", "diff.external", "true" }, tmp)

    assert.same({ { lnum = 4, count = 1, added = 1, removed = 1, old_lnum = 4 } }, present(collect(base, tmp)[1]).hunks)
  end)

  it("reads every file whose path git would quote or split at ' b/'", function()
    Fixture.init_repo("trunk", tmp)
    vim.fn.mkdir(vim.fs.joinpath(tmp, "my b"))
    for _, name in ipairs({ 'q"uote.txt', "plain.txt", "my b/f.txt" }) do
      write(name, TWELVE_LINES)
    end
    local base = Fixture.commit("seed", tmp)
    local edited = vim.list_slice(TWELVE_LINES)
    edited[4] = "FOUR"
    Fixture.git({ "mv", 'q"uote.txt', 'renamed"q.txt' }, tmp)
    Fixture.git({ "mv", "plain.txt", "pl\tain.txt" }, tmp)
    for _, name in ipairs({ 'renamed"q.txt', "pl\tain.txt", "my b/f.txt" }) do
      write(name, edited)
    end
    write('un"tracked.txt', { "new" })

    local hunk = { { lnum = 4, count = 1, added = 1, removed = 1, old_lnum = 4 } }
    local by_path = {}
    for _, file in ipairs(collect(base, tmp)) do
      by_path[file.path] = { status = file.status, oldpath = file.oldpath, added = file.added, hunks = file.hunks }
    end
    assert.same({
      ["my b/f.txt"] = { status = "modified", added = 1, hunks = hunk },
      ["pl\tain.txt"] = { status = "renamed", oldpath = "plain.txt", added = 1, hunks = hunk },
      ['renamed"q.txt'] = { status = "renamed", oldpath = 'q"uote.txt', added = 1, hunks = hunk },
      ['un"tracked.txt'] = {
        status = "untracked",
        added = 1,
        hunks = { { lnum = 1, count = 1, added = 1, removed = 0, old_lnum = 0 } },
      },
    }, by_path)
  end)

  it("keeps a non-ASCII path as a real filename", function()
    local base = Fixture.init_repo("trunk", tmp)
    write("é.txt", { "a", "b" })

    assert.equal("é.txt", present(collect(base, tmp)[1]).path)
  end)

  it("reports git's stderr when the base is not a commit", function()
    Fixture.init_repo("trunk", tmp)
    local files, err, done
    diff.collect("no-such-ref", tmp, function(result, message)
      files, err, done = result, message, true
    end)
    assert.is_true(
      vim.wait(10000, function()
        return done
      end, 10),
      "collect never called back"
    )

    assert.is_nil(files)
    assert.truthy(err and #err > 0)
  end)

  it("counts the commits made since the base", function()
    local base = Fixture.init_repo("trunk", tmp)
    write("a.txt", { "a" })
    Fixture.commit("one", tmp)
    write("b.txt", { "b" })
    Fixture.commit("two", tmp)
    local commits, done
    diff.collect(base, tmp, function(_, _, count)
      commits, done = count, true
    end)
    assert.is_true(
      vim.wait(10000, function()
        return done
      end, 10),
      "collect never called back"
    )

    assert.equal(2, commits)
  end)

  it("reports a staged rename as one renamed file", function()
    Fixture.init_repo("trunk", tmp)
    -- git enables rename detection by default, so without this the argv flag is
    -- not what makes the rename show up and the test proves nothing.
    Fixture.git({ "config", "diff.renames", "false" }, tmp)
    write("old.txt", { "keep me" })
    local base = Fixture.commit("seed", tmp)
    Fixture.git({ "mv", "old.txt", "new.txt" }, tmp)

    assert.same({
      {
        path = "new.txt",
        oldpath = "old.txt",
        status = "renamed",
        section = "implementation",
        added = 0,
        removed = 0,
        hunks = {},
      },
    }, collect(base, tmp))
  end)

  it("leaves gitignored paths out of the untracked files", function()
    Fixture.init_repo("trunk", tmp)
    write(".gitignore", { "build/" })
    local base = Fixture.commit("seed", tmp)
    vim.fn.mkdir(vim.fs.joinpath(tmp, "build"), "p")
    write("build/artifact.o", { "binary" })
    write("scratch.txt", { "a", "b", "c" })

    assert.same({
      {
        path = "scratch.txt",
        status = "untracked",
        section = "implementation",
        added = 3,
        removed = 0,
        hunks = { { lnum = 1, count = 3, added = 3, removed = 0, old_lnum = 0 } },
      },
    }, collect(base, tmp))
  end)

  it("counts only the untracked paths it can read", function()
    local base = Fixture.init_repo("trunk", tmp)
    write("scratch.txt", { "a", "b", "c" })
    -- A nested repo arrives from `ls-files` as the directory itself, and a
    -- dangling symlink as a path nothing can read.
    Fixture.git({ "init", "-q", "nested" }, tmp)
    write("nested/file.txt", { "inner" })
    assert.is_truthy(vim.uv.fs_symlink("missing", vim.fs.joinpath(tmp, "dangling")))

    local files = collect(base, tmp)

    assert.same(
      { "scratch.txt" },
      vim.tbl_map(function(file)
        return file.path
      end, files)
    )
    assert.equal(3, present(files[1]).added)
  end)

  it("marks the files a linguist-generated attribute covers, deleted ones included", function()
    Fixture.init_repo("trunk", tmp)
    write(".gitattributes", { "gen/** linguist-generated" })
    vim.fn.mkdir(vim.fs.joinpath(tmp, "gen"), "p")
    write("gen/old.ts", { "old" })
    local base = Fixture.commit("seed", tmp)
    write("gen/new.ts", { "new" })
    write("plain.ts", { "plain" })
    vim.fn.delete(vim.fs.joinpath(tmp, "gen/old.ts"))

    assert.same({ "gen/new.ts", "gen/old.ts" }, generated(base, tmp))
  end)

  it("marks a Go file whose generated header comes before its package clause", function()
    Fixture.init_repo("trunk", tmp)
    local go_header = { "// Code generated by x. DO NOT EDIT.", "package api" }
    write("old.go", go_header)
    local base = Fixture.commit("seed", tmp)
    write("api.pb.go", go_header)
    write("late.go", { "package api", "// Code generated by x. DO NOT EDIT." })
    write("plain.go", { "package api" })
    vim.fn.delete(vim.fs.joinpath(tmp, "old.go"))

    assert.same({ "api.pb.go" }, generated(base, tmp))
  end)

  it("files a lockfile under Generated by its name", function()
    Fixture.init_repo("trunk", tmp)
    write("README.md", { "seed" })
    local base = Fixture.commit("seed", tmp)
    write("go.sum", { "sum" })
    write("api.go", { "package api" })

    local section = {}
    for _, file in ipairs(collect(base, tmp)) do
      section[file.path] = file.section
    end
    assert.same({ ["go.sum"] = "generated", ["api.go"] = "implementation" }, section)
  end)

  it("calls back when the repository vanishes before the generated-file read", function()
    local base = seed_edited_file(tmp)
    local system = vim.system
    local check_attr_ran = false
    vim.system = function(argv, ...)
      if vim.tbl_contains(argv, "check-attr") then
        check_attr_ran = true
        vim.fn.delete(tmp, "rf")
      end
      return system(argv, ...)
    end
    local files ---@type changeset.File[]?
    local err
    local ok, raised = pcall(function()
      files, err = await_collect(base, tmp)
    end)
    vim.system = system
    ---@cast raised string?
    assert.is_true(ok, raised)
    assert.is_true(check_attr_ran)
    assert.is_nil(err)
    local first = present(present(files)[1])
    assert.equal("notes.txt", first.path)
    assert.equal(require("changeset.sections").classify("notes.txt"), first.section)
  end)

  it("reports a missing repository as an error", function()
    assert.matches("ENOENT", present((select(2, await_collect("HEAD", tmp .. "/gone")))))
  end)
end)

describe("changeset.diff.blob", function()
  local tmp ---@type string

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    Fixture.init_repo("trunk", tmp)
    vim.fn.writefile({ "one", "two" }, vim.fs.joinpath(tmp, "notes.txt"))
    Fixture.commit("seed", tmp)
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  ---@param object string
  ---@return string?
  local function blob(object)
    local text, done
    diff.blob(object, tmp, function(result)
      text, done = result, true
    end)
    assert.is_true(
      vim.wait(10000, function()
        return done
      end, 10),
      "blob never called back"
    )
    return text
  end

  it("reads a committed file's text", function()
    assert.equal("one\ntwo\n", blob("HEAD:notes.txt"))
  end)

  it("has no text for a path the commit does not hold", function()
    assert.is_nil(blob("HEAD:missing.txt"))
  end)
end)
