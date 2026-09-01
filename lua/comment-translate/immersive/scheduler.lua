---@brief Immersive translation scheduler.
---
---Owns async coordination only: priority, concurrency, in-flight merging and
---generation-based invalidation. It is the single place immersive mode calls
---the translate facade from. It never builds cache keys itself (the facade
---owns those) and never performs HTTP.
---
---Cancellation is deliberately logical rather than physical: an in-flight curl
---job cannot be cancelled cheaply, so a result is allowed to arrive and is
---then discarded unless it still matches the buffer's generation and the
---target's fingerprint (design.md 6.3).

local M = {}

local translate = require('comment-translate.translate')
local document = require('comment-translate.parser.document')
local virtual_text = require('comment-translate.ui.virtual_text')

---@class ImmersiveWaiter
---@field bufnr integer
---@field target_id string
---@field generation integer
---@field fingerprint string

---@class ImmersiveBufferState
---@field enabled boolean
---@field generation integer
---@field changedtick integer
---@field targets table<string, ImmersiveTarget>
---@field order string[]
---@field rendered table<string, string>
---@field queued table<string, boolean>
---@field failed table<string, integer>
---@field skipped table<string, boolean>

---@type table<integer, ImmersiveBufferState>
local buffers = {}

---@type table<string, { waiters: ImmersiveWaiter[] }>
local inflight = {}

---@type { bufnr: integer, target_id: string, generation: integer, priority: integer, seq: integer }[]
local queue = {}

local active = 0
local seq = 0

---@param bufnr integer
---@return ImmersiveBufferState?
local function state_of(bufnr)
  return buffers[bufnr]
end

---@param bufnr integer
---@return string
local function mode_for(bufnr)
  local config = require('comment-translate.config')
  local immersive = config.config.immersive or {}
  local ft = vim.bo[bufnr].filetype
  local by_ft = immersive.mode_by_filetype or {}
  return by_ft[ft] or immersive.default_mode or 'comment'
end

---@param bufnr integer
local function extract(bufnr)
  local mode = mode_for(bufnr)
  local extract_mode = (vim.bo[bufnr].filetype == 'text') and 'text' or 'markdown'
  if mode ~= 'document' then
    return {}
  end
  return document.extract(bufnr, extract_mode)
end

---@param bufnr integer
---@param state ImmersiveBufferState
local function rebuild_targets(bufnr, state)
  local targets = extract(bufnr)

  local by_id = {}
  local order = {}
  for _, target in ipairs(targets) do
    by_id[target.id] = target
    table.insert(order, target.id)
  end

  -- Drop marks for targets that no longer exist, and for targets whose
  -- content changed. A target that merely moved keeps its rendering, because
  -- the fingerprint excludes the range.
  for id, fingerprint in pairs(state.rendered) do
    local target = by_id[id]
    if not target or target.fingerprint ~= fingerprint then
      virtual_text.clear_target(bufnr, id)
      state.rendered[id] = nil
    end
  end

  -- A skipped target that has since changed or disappeared should not stay
  -- skipped; its replacement is judged on its own length.
  for id, _ in pairs(state.skipped) do
    if not by_id[id] then
      state.skipped[id] = nil
    end
  end

  state.targets = by_id
  state.order = order
  state.changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
end

---@param bufnr integer
---@param target_id string
---@param generation integer
---@param priority integer
local function enqueue(bufnr, target_id, generation, priority)
  seq = seq + 1
  table.insert(queue, {
    bufnr = bufnr,
    target_id = target_id,
    generation = generation,
    priority = priority,
    seq = seq,
  })
end

---@param job table
---@return boolean
local function is_current(job)
  if not vim.api.nvim_buf_is_valid(job.bufnr) then
    return false
  end
  local state = state_of(job.bufnr)
  if not state or not state.enabled then
    return false
  end
  if state.generation ~= job.generation then
    return false
  end
  return state.targets[job.target_id] ~= nil
end

---@param waiter ImmersiveWaiter
---@param result string?
local function deliver(waiter, result)
  if not vim.api.nvim_buf_is_valid(waiter.bufnr) then
    return
  end

  local state = state_of(waiter.bufnr)
  if not state or not state.enabled or state.generation ~= waiter.generation then
    return
  end

  local target = state.targets[waiter.target_id]
  if not target or target.fingerprint ~= waiter.fingerprint then
    return
  end

  if not result or result == '' then
    -- Remember the failure so this generation does not retry in a loop.
    state.failed[waiter.target_id] = state.generation
    return
  end

  virtual_text.show_block(waiter.bufnr, target, result)
  state.rendered[waiter.target_id] = target.fingerprint
end

local pump

