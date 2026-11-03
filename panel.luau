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
-- Fixed, like in greeter_helper.py: the privileged side never takes it from settings.
local STATE = "/var/lib/noctalia-greeter"
local HELPER = (noctalia.pluginDir() or ".") .. "/greeter_helper.py"
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

-- Same list as greeter_helper.py.
local IMAGE_EXTENSIONS = { jpg = true, jpeg = true, png = true, webp = true, jxl = true, bmp = true }

-- Wallpaper outside the state dir: _greetd cannot read the user's home, so copy it on save.
-- Returns the source path and its name in the state dir, or nil plus an error message.
local function wallpaperCopy()
  local path = values["appearance.wallpaper.path"]
  if type(path) ~= "string" or path == "" or path:sub(1, 6) == "color:" then
    return nil, nil
  end
  if path:sub(1, #STATE + 1) == STATE .. "/" then
    return nil, nil
  end
  local ext = (path:match("%.([%w]+)$") or ""):lower()
  if not IMAGE_EXTENSIONS[ext] then
    return nil, nil, `unsupported wallpaper type '.{ext}'`
  end
  return path, `wallpaper-custom.{ext}`
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
  noctalia.runAsync(privileged({ "/usr/bin/python3", "-I", HELPER, "read" }), function(result)
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
  local _, _, wallpaperError = wallpaperCopy()
  if wallpaperError ~= nil then
    setStatus(T("status.save_failed", { error = wallpaperError }), true)
    render()
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
    -- greeter_helper.py re-validates everything: it runs as root and trusts none of this.
    local wallSrc = wallpaperCopy()
    local argv = privileged({ "/usr/bin/python3", "-I", HELPER, "install", pendingPath })
    if wallSrc ~= nil then
      table.insert(argv, wallSrc)
    end
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

-- The preview can also end on its own (timeout, window closed): ask the system.
local function refreshPreviewState(after)
  noctalia.processMatches(function(matched)
    previewRunning = matched
    if after then
      after()
    end
  end, BIN .. "/noctalia-greeter-compositor", "--")
end

local function togglePreview()
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

function onPreview()
  refreshPreviewState(togglePreview)
end

function onClose()
  panel.close()
end

-- ── UI ───────────────────────────────────────────────────────────────────────────────

local currentSection = 1
local importAttempted = false
local CONTROL_WIDTH = 300

local function change(section, key, value)
  values[id(section, key)] = value
  dirty = true
  setStatus(T("status.unsaved"))
  render()
end

local function markDirty()
  dirty = true
  if status ~= T("status.unsaved") then
    setStatus(T("status.unsaved"))
    render()
  end
end

-- Translated label for a TOML value; falls back to the raw value.
local function valueLabel(group, value)
  if group == nil then
    return tostring(value)
  end
  local key = `panel.values.{group}.{tostring(value)}`
  local text = noctalia.tr(key)
  return (text ~= "" and text ~= key) and text or tostring(value)
end

local function defaultLabel(group, builtin)
  if builtin == nil then
    return T("default")
  end
  return T("default_with", { value = valueLabel(group, builtin) })
end

-- One setting: title and optional description on the left, control on the right.
local function row(title, description, control)
  local text = { ui.label({ text = title, color = "on_surface", fontWeight = "medium" }) }
  if description ~= nil then
    table.insert(text, ui.label({ text = description, color = "on_surface_variant", fontSize = 12, maxLines = 3 }))
  end
  return ui.row({ gap = 16, align = "center", paddingV = 4 }, {
    ui.column({ gap = 2, flexGrow = 1 }, text),
    ui.column({ width = CONTROL_WIDTH }, { control }),
  })
end

local function editable()
  return imported and not busy
end

-- Select whose first entry ("Default") removes the key. A value missing from `choices`
-- (written by hand) is kept as an extra entry instead of being dropped.
local function selectRow(title, description, section, key, choices, group, builtin)
  local current = values[id(section, key)]
  local options = { defaultLabel(group, builtin) }
  local keys = { false }
  local selected = 0
  for _, choice in ipairs(choices) do
    table.insert(options, valueLabel(group, choice))
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
  return row(title, description, ui.select({
    key = `select-{section}-{key}`,
    options = options,
    selectedIndex = selected,
    enabled = editable(),
    onChange = function(index)
      local v = keys[(tonumber(index) or 0) + 1]
      change(section, key, v ~= false and v or nil)
    end,
  }))
end

local function toggleRow(title, description, section, key, builtin)
  local current = values[id(section, key)]
  local checked = if current == nil then builtin else current == true
  return row(title, description, ui.row({ justify = "end" }, {
    ui.toggle({
      checked = checked,
      enabled = editable(),
      onChange = function(v)
        change(section, key, v == "true")
      end,
    }),
  }))
end

local function inputRow(title, description, section, key, placeholder)
  local current = values[id(section, key)]
  return row(title, description, ui.input({
    key = `input-{section}-{key}-{generation}`,
    value = current ~= nil and tostring(current) or "",
    placeholder = placeholder or T("default"),
    enabled = editable(),
    onChange = function(v)
      values[id(section, key)] = v ~= "" and v or nil
      markDirty()
    end,
  }))
end

local function sliderRow(title, section, key, min, max, step, format)
  local current = values[id(section, key)]
  return row(title, current ~= nil and format(current) or T("default"), ui.row({ gap = 8, align = "center" }, {
    ui.slider({
      flexGrow = 1,
      min = min,
      max = max,
      step = step,
      value = current ~= nil and current or min,
      enabled = editable(),
      onChange = function(v)
        values[id(section, key)] = tonumber(v)
        dirty = true
        setStatus(T("status.unsaved"))
        render()
      end,
    }),
    ui.button({
      glyph = "arrow-back-up",
      variant = "ghost",
      controlSize = "sm",
      tooltip = T("default"),
      enabled = editable() and current ~= nil,
      onClick = function()
        change(section, key, nil)
      end,
    }),
  }))
end

-- Path input plus a button that takes the wallpaper Noctalia currently shows.
local function wallpaperRow()
  local section, key = "appearance.wallpaper", "path"
  local current = values[id(section, key)]
  return row(T("fields.wallpaper_path"), T("hints.wallpaper"), ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = `input-{section}-{key}-{generation}`,
      flexGrow = 1,
      value = current ~= nil and tostring(current) or "",
      placeholder = T("default"),
      enabled = editable(),
      onChange = function(v)
        values[id(section, key)] = v ~= "" and v or nil
        markDirty()
      end,
    }),
    ui.button({
      glyph = "photo-check",
      variant = "outline",
      tooltip = T("actions.current_wallpaper"),
      enabled = editable(),
      onClick = function()
        local output = noctalia.focusedOutputName()
        local path = output ~= nil and noctalia.wallpaperPath(output) or nil
        if path ~= nil and path ~= "" then
          values[id(section, key)] = path
          generation += 1 -- reseed the uncontrolled input with the new path
          change(section, key, path)
        end
      end,
    }),
  }))
