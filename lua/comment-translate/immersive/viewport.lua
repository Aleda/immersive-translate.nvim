---@brief Scroll-event filtering for immersive mode.
---
---Rendering a translation inserts screen lines and pushes following content
---down, which changes the window's botline and fires WinScrolled again. If
---every such event rescheduled, each render would pull further paragraphs
---into view and the viewport priority in the scheduler would collapse into
---translating the whole document.
---
---The discriminator is topline: rendering below the cursor moves botline but
---never topline, while a genuine user scroll always moves topline. See
---design.md 6.3.

local M = {}

---@type table<integer, integer>
local last_topline = {}

---Should a scroll event for this window trigger rescheduling?
---@param winid integer
---@param topline integer  buffer line at the top of the window
---@return boolean
function M.should_reschedule(winid, topline)
  if last_topline[winid] == topline then
    return false
  end
  last_topline[winid] = topline
  return true
end

---Forget a window, e.g. on WinClosed. Without this the table grows for the
---lifetime of the session as windows open and close.
---@param winid integer
function M.forget(winid)
  last_topline[winid] = nil
end

---@return integer
function M.tracked_count()
  local n = 0
  for _ in pairs(last_topline) do
    n = n + 1
  end
  return n
end

function M.reset()
  last_topline = {}
end

return M
