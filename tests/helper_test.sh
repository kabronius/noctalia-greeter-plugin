#!/usr/bin/env bash
# Checks greeter_helper.py against symlink, ownership and file-type attacks.
# Runs unprivileged: the state directory is redirected with NOCTALIA_GREETER_STATE_DIR,
# which the helper honours only when it is not root. The owner check on the state
# directory itself needs root and is not covered here.
set -u

helper="$(cd "$(dirname "$0")/.." && pwd)/greeter_helper.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export NOCTALIA_GREETER_STATE_DIR="$work/state"
mkdir -p "$work/state"

failures=0
expect() { # name expected-exit command...
  local name=$1 want=$2
  shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [[ $got -eq $want ]]; then echo "ok   $name"; else echo "FAIL $name (exit $got, want $want)"; failures=$((failures + 1)); fi
}
check() { # name condition...
  local name=$1
  shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
}
run() { python3 -I "$helper" "$@"; }

echo SECRET > "$work/secret"
printf '[session]\ndefault = "Niri"\n' > "$work/new.toml"
printf '[appearance]\nhide_logo = true\n' > "$work/state/greeter.toml"
printf '\x89PNG\r\n\x1a\n' > "$work/img.png"

expect "install" 0 run install "$work/new.toml"
check "backup written" test -f "$work/state/greeter.toml.bak"

rm "$work/state/greeter.toml.bak"
ln -s "$work/secret" "$work/state/greeter.toml.bak"
expect "install over a symlinked backup" 0 run install "$work/new.toml"
check "symlink target untouched" grep -qx SECRET "$work/secret"
check "backup replaced, not followed" test ! -L "$work/state/greeter.toml.bak"

rm "$work/state/greeter.toml"
ln -s "$work/secret" "$work/state/greeter.toml"
expect "symlinked greeter.toml refused on install" 1 run install "$work/new.toml"
expect "symlinked greeter.toml refused on read" 1 run read
check "secret still intact" grep -qx SECRET "$work/secret"
rm "$work/state/greeter.toml"
printf '[a]\nx = 1\n' > "$work/state/greeter.toml"

mv "$work/state" "$work/state-real"
ln -s "$work/state-real" "$work/state"
expect "symlinked state directory refused" 1 run install "$work/new.toml"
rm "$work/state"
mv "$work/state-real" "$work/state"

ln -s "$work/new.toml" "$work/link.toml"
expect "symlinked input refused" 1 run install "$work/link.toml"
expect "input not owned by the caller refused" 1 run install /etc/passwd
expect "relative input refused" 1 bash -c "cd '$work' && python3 -I '$helper' install new.toml"
printf '[broken\n' > "$work/bad.toml"
expect "invalid TOML refused" 1 run install "$work/bad.toml"

printf 'polkit.addRule()' > "$work/x.rules"
expect "non-image wallpaper refused" 1 run install "$work/new.toml" "$work/x.rules"
ln -s "$work/img.png" "$work/link.png"
expect "symlinked wallpaper refused" 1 run install "$work/new.toml" "$work/link.png"
expect "own wallpaper accepted" 0 run install "$work/new.toml" "$work/img.png"
check "wallpaper copied" test -f "$work/state/wallpaper-custom.png"

expect "read" 0 run read
rm "$work/state/greeter.toml"
expect "read without greeter.toml exits 3" 3 run read

# sync-rule: the rule may only name helpers that are root-owned along their whole path.
export NOCTALIA_GREETER_RULES_DIR="$work/rules"
mkdir -p "$work/rules" "$work/bin"
touch "$work/bin/noctalia-greeter-apply-appearance"
ln -s "$work/bin/noctalia-greeter-apply-appearance" "$work/link-helper"
trust() { python3 -I -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("h", sys.argv[1]); h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
sys.exit(0 if h.root_owned_path(sys.argv[2]) is None else 1)' "$helper" "$1"; }
expect "root-owned path trusted" 0 trust /usr/bin/python3
expect "user-owned helper refused" 1 trust "$work/bin/noctalia-greeter-apply-appearance"
expect "symlink to a user-owned helper refused" 1 trust "$work/link-helper"
expect "unknown sync-rule action refused" 2 run sync-rule enable
printf 'old' > "$work/rules/50-noctalia-greeter-sync.rules"
expect "sync-rule remove" 0 run sync-rule remove
check "rule removed" test ! -e "$work/rules/50-noctalia-greeter-sync.rules"
expect "sync-rule remove without a rule" 0 run sync-rule remove

[[ $failures -eq 0 ]] || { echo "$failures check(s) failed"; exit 1; }
