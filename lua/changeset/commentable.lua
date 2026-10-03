---Which new-side lines of a pull request's file GitHub takes a review comment on.

local M = {}

-- Keep in sync with doc/agents/github-reviews.md, "Lines a review comment accepts".
---@param hunk changeset.Hunk
---@param lnum integer
---@return boolean
local function near(hunk, lnum)
  if hunk.count == 0 then
    return hunk.lnum - 2 <= lnum and lnum <= hunk.lnum + 3
  end
  return hunk.lnum - 3 <= lnum and lnum <= hunk.lnum + hunk.count + 2
end

---@param hunks changeset.Hunk[]
---@param lnum integer
---@return boolean
local function in_diff(hunks, lnum)
  for _, hunk in ipairs(hunks) do
    if near(hunk, lnum) then
      return true
    end
  end
  return false
end

---Whether GitHub takes a review comment on `range` of a file, and why not when it won't.
---@param hunks changeset.Hunk[] The file's hunks, the PR's base against its head, as `diff.lua` parses them.
---@param range { [1]: integer, [2]: integer } First and last new-side line, inclusive; equal for one line.
---@param matches_head boolean Whether the file on disk matches the PR's pushed head.
---@return boolean ok
---@return string? reason Why GitHub would refuse, when not ok.
function M.check(hunks, range, matches_head)
  if not matches_head then
    return false, "the file differs from the PR's head: save, push, or pull first"
  end
  for _, lnum in ipairs(range) do
    if not in_diff(hunks, lnum) then
      return false, ("line %d is outside the PR's diff, so GitHub won't take a comment there"):format(lnum)
    end
  end
  return true
end

return M
