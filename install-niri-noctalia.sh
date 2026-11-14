#!/usr/bin/env bash
# Arch desktop setup: niri + Noctalia shell + Noctalia greeter, plus drivers, apps and shell config.
#
# Usage:  ./install-niri-noctalia.sh [options]
#   --git         use the -git (development) packages for noctalia / noctalia-greeter
#   --no-greeter  skip greetd + noctalia-greeter setup
#   --no-blur     skip the blur window/layer rules (they need niri >= 26.04)
#   --amd-gpu     force-install AMD GPU drivers (default: auto-detect an AMD card)
#   --no-amd-gpu  skip AMD GPU drivers
#   --yes         don't ask questions (answer yes to everything, never reboot)
#   --verbose     show the full output instead of the progress screen
#
# Run as your normal user (NOT root), from a clone of the repo: it installs the
# config files in config/ and etc/ next to it. sudo is used where needed.
# Everything is logged to ~/arch-niri-noctalia-install.log.

# No `set -e` here: each step runs in its own subshell with `set -e`, so a
# failing step can be retried or skipped instead of killing the installer.
set -uo pipefail

USE_GIT=0
WITH_GREETER=1
WITH_BLUR=1
AMD_GPU=auto
ASSUME_YES=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --git) USE_GIT=1 ;;
    --no-greeter) WITH_GREETER=0 ;;
    --no-blur) WITH_BLUR=0 ;;
    --amd-gpu) AMD_GPU=yes ;;
    --no-amd-gpu) AMD_GPU=no ;;
    --yes|-y) ASSUME_YES=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# The progress screen needs a real terminal; otherwise print everything.
[[ -t 0 && -t 1 ]] || VERBOSE=1

# ── Colours ─────────────────────────────────────────────────────────────────
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  RST=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m'
  GRN=$'\e[38;2;166;227;161m' RED=$'\e[38;2;243;139;168m' YLW=$'\e[38;2;249;226;175m'
  ACC=$'\e[38;2;203;166;247m' MUT=$'\e[38;2;127;132;156m' TXT=$'\e[38;2;205;214;244m'
  BAR_OFF=$'\e[38;2;69;71;90m' EL=$'\e[K'
else
  RST='' BOLD='' DIM='' GRN='' RED='' YLW='' ACC='' MUT='' TXT='' BAR_OFF='' EL=''
fi

LOG="$HOME/arch-niri-noctalia-install.log"
WARN_FILE=$(mktemp)

# info/warn are used inside steps, whose output goes to the log. Warnings are
# also collected in WARN_FILE and shown in the summary at the end.
info() { if [[ -t 1 ]]; then printf '\e[1;34m==>\e[0m %s\n' "$*"; else printf '==> %s\n' "$*"; fi; }
warn() {
  if [[ -t 1 ]]; then printf '\e[1;33m==> WARNING:\e[0m %s\n' "$*"; else printf '==> WARNING: %s\n' "$*"; fi
  printf '%s\n' "$*" >> "$WARN_FILE"
}
die() { printf '%s==> ERROR:%s %s\n' "$RED$BOLD" "$RST" "$*" >&2; exit 1; }

# Questions are only asked before the progress screen starts.
confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local r; read -rp "$(printf '%s::%s %s %s[y/N]%s ' "$ACC" "$RST" "$1" "$MUT" "$RST")" r
  [[ $r =~ ^[Yy]$ ]]
}

# ── Sanity checks ───────────────────────────────────────────────────────────
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

# ═════════════════════════════════════════════════════════════════════════════
#  Helpers used by the steps
# ═════════════════════════════════════════════════════════════════════════════

AUR_HELPER=""
ensure_aur_helper() {
  [[ -n $AUR_HELPER ]] && return 0
  local h tmp
  for h in paru yay; do
    if command -v "$h" >/dev/null; then AUR_HELPER=$h; return 0; fi
  done
  info "No AUR helper found — installing paru-bin"
  tmp=$(mktemp -d)
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
# For optional apps: returns 1 with a warning (never aborts) if it fails.
install_one_of() {
  local label=$1 p; shift
  for p in "$@"; do
    if pacman -Qq "$p" &>/dev/null; then info "$label already installed ($p)"; return 0; fi
  done
  for p in "$@"; do
    if pacman -Si "$p" &>/dev/null; then
      info "Installing $label ($p from official repos)"
      if sudo pacman -S --needed --noconfirm "$p"; then return 0; fi
      warn "$label ($p) failed to install — skipped. See the log for details."
      return 1
    fi
  done
  ensure_aur_helper
  for p in "$@"; do
    if "$AUR_HELPER" -Si "$p" &>/dev/null; then
      info "Installing $label ($p from the AUR)"
      if "$AUR_HELPER" -S --needed --noconfirm "$p"; then return 0; fi
      warn "$label ($p) failed to install — skipped. See the log for details."
      return 1
    fi
  done
  warn "Couldn't find a package for $label (tried: $*) — skipped."
  return 1
}

multilib_enabled() { grep -qsE '^\s*\[multilib\]' /etc/pacman.conf; }

# Enable the [multilib] repo (32-bit libraries for Steam/Proton/Wine), if you
# said yes to it at the start.
WANT_MULTILIB=0
ensure_multilib() {
  multilib_enabled && return 0
  if [[ $WANT_MULTILIB -eq 1 ]]; then
    info "Enabling the [multilib] repo"
    sudo cp /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%s)"
    if grep -qE '^#\s*\[multilib\]' /etc/pacman.conf; then
      # Normal Arch: uncomment the existing block.
      sudo sed -i '/^#\s*\[multilib\]/,/^#\s*Include/ s/^#\s*//' /etc/pacman.conf
    else
      # Some setups (e.g. minimal/container pacman.conf) have no block at all.
      printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
    fi
    sudo pacman -Sy
  fi
  multilib_enabled
}

