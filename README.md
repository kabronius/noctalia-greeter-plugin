# Greeter Settings for Noctalia

A [Noctalia Shell](https://github.com/noctalia-dev/noctalia) plugin that edits the configuration of
[Noctalia Greeter](https://github.com/noctalia-dev/noctalia-greeter) from a panel: default session and
user, color scheme and appearance, wallpaper, clock, monitors, keyboard and cursor. A nested preview
shows the login screen with the unsaved changes.

![Greeter Settings panel, Appearance section](docs/panel.png)

The panel follows the layout of Noctalia's settings window: a sidebar with six sections (Login,
Appearance, Wallpaper, Clock, Monitors, Keyboard and cursor) and one row per setting, with the name and
a short explanation on the left and the control on the right. Every menu starts with **Default**, which
names the greeter's built-in value where it is known (for example *Default (Bottom right)*).

Noctalia Shell itself only offers **Sync Now** (wallpaper, palette, font, monitor layout). Everything
else lives in `greeter.toml`, which normally needs a text editor and root.

| | |
| --- | --- |
| Plugin id | `kabronius/greeter-settings` |
| Entries | panel `panel`, bar widget `bar` |
| Plugin API | 27 (Noctalia Shell 5.0.1 or newer) |
| Edits | `/var/lib/noctalia-greeter/greeter.toml` |
| License | Apache-2.0 |

## Installation

```sh
git clone https://github.com/kabronius/noctalia-greeter-plugin.git ~/src/noctalia-greeter-plugin
ln -s ~/src/noctalia-greeter-plugin ~/.local/share/noctalia/plugins/greeter-settings
noctalia msg plugins enable kabronius/greeter-settings
```

Open the panel with the bar widget (**Settings → Bar → Add widget → Greeter Settings**) or:

```sh
noctalia msg panel-toggle kabronius/greeter-settings:panel
```

Requirements: Noctalia Greeter installed, Python 3.11 or newer (`tomllib`), and a Polkit
authentication agent for `pkexec` (Noctalia's own: **Settings → Security → Polkit Agent**).

### Per-monitor settings

The **Monitors** section shows one card per display of the running session, with resolution, refresh
rate, scale, rotation and position. They are written to the `[output]` maps `modes`, `refresh_rate`,
`scales`, `transforms` and `layout`, keyed by connector name; entries keyed by a stable identifier
are matched and kept. **Default** removes the display's entry: the greeter then uses the EDID-preferred
mode, and Sync (`sync.toml`) for position, scale and rotation. **Copy from session** fills every
enabled display from the session; entries of displays that are not connected are kept.

The list of displays and their modes comes from `noctalia-greeter outputs --json`, which needs:

- Noctalia Greeter with `outputs --json` and the `[output].modes` key (fork
  [kabronius/noctalia-greeter](https://github.com/kabronius/noctalia-greeter), branch
  `feat/output-modes`); with an older greeter the section shows the error and only the global settings;
- a compositor that implements `wlr-output-management` (niri, Sway, Hyprland, other wlroots-based
  compositors).

Limits:

- the greeter selects only modes the display advertises over DRM; a custom mode of the session (niri
  `mode custom=true`) falls back to the preferred mode, so the logical size of that display can
  differ from the session's;
- choosing a refresh rate for one display turns a global numeric `refresh_rate` into the per-output
  map.

### Greeter sync without a password

With greeter auto sync enabled (`[shell.greeter_sync] auto_sync = true` in Noctalia's settings),
Noctalia Shell copies wallpaper, theme and display layout to the greeter on every change by running
`noctalia-greeter-apply-appearance` through `pkexec`, so a wallpaper rotation (Variety, slideshows)
asks for the administrator password each time. The **Sync** section installs
`/etc/polkit-1/rules.d/50-noctalia-greeter-sync.rules`, which allows that one program to the calling
user, in an active local session, without authentication; **Disable** removes the file.

The rule names `/usr/bin`, `/usr/local/bin` and `/opt/noctalia-greeter/bin` copies of the helper that
exist, and only when each one, through every directory and symlink target, is owned by root and not
writable by group or others: otherwise passwordless `pkexec` would run as root a file the user can
replace. A greeter copied into `/opt` with the user's ownership is refused with the offending path;
`sudo chown -R root:root /opt/noctalia-greeter` fixes it. What remains reachable without a password is
the helper itself, which reads the staging directory in `$XDG_RUNTIME_DIR` and writes only the greeter's
state, so the exposure is the login screen's appearance.

`/etc/polkit-1/rules.d` is readable only by root and polkitd, so the panel shows the state of the last
install or removal it made (a marker in the plugin data directory), not the file itself.

### Preview window size

The preview is a nested wlroots compositor; it appears as an ordinary window with app id `wlroots`
and asks for a 1280×720 output. A tiling compositor places it like any new window, so on niri it opens
as a narrow column next to the others, and a floating 1280×720 window does not fit a portrait monitor.
A full-width column fits every monitor and looks like the real login screen. On niri:

```kdl
// Noctalia Greeter preview (Greeter Settings plugin): the nested wlroots compositor.
window-rule {
  match app-id="^wlroots$"
  default-column-width { proportion 1.0; }
  open-focused true
}
```

The rule matches every nested wlroots compositor, not only the preview.

## Plugin settings

| Key | Default | Purpose |
| --- | --- | --- |
| `greeter_bin_dir` | `/opt/noctalia-greeter/bin` | Directory with `noctalia-greeter` and `noctalia-greeter-compositor`; `/usr/bin` for distribution packages |
| `privilege_command` | `pkexec` | Command prefix that runs `greeter_helper.py` as root, split on spaces (for example `run0`) |

The state directory is fixed at `/var/lib/noctalia-greeter`, the greeter's default; it is deliberately
not a setting (see [Security](#security)).

## Security

Reading and writing `greeter.toml` needs root, so the panel runs `greeter_helper.py` through
`privilege_command`. The helper treats both the panel's arguments and the contents of the state
directory as untrusted: the desktop session may be running other code as the same user, and the state
directory belongs to greetd's user, which handles input before anyone logs in.

| Risk | Handling in `greeter_helper.py` |
| --- | --- |
| Writing outside the greeter's directory | The state directory is hard-coded and must be owned by the `[default_session].user` of `/etc/greetd/config.toml` and not be world-writable |
| Symlinks or swapped files in the state directory | Files there are opened with `O_NOFOLLOW` relative to a directory fd and replaced with `rename(2)` from a root-only staging directory on the same filesystem; a symlinked `greeter.toml` is refused, a symlinked backup is replaced, never written through |
| Reading files the user may not read | Inputs must be absolute paths to regular files (no symlinks) owned by the calling user (`PKEXEC_UID`/`SUDO_UID`); a wallpaper may also be any world-readable file, never a root-only one |
| Planting non-image files | The wallpaper must end in `jpg`, `jpeg`, `png`, `webp`, `jxl` or `bmp` and is always installed as `wallpaper-custom.<ext>` |
| Malformed or swapped configuration | The TOML is parsed by the helper itself, after the last moment the caller could change it |
| Passwordless root through the sync rule | `sync-rule install` lists only helper paths owned by root along the whole path (symlink targets included) and not writable by group or others; the rule is limited to the calling user's active local session |

The panel's `set` IPC command accepts only the keys the panel manages, so a script cannot prepare
settings such as `[auth] allow_empty_password` for the user to save unknowingly. A save still asks
for the administrator password every time.

## IPC

The open panel accepts commands, useful for scripts:

```sh
P=kabronius/greeter-settings:panel
noctalia msg plugin $P all section clock                   # login, appearance, wallpaper, clock, outputs, input, sync
noctalia msg plugin $P all import
noctalia msg plugin $P all copy-session                    # per-monitor settings from the session
noctalia msg plugin $P all sync-rule install               # or remove; asks for the password once
noctalia msg plugin $P all set clock.position=top-center   # "key=" removes the key
noctalia msg plugin $P all set appearance.hide_logo=true
noctalia msg plugin $P all save
noctalia msg plugin $P all preview                         # again to close it
noctalia msg plugin $P all revert
```

`set` accepts only the keys listed in the panel; `true`/`false` and numbers keep their TOML type,
anything else is written as a string.

## Tests

`tests/greeter_toml_test.luau` covers reading, replacing, removing and adding keys, preservation of
comments and unmanaged sections, blank-line layout, string escaping and byte-identical no-op edits. It
needs a Luau interpreter whose `require` resolves paths relative to the requiring file; the edited
document it prints last can be checked with `python3 -c "import tomllib, sys; tomllib.load(sys.stdin.buffer)"`.

`tests/output_maps_test.luau` covers the per-output maps: parsing, lookup by connector or stable
identifier (also with colons), replacing, adding and removing entries, sizes, positions and number
formatting (24 checks). It runs with the same interpreter.

`tests/helper_test.sh` runs `greeter_helper.py` unprivileged against a temporary state directory and
checks the attacks listed under [Security]: symlinked `greeter.toml`, backup, state directory, input
and wallpaper, inputs not owned by the caller, relative paths, invalid TOML and non-image wallpapers; for
`sync-rule`, it checks that user-owned helpers (also through a symlink) are refused and that removal
works (26 checks). The ownership check on the state directory and writing into
`/etc/polkit-1/rules.d` run only as root and are not covered.

## Verification status

Checked with Noctalia Shell 5.0.1 and Noctalia Greeter 1.7.0 on Ubuntu 24.04:

- module tests: 20/20 and 24/24; helper tests: 26/26;
- panel loads, lists sessions, users, outputs and cursor themes, and renders imported values in all
  six sections;
- import of the installed `/var/lib/noctalia-greeter/greeter.toml` through `pkexec` and the Noctalia
  Polkit agent;
- import, edit and save through IPC and `greeter_helper.py` against a test state directory (`privilege_command = env NOCTALIA_GREETER_STATE_DIR=…`), including a refused `set` of an unmanaged key: keys
  replaced, removed and added, palette and comments preserved, `greeter.toml.bak` kept, result valid
  TOML with mode `0640`;
- preview window reflects unsaved changes (clock position, hidden logo, default session) and closes
  on the second request.
- with the niri rule above, the preview fills a 1080×1920 portrait monitor as a single column.
- Monitors section with the `feat/output-modes` greeter on niri (three displays, one rotated, one
  with a custom mode): cards list the advertised modes; **Copy from session** writes `modes`,
  `refresh_rate`, `scales`, `transforms` and `layout`, and the preview compositor reads the `modes`
  map.

Not exercised: a save into `/var/lib/noctalia-greeter` through `pkexec` (the install step was tested
with `privilege_command = env` only), the current-wallpaper button, and mode selection on real DRM
outputs at the login screen.