---@param job table
local function start_or_join(job)
  local state = state_of(job.bufnr)
  local target = state.targets[job.target_id]

  local request = translate.prepare(target.text, nil, nil, nil)

  local waiter = {
    bufnr = job.bufnr,
    target_id = job.target_id,
    generation = job.generation,
    fingerprint = target.fingerprint,
  }

  local cached = translate.lookup(request)
  if cached then
    state.queued[job.target_id] = nil
    deliver(waiter, cached)
    return
  end

  local entry = inflight[request.key]
  if entry then
    -- Someone is already fetching this exact text/profile; ride along.
    table.insert(entry.waiters, waiter)
    state.queued[job.target_id] = nil
    return
  end

  inflight[request.key] = { waiters = { waiter } }
  active = active + 1

  translate.execute(request, function(result)
    local finished = inflight[request.key]
    inflight[request.key] = nil
    active = active - 1

    if finished then
      for _, w in ipairs(finished.waiters) do
        local st = state_of(w.bufnr)
        if st then
          st.queued[w.target_id] = nil
        end
        deliver(w, result)
      end
    end

    pump()
  end)
end

pump = function()
  local config = require('comment-translate.config')
  local limit = (config.config.immersive or {}).concurrency or 2

  while active < limit and #queue > 0 do
    table.sort(queue, function(a, b)
      if a.priority ~= b.priority then
        return a.priority < b.priority
      end
      return a.seq < b.seq
    end)

    local job = table.remove(queue, 1)

    if is_current(job) then
      start_or_join(job)
    else
      local state = state_of(job.bufnr)
      if state then
        state.queued[job.target_id] = nil
      end
    end
  end
end

---@param bufnr integer
---@param winid? integer
---@return integer, integer
local function viewport_rows(bufnr, winid)
  winid = winid or vim.api.nvim_get_current_win()

  local ok = pcall(vim.api.nvim_win_get_buf, winid)
  if not ok or vim.api.nvim_win_get_buf(winid) ~= bufnr then
    return 0, vim.api.nvim_buf_line_count(bufnr) - 1
  end

  local top = vim.fn.line('w0', winid) - 1
  local bottom = vim.fn.line('w$', winid) - 1
  return top, bottom
end

---@param target ImmersiveTarget
---@param top integer
---@param bottom integer
---@param prefetch integer
---@return integer
local function priority_of(target, top, bottom, prefetch)
  if target.end_row >= top and target.start_row <= bottom then
    return 0
  end
  if target.end_row >= top - prefetch and target.start_row <= bottom + prefetch then
    return 1
  end
  return 2
end

---@param bufnr integer
---@param state ImmersiveBufferState
---@param target_id string
---@return boolean
local function needs_work(state, target_id)
  if state.rendered[target_id] then
    return false
  end
  if state.queued[target_id] then
    return false
  end
  if state.skipped[target_id] then
    return false
  end
  if state.failed[target_id] == state.generation then
    return false
  end
  return true
end

---Targets beyond the configured length are skipped rather than split: cutting
---a paragraph mid-sentence would damage translation coherence, and sending it
---whole risks a provider-side rejection. The user can still translate such a
---block explicitly with the visual replace command.
---@param state ImmersiveBufferState
---@param target ImmersiveTarget
---@return boolean
local function exceeds_length(state, target)
  local config = require('comment-translate.config')
  local limit = (config.config.immersive or {}).max_target_length
  if not limit or limit <= 0 then
    return false
  end

  -- Characters rather than bytes, so CJK text is not penalised.
  if vim.fn.strchars(target.text) <= limit then
    return false
  end

  state.skipped[target.id] = true
  return true
end

---Queue everything not yet rendered, ordered by viewport priority.
---@param bufnr integer
---@param winid? integer
function M.schedule_all(bufnr, winid)
  local state = state_of(bufnr)
  if not state or not state.enabled then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local config = require('comment-translate.config')
  local immersive = config.config.immersive or {}
  local prefetch = immersive.prefetch_lines or 40
  local viewport_only = immersive.viewport ~= false

  local top, bottom = viewport_rows(bufnr, winid)

  for _, id in ipairs(state.order) do
    local target = state.targets[id]
    if target and needs_work(state, id) and not exceeds_length(state, target) then
      local priority = viewport_only and priority_of(target, top, bottom, prefetch) or 0

      -- P2 is everything outside the window and its prefetch band. Those
      -- targets are deliberately *not* queued: they are picked up on a later
      -- pass once the reader scrolls toward them. Queueing them here would
      -- drain the whole document on the first pass and defeat the point of
      -- viewport priority (design.md 6.2).
      if priority < 2 then
        state.queued[id] = true
        enqueue(bufnr, id, state.generation, priority)
      end
    end
  end

  pump()
