---Where the user stands in the tree: you are here, the pick, the landing, and a restored position until it settles.
---It decides where the sidebar's cursor goes and which line wears each mark; the caller hands it the sidebar and acts.

local Rows = require("changeset.rows")

local M = {}

---What the position reads of the sidebar.
---@class changeset.position.View
---@field rows changeset.Row[] The tree, uncompressed.
---@field visible changeset.Row[] The row on each line of the sidebar's buffer.
---@field cursor integer? The sidebar's cursor line; nil while no window shows the sidebar.
---@field focused boolean Whether the sidebar has focus.

---What a session saved of where you were: the file you were in and the sidebar's cursor row.
---@class changeset.position.Saved
---@field here changeset.Spot? The file and line you were in.
---@field row { id: string, path: string }? The row the sidebar's cursor was on.

---@class changeset.position.Restoring : changeset.position.Saved
---@field at string? Id of the row under the sidebar's cursor when last checked; another means the user moved it.

---A line wearing one of the row marks.
---@class changeset.position.Mark
---@field kind "selected"|"here"|"picked"
---@field lnum integer

---@class changeset.Position
---@field private here changeset.Spot? Where the cursor is, while that is a file in this repository.
---@field private picked changeset.Picked? The row last opened from the sidebar.
---@field private landing { id: string? }? Where focusing the sidebar put its cursor, until the user moves it; a nil id landed before the tree had rows.
---@field private restoring changeset.position.Restoring? A restored position, until the tree can hold each half.
local Position = {}
Position.__index = Position

---A position for a new tree: nowhere yet, nothing picked.
---@return changeset.Position
function M.new()
  return setmetatable({}, Position)
end

---The line showing the row with `id`, or else its deepest ancestor on screen.
---
---A row id extends its parent's by a `\0`-joined segment, so a row folded away,
---filtered out, or hidden inside a compressed chain (whose line carries the head's
---id) is stood in for by whichever of its ancestors is showing.
---@param visible changeset.Row[]
---@param id string
---@return integer? lnum nil when nothing on screen is related.
local function nearest(visible, id)
  local best, best_len = nil, 0
  for lnum, row in ipairs(visible) do
    local shown = row.id
    if #shown > best_len and vim.startswith(id, shown) and (#id == #shown or id:byte(#shown + 1) == 0) then
      best, best_len = lnum, #shown
    end
  end
  return best
end

---Id of the row on line `lnum`.
---@param visible changeset.Row[]
---@param lnum integer?
---@return string?
local function id_at(visible, lnum)
  local row = lnum and visible[lnum]
  return row and row.id or nil
end

---Stop waiting to restore one half of a restored position.
---@private
---@param half "here"|"row"
function Position:release(half)
  local wanted = self.restoring
  if wanted then
    wanted[half] = nil
    if not (wanted.here or wanted.row) then
      self.restoring = nil
    end
  end
end

---Land on you are here, or its nearest ancestor on screen, and note the row the cursor ends on.
---@private
---@param view changeset.position.View
---@return integer? lnum nil leaves the cursor where it is.
function Position:land(view)
  local here = self.here
  local row = here and Rows.locate(view.rows, here.path, here.lnum)
  local lnum = row and nearest(view.visible, row.id)
  self.landing = { id = id_at(view.visible, lnum or view.cursor) }
  return lnum
end

---Apply each half of the restored position whose file is decided, dropping a half the tree no longer holds,
---then note the row the cursor ends on.
---@private
---@param view changeset.position.View
---@param decided fun(path: string, id: string?): boolean
---@param lnum integer? Where the cursor is already going.
---@return integer? lnum
function Position:settle(view, decided, lnum)
  local wanted = self.restoring
  if wanted and wanted.here and decided(wanted.here.path) then
    if Rows.locate(view.rows, wanted.here.path, wanted.here.lnum) then
      self.here = wanted.here
    end
    self:release("here")
  end
  if wanted and wanted.row and decided(wanted.row.path, wanted.row.id) then
    local restored = view.cursor and Rows.find(view.rows, wanted.row.id) and nearest(view.visible, wanted.row.id)
    if restored then
      lnum = restored
      -- Else a pending landing's follow would pull the cursor back off it.
      self.landing = nil
    end
    self:release("row")
  end
  if self.restoring then
    self.restoring.at = id_at(view.visible, lnum or view.cursor)
  end
  return lnum
end

