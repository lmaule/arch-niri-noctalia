---
name: add-app
description: Add (or remove/replace) an app or package in the UMBRINOC installer, install-umbrinoc.sh — verify the package, put it in the right step and package list, update keybinds, README tables and the CI package check, test locally and on GitHub. Use when the user asks to add, swap or drop an application, tool, font or driver in this repo.
---

# Add an app to the installer

Follow every step; skipping the README or CI updates has been the usual miss.

## 1. Verify the package
Use the `verify-arch-package` skill (`scripts/pkginfo.py --files NAME`): exact
name, official vs AUR, `-bin`/`-git` choice, optdepends worth installing, the
real command and `.desktop` names, and any setup it needs (services, modules,
MIME defaults, portal or config files). Don't proceed on a guessed name.

## 2. Put it in `install-umbrinoc.sh`
- **Official-repo packages:** add to the matching `PKGS_*` array near the top
  (`PKGS_DESKTOP`, `PKGS_ZSH`, `PKGS_FONTS`, `PKGS_FILES`, `PKGS_APPS`,
  `PKGS_GAMING`, `PKGS_KEYRING`, `PKGS_THEMING`; AMD packages go in
  `amd_packages()`). `step_packages` installs them all in one pacman run and
  each step re-installs its own list with `--needed`.
  Optional apps (failure must not stop the install) go in `PKGS_APPS`, and
  their step uses `install_one_of "Label" pkg || true`.
- **AUR packages:** in the step that owns them, use
  `install_one_of "Label" pkg-bin pkg || true` for optional apps (first found
  wins, failures become summary warnings) or `install_pkg pkg` for core parts.
- **Replacing a package:** ask up front, like `REMOVE_NIRI`/`REMOVE_NAUTILUS`
  (a `confirm` in the questions block, used in the step), never mid-install.
- **Setup:** services via `svc_enable` (never `systemctl enable --now`
  directly — containers/chroots have no running systemd); user config files
  via `install_config` (backs up a different existing file) or written only if
  missing; `warn` for anything the user should look at (shown in the summary).
- **New step?** Add to both `STEP_FN` and `STEP_TITLE`; look steps up with
  `step_index`, never by number.

## 3. Keybinds and config
Umbriel keybinds are in `config/umbriel/cfg/keybinds.toml` (Umbriel action
names; check for an existing bind on the same key). Noctalia colour templates
are `builtin_ids` in `config/noctalia/config.toml`.

## 4. README and CI
- README: Highlights, "What it installs" table (AUR packages get the ¹
  footnote and are listed in it), "What it configures", both keybind tables,
  Troubleshooting if there's a known pitfall.
- `.github/workflows/install-test.yml`: add the package to the `pacman -Q` list
  and a file check for any config the step writes.

## 5. Test
```bash
bash -n install-umbrinoc.sh && shellcheck -S warning install-umbrinoc.sh
```
Then the `local-test` skill (`--yes`, plus `STUB_FAIL_BATCH=1` if you touched
package lists), commit, push, and the `ci-check` skill. Report the GitHub
result and any build-time change (AUR builds can add minutes).
