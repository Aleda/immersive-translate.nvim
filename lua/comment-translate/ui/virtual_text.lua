---@brief Virtual-text rendering for translations.
---
---Everything here lives in the display layer only: extmarks in a private
---namespace. This module never calls nvim_buf_set_lines or
---nvim_buf_set_text, so buffer contents, changedtick and undo history are
---untouched (design.md 2.2).
---
---Two tracking schemes coexist:
---  * `blocks[bufnr][target_id]` for immersive document targets, keyed by
---    target id so two blocks sharing an anchor row cannot overwrite each
---    other;
---  * `extmarks[bufnr][line]` for the legacy comment/string path.

local M = {}

local ns_id = vim.api.nvim_create_namespace('comment_translate_immersive')

---@type table<integer, table<integer, integer>>
local extmarks = {}

---@type table<integer, table<string, integer>>
local blocks = {}

---@param bufnr number
function M.clear_buf(bufnr)
  -- Guard against nil bufnr to prevent table index errors
  if not bufnr then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    -- Buffer is invalid, just cleanup our tracking table
    extmarks[bufnr] = nil
    blocks[bufnr] = nil
    return
  end

  if extmarks[bufnr] then
    for _, mark_id in pairs(extmarks[bufnr]) do
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, mark_id)
    end
    extmarks[bufnr] = {}
  end

  if blocks[bufnr] then
    for _, mark_id in pairs(blocks[bufnr]) do
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, mark_id)
    end
    blocks[bufnr] = {}
  end
end

function M.clear_all()
  for bufnr, _ in pairs(extmarks) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.clear_buf(bufnr)
    end
  end
  for bufnr, _ in pairs(blocks) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.clear_buf(bufnr)
    end
  end
  extmarks = {}
  blocks = {}
end

---Wrap one logical line to `width` display columns.
---
---virt_lines are never soft-wrapped by Neovim: whatever does not fit the
---window is simply clipped and unreadable. So the renderer wraps the text
---itself, measuring in display cells (strdisplaywidth) rather than bytes or
---characters, since CJK glyphs occupy two columns each.
---@param line string
---@param width integer
---@return string[]
local function wrap_line(line, width)
  if width <= 0 or vim.fn.strdisplaywidth(line) <= width then
    return { line }
  end

  local out = {}
  local current = ''

  ---@param piece string
  local function push(piece)
    if current == '' then
      current = piece
    elseif vim.fn.strdisplaywidth(current .. ' ' .. piece) <= width then
      current = current .. ' ' .. piece
    else
      table.insert(out, current)
      current = piece
    end
  end

  ---Break a single token that is itself wider than the line.
  ---@param token string
  local function push_oversized(token)
    local chunk = ''
    for _, char in ipairs(vim.fn.split(token, '\\zs')) do
      if vim.fn.strdisplaywidth(chunk .. char) > width then
        if chunk ~= '' then
          if current ~= '' then
            table.insert(out, current)
            current = ''
          end
          table.insert(out, chunk)
        end
        chunk = char
      else
        chunk = chunk .. char
      end
    end
    if chunk ~= '' then
      push(chunk)
    end
  end

  for token in line:gmatch('%S+') do
    if vim.fn.strdisplaywidth(token) > width then
      push_oversized(token)
    else
      push(token)
    end
  end

  if current ~= '' then
    table.insert(out, current)
  end

  if #out == 0 then
    return { line }
  end

  return out
end

---Usable width for a translation block in the window showing `bufnr`.
---@param bufnr integer
---@return integer
local function display_width(bufnr)
  local width = nil

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      local info = vim.fn.getwininfo(winid)[1]
      width = info and info.width or vim.api.nvim_win_get_width(winid)
      -- Subtract gutters (number, sign and fold columns) so wrapped text
      -- lines up with the source rather than overflowing behind them.
      if info then
        width = width - (info.textoff or 0)
      end
      break
    end
  end

  if not width or width <= 0 then
    width = vim.o.columns
  end

  return width
