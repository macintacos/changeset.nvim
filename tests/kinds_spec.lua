local kinds = require("changeset.kinds")

describe("changeset.kinds", function()
  describe("for_filetype", function()
    it("keeps declaration kinds", function()
      assert.is_true(kinds.for_filetype("go").Function)
      assert.is_true(kinds.for_filetype("go").Class)
    end)

    it("keeps nothing back for data filetypes, where every kind is structure", function()
      assert.is_nil(kinds.for_filetype("toml"))
      assert.is_nil(kinds.for_filetype("json"))
      assert.is_nil(kinds.for_filetype("markdown"))
    end)

    it("drops Package for lua, where lua_ls uses it for control-flow blocks", function()
      assert.is_nil(kinds.for_filetype("lua").Package)
    end)

    it("keeps Package for languages that use it for real packages", function()
      assert.is_true(kinds.for_filetype("go").Package)
    end)

    it("does not let one filetype's exclusions leak into the next call", function()
      kinds.for_filetype("lua")
      assert.is_true(kinds.for_filetype("go").Package)
    end)
  end)
end)
