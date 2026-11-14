# arch-niri-noctalia

One script that turns a fresh Arch Linux install into a complete
[niri](https://github.com/niri-wm/niri) desktop with the
[Noctalia](https://github.com/noctalia-dev/noctalia) shell and
[Noctalia greeter](https://github.com/noctalia-dev/noctalia-greeter), plus AMD
drivers, apps, fonts and a zsh setup. Everything comes from the official Arch
repos or the AUR. No Flatpak.

> Designed to run after [archinstall](https://wiki.archlinux.org/title/Archinstall),
> which should already have set up networking, Bluetooth and power management.

## Quick start

Run as your normal user, not root. The script uses `sudo` where it needs it.

```bash
git clone https://github.com/lmaule/arch-niri-noctalia.git
cd arch-niri-noctalia
./install-niri-noctalia.sh
```

Reboot when it finishes, then choose the **niri** session at the Noctalia greeter.

### Options

| Flag | What it does |
|---|---|
| `--git` | Use the development (`-git`) packages for Noctalia and the greeter |
| `--no-greeter` | Skip greetd and the Noctalia greeter (start niri from a TTY with `niri-session`) |
| `--no-blur` | Skip the blur rules (they need niri 26.04 or newer) |
| `--amd-gpu` / `--no-amd-gpu` | Force or skip the AMD driver step (default: detect an AMD card) |
| `--yes` | Don't ask for confirmation (also enables multilib and removes AMDVLK without asking) |

## What it installs

| Area | Packages |
|---|---|
| Desktop | `niri`, `noctalia`, `xwayland-satellite`, `xdg-desktop-portal-gnome`, `xdg-desktop-portal-gtk`, `fuzzel`, PipeWire, `polkit`, `upower` |
| Login screen | `greetd`, `noctalia-greeter` |
| AMD GPU (RX 9000 / RDNA 4) | `mesa`, `vulkan-radeon`, `linux-firmware-amdgpu`, 32-bit drivers, `lact`, `rocm-smi-lib`, `vulkan-tools`, `mesa-utils`, `libva-utils` |
| Terminal & shell | `kitty`, `zsh` with completions, autosuggestions and syntax highlighting, `starship`, `btop`, `fastfetch` |
| Fonts | `noto-fonts`, `noto-fonts-cjk`, `noto-fonts-emoji`, `ttf-jetbrains-mono-nerd`, Nerd Font symbols |
| Files | `nautilus`, `xdg-user-dirs`, `gvfs` (MTP, SMB, NFS, network discovery, iPhone, cameras), `avahi`, `nss-mdns`, `ffmpegthumbnailer` |
| Passwords | `gnome-keyring`, `libsecret`, `seahorse` |
| Apps | Helium browser (`helium-browser-bin`, AUR), Steam, Discord, Spotify (`spotify-launcher`), ProtonPlus (AUR), Claude Desktop (`claude-desktop`, AUR) |

If no AUR helper is installed, the script installs `paru` first.

## What it configures

- **niri** (`~/.config/niri/config.kdl`, created from niri's default config if missing):
  - Starts Noctalia at login and stops starting waybar.
  - Adds Noctalia's recommended window rules and blur settings.
  - Makes kitty the terminal (`Mod+T`).
  - Adds Noctalia's keybinds, commenting out any default binds that use the same keys.
- **Noctalia:** turns on its built-in polkit agent, so apps that need admin rights can show a password prompt (`~/.config/noctalia/polkit.toml`).
- **Login:** greetd runs the Noctalia greeter, and any previous display manager is disabled.
- **Keyring:** your login password unlocks GNOME Keyring automatically, and `passwd` keeps the two passwords in sync (PAM).
- **Shell:** zsh becomes your login shell. A starter `~/.zshrc` is written if you don't have one, with the Starship *Pastel Powerline* preset and fastfetch on every new terminal.
- **Defaults:** Helium is the default browser and Nautilus opens folders. kitty uses JetBrains Mono Nerd Font.
- **Network shares:** Avahi is enabled, and `.local` hostnames resolve.

Every system file the script edits is backed up first as `<file>.bak.<timestamp>`.
Running the script again is safe: it skips anything it has already added.

## Keybinds

| Key | Action |
|---|---|
| `Mod+Space` | Noctalia launcher |
| `Mod+S` | Control center |
| `Mod+Shift+Comma` | Noctalia settings |
| `Alt+Tab` / `Alt+Shift+Tab` | Window switcher |
| `Mod+T` | kitty |
| `Mod+D` | fuzzel |
| `Super+Alt+L` | Lock screen |
| Volume, mic, brightness and media keys | Handled by Noctalia, with on-screen display |

`Mod` is the Super (Windows) key. niri's other default binds are unchanged. Press
`Mod+Shift+/` to see them all.

## After installing

- **Check the GPU:** run `vulkaninfo --summary`. It should list the RX 9070 XT with the RADV driver.
- **GPU control:** open LACT for fan curves and power limits. Overclocking has to be enabled in LACT's settings, then you reboot.
- **Saved logins:** if share or app passwords keep asking to be unlocked, open *Passwords and Keys* and make sure the **Login** keyring's password matches your login password.
- **Noctalia commands:** run `noctalia msg --help` to list everything you can bind to a key.

## Notes

- Tested for script syntax and config edits. Not yet run end to end on real hardware.
- Claude Desktop, Helium and ProtonPlus come from the AUR. The AUR packages are maintained by the community, not by the app developers.
- Blur needs niri 26.04+. On older versions the script skips it and adds it the next time you run the script.

## License

[MIT](LICENSE)
