local submittable = require("changeset.submittable")

describe("refusal", function()
  it("refuses a comment with neither a body nor a review comment", function()
    assert.is_string(submittable.refusal({ event = "COMMENT" }, 0))
  end)

  it("takes a comment with a body alone", function()
    assert.is_nil(submittable.refusal({ event = "COMMENT", body = "Looks good" }, 0))
  end)

  it("takes a comment with a review comment alone", function()
    assert.is_nil(submittable.refusal({ event = "COMMENT" }, 1))
  end)

  it("takes an empty approval", function()
    assert.is_nil(submittable.refusal({ event = "APPROVE" }, 0))
  end)

  it("takes an empty request for changes", function()
    assert.is_nil(submittable.refusal({ event = "REQUEST_CHANGES" }, 0))
  end)
end)

describe("events", function()
  it("offers only a comment on the viewer's own PR", function()
    assert.same({ "COMMENT" }, submittable.events(true))
  end)

  it("offers every event on someone else's PR, a comment first", function()
    assert.same({ "COMMENT", "APPROVE", "REQUEST_CHANGES" }, submittable.events(false))
  end)
end)