has_amd_gpu() {
  local v
  for v in /sys/class/drm/card*/device/vendor; do
    [[ -r $v && $(<"$v") == 0x1002 ]] && return 0
  done
  return 1
}

# Enable a systemd service; start it now too if systemd is running (it isn't
# in a container or chroot, where `--now` would fail).
svc_enable() {
  if [[ -d /run/systemd/system ]]; then sudo systemctl enable --now "$@"
  else sudo systemctl enable "$@"; fi
}

# version_ge A B  ->  true if A >= B
version_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

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

# Copies config/<app> to ~/.config/<app>. If you already have a different
# config there, it's moved to ~/.config/<app>.bak.<timestamp> first.
install_config() {
  local src=$1 dest=$2 bak
  if [[ -e $dest ]] && diff -rq "$src" "$dest" &>/dev/null; then
    info "$dest is already up to date"
    return 0
  fi
  if [[ -e $dest ]]; then
    bak="$dest.bak.$(date +%Y%m%d-%H%M%S)"
    warn "Your previous $dest was moved to $bak"
    mv "$dest" "$bak"
  fi
  info "Installing $dest"
  mkdir -p "$(dirname "$dest")"
  cp -r "$src" "$dest"
}

# ═════════════════════════════════════════════════════════════════════════════
#  Steps — each runs in its own subshell with `set -e`; output goes to the log
# ═════════════════════════════════════════════════════════════════════════════

step_update() {
  info "Updating system and installing base tools"
  sudo pacman -Syu --needed --noconfirm base-devel git
}

step_aur() {
  ensure_aur_helper
  info "Using AUR helper: $AUR_HELPER"
}

# AMD GPU drivers (RX 9000 / RDNA 4, e.g. RX 9070 XT)
step_amd() {
  local kver fw_pkg mesa_ver p
  local -a pkgs
  info "Installing AMD GPU drivers (amdgpu kernel driver + Mesa RADV/radeonsi)"

  # Kernel: RDNA 4 needs 6.13+, 6.14+ recommended.
  kver=$(uname -r | grep -oE '^[0-9]+\.[0-9]+')
  if ! version_ge "$kver" 6.13; then
    warn "Kernel $kver is too old for RX 9000 cards (need 6.13+). Update with 'sudo pacman -Syu' and reboot."
  fi

  # 32-bit drivers (Steam, Wine/Proton) need the multilib repo.
  ensure_multilib || true

  # Firmware: newer Arch splits AMD firmware into linux-firmware-amdgpu.
  fw_pkg=linux-firmware
  pacman -Si linux-firmware-amdgpu &>/dev/null && fw_pkg=linux-firmware-amdgpu

  pkgs=("$fw_pkg" mesa vulkan-radeon vulkan-icd-loader libva-utils vulkan-tools mesa-utils
        rocm-smi-lib)  # rocm-smi-lib: GPU usage/temps in btop
  if multilib_enabled; then
    pkgs+=(lib32-mesa lib32-vulkan-radeon lib32-vulkan-icd-loader)
  fi
  sudo pacman -S --needed --noconfirm "${pkgs[@]}"

  # AMDVLK is discontinued and can override RADV — remove it if you said yes.
  for p in amdvlk lib32-amdvlk; do
    if pacman -Qq "$p" &>/dev/null; then
      if [[ $REMOVE_AMDVLK -eq 1 ]]; then
        sudo pacman -Rns --noconfirm "$p"
      else
        warn "$p is still installed (discontinued AMD Vulkan driver; RADV is better)."
      fi
    fi
  done

  # LACT: GPU monitoring, fan curves, power limits and overclocking.
  info "Installing LACT (GPU control panel)"
  sudo pacman -S --needed --noconfirm lact
  svc_enable lactd.service

  mesa_ver=$(pacman -Q mesa | awk '{print $2}' | sed -E 's/^[0-9]+://; s/-.*//')
  if ! version_ge "$mesa_ver" 25.0; then
    warn "Mesa $mesa_ver is too old for RX 9000 cards (need 25.0+). Update your system."
  fi
  info "AMD drivers installed (kernel $kver, Mesa $mesa_ver)."
}

step_niri() {
  info "Installing niri and companion packages"
  install_pkg niri
  sudo pacman -S --needed --noconfirm \
    xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
    xwayland-satellite kitty \
    btop fastfetch hwdata \
    pipewire wireplumber pipewire-pulse \
    polkit upower
}

