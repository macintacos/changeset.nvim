local Dialog = require("support.dialog")
local Fixture = require("support.git")
local fake = require("support.herdr")
local present = require("support.present")
local herdr = require("changeset.herdr")

describe("changeset.herdr", function()
  ---@param fields table
  ---@return changeset.HerdrAgent
  local function agent(fields)
    local merged =
      vim.tbl_extend("force", { agent = "claude", agent_status = "idle", workspace_id = "w1", title = "" }, fields)
    ---@cast merged changeset.HerdrAgent
    return merged
  end

  local mine = agent({ pane_id = "w1:p0" })
  local alpha = agent({
    pane_id = "w1:p1",
    name = "alpha",
    title = "Fix the parser",
    cwd = "/src/parser",
    tokens = { branch = "fix-parser" },
  })
  local beta = agent({ pane_id = "w1:p2", agent = "codex", agent_status = "working" })

  ---Runs `send` and waits for its callback.
  ---@param text string
  ---@param keys string? Pressed in the agent picker once it opens.
  ---@param root string? The repository the text is about; a fresh one, which no send has gone from, when absent.
  ---@return string? err
  ---@return string? name
  ---@return boolean called
  local function send(text, keys, root)
    local done, err, name = false, nil, nil
    herdr.send(text, { title = "Submit 2 review comments", root = root or vim.fn.tempname() }, function(e, n)
      done, err, name = true, e, n
    end)
    if keys then
      Dialog.press(keys)
    end
    vim.wait(5000, function()
      return done
    end)
    return err, name, done
  end

  ---The calls that wrote to or focused a pane.
  ---@return string[][]
  local function writes()
    return vim.tbl_filter(function(call)
      return call[1] == "pane" or call[2] == "focus"
    end, fake.calls())
  end

  before_each(function()
    fake.reset()
    vim.env.HERDR_WORKSPACE_ID = "w1"
    vim.env.HERDR_PANE_ID = "w1:p0"
  end)

  after_each(function()
    vim.cmd("silent! fclose!")
  end)

  it("pastes into the only other agent unsent, then focuses its pane", function()
    fake.set("agent list", fake.agents({ mine, alpha }))

    local err, name = send("line one\nline two")

    assert.is_nil(err)
    assert.equal("alpha", name)
    assert.same({
      { "pane", "send-text", "w1:p1", "\27[200~line one\nline two\27[201~" },
      { "agent", "focus", "w1:p1" },
    }, writes())
  end)

  it("offers several agents under the title it is given, with where each works, and sends to the pick", function()
    fake.set("agent list", fake.agents({ beta, alpha }))
    local done, err, name = false, nil, nil
    herdr.send("hi", { title = "Submit 2 review comments", root = vim.fn.tempname() }, function(e, n)
      done, err, name = true, e, n
    end)
    local title, rows = Dialog.title(), Dialog.lines()
    Dialog.press("2")
    vim.wait(5000, function()
      return done
    end)

    assert.equal("Submit 2 review comments", title)
    assert.same({ "  1  ● alpha  idle     parser  fix-parser  Fix the parser", "  2  ● codex  working" }, rows)
    assert.is_nil(err)
    assert.equal("codex", name)
    assert.equal("w1:p2", present(writes()[1])[3])
  end)

  describe("with a repository checked out in two places", function()
    local root ---@type string
    local worktree ---@type string

    before_each(function()
      root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      root = vim.fs.normalize(present(vim.uv.fs_realpath(root)))
      Fixture.init_repo("main", root)
      worktree = vim.fn.tempname()
      Fixture.git({ "worktree", "add", "-q", worktree, "-b", "feature" }, root)
      worktree = vim.fs.normalize(present(vim.uv.fs_realpath(worktree)))
    end)

    after_each(function()
      vim.fn.delete(root, "rf")
      vim.fn.delete(worktree, "rf")
    end)

    ---The picker's rows for `agents`, each its name after a bar when focused; the pick is then cancelled.
    ---@param agents table[]
    ---@return string[]
    local function offered(agents)
      fake.set("agent list", fake.agents(agents))
      local done = false
      herdr.send("hi", { title = "Submit", root = root }, function()
        done = true
      end)
      local rows = vim.tbl_map(function(line)
        return (vim.startswith(line, "▌") and "▌" or "") .. line:match("● (%S+)")
      end, Dialog.lines())
      Dialog.press("q")
      vim.wait(5000, function()
        return done
      end)
      return rows
    end

    local other = agent({ pane_id = "w1:p1", name = "other", cwd = "/src/other", tokens = { branch = "main" } })
    local held = agent({ pane_id = "w1:p2", name = "held", agent_status = "blocked", tokens = { branch = "main" } })
    local busy = agent({ pane_id = "w1:p3", name = "busy", agent_status = "working", tokens = { branch = "feature" } })

    before_each(function()
      held.cwd = root
      busy.cwd = worktree .. "/lua"
    end)

    it("lists the agents working in it first, and one elsewhere on a branch of the same name with the rest", function()
      assert.same({ "▌busy", "held", "other" }, offered({ other, held, busy }))
    end)

    it("counts an agent working in it through a link", function()
      local link = vim.fn.tempname()
      assert.is_truthy(vim.uv.fs_symlink(worktree, link))
      busy.cwd = link

      local rows = offered({ other, busy })
      vim.fn.delete(link)

      assert.same({ "▌busy", "other" }, rows)
    end)

    it("focuses no row when no agent working in it can be picked", function()
      assert.same({ "held", "other" }, offered({ other, held }))
    end)

    it("leads with the agent it last went to while that agent works where it did", function()
      fake.set("agent list", fake.agents({ other, held, busy }))
      send("hi", "3", root)

      assert.same({ "▌other", "busy", "held" }, offered({ other, held, busy }))
      local moved = vim.tbl_extend("force", other, { cwd = "/src/moved" })
      assert.same({ "▌busy", "held", "other" }, offered({ moved, held, busy }))
    end)

    it("remembers the agent it last went to for each branch", function()
      fake.set("agent list", fake.agents({ other, held, busy }))
      send("hi", "3", root)
      Fixture.git({ "checkout", "-q", "-b", "next" }, root)

      assert.same({ "▌busy", "held", "other" }, offered({ other, held, busy }))
    end)
  end)

  it("ranks the agent last sent to, then those working in the repository, ready first and blocked last", function()
    local ranked, focus = herdr._rank({
      agent({ pane_id = "out-blocked", agent_status = "blocked", cwd = "/elsewhere" }),
      agent({ pane_id = "out-idle", cwd = "/repo-other" }),
      agent({ pane_id = "in-blocked", agent_status = "blocked", cwd = "/repo" }),
      agent({ pane_id = "in-unknown", agent_status = "unknown", cwd = "/wt/feature/lua" }),
      agent({ pane_id = "in-working", agent_status = "working", cwd = "/repo" }),
      agent({ pane_id = "in-idle", cwd = "/repo/lua" }),
      agent({ pane_id = "in-done", agent_status = "done", cwd = "/repo" }),
      agent({ pane_id = "last", agent_status = "working", cwd = "/elsewhere" }),
    }, { worktrees = { "/repo", "/wt/feature" }, last = { pane = "last", dir = "/elsewhere" } }, function(path)
      return path
    end)

    assert.same(
      { "last", "in-idle", "in-done", "in-working", "in-unknown", "in-blocked", "out-idle", "out-blocked" },
      vim.tbl_map(function(a)
        return a.pane_id
      end, ranked)
    )
    assert.equal(1, focus)
  end)

  it("sends nothing when the pick is cancelled", function()
    fake.set("agent list", fake.agents({ alpha, beta }))

    local err, name, called = send("hi", "q")

    assert.is_true(called)
    assert.is_nil(err)
    assert.is_nil(name)
    assert.same({}, writes())
  end)

  it("offers an agent at a permission prompt without letting it be picked", function()
    fake.set(
      "agent list",
      fake.agents({ alpha, agent({ pane_id = "w1:p5", name = "gamma", agent_status = "blocked" }) })
    )

    local err, name = send("hi", "2q")

    assert.same({ nil, nil }, { err, name })
    assert.same({}, writes())
  end)

  it("keeps only agents in this workspace other than this pane", function()
    local entries = {
      mine,
      agent({ pane_id = "w2:p1", workspace_id = "w2" }),
      agent({ pane_id = "w1:p3", agent = vim.NIL }),
      agent({ pane_id = "w1:p4", agent = "" }),
      beta,
      alpha,
    }
    local kept = herdr._candidates(vim.json.decode(vim.json.encode(entries)), "w1", "w1:p0")
    assert.same(
      { "w1:p2", "w1:p1" },
      vim.tbl_map(function(a)
        return a.pane_id
      end, kept)
    )
  end)

  it("names an agent by name, then display name, then kind, then pane, skipping null", function()
    assert.equal(
      "Display",
      herdr._name(vim.json.decode('{"name":null,"display_agent":"Display","agent":"claude","pane_id":"p"}'))
    )
    assert.equal("p", herdr._name({ agent = "", pane_id = "p" }))
  end)

  it("labels a status through the agent's state labels", function()
    local row =
      herdr._row({ pane_id = "p", agent = "x", agent_status = "working", state_labels = { working = "Thinking" } })
    assert.equal("Thinking", present(row.cells[2])[1])
  end)

  it("shows where an agent works by the directory of the program in its pane, over the pane's own", function()
    local row = herdr._row({
      pane_id = "p",
      agent = "x",
      cwd = "/home",
      foreground_cwd = "/wt/sandbox-pr1",
      tokens = { branch = "feat/store" },
      title = "t",
    })

    assert.same(
      { "x", "", "sandbox-pr1", "feat/store", "t" },
      vim.tbl_map(function(cell)
        return cell[1]
      end, row.cells)
    )
  end)

  it("reports that there is no agent when none is left", function()
    fake.set("agent list", fake.agents({ mine }))
    assert.equal("no agent in this herdr workspace", (send("hi")))
  end)

  it("refuses outside herdr without calling it", function()
    vim.env.HERDR_WORKSPACE_ID = nil
    local err = send("hi")
    assert.matches("not inside a herdr pane", present(err))
    assert.same({}, fake.calls())
  end)

  it("says herdr isn't on PATH inside a herdr pane without it, without calling it", function()
    local err = require("support.gh").without(send, "hi")
    assert.matches("isn't on PATH", present(err))
    assert.same({}, fake.calls())
  end)

  it("refuses when herdr can't be started", function()
    local system = vim.system
    vim.system = function()
      error("E2BIG")
    end
    local err, _, called = send("hi")
    vim.system = system
    assert.is_true(called)
    assert.truthy(err)
  end)

  it("refuses an agent that is at a prompt by the time of the send", function()
    fake.answer("agent list", fake.agents({ alpha }))
    fake.answer("agent list", fake.agents({ agent({ pane_id = "w1:p1", name = "alpha", agent_status = "blocked" }) }))
    assert.equal("answer alpha's prompt first", (send("hi")))
    assert.same({}, writes())
  end)

  it("reports an agent whose pane went away before the send as closed", function()
    fake.answer("agent list", fake.agents({ alpha }))
    fake.answer("agent list", fake.agents({}))
    assert.equal("alpha closed", (send("hi")))
    assert.same({}, writes())
  end)

  it("reports a pane herdr cannot find as closed", function()
    fake.set("agent list", fake.agents({ alpha }))
    fake.set("pane send-text", fake.error("pane_not_found"))
    assert.equal("alpha closed", (send("hi")))
  end)

  it("reports any other failed send as refused", function()
    fake.set("agent list", fake.agents({ alpha }))
    fake.set("pane send-text", fake.error("internal"))
    assert.equal("herdr refused the paste", (send("hi")))
  end)

  it("strips paste terminators from the text, including one that stripping forms", function()
    assert.equal("\27[200~ab\27[201~", herdr._bracket("a\27[201\27[201~~b"))
  end)

  it("succeeds when only the focus fails", function()
    fake.set("agent list", fake.agents({ alpha }))
    fake.set("agent focus", fake.error("internal"))
    local err, name = send("hi")
    assert.is_nil(err)
    assert.equal("alpha", name)
  end)
end)
