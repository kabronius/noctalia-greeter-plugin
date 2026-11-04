#!/usr/bin/env python3
"""Privileged half of the Greeter Settings plugin, run through pkexec (or another privilege
command) by the panel.

    greeter_helper.py read
        Print the installed greeter.toml; exit 3 when there is none.
    greeter_helper.py install NEW_TOML [WALLPAPER]
        Install NEW_TOML as greeter.toml, keep the previous file as greeter.toml.bak and, when
        WALLPAPER is given, copy it in as wallpaper-custom.<ext>.
    greeter_helper.py sync-rule install|remove
        Install (or remove) a Polkit rule that lets the calling user run Noctalia's greeter
        sync helper, noctalia-greeter-apply-appearance, through pkexec without a password while
        in an active local session. Only helper paths owned by root along their whole path
        are allowed, otherwise the rule would hand root to anyone who can write the helper.

The caller is the desktop user and the state directory belongs to greetd's user, so neither
is trusted:
- the state directory is fixed; it is not taken from the caller;
- files in it are opened with O_NOFOLLOW relative to a directory fd and replaced by rename(2)
  from a root-only staging directory on the same filesystem, so a symlink or a swapped file
  in the state directory is never followed or written through;
- input files must be regular files owned by the calling user (PKEXEC_UID / SUDO_UID); a
  wallpaper may also be any world-readable regular file, never a root-only one;
- the wallpaper extension is restricted to image types, and the TOML is parsed here, after
  the last chance for the caller to change it.

Without root privileges (tests), NOCTALIA_GREETER_STATE_DIR may point elsewhere and
ownership is left unchanged.
"""

import json
import os
import pwd
import shutil
import stat
import sys
import tempfile
import tomllib

STATE_DIR = "/var/lib/noctalia-greeter"
GREETD_CONFIG = "/etc/greetd/config.toml"
IMAGE_EXTENSIONS = {"jpg", "jpeg", "png", "webp", "jxl", "bmp"}
MAX_TOML = 1 << 20
MAX_IMAGE = 64 << 20
RULES_DIR = "/etc/polkit-1/rules.d"
RULE_NAME = "50-noctalia-greeter-sync.rules"
# Paths Noctalia Shell runs the greeter sync helper from (it looks in /usr/bin, then
# /usr/local/bin), plus the install location they link to.
SYNC_HELPERS = (
    "/usr/bin/noctalia-greeter-apply-appearance",
    "/usr/local/bin/noctalia-greeter-apply-appearance",
    "/opt/noctalia-greeter/bin/noctalia-greeter-apply-appearance",
)


def fail(message, code=1):
    print(f"greeter_helper: {message}", file=sys.stderr)
    sys.exit(code)


def is_root():
    return os.geteuid() == 0


def caller_uid():
    for name in ("PKEXEC_UID", "SUDO_UID"):
        value = os.environ.get(name, "")
        if value.isdigit():
            return int(value)
    return os.getuid()


def state_dir():
    if not is_root():
        return os.environ.get("NOCTALIA_GREETER_STATE_DIR") or STATE_DIR
    return STATE_DIR


def greeter_account():
    """greetd's session user, which must own the state directory."""
    try:
        with open(GREETD_CONFIG, "rb") as handle:
            user = tomllib.load(handle).get("default_session", {}).get("user", "")
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {GREETD_CONFIG}: {error}")
    if not user:
        fail(f"no [default_session].user in {GREETD_CONFIG}")
    try:
        return pwd.getpwnam(user)
    except KeyError:
        fail(f"greetd user '{user}' does not exist")


def open_state_dir():
    path = state_dir()
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as error:
        fail(f"cannot open state directory {path}: {error}")
    info = os.fstat(fd)
    if is_root():
        account = greeter_account()
        if info.st_uid != account.pw_uid:
            fail(f"{path} is not owned by greetd's user {account.pw_name}")
        if info.st_mode & stat.S_IWOTH:
            fail(f"{path} is world-writable")
    return fd, path


