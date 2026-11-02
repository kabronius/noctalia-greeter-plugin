--!nonstrict
-- Greeter Settings panel: edits Noctalia Greeter's greeter.toml.
--
-- The state directory (default /var/lib/noctalia-greeter) belongs to greetd's user and is
-- not readable by the desktop user, so the panel works on a copy in the plugin data dir:
--   import  pkexec reads the installed greeter.toml once into the copy;
--   save    the copy is rewritten (managed keys only), checked with Python's tomllib and
--           installed through pkexec with the directory's owner, keeping greeter.toml.bak;
--   preview the greeter compositor runs nested against a temporary copy.
-- Lines the panel does not manage (comments, palettes, other keys) are kept verbatim.

local BIN = noctalia.getConfig("greeter_bin_dir")
local STATE = noctalia.getConfig("state_dir")
local PRIVILEGE = noctalia.getConfig("privilege_command") or "pkexec"
local HOME = noctalia.getenv("HOME") or ""
local USER = noctalia.getenv("USER") or ""
local dataDir = noctalia.pluginDataDir() or (HOME .. "/.local/state/noctalia/greeter-settings")
local workPath = dataDir .. "/greeter.toml"
local pendingPath = dataDir .. "/greeter.toml.new"
local previewDir = dataDir .. "/preview"

-- argv prefix that runs a command as root, from the privilege_command setting.
local function privileged(argv)
  local out = {}
  for word in PRIVILEGE:gmatch("%S+") do
    table.insert(out, word)
  end
  for _, a in ipairs(argv) do
    table.insert(out, a)
  end
  return out
end

local function T(key, subst)
  return noctalia.tr("panel." .. key, subst)
end

local TOML = require("./greeter_toml.luau")
local doc = { lines = {} }

-- ── Managed fields ───────────────────────────────────────────────────────────────────

local lists = {
  sessions = {},
  users = {},
  outputs = {},
  cursors = {},
  schemes = { "Synced", "Noctalia", "Ayu", "Catppuccin", "Dracula", "Eldritch", "Gruvbox", "Kanagawa", "Nord", "Rosé Pine", "Tokyo-Night" },
  themeModes = { "dark", "light" },
  passwordStyles = { "default", "random" },
  corners = { "bottom-right", "bottom-left", "top-left", "top-right", "hidden" },
  clockPositions = { "above-panel", "top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right" },
  fillModes = { "crop", "fit", "center", "stretch", "repeat", "span" },
  cursorSizes = { 16, 24, 32, 48, 64 },
}

-- section, key: TOML location. Values hold the decoded value or nil (key absent).
local FIELDS = {
  { "session", "default" },
  { "user", "default" },
  { "appearance", "scheme" },
  { "appearance", "theme_mode" },
  { "appearance", "password_style" },
  { "appearance", "hide_logo" },
  { "appearance", "power_buttons_position" },
  { "appearance", "scheme_selector_position" },
  { "appearance", "font_family" },
  { "appearance", "corner_radius_scale" },
  { "appearance.wallpaper", "path" },
  { "appearance.wallpaper", "fill_mode" },
  { "appearance.wallpaper", "fill_color" },
  { "clock", "enabled" },
  { "clock", "position" },
  { "clock", "time_format" },
  { "clock", "date_format" },
  { "output", "name" },
  { "idle", "timeout" },
  { "cursor", "theme" },
  { "cursor", "size" },
  { "keyboard", "layout" },
  { "keyboard", "variant" },
  { "keyboard", "numlock" },
}

local MANAGED_SECTIONS = {}
for _, f in ipairs(FIELDS) do
  MANAGED_SECTIONS[f[1]] = true
end

local values = {}
local imported = false -- working copy reflects the installed file (or there is none)
local dirty = false
local busy = false
local status = ""
local statusIsError = false
local generation = 0 -- bumps input keys so uncontrolled inputs reseed after a reload
local previewRunning = false

local function id(section, key)
  return section .. "." .. key
end

local function loadValuesFromDoc()
  values = {}
  for _, f in ipairs(FIELDS) do
    values[id(f[1], f[2])] = TOML.get(doc, f[1], f[2])
  end
  generation += 1
end

