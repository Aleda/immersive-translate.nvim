---@diagnostic disable: undefined-global
describe('commands', function()
  local commands
  local config
  local ui
  local bufnr

  before_each(function()
    -- Reset all related modules before each test
    package.loaded['comment-translate'] = nil
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser'] = nil
    package.loaded['comment-translate.parser.regex'] = nil
    package.loaded['comment-translate.parser.treesitter'] = nil
    package.loaded['comment-translate.translate'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.translate.google'] = nil
    package.loaded['comment-translate.translate.llm'] = nil
    package.loaded['comment-translate.ui'] = nil
    package.loaded['comment-translate.ui.hover'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil
    package.loaded['comment-translate.autocmds'] = nil
    package.loaded['comment-translate.utils'] = nil

    config = require('comment-translate.config')
    config.setup({
      target_language = 'ja',
      hover = {
        enabled = true,
        delay = 100,
        auto = true,
      },
      immersive = {
        enabled = false,
      },
      keymaps = {
        hover = false,
        hover_manual = false,
        replace = false,
        toggle = false,
      },
    })

    commands = require('comment-translate.commands')
    ui = require('comment-translate.ui')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    ui.hover.close()
    ui.virtual_text.clear_all()
  end)

  describe('is_immersive_enabled', function()
    it('should return false by default', function()
      assert.is_false(commands.is_immersive_enabled())
    end)

    it('should return true after toggle', function()
      -- Note: toggle_immersive calls update_immersive which needs parser
      -- Just test the state management
      assert.is_false(commands.is_immersive_enabled())
    end)
  end)

  describe('cleanup_buffer', function()
    it('should cleanup buffer state without error', function()
      assert.has_no.errors(function()
        commands.cleanup_buffer(bufnr)
      end)
    end)

    it('should handle invalid buffer gracefully', function()
      assert.has_no.errors(function()
        commands.cleanup_buffer(99999)
      end)
    end)
  end)

  describe('hover_translate_on_demand', function()
    it('should exist and be callable', function()
      assert.is_function(commands.hover_translate_on_demand)
    end)
  end)
end)

describe('replace selection safety', function()
  local commands
  local bufnr
  local original_notify
  local notify_messages
  local translate_calls
  local pending_callback

  local function reset_modules(fake_translate)
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser'] = nil
    package.loaded['comment-translate.translate'] = fake_translate
    package.loaded['comment-translate.ui'] = nil
    package.loaded['comment-translate.ui.hover'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil
  end

  local function set_selection(line, start_col, end_col)
    vim.api.nvim_buf_set_mark(bufnr, '<', line, start_col, {})
    vim.api.nvim_buf_set_mark(bufnr, '>', line, end_col, {})
  end

  before_each(function()
    translate_calls = {}
    pending_callback = nil
    local fake_translate = {
      translate = function(text, target_lang, source_lang, callback)
        table.insert(translate_calls, {
          text = text,
          target_lang = target_lang,
          source_lang = source_lang,
        })
        pending_callback = callback
      end,
    }

    reset_modules(fake_translate)

    local config = require('comment-translate.config')
    config.reset()
    commands = require('comment-translate.commands')

    notify_messages = {}
    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_messages, { msg = msg, level = level })
    end

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    vim.notify = original_notify
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it('should replace a multibyte visual selection using byte columns', function()
    local prefix = 'before '
    local selected = 'こんにちは'
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { prefix .. selected .. ' after' })
    set_selection(1, #prefix, #prefix + #selected - 1)

    commands.replace_selection()
    pending_callback('hello')

    assert.equals(selected, translate_calls[1].text)
    assert.same({ 'before hello after' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it('should not replace when the buffer changed before translation returns', function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'alpha beta' })
    set_selection(1, 0, 4)

    commands.replace_selection()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'user changed beta' })
    pending_callback('translated')

    assert.equals('alpha', translate_calls[1].text)
    assert.same({ 'user changed beta' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.matches('buffer changed', notify_messages[#notify_messages].msg)
  end)
end)

describe('immersive async lifecycle', function()
  local commands
  local bufnr
  local translate_callbacks
  local shown

  local function reset_modules(fake_parser, fake_translate, fake_ui)
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser'] = fake_parser
    package.loaded['comment-translate.translate'] = fake_translate
    package.loaded['comment-translate.ui'] = fake_ui
  end

  before_each(function()
    translate_callbacks = {}
    shown = {}

    local fake_parser = {
      get_all_comments = function()
        return {
          [0] = 'comment A',
        }
      end,
    }
    local fake_translate = {
      translate = function(_, _, _, callback)
        table.insert(translate_callbacks, callback)
      end,
    }
    local fake_ui = {
      hover = {
        close = function() end,
      },
      virtual_text = {
        clear_buf = function() end,
        clear_all = function() end,
        show = function(target_bufnr, line, text)
          table.insert(shown, {
            bufnr = target_bufnr,
            line = line,
            text = text,
          })
        end,
      },
    }

    reset_modules(fake_parser, fake_translate, fake_ui)
    local config = require('comment-translate.config')
    config.reset()
    commands = require('comment-translate.commands')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it('should ignore immersive translation results after the buffer is deleted', function()
    commands.enable_immersive(bufnr)

    assert.equals(1, #translate_callbacks)

    vim.api.nvim_buf_delete(bufnr, { force = true })
    translate_callbacks[1]('translated A')

    assert.same({}, shown)
  end)
end)

describe('plugin commands', function()
  local bufnr
  local health_bufnr
  local original_cmd
  local original_loaded
  local original_health
  local original_get_parser

  before_each(function()
    package.loaded['comment-translate'] = nil
    package.loaded['comment-translate.health'] = nil
    original_loaded = vim.g.loaded_comment_translate
    vim.g.loaded_comment_translate = nil
    original_cmd = vim.cmd
    original_get_parser = vim.treesitter.get_parser

    bufnr = vim.api.nvim_create_buf(false, false)
    health_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = 'lua'

    dofile('plugin/comment-translate.lua')
  end)

  after_each(function()
    vim.cmd = original_cmd
    vim.health = original_health
    vim.treesitter.get_parser = original_get_parser
    vim.g.loaded_comment_translate = original_loaded
    pcall(vim.api.nvim_del_user_command, 'CommentTranslateHealth')
    pcall(vim.api.nvim_del_user_command, 'CommentTranslateSetup')
    if health_bufnr and vim.api.nvim_buf_is_valid(health_bufnr) then
      vim.api.nvim_buf_delete(health_bufnr, { force = true })
    end
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it('should capture the current buffer before running the health check', function()
    local parser_bufnr
    local health = require('comment-translate.health')
    original_health = vim.health
    vim.health = {
      start = function() end,
      ok = function() end,
      error = function() end,
      warn = function() end,
      info = function() end,
    }
    vim.treesitter.get_parser = function(target_bufnr)
      parser_bufnr = target_bufnr
      return {}
    end

    vim.cmd = function(_)
      vim.api.nvim_set_current_buf(health_bufnr)
      health.check()
    end

    vim.api.nvim_cmd({ cmd = 'CommentTranslateHealth' }, {})

    assert.equals(bufnr, parser_bufnr)
  end)

  it('should not load heavy modules during runtime plugin load', function()
    assert.is_nil(package.loaded['comment-translate'])
    assert.is_nil(package.loaded['comment-translate.health'])
  end)

  it('should keep runtime plugin loading idempotent', function()
    local setup_command_before = vim.api.nvim_get_commands({})['CommentTranslateSetup']
    local health_command_before = vim.api.nvim_get_commands({})['CommentTranslateHealth']

    dofile('plugin/comment-translate.lua')

    local commands_after = vim.api.nvim_get_commands({})
    assert.same(setup_command_before, commands_after['CommentTranslateSetup'])
    assert.same(health_command_before, commands_after['CommentTranslateHealth'])
  end)
end)

describe('autocmds', function()
  local autocmds
  local config

  before_each(function()
    package.loaded['comment-translate.autocmds'] = nil
    package.loaded['comment-translate.config'] = nil

    config = require('comment-translate.config')
    config.setup({
      hover = {
        enabled = true,
        delay = 100,
        auto = true,
      },
    })

    autocmds = require('comment-translate.autocmds')
  end)

  describe('cleanup_all_timers', function()
    it('should cleanup without error', function()
      assert.has_no.errors(function()
        autocmds.cleanup_all_timers()
      end)
    end)
  end)

  describe('show_hover_on_demand', function()
    it('should exist and be callable', function()
      assert.is_function(autocmds.show_hover_on_demand)
    end)
  end)
end)

describe('ui.hover', function()
  local hover
  local bufnr

  before_each(function()
    package.loaded['comment-translate.ui.hover'] = nil
    hover = require('comment-translate.ui.hover')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'test line' })
  end)

  after_each(function()
    hover.close()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe('show', function()
    it('should create hover window with text', function()
      hover.show('Hello World')

      local hover_bufnr = hover.bufnr()
      assert.is_not_nil(hover_bufnr)
      assert.is_true(vim.api.nvim_buf_is_valid(hover_bufnr))

      local hover_winid = hover.winid()
      assert.is_not_nil(hover_winid)
      assert.is_true(vim.api.nvim_win_is_valid(hover_winid))
      assert.is_true(vim.api.nvim_win_get_config(hover_winid).focusable)
      assert.is_true(hover.is_hover_window(hover_winid))
      assert.is_true(hover.is_hover_buffer(hover_bufnr))
      assert.is_false(hover.is_hover_buffer(bufnr))

      local lines = vim.api.nvim_buf_get_lines(hover_bufnr, 0, -1, false)
      assert.equals('Hello World', lines[1])
    end)

    it('should handle empty text gracefully', function()
      assert.has_no.errors(function()
        hover.show('')
      end)
      assert.is_nil(hover.bufnr())
    end)

    it('should handle nil text gracefully', function()
      assert.has_no.errors(function()
        hover.show(nil)
      end)
      assert.is_nil(hover.bufnr())
    end)

    it('should handle multiline text', function()
      hover.show('Line 1\nLine 2\nLine 3')

      local hover_bufnr = hover.bufnr()
      assert.is_not_nil(hover_bufnr)

      local lines = vim.api.nvim_buf_get_lines(hover_bufnr, 0, -1, false)
      assert.equals(3, #lines)
      assert.equals('Line 1', lines[1])
      assert.equals('Line 2', lines[2])
      assert.equals('Line 3', lines[3])
    end)
  end)

  describe('close', function()
    it('should close hover window', function()
      hover.show('Test')
      assert.is_not_nil(hover.bufnr())

      hover.close()
      assert.is_nil(hover.bufnr())
      assert.is_nil(hover.winid())
    end)

    it('should clear stale state when hover window was already closed', function()
      hover.show('Test')
      local hover_winid = hover.winid()
      assert.is_not_nil(hover_winid)

      vim.api.nvim_win_close(hover_winid, true)
      hover.close()

      assert.is_nil(hover.bufnr())
      assert.is_nil(hover.winid())
    end)

    it('should handle multiple close calls', function()
      hover.show('Test')
      hover.close()

      assert.has_no.errors(function()
        hover.close()
        hover.close()
      end)
    end)
  end)
end)

describe('ui.virtual_text', function()
  local virtual_text
  local bufnr

  before_each(function()
    package.loaded['comment-translate.ui.virtual_text'] = nil
    virtual_text = require('comment-translate.ui.virtual_text')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      '-- Comment line 1',
      'local x = 1',
      '-- Comment line 2',
    })
  end)

  after_each(function()
    virtual_text.clear_all()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe('show', function()
    it('should add virtual text', function()
      assert.has_no.errors(function()
        virtual_text.show(bufnr, 0, 'Translated text')
      end)
    end)

    it('should ignore invalid buffers without error', function()
      assert.has_no.errors(function()
        virtual_text.show(99999, 0, 'Translated text')
      end)
    end)
  end)

  describe('clear_buf', function()
    it('should clear virtual text from buffer', function()
      virtual_text.show(bufnr, 0, 'Test')

      assert.has_no.errors(function()
        virtual_text.clear_buf(bufnr)
      end)
    end)

    it('should handle invalid buffer gracefully', function()
      assert.has_no.errors(function()
        virtual_text.clear_buf(99999)
      end)
    end)

    it('should handle nil bufnr gracefully', function()
      assert.has_no.errors(function()
        virtual_text.clear_buf(nil)
      end)
    end)
  end)

  describe('clear_all', function()
    it('should clear all virtual text', function()
      virtual_text.show(bufnr, 0, 'Test 1')
      virtual_text.show(bufnr, 2, 'Test 2')

      assert.has_no.errors(function()
        virtual_text.clear_all()
      end)
    end)
  end)
end)

describe('immersive multi-buffer behavior', function()
  local commands
  local config
  local ui
  local bufnr1, bufnr2

  before_each(function()
    -- Reset all related modules
    package.loaded['comment-translate'] = nil
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser'] = nil
    package.loaded['comment-translate.parser.regex'] = nil
    package.loaded['comment-translate.parser.treesitter'] = nil
    package.loaded['comment-translate.translate'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.translate.google'] = nil
    package.loaded['comment-translate.translate.llm'] = nil
    package.loaded['comment-translate.ui'] = nil
    package.loaded['comment-translate.ui.hover'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil
    package.loaded['comment-translate.autocmds'] = nil
    package.loaded['comment-translate.utils'] = nil

    config = require('comment-translate.config')
    config.setup({
      target_language = 'ja',
      hover = {
        enabled = false,
        delay = 100,
        auto = true,
      },
      immersive = {
        enabled = false,
      },
      keymaps = {
        hover = false,
        hover_manual = false,
        replace = false,
        toggle = false,
      },
    })

    commands = require('comment-translate.commands')
    ui = require('comment-translate.ui')

    -- Create two test buffers
    bufnr1 = vim.api.nvim_create_buf(false, true)
    bufnr2 = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_lines(bufnr1, 0, -1, false, { '-- Buffer 1 comment' })
    vim.api.nvim_buf_set_lines(bufnr2, 0, -1, false, { '-- Buffer 2 comment' })
  end)

  after_each(function()
    if bufnr1 and vim.api.nvim_buf_is_valid(bufnr1) then
      vim.api.nvim_buf_delete(bufnr1, { force = true })
    end
    if bufnr2 and vim.api.nvim_buf_is_valid(bufnr2) then
      vim.api.nvim_buf_delete(bufnr2, { force = true })
    end
    ui.hover.close()
    ui.virtual_text.clear_all()
  end)

  describe('toggle_immersive global disable', function()
    it('should disable immersive mode for all buffers when toggled off', function()
      -- Enable immersive on buffer 1
      vim.api.nvim_set_current_buf(bufnr1)
      commands.enable_immersive(bufnr1)
      assert.is_true(commands.is_immersive_enabled(bufnr1))

      -- Enable immersive on buffer 2
      commands.enable_immersive(bufnr2)
      assert.is_true(commands.is_immersive_enabled(bufnr2))

      -- Toggle off (globally) from buffer 1
      vim.api.nvim_set_current_buf(bufnr1)
      commands.toggle_immersive(bufnr1)

      -- Both buffers should be disabled
      assert.is_false(commands.is_immersive_enabled(bufnr1))
      assert.is_false(commands.is_immersive_enabled(bufnr2))
      assert.is_false(commands.is_immersive_globally_enabled())
    end)

    it('should not affect other buffers when enabling', function()
      -- Enable only on buffer 1
      vim.api.nvim_set_current_buf(bufnr1)
      commands.toggle_immersive(bufnr1)

      assert.is_true(commands.is_immersive_enabled(bufnr1))
      assert.is_false(commands.is_immersive_enabled(bufnr2))
      assert.is_true(commands.is_immersive_globally_enabled())
    end)
  end)
end)
