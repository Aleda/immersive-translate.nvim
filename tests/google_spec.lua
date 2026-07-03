---@diagnostic disable: undefined-global
describe('translate.google', function()
  local config
  local google
  local cache
  local original_notify
  local original_executable
  local notify_messages
  local job_state

  local function setup_fake_job()
    job_state = {
      new_calls = 0,
      exit_code = 0,
      stdout = '',
      stderr_lines = {},
      last_opts = nil,
    }

    local FakeJob = {}
    function FakeJob.new(_, opts)
      job_state.new_calls = job_state.new_calls + 1
      job_state.last_opts = opts
      return setmetatable({
        _opts = opts,
      }, {
        __index = {
          result = function()
            return { job_state.stdout }
          end,
          start = function(job)
            for _, line in ipairs(job_state.stderr_lines or {}) do
              job._opts.on_stderr(nil, line)
            end
            job._opts.on_exit(job, job_state.exit_code)
          end,
        },
      })
    end

    package.loaded['plenary.job'] = FakeJob
  end

  local function await_callback(fn)
    local done = false
    local value = nil
    fn(function(result)
      value = result
      done = true
    end)
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    return value
  end

  local function assert_uses_stdin_config(opts)
    assert.equals('curl', opts.command)
    assert.same({ '--config', '-' }, opts.args)
    assert.is_string(opts.writer)
  end

  local function assert_args_do_not_contain(opts, needle)
    assert.is_nil(table.concat(opts.args, '\n'):find(needle, 1, true))
  end

  local function decode_curl_config_string(value)
    local result = {}
    local i = 1
    while i <= #value do
      local char = value:sub(i, i)
      if char == '\\' then
        local next_char = value:sub(i + 1, i + 1)
        if next_char == 'n' then
          table.insert(result, '\n')
        elseif next_char == 'r' then
          table.insert(result, '\r')
        elseif next_char == 't' then
          table.insert(result, '\t')
        else
          table.insert(result, next_char)
        end
        i = i + 2
      else
        table.insert(result, char)
        i = i + 1
      end
    end
    return table.concat(result, '')
  end

  local function config_value(writer, option)
    local prefix = option .. ' = "'
    for line in writer:gmatch('[^\n]+') do
      if line:sub(1, #prefix) == prefix then
        return decode_curl_config_string(line:sub(#prefix + 1, -2))
      end
    end
    return nil
  end

  local function has_config_line(writer, expected)
    for line in writer:gmatch('[^\n]+') do
      if line == expected then
        return true
      end
    end
    return false
  end

  before_each(function()
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.translate.google'] = nil
    package.loaded['plenary.job'] = nil

    setup_fake_job()

    config = require('comment-translate.config')
    config.reset()
    cache = require('comment-translate.translate.cache')
    cache.clear()
    google = require('comment-translate.translate.google')

    notify_messages = {}
    original_notify = vim.notify
    original_executable = vim.fn.executable
    vim.notify = function(msg, level)
      table.insert(notify_messages, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = original_notify
    vim.fn.executable = original_executable
  end)

  it('should keep translated text out of curl argv', function()
    config.setup({
      max_length = 5000,
    })
    job_state.stdout = vim.fn.json_encode({
      {
        { '翻訳結果', 'sensitive token' },
      },
    })

    local result = await_callback(function(cb)
      google.translate('sensitive token', 'ja', 'en', cb)
    end)

    assert.equals('翻訳結果', result)
    assert.equals(1, job_state.new_calls)
    assert_uses_stdin_config(job_state.last_opts)
    assert_args_do_not_contain(job_state.last_opts, 'sensitive token')
    assert_args_do_not_contain(job_state.last_opts, 'sensitive%20token')
    assert.is_true(has_config_line(job_state.last_opts.writer, 'get'))
    assert.matches('translate%.googleapis%.com', config_value(job_state.last_opts.writer, 'url'))
    assert.is_nil(config_value(job_state.last_opts.writer, 'url'):find('sensitive', 1, true))
    assert.equals('q=sensitive token', config_value(job_state.last_opts.writer, 'data-urlencode'))
  end)

  it('should not include curl stderr details in failure notifications', function()
    config.setup({
      max_length = 5000,
    })
    job_state.exit_code = 22
    job_state.stderr_lines = { 'curl failed with sensitive token' }

    local result = await_callback(function(cb)
      google.translate('sensitive token', 'ja', 'en', cb)
    end)

    assert.is_nil(result)
    assert.matches('Translation failed', notify_messages[1].msg)
    assert.is_nil(notify_messages[1].msg:find('sensitive token', 1, true))
    assert.is_nil(notify_messages[1].msg:find('curl failed', 1, true))
  end)
end)