local function setStatus(text, isError)
  status = text
  statusIsError = isError == true
end

local function loadWorkingCopy()
  local text = noctalia.readFile(workPath)
  if text ~= nil then
    doc.lines = TOML.splitLines(text)
    imported = true
    setStatus("")
  else
    doc.lines = {}
    imported = false
    setStatus(T("status.not_imported"))
  end
  loadValuesFromDoc()
  dirty = false
end

-- Wallpaper outside the state dir: _greetd cannot read the user's home, so copy it on save.
local function wallpaperCopy()
  local path = values["appearance.wallpaper.path"]
  if type(path) ~= "string" or path == "" or path:sub(1, 6) == "color:" then
    return nil, nil
  end
  if path:sub(1, #STATE + 1) == STATE .. "/" then
    return nil, nil
  end
  local ext = path:match("%.([%w]+)$") or "img"
  return path, `wallpaper-custom.{ext:lower()}`
end

local function renderDocText(forInstall)
  local saved = table.clone(doc.lines)
  for _, f in ipairs(FIELDS) do
    local value = values[id(f[1], f[2])]
    if value == "" then
      value = nil
    end
    TOML.set(doc, f[1], f[2], value)
  end
  if forInstall then
    local _, name = wallpaperCopy()
    if name ~= nil then
      TOML.set(doc, "appearance.wallpaper", "path", `{STATE}/{name}`)
    end
  end
  TOML.pruneEmptySections(doc, MANAGED_SECTIONS)
  local text = table.concat(doc.lines, "\n") .. "\n"
  local result = table.clone(doc.lines)
  doc.lines = saved
  return text, result
end

-- ── Lists from the system ────────────────────────────────────────────────────────────

local function linesOf(text)
  local out = {}
  for line in (text or ""):gmatch("[^\n]+") do
    line = noctalia.string.trim(line)
    if line ~= "" and not line:find(":%s*ERROR") then
      table.insert(out, line)
    end
  end
  return out
end

local render -- forward

local function loadLists()
  noctalia.runAsync({ BIN .. "/noctalia-greeter", "sessions" }, function(result)
    lists.sessions = linesOf(result.stdout)
    render()
  end, 10000)
  noctalia.runAsync({ BIN .. "/noctalia-greeter", "outputs" }, function(result)
    lists.outputs = linesOf(result.stdout)
    render()
  end, 10000)

  local users = {}
  for line in (noctalia.readFile("/etc/passwd") or ""):gmatch("[^\n]+") do
    local name, uid, shell = line:match("^([^:]+):[^:]*:(%d+):%d+:[^:]*:[^:]*:([^:]*)$")
    uid = tonumber(uid)
    if name ~= nil and uid ~= nil and uid >= 1000 and uid < 60000 and not shell:find("nologin") and not shell:find("false") then
      table.insert(users, name)
    end
  end
  table.sort(users)
  lists.users = users

  local cursors, seen = {}, {}
  for _, base in ipairs({ HOME .. "/.local/share/icons", HOME .. "/.icons", "/usr/share/icons" }) do
    for _, name in ipairs(noctalia.listDir(base) or {}) do
      if not seen[name] and noctalia.fileExists(`{base}/{name}/cursors`) then
        seen[name] = true
        table.insert(cursors, name)
      end
    end
  end
  table.sort(cursors)
  lists.cursors = cursors
end

-- ── Actions ──────────────────────────────────────────────────────────────────────────

local function lastLine(text)
  local last = ""
  for line in (text or ""):gmatch("[^\n]+") do
    last = line
  end
  return last
end

function onImport()
  busy = true
  setStatus(T("status.saving"))
  render()
  local script = 'f="$1/greeter.toml"; if [ -f "$f" ]; then cat "$f"; else exit 3; fi'
  noctalia.runAsync(privileged({ "/bin/sh", "-c", script, "greeter-settings", STATE }), function(result)
    busy = false
    if result.exitCode == 0 then
      noctalia.mkdirAll(dataDir)
      noctalia.writeFile(workPath, result.stdout)
      loadWorkingCopy()
      setStatus(T("status.imported"))
    elseif result.exitCode == 3 then
      noctalia.mkdirAll(dataDir)
      noctalia.writeFile(workPath, "")
      loadWorkingCopy()
      setStatus(T("status.no_file"))
    else
      setStatus(T("status.import_failed", { error = lastLine(result.stderr) ~= "" and lastLine(result.stderr) or `exit {result.exitCode}` }), true)
    end
    render()
  end, 60000)
end

function onSave()
  if busy or not imported then
    return
  end
  local text = renderDocText(true)
  noctalia.mkdirAll(dataDir)
  local ok, err = noctalia.writeFile(pendingPath, text)
  if not ok then
    setStatus(T("status.save_failed", { error = err or "write" }), true)
    render()
    return
  end
  busy = true
  setStatus(T("status.saving"))
  render()

  local check = "import sys, tomllib; tomllib.load(open(sys.argv[1], 'rb'))"
  noctalia.runAsync({ "python3", "-I", "-c", check, pendingPath }, function(validation)
    if validation.exitCode ~= 0 then
      busy = false
      setStatus(T("status.invalid", { error = lastLine(validation.stderr) }), true)
      render()
      return
    end
    local wallSrc, wallName = wallpaperCopy()
    local script = [[
set -eu
src=$1; dir=$2; wsrc=$3; wname=$4
owner=$(stat -c %U "$dir"); group=$(stat -c %G "$dir")
if [ -n "$wsrc" ]; then install -o "$owner" -g "$group" -m 0640 "$wsrc" "$dir/$wname"; fi
if [ -f "$dir/greeter.toml" ]; then cp -p "$dir/greeter.toml" "$dir/greeter.toml.bak"; fi
install -o "$owner" -g "$group" -m 0640 "$src" "$dir/greeter.toml"
]]
    local argv = privileged({ "/bin/sh", "-c", script, "greeter-settings", pendingPath, STATE, wallSrc or "", wallName or "" })
    noctalia.runAsync(argv, function(result)
      busy = false
      if result.exitCode == 0 then
        noctalia.renameFile(pendingPath, workPath)
        loadWorkingCopy()
        setStatus(T("status.saved"))
      else
        local reason = lastLine(result.stderr)
        if reason == "" then
          reason = result.timedOut and "timeout" or `exit {result.exitCode}`
        end
        setStatus(T("status.save_failed", { error = reason }), true)
      end
      render()
    end, 60000)
  end, 10000)
end

function onRevert()
  loadWorkingCopy()
  render()
end

function onPreview()
  if previewRunning then
    noctalia.runAsync({ "pkill", "-u", USER, "-f", BIN .. "/noctalia-greeter-compositor" })
    previewRunning = false
    setStatus("")
    render()
    return
  end
  if not noctalia.fileExists(BIN .. "/noctalia-greeter-compositor") then
    setStatus(T("status.missing_greeter", { dir = BIN }), true)
    render()
    return
  end
  noctalia.mkdirAll(previewDir)
  local text = renderDocText(false)
  noctalia.writeFile(previewDir .. "/greeter.toml", text)
  -- Detached; `timeout` closes a forgotten preview.
  local started = noctalia.runAsync({
    "env",
    "NOCTALIA_GREETER_STATE_DIR=" .. previewDir,
    "GREETER_BIN=" .. BIN .. "/noctalia-greeter",
    "timeout", "600",
    BIN .. "/noctalia-greeter-compositor", "--",
  })
  previewRunning = started
  setStatus(started and T("status.preview_running") or T("status.preview_failed", { error = "runAsync" }), not started)
  render()
end

function onClose()
  panel.close()
end

-- ── UI ───────────────────────────────────────────────────────────────────────────────

local function change(section, key, value)
  values[id(section, key)] = value
  dirty = true
  setStatus(T("status.unsaved"))
  render()
end

local function label(text, color)
  return ui.label({ text = text, color = color or "on_surface_variant", maxLines = 3 })
end

local function section(title, children)
  local body = { ui.label({ text = title, fontSize = 15, fontWeight = "semibold", color = "primary" }) }
  for _, child in ipairs(children) do
    table.insert(body, child)
  end
  return ui.column({ gap = 10, padding = 12, radius = 12, fill = "surface_variant" }, body)
end

local function field(text, control)
  return ui.column({ gap = 6 }, { ui.label({ text = text, color = "on_surface" }), control })
end

-- Select with a leading "Default" entry that removes the key. A value missing from
-- `choices` (set by hand) is kept as an extra option instead of being dropped.
local function selectField(text, section, key, choices, display)
  local current = values[id(section, key)]
  local options = { T("default") }
  local keys = { false }
  local selected = 0
  for _, choice in ipairs(choices) do
    table.insert(options, display and display(choice) or tostring(choice))
    table.insert(keys, choice)
    if current ~= nil and tostring(choice) == tostring(current) then
      selected = #options - 1
    end
  end
  if current ~= nil and selected == 0 then
    table.insert(options, tostring(current))
    table.insert(keys, current)
    selected = #options - 1
  end
  return field(text, ui.select({
    key = `select-{section}-{key}`,
    options = options,
    selectedIndex = selected,
    enabled = imported and not busy,
    onChange = function(index)
      local v = keys[(tonumber(index) or 0) + 1]
      change(section, key, v ~= false and v or nil)
    end,
  }))
end

local function toggleField(text, section, key, defaultValue)
  local current = values[id(section, key)]
  local checked = if current == nil then defaultValue else current == true
  return ui.row({ gap = 12, align = "center" }, {
    ui.label({ text = text, color = "on_surface", flexGrow = 1 }),
    ui.toggle({
      checked = checked,
      enabled = imported and not busy,
      onChange = function(v)
        change(section, key, v == "true")
      end,
    }),
  })
end

local function inputField(text, section, key, placeholder)
  local current = values[id(section, key)]
  return field(text, ui.input({
    key = `input-{section}-{key}-{generation}`,
    value = current ~= nil and tostring(current) or "",
    placeholder = placeholder or T("default"),
    enabled = imported and not busy,
    onChange = function(v)
      values[id(section, key)] = v ~= "" and v or nil
      dirty = true
      if status ~= T("status.unsaved") then
        setStatus(T("status.unsaved"))
        render()
      end
    end,
  }))
end

local function sliderField(textKey, section, key, min, max, step, format)
  local current = values[id(section, key)]
  local shown = current ~= nil and format(current) or T("default")
  return ui.column({ gap = 6 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = T(textKey, { value = shown }), color = "on_surface", flexGrow = 1 }),
      ui.button({
        text = T("default"),
        variant = "ghost",
        controlSize = "sm",
        enabled = imported and not busy and current ~= nil,
        onClick = function()
          change(section, key, nil)
        end,
      }),
    }),
    ui.slider({
      min = min,
      max = max,
      step = step,
      value = current ~= nil and current or min,
      enabled = imported and not busy,
      onChange = function(v)
        values[id(section, key)] = tonumber(v)
        dirty = true
        setStatus(T("status.unsaved"))
        render()
      end,
    }),
  })
