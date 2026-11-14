#!/usr/bin/env bash
# Arch desktop setup: niri + Noctalia shell + Noctalia greeter, plus drivers, apps and shell config.
#
# Usage:  ./install-niri-noctalia.sh [--git] [--no-greeter] [--no-blur] [--amd-gpu|--no-amd-gpu] [--yes]
#   --git         use the -git (development) packages for noctalia / noctalia-greeter
#   --no-greeter  skip greetd + noctalia-greeter setup
#   --no-blur     skip the blur window/layer rules (they need niri >= 26.04)
#   --amd-gpu     force-install AMD GPU drivers (default: auto-detect an AMD card)
#   --no-amd-gpu  skip AMD GPU drivers
#   --yes         don't ask for confirmation
#
# Run as your normal user (NOT root), from a clone of the repo: it installs the
# config files in config/ and etc/ next to it. sudo is used where needed.

set -euo pipefail

USE_GIT=0
WITH_GREETER=1
WITH_BLUR=1
AMD_GPU=auto
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --git) USE_GIT=1 ;;
    --no-greeter) WITH_GREETER=0 ;;
    --no-blur) WITH_BLUR=0 ;;
    --amd-gpu) AMD_GPU=yes ;;
    --no-amd-gpu) AMD_GPU=no ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

info() { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m==> WARNING:\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -rp "$1 [y/N] " r
  [[ $r =~ ^[Yy]$ ]]
}

# --- Sanity checks -----------------------------------------------------------
[[ $EUID -eq 0 ]] && die "Run this as your normal user, not root (AUR builds refuse root)."
command -v pacman >/dev/null || die "pacman not found — this script is for Arch-based systems."
command -v sudo   >/dev/null || die "sudo is required."

# Config files live next to this script (config/ and etc/ in the repo).
REPO_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
[[ -d $REPO_DIR/config/niri && -d $REPO_DIR/etc/dconf ]] || die \
  "config/ and etc/ not found next to this script. Clone the whole repo and run it from there:
    git clone https://github.com/lmaule/arch-niri-noctalia.git && cd arch-niri-noctalia && ./install-niri-noctalia.sh"

SHELL_PKG=noctalia
GREETER_PKG=noctalia-greeter
if [[ $USE_GIT -eq 1 ]]; then
  SHELL_PKG=noctalia-git
  GREETER_PKG=noctalia-greeter-git
fi

info "Will install: niri, $SHELL_PKG$([[ $WITH_GREETER -eq 1 ]] && echo ", greetd, $GREETER_PKG")"
confirm "Continue?" || exit 0

# --- System update + base tools ----------------------------------------------
info "Updating system and installing base tools"
sudo pacman -Syu --needed --noconfirm base-devel git

# --- AUR helper --------------------------------------------------------------
AUR_HELPER=""
ensure_aur_helper() {
  [[ -n $AUR_HELPER ]] && return
  for h in paru yay; do
    if command -v "$h" >/dev/null; then AUR_HELPER=$h; return; fi
  done
  info "No AUR helper found — installing paru-bin"
  local tmp; tmp=$(mktemp -d)
  git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
  (cd "$tmp/paru-bin" && makepkg -si --noconfirm)
  rm -rf "$tmp"
  AUR_HELPER=paru
}

# Install from official repos if available, otherwise from the AUR.
install_pkg() {
  local pkg=$1
  if pacman -Qq "$pkg" &>/dev/null; then
    info "$pkg already installed"
  elif pacman -Si "$pkg" &>/dev/null; then
    info "Installing $pkg from official repos"
    sudo pacman -S --needed --noconfirm "$pkg"
  else
    ensure_aur_helper
    info "Installing $pkg from the AUR via $AUR_HELPER"
    "$AUR_HELPER" -S --needed --noconfirm "$pkg"
  fi
}

