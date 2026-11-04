--!nonstrict
-- Tests for output_maps.luau. Run with a Luau CLI whose `require` resolves paths relative
-- to this file's directory.

local Maps = require("../output_maps.luau")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures += 1
    print("FAIL " .. name .. (detail and ("  " .. tostring(detail)) or ""))
  end
end

local LAYOUT = "DP-1:0,-420; HDMI-A-1:1080,0"
local DP1 = { "DP-1", "LG Electronics - LG HDR 4K - DP-1" }
local EDP = { "eDP-1", "Unknown - Unknown - eDP-1" }

local entries = Maps.parse(LAYOUT)
check("parse keeps order", #entries == 2 and entries[1].key == "DP-1" and entries[2].key == "HDMI-A-1")
check("parse negative coordinates", entries[1].value == "0,-420", entries[1].value)
check("parse ignores malformed entries", #Maps.parse("DP-1; :1x1; HDMI-A-1:60") == 1)
check("parse non-string", #Maps.parse(120) == 0)

check("get by connector", Maps.get(LAYOUT, DP1) == "0,-420")
check("get missing output", Maps.get(LAYOUT, EDP) == nil)
check("get by stable identifier", Maps.get("LG Electronics - LG HDR 4K - DP-1:1920x1080", DP1) == "1920x1080")
check("identifier with colons", Maps.get("Vendor: Model:2560x1440", { "DP-9", "Vendor: Model" }) == "2560x1440")

check("set replaces in place", Maps.set(LAYOUT, DP1, "0,0") == "DP-1:0,0; HDMI-A-1:1080,0", Maps.set(LAYOUT, DP1, "0,0"))
check("set appends under the connector", Maps.set(LAYOUT, EDP, "3000,0") == LAYOUT .. "; eDP-1:3000,0")
check("set keeps identifier keys", Maps.set("LG Electronics - LG HDR 4K - DP-1:60", DP1, "75") == "LG Electronics - LG HDR 4K - DP-1:75")
check("set nil removes", Maps.set(LAYOUT, DP1, nil) == "HDMI-A-1:1080,0")
check("set empty removes", Maps.set(LAYOUT, DP1, "") == "HDMI-A-1:1080,0")
check("removing the last entry gives nil", Maps.set("DP-1:60", DP1, nil) == nil)
check("set on nil map", Maps.set(nil, EDP, "2560x1600") == "eDP-1:2560x1600")

local w, h = Maps.parseSize("1920x1080")
check("parseSize", w == 1920 and h == 1080)
check("parseSize rejects junk", Maps.parseSize("1920x") == nil)
local x, y = Maps.parsePosition(" 0 , -420 ")
check("parsePosition", x == 0 and y == -420)
check("parsePosition rejects junk", Maps.parsePosition("0;1") == nil)

check("formatNumber integer", Maps.formatNumber(60) == "60")
check("formatNumber float integer", Maps.formatNumber(1.0) == "1")
check("formatNumber fraction", Maps.formatNumber(119.904) == "119.904", Maps.formatNumber(119.904))
check("formatNumber trims zeros", Maps.formatNumber(1.25) == "1.25", Maps.formatNumber(1.25))
check("formatNumber nil", Maps.formatNumber(nil) == nil)

print(failures == 0 and "all passed" or `{failures} failed`)
