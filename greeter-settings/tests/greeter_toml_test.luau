--!nonstrict
-- Tests for greeter_toml.luau. Run with a Luau CLI whose `require` resolves paths relative
-- to this file's directory. The edited document is printed last, so it can be piped into
-- Python's tomllib as a syntax check.

local TOML = require("../greeter_toml.luau")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures += 1
    print("FAIL " .. name .. (detail and ("  " .. tostring(detail)) or ""))
  end
end

local SAMPLE = [[
# comment at the top
[session]
# picker label
default = "niri"

[user]
default = "lysec"

[appearance]
scheme = "Synced"
hide_logo = false # inline comment
corner_radius_scale = 1.0

[appearance.palette]
primary = "#fff59b"
on_primary = "#0e0e43"

[idle]
timeout = 300

[cursor]
theme = "Adwaita"
size = 24
]]

local doc = { lines = TOML.splitLines(SAMPLE) }

-- Reading
check("string value", TOML.get(doc, "session", "default") == "niri")
check("bool with inline comment", TOML.get(doc, "appearance", "hide_logo") == false)
check("float value", TOML.get(doc, "appearance", "corner_radius_scale") == 1.0)
check("integer value", TOML.get(doc, "idle", "timeout") == 300)
check("key only in its section", TOML.get(doc, "appearance", "default") == nil)
check("dotted section", TOML.get(doc, "appearance.palette", "primary") == "#fff59b")
check("missing key", TOML.get(doc, "clock", "enabled") == nil)

-- Replace, remove, add
TOML.set(doc, "session", "default", "Niri")
check("replace keeps comment above", doc.lines[3] == "# picker label" and doc.lines[4] == 'default = "Niri"', doc.lines[4])
TOML.set(doc, "user", "default", nil)
check("remove key", TOML.get(doc, "user", "default") == nil)
TOML.set(doc, "appearance", "password_style", "random")
check("add key to existing section", TOML.get(doc, "appearance", "password_style") == "random")
TOML.set(doc, "clock", "position", "top-center")
check("add new section", TOML.get(doc, "clock", "position") == "top-center")
TOML.set(doc, "idle", "timeout", nil)
TOML.pruneEmptySections(doc, { user = true, idle = true, clock = true })
local text = table.concat(doc.lines, "\n")
check("empty managed sections pruned", not text:find("%[user%]") and not text:find("%[idle%]"), text)
check("palette kept verbatim", text:find('%[appearance%.palette%]\nprimary = "#fff59b"\non_primary = "#0e0e43"') ~= nil)
check("top comment kept", doc.lines[1] == "# comment at the top")
check("unmanaged section kept", TOML.get(doc, "cursor", "size") == 24)

-- A removed section in the middle leaves exactly one blank line between its neighbours
local mid = { lines = TOML.splitLines("[a]\nx = 1\n\n[b]\ny = 2\n\n[c]\nz = 3\n") }
TOML.set(mid, "b", "y", nil)
TOML.set(mid, "d", "w", 4)
TOML.pruneEmptySections(mid, { b = true })
check("blank line between sections", table.concat(mid.lines, "\n") == "[a]\nx = 1\n\n[c]\nz = 3\n\n[d]\nw = 4", table.concat(mid.lines, "\n"))

-- Escaping round trip
TOML.set(doc, "clock", "date_format", 'say "hi" \\ %A')
check("escaped string round trip", TOML.get(doc, "clock", "date_format") == 'say "hi" \\ %A', TOML.get(doc, "clock", "date_format"))
TOML.set(doc, "appearance", "corner_radius_scale", 1.25)
check("float encoding", TOML.get(doc, "appearance", "corner_radius_scale") == 1.25)

-- No-op on an untouched document keeps it byte-identical
local again = { lines = TOML.splitLines(SAMPLE) }
TOML.set(again, "session", "default", "niri")
TOML.set(again, "cursor", "size", 24)
check("no-op preserves text", table.concat(again.lines, "\n") .. "\n" == SAMPLE, table.concat(again.lines, "\n"))

-- Empty document
local empty = { lines = TOML.splitLines("") }
TOML.set(empty, "session", "default", "Niri")
check("first key in empty file", table.concat(empty.lines, "\n") == '[session]\ndefault = "Niri"', table.concat(empty.lines, "\n"))

print(table.concat(doc.lines, "\n"))
if failures > 0 then
  error(`{failures} check(s) failed`)
end