# install_one_of "Label" pkg1 pkg2 ...
# Installs the first candidate found (official repos first, then the AUR).
# Returns 1 (without aborting) if none of them exist.
install_one_of() {
  local label=$1 p; shift
  for p in "$@"; do
    if pacman -Qq "$p" &>/dev/null; then info "$label already installed ($p)"; return 0; fi
  done
  for p in "$@"; do
    if pacman -Si "$p" &>/dev/null; then
      info "Installing $label ($p from official repos)"
      sudo pacman -S --needed --noconfirm "$p"; return 0
    fi
  done
  ensure_aur_helper
  for p in "$@"; do
    if "$AUR_HELPER" -Si "$p" &>/dev/null; then
      info "Installing $label ($p from the AUR)"
      "$AUR_HELPER" -S --needed --noconfirm "$p"; return 0
    fi
  done
  warn "Couldn't find a package for $label (tried: $*) — skipping."
  return 1
}

multilib_enabled() { grep -qE '^\s*\[multilib\]' /etc/pacman.conf; }

# Enable the [multilib] repo (32-bit libraries for Steam/Proton/Wine).
ensure_multilib() {
  multilib_enabled && return 0
  if confirm "Enable the [multilib] repo (32-bit libraries, needed by Steam/Proton)?"; then
    sudo cp /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%s)"
    sudo sed -i '/^#\s*\[multilib\]/,/^#\s*Include/ s/^#\s*//' /etc/pacman.conf
    sudo pacman -Sy
  fi
  multilib_enabled
}

# --- AMD GPU drivers (RX 9000 / RDNA 4, e.g. RX 9070 XT) ---------------------
has_amd_gpu() {
  local v
  for v in /sys/class/drm/card*/device/vendor; do
    [[ -r $v && $(<"$v") == 0x1002 ]] && return 0
  done
  return 1
}

# version_ge A B  ->  true if A >= B
version_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

if [[ $AMD_GPU == auto ]]; then
  has_amd_gpu && AMD_GPU=yes || AMD_GPU=no
fi

if [[ $AMD_GPU == yes ]]; then
  info "Installing AMD GPU drivers (amdgpu kernel driver + Mesa RADV/radeonsi)"

  # Kernel: RDNA 4 needs 6.13+, 6.14+ recommended.
  KVER=$(uname -r | grep -oE '^[0-9]+\.[0-9]+')
  if ! version_ge "$KVER" 6.13; then
    warn "Running kernel $KVER is too old for RX 9000 cards (need 6.13+)."
    warn "Run 'sudo pacman -Syu' (or install the 'linux' package) and reboot."
  fi

  # 32-bit drivers (Steam, Wine/Proton) need the multilib repo.
  ensure_multilib || true

  # Firmware: newer Arch splits AMD firmware into linux-firmware-amdgpu.
  FW_PKG=linux-firmware
  pacman -Si linux-firmware-amdgpu &>/dev/null && FW_PKG=linux-firmware-amdgpu

  AMD_PKGS=("$FW_PKG" mesa vulkan-radeon vulkan-icd-loader libva-utils vulkan-tools mesa-utils
            rocm-smi-lib)  # rocm-smi-lib: GPU usage/temps in btop
  if multilib_enabled; then
    AMD_PKGS+=(lib32-mesa lib32-vulkan-radeon lib32-vulkan-icd-loader)
  fi
  sudo pacman -S --needed --noconfirm "${AMD_PKGS[@]}"

  # AMDVLK is discontinued and can override RADV — remove it if present.
  for p in amdvlk lib32-amdvlk; do
    if pacman -Qq "$p" &>/dev/null; then
      warn "$p is installed (discontinued AMD Vulkan driver; RADV is better)."
      if confirm "Remove $p?"; then sudo pacman -Rns --noconfirm "$p"; fi
    fi
  done

  # LACT: GPU monitoring, fan curves, power limits and overclocking.
  info "Installing LACT (GPU control panel)"
  sudo pacman -S --needed --noconfirm lact
  sudo systemctl enable --now lactd.service

  MESA_VER=$(pacman -Q mesa | awk '{print $2}' | sed -E 's/^[0-9]+://; s/-.*//')
  if ! version_ge "$MESA_VER" 25.0; then
    warn "Mesa $MESA_VER is too old for RX 9000 cards (need 25.0+). Update your system."
  fi
  info "AMD drivers installed (kernel $KVER, Mesa $MESA_VER). Verify after reboot with: vulkaninfo --summary"
