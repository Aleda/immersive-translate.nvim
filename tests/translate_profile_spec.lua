---@diagnostic disable: undefined-global
-- Profile-aware cache keys and the translate facade (design.md §3.3).
--
-- The completed cache has exactly one owner: translate/init.lua. Providers no
-- longer read or write it. The key carries the full output profile so the same
-- source text translated by two different models cannot collide.

describe('translate facade profile cache', function()
  local translate
  local cache
  local config

  local function reload()
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.translate.init'] = nil
    package.loaded['comment-translate.translate'] = nil

    config = require('comment-translate.config')
    cache = require('comment-translate.translate.cache')
    translate = require('comment-translate.translate')
  end

  before_each(function()
    reload()
    config.setup({
      target_language = 'zh-CN',
      translate_service = 'llm',
      cache = { enabled = true, max_entries = 50 },
      llm = { provider = 'openai', model = 'gpt-5.2' },
    })
    cache.clear()
  end)

  describe('prepare', function()
    it('should build a request carrying a stable key', function()
      local a = translate.prepare('hello', 'zh-CN', 'en')
      local b = translate.prepare('hello', 'zh-CN', 'en')

      assert.is_string(a.key)
      assert.equals(a.key, b.key)
      assert.equals('hello', a.text)
    end)

    it('should not leak source text into the key', function()
      local req = translate.prepare('a very secret sentence', 'zh-CN', 'en')

      assert.is_nil(req.key:find('secret', 1, true))
    end)

    it('should produce different keys for different target languages', function()
      local zh = translate.prepare('hello', 'zh-CN', 'en')
      local ja = translate.prepare('hello', 'ja', 'en')

      assert.are_not.equals(zh.key, ja.key)
    end)

    it('should produce different keys for different source languages', function()
      local en = translate.prepare('hello', 'zh-CN', 'en')
      local fr = translate.prepare('hello', 'zh-CN', 'fr')

      assert.are_not.equals(en.key, fr.key)
    end)
  end)

  describe('profile dimensions', function()
    local function key_for(setup_overrides)
      reload()
      config.setup(setup_overrides)
      return translate.prepare('hello', 'zh-CN', 'en').key
    end

    it('should not collide across translate services', function()
      local google = key_for({ translate_service = 'google' })
      local llm = key_for({
        translate_service = 'llm',
        llm = { provider = 'openai', model = 'gpt-5.2' },
      })

      assert.are_not.equals(google, llm)
    end)

    it('should not collide across llm providers', function()
      local openai = key_for({
        translate_service = 'llm',
        llm = { provider = 'openai', model = 'shared-model' },
      })
      local anthropic = key_for({
        translate_service = 'llm',
        llm = { provider = 'anthropic', model = 'shared-model' },
      })

      assert.are_not.equals(openai, anthropic)
    end)

    it('should not collide across models', function()
      local a = key_for({
        translate_service = 'llm',
        llm = { provider = 'openai', model = 'model-a' },
      })
      local b = key_for({
        translate_service = 'llm',
        llm = { provider = 'openai', model = 'model-b' },
      })

      assert.are_not.equals(a, b)
    end)

    it('should not collide across endpoints', function()
      local a = key_for({
        translate_service = 'llm',
        llm = { provider = 'ollama', model = 'm', endpoint = 'http://localhost:11434/api/chat' },
      })
      local b = key_for({
        translate_service = 'llm',
        llm = { provider = 'ollama', model = 'm', endpoint = 'http://example.com/api/chat' },
      })

      assert.are_not.equals(a, b)
    end)

    it('should not collide across system prompts', function()
      local a = key_for({
        translate_service = 'llm',
        llm = { provider = 'openai', model = 'm', system_prompt = 'be formal' },
      })
      local b = key_for({
        translate_service = 'llm',
        llm = { provider = 'openai', model = 'm', system_prompt = 'be casual' },
      })

      assert.are_not.equals(a, b)
    end)

    it('should hit for an identical profile', function()
      local a = key_for({
        translate_service = 'llm',
        llm = { provider = 'openai', model = 'm', system_prompt = 'p' },
      })
      local b = key_for({
        translate_service = 'llm',
        llm = { provider = 'openai', model = 'm', system_prompt = 'p' },
      })

      assert.equals(a, b)
    end)

    it('should not leak the endpoint or prompt verbatim into the key', function()
      reload()
      config.setup({
        translate_service = 'llm',
        llm = {
          provider = 'ollama',
          model = 'm',
          endpoint = 'http://internal.example.com/secret-path',
          system_prompt = 'a private instruction',
        },
      })
      local key = translate.prepare('hello', 'zh-CN', 'en').key

      assert.is_nil(key:find('secret%-path'))
      assert.is_nil(key:find('private instruction', 1, true))
    end)
  end)

  describe('lookup and store', function()
    it('should return nil before anything is stored', function()
      local req = translate.prepare('hello', 'zh-CN', 'en')

      assert.is_nil(translate.lookup(req))
    end)

    it('should round-trip through the facade', function()
      local req = translate.prepare('hello', 'zh-CN', 'en')
      translate.store(req, '你好')

      assert.equals('你好', translate.lookup(req))
    end)

    it('should not hit across differing profiles', function()
      local req = translate.prepare('hello', 'zh-CN', 'en')
      translate.store(req, '你好')

      reload()
      config.setup({
        translate_service = 'llm',
        cache = { enabled = true, max_entries = 50 },
        llm = { provider = 'anthropic', model = 'other' },
      })
      local other = translate.prepare('hello', 'zh-CN', 'en')

      assert.is_nil(translate.lookup(other))
    end)

    it('should respect a disabled cache', function()
      reload()
      config.setup({
        translate_service = 'google',
        cache = { enabled = false },
      })

      local req = translate.prepare('hello', 'zh-CN', 'en')
      translate.store(req, '你好')

      assert.is_nil(translate.lookup(req))
    end)
  end)

  describe('invalidate', function()
    it('should drop only the given request key', function()
      local a = translate.prepare('hello', 'zh-CN', 'en')
      local b = translate.prepare('world', 'zh-CN', 'en')
      translate.store(a, '你好')
      translate.store(b, '世界')

      translate.invalidate(a)

      assert.is_nil(translate.lookup(a))
      assert.equals('世界', translate.lookup(b))
    end)
  end)

  describe('clear', function()
    it('should drop every entry', function()
      local req = translate.prepare('hello', 'zh-CN', 'en')
      translate.store(req, '你好')

      cache.clear()

      assert.is_nil(translate.lookup(req))
    end)
  end)
end)
