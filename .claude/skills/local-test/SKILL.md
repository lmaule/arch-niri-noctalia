---
name: local-test
description: Test install-umbrinoc.sh locally without an Arch system — run the whole installer against stand-in pacman/sudo/paru/makepkg/systemctl commands in a throwaway home folder and report exit code, steps, pacman transactions, packages and sudo prompts. Use after any change to the install script, before pushing, and to test failure handling, retry/skip, the sudo password flow, --yes/--no-blur/--no-greeter/--amd-gpu, or the one-go package fallback.
---

# Test the installer locally

The stand-ins (in `scripts/stubs/`) log what they would do and change nothing
on the machine. The stub pacman remembers installs, so `--needed`, removals
and transaction counts behave like the real thing. It works as root (the test
copy's "not as root" check is disabled).

## Run
From the repo root:
```bash
.claude/skills/local-test/scripts/run-local-test.sh --yes            # full install
.claude/skills/local-test/scripts/run-local-test.sh --yes --amd-gpu  # + AMD step
.claude/skills/local-test/scripts/run-local-test.sh --yes --no-blur --no-greeter
```
It prints the work folder, exit code, pacman transactions, packages installed,
sudo terminal prompts (must be 0), the steps run, warnings, and the log path.
The work folder is kept: inspect `home/` (installed configs), `home/umbrinoc-install.log`,
`home/pacman-transactions.log`, `home/sudo-calls.log`, `out.txt`.

## Scenarios (environment variables)
| Test | Command |
|---|---|
| One-go install fails → steps install their own packages | `STUB_FAIL_BATCH=1 …/run-local-test.sh --yes` |
| A step fails (with `--yes` the install stops, exit 1) | `STUB_FAIL_BATCH=1 STUB_FAIL_PKG=kitty …/run-local-test.sh --yes` |
| sudo needs a password (every call; password is `secret`) | `STUB_NOPASSWD= …` with the interactive run below |
| Slow it down (for screenshots) | `STUB_DELAY=0.5 …` |

## Interactive runs (questions, password, retry menu)
`--prepare-only` prints a `run.sh` that starts the installer in the test
folder. Drive it in a pseudo-terminal with `capture.py` (from the
`readme-screenshots` skill), which sends key presses at given seconds and saves
screen snapshots as HTML. Keys need real newlines, so build them with `$'...'`:
```bash
run=$(.claude/skills/local-test/scripts/run-local-test.sh --prepare-only)
STUB_NOPASSWD= python3 .claude/skills/readme-screenshots/scripts/capture.py \
  "$run" "" "3,9,40" shot $'1=y\n,1.6=y\n,2.4=secret\n,8=r'
```
(answers Continue and multilib, types the sudo password, presses `r` at a
failure if one is showing; snapshots at 3, 9 and 40 s — the last shows the
summary and the "Reboot now?" question). `shot-end.html` is written only if
the program exits before the last snapshot.

## What it can't test
Real packages, AUR builds, niri/Umbriel itself, the GPU, booting and the login
screen. Use the `ci-check` skill for the real-Arch test after pushing.
