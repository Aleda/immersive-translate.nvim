---@diagnostic disable: undefined-global
-- Block renderer — design.md 7.
--
-- Translations live only in the display layer: extmarks in a private
-- namespace, anchored to the last row of a target. Nothing here may modify
-- buffer text, changedtick or undo history.

describe('ui.virtual_text block rendering', function()
  local virtual_text
  local config
  local ns_id

  local function make_buf(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  local function target(id, start_row, end_row, kind)
    return {
      id = id,
      kind = kind or 'paragraph',
      start_row = start_row,
      end_row = end_row,
      text = 'source',
      fingerprint = 'fp-' .. id,
    }
  end

  local function marks(bufnr)
    return vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
  end

  before_each(function()
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil

    config = require('comment-translate.config')
    config.setup({})
    virtual_text = require('comment-translate.ui.virtual_text')
    virtual_text.clear_all()

    ns_id = vim.api.nvim_create_namespace('comment_translate_immersive')
  end)

  describe('show_block', function()
    it('should place the translation in virt_lines, not at end of line', function()
      local bufnr = make_buf({ 'line one', 'line two' })

      virtual_text.show_block(bufnr, target('a', 0, 1), '译文')

      local all = marks(bufnr)
      assert.equals(1, #all)
      local details = all[1][4]
      assert.is_table(details.virt_lines)
      assert.equals(1, #details.virt_lines)
      assert.is_nil(details.virt_text)
    end)

    it('should anchor the block at end_row', function()
      local bufnr = make_buf({ 'a', 'b', 'c' })

      virtual_text.show_block(bufnr, target('a', 0, 2), '译文')

      local all = marks(bufnr)
      assert.equals(2, all[1][2])
    end)

    it('should render each source line of the translation', function()
      local bufnr = make_buf({ 'line' })

      virtual_text.show_block(bufnr, target('a', 0, 0), 'first\nsecond\nthird')

      local details = marks(bufnr)[1][4]
      assert.equals(3, #details.virt_lines)
    end)

    it('should place the block below the source', function()
      local bufnr = make_buf({ 'line' })

      virtual_text.show_block(bufnr, target('a', 0, 0), '译文')

      local details = marks(bufnr)[1][4]
      assert.is_not_true(details.virt_lines_above)
    end)

    it('should use the configured highlight group', function()
      config.setup({ immersive = { render = { hl_group = 'DiagnosticHint' } } })
      package.loaded['comment-translate.ui.virtual_text'] = nil
      virtual_text = require('comment-translate.ui.virtual_text')

      local bufnr = make_buf({ 'line' })
      virtual_text.show_block(bufnr, target('a', 0, 0), '译文')

      local details = marks(bufnr)[1][4]
      assert.equals('DiagnosticHint', details.virt_lines[1][1][2])
    end)

    it('should apply the configured prefix', function()
      config.setup({ immersive = { render = { prefix = '▍' } } })
      package.loaded['comment-translate.ui.virtual_text'] = nil
      virtual_text = require('comment-translate.ui.virtual_text')

      local bufnr = make_buf({ 'line' })
      virtual_text.show_block(bufnr, target('a', 0, 0), '译文')

      local details = marks(bufnr)[1][4]
      assert.equals('▍译文', details.virt_lines[1][1][1])
    end)

    it('should ignore empty translations', function()
      local bufnr = make_buf({ 'line' })

      virtual_text.show_block(bufnr, target('a', 0, 0), '')

      assert.equals(0, #marks(bufnr))
    end)

    it('should be a no-op for an invalid buffer', function()
      local bufnr = make_buf({ 'line' })
      vim.api.nvim_buf_delete(bufnr, { force = true })

      assert.has_no.errors(function()
        virtual_text.show_block(bufnr, target('a', 0, 0), '译文')
      end)
    end)

    it('should clamp an out-of-range anchor row', function()
      local bufnr = make_buf({ 'only line' })

      assert.has_no.errors(function()
        virtual_text.show_block(bufnr, target('a', 0, 99), '译文')
      end)
      assert.equals(1, #marks(bufnr))
    end)
  end)

  describe('wrapping', function()
    -- virt_lines never soft-wrap: anything wider than the window is clipped
    -- and simply unreadable, so the renderer must wrap the text itself.
    it('should split a long translation across several virt_lines', function()
      local bufnr = make_buf({ 'source' })
      local long = string.rep('word ', 120)

      virtual_text.show_block(bufnr, target('a', 0, 0), long)

      local details = marks(bufnr)[1][4]
      assert.is_true(#details.virt_lines > 1, 'long text was not wrapped')
    end)

    it('should keep every rendered line within the window width', function()
      local bufnr = make_buf({ 'source' })
      local width = vim.api.nvim_win_get_width(0)

      virtual_text.show_block(bufnr, target('a', 0, 0), string.rep('word ', 120))

      for _, vline in ipairs(marks(bufnr)[1][4].virt_lines) do
        assert.is_true(vim.fn.strdisplaywidth(vline[1][1]) <= width)
      end
    end)

    it('should wrap CJK text on display width, not byte length', function()
      local bufnr = make_buf({ 'source' })
      local width = vim.api.nvim_win_get_width(0)

      virtual_text.show_block(bufnr, target('a', 0, 0), string.rep('中文段落', 60))

      for _, vline in ipairs(marks(bufnr)[1][4].virt_lines) do
        assert.is_true(vim.fn.strdisplaywidth(vline[1][1]) <= width)
      end
    end)

    it('should not split a short translation', function()
      local bufnr = make_buf({ 'source' })

      virtual_text.show_block(bufnr, target('a', 0, 0), '短译文')

      assert.equals(1, #marks(bufnr)[1][4].virt_lines)
    end)

    it('should preserve explicit newlines as separate lines', function()
      local bufnr = make_buf({ 'source' })

      virtual_text.show_block(bufnr, target('a', 0, 0), 'first\nsecond')

      assert.equals(2, #marks(bufnr)[1][4].virt_lines)
    end)

    it('should not lose any words when wrapping', function()
      local bufnr = make_buf({ 'source' })
      local words = {}
      for i = 1, 80 do
        table.insert(words, 'w' .. i)
      end
      local text = table.concat(words, ' ')

      virtual_text.show_block(bufnr, target('a', 0, 0), text)

      local joined = {}
      for _, vline in ipairs(marks(bufnr)[1][4].virt_lines) do
        table.insert(joined, vline[1][1])
      end
      local rebuilt = table.concat(joined, ' ')
      for _, w in ipairs(words) do
        assert.is_not_nil(rebuilt:find('%f[%w]' .. w .. '%f[%W]'), 'lost ' .. w)
      end
    end)
  end)

  describe('target id tracking', function()
    it('should keep distinct targets from overwriting each other', function()
      local bufnr = make_buf({ 'a', 'b' })

      virtual_text.show_block(bufnr, target('first', 0, 0), '译文一')
      virtual_text.show_block(bufnr, target('second', 1, 1), '译文二')

      assert.equals(2, #marks(bufnr))
    end)

    it('should keep two targets sharing an anchor row distinct', function()
      -- The old line-keyed tracking collapsed these into one mark.
      local bufnr = make_buf({ 'a' })

      virtual_text.show_block(bufnr, target('x', 0, 0), 'first')
      virtual_text.show_block(bufnr, target('y', 0, 0), 'second')

      assert.equals(2, #marks(bufnr))
    end)

    it('should replace the mark when the same target renders again', function()
      local bufnr = make_buf({ 'a' })

      virtual_text.show_block(bufnr, target('same', 0, 0), 'first')
      virtual_text.show_block(bufnr, target('same', 0, 0), 'second')

      local all = marks(bufnr)
      assert.equals(1, #all)
      assert.equals('second', all[1][4].virt_lines[1][1][1])
    end)
  end)

  describe('clear_target', function()
    it('should remove only the named target', function()
      local bufnr = make_buf({ 'a', 'b' })
      virtual_text.show_block(bufnr, target('keep', 0, 0), 'one')
      virtual_text.show_block(bufnr, target('drop', 1, 1), 'two')

      virtual_text.clear_target(bufnr, 'drop')

      local all = marks(bufnr)
      assert.equals(1, #all)
      assert.equals('one', all[1][4].virt_lines[1][1][1])
    end)

    it('should tolerate an unknown target id', function()
      local bufnr = make_buf({ 'a' })

      assert.has_no.errors(function()
        virtual_text.clear_target(bufnr, 'never-rendered')
      end)
    end)
  end)

  describe('buffer invariants', function()
    it('should not modify buffer text or changedtick', function()
      local bufnr = make_buf({ 'alpha', 'beta', 'gamma' })
      local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local before_tick = vim.api.nvim_buf_get_changedtick(bufnr)

      virtual_text.show_block(bufnr, target('a', 0, 0), '译文一')
      virtual_text.show_block(bufnr, target('b', 1, 2), '译文二')
      virtual_text.clear_target(bufnr, 'a')
      virtual_text.clear_buf(bufnr)

      assert.same(before_lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.equals(before_tick, vim.api.nvim_buf_get_changedtick(bufnr))
      assert.is_false(vim.bo[bufnr].modified)
    end)
  end)

  describe('clear_buf', function()
    it('should drop every mark and its tracking state', function()
      local bufnr = make_buf({ 'a', 'b' })
      virtual_text.show_block(bufnr, target('one', 0, 0), 'x')
      virtual_text.show_block(bufnr, target('two', 1, 1), 'y')

      virtual_text.clear_buf(bufnr)

      assert.equals(0, #marks(bufnr))

      -- Re-rendering the same ids must work after a clear.
      virtual_text.show_block(bufnr, target('one', 0, 0), 'x')
      assert.equals(1, #marks(bufnr))
    end)
  end)

  describe('legacy show_inline', function()
    it('should still render for the comment path', function()
      local bufnr = make_buf({ 'code line' })

      virtual_text.show(bufnr, 0, 'translated')

      local all = marks(bufnr)
      assert.equals(1, #all)
      assert.is_table(all[1][4].virt_text)
    end)
  end)
end)
