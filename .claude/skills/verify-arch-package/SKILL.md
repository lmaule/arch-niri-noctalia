---
name: verify-arch-package
description: Look up Arch Linux packages before using them in install-umbrinoc.sh — whether a package is in the official repos or only the AUR, its exact name, version, votes, dependencies, optional dependencies, and the files it installs (the real command name, .desktop file, systemd units, udev rules). Use whenever adding, renaming or replacing a package, choosing between AUR variants (-bin, -git), or setting a keybind/default app that needs a command or desktop-file name.
---

# Verify an Arch package

Never guess package names, command names or desktop-file names. In this repo
guesses were wrong several times: `helium-bin` (really `helium-browser-bin`),
Zed's command `zed` (really `zeditor`), Helium's desktop file
(`helium-browser.desktop`), Umbriel only existing as `umbriel-git`.

## Steps

1. Look the package up (run from the repo root):
   ```bash
   .claude/skills/verify-arch-package/scripts/pkginfo.py --files NAME...
   ```
   It prints official repo + version, or AUR version/votes/maintainer, deps and
   optdepends. `--files` lists binaries, `.desktop`, systemd/udev/portal files
   (official), or the PKGBUILD lines that install files (AUR).
2. Not found? Search, and prefer the most-voted, non-out-of-date match:
   ```bash
   .claude/skills/verify-arch-package/scripts/pkginfo.py --search WORD
   ```
3. Decide with these rules of thumb:
   - Official repo beats AUR. In the AUR, a `-bin` package (prebuilt) beats
     compiling, unless it's stale; `-git` builds the latest code (slow, can break).
   - Check **optdepends**: features often need them (e.g. `edk2-ovmf` + `swtpm`
     for Windows 11 VMs, Luciole's thumbnail/archive helpers).
   - Note setup the package does *not* do: services to enable, modules to load,
     MIME defaults, portal config (read its docs/PACKAGING.md when unsure).
   - For keybinds and `xdg-mime`, use the command and `.desktop` names from `--files`.
4. Report what you found (with versions) before changing the installer.

`pkginfo.py` uses curl, so it follows the session's proxy settings.
