local diff = require("plugins.changeset.diff")
local Fixture = require("support.git")

-- Real `git diff --numstat -M <base>` output. Renames appear as `old => new`, or with the
-- shared prefix/suffix folded into braces; binary files report `-` for both counts.
local NUMSTAT = {
  "0\t0\tdocs/{guide => tutorial}/intro.md",
  "4\t0\tfresh.lua",
  "0\t6\tlegacy.lua",
  "-\t-\tlogo.png",
  "0\t0\tlua/{a => }/x.lua",
  "1\t1\told_name.lua => new_name.lua",
  "3\t2\tnotes.txt",
  "2\t3\tsrc/session.lua",
}

-- Real `git diff --name-status -M <base>` output for the same change as NUMSTAT.
local NAME_STATUS = {
  "R100\tdocs/guide/intro.md\tdocs/tutorial/intro.md",
  "A\tfresh.lua",
  "D\tlegacy.lua",
  "M\tlogo.png",
  "R100\tlua/a/x.lua\tlua/x.lua",
  "R088\told_name.lua\tnew_name.lua",
  "M\tnotes.txt",
  "M\tsrc/session.lua",
}

describe("changeset.diff._parse_numstat", function()
  local stats

  before_each(function()
    stats = diff._parse_numstat(NUMSTAT)
  end)

  it("reads added and removed counts per path", function()
    assert.same({ added = 2, removed = 3 }, stats["src/session.lua"])
    assert.same({ added = 4, removed = 0 }, stats["fresh.lua"])
    assert.same({ added = 0, removed = 6 }, stats["legacy.lua"])
  end)

  it("keys a plain `old => new` rename by its new path", function()
    assert.same({ added = 1, removed = 1 }, stats["new_name.lua"])
    assert.is_nil(stats["old_name.lua"])
  end)

  it("expands the brace form of a rename to the new path", function()
    assert.same({ added = 0, removed = 0 }, stats["docs/tutorial/intro.md"])
  end)

  it("drops the empty side of a brace rename without leaving a double slash", function()
    assert.same({ added = 0, removed = 0 }, stats["lua/x.lua"])
  end)

  it("counts a binary file's `-` placeholders as zero", function()
    assert.same({ added = 0, removed = 0 }, stats["logo.png"])
  end)

  it("unquotes a path git quoted because it holds a quote character", function()
    local stat = diff._parse_numstat({ '1\t0\t"quo\\"te.txt"' })

    assert.same({ added = 1, removed = 0 }, stat['quo"te.txt'])
  end)

  it("returns an empty table for an empty diff", function()
    assert.same({}, diff._parse_numstat({}))
  end)
end)

describe("changeset.diff._parse_name_status", function()
  local statuses

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
    assert.same({ status = "renamed", oldpath = "lua/a/x.lua" }, statuses["lua/x.lua"])
    assert.is_nil(statuses["old_name.lua"])
  end)

  it("unquotes a path git quoted because it holds a quote character", function()
    local status = diff._parse_name_status({ 'A\t"quo\\"te.txt"' })

    assert.same({ status = "added" }, status['quo"te.txt'])
  end)

  it("returns an empty table for an empty diff", function()
    assert.same({}, diff._parse_name_status({}))
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
  local hunks

  before_each(function()
    hunks = diff._parse_hunks(HUNKS)
  end)

  it("reads every hunk of a file that has several", function()
    assert.same({
      { lnum = 3, count = 1, added = 1, removed = 1 },
      { lnum = 10, count = 1, added = 1, removed = 1 },
      { lnum = 24, count = 0, added = 0, removed = 1 },
    }, hunks["src/session.lua"])
  end)

  it("records a pure deletion at the line it followed, with a zero count", function()
    assert.same({ lnum = 7, count = 0, added = 0, removed = 2 }, hunks["notes.txt"][1])
  end)

  it("records a pure addition as the new lines it spans", function()
    assert.same({ lnum = 16, count = 3, added = 3, removed = 0 }, hunks["notes.txt"][2])
  end)

  it("spans the whole file for a newly added one", function()
    assert.same({ { lnum = 1, count = 4, added = 4, removed = 0 } }, hunks["fresh.lua"])
  end)

  it("records a deleted file as one pure deletion", function()
    assert.same({ { lnum = 0, count = 0, added = 0, removed = 6 } }, hunks["legacy.lua"])
  end)

  it("attributes a renamed file's hunks to its new path", function()
    assert.same({ { lnum = 5, count = 1, added = 1, removed = 1 } }, hunks["new_name.lua"])
    assert.is_nil(hunks["old_name.lua"])
  end)

  it("lists a binary file with no hunks", function()
    assert.same({}, hunks["logo.png"])
  end)

  it("lists a rename with no content change with no hunks", function()
    assert.same({}, hunks["docs/tutorial/intro.md"])
    assert.same({}, hunks["lua/x.lua"])
  end)

  it("keeps the spaces in a path", function()
    local spaced = diff._parse_hunks(HUNKS_SPACED_PATH)
    assert.same({ { lnum = 2, count = 1, added = 1, removed = 1 } }, spaced["my notes.txt"])
  end)

  it("unquotes a path git quoted because it holds a quote character", function()
    local quoted = diff._parse_hunks({
      'diff --git "a/quo\\"te.txt" "b/quo\\"te.txt"',
      "@@ -1 +1 @@",
    })

    assert.same({ { lnum = 1, count = 1, added = 1, removed = 1 } }, quoted['quo"te.txt'])
  end)

  it("drops a hunk header that arrives before any file header", function()
    assert.same({}, diff._parse_hunks({ "@@ -1 +1 @@" }))
  end)

  it("returns an empty table for an empty diff", function()
    assert.same({}, diff._parse_hunks({}))
  end)
end)