elif [[ $AMD_GPU == no ]]; then
  info "No AMD GPU detected / --no-amd-gpu given — skipping AMD drivers"
fi

# --- niri + useful companions ------------------------------------------------
info "Installing niri and companion packages"
install_pkg niri
sudo pacman -S --needed --noconfirm \
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
  xwayland-satellite kitty fuzzel \
  btop fastfetch hwdata \
  pipewire wireplumber pipewire-pulse \
  polkit upower

# --- zsh as the default shell ------------------------------------------------
info "Installing zsh"
sudo pacman -S --needed --noconfirm \
  zsh zsh-completions zsh-autosuggestions zsh-syntax-highlighting starship

# Starter ~/.zshrc (skipped if you already have one). Without it, zsh opens a
# first-run setup wizard the first time you start it.
if [[ ! -f $HOME/.zshrc ]]; then
  info "Creating a starter ~/.zshrc"
  cat > "$HOME/.zshrc" <<'EOF'
# ~/.zshrc — created by install-niri-noctalia.sh

# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE

# Behaviour
setopt AUTO_CD INTERACTIVE_COMMENTS
bindkey -e                                   # emacs-style keys (Ctrl+A, Ctrl+E, ...)
bindkey '^[[H' beginning-of-line             # Home
bindkey '^[[F' end-of-line                   # End
bindkey '^[[3~' delete-char                  # Delete
bindkey '^[[1;5C' forward-word               # Ctrl+Right
bindkey '^[[1;5D' backward-word              # Ctrl+Left

# Tab completion (menu, case-insensitive)
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# Aliases
alias ls='ls --color=auto'
alias ll='ls -lah'
alias grep='grep --color=auto'

# Plugins (syntax highlighting must be sourced last)
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF
fi

# Starship prompt + fastfetch on every new terminal. Appended separately so they
# are also added to an existing ~/.zshrc (each only once).
if ! grep -qF 'starship init zsh' "$HOME/.zshrc"; then
  info "Enabling the Starship prompt in ~/.zshrc"
  printf '\n# Starship prompt (config: ~/.config/starship.toml)\neval "$(starship init zsh)"\n' >> "$HOME/.zshrc"
fi
if ! grep -qE '^[^#]*fastfetch' "$HOME/.zshrc"; then
  info "Showing fastfetch when a terminal opens"
  printf '\n# System info when a terminal opens (interactive shells only)\n[[ -o interactive ]] && command -v fastfetch >/dev/null && fastfetch\n' >> "$HOME/.zshrc"
fi

# Starship theme: the Pastel Powerline preset (needs a Nerd Font — kitty uses
# JetBrainsMono Nerd Font, set up below). Skipped if you already have a config.
STARSHIP_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml"
if [[ ! -f $STARSHIP_CFG ]]; then
  info "Applying the Starship 'Pastel Powerline' preset ($STARSHIP_CFG)"
  mkdir -p "$(dirname "$STARSHIP_CFG")"
  starship preset pastel-powerline -o "$STARSHIP_CFG"
else
  info "$STARSHIP_CFG already exists — leaving your Starship config alone"
fi

# Make zsh your login shell (takes effect next time you log in).
if [[ $(getent passwd "$USER" | cut -d: -f7) != /usr/bin/zsh ]]; then
  info "Setting zsh as the default shell for $USER"
  sudo chsh -s /usr/bin/zsh "$USER"
fi

# --- Fonts -------------------------------------------------------------------
#   noto-fonts:              main UI font, wide language coverage
#   noto-fonts-cjk:          Chinese / Japanese / Korean
#   noto-fonts-emoji:        colour emoji (Noctalia's launcher has an emoji picker)
#   ttf-jetbrains-mono-nerd: coding font with Nerd Font icons, used for kitty
#   ttf-nerd-fonts-symbols:  icon fallback so any font can show Nerd Font glyphs
info "Installing fonts"
sudo pacman -S --needed --noconfirm \
  noto-fonts noto-fonts-cjk noto-fonts-emoji \
  ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono
