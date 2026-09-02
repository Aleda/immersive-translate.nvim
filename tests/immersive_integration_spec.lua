---@diagnostic disable: undefined-global
-- End-to-end immersive behaviour — design.md 11.2.
--
-- Drives the real user commands against a displayed buffer with a stubbed
-- provider, so the properties a reader actually notices are covered: the file
-- is never touched, long documents do not drain the API budget, and scrolling
-- fetches what came into view.

describe('immersive integration', function()
  local translate
  local calls
  local ns

  local function setup_plugin(overrides)
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.translate'] = nil
    package.loaded['comment-translate.translate.init'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.parser.document'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil
    package.loaded['comment-translate.immersive.scheduler'] = nil
    package.loaded['comment-translate.immersive.viewport'] = nil
    package.loaded['comment-translate.commands'] = nil

    require('comment-translate.config').setup(overrides)

    require('comment-translate.translate.cache').clear()
    require('comment-translate.immersive.scheduler').reset()

    translate = require('comment-translate.translate')
    calls = 0
    translate.execute = function(request, callback)
      calls = calls + 1
      translate.store(request, '[zh] ' .. request.text)
      callback('[zh] ' .. request.text)
    end
  end

  ---@param count integer
  ---@return integer
  local function show_document(count)
    local lines = {}
    for i = 1, count do
      table.insert(lines, 'Paragraph ' .. i .. ' with a sentence of body text.')
      table.insert(lines, '')
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = 'markdown'

    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
    vim.cmd('normal! zt')

    return bufnr
  end

  local function marks(bufnr)
    return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  end

  before_each(function()
    setup_plugin({
      immersive = { concurrency = 4, prefetch_lines = 10, min_chars = 1 },
      cache = { enabled = true, max_entries = 500 },
    })
    ns = vim.api.nvim_create_namespace('comment_translate_immersive')
  end)

  after_each(function()
    require('comment-translate.immersive.scheduler').reset()
  end)

  describe('viewport budget', function()
    it('should translate far less than a long document on open', function()
      local bufnr = show_document(150)
      local commands = require('comment-translate.commands')

      commands.enable_immersive(bufnr)

      assert.is_true(calls > 0)
      assert.is_true(calls < 150, 'translated ' .. calls .. ' of 150 paragraphs')
    end)

    it('should fetch newly visible paragraphs after scrolling', function()
      local bufnr = show_document(150)
      local commands = require('comment-translate.commands')
      local winid = vim.api.nvim_get_current_win()

      commands.enable_immersive(bufnr)
      local first = calls

      vim.api.nvim_win_set_cursor(winid, { 150, 0 })
      vim.cmd('normal! zt')
      commands.ensure_visible(bufnr, winid)

      assert.is_true(calls > first, 'scrolling fetched nothing new')
      assert.is_true(calls < 150)
    end)
  end)

  describe('rendering', function()
    it('should render blocks below the source, never at end of line', function()
      local bufnr = show_document(4)
      require('comment-translate.commands').enable_immersive(bufnr)

      local all = marks(bufnr)
      assert.is_true(#all > 0)
      for _, mark in ipairs(all) do
        assert.is_table(mark[4].virt_lines)
        assert.is_nil(mark[4].virt_text)
      end
    end)
  end)

  describe('buffer invariants', function()
    it('should leave text, changedtick and modified untouched', function()
      local bufnr = show_document(6)
      local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local before_tick = vim.api.nvim_buf_get_changedtick(bufnr)
      local before_modified = vim.bo[bufnr].modified

      require('comment-translate.commands').enable_immersive(bufnr)

      assert.same(before_lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.equals(before_tick, vim.api.nvim_buf_get_changedtick(bufnr))
      assert.equals(before_modified, vim.bo[bufnr].modified)
    end)
  end)

  describe('teardown', function()
    it('should clear every mark when disabled', function()
      local bufnr = show_document(5)
      local commands = require('comment-translate.commands')

      commands.enable_immersive(bufnr)
      assert.is_true(#marks(bufnr) > 0)

      require('comment-translate.immersive.scheduler').disable(bufnr)

      assert.equals(0, #marks(bufnr))
    end)
  end)
end)
