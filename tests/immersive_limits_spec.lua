---@diagnostic disable: undefined-global
-- Stabilization behaviour — design.md 10.1 (errors) and 10.2 (budgets).

describe('immersive limits and errors', function()
  local scheduler
  local config
  local translate
  local cache

  local fake

  local function install_fake_translator()
    fake = { calls = {}, pending = {} }

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
  end

  ---Resolve every outstanding request. Pass fail=true to simulate provider
  ---failure; `nil` alone cannot express that, since a nil result would be
  ---indistinguishable from "use the default success value".
  local function resolve_all(fail)
    while #fake.pending > 0 do
      local job = table.remove(fake.pending, 1)
      if fail then
        job.callback(nil)
      else
        job.callback('t:' .. job.request.text)
      end
    end
  end

  local function make_buf(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = 'markdown'
    return bufnr
  end

  ---A buffer that is actually displayed, so w0/w$ report a real viewport.
  ---A buffer shown in no window has no viewport, and the scheduler then
  ---correctly falls back to treating the whole buffer as visible.
  local function make_visible_buf(lines)
    local bufnr = make_buf(lines)
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 1, 0 })
    vim.cmd('normal! zt')
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

  describe('max_target_length', function()
    it('should not send a target longer than the limit', function()
      config.setup({
        immersive = { concurrency = 2, prefetch_lines = 0, min_chars = 1, max_target_length = 40 },
      })

      local bufnr = make_buf({
        string.rep('long ', 40),
        '',
        'short enough',
      })

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      assert.equals(1, #fake.calls)
      assert.equals('short enough', fake.calls[1])
    end)

    it('should measure length in characters, not bytes', function()
      config.setup({
        immersive = { concurrency = 2, prefetch_lines = 0, min_chars = 1, max_target_length = 10 },
      })

      -- 6 CJK characters: well under 10 chars but over 10 bytes.
      local bufnr = make_buf({ '中文段落文本' })

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      assert.equals(1, #fake.calls)
    end)

    it('should leave an oversized target unrendered', function()
      config.setup({
        immersive = { concurrency = 2, prefetch_lines = 0, min_chars = 1, max_target_length = 20 },
      })

      local bufnr = make_buf({ string.rep('word ', 30) })

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all()

      assert.equals(0, scheduler.rendered_count(bufnr))
    end)

    it('should not re-queue an oversized target on every pass', function()
      config.setup({
        immersive = { concurrency = 2, prefetch_lines = 0, min_chars = 1, max_target_length = 20 },
      })

      local bufnr = make_buf({ string.rep('word ', 30) })

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      scheduler.schedule_all(bufnr)
      scheduler.schedule_all(bufnr)

      assert.equals(0, #fake.calls)
    end)
  end)

  describe('failure containment', function()
    it('should not retry a failed target within the same generation', function()
      local bufnr = make_buf({ 'one paragraph', '', 'two paragraph' })

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all(true)

      local after = #fake.calls
      scheduler.schedule_all(bufnr)

      assert.equals(after, #fake.calls)
    end)

    it('should allow a retry after an explicit refresh', function()
      local bufnr = make_buf({ 'one paragraph' })

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all(true)
      local after_failure = #fake.calls

      scheduler.refresh(bufnr)
      scheduler.schedule_all(bufnr)

      assert.is_true(#fake.calls > after_failure)
    end)
  end)

  describe('viewport budget', function()
    it('should not translate the whole document when viewport mode is on', function()
      -- P2 targets exist only so they can be promoted when the reader scrolls
      -- to them. Draining them immediately would spend the API budget on text
      -- nobody is looking at, which is the behaviour this mode exists to
      -- avoid (design.md 6.2, 10.2).
      config.setup({
        immersive = { concurrency = 2, prefetch_lines = 0, viewport = true, min_chars = 1 },
      })

      local lines = {}
      for i = 1, 120 do
        table.insert(lines, 'Paragraph ' .. i .. ' with body text.')
        table.insert(lines, '')
      end
      local bufnr = make_visible_buf(lines)

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all()

      assert.is_true(#fake.calls > 0)
      assert.is_true(#fake.calls < 120)
    end)

    it('should translate everything when viewport mode is off', function()
      config.setup({
        immersive = { concurrency = 2, viewport = false, min_chars = 1 },
      })

      local bufnr = make_buf({ 'One para.', '', 'Two para.', '', 'Three para.' })

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all()

      assert.equals(3, #fake.calls)
    end)

    it('should pick up newly visible targets on a later pass', function()
      config.setup({
        immersive = { concurrency = 2, prefetch_lines = 0, viewport = true, min_chars = 1 },
      })

      local lines = {}
      for i = 1, 60 do
        table.insert(lines, 'Paragraph ' .. i .. ' with body text.')
        table.insert(lines, '')
      end
      local bufnr = make_visible_buf(lines)

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)
      resolve_all()
      local first = #fake.calls

      -- Widening the prefetch band stands in for scrolling: more targets
      -- become eligible and must be queued on the next pass.
      config.setup({
        immersive = { concurrency = 2, prefetch_lines = 400, viewport = true, min_chars = 1 },
      })
      scheduler.schedule_all(bufnr)
      resolve_all()

      assert.is_true(#fake.calls > first)
    end)
  end)

  describe('privacy', function()
    it('should never place source text in a cache key', function()
      local secret = 'a confidential sentence that must not appear'
      local request = translate.prepare(secret, 'zh-CN', 'en')

      assert.is_nil(request.key:find('confidential', 1, true))
    end)
  end)
end)
