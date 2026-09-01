---@brief Document (markdown/text) paragraph extraction.
---
---A deterministic line grammar rather than a Tree-sitter query: it works with
---no parser installed, covers the small set of stable Markdown block rules the
---reading experience needs, and runs in O(lines) so results can be cached by
---changedtick. See design.md 5.1/5.2.
---
---Extraction is pure: it reads buffer lines and returns targets. It never
---translates, renders or touches buffer text.

local M = {}

---@class ImmersiveTarget
---@field id string          -- positional identity: kind:start_row:end_row
---@field kind 'paragraph'|'heading'|'blockquote'|'list_item'|'comment'
---@field start_row integer  -- 0-based, inclusive
---@field end_row integer    -- 0-based, inclusive; extmark anchor
---@field text string        -- normalized source text
---@field fingerprint string -- sha256(kind .. '\30' .. text); excludes range

local FENCE_PATTERN = '^%s*([`~][`~][`~]+)'
local ATX_PATTERN = '^%s*(#+)%s+(.*)$'
local QUOTE_PATTERN = '^%s*>%s?(.*)$'
local BULLET_PATTERN = '^(%s*)[%-%*%+]%s+(.+)$'
local ORDERED_PATTERN = '^(%s*)%d+[%.%)]%s+(.+)$'
local REF_DEF_PATTERN = '^%s*%[[^%]]+%]:%s'
local HTML_OPEN_PATTERN = '^%s*<%s*[%a!/]'
local TABLE_PATTERN = '^%s*|'
local THEMATIC_PATTERN = '^%s*([%-%*_])%s*%1%s*%1[%s%-%*_]*$'

---@param line string
---@return boolean
local function is_blank(line)
  return line:match('^%s*$') ~= nil
end

---Strip inline constructs whose payload must never reach a translation
---request. Order matters: images (with their alt text) go first, then links
---collapse to their visible label, then any remaining URL token is removed.
---@param line string
---@return string
local function strip_inline(line)
  -- Images, inline and reference form, including alt text.
  line = line:gsub('!%[[^%]]*%]%b()', '')
  line = line:gsub('!%[[^%]]*%]%s*%[[^%]]*%]', '')
  line = line:gsub('!%[[^%]]*%]', '')

  -- Links collapse to their visible label.
  line = line:gsub('%[([^%]]*)%]%b()', '%1')
  line = line:gsub('%[([^%]]*)%]%s*%[[^%]]*%]', '%1')
  line = line:gsub('%[([^%]]*)%]', '%1')

  -- Autolinks and bare URLs.
  line = line:gsub('<%s*%a[%w+.-]*://[^>%s]*%s*>', '')
  line = line:gsub('%a[%w+.-]*://%S+', '')

  return line
end

---The fixed normalization pipeline from design.md 5.1: strip inline tokens,
---trim each line, collapse internal whitespace, drop emptied lines, then join
---with single spaces. Its output is the sole input to fingerprint and cache
---key, so it must be deterministic.
---@param lines string[]
---@return string
local function normalize(lines)
  local cleaned = {}

  for _, line in ipairs(lines) do
    local stripped = strip_inline(line)
    stripped = stripped:gsub('[ \t]+', ' ')
    stripped = stripped:match('^%s*(.-)%s*$')
    if stripped ~= '' then
      table.insert(cleaned, stripped)
    end
  end

  local joined = table.concat(cleaned, ' ')
  joined = joined:gsub('[ \t]+', ' ')
  return joined:match('^%s*(.-)%s*$')
end

---@param kind string
---@param text string
---@return string
local function fingerprint_of(kind, text)
  -- Record separator rather than NUL: vim.fn.sha256() returns a Blob when the
  -- argument contains an embedded NUL. RS cannot appear in normalized text,
  -- which collapses all whitespace and control characters.
  return vim.fn.sha256(kind .. '\30' .. text)
end

---@param targets ImmersiveTarget[]
---@param kind string
---@param start_row integer
---@param end_row integer
---@param lines string[]
---@param min_chars integer
local function push(targets, kind, start_row, end_row, lines, min_chars)
  local text = normalize(lines)
  if text == '' or vim.fn.strchars(text) < min_chars then
    return
  end

  table.insert(targets, {
    id = string.format('%s:%d:%d', kind, start_row, end_row),
    kind = kind,
    start_row = start_row,
    end_row = end_row,
    text = text,
    fingerprint = fingerprint_of(kind, text),
  })
