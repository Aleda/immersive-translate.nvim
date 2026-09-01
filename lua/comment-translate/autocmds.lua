local M = {}

---@type table<number, uv_timer_t>
local hover_timers = {}

---@type table Stored references for manual hover
local manual_hover_refs = {
  config = nil,
  parser = nil,
  translate = nil,
  ui = nil,
}

---@param bufnr number
local function cleanup_timer(bufnr)
  if hover_timers[bufnr] then
    hover_timers[bufnr]:stop()
    hover_timers[bufnr]:close()
    hover_timers[bufnr] = nil
  end
end

local function is_hover_buffer(ui, bufnr)
  if ui.hover.is_hover_buffer and ui.hover.is_hover_buffer(bufnr) then
    return true
  end

  return ui.hover.bufnr and bufnr == ui.hover.bufnr()
end

local function is_hover_context(ui)
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()

  if ui.hover.is_hover_window and ui.hover.is_hover_window(current_win) then
    return true
  end
  if is_hover_buffer(ui, current_buf) then
    return true
  end
  if ui.hover.winid and current_win == ui.hover.winid() then
    return true
  end
  return current_buf == ui.hover.bufnr()
end

local function close_stale_hover(ui)
  if is_hover_context(ui) then
    return
  end

  local hover_bufnr = ui.hover.bufnr()
  if hover_bufnr and vim.api.nvim_get_current_buf() ~= hover_bufnr then
    ui.hover.close()
  end
end

function M.setup_hover(config, parser, translate, ui)
  local hover_group = vim.api.nvim_create_augroup('CommentTranslateHover', { clear = true })

  manual_hover_refs.config = config
  manual_hover_refs.parser = parser
  manual_hover_refs.translate = translate
  manual_hover_refs.ui = ui

  if not config.config.hover.enabled then
    return
  end

  vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
    group = hover_group,
    callback = function()
      if not config.config.hover.auto then
        return
      end
      if is_hover_context(ui) then
        return
      end

      local bufnr = vim.api.nvim_get_current_buf()
      cleanup_timer(bufnr)

      local uv = vim.uv or vim.loop
      local timer = uv.new_timer()
      hover_timers[bufnr] = timer

      timer:start(config.config.hover.delay, 0, function()
        vim.schedule(function()
          local ok = pcall(function()
            if hover_timers[bufnr] == timer then
              if is_hover_context(ui) then
                return
              end
              local text, _ = parser.get_text_at_cursor()
              if text then
                translate.translate(text, nil, nil, function(result)
                  if result and hover_timers[bufnr] == timer then
                    ui.hover.show(result)
                  end
                end)
              else
                ui.hover.close()
              end
            end
          end)
          if not ok then
            vim.notify('comment-translate: hover error', vim.log.levels.DEBUG)
          end
        end)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = hover_group,
    callback = function()
      if is_hover_context(ui) then
        return
      end
      local bufnr = vim.api.nvim_get_current_buf()
      cleanup_timer(bufnr)

      vim.defer_fn(function()
        if is_hover_context(ui) then
          return
        end
        local text, _ = parser.get_text_at_cursor()
        if not text then
          ui.hover.close()
        end
      end, 100)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
    group = hover_group,
    callback = function(args)
      cleanup_timer(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = hover_group,
    callback = function()
      close_stale_hover(ui)
    end,
  })

  vim.api.nvim_create_autocmd('BufDelete', {
    group = hover_group,
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      cleanup_timer(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    group = hover_group,
    callback = function(args)
      cleanup_timer(args.buf)
      local hover_bufnr = ui.hover.bufnr()
      if hover_bufnr and hover_bufnr ~= args.buf then
        ui.hover.close()
      end
    end,
  })

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = hover_group,
    callback = function()
      for bufnr, _ in pairs(hover_timers) do
        cleanup_timer(bufnr)
      end
      ui.hover.close()
    end,
  })
end