end

---@return table
local function render_opts()
  local config = require('comment-translate.config')
  local render = (config.config.immersive or {}).render or {}
  return {
    hl_group = render.hl_group or 'Comment',
    prefix = render.prefix or '',
  }
end

---Show a translation block beneath a target. Does not modify buffer text.
---@param bufnr integer
---@param target ImmersiveTarget
---@param translated_text string
function M.show_block(bufnr, target, translated_text)
  if not translated_text or translated_text == '' then
    return
  end

  if not bufnr or not target or not vim.api.nvim_buf_is_valid(bufnr) then
    if bufnr then
      blocks[bufnr] = nil
    end
    return
  end

  local opts = render_opts()

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local anchor = target.end_row or 0
  if anchor < 0 then
    anchor = 0
  end
  if anchor > line_count - 1 then
    anchor = line_count - 1
  end

  local width = display_width(bufnr) - vim.fn.strdisplaywidth(opts.prefix)

  local virt_lines = {}
  for _, line in ipairs(vim.split(translated_text, '\n', { plain = true })) do
    for _, wrapped in ipairs(wrap_line(line, width)) do
      table.insert(virt_lines, { { opts.prefix .. wrapped, opts.hl_group } })
    end
  end

  local mark_opts = {
    virt_lines = virt_lines,
    virt_lines_above = false,
    hl_mode = 'combine',
  }

  -- virt_lines_leftcol is only available from Neovim 0.10; passing an unknown
  -- field to nvim_buf_set_extmark is an error rather than a silent no-op.
  if vim.fn.has('nvim-0.10') == 1 then
    mark_opts.virt_lines_leftcol = false
  end

  blocks[bufnr] = blocks[bufnr] or {}

  local previous = blocks[bufnr][target.id]
  if previous then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, previous)
  end

  local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, anchor, 0, mark_opts)
  if not ok then
    blocks[bufnr][target.id] = nil
    return
  end

  blocks[bufnr][target.id] = mark_id
end

---Remove the block rendered for a single target.
---@param bufnr integer
---@param target_id string
function M.clear_target(bufnr, target_id)
  if not bufnr or not target_id then
    return
  end

  local buf_blocks = blocks[bufnr]
  if not buf_blocks then
    return
  end

  local mark_id = buf_blocks[target_id]
  if not mark_id then
    return
  end

  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, mark_id)
  end
  buf_blocks[target_id] = nil
end

---@param bufnr number
---@param line number
---@param translated_text string
function M.show_inline(bufnr, line, translated_text)
  if not translated_text or translated_text == '' then
    return
  end

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    if bufnr and extmarks[bufnr] then
      extmarks[bufnr] = nil
    end
    return
  end

  if extmarks[bufnr] and extmarks[bufnr][line] then
    vim.api.nvim_buf_del_extmark(bufnr, ns_id, extmarks[bufnr][line])
  end

  local line_content = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ''
  local col = #line_content

  local lines = vim.split(translated_text, '\n', { plain = true })
  local opts = {
    hl_mode = 'combine',
  }

  if #lines == 1 then
    opts.virt_text = { { ' → ' .. lines[1], 'Comment' } }
    opts.virt_text_pos = 'eol'
  else
    opts.virt_text = { { ' → ' .. lines[1], 'Comment' } }
    opts.virt_text_pos = 'eol'
    local virt_lines = {}
    for i = 2, #lines do
      table.insert(virt_lines, { { '   ' .. lines[i], 'Comment' } })
    end
    opts.virt_lines = virt_lines
  end

  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, col, opts)

  if not extmarks[bufnr] then
    extmarks[bufnr] = {}
  end
  extmarks[bufnr][line] = mark_id
end

---@param bufnr number
---@param line number
---@param translated_text string
function M.show(bufnr, line, translated_text)
  M.show_inline(bufnr, line, translated_text)
end

return M
