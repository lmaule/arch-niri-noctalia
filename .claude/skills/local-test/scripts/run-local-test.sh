#!/usr/bin/env bash
# Run install-umbrinoc.sh against stand-in system commands in a throwaway
# folder: fake HOME, stub pacman/sudo/paru/makepkg/systemctl/... first on PATH.
# Nothing on this machine is installed or changed. Works as root (the copy's
# "not as root" check is disabled).
#
# Usage:
#   run-local-test.sh [--prepare-only] [--] [installer options, e.g. --yes --amd-gpu]
#
#   --prepare-only  set up the folder and print the path of a run.sh that
#                   starts the installer (for screenshots / interactive tests)
#
# Environment (passed through to the stubs):
#   STUB_NOPASSWD=1   (default) sudo needs no password; set to "" to make every
#                     sudo call require the password "secret"
#   STUB_FAIL_BATCH=1 make the one-go package install fail (tests the fallback)
#   STUB_FAIL_PKG=x   make the first install that includes package x fail once.
#                     Official packages are all in the one-go step, whose
#                     fallback absorbs that; add STUB_FAIL_BATCH=1 to make the
#                     step that installs x fail (retry/skip/quit, or --yes stops).
#   STUB_DELAY=0.5    slow every stub install down (for screenshots)
#   KEEP=0            delete the work folder after a successful run (default: keep it)

set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
[[ -f $repo/install-umbrinoc.sh ]] || { echo "install-umbrinoc.sh not found in $repo" >&2; exit 2; }

prepare_only=0
if [[ ${1:-} == --prepare-only ]]; then prepare_only=1; shift; fi
if [[ ${1:-} == -- ]]; then shift; fi

work=$(mktemp -d "${TMPDIR:-/tmp}/umbrinoc-test.XXXXXX")
mkdir -p "$work/repo" "$work/home" "$work/xdg"
chmod 700 "$work/xdg"
cp -r "$repo/config" "$repo/etc" "$repo/install-umbrinoc.sh" "$work/repo/"
cp -r "$here/stubs" "$work/stubs"          # makepkg writes paru into here
sed -i 's/^\[\[ \$EUID -eq 0 \]\] && die/false \&\& die/' "$work/repo/install-umbrinoc.sh"

cat > "$work/run.sh" <<EOF
#!/bin/bash
exec env STUB_NOPASSWD="\${STUB_NOPASSWD-1}" XDG_RUNTIME_DIR="$work/xdg" HOME="$work/home" USER=tester \\
  PATH="$work/stubs:/usr/local/bin:/usr/bin:/bin" bash "$work/repo/install-umbrinoc.sh" "\$@"
EOF
chmod +x "$work/run.sh"

if [[ $prepare_only -eq 1 ]]; then echo "$work/run.sh"; exit 0; fi

"$work/run.sh" "$@" > "$work/out.txt" 2>&1 < /dev/null
rc=$?
H=$work/home
count() { local c=0; if [[ -f $1 ]]; then c=$(grep -c "$2" "$1"); fi; echo "${c:-0}"; }
echo "work folder:          $work"
echo "installer exit code:  $rc"
echo "pacman transactions:  $(count "$H/pacman-transactions.log" '^TX') (one-go/-S: $(count "$H/pacman-transactions.log" '^TX -S'), -U: $(count "$H/pacman-transactions.log" '^TX -U'))"
echo "packages installed:   $(sort -u "$H/.stub-installed" 2>/dev/null | wc -l)"
echo "sudo terminal prompts: $(count "$H/sudo-calls.log" PROMPTED)  (must be 0)"
echo "steps run:"
sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$work/out.txt" | grep -E '^==> \[[0-9]+/[0-9]+\]|✘|Install stopped' | sed 's/^/   /'
sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$work/out.txt" | grep -E 'All done|WARNING' | sed 's/^/   /'
echo "log: $H/umbrinoc-install.log"
if [[ ${KEEP:-1} != 1 && $rc -eq 0 ]]; then rm -rf -- "$work"; fi
exit "$rc"