end

---@param lines string[]
---@return integer
local function front_matter_end(lines)
  if #lines == 0 or lines[1]:match('^%-%-%-%s*$') == nil then
    return 0
  end
  for i = 2, #lines do
    if lines[i]:match('^%-%-%-%s*$') or lines[i]:match('^%.%.%.%s*$') then
      return i
    end
  end
  return 0
end

---Extract targets from a buffer.
---@param bufnr integer
---@param mode? 'document'|'text'|string
---@return ImmersiveTarget[]
function M.extract(bufnr, mode)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local config = require('comment-translate.config')
  local immersive = config.config.immersive or {}
  local min_chars = immersive.min_chars or 3
  local plain = mode == 'text'

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total = #lines
  local targets = {}

  local i = 1
  if not plain then
    local fm = front_matter_end(lines)
    if fm > 0 then
      i = fm + 1
    end
  end

  -- Lines of the paragraph currently being accumulated, if any.
  local para = nil
  local para_start = 0

  local function flush_paragraph(end_row)
    if para then
      push(targets, 'paragraph', para_start, end_row, para, min_chars)
      para = nil
    end
  end

  local function absorb(row, line)
    if not para then
      para = {}
      para_start = row
    end
    table.insert(para, line)
  end

  ---Consume the block starting at `i` and return the next index to visit.
  ---@param row integer
  ---@param line string
  ---@return integer
  local function step(row, line)
    if is_blank(line) then
      flush_paragraph(row - 1)
      return i + 1
    end

    if plain then
      -- Plain text: blank lines are the only separator.
      absorb(row, line)
      return i + 1
    end

    -- Fenced code: skip the whole block, including an unterminated one.
    local fence = line:match(FENCE_PATTERN)
    if fence then
      flush_paragraph(row - 1)
      local marker = fence:sub(1, 1)
      local j = i + 1
      while j <= total do
        local candidate = lines[j]:match(FENCE_PATTERN)
        j = j + 1
        if candidate and candidate:sub(1, 1) == marker then
          break
        end
      end
      return j
    end

    -- Thematic breaks must be tested before list bullets, since `---` and
    -- `***` would otherwise read as bullet markers.
    if line:match(THEMATIC_PATTERN) then
      flush_paragraph(row - 1)
      return i + 1
    end

    -- Link reference definitions and tables are skipped line by line.
    if line:match(REF_DEF_PATTERN) or line:match(TABLE_PATTERN) then
      flush_paragraph(row - 1)
      return i + 1
    end

    -- An HTML block runs to the next blank line.
    if line:match(HTML_OPEN_PATTERN) then
      flush_paragraph(row - 1)
      local j = i
      while j <= total and not is_blank(lines[j]) do
        j = j + 1
      end
      return j
    end

    -- Indented code, but only when it starts a block rather than continuing a
    -- paragraph, since a wrapped paragraph line may legitimately be indented.
    if not para and line:match('^    %S') then
      return i + 1
    end

    local hashes, heading_text = line:match(ATX_PATTERN)
    if hashes and #hashes <= 6 then
      flush_paragraph(row - 1)
      push(targets, 'heading', row, row, { heading_text }, min_chars)
      return i + 1
    end

    if line:match(QUOTE_PATTERN) then
      flush_paragraph(row - 1)
      local collected = {}
      local j = i
      while j <= total do
        local quoted = lines[j]:match(QUOTE_PATTERN)
        if not quoted then
          break
        end
        table.insert(collected, quoted)
        j = j + 1
      end
      push(targets, 'blockquote', row, j - 2, collected, min_chars)
      return j
    end

    local _, bullet_text = line:match(BULLET_PATTERN)
    if not bullet_text then
      _, bullet_text = line:match(ORDERED_PATTERN)
    end
    if bullet_text then
      flush_paragraph(row - 1)
      -- One target per item; items never merge with each other.
      push(targets, 'list_item', row, row, { bullet_text }, min_chars)
      return i + 1
    end

    absorb(row, line)
    return i + 1
  end

  while i <= total do
    local next_i = step(i - 1, lines[i])
    -- Defensive: every branch must consume at least one line.
    i = next_i > i and next_i or i + 1
  end

  flush_paragraph(total - 1)

  return targets
end

return M