---Note where the cursor is, which lets go of a restored "you are here".
---@param spot changeset.Spot? nil while the cursor is in no file of this repository.
function Position:track(spot)
  self.here = spot
  self:release("here")
end

---Make `row` the pick. A folded chain is recorded by its tip, the symbol it jumps to.
---@param row changeset.Row
function Position:pick(row)
  self.picked = { id = row.tip or row.id, path = row.path, lnum = row.lnum or 1 }
end

---The sidebar was entered: land on you are here, letting go of a restored row still waiting.
---@param view changeset.position.View
---@return integer? lnum The line to put the sidebar's cursor on; nil leaves it.
function Position:entered(view)
  self:release("row")
  return self:land(view)
end

---The tree's rows were rebuilt and drawn. A pending landing follows you deeper, and a restored position whose
---file is now decided is applied over it, unless the cursor moved off them since or focus left the sidebar.
---@param view changeset.position.View As drawn from the rebuilt rows.
---@param before string? Id of the row under the sidebar's cursor before the rows changed.
---@param decided fun(path: string, id: string?): boolean Whether the tree is done growing under `path` or row `id`.
---@return integer? lnum The line to put the sidebar's cursor on; nil leaves it.
function Position:rebuilt(view, before, decided)
  -- Before the first diff the landing and the row under the cursor are both nil, which is still "not moved".
  -- Only a rebuild follows: a fold or filter redraw brings no deeper row.
  local follow = self.landing and view.focused and self.landing.id == before
  if self.restoring and view.focused and self.restoring.at ~= before then
    self:release("row")
  end
  local lnum
  if follow then
    lnum = self:land(view)
  else
    self.landing = nil
  end
  -- After the landing: a restored row overrides it.
  return self:settle(view, decided, lnum)
end

---The parts of a recorded position shaped as `saved` writes them.
---@param value any
---@return changeset.position.Restoring?
local function recorded(value)
  if type(value) ~= "table" then
    return nil
  end
  local here, row = value.here, value.row
  here = type(here) == "table" and type(here.path) == "string" and type(here.lnum) == "number" and here or nil
  row = type(row) == "table" and type(row.id) == "string" and type(row.path) == "string" and row or nil
  return (here or row) and { here = here, row = row } or nil
end

---Take up the position a saved session recorded, applying each half once the tree has decided its file.
---@param value any The recorded position, decoded; anything not shaped as `saved` writes it is ignored.
---@param view changeset.position.View
---@param decided fun(path: string, id: string?): boolean Whether the tree is done growing under `path` or row `id`.
---@return integer? lnum The line to put the sidebar's cursor on; nil leaves it.
function Position:restore(value, view, decided)
  self.restoring = recorded(value)
  return self:settle(view, decided)
end

---GitHub answered about the tree's PR, which can decide a restored Comments row.
---@param view changeset.position.View
---@param decided fun(path: string, id: string?): boolean Whether the tree is done growing under `path` or row `id`.
---@return integer? lnum The line to put the sidebar's cursor on; nil leaves it.
function Position:answered(view, decided)
  return self:settle(view, decided)
end

---The diff could not be read, so nothing would ever settle a restored position.
function Position:failed()
  self.restoring = nil
end

---The line each mark goes on: the selected row while the sidebar has focus, you are here, and the pick, the
---last two on their nearest ancestor on screen. A line several would mark shows the first of those.
---@param view changeset.position.View
---@return changeset.position.Mark[]
function Position:marks(view)
  local here, picked = self.here, self.picked
  local here_row = here and Rows.locate(view.rows, here.path, here.lnum)
  local picked_row = picked and Rows.relocate(view.rows, picked)
  local candidates = {
    { "selected", view.focused and id_at(view.visible, view.cursor) and view.cursor },
    { "here", here_row and nearest(view.visible, here_row.id) },
    { "picked", picked_row and nearest(view.visible, picked_row.id) },
  }
  local marks, taken = {}, {}
  for _, candidate in ipairs(candidates) do
    local kind, lnum = candidate[1], candidate[2]
    if lnum and not taken[lnum] then
      taken[lnum] = true
      table.insert(marks, { kind = kind, lnum = lnum })
    end
  end
  return marks
end

---What a session should save of where you are; nil while a restored position waits, since the half-built tree's
---would replace it.
---@param row changeset.Row? The row under the sidebar's cursor.
---@return changeset.position.Saved?
function Position:saved(row)
  if not self.restoring then
    return { here = self.here, row = row and { id = row.id, path = row.path } }
  end
end

return M