fc-cache -f >/dev/null

# Use JetBrains Mono Nerd Font in kitty, unless you've already picked a font.
KITTY_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/kitty/kitty.conf"
if ! grep -qsE '^\s*font_family\s' "$KITTY_CFG"; then
  info "Setting kitty's font to JetBrainsMono Nerd Font ($KITTY_CFG)"
  mkdir -p "$(dirname "$KITTY_CFG")"
  printf '\n# Added by install-niri-noctalia.sh\nfont_family JetBrainsMono Nerd Font\nfont_size 11.0\n' >> "$KITTY_CFG"
fi

# --- File manager, user dirs, MTP & network shares ---------------------------
info "Installing Nautilus, XDG user dirs, MTP and network share support"
sudo pacman -S --needed --noconfirm \
  nautilus \
  xdg-user-dirs xdg-utils \
  gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-dnssd \
  avahi nss-mdns

# Optional extras — only installed if your repos have them.
#   gvfs-wsdd:          discover Windows (SMB) machines on the network
#   gvfs-afc:           iPhone/iPad file access
#   gvfs-gphoto2:       cameras (PTP)
#   ffmpegthumbnailer:  video thumbnails in Nautilus
for p in gvfs-wsdd gvfs-afc gvfs-gphoto2 ffmpegthumbnailer; do
  if pacman -Si "$p" &>/dev/null; then
    sudo pacman -S --needed --noconfirm "$p"
  fi
done

# Create ~/Desktop, ~/Documents, ~/Downloads, ~/Music, ~/Pictures, ~/Videos, ...
xdg-user-dirs-update

# Make Nautilus the default app for opening folders.
xdg-mime default org.gnome.Nautilus.desktop inode/directory

# Avahi: lets Nautilus's "Network" view find shares and printers on the LAN.
sudo systemctl enable --now avahi-daemon.service

# nss-mdns: resolve *.local hostnames (e.g. smb://nas.local).
if ! grep -qE '^hosts:.*mdns' /etc/nsswitch.conf; then
  info "Enabling .local hostname resolution in /etc/nsswitch.conf"
  sudo cp /etc/nsswitch.conf "/etc/nsswitch.conf.bak.$(date +%s)"
  if grep -qE '^hosts:.*\bresolve\b' /etc/nsswitch.conf; then
    sudo sed -i -E '/^hosts:/ s/\bresolve\b/mdns_minimal [NOTFOUND=return] resolve/' /etc/nsswitch.conf
  else
    sudo sed -i -E '/^hosts:/ s/\bdns\b/mdns_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf
  fi
fi

# Avahi and systemd-resolved both want port 5353 for mDNS — turn resolved's off.
if systemctl is-active --quiet systemd-resolved; then
  sudo mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nMulticastDNS=no\n' | sudo tee /etc/systemd/resolved.conf.d/no-mdns.conf >/dev/null
  sudo systemctl restart systemd-resolved
fi

# --- Helium browser (AUR, community-maintained) ------------------------------
# helium-browser-bin repackages the official Linux release (verified on the AUR).
if ! install_one_of "Helium browser" helium-browser-bin; then
  warn "Get the AppImage from https://github.com/imputnet/helium-linux/releases/latest"
fi

# Make Helium the default browser. The desktop file name depends on the package
# (upstream recommends helium.desktop), so find whichever one is installed.
HELIUM_DESKTOP=""
for d in helium-browser.desktop helium.desktop net.imput.helium.desktop; do
  if [[ -f /usr/share/applications/$d ]]; then HELIUM_DESKTOP=$d; break; fi
done
if [[ -z $HELIUM_DESKTOP ]]; then
  HELIUM_DESKTOP=$(find /usr/share/applications -maxdepth 1 -iname '*helium*.desktop' -printf '%f\n' 2>/dev/null | head -n1)
fi

