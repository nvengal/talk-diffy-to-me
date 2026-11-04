local M = {}

---@param count integer rows to search
---@param size integer rows a match spans
---@param near integer row the match was last seen at
---@param matches_at fun(first: integer): boolean
---@return integer? first the matching start row nearest to `near`
function M.nearest(count, size, near, matches_at)
  local best
  for first = 1, count - size + 1 do
    if (not best or math.abs(first - near) < math.abs(best - near)) and matches_at(first) then
      best = first
    end
  end
  return best
end

return M
