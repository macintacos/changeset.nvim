local fake = require("support.herdr")
local herdr = require("changeset.herdr")

describe("changeset.herdr", function()
  local select = vim.ui.select

  ---@param fields table
  ---@return table
  local function agent(fields)
    return vim.tbl_extend("force", { agent = "claude", agent_status = "idle", workspace_id = "w1", title = "" }, fields)
  end

  local mine = agent({ pane_id = "w1:p0" })
  local alpha = agent({ pane_id = "w1:p1", name = "alpha", tab_id = "w1:t1", title = "Fix the parser" })
  local beta = agent({ pane_id = "w1:p2", agent = "codex", agent_status = "working", tab_id = "w1:t2" })

  ---Runs `send` and waits for its callback.
  ---@param text string
  ---@return string? err
  ---@return string? name
  ---@return boolean called
  local function send(text)
    local done, err, name = false, nil, nil
    herdr.send(text, function(e, n)
      done, err, name = true, e, n
    end)
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
    vim.ui.select = select
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

  it("offers several agents in herdr's order with name, status, tab and title, and sends to the pick", function()
    fake.set("agent list", fake.agents({ alpha, beta }))
    fake.set(
      "tab list",
      { stdout = vim.json.encode({ result = { tabs = { { tab_id = "w1:t1", label = "parser" } } } }) }
    )
    local rows, prompt
    vim.ui.select = function(items, opts, on_choice)
      prompt = opts.prompt
      rows = vim.tbl_map(opts.format_item, items)
      on_choice(items[2])
    end

    local err, name = send("hi")

    assert.is_nil(err)
    assert.equal("Send the review to which agent?", prompt)
    assert.same({ "alpha · idle · parser · Fix the parser", "codex · working" }, rows)
    assert.equal("codex", name)
    assert.same({ "tab", "list", "--workspace", "w1" }, fake.calls()[2])
    assert.equal("w1:p2", writes()[1][3])
  end)

  it("sends nothing when the pick is cancelled", function()
    fake.set("agent list", fake.agents({ alpha, beta }))
    vim.ui.select = function(_, _, on_choice)
      on_choice(nil)
    end

    local err, name, called = send("hi")

    assert.is_true(called)
    assert.is_nil(err)
    assert.is_nil(name)
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
    assert.equal(
      "x · Thinking",
      herdr._row({ pane_id = "p", agent = "x", agent_status = "working", state_labels = { working = "Thinking" } }, {})
    )
  end)

  it("reports that there is no agent when none is left", function()
    fake.set("agent list", fake.agents({ mine }))
    assert.equal("no agent in this herdr workspace", (send("hi")))
  end)

  it("refuses outside herdr without calling it", function()
    vim.env.HERDR_WORKSPACE_ID = nil
    local err = send("hi")
    assert.matches("not inside a herdr pane", err)
    assert.same({}, fake.calls())
  end)

  it("says herdr isn't on PATH inside a herdr pane without it, without calling it", function()
    local err = require("support.gh").without(send, "hi")
    assert.matches("isn't on PATH", err)
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
    assert.equal("herdr refused the send", (send("hi")))
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