if [[ -n $HELIUM_DESKTOP ]]; then
  info "Setting Helium ($HELIUM_DESKTOP) as the default browser"
  for mime in x-scheme-handler/http x-scheme-handler/https text/html \
              application/xhtml+xml x-scheme-handler/about x-scheme-handler/unknown; do
    xdg-mime default "$HELIUM_DESKTOP" "$mime"
  done
  xdg-settings set default-web-browser "$HELIUM_DESKTOP" 2>/dev/null || true
else
  warn "Helium's desktop file not found — default browser not changed."
fi

# --- Apps: Steam, Discord, Spotify, ProtonPlus, Claude Desktop (no Flatpak) --
# Steam (official, multilib). Needs the 32-bit graphics drivers too.
if ensure_multilib; then
  STEAM_PKGS=(steam)
  [[ $AMD_GPU == yes ]] && STEAM_PKGS+=(lib32-mesa lib32-vulkan-radeon)
  info "Installing Steam"
  sudo pacman -S --needed --noconfirm "${STEAM_PKGS[@]}"
else
  warn "[multilib] is not enabled — skipping Steam."
fi

# Discord (official Arch repo).
install_one_of "Discord" discord || true

# Spotify: the AUR 'spotify' package (most-voted Spotify package on the AUR),
# which repackages Spotify's official client. Its build checks Spotify's
# signature, so import Spotify's public signing key into your keyring first.
SPOTIFY_KEY=E1096BCBFF6D418796DE78515384CE82BA52C83A
if ! gpg --list-keys "$SPOTIFY_KEY" &>/dev/null; then
  info "Importing Spotify's package signing key"
  curl -fsSL https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.gpg | gpg --import - \
    || warn "Could not import Spotify's key — the Spotify build may fail."
fi
if pacman -Qq spotify-launcher &>/dev/null; then
  if confirm "Remove spotify-launcher (replaced by the AUR 'spotify' package)?"; then
    sudo pacman -Rns --noconfirm spotify-launcher
  fi
fi
ensure_aur_helper
if pacman -Qq spotify &>/dev/null; then
  info "Spotify already installed"
else
  info "Installing Spotify (spotify from the AUR)"
  "$AUR_HELPER" -S --needed --noconfirm spotify || warn "Spotify install failed — skipping."
fi

# ProtonPlus: manages Proton-GE / Wine-GE etc. for Steam, Lutris, Heroic (AUR).
install_one_of "ProtonPlus" protonplus || true

# Claude Desktop: the AUR package repackages Anthropic's official Linux build
# (downloaded from downloads.claude.ai); the AUR packaging itself is community-run.
install_one_of "Claude Desktop" claude-desktop || true

# --- GNOME Keyring (stores share/Wi-Fi/app passwords), unlocked at login -----
info "Installing GNOME Keyring"
sudo pacman -S --needed --noconfirm gnome-keyring libsecret seahorse

# Add a pam_gnome_keyring line after the last line of the given type
# (auth/session/password) in a PAM file, unless it's already there.
pam_add() {
  local file=$1 type=$2 line=$3 tmp
  [[ -f $file ]] || return 0
  grep -qE "^\s*${type}\s+.*pam_gnome_keyring\.so" "$file" && return 0
  tmp=$(mktemp)
  awk -v t="$type" -v l="$line" '
    { lines[NR] = $0; if ($1 == t) last = NR }
    END {
      for (i = 1; i <= NR; i++) { print lines[i]; if (i == last) print l }
      if (!last) print l
    }
  ' "$file" > "$tmp"
  sudo install -m 644 "$tmp" "$file"
  rm -f "$tmp"
}

# Which PAM service handles your login: greetd (greeter) or login (TTY).
if [[ $WITH_GREETER -eq 1 ]]; then
  sudo pacman -S --needed --noconfirm greetd   # provides /etc/pam.d/greetd
  LOGIN_PAM=/etc/pam.d/greetd
else
  LOGIN_PAM=/etc/pam.d/login
fi

info "Configuring PAM so your login password unlocks the keyring ($LOGIN_PAM)"
for f in "$LOGIN_PAM" /etc/pam.d/passwd; do
  [[ -f $f ]] && sudo cp "$f" "$f.bak.$(date +%s)"
