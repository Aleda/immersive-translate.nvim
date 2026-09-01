---@diagnostic disable: undefined-global
-- Immersive scheduler — design.md 6.
--
-- Uses a fake translator so ordering, concurrency, de-duplication and
-- invalidation are observable without any network access.

describe('immersive.scheduler', function()
  local scheduler
  local config
  local translate
  local cache

  local fake

  ---Install a controllable translator in place of the real facade.
  local function install_fake_translator()
    fake = {
      calls = {},
      pending = {},
    }

    -- Stands in for the provider layer only. The real execute() stores
    -- successful results in the completed cache before invoking the callback,
    -- so the fake must do the same or cache-hit behaviour cannot be observed.
    translate.execute = function(request, callback)
      table.insert(fake.calls, request.text)
      table.insert(fake.pending, {
        request = request,
        callback = function(result)
          if result and result ~= '' then
            translate.store(request, result)
          end
          callback(result)
        end,
      })
    end

    return fake
  end

  ---Resolve the oldest outstanding request.
  local function resolve_next(result)
    local job = table.remove(fake.pending, 1)
    assert.is_not_nil(job)
    job.callback(result or ('translated:' .. job.request.text))
    return job
  end

  local function resolve_all()
    while #fake.pending > 0 do
      resolve_next()
    end
  end

  local function make_buf(count)
    local lines = {}
    for i = 1, count do
      table.insert(lines, 'Paragraph number ' .. i .. ' with some body text.')
      table.insert(lines, '')
    end
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = 'markdown'
    return bufnr
  end

  before_each(function()
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.translate'] = nil
    package.loaded['comment-translate.translate.init'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.parser.document'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil
    package.loaded['comment-translate.immersive.scheduler'] = nil

    config = require('comment-translate.config')
    config.setup({
      immersive = { concurrency = 2, prefetch_lines = 0, min_chars = 1 },
      cache = { enabled = true, max_entries = 100 },
    })

    cache = require('comment-translate.translate.cache')
    cache.clear()

    translate = require('comment-translate.translate')
    install_fake_translator()

    scheduler = require('comment-translate.immersive.scheduler')
    scheduler.reset()
  end)

  after_each(function()
    scheduler.reset()
  end)

  describe('concurrency', function()
    it('should not exceed the configured limit', function()
      local bufnr = make_buf(10)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      assert.equals(2, #fake.pending)
    end)

    it('should start the next job as each completes', function()
      local bufnr = make_buf(5)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      assert.equals(2, #fake.pending)
      resolve_next()
      assert.equals(2, #fake.pending)
    end)

    it('should release its slot when a request fails', function()
      local bufnr = make_buf(5)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      resolve_next(nil)

      -- A failure must not leak the slot.
      assert.equals(2, #fake.pending)
    end)

    it('should drain every target eventually', function()
      local bufnr = make_buf(6)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      resolve_all()

      assert.equals(6, #fake.calls)
      assert.equals(0, scheduler.active_count())
    end)
  end)

  describe('cache', function()
    it('should not request a target already in the completed cache', function()
      local bufnr = make_buf(3)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all()
      local first_round = #fake.calls

      scheduler.disable(bufnr)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      assert.equals(first_round, #fake.calls)
    end)
  end)

  describe('in-flight de-duplication', function()
    it('should issue one request for duplicate text and fan out to both', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'Duplicated paragraph text.',
        '',
        'Duplicated paragraph text.',
      })
      vim.bo[bufnr].filetype = 'markdown'

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      assert.equals(1, #fake.calls)

      resolve_all()

      assert.equals(2, scheduler.rendered_count(bufnr))
    end)
  end)

  describe('generation invalidation', function()
    it('should discard a result whose generation is stale', function()
      local bufnr = make_buf(3)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      local job = table.remove(fake.pending, 1)
      scheduler.invalidate(bufnr)
      job.callback('late result')

      assert.equals(0, scheduler.rendered_count(bufnr))
    end)

    it('should discard results after disable', function()
      local bufnr = make_buf(3)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      local job = table.remove(fake.pending, 1)
      scheduler.disable(bufnr)
      job.callback('late result')

      assert.equals(0, scheduler.rendered_count(bufnr))
    end)

    it('should discard results for a wiped buffer', function()
      local bufnr = make_buf(3)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      local job = table.remove(fake.pending, 1)
      vim.api.nvim_buf_delete(bufnr, { force = true })

      assert.has_no.errors(function()
        job.callback('late result')
      end)
    end)

    it('should release the slot even when the result is stale', function()
      local bufnr = make_buf(6)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      local job = table.remove(fake.pending, 1)
      scheduler.invalidate(bufnr)
      job.callback('late result')

      assert.is_true(scheduler.active_count() < 2)
    end)
  end)

  describe('failure handling', function()
    it('should not retry a failed target in the same generation', function()
      local bufnr = make_buf(2)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      resolve_next(nil)
      local after_failure = #fake.calls

      scheduler.schedule_all(bufnr)

      assert.equals(after_failure, #fake.calls)
    end)
  end)

  describe('teardown', function()
    it('should drop all state for a disabled buffer', function()
      local bufnr = make_buf(3)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all()

      scheduler.disable(bufnr)

      assert.is_false(scheduler.is_enabled(bufnr))
      assert.equals(0, scheduler.rendered_count(bufnr))
    end)

    it('should remove waiters belonging to a disabled buffer', function()
      local bufnr = make_buf(4)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      scheduler.disable(bufnr)
      resolve_all()

      assert.equals(0, scheduler.inflight_count())
    end)
  end)

  describe('rendering', function()
    it('should render each completed target once', function()
      local bufnr = make_buf(4)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all()

      assert.equals(4, scheduler.rendered_count(bufnr))
    end)

    it('should not modify the buffer', function()
      local bufnr = make_buf(4)
      local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local tick = vim.api.nvim_buf_get_changedtick(bufnr)

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all()

      assert.same(before, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.equals(tick, vim.api.nvim_buf_get_changedtick(bufnr))
    end)
  end)

  describe('line drift', function()
    it('should not re-request targets after an edit above them', function()
      local bufnr = make_buf(4)
      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all()
      local before = #fake.calls

      -- Insert a line at the very top: every target below shifts down.
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { 'Newly inserted heading line' })
      scheduler.refresh(bufnr)
      scheduler.schedule_all(bufnr)

      -- Only the new paragraph may be requested; existing content is cached
      -- because the fingerprint excludes the range.
      assert.is_true(#fake.calls - before <= 1)
    end)
  end)
end)