end

local function minutes(v)
  if v <= 0 then
    return T("fields.idle_off")
  end
  return v >= 60 and string.format("%d min %02d s", v // 60, v % 60) or `{v} s`
end

local SECTIONS = {
  {
    key = "login",
    glyph = "login",
    rows = function()
      return {
        selectRow(T("fields.session"), T("hints.session"), "session", "default", lists.sessions),
        selectRow(T("fields.user"), T("hints.user"), "user", "default", lists.users),
        selectRow(T("fields.password_style"), nil, "appearance", "password_style", lists.passwordStyles, "password", "default"),
      }
    end,
  },
  {
    key = "appearance",
    glyph = "palette",
    rows = function()
      return {
        selectRow(T("fields.scheme"), T("hints.synced"), "appearance", "scheme", lists.schemes),
        selectRow(T("fields.theme_mode"), nil, "appearance", "theme_mode", lists.themeModes, "theme"),
        inputRow(T("fields.font_family"), T("hints.font"), "appearance", "font_family", "Noto Sans"),
        sliderRow(T("fields.corner_radius"), "appearance", "corner_radius_scale", 0, 2, 0.1, function(v)
          return string.format("%.1f×", v)
        end),
        toggleRow(T("fields.hide_logo"), nil, "appearance", "hide_logo", false),
        selectRow(T("fields.power_buttons"), nil, "appearance", "power_buttons_position", lists.corners, "corner", "bottom-right"),
        selectRow(T("fields.scheme_selector"), nil, "appearance", "scheme_selector_position", lists.corners, "corner", "top-right"),
      }
    end,
  },
  {
    key = "wallpaper",
    glyph = "photo",
    rows = function()
      return {
        wallpaperRow(),
        selectRow(T("fields.wallpaper_fill"), nil, "appearance.wallpaper", "fill_mode", lists.fillModes, "fill"),
        inputRow(T("fields.wallpaper_color"), T("hints.color"), "appearance.wallpaper", "fill_color", "#13140d"),
      }
    end,
  },
  {
    key = "clock",
    glyph = "clock",
    rows = function()
      return {
        toggleRow(T("fields.clock_enabled"), nil, "clock", "enabled", true),
        selectRow(T("fields.clock_position"), nil, "clock", "position", lists.clockPositions, "clock", "above-panel"),
        inputRow(T("fields.time_format"), T("hints.formats"), "clock", "time_format", "{:%H:%M}"),
        inputRow(T("fields.date_format"), nil, "clock", "date_format", "%A, %x"),
      }
    end,
  },
  {
    key = "outputs",
    glyph = "device-desktop",
    rows = function()
      return {
        selectRow(T("fields.output_name"), T("hints.output"), "output", "name", lists.outputs, nil, nil),
        sliderRow(T("fields.idle"), "idle", "timeout", 0, 1800, 30, minutes),
      }
    end,
  },
  {
    key = "input",
    glyph = "keyboard",
    rows = function()
      return {
        inputRow(T("fields.keyboard_layout"), T("hints.layout"), "keyboard", "layout", "us"),
        inputRow(T("fields.keyboard_variant"), nil, "keyboard", "variant"),
        toggleRow(T("fields.numlock"), nil, "keyboard", "numlock", false),
        selectRow(T("fields.cursor_theme"), nil, "cursor", "theme", lists.cursors),
        selectRow(T("fields.cursor_size"), nil, "cursor", "size", lists.cursorSizes),
      }
    end,
  },
}

render = function()
  local nav = {}
  for index, section in ipairs(SECTIONS) do
    table.insert(nav, ui.button({
      text = T(`sections.{section.key}`),
      glyph = section.glyph,
      variant = "ghost",
      contentAlign = "start",
      selected = index == currentSection,
      onClick = function()
        currentSection = index
        render()
      end,
    }))
  end
  table.insert(nav, ui.spacer({ flexGrow = 1 }))
  table.insert(nav, ui.button({
    text = previewRunning and T("actions.stop_preview") or T("actions.preview"),
    glyph = previewRunning and "eye-off" or "eye",
    variant = "outline",
    tooltip = T("hints.preview"),
    onClick = onPreview,
  }))

  local section = SECTIONS[currentSection]
  local content = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = T(`sections.{section.key}`), fontSize = 18, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", onClick = onClose }),
    }),
  }
  if not imported then
    table.insert(content, ui.row({ gap = 12, align = "center", padding = 12, radius = 12, fill = "surface_variant" }, {
      ui.label({ text = status ~= "" and status or T("status.not_imported"), color = statusIsError and "error" or "on_surface", flexGrow = 1, maxLines = 3 }),
      ui.button({ text = T("actions.import"), glyph = "download", variant = "primary", enabled = not busy, onClick = onImport }),
    }))
  end
  table.insert(content, ui.scroll({ flexGrow = 1, gap = 6 }, section.rows()))

  local footerText = imported and status or ""
  table.insert(content, ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = footerText, color = statusIsError and "error" or "on_surface_variant", flexGrow = 1, maxLines = 2 }),
    ui.button({ text = T("actions.revert"), variant = "ghost", enabled = imported and dirty and not busy, onClick = onRevert }),
    ui.button({ text = T("actions.save"), glyph = "device-floppy", variant = "primary", enabled = imported and dirty and not busy, onClick = onSave }),
  }))

  panel.render(ui.row({ flexGrow = 1, gap = 16 }, {
    ui.column({ width = 230, gap = 4, padding = 8, radius = 12, fill = "surface_variant" }, nav),
    ui.column({ flexGrow = 1, gap = 12 }, content),
  }))