def read_regular_nofollow(name, dir_fd=None, limit=MAX_TOML):
    """Contents of a regular file, never following a symlink at the last component."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OSError(f"{name} is not a regular file")
        if info.st_size > limit:
            raise OSError(f"{name} is larger than {limit} bytes")
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks), info
    finally:
        os.close(fd)


def read_caller_file(path, limit, allow_world_readable):
    """Input from the caller: a regular file it owns (or, for images, any public file)."""
    if not os.path.isabs(path):
        fail(f"{path} is not an absolute path")
    try:
        data, info = read_regular_nofollow(path, limit=limit)
    except OSError as error:
        fail(f"cannot read {path}: {error}")
    owned = info.st_uid == caller_uid()
    public = allow_world_readable and bool(info.st_mode & stat.S_IROTH)
    if not (owned or public):
        fail(f"{path} is neither owned by the caller nor world-readable")
    return data


def staged_replace(dir_fd, name, data, owner):
    """Write data to a root-only staging directory next to the state directory, then rename
    it over dir/name. rename(2) replaces the directory entry and never follows it."""
    parent = os.path.dirname(state_dir().rstrip("/")) or "/"
    staging = tempfile.mkdtemp(prefix=".noctalia-greeter-settings-", dir=parent)
    try:
        temp = os.path.join(staging, name)
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
            if owner is not None:
                os.fchown(fd, owner.pw_uid, owner.pw_gid)
            os.fchmod(fd, 0o640)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temp, name, dst_dir_fd=dir_fd)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def command_read():
    dir_fd, path = open_state_dir()
    try:
        data, _ = read_regular_nofollow("greeter.toml", dir_fd=dir_fd)
    except FileNotFoundError:
        sys.exit(3)
    except OSError as error:
        fail(f"cannot read {path}/greeter.toml: {error}")
    sys.stdout.buffer.write(data)


def command_install(new_toml, wallpaper):
    data = read_caller_file(new_toml, MAX_TOML, allow_world_readable=False)
    try:
        tomllib.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        fail(f"invalid TOML: {error}")

    image = None
    image_name = None
    if wallpaper:
        extension = wallpaper.rsplit(".", 1)[-1].lower() if "." in os.path.basename(wallpaper) else ""
        if extension not in IMAGE_EXTENSIONS:
            fail(f"unsupported wallpaper type '.{extension}'")
        image = read_caller_file(wallpaper, MAX_IMAGE, allow_world_readable=True)
        image_name = f"wallpaper-custom.{extension}"

    dir_fd, path = open_state_dir()
    owner = greeter_account() if is_root() else None
    try:
        if image is not None:
            staged_replace(dir_fd, image_name, image, owner)
        try:
            previous, _ = read_regular_nofollow("greeter.toml", dir_fd=dir_fd)
            staged_replace(dir_fd, "greeter.toml.bak", previous, owner)
        except FileNotFoundError:
            pass
        except OSError as error:
            fail(f"refusing to back up {path}/greeter.toml: {error}")
        staged_replace(dir_fd, "greeter.toml", data, owner)
    except OSError as error:
        fail(f"install failed: {error}")
    finally:
        os.close(dir_fd)


def rules_dir():
    if not is_root():
        return os.environ.get("NOCTALIA_GREETER_RULES_DIR") or RULES_DIR
    return RULES_DIR


def owner_name(uid):
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def root_owned_path(path, depth=0):
    """Reason the path is unsafe to run as root without a password, or None. Every
    component, from / to the file, must be owned by root and not group- or world-writable
    (symlinks only need a root owner); a symlink is followed and its target checked too."""
    current = "/"
    for part in [p for p in path.split("/") if p]:
        current = os.path.join(current, part)
        try:
            info = os.lstat(current)
        except OSError as error:
            return f"{current}: {error.strerror}"
        if info.st_uid != 0:
            return f"{current} is owned by {owner_name(info.st_uid)}, not root"
        if stat.S_ISLNK(info.st_mode):
            if depth >= 8:
                return f"{current}: too many symlinks"
            target = os.path.join(os.path.dirname(current), os.readlink(current))
            rest = path[len(current):]
            return root_owned_path(os.path.normpath(target + rest), depth + 1)
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            return f"{current} is writable by its group or by everyone"
    return None


def sync_rule_text(user, programs):
    return (
        "// Installed by the Greeter Settings plugin (kabronius/greeter-settings).\n"
        "// Noctalia's greeter sync runs noctalia-greeter-apply-appearance through pkexec on every\n"
        "// wallpaper or theme change; this user may run it without a password while in an active\n"
        "// local session. The helper must stay root-owned along its whole path.\n"
        "polkit.addRule(function (action, subject) {\n"
        f"    var programs = {json.dumps(programs)};\n"
        '    if (action.id == "org.freedesktop.policykit.exec" &&\n'
        '        programs.indexOf(action.lookup("program")) >= 0 &&\n'
        f"        subject.user == {json.dumps(user)} && subject.local && subject.active) {{\n"
        "        return polkit.Result.YES;\n"
        "    }\n"
        "});\n"
    )


def command_sync_rule(action):
    directory = rules_dir()
    target = os.path.join(directory, RULE_NAME)
    if action == "remove":
        try:
            os.unlink(target)
        except FileNotFoundError:
            pass
        except OSError as error:
            fail(f"cannot remove {target}: {error}")
        return

    try:
        user = pwd.getpwuid(caller_uid()).pw_name
    except KeyError:
        fail(f"unknown caller uid {caller_uid()}")
    if caller_uid() == 0:
        fail("refusing a rule for root")
    programs = []
    problems = []
    for path in SYNC_HELPERS:
        if not os.path.lexists(path):
            continue
        problem = root_owned_path(path)
        if problem is None:
            programs.append(path)
        else:
            problems.append(problem)
    if problems or not programs:
        fail(problems[0] if problems else "noctalia-greeter-apply-appearance not found")

    data = sync_rule_text(user, programs).encode()
    try:
        dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as error:
        fail(f"cannot open {directory}: {error}")
    try:
        temp = f".{RULE_NAME}.{os.getpid()}"
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=dir_fd)
        try:
            os.write(fd, data)
            os.fchmod(fd, 0o644)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temp, RULE_NAME, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except OSError as error:
        fail(f"cannot write {target}: {error}")
    finally:
        os.close(dir_fd)


def main(argv):
    if len(argv) == 2 and argv[1] == "read":
        command_read()
    elif len(argv) in (3, 4) and argv[1] == "install":
        command_install(argv[2], argv[3] if len(argv) == 4 else "")
    elif len(argv) == 3 and argv[1] == "sync-rule" and argv[2] in ("install", "remove"):
        command_sync_rule(argv[2])
    else:
        fail("usage: greeter_helper.py read | install NEW_TOML [WALLPAPER] | sync-rule install|remove", 2)


if __name__ == "__main__":
    main(sys.argv)
