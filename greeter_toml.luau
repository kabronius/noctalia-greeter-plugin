--!nonstrict
-- Line-preserving editor for the subset of TOML used by greeter.toml.
--
-- Only `key = scalar` lines inside `[section]` headers are read or written. Every other
-- line (comments, arrays of tables, inline tables, unmanaged keys) is kept verbatim, so
-- hand-written settings such as [appearance.palette] survive a save.

local M = {}


function M.splitLines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    table.insert(lines, line)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

function M.sectionOf(line)
  return line:match("^%s*%[%s*([^%[%]]-)%s*%]%s*$")
end

local function isTableHeader(line)
  return line:match("^%s*%[") ~= nil
end

local function keyOf(line)
  return line:match("^%s*([%w_%-]+)%s*=")
end

-- Locate `key` inside `[section]`: returns its line index (or nil), the header index (or nil)
-- and the index of the section's last non-blank line.
local function locate(doc, section, key)
  local current = ""
  local header, lastLine, found = nil, nil, nil
  for i, line in ipairs(doc.lines) do
    if isTableHeader(line) then
      current = M.sectionOf(line) or ("\0" .. line)
      if current == section then
        header = i
        lastLine = i
      end
    elseif current == section then
      if line:match("%S") then
        lastLine = i
      end
      if keyOf(line) == key then
        found = i
      end
    end
  end
  return found, header, lastLine
end

function M.decodeValue(raw)
  raw = raw:match("^%s*(.-)%s*$")
  if raw:sub(1, 1) == '"' then
    local out, i = {}, 2
    while i <= #raw do
      local c = raw:sub(i, i)
      if c == "\\" then
        local n = raw:sub(i + 1, i + 1)
        local map = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\" }
        table.insert(out, map[n] or n)
        i += 2
      elseif c == '"' then
        return table.concat(out)
      else
        table.insert(out, c)
        i += 1
      end
    end
    return table.concat(out)
  elseif raw:sub(1, 1) == "'" then
    return raw:match("^'(.-)'") or raw
  end
  local bare = (raw:match("^([^#]*)") or raw):match("^%s*(.-)%s*$")
  if bare == "true" then
    return true
  elseif bare == "false" then
    return false
  end
  local number = tonumber(bare)
  if number ~= nil then
    return number
  end
  return bare
end

function M.encodeValue(value)
  if type(value) == "boolean" then
    return value and "true" or "false"
  elseif type(value) == "number" then
    if value == math.floor(value) then
      return tostring(math.floor(value))
    end
    return string.format("%.2f", value)
  end
  local s = tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t")
  return '"' .. s .. '"'
end

function M.get(doc, section, key)
  local index = locate(doc, section, key)
  if index == nil then
    return nil
  end
  return M.decodeValue(doc.lines[index]:match("=%s*(.*)$") or "")
end

function M.set(doc, section, key, value)
  local index, header, lastLine = locate(doc, section, key)
  if value == nil then
    if index ~= nil then
      table.remove(doc.lines, index)
    end
    return
  end
  local line = `{key} = {M.encodeValue(value)}`
  if index ~= nil then
    doc.lines[index] = line
  elseif header ~= nil then
    table.insert(doc.lines, lastLine + 1, line)
  else
    if #doc.lines > 0 then
      table.insert(doc.lines, "")
    end
    table.insert(doc.lines, `[{section}]`)
    table.insert(doc.lines, line)
  end
end

-- Drop headers of managed sections left without keys after removals.
function M.pruneEmptySections(doc, managed)
  local i = 1
  while i <= #doc.lines do
    local name = M.sectionOf(doc.lines[i])
    if name ~= nil and managed[name] then
      local j = i + 1
      local hasContent = false
      while j <= #doc.lines and not isTableHeader(doc.lines[j]) do
        if doc.lines[j]:match("%S") then
          hasContent = true
        end
        j += 1
      end
      if not hasContent then
        for _ = i, j - 1 do
          table.remove(doc.lines, i)
        end
      else
        i = j
      end
    else
      i += 1
    end
  end
  M.tidyBlankLines(doc)
end

-- One blank line before every table header, no runs of blank lines, none at the ends.
function M.tidyBlankLines(doc)
  local out = {}
  for _, line in ipairs(doc.lines) do
    local blank = not line:match("%S")
    if blank then
      if #out > 0 and out[#out] ~= "" then
        table.insert(out, "")
      end
    else
      if isTableHeader(line) and #out > 0 and out[#out] ~= "" then
        table.insert(out, "")
      end
      table.insert(out, line)
    end
  end
  while #out > 0 and out[#out] == "" do
    table.remove(out)
  end
  doc.lines = out
end

return M
