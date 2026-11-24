--!nonstrict
local M = {}

function M.smsThread(thread)
  return type(thread) == "string" and thread ~= "" and thread:sub(1, 5) ~= "chat:"
end

-- Conversation lists mix two independently permitted sources. History
-- responses have no row kind; always classify those by their thread ID.
function M.withoutSms(data)
  if type(data) ~= "table" or type(data.items) ~= "table" then return data end
  local items = {}
  for _, row in ipairs(data.items) do
    if type(row) == "table" and row.kind ~= "sms" and not (row.kind == nil and M.smsThread(row.id)) then
      items[#items + 1] = row
    end
  end
  if #items == #data.items then return data end
  local result = {}
  for key, value in pairs(data) do result[key] = value end
  result.items = items
  return result
end

return M
