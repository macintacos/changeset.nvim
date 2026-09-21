local prefs = require("plugins.changeset.prefs")

local ROOT = "/src/app"
local BRANCH = "feat/login"

describe("changeset.prefs", function()
  describe("resolve", function()
    it("hides nothing when nothing has been saved", function()
      local hidden, scope = prefs.resolve({}, ROOT, BRANCH)

      assert.same({}, hidden)
      assert.is_nil(scope)
    end)

    it("reads the global set when no repo or branch has its own", function()
      local hidden, scope = prefs.resolve({ global = { "Variable" } }, ROOT, BRANCH)

      assert.same({ Variable = true }, hidden)
      assert.equal("global", scope)
    end)

    it("prefers a repo's own set over the global one", function()
      local data = { global = { "Variable" }, repos = { [ROOT] = { kinds = { "Field" } } } }

      local hidden, scope = prefs.resolve(data, ROOT, BRANCH)

      assert.same({ Field = true }, hidden)
      assert.equal("repo", scope)
    end)

    it("prefers the branch's own set over the repo's", function()
      local data = {
        global = { "Variable" },
        repos = { [ROOT] = { kinds = { "Field" }, branches = { [BRANCH] = { "Property" } } } },
      }

      local hidden, scope = prefs.resolve(data, ROOT, BRANCH)

      assert.same({ Property = true }, hidden)
      assert.equal("branch", scope)
    end)

    it("lets a branch that hides nothing override a repo that hides something", function()
      local data = { repos = { [ROOT] = { kinds = { "Field" }, branches = { [BRANCH] = {} } } } }

      local hidden, scope = prefs.resolve(data, ROOT, BRANCH)

      assert.same({}, hidden)
      assert.equal("branch", scope)
    end)

    it("leaves another repo's set alone", function()
      local data = { repos = { ["/src/other"] = { kinds = { "Field" } } } }

      local hidden, scope = prefs.resolve(data, ROOT, BRANCH)

      assert.same({}, hidden)
      assert.is_nil(scope)
    end)
  end)

  describe("apply", function()
    it("records a branch set without touching the wider scopes", function()
      local data = { global = { "Variable" }, repos = { [ROOT] = { kinds = { "Field" } } } }

      local out = prefs.apply(data, "branch", ROOT, BRANCH, { Property = true })

      assert.same({ "Property" }, out.repos[ROOT].branches[BRANCH])
      assert.same({ "Variable" }, out.global)
      assert.same({ "Field" }, out.repos[ROOT].kinds)
    end)

    it("clears the branch set that would shadow a repo save", function()
      local data = { repos = { [ROOT] = { branches = { [BRANCH] = { "Property" } } } } }

      local hidden, scope = prefs.resolve(prefs.apply(data, "repo", ROOT, BRANCH, { Field = true }), ROOT, BRANCH)

      assert.same({ Field = true }, hidden)
      assert.equal("repo", scope)
    end)

    it("clears the repo and branch sets that would shadow a global save", function()
      local data = { repos = { [ROOT] = { kinds = { "Field" }, branches = { [BRANCH] = { "Property" } } } } }

      local saved = prefs.apply(data, "global", ROOT, BRANCH, { Variable = true })
      local hidden, scope = prefs.resolve(saved, ROOT, BRANCH)

      assert.same({ Variable = true }, hidden)
      assert.equal("global", scope)
    end)

    it("leaves a different repo's set standing through a global save", function()
      local data = { repos = { ["/src/other"] = { kinds = { "Field" } } } }

      local out = prefs.apply(data, "global", ROOT, BRANCH, { Variable = true })

      assert.same({ "Field" }, out.repos["/src/other"].kinds)
    end)

    it("leaves the set it was given unchanged", function()
      local data = { global = { "Variable" } }

      prefs.apply(data, "global", ROOT, BRANCH, { Field = true })

      assert.same({ global = { "Variable" } }, data)
    end)

    it("writes kind names in a stable order, so the file does not churn", function()
      local out = prefs.apply({}, "global", ROOT, BRANCH, { Variable = true, Field = true, Class = true })

      assert.same({ "Class", "Field", "Variable" }, out.global)
    end)
  end)

  describe("the file on disk", function()
    it("carries a saved set back across a restart", function()
      local file = vim.fn.tempname() .. "/filters.json"

      prefs.save(file, prefs.apply({}, "branch", ROOT, BRANCH, { Field = true }))

      assert.same({ Field = true }, (prefs.resolve(prefs.load(file), ROOT, BRANCH)))
    end)

    it("hides nothing when the file is absent", function()
      assert.same({}, prefs.load(vim.fn.tempname() .. "/missing.json"))
    end)

    it("reports a choice that did not reach the disk", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      vim.fn.setfperm(dir, "r-xr-xr-x")

      local written = prefs.save(dir .. "/filters.json", { global = { "Field" } })
      vim.fn.setfperm(dir, "rwxr-xr-x")
      vim.fn.delete(dir, "rf")

      assert.is_false(written)
    end)

    it("hides nothing when a scope in the file was hand-edited to null", function()
      local file = vim.fn.tempname() .. "/filters.json"
      vim.fn.mkdir(vim.fs.dirname(file), "p")
      vim.fn.writefile({ '{"repos": null, "global": null}' }, file)

      assert.same({}, (prefs.resolve(prefs.load(file), ROOT, BRANCH)))
    end)
  end)
end)