step_zsh() {
  local starship_cfg
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
  # JetBrainsMono Nerd Font, set up in the fonts step). Skipped if you have a config.
  starship_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml"
  if [[ ! -f $starship_cfg ]]; then
    info "Applying the Starship 'Pastel Powerline' preset ($starship_cfg)"
    mkdir -p "$(dirname "$starship_cfg")"
    starship preset pastel-powerline -o "$starship_cfg"
  else
    info "$starship_cfg already exists — leaving your Starship config alone"
  fi

  # Make zsh your login shell (takes effect next time you log in).
  if [[ $(getent passwd "$USER" | cut -d: -f7) != /usr/bin/zsh ]]; then
    info "Setting zsh as the default shell for $USER"
    sudo chsh -s /usr/bin/zsh "$USER"
  fi
}

step_fonts() {
  local kitty_cfg
  #   noto-fonts:              main UI font, wide language coverage
  #   noto-fonts-cjk:          Chinese / Japanese / Korean
  #   noto-fonts-emoji:        colour emoji (Noctalia's launcher has an emoji picker)
  #   ttf-jetbrains-mono-nerd: coding font with Nerd Font icons, used for kitty
  #   ttf-nerd-fonts-symbols:  icon fallback so any font can show Nerd Font glyphs
  info "Installing fonts"
  sudo pacman -S --needed --noconfirm \
    noto-fonts noto-fonts-cjk noto-fonts-emoji \
    ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono
  fc-cache -f

  # Use JetBrains Mono Nerd Font in kitty, unless you've already picked a font.
  kitty_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/kitty/kitty.conf"
  if ! grep -qsE '^\s*font_family\s' "$kitty_cfg"; then
    info "Setting kitty's font to JetBrainsMono Nerd Font ($kitty_cfg)"
    mkdir -p "$(dirname "$kitty_cfg")"
    printf '\n# Added by install-niri-noctalia.sh\nfont_family JetBrainsMono Nerd Font\nfont_size 11.0\n' >> "$kitty_cfg"
  fi
}

# File manager, user dirs, MTP & network shares
step_files() {
  local p
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
  svc_enable avahi-daemon.service

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
}

# Helium browser (AUR, community-maintained)
step_helium() {
  local d mime desktop=""
  # helium-browser-bin repackages the official Linux release.
  if ! install_one_of "Helium browser" helium-browser-bin; then
    warn "Get the Helium AppImage from https://github.com/imputnet/helium-linux/releases/latest"
  fi

  # Make Helium the default browser. The desktop file name depends on the package
  # (upstream recommends helium.desktop), so find whichever one is installed.
  for d in helium-browser.desktop helium.desktop net.imput.helium.desktop; do
    if [[ -f /usr/share/applications/$d ]]; then desktop=$d; break; fi
  done
  if [[ -z $desktop ]]; then
    desktop=$(find /usr/share/applications -maxdepth 1 -iname '*helium*.desktop' -printf '%f\n' 2>/dev/null | head -n1)
  fi

  if [[ -n $desktop ]]; then
    info "Setting Helium ($desktop) as the default browser"
    for mime in x-scheme-handler/http x-scheme-handler/https text/html \
                application/xhtml+xml x-scheme-handler/about x-scheme-handler/unknown; do
      xdg-mime default "$desktop" "$mime"
    done
    xdg-settings set default-web-browser "$desktop" 2>/dev/null || true
  else
    warn "Helium's desktop file not found — default browser not changed."
  fi
}

# Apps: Steam, Discord, Spotify, ProtonPlus, Claude Desktop (no Flatpak).
# Each app is optional: a failure is reported in the summary, not fatal.
step_apps() {
  local -a steam_pkgs
  local spotify_key=E1096BCBFF6D418796DE78515384CE82BA52C83A

  # Steam (official, multilib). Needs the 32-bit graphics drivers too.
  if ensure_multilib; then
    steam_pkgs=(steam)
    if [[ $AMD_GPU == yes ]]; then steam_pkgs+=(lib32-mesa lib32-vulkan-radeon); fi
    info "Installing Steam"
    sudo pacman -S --needed --noconfirm "${steam_pkgs[@]}" \
      || warn "Steam failed to install — skipped. See the log for details."
  else
    warn "[multilib] is not enabled — Steam skipped."
  fi

  # Discord (official Arch repo).
  install_one_of "Discord" discord || true

  # Spotify: the AUR 'spotify' package (most-voted Spotify package on the AUR),
  # which repackages Spotify's official client. Its build checks Spotify's
  # signature, so import Spotify's public signing key into your keyring first.
  if ! gpg --list-keys "$spotify_key" &>/dev/null; then
    info "Importing Spotify's package signing key"
    curl -fsSL https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.gpg | gpg --import - \
      || warn "Could not import Spotify's key — the Spotify build may fail."
  fi
  if pacman -Qq spotify-launcher &>/dev/null && [[ $REMOVE_SPOTIFY_LAUNCHER -eq 1 ]]; then
    sudo pacman -Rns --noconfirm spotify-launcher
  fi
  ensure_aur_helper
  if pacman -Qq spotify &>/dev/null; then
    info "Spotify already installed"
  else
    info "Installing Spotify (spotify from the AUR)"
    "$AUR_HELPER" -S --needed --noconfirm spotify \
      || warn "Spotify failed to install — skipped. See the log for details."
  fi

  # ProtonPlus: manages Proton-GE / Wine-GE etc. for Steam, Lutris, Heroic (AUR).
  install_one_of "ProtonPlus" protonplus || true

  # Claude Desktop: the AUR package repackages Anthropic's official Linux build
  # (downloaded from downloads.claude.ai); the AUR packaging itself is community-run.
  install_one_of "Claude Desktop" claude-desktop || true
}

