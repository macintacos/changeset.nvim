local diff_reach = require("changeset.diff_reach")

describe("changeset.diff_reach", function()
  local A, B = "/repo/a.lua", "/repo/b.lua"

  ---Whether `reach` allows `A` and `B`, in that order.
  ---@param reach changeset.DiffReach
  ---@return boolean[]
  local function allowed(reach)
    return { reach:allows(A), reach:allows(B) }
  end

  it("allows no file before it is turned on", function()
    local reach = diff_reach.new()
    reach:enter(A)

    assert.same({ false, false }, allowed(reach))
    assert.is_false(reach:on())
  end)

  it("allows every file once turned on", function()
    local reach = diff_reach.new()

    reach:turn_on()

    assert.same({ true, true }, allowed(reach))
    assert.is_true(reach:on())
  end)

  it("limited to none, allows no file and is off", function()
    local reach = diff_reach.new()
    reach:turn_on()
    reach:enter(A)

    reach:limit("none")

    assert.same({ false, false }, allowed(reach))
    assert.is_false(reach:on())
  end)

  it("limited to entered, allows only the files entered, those entered later included", function()
    local reach = diff_reach.new()
    reach:enter(A)
    reach:turn_on()

    reach:limit("entered")
    assert.same({ true, false }, allowed(reach))
    reach:enter(B)

    assert.same({ true, true }, allowed(reach))
    assert.is_true(reach:on())
  end)

  it("limited to all, still allows every file", function()
    local reach = diff_reach.new()
    reach:turn_on()

    reach:limit("all")

    assert.same({ true, true }, allowed(reach))
  end)

  it("never allows more for a limit wider than it is", function()
    local reach = diff_reach.new()
    reach:enter(A)
    reach:turn_on()
    reach:limit("entered")

    reach:limit("all")
    assert.same({ true, false }, allowed(reach))
    reach:limit("none")
    reach:limit("all")

    assert.same({ false, false }, allowed(reach))
  end)

  it("keeps the files entered through being turned off and on", function()
    local reach = diff_reach.new()
    reach:turn_on()
    reach:enter(A)
    reach:limit("none")
    reach:turn_on()

    reach:limit("entered")

    assert.same({ true, false }, allowed(reach))
  end)

  it("says whether a file was entered for the first time", function()
    local reach = diff_reach.new()

    assert.same({ true, false }, { reach:enter(A), reach:enter(A) })
  end)

  it("stops allowing a file closed by hand, and only that file, until it is next turned on", function()
    local reach = diff_reach.new()
    reach:turn_on()

    reach:hand_close(A)
    assert.same({ false, true }, allowed(reach))
    reach:limit("none")
    reach:turn_on()

    assert.same({ true, true }, allowed(reach))
  end)

  it("lets turning on again while on clear the files closed by hand", function()
    local reach = diff_reach.new()
    reach:turn_on()
    reach:hand_close(A)

    reach:turn_on()

    assert.same({ true, true }, allowed(reach))
  end)
end)
