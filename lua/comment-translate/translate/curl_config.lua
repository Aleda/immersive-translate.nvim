local M = {}

---@param value any
---@return string
function M.quote(value)
  value = tostring(value)
  value = value:gsub('\\', '\\\\')
  value = value:gsub('"', '\\"')
  value = value:gsub('\n', '\\n')
  value = value:gsub('\r', '\\r')
  value = value:gsub('\t', '\\t')
  return '"' .. value .. '"'
end

---@param name string
---@param value any
---@return string
function M.option(name, value)
  return string.format('%s = %s', name, M.quote(value))
end

---@param lines string[]
---@return string
function M.build(lines)
  return table.concat(lines, '\n') .. '\n'
end

return M