function M.setup_immersive(commands, ui)
  local immersive_group = vim.api.nvim_create_augroup('CommentTranslateImmersive', { clear = true })
  local viewport = require('comment-translate.immersive.viewport')
  local config = require('comment-translate.config')

  ---@type table<integer, uv_timer_t>
  local debounce_timers = {}

  local function cancel_debounce(bufnr)
    local timer = debounce_timers[bufnr]
    if timer then
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
      debounce_timers[bufnr] = nil
    end
  end

  ---Run `fn` after the configured quiet period, collapsing bursts of events.
  ---@param bufnr integer
  ---@param delay integer
  ---@param fn fun()
  local function debounce(bufnr, delay, fn)
    cancel_debounce(bufnr)

    local timer = vim.loop.new_timer()
    if not timer then
      fn()
      return
    end

    debounce_timers[bufnr] = timer
    timer:start(
      delay,
      0,
      vim.schedule_wrap(function()
        cancel_debounce(bufnr)
        if vim.api.nvim_buf_is_valid(bufnr) then
          fn()
        end
      end)
    )
  end

  local function debounce_ms()
    return (config.config.immersive or {}).debounce_ms or 120
  end

  vim.api.nvim_create_autocmd({ 'WinScrolled', 'WinResized' }, {
    group = immersive_group,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      local bufnr = vim.api.nvim_get_current_buf()

      if is_hover_buffer(ui, bufnr) then
        return
      end
      if not commands.is_immersive_enabled(bufnr) then
        return
      end

      -- Only a change in topline is a real scroll; a changed botline alone
      -- means our own virt_lines pushed content down (design.md 6.3).
      local topline = vim.fn.line('w0', winid)
      if not viewport.should_reschedule(winid, topline) then
        return
      end

      debounce(bufnr, debounce_ms(), function()
        commands.ensure_visible(bufnr, winid)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = immersive_group,
    callback = function(args)
      if is_hover_buffer(ui, args.buf) then
        return
      end
      if not commands.is_immersive_enabled(args.buf) then
        return
      end

      debounce(args.buf, 250, function()
        commands.refresh_immersive(args.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = immersive_group,
    callback = function(args)
      local winid = tonumber(args.match)
      if winid then
        viewport.forget(winid)
      end
    end,
  })

  vim.api.nvim_create_autocmd('BufEnter', {
    group = immersive_group,
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      if is_hover_buffer(ui, bufnr) then
        return
      end

      if commands.is_immersive_globally_enabled() and not commands.is_immersive_enabled(bufnr) then
        commands.enable_immersive(bufnr)
      elseif commands.is_immersive_enabled(bufnr) then
        commands.update_immersive(bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd('BufWritePost', {
    group = immersive_group,
    callback = function(args)
      if commands.is_immersive_enabled(args.buf) then
        commands.refresh_immersive(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    group = immersive_group,
    callback = function(args)
      cancel_debounce(args.buf)
      ui.virtual_text.clear_buf(args.buf)
      commands.cleanup_buffer(args.buf)
    end,
  })

  local function cleanup_all_debounce()
    for bufnr, _ in pairs(debounce_timers) do
      cancel_debounce(bufnr)
    end
  end

  -- Invariant: no immersive timer may outlive the session (design.md 2.2).
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = immersive_group,
    callback = cleanup_all_debounce,
  })

  M.cleanup_immersive_timers = cleanup_all_debounce
end

function M.cleanup_all_timers()
  for bufnr, _ in pairs(hover_timers) do
    cleanup_timer(bufnr)
  end
  if M.cleanup_immersive_timers then
    M.cleanup_immersive_timers()
  end
end

function M.show_hover_on_demand()
  local refs = manual_hover_refs
  if not refs.parser or not refs.translate or not refs.ui then
    vim.notify('comment-translate: hover not initialized', vim.log.levels.WARN)
    return
  end

  local text, _ = refs.parser.get_text_at_cursor()
  if not text then
    vim.notify('No comment or string found', vim.log.levels.INFO)
    return
  end

  refs.translate.translate(text, nil, nil, function(result)
    if result then
      refs.ui.hover.show(result)
    else
      vim.notify('Translation failed', vim.log.levels.ERROR)
    end
  end)
end

return M
