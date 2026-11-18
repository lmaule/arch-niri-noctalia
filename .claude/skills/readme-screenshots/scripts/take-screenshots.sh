#!/usr/bin/env bash
# Re-take the README's installer screenshots from the current install script:
#   docs/installer.png      kitty / modern terminal (24-bit colour)
#   docs/installer-tty.png  Linux console (16 colours, plain symbols)
#
# The installer runs against the local-test stand-ins (nothing is installed),
# slowed with STUB_DELAY so a mid-install moment can be captured.
#
# Usage: take-screenshots.sh [SECONDS]   (moment to capture, default 3)
# Needs: python3 + pyte (pip install pyte), node + playwright with Chromium.

set -euo pipefail
here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
runner=$repo/.claude/skills/local-test/scripts/run-local-test.sh
at=${1:-3}
out=$(mktemp -d "${TMPDIR:-/tmp}/umbrinoc-shots.XXXXXX")

python3 -c 'import pyte' 2>/dev/null || { echo "pyte missing: pip install pyte" >&2; exit 2; }

shoot() {  # $1 = output name, rest = environment for the capture
  local name=$1; shift
  local run; run=$("$runner" --prepare-only)
  ( cd "$out" && env STUB_DELAY=0.5 "$@" python3 "$here/capture.py" "$run" "--yes" "$at" "$name" "" )
  [[ -f $out/$name-$at.html ]] || { echo "No snapshot at ${at}s for $name (install finished first?)" >&2; exit 1; }
}
shoot kitty COLORTERM=truecolor CAPTURE_TERM=xterm-256color
shoot tty CAPTURE_TERM=linux CAPTURE_BG='#000' CAPTURE_TITLE='Linux console (TTY) — ./install-umbrinoc.sh'

# Quick text check of what was captured.
for f in kitty tty; do
  python3 - "$out/$f-$at.html" "$f" <<'PY'
import html, re, sys
t = open(sys.argv[1]).read()
pre = re.search(r"<pre>(.*)</pre>", t, re.S).group(1)
lines = [l.strip() for l in html.unescape(re.sub(r"<[^>]+>", "", pre)).splitlines() if l.strip()]
bar = next((l for l in lines if re.search(r"\d+/\d+", l) and "%" in l), "(no progress bar)")
print(f"{sys.argv[2]:5}: {bar[-22:]}  |  running: {next((l[3:] for l in lines if l[:1] in '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏|/-\\\\' and 'skipped' not in l), '?')}")
PY
done

node -e '
const {chromium} = require("playwright");
(async () => {
  const [out, at, docs] = process.argv.slice(1);
  const b = await chromium.launch();
  const p = await b.newPage({deviceScaleFactor: 2, viewport: {width: 1100, height: 800}});
  for (const [f, o] of [["kitty", "installer.png"], ["tty", "installer-tty.png"]]) {
    await p.goto(`file://${out}/${f}-${at}.html`);
    await (await p.$(".win")).screenshot({path: `${docs}/${o}`});
  }
  await b.close();
})();' "$out" "$at" "$repo/docs"
echo "Updated $repo/docs/installer.png and installer-tty.png (snapshots in $out)"
