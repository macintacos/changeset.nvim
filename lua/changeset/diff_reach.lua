---Which files the unified diff reaches: none, the files entered, or all of them, less those closed by hand.
---It decides; `changeset.unified_diff` opens and closes the views.

local M = {}

---How far the diff reaches, narrowest first.
---@alias changeset.DiffReach.Level "off"|"entered"|"all"

---What `unified_diff.keep` keeps once the sidebar closes.
---@alias changeset.DiffReach.Keep "none"|"entered"|"all"

---@type table<changeset.DiffReach.Level, integer>
local RANK = { off = 0, entered = 1, all = 2 }

---@type table<changeset.DiffReach.Keep, changeset.DiffReach.Level>
local KEPT = { none = "off", entered = "entered", all = "all" }

---@class changeset.DiffReach
---@field private level changeset.DiffReach.Level
---@field private entered_files table<string, true> Every file entered this session, by absolute path.
---@field private hand_closed table<string, true?> Files whose view the user closed since the diff last turned on.
local DiffReach = {}
DiffReach.__index = DiffReach

---A reach for a new session: off, nothing entered or closed.
---@return changeset.DiffReach
function M.new()
  return setmetatable({ level = "off", entered_files = {}, hand_closed = {} }, DiffReach)
end

---Reach every file, those closed by hand included.
function DiffReach:turn_on()
  self.level, self.hand_closed = "all", {}
end

---Reach no further than `keep` says, never further than now.
---@param keep changeset.DiffReach.Keep
function DiffReach:limit(keep)
  if RANK[KEPT[keep]] < RANK[self.level] then
    self.level = KEPT[keep]
  end
end

---Note that the user entered the file at `path`, for the rest of the session.
---@param path string Absolute.
---@return boolean new Whether it was not entered before.
function DiffReach:enter(path)
  local new = not self.entered_files[path]
  self.entered_files[path] = true
  return new
end

---Stop reaching the file at `path`, whose view the user closed, until the diff next turns on.
---@param path string Absolute.
function DiffReach:hand_close(path)
  self.hand_closed[path] = true
end

---Whether the diff reaches the file at `path`.
---@param path string Absolute.
---@return boolean
function DiffReach:allows(path)
  if self.hand_closed[path] then
    return false
  end
  return self.level == "all" or (self.level == "entered" and self.entered_files[path] == true)
end

---Whether the diff reaches any file at all.
---@return boolean
function DiffReach:on()
  return self.level ~= "off"
end

return M