end

local function outputLabel(name)
  return name
end

render = function()
  local outputs = {}
  for _, o in ipairs(lists.outputs) do
    table.insert(outputs, o)
  end

  local body = {
    section(T("sections.login"), {
      selectField(T("fields.session"), "session", "default", lists.sessions),
      selectField(T("fields.user"), "user", "default", lists.users),
    }),
    section(T("sections.appearance"), {
      selectField(T("fields.scheme"), "appearance", "scheme", lists.schemes),
      label(T("hints.synced")),
      selectField(T("fields.theme_mode"), "appearance", "theme_mode", lists.themeModes),
      selectField(T("fields.password_style"), "appearance", "password_style", lists.passwordStyles),
      toggleField(T("fields.hide_logo"), "appearance", "hide_logo", false),
      selectField(T("fields.power_buttons"), "appearance", "power_buttons_position", lists.corners),
      selectField(T("fields.scheme_selector"), "appearance", "scheme_selector_position", lists.corners),
      inputField(T("fields.font_family"), "appearance", "font_family"),
      sliderField("fields.corner_radius", "appearance", "corner_radius_scale", 0, 2, 0.1, function(v)
        return string.format("%.1f", v)
      end),
    }),
    section(T("sections.wallpaper"), {
      inputField(T("fields.wallpaper_path"), "appearance.wallpaper", "path", "/path/to/image.jpg"),
      label(T("hints.wallpaper")),
      selectField(T("fields.wallpaper_fill"), "appearance.wallpaper", "fill_mode", lists.fillModes),
      inputField(T("fields.wallpaper_color"), "appearance.wallpaper", "fill_color", "#13140d"),
    }),
    section(T("sections.clock"), {
      toggleField(T("fields.clock_enabled"), "clock", "enabled", true),
      selectField(T("fields.clock_position"), "clock", "position", lists.clockPositions),
      inputField(T("fields.time_format"), "clock", "time_format", "{:%H:%M}"),
      inputField(T("fields.date_format"), "clock", "date_format", "%A, %x"),
      label(T("hints.formats")),
    }),
    section(T("sections.outputs"), {
      selectField(T("fields.output_name"), "output", "name", outputs, outputLabel),
      sliderField("fields.idle", "idle", "timeout", 0, 1800, 30, function(v)
        if v <= 0 then
          return T("fields.idle_off")
        end
        return v >= 60 and string.format("%d min %02d s", v // 60, v % 60) or `{v} s`
      end),
    }),
    section(T("sections.input"), {
      selectField(T("fields.cursor_theme"), "cursor", "theme", lists.cursors),
      selectField(T("fields.cursor_size"), "cursor", "size", lists.cursorSizes),
      inputField(T("fields.keyboard_layout"), "keyboard", "layout", "us"),
      inputField(T("fields.keyboard_variant"), "keyboard", "variant"),
      toggleField(T("fields.numlock"), "keyboard", "numlock", false),
    }),
  }

  local header = {
    ui.label({ text = T("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    ui.button({ glyph = "close", variant = "ghost", onClick = onClose }),
  }

  local banner = {}
  if not imported then
    table.insert(banner, ui.button({ text = T("actions.import"), glyph = "download", variant = "primary", enabled = not busy, onClick = onImport }))
  end

  local footer = ui.row({ gap = 8, align = "center" }, {
    ui.button({ text = previewRunning and T("actions.stop_preview") or T("actions.preview"), glyph = "eye", variant = "outline", onClick = onPreview }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({ text = T("actions.revert"), variant = "ghost", enabled = imported and dirty and not busy, onClick = onRevert }),
    ui.button({ text = T("actions.save"), glyph = "device-floppy", variant = "primary", enabled = imported and dirty and not busy, onClick = onSave }),
  })

  local children = { ui.row({ align = "center", gap = 8 }, header) }
  if status ~= "" then
    table.insert(children, ui.label({ text = status, color = statusIsError and "error" or "on_surface_variant", maxLines = 4 }))
  end
  for _, b in ipairs(banner) do
    table.insert(children, b)
  end
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 12 }, body))
  table.insert(children, ui.label({ text = T("hints.preview"), color = "on_surface_variant", maxLines = 2 }))
  table.insert(children, footer)

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, children))
end

