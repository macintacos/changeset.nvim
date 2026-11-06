local Dialog = require("support.dialog")
local Fixture = require("support.git")
local fake = require("support.rex")
local present = require("support.present")
local agent = require("changeset.agent")

describe("changeset.agent", function()
  ---@alias support.Foreground { pid: integer, name: string, cwd: string? }

  ---A pane as the listing script reports it, its foreground program the one that reported its status unless
  ---`fields.foreground` says otherwise.
  ---@param fields { block: string, app: string?, state: string?, label: string?, cwd: string?, id: string?, foreground: support.Foreground? }
  ---@return changeset.RexPane
  local function pane(fields)
    return {
      block_id = fields.block,
      label = fields.label,
      records = {
        {
          id = fields.id,
          state = fields.state or "idle",
          effective_app = fields.app or "claude-code",
          owner = { pid = 7, name = "2.1" },
        },
      },
      foreground = fields.foreground or { pid = 7, name = "2.1", cwd = fields.cwd },
    }
  end

  local mine = pane({ block = "b0" })
  local alpha = pane({ block = "b1", app = "alpha", label = "Fix the parser", cwd = "/src/parser" })
  local beta = pane({ block = "b2", app = "codex", state = "working" })

  ---Runs `send` and waits for its callback.
  ---@param text string
  ---@param keys string? Pressed in the agent picker once it opens.
  ---@param root string? The repository the text is about; a fresh one, which no send has gone from, when absent.
  ---@return string? err
  ---@return string? name
  ---@return boolean called
  local function send(text, keys, root)
    local done, err, name = false, nil, nil
    agent.send(text, { title = "Submit 2 review comments", root = root or vim.fn.tempname() }, function(e, n)
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
  ---@return { args: string[], stdin: string }[]
  local function writes()
    return vim.tbl_filter(function(call)
      return call.args[1] == "api" or call.args[1] == "focus"
    end, fake.calls())
  end

  before_each(function()
    fake.reset()
    vim.env.REX_SESSION = "s1"
    vim.env.REX_BLOCK = "b0"
  end)

  after_each(function()
    vim.cmd("silent! fclose!")
  end)

  it("pastes into the only other agent unsent, then focuses its pane", function()
    fake.set("do", fake.panes({ mine, alpha }))

    local err, name = send("line one\nline two")

    assert.is_nil(err)
    assert.equal("alpha", name)
    local calls = writes()
    assert.same({ { "api", "call", "-s", "s1", "block.event", "-" }, { "focus", "-s", "s1", "b1" } }, {
      present(calls[1]).args,
      present(calls[2]).args,
    })
    assert.same(
      { block_id = "b1", event = { type = "paste", payload = { text = "line one\nline two" } } },
      vim.json.decode(present(calls[1]).stdin)
    )
  end)

  it("lists the panes of this Rex session", function()
    fake.set("do", fake.panes({ mine, alpha }))
    send("hi")
    assert.same({ "do", "-s", "s1", "-e" }, vim.list_slice(present(fake.calls()[1]).args, 1, 4))
  end)

  it("offers several agents under the title it is given, with where each works, and sends to the pick", function()
    fake.set("do", fake.panes({ beta, alpha }))
    local done, err, name = false, nil, nil
    agent.send("hi", { title = "Submit 2 review comments", root = vim.fn.tempname() }, function(e, n)
      done, err, name = true, e, n
    end)
    local title, rows = Dialog.title(), Dialog.lines()
    Dialog.press("2")
    vim.wait(5000, function()
      return done
    end)

    assert.equal("Submit 2 review comments", title)
    assert.same({ "  1  ● alpha  idle     parser    Fix the parser", "  2  ● codex  working" }, rows)
    assert.is_nil(err)
    assert.equal("codex", name)
    assert.equal("b2", present(writes()[2]).args[4])
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

    ---The picker's rows for `panes`, each its name after a bar when focused; the pick is then cancelled.
    ---@param panes table[]
    ---@return string[]
    local function offered(panes)
      fake.set("do", fake.panes(panes))
      local done = false
      agent.send("hi", { title = "Submit", root = root }, function()
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

    local other = pane({ block = "b1", app = "other", cwd = "/src/other" })
    local held ---@type changeset.RexPane
    local busy ---@type changeset.RexPane

    ---@param cwd string
    ---@return changeset.RexPane
    local function busy_in(cwd)
      return pane({ block = "b3", app = "busy", state = "working", cwd = cwd })
    end

    before_each(function()
      held = pane({ block = "b2", app = "held", state = "blocked", cwd = root })
      busy = busy_in(worktree .. "/lua")
    end)

    it("lists the agents working in it first, and the rest after", function()
      assert.same({ "▌busy", "held", "other" }, offered({ other, held, busy }))
    end)

    it("shows the branch checked out where each agent works", function()
      fake.set("do", fake.panes({ held, busy }))
      agent.send("hi", { title = "Submit", root = root }, function() end)
      local rows = Dialog.lines()
      Dialog.press("q")

      assert.is_truthy((present(rows[1]):find("busy  working  lua  feature", 1, true)))
      assert.is_truthy((present(rows[2]):find(vim.fs.basename(root) .. "%s+main%s")))
    end)

    it("counts an agent working in it through a link", function()
      local link = vim.fn.tempname()
      assert.is_truthy(vim.uv.fs_symlink(worktree, link))

      local rows = offered({ other, busy_in(link) })
      vim.fn.delete(link)

      assert.same({ "▌busy", "other" }, rows)
    end)

    it("focuses no row when no agent working in it can be picked", function()
      assert.same({ "held", "other" }, offered({ other, held }))
    end)

    it("leads with the agent it last went to while that agent works where it did", function()
      fake.set("do", fake.panes({ other, held, busy }))
      send("hi", "3", root)

      assert.same({ "▌other", "busy", "held" }, offered({ other, held, busy }))
      local moved = pane({ block = "b1", app = "other", cwd = "/src/moved" })
      assert.same({ "▌busy", "held", "other" }, offered({ moved, held, busy }))
    end)

    it("remembers the agent it last went to for each branch", function()
      fake.set("do", fake.panes({ other, held, busy }))
      send("hi", "3", root)
      Fixture.git({ "checkout", "-q", "-b", "next" }, root)

      assert.same({ "▌busy", "held", "other" }, offered({ other, held, busy }))
    end)
  end)

  it("ranks the agent last sent to, then those working in the repository, ready first and blocked last", function()
    ---@param block string
    ---@param status string
    ---@param cwd string
    ---@return changeset.Agent
    local function at(block, status, cwd)
      return { block = block, app = "claude-code", status = status, cwd = cwd }
    end
    local ranked, focus = agent._rank({
      at("out-blocked", "blocked", "/elsewhere"),
      at("out-idle", "idle", "/repo-other"),
      at("in-blocked", "blocked", "/repo"),
      at("in-error", "error", "/wt/feature/lua"),
      at("in-working", "working", "/repo"),
      at("in-idle", "idle", "/repo/lua"),
      at("in-done", "done", "/repo"),
      at("last", "working", "/elsewhere"),
    }, { worktrees = { "/repo", "/wt/feature" }, last = { block = "last", dir = "/elsewhere" } }, function(path)
      return path
    end)

    assert.same(
      { "last", "in-idle", "in-done", "in-working", "in-error", "in-blocked", "out-idle", "out-blocked" },
      vim.tbl_map(function(a)
        return a.block
      end, ranked)
    )
    assert.equal(1, focus)
  end)

  it("sends nothing when the pick is cancelled", function()
    fake.set("do", fake.panes({ alpha, beta }))

    local err, name, called = send("hi", "q")

    assert.is_true(called)
    assert.is_nil(err)
    assert.is_nil(name)
    assert.same({}, writes())
  end)

  it("offers an agent at a permission prompt without letting it be picked", function()
    fake.set("do", fake.panes({ alpha, pane({ block = "b5", app = "gamma", state = "blocked" }) }))

    local err, name = send("hi", "2q")

    assert.same({ nil, nil }, { err, name })
    assert.same({}, writes())
  end)

  it("keeps the panes other than this one whose foreground program reports a status naming itself", function()
    ---@type changeset.RexPane[]
    local panes = {
      mine,
      { block_id = "b7", label = "shell", records = {}, foreground = { pid = 1, name = "fish" } },
      { block_id = "b8" },
      pane({ block = "b3", foreground = { pid = 9, name = "fish" } }),
      pane({ block = "b4", foreground = { pid = 7, name = "zsh" } }),
      pane({ block = "b5", app = "" }),
      pane({ block = "b6", id = "build" }),
      beta,
      alpha,
    }

    local kept = agent._agents(panes, "b0", function(dir)
      return dir == "/src/parser" and "fix-parser" or nil
    end)

    assert.same({
      { block = "b2", app = "codex", status = "working" },
      {
        block = "b1",
        app = "alpha",
        status = "idle",
        title = "Fix the parser",
        cwd = "/src/parser",
        branch = "fix-parser",
      },
    }, kept)
  end)

  it("shows an agent's name, status, directory, branch and title", function()
    local row = agent._row({
      block = "b",
      app = "claude-code",
      status = "working",
      cwd = "/wt/sandbox-pr1",
      branch = "feat/store",
      title = "t",
    })

    assert.same(
      { "claude-code", "working", "sandbox-pr1", "feat/store", "t" },
      vim.tbl_map(function(cell)
        return cell[1]
      end, row.cells)
    )
  end)

  it("reports that there is no agent when none is left", function()
    fake.set("do", fake.panes({ mine }))
    assert.equal("no agent in this Rex session", (send("hi")))
  end)

  it("refuses outside Rex without calling it", function()
    vim.env.REX_SESSION = nil
    local err = send("hi")
    assert.matches("not inside a Rex pane", present(err))
    assert.same({}, fake.calls())
  end)

  it("says rex isn't on PATH inside a Rex pane without it, without calling it", function()
    local err = require("support.gh").without(send, "hi")
    assert.matches("isn't on PATH", present(err))
    assert.same({}, fake.calls())
  end)

  it("refuses when rex can't be started", function()
    local err, _, called = require("support.spawns").failing(send, "hi")
    assert.is_true(called)
    assert.truthy(err)
  end)

  it("refuses when rex can't list the session's panes", function()
    fake.set("do", fake.error(1))
    assert.equal("Rex did not list this session's panes", (send("hi")))
  end)

  it("refuses an agent that is at a prompt by the time of the send", function()
    fake.answer("do", fake.panes({ alpha }))
    fake.answer("do", fake.panes({ pane({ block = "b1", app = "alpha", state = "blocked" }) }))
    assert.equal("answer alpha's prompt first", (send("hi")))
    assert.same({}, writes())
  end)

  it("reports an agent that exited before the send as closed", function()
    local exited = pane({ block = "b1", app = "alpha", foreground = { pid = 9, name = "fish" } })
    fake.answer("do", fake.panes({ alpha }))
    fake.answer("do", fake.panes({ exited }))
    assert.equal("alpha closed", (send("hi")))
    assert.same({}, writes())
  end)

  it("reports a pane rex cannot find as closed", function()
    fake.set("do", fake.panes({ alpha }))
    fake.set("api", fake.error(3))
    assert.equal("alpha closed", (send("hi")))
  end)

  it("reports any other failed paste as refused", function()
    fake.set("do", fake.panes({ alpha }))
    fake.set("api", fake.error(1))
    assert.equal("Rex refused the paste", (send("hi")))
  end)

  it("succeeds when only the focus fails", function()
    fake.set("do", fake.panes({ alpha }))
    fake.set("focus", fake.error(3))
    local err, name = send("hi")
    assert.is_nil(err)
    assert.equal("alpha", name)
  end)
end)
