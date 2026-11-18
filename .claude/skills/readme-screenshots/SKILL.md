---
name: readme-screenshots
description: Re-take the README's installer screenshots (docs/installer.png in kitty colours, docs/installer-tty.png as the Linux console) from the current install-umbrinoc.sh. Use when the installer's steps, step titles, banner, colours or log name change, or the user asks to update the README screenshots.
---

# Update the README screenshots

## Run
From the repo root:
```bash
.claude/skills/readme-screenshots/scripts/take-screenshots.sh      # moment: 3 s
.claude/skills/readme-screenshots/scripts/take-screenshots.sh 4    # later moment
```
It runs the installer against the `local-test` stand-ins (slowed with
`STUB_DELAY`, nothing installed) in a 96×34 virtual terminal (`capture.py`,
using pyte), snapshots it mid-install, and renders both images with Playwright
into `docs/`. It prints the progress bar and the running step for each, e.g.
`7/16 … running: Luciole, phones and network shares`.

## Check before committing
- View both PNGs. Pick the moment so an interesting step is running (adjust
  the seconds argument); "install finished first" means pick an earlier time.
- The banner needs ≥ N+17 terminal rows (N = steps); with more steps, raise
  `ROWS` in `capture.py` or the banner is replaced by a one-line title.
- Commit only `docs/installer.png` and `docs/installer-tty.png`.

## Requirements
`pip install pyte`; Node with Playwright and Chromium (`require('playwright')`).
The kitty look uses `COLORTERM=truecolor` with `TERM=xterm-256color`, because
the `xterm-kitty` terminfo may be missing in a sandbox (which mis-centres the
layout). The TTY look uses `TERM=linux` and the VGA palette.
