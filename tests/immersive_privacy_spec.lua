---@diagnostic disable: undefined-global
-- Privacy guarantees — design.md 10.3.
--
-- Immersive mode reads whole documents, so anything that reaches a provider
-- or a cache key is a disclosure decision. These assertions are the ones worth
-- failing the build over.

describe('immersive privacy', function()
  local scheduler
  local config
  local translate
  local cache

  local sent

  local function make_buf(lines)
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
      immersive = { concurrency = 4, prefetch_lines = 500, min_chars = 1 },
      translate_service = 'llm',
      llm = {
        provider = 'ollama',
        model = 'm',
        endpoint = 'http://localhost:11434/api/chat',
        system_prompt = 'INTERNAL-PROMPT-TEXT',
      },
    })

    cache = require('comment-translate.translate.cache')
    cache.clear()

    translate = require('comment-translate.translate')

    sent = {}
    translate.execute = function(request, callback)
      table.insert(sent, request.text)
      translate.store(request, 'translated')
      callback('translated')
    end

    scheduler = require('comment-translate.immersive.scheduler')
    scheduler.reset()
  end)

  after_each(function()
    scheduler.reset()
  end)

  describe('outbound request text', function()
    it('should never contain a URL, token or host', function()
      local bufnr = make_buf({
        'Visit [our portal](https://internal.example/login?token=ABC123) today.',
        '',
        '![diagram](https://cdn.example/private/arch.png)',
        '',
        'Contact <https://intranet.example/team> for access.',
        '',
        '[ref]: https://hidden.example/path',
        '',
        'A plain sentence with no links at all.',
      })

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      local blob = table.concat(sent, '\n')

      for _, needle in ipairs({
        'http',
        'ABC123',
        'internal.example',
        'cdn.example',
        'intranet.example',
        'hidden.example',
        'arch.png',
      }) do
        assert.is_nil(blob:find(needle, 1, true), 'leaked ' .. needle)
      end
    end)

    it('should still send the readable prose around a link', function()
      local bufnr = make_buf({ 'Visit [our portal](https://internal.example/x) today.' })

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      assert.equals('Visit our portal today.', sent[1])
    end)

    it('should send nothing for an image-only block', function()
      local bufnr = make_buf({ '![diagram](https://cdn.example/a.png)' })

      scheduler.enable(bufnr)
      scheduler.schedule_all(bufnr)

      assert.equals(0, #sent)
    end)
  end)

  describe('cache keys', function()
    it('should not carry source text, endpoint or system prompt', function()
      local key = translate.prepare('A plain sentence with no links at all.', nil, nil, nil).key

      assert.is_nil(key:find('INTERNAL-PROMPT-TEXT', 1, true))
      assert.is_nil(key:find('localhost:11434', 1, true))
      assert.is_nil(key:find('plain sentence', 1, true))
      assert.is_nil(key:find('http', 1, true))
    end)
  end)

  describe('cache bounds', function()
    it('should never exceed max_entries', function()
      config.setup({ cache = { enabled = true, max_entries = 5 } })

      for i = 1, 40 do
        local request = translate.prepare('sentence number ' .. i, nil, nil, nil)
        translate.store(request, 'translated ' .. i)
      end

      assert.is_true(cache.size() <= 5)
    end)
  end)
end)