done
# On login: grab the password (auth) and unlock/create the "login" keyring (session).
pam_add "$LOGIN_PAM" auth    "auth       optional     pam_gnome_keyring.so"
pam_add "$LOGIN_PAM" session "session    optional     pam_gnome_keyring.so auto_start"
# On `passwd`: change the keyring password too, so they stay the same.
pam_add /etc/pam.d/passwd password "password   optional     pam_gnome_keyring.so"

# --- Noctalia shell ----------------------------------------------------------
install_pkg "$SHELL_PKG"

# --- GTK & Qt theming (adw-gtk3 + qt5ct/qt6ct, coloured by Noctalia) ----------
# Follows Noctalia's GTK/Qt guide: adw-gtk3 for GTK apps, qt5ct/qt6ct for Qt
# apps. Noctalia's gtk3/gtk4/qt colour templates are switched on in
# config/noctalia/config.toml, and QT_QPA_PLATFORMTHEME in config/niri/cfg/misc.kdl.
info "Installing GTK/Qt theming tools and cursor theme"
sudo pacman -S --needed --noconfirm adw-gtk-theme nwg-look qt5ct qt6ct capitaine-cursors dconf

# Point qt5ct/qt6ct at the colour files Noctalia's Qt template writes.
# Skipped for any of the two you've already configured.
for v in qt5ct qt6ct; do
  QTCT_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/$v/$v.conf"
  if [[ ! -f $QTCT_CFG ]]; then
    info "Configuring $v to use Noctalia's colours ($QTCT_CFG)"
    mkdir -p "$(dirname "$QTCT_CFG")/colors"
    cat > "$QTCT_CFG" <<EOF
[Appearance]
color_scheme_path=${XDG_CONFIG_HOME:-$HOME/.config}/$v/colors/noctalia.conf
custom_palette=true
style=Fusion
icon_theme=Adwaita
standard_dialogs=default
EOF
  fi
done

# System-wide GTK defaults (dark adw-gtk3, capitaine cursors) via dconf, as in
# CachyOS. Your own settings (e.g. from nwg-look) still take priority.
info "Installing dconf defaults (etc/dconf)"
if [[ -f /etc/dconf/profile/user ]] && ! cmp -s "$REPO_DIR/etc/dconf/profile/user" /etc/dconf/profile/user; then
  sudo cp /etc/dconf/profile/user "/etc/dconf/profile/user.bak.$(date +%s)"
fi
sudo install -Dm644 "$REPO_DIR/etc/dconf/profile/user" /etc/dconf/profile/user
sudo install -Dm644 "$REPO_DIR/etc/dconf/db/local.d/00-arch-niri-noctalia.conf" \
  /etc/dconf/db/local.d/00-arch-niri-noctalia.conf
sudo dconf update

# --- Config files: niri + Noctalia (from config/ in this repo) ----------------
# Copies config/<app> to ~/.config/<app>. If you already have a different
# config there, it's moved to ~/.config/<app>.bak.<timestamp> first.
install_config() {
  local src=$1 dest=$2
  if [[ -e $dest ]] && diff -rq "$src" "$dest" &>/dev/null; then
    info "$dest is already up to date"
    return
  fi
  if [[ -e $dest ]]; then
    local bak; bak="$dest.bak.$(date +%Y%m%d-%H%M%S)"
    warn "Backing up your existing $dest to $bak"
    mv "$dest" "$bak"
  fi
  info "Installing $dest"
  mkdir -p "$(dirname "$dest")"
  cp -r "$src" "$dest"
}

CFG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
NIRI_DIR="$CFG_HOME/niri"
NIRI_CFG="$NIRI_DIR/config.kdl"

# Prepare the niri config in a temp copy so the blur decision is part of the
# comparison (and re-runs don't back up an unchanged config).
NIRI_SRC=$(mktemp -d)
cp -r "$REPO_DIR/config/niri/." "$NIRI_SRC/"

