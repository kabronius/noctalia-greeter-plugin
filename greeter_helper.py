#!/usr/bin/env python3
"""Privileged half of the Greeter Settings plugin, run through pkexec (or another privilege
command) by the panel.

    greeter_helper.py read
        Print the installed greeter.toml; exit 3 when there is none.
    greeter_helper.py install NEW_TOML [WALLPAPER]
        Install NEW_TOML as greeter.toml, keep the previous file as greeter.toml.bak and, when
        WALLPAPER is given, copy it in as wallpaper-custom.<ext>.

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


def main(argv):
    if len(argv) == 2 and argv[1] == "read":
        command_read()
    elif len(argv) in (3, 4) and argv[1] == "install":
        command_install(argv[2], argv[3] if len(argv) == 4 else "")
    else:
        fail("usage: greeter_helper.py read | install NEW_TOML [WALLPAPER]", 2)


if __name__ == "__main__":
    main(sys.argv)
