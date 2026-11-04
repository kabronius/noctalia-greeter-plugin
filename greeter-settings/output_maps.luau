--!nonstrict
-- Per-output maps of greeter.toml's [output] table: layout, modes, refresh_rate, scales and
-- transforms are strings of `IDENTIFIER:VALUE` entries separated by semicolons, for example
-- "DP-1:1920x1080; HDMI-A-1:1920x1080". The value is everything after the last colon, as in
-- the greeter compositor, so identifiers may contain colons and spaces.

local M = {}

-- Ordered entries { { key = "DP-1", value = "1920x1080" }, ... }; malformed entries are dropped.
function M.parse(text)
  local entries = {}
  if type(text) ~= "string" then
    return entries
  end
  for token in text:gmatch("[^;]+") do
    local key, value = token:match("^%s*(.-)%s*:%s*([^:]-)%s*$")
    if key ~= nil and key ~= "" and value ~= "" then
      table.insert(entries, { key = key, value = value })
    end
  end
  return entries
end

function M.serialize(entries)
  local parts = {}
  for _, entry in ipairs(entries) do
    if entry.value ~= nil and entry.value ~= "" then
      table.insert(parts, `{entry.key}:{entry.value}`)
    end
  end
  return #parts > 0 and table.concat(parts, "; ") or nil
end

-- Index of the entry for an output, matched by connector name or stable identifier.
local function find(entries, names)
  for i, entry in ipairs(entries) do
    for _, name in ipairs(names) do
      if name ~= nil and name ~= "" and entry.key == name then
        return i
      end
    end
  end
  return nil
end

-- Value for an output, or nil. `names` lists the connector first, then the stable identifier.
function M.get(text, names)
  local entries = M.parse(text)
  local index = find(entries, names)
  return index ~= nil and entries[index].value or nil
end

-- New map text with the output's value replaced, added (under the connector name) or removed
-- (value nil). Other entries and their order are kept; nil when the map ends up empty.
function M.set(text, names, value)
  local entries = M.parse(text)
  local index = find(entries, names)
  if value == nil or value == "" then
    if index ~= nil then
      table.remove(entries, index)
    end
  elseif index ~= nil then
    entries[index].value = value
  else
    table.insert(entries, { key = names[1], value = value })
  end
  return M.serialize(entries)
end

-- "1920x1080" -> 1920, 1080
function M.parseSize(value)
  local w, h = (value or ""):match("^(%d+)[xX](%d+)$")
  return tonumber(w), tonumber(h)
end

-- "0,-420" -> 0, -420
function M.parsePosition(value)
  local x, y = (value or ""):match("^%s*(%-?%d+)%s*,%s*(%-?%d+)%s*$")
  return tonumber(x), tonumber(y)
end

-- Shortest decimal form: 60 -> "60", 59.951 -> "59.951", 1.25 -> "1.25".
function M.formatNumber(n)
  if n == nil then
    return nil
  end
  if n == math.floor(n) then
    return string.format("%d", n)
  end
  local text = string.format("%.3f", n):gsub("0+$", ""):gsub("%.$", "")
  return text
end

return M