# Blur needs niri >= 26.04 — older versions reject the settings in cfg/blur.kdl.
NIRI_VER=$(niri --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)
if [[ $WITH_BLUR -eq 0 ]]; then
  info "Blur disabled (--no-blur)"
  sed -i 's|^include "./cfg/blur.kdl"|// include "./cfg/blur.kdl"  // disabled by --no-blur|' "$NIRI_SRC/config.kdl"
elif [[ -z $NIRI_VER ]] || ! version_ge "$NIRI_VER" 26.04; then
  warn "niri ${NIRI_VER:-(unknown version)} is older than 26.04 — blur disabled."
  warn "Re-run this script after upgrading niri to turn it on."
  sed -i 's|^include "./cfg/blur.kdl"|// include "./cfg/blur.kdl"  // needs niri 26.04+|' "$NIRI_SRC/config.kdl"
fi

install_config "$NIRI_SRC" "$NIRI_DIR"
rm -rf "$NIRI_SRC"

# Noctalia: only config.toml is managed; other files in ~/.config/noctalia
# (plugins, your own *.toml) are left alone.
NOCTALIA_DIR="$CFG_HOME/noctalia"
mkdir -p "$NOCTALIA_DIR"
install_config "$REPO_DIR/config/noctalia/config.toml" "$NOCTALIA_DIR/config.toml"
# Files older versions of this script wrote, now part of config.toml.
for old in polkit.toml theming.toml; do
  if [[ -f $NOCTALIA_DIR/$old ]] && grep -q 'install-niri-noctalia\|polkit_agent' "$NOCTALIA_DIR/$old"; then
    mv "$NOCTALIA_DIR/$old" "$NOCTALIA_DIR/$old.bak.$(date +%Y%m%d-%H%M%S)"
  fi
done

if command -v niri >/dev/null && ! niri validate -c "$NIRI_CFG"; then
  warn "niri reports a config error in $NIRI_DIR — your previous config is in $NIRI_DIR.bak.*"
fi

# --- Greeter (greetd + noctalia-greeter) -------------------------------------
if [[ $WITH_GREETER -eq 1 ]]; then
  sudo pacman -S --needed --noconfirm greetd
  install_pkg "$GREETER_PKG"

  GREETER_CMD=$(command -v noctalia-greeter-session || echo /usr/bin/noctalia-greeter-session)
  GREETD_CFG=/etc/greetd/config.toml

  info "Configuring greetd ($GREETD_CFG)"
  sudo mkdir -p /etc/greetd
  [[ -f $GREETD_CFG ]] && sudo cp "$GREETD_CFG" "$GREETD_CFG.bak.$(date +%s)"

  # Replace only the [default_session] section, keep everything else (e.g. [terminal]).
  tmp=$(mktemp)
  if [[ -f $GREETD_CFG ]]; then
    sudo awk '
      /^\s*\[default_session\]/ { skip=1; next }
      /^\s*\[/                  { skip=0 }
      !skip
    ' "$GREETD_CFG" > "$tmp"
  fi
  grep -q '^\s*\[terminal\]' "$tmp" || printf '[terminal]\nvt = 1\n\n' >> "$tmp"
  cat >> "$tmp" <<EOF

[default_session]
command = "$GREETER_CMD"
user = "greeter"
EOF
  sudo install -m 644 "$tmp" "$GREETD_CFG"
  rm -f "$tmp"

  info "Setting up greeter state/appearance sync"
  if command -v noctalia-greeter-apply-appearance >/dev/null; then
    sudo noctalia-greeter-apply-appearance --setup-system || warn "appearance setup failed (non-fatal)"
  fi

  # Disable whatever display manager is currently active.
  if [[ -L /etc/systemd/system/display-manager.service ]]; then
    current_dm=$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")
    if [[ $current_dm != greetd.service ]]; then
      info "Disabling current display manager: $current_dm"
      sudo systemctl disable "$current_dm"
    fi
  fi

  info "Enabling greetd"
  sudo systemctl enable greetd.service
fi

echo
info "Done!"
if [[ $WITH_GREETER -eq 1 ]]; then
  echo "    Reboot to get the Noctalia greeter, then pick the niri session."
else
  echo "    Log out and start niri from a TTY with:  niri-session"
fi