end

---Schedule only what is currently visible plus the prefetch band.
---@param bufnr integer
---@param winid? integer
function M.ensure_visible(bufnr, winid)
  local state = state_of(bufnr)
  if not state or not state.enabled then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.api.nvim_buf_get_changedtick(bufnr) ~= state.changedtick then
    rebuild_targets(bufnr, state)
  end

  M.schedule_all(bufnr, winid)
end

---@param bufnr integer
function M.enable(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local state = buffers[bufnr]
  if not state then
    state = {
      enabled = true,
      generation = 0,
      changedtick = -1,
      targets = {},
      order = {},
      rendered = {},
      queued = {},
      failed = {},
      skipped = {},
    }
    buffers[bufnr] = state
  end

  state.enabled = true
  state.generation = state.generation + 1
  state.queued = {}
  state.failed = {}
  state.skipped = {}
  rebuild_targets(bufnr, state)
end

---Bump the generation so outstanding results stop being renderable.
---@param bufnr integer
function M.invalidate(bufnr)
  local state = state_of(bufnr)
  if not state then
    return
  end
  state.generation = state.generation + 1
  state.queued = {}
  state.failed = {}
  -- An explicit refresh is the user asking to try again, including for
  -- targets previously skipped or failed.
  state.skipped = {}
end

---Re-extract targets, keeping marks for unchanged content.
---@param bufnr integer
function M.refresh(bufnr)
  local state = state_of(bufnr)
  if not state or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  M.invalidate(bufnr)
  rebuild_targets(bufnr, state)
end

---Drop the completed-cache entry for every target in this buffer, so the next
---schedule refetches them. Used by `:ImmersiveTranslateRefresh!`.
---@param bufnr integer
function M.invalidate_cached(bufnr)
  local state = state_of(bufnr)
  if not state then
    return
  end

  for _, id in ipairs(state.order) do
    local target = state.targets[id]
    if target then
      translate.invalidate(translate.prepare(target.text, nil, nil, nil))
    end
  end
end

---Clear rendered state for targets in the current viewport and requeue them.
---Marks in other buffers, and in-flight requests, are left alone.
---@param bufnr integer
---@param winid? integer
function M.clear_visible(bufnr, winid)
  local state = state_of(bufnr)
  if not state or not state.enabled or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local config = require('comment-translate.config')
  local prefetch = (config.config.immersive or {}).prefetch_lines or 40
  local top, bottom = viewport_rows(bufnr, winid)

  for _, id in ipairs(state.order) do
    local target = state.targets[id]
    if target and priority_of(target, top, bottom, prefetch) == 0 then
      virtual_text.clear_target(bufnr, id)
      state.rendered[id] = nil
    end
  end

  state.generation = state.generation + 1
  state.queued = {}
  state.failed = {}
  state.skipped = {}

  M.schedule_all(bufnr, winid)
end

---@param bufnr integer
local function drop_waiters(bufnr)
  for _, entry in pairs(inflight) do
    local kept = {}
    for _, waiter in ipairs(entry.waiters) do
      if waiter.bufnr ~= bufnr then
        table.insert(kept, waiter)
      end
    end
    -- The entry itself stays even when no waiters remain, so the running
    -- request still resolves and decrements `active`; it simply has nobody
    -- left to render for.
    entry.waiters = kept
  end
end

---@param bufnr integer
function M.disable(bufnr)
  local state = state_of(bufnr)
  if not state then
    return
  end

  state.generation = state.generation + 1
  state.enabled = false

  virtual_text.clear_buf(bufnr)

  local kept = {}
  for _, job in ipairs(queue) do
    if job.bufnr ~= bufnr then
      table.insert(kept, job)
    end
  end
  queue = kept

  drop_waiters(bufnr)

  buffers[bufnr] = nil
end

---@param bufnr integer
---@return boolean
function M.is_enabled(bufnr)
  local state = state_of(bufnr)
  return state ~= nil and state.enabled
end

---@param bufnr integer
---@return integer
function M.rendered_count(bufnr)
  local state = state_of(bufnr)
  if not state then
    return 0
  end
  local n = 0
  for _ in pairs(state.rendered) do
    n = n + 1
  end
  return n
end

---@return integer
function M.active_count()
  return active
end

---@return integer
function M.inflight_count()
  local n = 0
  for _, entry in pairs(inflight) do
    n = n + #entry.waiters
  end
  return n
end

---Drop every scheduler-owned piece of state. Test and teardown helper.
function M.reset()
  for bufnr, _ in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      virtual_text.clear_buf(bufnr)
    end
  end
  buffers = {}
  inflight = {}
  queue = {}
  active = 0
  seq = 0
end

return M
