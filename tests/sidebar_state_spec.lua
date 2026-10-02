local Fixture = require("support.git")
require("support.gh")

describe("changeset.sidebar_state", function()
  local build = require("changeset.build")
  local sidebar_state = require("changeset.sidebar_state")
  local tmp, previous_dir

  before_each(function()
    tmp, previous_dir = Fixture.enter_tempdir()
  end)

  after_each(function()
    vim.fn.chdir(previous_dir)
    vim.fn.delete(tmp, "rf")
  end)

  it("holds the state of whatever tree was built, with no sidebar loaded", function()
    assert.is_nil(sidebar_state.current())

    Fixture.feature_one_file(tmp)
    build.build()
    local state = sidebar_state.current()

    assert.equal(build.current(), assert(state).tree)
    assert.equal(state, sidebar_state.current())
    assert.is_nil(package.loaded["changeset"])
  end)

  it("starts afresh for a tree that replaced the last one", function()
    Fixture.feature_one_file(tmp)
    build.build()
    local state = assert(sidebar_state.current())

    Fixture.git({ "checkout", "-q", "-b", "other" }, tmp)
    build.build()
    local fresh = assert(sidebar_state.current())

    assert.is_false(state == fresh)
    assert.equal(build.current(), fresh.tree)
    assert.same({}, fresh.rows)
  end)
end)