describe("changeset.diff._assemble", function()
  local NO_PARTS = { numstat = {}, statuses = {}, hunks = {}, untracked = {} }

  ---@param overrides table
  local function assemble(overrides)
    return diff._assemble(vim.tbl_extend("force", NO_PARTS, overrides))
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
        hunks = { { lnum = 1, count = 3, added = 3, removed = 0 } },
      },
    }, files)
  end)

  it("gives an empty untracked file no hunk", function()
    local files = assemble({ untracked = { ["empty.txt"] = 0 } })

    assert.same({}, files[1].hunks)
  end)

  it("orders tracked and untracked files together by path", function()
    local files = assemble({
      statuses = { ["b.lua"] = { status = "modified" }, ["d.lua"] = { status = "added" } },
      untracked = { ["a.txt"] = 1, ["c.txt"] = 1 },
    })

    local paths = vim.tbl_map(function(file)
      return file.path
    end, files)
    assert.same({ "a.txt", "b.lua", "c.txt", "d.lua" }, paths)
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

local TWELVE_LINES =
  { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve" }

---Run `diff.collect` and block until its callback fires, failing on timeout or git error.
---@param base string
---@param cwd string
---@return changeset.File[]
local function collect(base, cwd)
  local files, err, done
  diff.collect(base, cwd, function(result, message)
    files, err, done = result, message, true
  end)
  assert(
    vim.wait(10000, function()
      return done
    end, 10),
    "collect never called back"
  )
  assert(not err, err)
  return files
end

describe("changeset.diff.collect", function()
  local tmp

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
        added = 2,
        removed = 2,
        hunks = {
          { lnum = 4, count = 1, added = 1, removed = 1 },
          { lnum = 8, count = 1, added = 1, removed = 1 },
        },
      },
    }, collect(base, tmp))
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

    assert.same({ { lnum = 4, count = 1, added = 1, removed = 1 } }, collect(base, tmp)[1].hunks)
  end)

  it("reads hunks when the user config installs an external diff driver", function()
    local base = seed_edited_file(tmp)
    -- An external driver replaces git's own diff output wholesale, so the
    -- parser sees no hunk headers at all.
    Fixture.git({ "config", "diff.external", "true" }, tmp)

    assert.same({ { lnum = 4, count = 1, added = 1, removed = 1 } }, collect(base, tmp)[1].hunks)
  end)

  it("keeps a non-ASCII path as a real filename", function()
    local base = Fixture.init_repo("trunk", tmp)
    write("é.txt", { "a", "b" })

    assert.equal("é.txt", collect(base, tmp)[1].path)
  end)

  it("reports git's stderr when the base is not a commit", function()
    Fixture.init_repo("trunk", tmp)
    local files, err, done
    diff.collect("no-such-ref", tmp, function(result, message)
      files, err, done = result, message, true
    end)
    assert(
      vim.wait(10000, function()
        return done
      end, 10),
      "collect never called back"
    )

    assert.is_nil(files)
    assert.truthy(err and #err > 0)
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
      { path = "new.txt", oldpath = "old.txt", status = "renamed", added = 0, removed = 0, hunks = {} },
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
        added = 3,
        removed = 0,
        hunks = { { lnum = 1, count = 3, added = 3, removed = 0 } },
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
    assert(vim.uv.fs_symlink("missing", vim.fs.joinpath(tmp, "dangling")))

    local files = collect(base, tmp)

    assert.same(
      { "scratch.txt" },
      vim.tbl_map(function(file)
        return file.path
      end, files)
    )
    assert.equal(3, files[1].added)
  end)
end)