# Gaming tools and VMs. Optional like the apps above: failures are reported in
# the summary, not fatal.
#   mangohud:        FPS / temperature / frame-time overlay (lib32 for 32-bit games)
#   goverlay:        GUI for configuring MangoHud
#   faugus-launcher: runs Windows games outside Steam with UMU-Launcher (AUR)
#   vm-curator:      terminal app for QEMU/KVM virtual machines (AUR); edk2-ovmf
#                    adds UEFI boot and swtpm a TPM, both needed for Windows 11 VMs
step_gaming_vms() {
  local -a pkgs=(mangohud goverlay edk2-ovmf swtpm)
  if multilib_enabled; then pkgs+=(lib32-mangohud); fi
  info "Installing MangoHud, GOverlay and VM firmware (UEFI/TPM)"
  sudo pacman -S --needed --noconfirm "${pkgs[@]}" \
    || warn "MangoHud/GOverlay failed to install — skipped. See the log for details."

  install_one_of "Faugus Launcher" faugus-launcher || true
  install_one_of "VM Curator" vm-curator || true
}

# GNOME Keyring (stores share/Wi-Fi/app passwords), unlocked at login
step_keyring() {
  local login_pam f
  info "Installing GNOME Keyring"
  sudo pacman -S --needed --noconfirm gnome-keyring libsecret seahorse

  # Which PAM service handles your login: greetd (greeter) or login (TTY).
  if [[ $WITH_GREETER -eq 1 ]]; then
    sudo pacman -S --needed --noconfirm greetd   # provides /etc/pam.d/greetd
    login_pam=/etc/pam.d/greetd
  else
    login_pam=/etc/pam.d/login
  fi

  info "Configuring PAM so your login password unlocks the keyring ($login_pam)"
  for f in "$login_pam" /etc/pam.d/passwd; do
    if [[ -f $f ]]; then sudo cp "$f" "$f.bak.$(date +%s)"; fi
  done
  # On login: grab the password (auth) and unlock/create the "login" keyring (session).
  pam_add "$login_pam" auth    "auth       optional     pam_gnome_keyring.so"
  pam_add "$login_pam" session "session    optional     pam_gnome_keyring.so auto_start"
  # On `passwd`: change the keyring password too, so they stay the same.
  pam_add /etc/pam.d/passwd password "password   optional     pam_gnome_keyring.so"
}

step_noctalia() {
  install_pkg "$SHELL_PKG"
}

# GTK & Qt theming (adw-gtk3 + qt5ct/qt6ct, coloured by Noctalia).
# Follows Noctalia's GTK/Qt guide: adw-gtk3 for GTK apps, qt5ct/qt6ct for Qt
# apps. Noctalia's gtk3/gtk4/qt colour templates are switched on in
# config/noctalia/config.toml, and QT_QPA_PLATFORMTHEME in config/niri/cfg/misc.kdl.
step_theming() {
  local v qtct_cfg
  info "Installing GTK/Qt theming tools and cursor theme"
  sudo pacman -S --needed --noconfirm adw-gtk-theme nwg-look qt5ct qt6ct capitaine-cursors dconf

  # Point qt5ct/qt6ct at the colour files Noctalia's Qt template writes.
  # Skipped for any of the two you've already configured.
  for v in qt5ct qt6ct; do
    qtct_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/$v/$v.conf"
    if [[ ! -f $qtct_cfg ]]; then
      info "Configuring $v to use Noctalia's colours ($qtct_cfg)"
      mkdir -p "$(dirname "$qtct_cfg")/colors"
      cat > "$qtct_cfg" <<EOF
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
}