-- IPC, e.g. noctalia msg plugin kabronius/greeter-settings:panel all set clock.position=top-center
--   set <section.key>=<value>   value "" removes the key; true/false/numbers keep their type
--   import | save | preview | revert
function onIpc(event, payload)
  if event == "set" then
    local path, raw = (payload or ""):match("^%s*([^=]-)%s*=%s*(.-)%s*$")
    local sectionName, key = (path or ""):match("^(.*)%.([^%.]+)$")
    if sectionName == nil then
      noctalia.log("greeter-settings: set expects section.key=value, got " .. tostring(payload))
      return
    end
    local value = nil
    if raw ~= "" then
      value = TOML.decodeValue(raw:match('^".*"$') and raw or (tonumber(raw) ~= nil or raw == "true" or raw == "false") and raw or ('"' .. raw .. '"'))
    end
    change(sectionName, key, value)
  elseif event == "import" then
    onImport()
  elseif event == "save" then
    onSave()
  elseif event == "preview" then
    onPreview()
  elseif event == "revert" then
    onRevert()
  end
end

function onOpen(_context)
  loadWorkingCopy()
  if not noctalia.fileExists(BIN .. "/noctalia-greeter") then
    setStatus(T("status.missing_greeter", { dir = BIN }), true)
  end
  loadLists()
  render()
end
