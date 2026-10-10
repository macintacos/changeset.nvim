local Changes = require("support.changes")
local Fixture = require("support.git")
local Symbols = require("support.symbols")
local present = require("support.present")
require("support.gh")

describe("changeset.sidebar_state", function()
  local build = require("changeset.build")
  local Rows = require("changeset.rows")
  local sidebar_state = require("changeset.sidebar_state")
  local tmp ---@type string
  local previous_dir ---@type string
  local symbols ---@type support.symbols.Source

  local ROWS = Rows.build(
    { Changes.file("mod.lua", { 1 }) },
    { ["mod.lua"] = { Changes.sym("load", "Function", 0, 1, 2) } }
  )

  local MARKED = { rows = ROWS, visible = ROWS, cursor = 1, focused = false }

  ---Build the tree and wait for its diff.
  local function built()
    build.build()
    assert.is_true(vim.wait(10000, function()
      return present(build.current()).collected
    end, 10))
  end

  ---The names on screen when `view` shows `ROWS`.
  ---@param view changeset.View
  ---@return string[]
  local function shown(view)
    view:show(ROWS, {
      icon = function()
        return "", ""
      end,
      width = 80,
      cursor = 1,
    })
    return vim.tbl_map(function(row)
      return row.name
    end, view:visible())
  end

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
    symbols = Symbols.install()
  end)

  after_each(function()
    symbols.restore()
    vim.cmd("silent! %bwipeout!")
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("holds the state of whatever tree was built, with no sidebar loaded", function()
    assert.is_nil(sidebar_state.current())

    Fixture.feature_one_file(tmp)
    built()
    local state = sidebar_state.current()

    assert.equal(build.current(), present(state).tree)
    assert.equal(state, sidebar_state.current())
    assert.is_nil(package.loaded["changeset"])
  end)

  it("starts afresh for a tree that replaced the last one, keeping the repository's folds", function()
    Fixture.feature_one_file(tmp)
    built()
    local state = present(sidebar_state.current())
    state.rows = ROWS
    state.view:narrow("mod")
    state.view:fold_files(ROWS)
    state.position:pick(present(Rows.files(ROWS)[1]))
    local folded = shown(state.view)
    assert.equal(1, #state.position:marks(MARKED))

    Fixture.git({ "checkout", "-q", "-b", "other" }, tmp)
    built()
    local fresh = present(sidebar_state.current())

    assert.is_false(state == fresh)
    assert.equal(build.current(), fresh.tree)
    assert.same({}, fresh.rows)
    assert.equal("", fresh.view:query())
    assert.same({}, fresh.position:marks(MARKED))
    assert.same(folded, shown(fresh.view))
  end)
end)