# Config files: niri + Noctalia (from config/ in this repo)
step_config() {
  local cfg_home niri_dir niri_src niri_ver noctalia_dir old
  cfg_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  niri_dir="$cfg_home/niri"

  # Prepare the niri config in a temp copy so the blur decision is part of the
  # comparison (and re-runs don't back up an unchanged config).
  niri_src=$(mktemp -d)
  cp -r "$REPO_DIR/config/niri/." "$niri_src/"

  # Blur needs niri >= 26.04 — older versions reject the settings in cfg/blur.kdl.
  niri_ver=$(niri --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)
  if [[ $WITH_BLUR -eq 0 ]]; then
    info "Blur disabled (--no-blur)"
    sed -i 's|^include "./cfg/blur.kdl"|// include "./cfg/blur.kdl"  // disabled by --no-blur|' "$niri_src/config.kdl"
  elif [[ -z $niri_ver ]] || ! version_ge "$niri_ver" 26.04; then
    warn "niri ${niri_ver:-(unknown version)} is older than 26.04 — blur is off. Re-run the installer after upgrading niri."
    sed -i 's|^include "./cfg/blur.kdl"|// include "./cfg/blur.kdl"  // needs niri 26.04+|' "$niri_src/config.kdl"
  fi

  install_config "$niri_src" "$niri_dir"
  rm -rf "$niri_src"

  # Noctalia: only config.toml is managed; other files in ~/.config/noctalia
  # (plugins, your own *.toml) are left alone.
  noctalia_dir="$cfg_home/noctalia"
  mkdir -p "$noctalia_dir"
  install_config "$REPO_DIR/config/noctalia/config.toml" "$noctalia_dir/config.toml"
  # Files older versions of this script wrote, now part of config.toml.
  for old in polkit.toml theming.toml; do
    if [[ -f $noctalia_dir/$old ]] && grep -q 'install-niri-noctalia\|polkit_agent' "$noctalia_dir/$old"; then
      mv "$noctalia_dir/$old" "$noctalia_dir/$old.bak.$(date +%Y%m%d-%H%M%S)"
    fi
  done

  # Folder for niri screenshots (screenshot-path in cfg/misc.kdl).
  mkdir -p "$HOME/Pictures/Screenshots"

  # btop: Noctalia's btop colour template only switches the theme if btop.conf
  # exists, and btop only creates it on first launch — so start one.
  if [[ ! -f $cfg_home/btop/btop.conf ]]; then
    info "Creating ~/.config/btop/btop.conf with Noctalia's colours"
    mkdir -p "$cfg_home/btop"
    printf '# Created by install-niri-noctalia.sh; btop adds its other settings on first run.\ncolor_theme = "noctalia"\n' \
      > "$cfg_home/btop/btop.conf"
  fi

  if command -v niri >/dev/null && ! niri validate -c "$niri_dir/config.kdl"; then
    warn "niri reports a config error in $niri_dir — see the log. Your previous config is in $niri_dir.bak.*"
  fi
}

