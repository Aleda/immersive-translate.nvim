---@diagnostic disable: undefined-global
-- Prompt shape and reasoning support for LLM providers.

describe('translate.llm prompt and reasoning', function()
  local config
  local llm
  local job_state

  local function setup_fake_job()
    job_state = { new_calls = 0, exit_code = 0, stdout = '', last_opts = nil }

    local FakeJob = {}
    function FakeJob.new(_, opts)
      job_state.new_calls = job_state.new_calls + 1
      job_state.last_opts = opts
      return setmetatable({ _opts = opts }, {
        __index = {
          result = function()
            return { job_state.stdout }
          end,
          start = function(job)
            job._opts.on_exit(job, job_state.exit_code)
          end,
        },
      })
    end

    package.loaded['plenary.job'] = FakeJob
  end

  local function await(fn)
    local done, value = false, nil
    fn(function(result)
      value = result
      done = true
    end)
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    return value
  end

  local function decode_config_string(value)
    local out, i = {}, 1
    while i <= #value do
      local c = value:sub(i, i)
      if c == '\\' then
        local n = value:sub(i + 1, i + 1)
        table.insert(out, n == 'n' and '\n' or (n == 't' and '\t' or n))
        i = i + 2
      else
        table.insert(out, c)
        i = i + 1
      end
    end
    return table.concat(out, '')
  end

  local function request_body()
    local prefix = 'data-raw = "'
    for line in job_state.last_opts.writer:gmatch('[^\n]+') do
      if line:sub(1, #prefix) == prefix then
        return vim.fn.json_decode(decode_config_string(line:sub(#prefix + 1, -2)))
      end
    end
    return nil
  end

  before_each(function()
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.translate.llm'] = nil
    package.loaded['plenary.job'] = nil

    setup_fake_job()

    config = require('comment-translate.config')
    config.reset()
    llm = require('comment-translate.translate.llm')
  end)

  describe('delimited source text', function()
    it('should wrap the source text in delimiters', function()
      config.setup({ llm = { provider = 'openai', api_key = 'k' } })
      job_state.stdout = vim.fn.json_encode({ choices = { { message = { content = 'x' } } } })

      await(function(cb)
        llm.translate('Visible paragraphs come first', 'zh-CN', nil, cb)
      end)

      local user = request_body().messages[2].content
      assert.is_not_nil(user:find('<text>', 1, true))
      assert.is_not_nil(user:find('</text>', 1, true))
      assert.is_not_nil(user:find('Visible paragraphs come first', 1, true))
    end)

    it('should place the text after the opening delimiter', function()
      config.setup({ llm = { provider = 'openai', api_key = 'k' } })
      job_state.stdout = vim.fn.json_encode({ choices = { { message = { content = 'x' } } } })

      await(function(cb)
        llm.translate('SOURCE', 'zh-CN', nil, cb)
      end)

      local user = request_body().messages[2].content
      assert.is_true(user:find('<text>', 1, true) < user:find('SOURCE', 1, true))
    end)

    it('should instruct the model never to ask for input', function()
      config.setup({ llm = { provider = 'openai', api_key = 'k' } })
      job_state.stdout = vim.fn.json_encode({ choices = { { message = { content = 'x' } } } })

      await(function(cb)
        llm.translate('text', 'zh-CN', nil, cb)
      end)

      local system = request_body().messages[1].content
      assert.is_not_nil(system:lower():find('never ask', 1, true))
    end)

    it('should still honour a user-supplied system prompt', function()
      config.setup({ llm = { provider = 'openai', api_key = 'k', system_prompt = 'CUSTOM RULES' } })
      job_state.stdout = vim.fn.json_encode({ choices = { { message = { content = 'x' } } } })

      await(function(cb)
        llm.translate('text', 'zh-CN', nil, cb)
      end)

      assert.equals('CUSTOM RULES', request_body().messages[1].content)
    end)
  end)

  describe('reasoning control', function()
    it('should omit reasoning fields by default', function()
      config.setup({ llm = { provider = 'anthropic', api_key = 'k' } })
      job_state.stdout = vim.fn.json_encode({ content = { { type = 'text', text = 'x' } } })

      await(function(cb)
        llm.translate('text', 'zh-CN', nil, cb)
      end)

      local body = request_body()
      assert.is_nil(body.thinking)
      assert.is_nil(body.reasoning_effort)
    end)

    it('should send an anthropic thinking budget when configured', function()
      config.setup({
        llm = {
          provider = 'anthropic',
          api_key = 'k',
          reasoning = { enabled = true, budget_tokens = 2048 },
        },
      })
      job_state.stdout = vim.fn.json_encode({ content = { { type = 'text', text = 'x' } } })

      await(function(cb)
        llm.translate('text', 'zh-CN', nil, cb)
      end)

      local body = request_body()
      assert.equals('enabled', body.thinking.type)
      assert.equals(2048, body.thinking.budget_tokens)
    end)

    it('should raise max_tokens above the thinking budget', function()
      config.setup({
        llm = {
          provider = 'anthropic',
          api_key = 'k',
          reasoning = { enabled = true, budget_tokens = 4096 },
        },
      })
      job_state.stdout = vim.fn.json_encode({ content = { { type = 'text', text = 'x' } } })

      await(function(cb)
        llm.translate('text', 'zh-CN', nil, cb)
      end)

      local body = request_body()
      assert.is_true(body.max_tokens > body.thinking.budget_tokens)
    end)

    it('should drop temperature when anthropic thinking is on', function()
      -- Anthropic rejects temperature together with extended thinking.
      config.setup({
        llm = {
          provider = 'anthropic',
          api_key = 'k',
          reasoning = { enabled = true, budget_tokens = 1024 },
        },
      })
      job_state.stdout = vim.fn.json_encode({ content = { { type = 'text', text = 'x' } } })

      await(function(cb)
        llm.translate('text', 'zh-CN', nil, cb)
      end)

      assert.is_nil(request_body().temperature)
    end)

    it('should send reasoning_effort for openai-shaped providers', function()
      config.setup({
        llm = {
          provider = 'openai',
          api_key = 'k',
          reasoning = { enabled = true, effort = 'high' },
        },
      })
      job_state.stdout = vim.fn.json_encode({ choices = { { message = { content = 'x' } } } })

      await(function(cb)
        llm.translate('text', 'zh-CN', nil, cb)
      end)

      assert.equals('high', request_body().reasoning_effort)
    end)
  end)

  describe('reasoning in responses', function()
    it('should ignore anthropic thinking blocks', function()
      config.setup({ llm = { provider = 'anthropic', api_key = 'k' } })
      job_state.stdout = vim.fn.json_encode({
        content = {
          { type = 'thinking', thinking = 'internal deliberation' },
          { type = 'text', text = '译文' },
        },
      })

      local result = await(function(cb)
        llm.translate('text', 'zh-CN', nil, cb)
      end)

      assert.equals('译文', result)
    end)

    it('should ignore an openai reasoning_content field', function()
      config.setup({ llm = { provider = 'openai', api_key = 'k' } })
      job_state.stdout = vim.fn.json_encode({
        choices = {
          { message = { reasoning_content = 'internal deliberation', content = '译文' } },
        },
      })

      local result = await(function(cb)
        llm.translate('text', 'zh-CN', nil, cb)
      end)

      assert.equals('译文', result)
    end)
  end)
end)