end

-- IPC, e.g. noctalia msg plugin kabronius/greeter-settings:panel all set clock.position=top-center
--   set <section.key>=<value>   value "" removes the key; true/false/numbers keep their type
--   section <login|appearance|wallpaper|clock|outputs|input>
--   import | save | preview | revert
function onIpc(event, payload)
  if event == "section" then
    for index, entry in ipairs(SECTIONS) do
      if entry.key == payload then
        currentSection = index
        render()
      end
    end
  elseif event == "set" then
    local path, raw = (payload or ""):match("^%s*([^=]-)%s*=%s*(.-)%s*$")
    local sectionName, key = (path or ""):match("^(.*)%.([^%.]+)$")
    if sectionName == nil then
      noctalia.log("greeter-settings: set expects section.key=value, got " .. tostring(payload))
      return
    end
    local managed = false
    for _, f in ipairs(FIELDS) do
      if f[1] == sectionName and f[2] == key then
        managed = true
      end
    end
    if not managed then
      noctalia.log("greeter-settings: set refuses unmanaged key " .. path)
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
  loadLists()
  refreshPreviewState(function()
    render()
  end)
  if not noctalia.fileExists(BIN .. "/noctalia-greeter") then
    setStatus(T("status.missing_greeter", { dir = BIN }), true)
  elseif not imported and not importAttempted then
    -- First open: read the installed file straight away instead of waiting for a click.
    importAttempted = true
    onImport()
    return
  end
  render()
end