# Greeter (greetd + noctalia-greeter)
step_greeter() {
  local greeter_cmd greetd_cfg=/etc/greetd/config.toml tmp current_dm
  sudo pacman -S --needed --noconfirm greetd
  install_pkg "$GREETER_PKG"

  greeter_cmd=$(command -v noctalia-greeter-session || echo /usr/bin/noctalia-greeter-session)

  info "Configuring greetd ($greetd_cfg)"
  sudo mkdir -p /etc/greetd
  if [[ -f $greetd_cfg ]]; then sudo cp "$greetd_cfg" "$greetd_cfg.bak.$(date +%s)"; fi

  # Replace only the [default_session] section, keep everything else (e.g. [terminal]).
  tmp=$(mktemp)
  if [[ -f $greetd_cfg ]]; then
    # shellcheck disable=SC2024  # the redirect writes our own temp file, on purpose
    sudo awk '
      /^\s*\[default_session\]/ { skip=1; next }
      /^\s*\[/                  { skip=0 }
      !skip
    ' "$greetd_cfg" > "$tmp"
  fi
  grep -q '^\s*\[terminal\]' "$tmp" || printf '[terminal]\nvt = 1\n\n' >> "$tmp"
  cat >> "$tmp" <<EOF

[default_session]
command = "$greeter_cmd"
user = "greeter"
EOF
  sudo install -m 644 "$tmp" "$greetd_cfg"
  rm -f "$tmp"

  info "Setting up greeter state/appearance sync"
  if command -v noctalia-greeter-apply-appearance >/dev/null; then
    sudo noctalia-greeter-apply-appearance --setup-system || warn "Greeter appearance setup failed (non-fatal)."
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
}

# Step list: function | title shown on screen.
STEP_FN=(step_update step_aur step_amd step_niri step_zsh step_fonts step_files
         step_helium step_apps step_gaming_vms step_keyring step_noctalia step_theming step_config
         step_greeter)
STEP_TITLE=(
  "Updating Arch"
  "AUR helper (paru)"
  "AMD GPU drivers + LACT"
  "niri and desktop tools"
  "zsh, Starship and fastfetch"
  "Fonts"
  "Nautilus, phones and network shares"
  "Helium browser"
  "Steam, Discord, Spotify, ProtonPlus, Claude"
  "MangoHud, GOverlay, Faugus, VM Curator"
  "GNOME Keyring"
  "Noctalia shell"
  "GTK and Qt theming"
  "Config files (niri, Noctalia)"
  "Login screen (Noctalia greeter)"
)
N=${#STEP_FN[@]}
declare -a STATE   # pending | running | done | skipped | failed

# ═════════════════════════════════════════════════════════════════════════════
#  Progress screen
# ═════════════════════════════════════════════════════════════════════════════

BANNER=(
"███╗   ██╗██╗██████╗ ██╗███╗   ██╗ ██████╗  ██████╗"
"████╗  ██║██║██╔══██╗██║████╗  ██║██╔═══██╗██╔════╝"
"██╔██╗ ██║██║██████╔╝██║██╔██╗ ██║██║   ██║██║     "
"██║╚██╗██║██║██╔══██╗██║██║╚██╗██║██║   ██║██║     "
"██║ ╚████║██║██║  ██║██║██║ ╚████║╚██████╔╝╚██████╗"
"╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝  ╚═════╝"
)
GRAD=( "137;180;250" "160;170;250" "180;160;248" "203;166;247" "220;160;230" "245;194;231" )
SUBTITLE_PLAIN="niri · noctalia · arch linux — desktop installer"
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
START=$(date +%s)
UI_ACTIVE=0
STEP_PID=""
SUDO_KEEPALIVE=""

term_cols()  { tput cols 2>/dev/null || echo 80; }
term_lines() { tput lines 2>/dev/null || echo 40; }

center() {  # center <text-without-colour-codes> <coloured-text>
  local pad=$(( ($(term_cols) - ${#1}) / 2 ))
  if (( pad < 0 )); then pad=0; fi
  printf '%*s%s' "$pad" '' "$2"
}

banner() {
  local i
  if (( $(term_cols) >= 56 )); then
    for i in "${!BANNER[@]}"; do
      if [[ -n $RST ]]; then
        center "${BANNER[i]}" "$(printf '\e[38;2;%sm%s%s' "${GRAD[i]}" "${BANNER[i]}" "$RST")"
      else
        center "${BANNER[i]}" "${BANNER[i]}"
      fi
      printf '%s\n' "$EL"
    done
  else
    center "NIRINOC" "${BOLD}${ACC}NIRINOC${RST}"; printf '%s\n' "$EL"
  fi
  center "$SUBTITLE_PLAIN" "${MUT}niri · noctalia · arch linux ${ACC}—${MUT} desktop installer${RST}"
  printf '%s\n' "$EL"
}

draw_header() {
  local cols done=0 i pct barw fill elapsed bar_on bar_off plain
  cols=$(term_cols)
  for ((i = 0; i < N; i++)); do
    case ${STATE[i]} in done|skipped) done=$((done + 1)) ;; esac
  done
  pct=$(( done * 100 / N ))
  elapsed=$(( $(date +%s) - START ))

  printf '\e[H\e[K\n'
  # Hide the big banner on short terminals so the checklist still fits.
  if (( $(term_lines) >= N + 17 )); then banner; else
    center "NIRINOC — desktop installer" "${BOLD}${ACC}NIRINOC${RST}${MUT} — desktop installer${RST}"; printf '\e[K\n'
  fi
  printf '\e[K\n'

  barw=$(( cols - 30 ))
  if (( barw > 60 )); then barw=60; fi
  if (( barw < 10 )); then barw=10; fi
  fill=$(( done * barw / N ))
  printf -v bar_on '%*s' "$fill" ''; bar_on=${bar_on// /█}
  printf -v bar_off '%*s' "$((barw - fill))" ''; bar_off=${bar_off// /░}
  printf -v plain '%3d%%  %s%s  %d/%d  %02d:%02d' "$pct" "$bar_on" "$bar_off" "$done" "$N" $((elapsed / 60)) $((elapsed % 60))
  center "$plain" "$(printf '%s%3d%%%s  %s%s%s%s%s  %s%d/%d  %02d:%02d%s' \
    "$BOLD$TXT" "$pct" "$RST" "$ACC" "$bar_on" "$BAR_OFF" "$bar_off" "$RST" \
    "$MUT" "$done" "$N" $((elapsed / 60)) $((elapsed % 60)) "$RST")"
  printf '\e[K\n\e[K\n'
}

# Latest non-empty log line, without colour codes or carriage-return progress.
last_log_line() {
  tail -n 20 "$LOG" 2>/dev/null \
    | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | awk -F'\r' '{print $NF}' \
    | grep -v '^[[:space:]]*$' | tail -n 1
}

draw() {
  local frame=$1 cols left i icon col title last
  cols=$(term_cols)
  draw_header
  left=$(( (cols - 52) / 2 ))
  if (( left < 2 )); then left=2; fi
  for ((i = 0; i < N; i++)); do
    title=${STEP_TITLE[i]}
    case ${STATE[i]} in
      done)    icon="${GRN}✔"; col=$MUT ;;
      running) icon="${ACC}${SPIN[frame % ${#SPIN[@]}]}"; col="$BOLD$TXT" ;;
      failed)  icon="${RED}✘"; col="$BOLD$RED" ;;
      skipped) icon="${BAR_OFF}–"; col=$BAR_OFF; title="$title (skipped)" ;;
      *)       icon="${BAR_OFF}○"; col=$BAR_OFF ;;
    esac
    printf '%*s%s%s  %s%s%s\e[K\n' "$left" '' "$icon" "$RST" "$col" "$title" "$RST"
  done
  last=$(last_log_line | cut -c1-$(( cols - left - 4 )))
  printf '\e[K\n%*s%s› %s%s\e[K\n\e[K\n' "$left" '' "$DIM$MUT" "$last" "$RST"
  center "Full log: ~/${LOG##*/}   ·   Ctrl+C to cancel" "${DIM}${MUT}Full log: ~/${LOG##*/}   ·   Ctrl+C to cancel${RST}"
  printf '\e[K\e[J'
}

ui_start() { printf '\e[?1049h\e[?25l\e[2J'; UI_ACTIVE=1; }   # alternate screen, hide cursor
ui_stop()  { if [[ $UI_ACTIVE -eq 1 ]]; then printf '\e[?25h\e[?1049l'; UI_ACTIVE=0; fi; }

cleanup() {
  ui_stop
  if [[ -n $STEP_PID ]]; then kill "$STEP_PID" 2>/dev/null; fi
  if [[ -n $SUDO_KEEPALIVE ]]; then kill "$SUDO_KEEPALIVE" 2>/dev/null; fi
  rm -f "$WARN_FILE"
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; printf "\nCancelled. Log: %s\n" "$LOG"; exit 130' INT TERM

# Run step $1. Returns 0 on success, 1 on failure.
run_step() {
  local i=$1 frame=0 rc
  STATE[i]=running
  printf '\n════ [%d/%d] %s ════\n' "$((i + 1))" "$N" "${STEP_TITLE[i]}" >> "$LOG"

  if [[ $VERBOSE -eq 1 ]]; then
    printf '\n%s==> [%d/%d] %s%s\n' "$BOLD$ACC" "$((i + 1))" "$N" "${STEP_TITLE[i]}" "$RST"
    ( set -e; "${STEP_FN[i]}" ) 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
  else
    ( set -e; "${STEP_FN[i]}" ) >> "$LOG" 2>&1 < /dev/null &
    STEP_PID=$!
    while kill -0 "$STEP_PID" 2>/dev/null; do
      draw "$frame"; frame=$((frame + 1)); sleep 0.1
    done
    wait "$STEP_PID"; rc=$?
    STEP_PID=""
  fi

  if [[ $rc -eq 0 ]]; then STATE[i]="done"; else STATE[i]=failed; fi
  [[ $VERBOSE -eq 1 ]] || draw "$frame"
  return "$rc"
}

# Ask what to do after a failed step. Sets CHOICE to r, s or q.
CHOICE=""
failure_menu() {
  local i=$1 key cols
  cols=$(term_cols)
  if [[ $VERBOSE -eq 0 ]]; then
    # The error panel replaces the checklist so everything fits on one screen.
    printf '\e[2J'; draw_header
    center "✘ Step $((i + 1))/$N failed: ${STEP_TITLE[i]}" \
      "${BOLD}${RED}✘ Step $((i + 1))/$N failed: ${RST}${BOLD}${STEP_TITLE[i]}${RST}"
    printf '\n\n      %sLast lines of the log:%s\n' "$MUT" "$RST"
    tail -n 12 "$LOG" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | cut -c1-$(( cols - 12 )) \
      | sed "s/^/      ${MUT}│${RST} /"
    printf '\n      %sFull log: %s%s\n' "$DIM$MUT" "$LOG" "$RST"
  else
    printf '\n%s✘ Step %d/%d failed: %s%s  (log: %s)\n' "$BOLD$RED" "$((i + 1))" "$N" "${STEP_TITLE[i]}" "$RST" "$LOG"
  fi
  if [[ $ASSUME_YES -eq 1 ]]; then CHOICE=q; return; fi
  printf '\n      %s[r]%s retry   %s[s]%s skip   %s[q]%s quit and show the log  ' \
    "$ACC" "$RST" "$ACC" "$RST" "$ACC" "$RST"
  while true; do
    read -rsn1 key < /dev/tty
    case $key in r|R) CHOICE=r; return ;; s|S) CHOICE=s; return ;; q|Q) CHOICE=q; return ;; esac
  done
}

