---@brief Translation facade.
---
---This module is the single owner of the completed-translation cache. Providers
---(`google.lua`, `llm.lua`) perform requests and parsing only; they never read
---or write the cache themselves. Centralising it here means hover, replace and
---immersive mode all share one correct cache semantics, and that the key can
---carry the full output profile (service, provider, model, endpoint, prompt).
---Without the profile, the same paragraph translated by two different models
---would collide in the cache.

local M = {}

local cache = require('comment-translate.translate.cache')
local utils = require('comment-translate.utils')

M.SERVICES = {
  google = 'google',
  llm = 'llm',
}

---@param service_name? string
---@return table?
---@return string?
local function get_service(service_name)
  local config = require('comment-translate.config')
  service_name = service_name or config.config.translate_service

  if service_name == M.SERVICES.google then
    return require('comment-translate.translate.google'), nil
  elseif service_name == M.SERVICES.llm then
    return require('comment-translate.translate.llm'), nil
  else
    return nil, 'Unknown translate service: ' .. tostring(service_name)
  end
end

---@param value any
---@return string
local function hashed(value)
  if value == nil or value == '' then
    return ''
  end
  return vim.fn.sha256(tostring(value))
end

---Describe everything that can change the *output* of a translation.
---Endpoint and system prompt are hashed so the key never carries a URL,
---an internal hostname or prompt text verbatim.
---@param service string
---@return string
local function profile_of(service)
  local config = require('comment-translate.config')

  if service == M.SERVICES.llm then
    local llm = config.config.llm or {}
    return table.concat({
      'llm',
      llm.provider or 'openai',
      llm.model or '',
      hashed(llm.endpoint),
      hashed(llm.system_prompt),
    }, '|')
  end

  -- Google has no per-request profile beyond the service itself.
  return table.concat({ service, 'google', '', '', '' }, '|')
end

---@class TranslationRequest
---@field key string
---@field text string
---@field target_lang string
---@field source_lang string
---@field service string

---Build a request descriptor, including its profile-aware cache key.
---Callers must use this rather than composing keys themselves.
---@param text string
---@param target_lang? string
---@param source_lang? string
---@param opts? { service?: string }
---@return TranslationRequest
function M.prepare(text, target_lang, source_lang, opts)
  opts = opts or {}
  local config = require('comment-translate.config')

  target_lang = target_lang or config.config.target_language
  local service = opts.service or config.config.translate_service

  local normalized_target = utils.normalize_lang_code(target_lang)
  local normalized_source = source_lang and utils.normalize_lang_code(source_lang) or 'auto'

  local key = table.concat({
    vim.fn.sha256(text),
    normalized_source,
    normalized_target,
    profile_of(service),
  }, '|')

  return {
    key = key,
    text = text,
    target_lang = target_lang,
    source_lang = source_lang,
    service = service,
  }
end

---@param request TranslationRequest
---@return string?
function M.lookup(request)
  return cache.get_by_key(request.key)
end

---@param request TranslationRequest
---@param translated_text string
function M.store(request, translated_text)
  cache.set_by_key(request.key, translated_text)
end

---Remove only this request's completed entry.
---@param request TranslationRequest
function M.invalidate(request)
  cache.del_by_key(request.key)
end

---Perform the provider request for an already-prepared request.
---Skips the cache lookup; on success stores the result under `request.key`.
---@param request TranslationRequest
---@param callback fun(result: string?)
function M.execute(request, callback)
  if not callback then
    vim.notify('comment-translate: callback is required for execute()', vim.log.levels.ERROR)
    return
  end

  local service, err = get_service(request.service)
  if not service then
    vim.notify('comment-translate: ' .. (err or 'Unknown error'), vim.log.levels.ERROR)
    vim.schedule(function()
      callback(nil)
    end)
    return
  end

  service.translate(request.text, request.target_lang, request.source_lang, function(result)
    if result and result ~= '' then
      M.store(request, result)
    end
    callback(result)
  end)
end

---Translate text using the configured service.
---Compatibility wrapper: prepare -> lookup -> execute.
---@param text string Text to translate
---@param target_lang? string Target language code
---@param source_lang? string Source language code
---@param callback fun(result: string?) Callback with translated text or nil on error
---@param service_name? string Override translation service
function M.translate(text, target_lang, source_lang, callback, service_name)
  if not callback then
    vim.notify('comment-translate: callback is required for translate()', vim.log.levels.ERROR)
    return
  end

  local config = require('comment-translate.config')
  local service = service_name or config.config.translate_service

  if not M.SERVICES[service] then
    vim.notify(
      'comment-translate: Unknown translate service: ' .. tostring(service),
      vim.log.levels.ERROR
    )
    vim.schedule(function()
      callback(nil)
    end)
    return
  end

  local request = M.prepare(text, target_lang, source_lang, { service = service })

  local cached = M.lookup(request)
  if cached then
    vim.schedule(function()
      callback(cached)
    end)
    return
  end

  M.execute(request, callback)
end

---@return string[]
function M.get_available_services()
  return { M.SERVICES.google, M.SERVICES.llm }
end

return M
