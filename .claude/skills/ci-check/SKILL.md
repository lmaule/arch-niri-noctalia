---
name: ci-check
description: After pushing to arch-umbriel-noctalia, wait for the GitHub "Install test" (the real installer in an Arch container), report which checks passed or failed and why, warnings, and timings per step and per AUR build; compare two runs to measure a speed change. Use after every push that touches the installer or configs, when the user asks whether something works, or when measuring install speed.
---

# Check the GitHub install test

The workflow `.github/workflows/install-test.yml` runs `install-umbrinoc.sh
--yes --verbose --amd-gpu` as a normal user in `archlinux:latest`, validates the
Umbriel config with `umbriel config validate`, then checks files and packages.
It can't test booting, the login screen or the GPU.

## Wait for the result
```bash
.claude/skills/ci-check/scripts/watch-ci.sh            # run for HEAD
.claude/skills/ci-check/scripts/watch-ci.sh RUN_ID LOG # a specific run
```
Runs take ~8–14 minutes (Umbriel and Luciole compile from source). Run it in
the background and report when it finishes; don't poll in a tight loop. It
prints the run URL, each step's result, and saves the job log (exit 0 = passed).

## Read the log
```bash
.claude/skills/ci-check/scripts/ci-timings.py LOG              # one run
.claude/skills/ci-check/scripts/ci-timings.py BEFORE.log AFTER.log
```
Shows installer total, time per step, compile time per AUR package, time by
activity (compile, AUR fetch, downloads, installs, hooks), pacman transactions,
MB downloaded, warnings and the failing check.

## When it fails
- Find the failing step, then the first `error:`/`==> ERROR`/`WARNING` lines in
  the log around the installer step that failed (`grep -n` the saved log).
- Container-only causes seen before: no commented `[multilib]` block in the
  Docker image's pacman.conf; `systemctl --now` without running systemd.
  Fix the installer so it handles them — they can happen on real systems too.
- A `pacman -Q pkg` failure in "Check the installed files" usually means an
  optional app failed quietly: look for its `WARNING` in the log.

## Reporting speed
GitHub runners vary ~20% between runs. Compare activities, not just the total:
compile time for the *same* packages changing means runner variance, not your
change. Say so plainly rather than claiming a gain.