# ═════════════════════════════════════════════════════════════════════════════
#  Start: questions first, then the progress screen
# ═════════════════════════════════════════════════════════════════════════════

if [[ $AMD_GPU == auto ]]; then
  if has_amd_gpu; then AMD_GPU=yes; else AMD_GPU=no; fi
fi

clear 2>/dev/null || true
echo; banner; echo
printf '  %sThis will install and set up:%s\n' "$BOLD" "$RST"
printf '   %s•%s niri, %s%s\n' "$ACC" "$RST" "$SHELL_PKG" "$([[ $WITH_GREETER -eq 1 ]] && echo ", $GREETER_PKG (login screen)")"
if [[ $AMD_GPU == yes ]]; then printf '   %s•%s AMD GPU drivers and LACT\n' "$ACC" "$RST"; fi
printf '   %s•%s kitty, zsh + Starship, fonts, Nautilus, GNOME Keyring, GTK/Qt theming\n' "$ACC" "$RST"
printf '   %s•%s Helium, Steam, Discord, Spotify, ProtonPlus, Claude Desktop\n' "$ACC" "$RST"
printf '   %s•%s MangoHud, GOverlay, Faugus Launcher, VM Curator\n' "$ACC" "$RST"
printf '   %s•%s your niri + Noctalia config (an existing one is backed up first)\n\n' "$ACC" "$RST"

confirm "Continue?" || exit 0

# Every other question is asked now, so nothing interrupts the install later.
WANT_MULTILIB=1
if ! multilib_enabled; then
  confirm "Enable the [multilib] repo? (32-bit libraries — needed by Steam and Proton)" || WANT_MULTILIB=0
fi
REMOVE_AMDVLK=0
if [[ $AMD_GPU == yes ]] && pacman -Qq amdvlk &>/dev/null; then
  confirm "Remove AMDVLK? (discontinued AMD Vulkan driver that can override the better RADV)" && REMOVE_AMDVLK=1
fi
REMOVE_SPOTIFY_LAUNCHER=0
if pacman -Qq spotify-launcher &>/dev/null; then
  confirm "Remove spotify-launcher? (replaced by the AUR 'spotify' package)" && REMOVE_SPOTIFY_LAUNCHER=1
fi

# Ask for the sudo password once, then keep it fresh in the background.
printf '\n%s::%s Your password is needed for sudo (asked once).\n' "$ACC" "$RST"
sudo -v || die "sudo failed."
( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &
SUDO_KEEPALIVE=$!

# Start a fresh log (keeping the previous one as .old).
if [[ -f $LOG ]]; then mv -f "$LOG" "$LOG.old"; fi
{
  echo "arch-niri-noctalia installer — $(date)"
  echo "repo: $REPO_DIR ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo 'no git'))"
  echo "options: $*"
  echo "AMD GPU: $AMD_GPU   multilib: $WANT_MULTILIB   greeter: $WITH_GREETER   blur: $WITH_BLUR"
} > "$LOG"

for ((i = 0; i < N; i++)); do STATE[i]=pending; done
# Look steps up by name, so adding steps never shifts these.
step_index() { local j; for j in "${!STEP_FN[@]}"; do [[ ${STEP_FN[j]} == "$1" ]] && { echo "$j"; return; }; done; }
[[ $AMD_GPU == yes ]]     || STATE[$(step_index step_amd)]=skipped
[[ $WITH_GREETER -eq 1 ]] || STATE[$(step_index step_greeter)]=skipped

[[ $VERBOSE -eq 1 ]] || ui_start

i=0
while (( i < N )); do
  if [[ ${STATE[i]} == skipped ]]; then i=$((i + 1)); continue; fi
  # Not `if run_step`: bash ignores `set -e` inside anything called from an
  # if/&&/|| test, which would stop steps from failing on errors.
  run_step "$i"; rc=$?
  if [[ $rc -eq 0 ]]; then i=$((i + 1)); continue; fi
  failure_menu "$i"
  case $CHOICE in
    r) STATE[i]=pending; [[ $VERBOSE -eq 1 ]] || printf '\e[2J' ;;
    s) STATE[i]=skipped; warn "Skipped after an error: ${STEP_TITLE[i]} (details in the log)"
       [[ $VERBOSE -eq 1 ]] || printf '\e[2J'; i=$((i + 1)) ;;
    *) cleanup; trap - EXIT
       printf '\nInstall stopped at: %s\nFull log: %s\n' "${STEP_TITLE[i]}" "$LOG"
       if [[ $ASSUME_YES -eq 0 ]] && command -v less >/dev/null; then less -R +G "$LOG"; fi
       exit 1 ;;
  esac
done

sleep 0.3
ui_stop

# ── Summary (printed to the normal screen so it stays in your scrollback) ──
ELAPSED=$(( $(date +%s) - START ))
clear 2>/dev/null || true
echo; banner; echo
center "✔ All done in $((ELAPSED / 60))m $((ELAPSED % 60))s" "${BOLD}${GRN}✔ All done in $((ELAPSED / 60))m $((ELAPSED % 60))s${RST}"
printf '\n\n'

if [[ -s $WARN_FILE ]]; then
  printf '  %sWorth a look:%s\n' "$BOLD$YLW" "$RST"
  sort -u "$WARN_FILE" | sed "s/^/   ${YLW}!${RST} /"
  echo
fi

printf '  %sNext:%s\n' "$BOLD" "$RST"
if [[ $WITH_GREETER -eq 1 ]]; then
  printf '   %s•%s Reboot, then pick %sniri%s at the Noctalia login screen.\n' "$ACC" "$RST" "$ACC" "$RST"
else
  printf '   %s•%s Log out and start niri from a TTY with: %sniri-session%s\n' "$ACC" "$RST" "$ACC" "$RST"
fi
printf '   %s•%s Press %sMod+Shift+/%s in niri to see all keybinds.\n' "$ACC" "$RST" "$BOLD" "$RST"
printf '   %s•%s Full log: %s\n\n' "$ACC" "$RST" "$LOG"

if [[ $ASSUME_YES -eq 0 && $WITH_GREETER -eq 1 ]]; then
  if confirm "Reboot now?"; then sudo systemctl reboot; fi
fi
