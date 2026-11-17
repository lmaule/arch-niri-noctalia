#!/usr/bin/env bash
# Arch desktop setup: Umbriel + Noctalia shell + Noctalia greeter, plus drivers, apps and shell config.
#
# Usage:  ./install-umbrinoc.sh [options]
#   --git         use the -git (development) packages for noctalia / noctalia-greeter
#   --no-greeter  skip greetd + noctalia-greeter setup
#   --no-blur     leave out the blur settings (cfg/blur.toml)
#   --amd-gpu     force-install AMD GPU drivers (default: auto-detect an AMD card)
#   --no-amd-gpu  skip AMD GPU drivers
#   --yes         don't ask questions (answer yes to everything, never reboot)
#   --verbose     show the full output instead of the progress screen
#
# Run as your normal user (NOT root), from a clone of the repo: it installs the
# config files in config/ and etc/ next to it. sudo is used where needed.
# Everything is logged to ~/umbrinoc-install.log.

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

# ── Colours and symbols ─────────────────────────────────────────────────────
# Three palettes, picked by what the terminal can show:
#   truecolor  kitty and most modern terminals — the pastel design
#   256        terminals without 24-bit colour — nearest 256-colour shades
#   16         the Linux TTY console — basic ANSI colours. It turns every 24-bit
#              pastel into plain white, so those can't be used there.
# The TTY's font also lacks symbols like ✔ ✘ ○ and the braille spinner, so it
# gets plain ones that every console font has.
COLOR_DEPTH=none
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  if [[ ${TERM:-} == linux ]]; then
    COLOR_DEPTH=16
  elif [[ ${COLORTERM:-} == truecolor || ${COLORTERM:-} == 24bit \
          || ${TERM:-} =~ (kitty|ghostty|foot|wezterm|alacritty|direct) ]]; then
    COLOR_DEPTH=truecolor
  elif (( $(tput colors 2>/dev/null || echo 8) >= 256 )); then
    COLOR_DEPTH=256
  else
    COLOR_DEPTH=16
  fi
fi

case $COLOR_DEPTH in
  truecolor)
    GRN=$'\e[38;2;166;227;161m' RED=$'\e[38;2;243;139;168m' YLW=$'\e[38;2;249;226;175m'
    ACC=$'\e[38;2;203;166;247m' MUT=$'\e[38;2;127;132;156m' TXT=$'\e[38;2;205;214;244m'
    BAR_OFF=$'\e[38;2;69;71;90m'
    GRAD=( $'\e[38;2;137;180;250m' $'\e[38;2;160;170;250m' $'\e[38;2;180;160;248m'
           $'\e[38;2;203;166;247m' $'\e[38;2;220;160;230m' $'\e[38;2;245;194;231m' ) ;;
  256)
    GRN=$'\e[38;5;151m' RED=$'\e[38;5;211m' YLW=$'\e[38;5;223m'
    ACC=$'\e[38;5;183m' MUT=$'\e[38;5;103m' TXT=$'\e[38;5;189m'
    BAR_OFF=$'\e[38;5;238m'
    GRAD=( $'\e[38;5;111m' $'\e[38;5;147m' $'\e[38;5;141m' $'\e[38;5;183m' $'\e[38;5;182m' $'\e[38;5;218m' ) ;;
  16)
    GRN=$'\e[1;32m' RED=$'\e[1;31m' YLW=$'\e[1;33m'
    ACC=$'\e[1;35m' MUT=$'\e[0;37m' TXT=$'\e[1;37m'
    BAR_OFF=$'\e[1;30m'   # bold black = dark grey on the console
    GRAD=( $'\e[1;36m' $'\e[1;34m' $'\e[1;34m' $'\e[1;35m' $'\e[1;35m' $'\e[0;35m' ) ;;
esac

if [[ $COLOR_DEPTH == none ]]; then
  RST='' BOLD='' DIM='' GRN='' RED='' YLW='' ACC='' MUT='' TXT='' BAR_OFF='' EL=''
  GRAD=( '' '' '' '' '' '' )
else
  RST=$'\e[0m' BOLD=$'\e[1m' EL=$'\e[K'
  # The console shows "dim" as its own odd colour, so only use it elsewhere.
  if [[ $COLOR_DEPTH == 16 ]]; then DIM=''; else DIM=$'\e[2m'; fi
fi

if [[ ${TERM:-} == linux ]]; then
  SYM_OK='√' SYM_FAIL='x' SYM_TODO='·' SYM_SKIP='-' SYM_ARROW='>' SYM_DASH='-' SYM_DOT='*'
  SPIN=('|' '/' '-' '\')
else
  SYM_OK='✔' SYM_FAIL='✘' SYM_TODO='○' SYM_SKIP='–' SYM_ARROW='›' SYM_DASH='—' SYM_DOT='•'
  SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
fi

LOG="$HOME/umbrinoc-install.log"
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
[[ -d $REPO_DIR/config/umbriel && -d $REPO_DIR/etc/dconf ]] || die \
  "config/ and etc/ not found next to this script. Clone the whole repo and run it from there:
    git clone https://github.com/lmaule/arch-umbriel-noctalia.git && cd arch-umbriel-noctalia && ./install-umbrinoc.sh"

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

# AMD/ATI graphics = PCI vendor 0x1002 with a display class (0x03xxxx). Read
# from the PCI bus, not /sys/class/drm: on a fresh install amdgpu often can't
# load yet (its firmware isn't installed), so the card only shows up on PCI.
has_amd_gpu() {
  local d
  for d in /sys/bus/pci/devices/*; do
    [[ -r $d/vendor && -r $d/class ]] || continue
    if [[ $(<"$d/vendor") == 0x1002 && $(<"$d/class") == 0x03* ]]; then return 0; fi
  done
  return 1
}

# Graphics devices on the PCI bus, for the log.
list_gpus() {
  local d drv found=0
  for d in /sys/bus/pci/devices/*; do
    [[ -r $d/class && $(<"$d/class") == 0x03* ]] || continue
    found=1
    drv=none
    if [[ -e $d/driver ]]; then drv=$(basename "$(readlink -f "$d/driver")"); fi
    printf '  %s vendor=%s device=%s driver=%s\n' "${d##*/}" "$(<"$d/vendor")" "$(<"$d/device")" "$drv"
  done
  [[ $found -eq 1 ]] || echo "  (none found)"
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
#  Package lists from the official repos. step_packages installs them all in
#  one pacman run (so post-install hooks run once); each step still installs
#  its own list with --needed, which is a no-op after that, or the fallback if
#  the one-go install failed.
# ═════════════════════════════════════════════════════════════════════════════

PKGS_DESKTOP=(xdg-desktop-portal-gtk kitty btop fastfetch hwdata
              pipewire wireplumber pipewire-pulse polkit upower ddcutil
              quickshell)   # quickshell: QtQuick toolkit for custom widgets and Quickshell-based shells
PKGS_ZSH=(zsh zsh-completions zsh-autosuggestions zsh-syntax-highlighting starship)
#   noto-fonts:              main UI font, wide language coverage
#   noto-fonts-cjk:          Chinese / Japanese / Korean
#   noto-fonts-emoji:        colour emoji (Noctalia's launcher has an emoji picker)
#   ttf-jetbrains-mono-nerd: coding font with Nerd Font icons, used for kitty
#   ttf-nerd-fonts-symbols:  icon fallback so any font can show Nerd Font glyphs
PKGS_FONTS=(noto-fonts noto-fonts-cjk noto-fonts-emoji
            ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono)
# Luciole (the file manager) is built from the AUR in step_files. These are
# GVfs (Trash, phones, network shares) and Luciole's optional helpers: video and
# PDF thumbnails, 7z archives, network TLS and terminal actions.
PKGS_FILES=(xdg-user-dirs xdg-utils
            gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-dnssd avahi nss-mdns
            ffmpeg poppler 7zip glib-networking xdg-terminal-exec)
# Optional extras, only installed if your repos have them:
#   gvfs-wsdd: find Windows (SMB) machines   gvfs-afc: iPhone/iPad files
#   gvfs-gphoto2: cameras (PTP)              ffmpegthumbnailer: video thumbnails
PKGS_FILES_OPTIONAL=(gvfs-wsdd gvfs-afc gvfs-gphoto2 ffmpegthumbnailer)
PKGS_APPS=(discord qbittorrent zed)       # optional apps from the repos
PKGS_GAMING=(mangohud goverlay edk2-ovmf swtpm)
PKGS_KEYRING=(gnome-keyring libsecret seahorse)
PKGS_THEMING=(adw-gtk-theme nwg-look qt5ct qt6ct capitaine-cursors dconf)

# AMD driver packages -> AMD_PKGS (needs multilib already decided).
amd_packages() {
  local fw_pkg=linux-firmware
  # Newer Arch splits AMD firmware into linux-firmware-amdgpu.
  if pacman -Si linux-firmware-amdgpu &>/dev/null; then fw_pkg=linux-firmware-amdgpu; fi
  AMD_PKGS=("$fw_pkg" mesa vulkan-radeon vulkan-icd-loader libva-utils vulkan-tools mesa-utils
            rocm-smi-lib)  # rocm-smi-lib: GPU usage/temps in btop
  if multilib_enabled; then
    AMD_PKGS+=(lib32-mesa lib32-vulkan-radeon lib32-vulkan-icd-loader)
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Steps — each runs in its own subshell with `set -e`; output goes to the log
# ═════════════════════════════════════════════════════════════════════════════

step_update() {
  info "Updating system and installing base tools"
  sudo pacman -Syu --needed --noconfirm base-devel git
}

# Every official-repo package in one pacman run. Never fails the install: if
# this run fails, each later step installs its own packages as before.
step_packages() {
  local -a all=()
  local p
  ensure_multilib || true   # Steam and the 32-bit drivers need it

  all+=("${PKGS_DESKTOP[@]}" "${PKGS_ZSH[@]}" "${PKGS_FONTS[@]}" "${PKGS_FILES[@]}"
        "${PKGS_GAMING[@]}" "${PKGS_KEYRING[@]}" "${PKGS_THEMING[@]}")
  for p in "${PKGS_FILES_OPTIONAL[@]}" "${PKGS_APPS[@]}" "$SHELL_PKG"; do
    if pacman -Si "$p" &>/dev/null; then all+=("$p"); fi
  done
  if [[ $AMD_GPU == yes ]]; then
    amd_packages
    all+=("${AMD_PKGS[@]}" lact)
  fi
  if multilib_enabled; then
    all+=(steam lib32-mangohud)
    if [[ $AMD_GPU == yes ]]; then all+=(lib32-mesa lib32-vulkan-radeon); fi
  fi
  if [[ $WITH_GREETER -eq 1 ]]; then
    all+=(greetd)
    if pacman -Si "$GREETER_PKG" &>/dev/null; then all+=("$GREETER_PKG"); fi
  fi

  info "Installing ${#all[@]} packages from the Arch repos in one go"
  if ! sudo pacman -S --needed --noconfirm "${all[@]}"; then
    info "The one-go install didn't work; each step will install its own packages instead."
  fi
  return 0
}

step_aur() {
  ensure_aur_helper
  info "Using AUR helper: $AUR_HELPER"
}

# AMD GPU drivers (RX 9000 / RDNA 4, e.g. RX 9070 XT)
step_amd() {
  local kver mesa_ver p
  info "Installing AMD GPU drivers (amdgpu kernel driver + Mesa RADV/radeonsi)"

  # Kernel: RDNA 4 needs 6.13+, 6.14+ recommended.
  kver=$(uname -r | grep -oE '^[0-9]+\.[0-9]+')
  if ! version_ge "$kver" 6.13; then
    warn "Kernel $kver is too old for RX 9000 cards (need 6.13+). Update with 'sudo pacman -Syu' and reboot."
  fi

  # 32-bit drivers (Steam, Wine/Proton) need the multilib repo.
  ensure_multilib || true

  amd_packages
  sudo pacman -S --needed --noconfirm "${AMD_PKGS[@]}"

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

step_desktop() {
  local p
  # niri is replaced by Umbriel; remove it if you said yes at the start.
  for p in niri xwayland-satellite; do
    if pacman -Qq "$p" &>/dev/null && [[ $REMOVE_NIRI -eq 1 ]]; then
      info "Removing $p (replaced by Umbriel)"
      sudo pacman -Rns --noconfirm "$p"
    fi
  done

  # Umbriel is only packaged as umbriel-git (AUR), built from its latest code.
  # It pulls in its screen-sharing portal and Xwayland (started on demand).
  info "Installing Umbriel (umbriel-git from the AUR; this build takes a few minutes)"
  install_pkg umbriel-git
  info "Installing desktop companion packages"
  sudo pacman -S --needed --noconfirm "${PKGS_DESKTOP[@]}"

  # ddcutil: brightness control for external monitors over DDC/CI (Noctalia's
  # brightness keys and slider; switched on in config/noctalia/config.toml).
  # The package loads the i2c-dev module at boot and gives the logged-in user
  # access; load it now too so it works before the next reboot.
  if [[ -d /run/systemd/system ]]; then
    sudo modprobe i2c-dev || warn "Couldn't load the i2c-dev module now; it loads at the next boot."
  fi
}

step_zsh() {
  local starship_cfg
  info "Installing zsh"
  sudo pacman -S --needed --noconfirm "${PKGS_ZSH[@]}"

  # Starter ~/.zshrc (skipped if you already have one). Without it, zsh opens a
  # first-run setup wizard the first time you start it.
  if [[ ! -f $HOME/.zshrc ]]; then
    info "Creating a starter ~/.zshrc"
    cat > "$HOME/.zshrc" <<'EOF'
# ~/.zshrc — created by install-umbrinoc.sh

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
  info "Installing fonts"
  sudo pacman -S --needed --noconfirm "${PKGS_FONTS[@]}"
  fc-cache -f

  # Use JetBrains Mono Nerd Font in kitty, unless you've already picked a font.
  kitty_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/kitty/kitty.conf"
  if ! grep -qsE '^\s*font_family\s' "$kitty_cfg"; then
    info "Setting kitty's font to JetBrainsMono Nerd Font ($kitty_cfg)"
    mkdir -p "$(dirname "$kitty_cfg")"
    printf '\n# Added by install-umbrinoc.sh\nfont_family JetBrainsMono Nerd Font\nfont_size 11.0\n' >> "$kitty_cfg"
  fi
}

# File manager (Luciole), user dirs, MTP & network shares
step_files() {
  local p terminals
  if pacman -Qq nautilus &>/dev/null && [[ $REMOVE_NAUTILUS -eq 1 ]]; then
    info "Removing Nautilus (replaced by Luciole)"
    sudo pacman -Rns --noconfirm nautilus \
      || warn "Couldn't remove Nautilus (another package may need it); it's left installed."
  fi

  info "Installing XDG user dirs, MTP and network share support"
  sudo pacman -S --needed --noconfirm "${PKGS_FILES[@]}"
  # Optional extras (see PKGS_FILES_OPTIONAL), only if your repos have them.
  for p in "${PKGS_FILES_OPTIONAL[@]}"; do
    if pacman -Si "$p" &>/dev/null; then
      sudo pacman -S --needed --noconfirm "$p"
    fi
  done

  # Luciole: Noctalia's file manager, only packaged as luciole-git (AUR),
  # built from its latest code.
  info "Installing Luciole (luciole-git from the AUR)"
  install_pkg luciole-git

  # Create ~/Desktop, ~/Documents, ~/Downloads, ~/Music, ~/Pictures, ~/Videos, ...
  xdg-user-dirs-update

  # Luciole's sidebar (Places) shows the folders in ~/.config/gtk-3.0/bookmarks.
  # GNOME fills that in at login with xdg-user-dirs-gtk, which needs a running
  # GNOME-style session (Umbriel doesn't run it), so add the same entries here.
  # Your own bookmarks are kept; entries already there aren't added twice.
  local bookmarks="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks" dir name uri
  mkdir -p "$(dirname "$bookmarks")"
  touch "$bookmarks"
  for name in DOCUMENTS DOWNLOAD MUSIC PICTURES VIDEOS; do
    dir=$(xdg-user-dir "$name")
    [[ -n $dir && $dir != "$HOME" && -d $dir ]] || continue
    uri="file://${dir// /%20}"
    if ! awk -v u="$uri" '$1 == u { found = 1 } END { exit !found }' "$bookmarks"; then
      info "Adding $dir to the file manager's sidebar"
      printf '%s\n' "$uri" >> "$bookmarks"
    fi
  done

  # Make Luciole the default app for opening folders.
  xdg-mime default dev.noctalia.luciole.desktop inode/directory

  # Terminal for Luciole's "Open Terminal Here" (and other apps that ask
  # xdg-terminal-exec): kitty. Skipped if you've already chosen one.
  terminals="${XDG_CONFIG_HOME:-$HOME/.config}/xdg-terminals.list"
  if [[ ! -f $terminals ]]; then
    info "Setting kitty as the terminal for 'Open Terminal Here' ($terminals)"
    mkdir -p "$(dirname "$terminals")"
    printf '# Created by install-umbrinoc.sh\nkitty.desktop\n' > "$terminals"
  fi

  # Avahi: lets the file manager find shares and printers on the LAN.
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

# Do Steam's first-run data setup now, exactly as its launcher would.
# Steam expects ~/.steam/steam to be a symlink to ~/.local/share/Steam. If
# anything creates ~/.steam/steam as a plain folder first, Steam's launcher
# puts its link *inside* that folder and then fails with "Couldn't set up
# Steam data". Setting it up here makes the link exist before any other tool
# (or a first launch) can touch it, and moves a stray folder out of the way.
setup_steam_data() {
  local boot=/usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz
  local data="${XDG_DATA_HOME:-$HOME/.local/share}/Steam" link="$HOME/.steam/steam" bak
  [[ -f $boot ]] || return 0
  if [[ -x "$(readlink -f "$link" 2>/dev/null)/steam.sh" ]]; then
    info "Steam's data folder is already set up"
    return 0
  fi
  mkdir -p "$HOME/.steam"
  if [[ -e $link && ! -L $link ]]; then
    bak="$link.bak.$(date +%Y%m%d-%H%M%S)"
    warn "$link was a plain folder, which stops Steam starting; moved it to $bak"
    mv "$link" "$bak"
  fi
  if [[ ! -x $data/steam.sh ]]; then
    info "Setting up Steam's data folder ($data)"
    ( umask 077; mkdir -p "$data" && tar -xJf "$boot" -C "$data" )
  fi
  ln -sfn "$data" "$link"
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
    if sudo pacman -S --needed --noconfirm "${steam_pkgs[@]}"; then
      setup_steam_data || warn "Couldn't pre-set up Steam's data folder; Steam will do it on first launch."
    else
      warn "Steam failed to install — skipped. See the log for details."
    fi
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

  # qBittorrent (torrent client) and Zed (code editor; its command is `zeditor`).
  install_one_of "qBittorrent" qbittorrent || true
  install_one_of "Zed" zed || true
}

# Gaming tools and VMs. Optional like the apps above: failures are reported in
# the summary, not fatal.
#   mangohud:        FPS / temperature / frame-time overlay (lib32 for 32-bit games)
#   goverlay:        GUI for configuring MangoHud
#   faugus-launcher: runs Windows games outside Steam with UMU-Launcher (AUR)
#   vm-curator-bin:  terminal app for QEMU/KVM virtual machines (AUR, prebuilt —
#                    no Rust build; the source package is the fallback); edk2-ovmf
#                    adds UEFI boot and swtpm a TPM, both needed for Windows 11 VMs
step_gaming_vms() {
  local -a pkgs=("${PKGS_GAMING[@]}")
  if multilib_enabled; then pkgs+=(lib32-mangohud); fi
  info "Installing MangoHud, GOverlay and VM firmware (UEFI/TPM)"
  sudo pacman -S --needed --noconfirm "${pkgs[@]}" \
    || warn "MangoHud/GOverlay failed to install — skipped. See the log for details."

  install_one_of "Faugus Launcher" faugus-launcher || true
  install_one_of "VM Curator" vm-curator-bin vm-curator || true
}

# GNOME Keyring (stores share/Wi-Fi/app passwords), unlocked at login
step_keyring() {
  local login_pam f
  info "Installing GNOME Keyring"
  sudo pacman -S --needed --noconfirm "${PKGS_KEYRING[@]}"

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
# config/noctalia/config.toml, and QT_QPA_PLATFORMTHEME in config/umbriel/cfg/environment.toml.
step_theming() {
  local v qtct_cfg
  info "Installing GTK/Qt theming tools and cursor theme"
  sudo pacman -S --needed --noconfirm "${PKGS_THEMING[@]}"

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
  sudo install -Dm644 "$REPO_DIR/etc/dconf/db/local.d/00-arch-umbriel-noctalia.conf" \
    /etc/dconf/db/local.d/00-arch-umbriel-noctalia.conf
  # The same defaults under this repo's old name, from earlier installs.
  if [[ -f /etc/dconf/db/local.d/00-arch-niri-noctalia.conf ]]; then
    sudo rm -f /etc/dconf/db/local.d/00-arch-niri-noctalia.conf
  fi
  sudo dconf update
}

# Config files: Umbriel + Noctalia (from config/ in this repo)
step_config() {
  local cfg_home umbriel_dir umbriel_src noctalia_dir old shots_cfg
  cfg_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  umbriel_dir="$cfg_home/umbriel"

  # Prepare the Umbriel config in a temp copy so the blur choice is part of the
  # comparison (and re-runs don't back up an unchanged config).
  umbriel_src=$(mktemp -d)
  cp -r "$REPO_DIR/config/umbriel/." "$umbriel_src/"
  if [[ $WITH_BLUR -eq 0 ]]; then
    info "Blur disabled (--no-blur)"
    sed -i '/^  "cfg\/blur.toml",$/d' "$umbriel_src/config.toml"
  fi

  install_config "$umbriel_src" "$umbriel_dir"
  rm -rf "$umbriel_src"

  # Noctalia: only config.toml is managed; other files in ~/.config/noctalia
  # (plugins, your own *.toml) are left alone.
  noctalia_dir="$cfg_home/noctalia"
  mkdir -p "$noctalia_dir"
  install_config "$REPO_DIR/config/noctalia/config.toml" "$noctalia_dir/config.toml"

  # Desktop portals: Luciole as the Open/Save file picker for other apps.
  # This replaces Umbriel's packaged umbriel-portals.conf, so it repeats its
  # default (Umbriel's portal, then GTK's). Applies from the next login.
  install_config "$REPO_DIR/config/xdg-desktop-portal/umbriel-portals.conf" \
    "$cfg_home/xdg-desktop-portal/umbriel-portals.conf"
  # Files older versions of this script wrote, now part of config.toml.
  for old in polkit.toml theming.toml; do
    if [[ -f $noctalia_dir/$old ]] && grep -q 'install-niri-noctalia\|install-umbrinoc\|polkit_agent' "$noctalia_dir/$old"; then
      mv "$noctalia_dir/$old" "$noctalia_dir/$old.bak.$(date +%Y%m%d-%H%M%S)"
    fi
  done

  # Screenshots: Noctalia takes them under Umbriel. Save them to
  # ~/Pictures/Screenshots (written here with the full path, so it doesn't
  # depend on ~ expansion). Skipped if you've set a screenshot folder yourself.
  mkdir -p "$HOME/Pictures/Screenshots"
  shots_cfg="$noctalia_dir/screenshots.toml"
  if ! grep -qsE '^\s*\[shell\.screenshot\]' "$noctalia_dir"/*.toml; then
    info "Saving Noctalia screenshots to ~/Pictures/Screenshots ($shots_cfg)"
    printf '# Created by install-umbrinoc.sh\n[shell.screenshot]\ndirectory = "%s"\n' \
      "$HOME/Pictures/Screenshots" > "$shots_cfg"
  fi

  # btop: Noctalia's btop colour template only switches the theme if btop.conf
  # exists, and btop only creates it on first launch — so start one.
  if [[ ! -f $cfg_home/btop/btop.conf ]]; then
    info "Creating ~/.config/btop/btop.conf with Noctalia's colours"
    mkdir -p "$cfg_home/btop"
    printf '# Created by install-umbrinoc.sh; btop adds its other settings on first run.\ncolor_theme = "noctalia"\n' \
      > "$cfg_home/btop/btop.conf"
  fi

  if command -v umbriel >/dev/null && ! umbriel config validate -c "$umbriel_dir/config.toml"; then
    warn "Umbriel reports a config error in $umbriel_dir — see the log. Your previous config is in $umbriel_dir.bak.*"
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
STEP_FN=(step_update step_packages step_aur step_amd step_desktop step_zsh step_fonts step_files
         step_helium step_apps step_gaming_vms step_keyring step_noctalia step_theming step_config
         step_greeter)
STEP_TITLE=(
  "Updating Arch"
  "Packages from the Arch repos"
  "AUR helper (paru)"
  "AMD GPU drivers + LACT"
  "Umbriel and desktop tools"
  "zsh, Starship and fastfetch"
  "Fonts"
  "Luciole, phones and network shares"
  "Helium browser"
  "Apps (Steam, Discord, Spotify, Zed, ...)"
  "MangoHud, GOverlay, Faugus, VM Curator"
  "GNOME Keyring"
  "Noctalia shell"
  "GTK and Qt theming"
  "Config files (Umbriel, Noctalia)"
  "Login screen (Noctalia greeter)"
)
N=${#STEP_FN[@]}
declare -a STATE   # pending | running | done | skipped | failed

# ═════════════════════════════════════════════════════════════════════════════
#  Progress screen
# ═════════════════════════════════════════════════════════════════════════════

BANNER=(
"██╗   ██╗███╗   ███╗██████╗ ██████╗ ██╗███╗   ██╗ ██████╗  ██████╗"
"██║   ██║████╗ ████║██╔══██╗██╔══██╗██║████╗  ██║██╔═══██╗██╔════╝"
"██║   ██║██╔████╔██║██████╔╝██████╔╝██║██╔██╗ ██║██║   ██║██║     "
"██║   ██║██║╚██╔╝██║██╔══██╗██╔══██╗██║██║╚██╗██║██║   ██║██║     "
"╚██████╔╝██║ ╚═╝ ██║██████╔╝██║  ██║██║██║ ╚████║╚██████╔╝╚██████╗"
" ╚═════╝ ╚═╝     ╚═╝╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝  ╚═════╝"
)
SUBTITLE_PLAIN="umbriel · noctalia · arch linux $SYM_DASH desktop installer"
START=$(date +%s)
UI_ACTIVE=0
STEP_PID=""
SUDO_KEEPALIVE=""
SUDO_DIR=""
BUILD_CONF_DIR=""

term_cols()  { tput cols 2>/dev/null || echo 80; }
term_lines() { tput lines 2>/dev/null || echo 40; }

center() {  # center <text-without-colour-codes> <coloured-text>
  local pad=$(( ($(term_cols) - ${#1}) / 2 ))
  if (( pad < 0 )); then pad=0; fi
  printf '%*s%s' "$pad" '' "$2"
}

banner() {
  local i
  if (( $(term_cols) >= 70 )); then
    for i in "${!BANNER[@]}"; do
      if [[ -n $RST ]]; then
        center "${BANNER[i]}" "${GRAD[i]}${BANNER[i]}${RST}"
      else
        center "${BANNER[i]}" "${BANNER[i]}"
      fi
      printf '%s\n' "$EL"
    done
  else
    center "UMBRINOC" "${BOLD}${ACC}UMBRINOC${RST}"; printf '%s\n' "$EL"
  fi
  center "$SUBTITLE_PLAIN" "${MUT}umbriel · noctalia · arch linux ${ACC}${SYM_DASH}${MUT} desktop installer${RST}"
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
    center "UMBRINOC $SYM_DASH desktop installer" "${BOLD}${ACC}UMBRINOC${RST}${MUT} $SYM_DASH desktop installer${RST}"; printf '\e[K\n'
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

# Log text for the screen: no colour codes, and on the Linux console only plain
# ASCII (its font can't draw characters like — or ✔ that appear in the log).
screen_safe() {
  sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | if [[ ${TERM:-} == linux ]]; then
    sed 's/—/-/g; s/–/-/g' | LC_ALL=C tr -cd '\11\12\15\40-\176'
  else cat; fi
}

# Latest non-empty log line, without carriage-return progress.
last_log_line() {
  tail -n 20 "$LOG" 2>/dev/null | screen_safe | awk -F'\r' '{print $NF}' \
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
      done)    icon="${GRN}${SYM_OK}"; col=$MUT ;;
      running) icon="${ACC}${SPIN[frame % ${#SPIN[@]}]}"; col="$BOLD$TXT" ;;
      failed)  icon="${RED}${SYM_FAIL}"; col="$BOLD$RED" ;;
      skipped) icon="${BAR_OFF}${SYM_SKIP}"; col=$BAR_OFF; title="$title (skipped)" ;;
      *)       icon="${BAR_OFF}${SYM_TODO}"; col=$BAR_OFF ;;
    esac
    printf '%*s%s%s  %s%s%s\e[K\n' "$left" '' "$icon" "$RST" "$col" "$title" "$RST"
  done
  last=$(last_log_line | cut -c1-$(( cols - left - 4 )))
  printf '\e[K\n%*s%s%s %s%s\e[K\n\e[K\n' "$left" '' "$DIM$MUT" "$SYM_ARROW" "$last" "$RST"
  center "Full log: ~/${LOG##*/}   ·   Ctrl+C to cancel" "${DIM}${MUT}Full log: ~/${LOG##*/}   ·   Ctrl+C to cancel${RST}"
  printf '\e[K\e[J'
}

ui_start() { printf '\e[?1049h\e[?25l\e[2J'; UI_ACTIVE=1; }   # alternate screen, hide cursor
ui_stop()  { if [[ $UI_ACTIVE -eq 1 ]]; then printf '\e[?25h\e[?1049l'; UI_ACTIVE=0; fi; }

cleanup() {
  ui_stop
  if [[ -n $STEP_PID ]]; then kill "$STEP_PID" 2>/dev/null; fi
  if [[ -n $SUDO_KEEPALIVE ]]; then kill "$SUDO_KEEPALIVE" 2>/dev/null; fi
  if [[ -n $SUDO_DIR ]]; then rm -rf "$SUDO_DIR"; fi   # deletes the saved password
  if [[ -n $BUILD_CONF_DIR ]]; then rm -rf "$BUILD_CONF_DIR"; fi
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
    center "$SYM_FAIL Step $((i + 1))/$N failed: ${STEP_TITLE[i]}" \
      "${BOLD}${RED}${SYM_FAIL} Step $((i + 1))/$N failed: ${RST}${BOLD}${STEP_TITLE[i]}${RST}"
    printf '\n\n      %sLast lines of the log:%s\n' "$MUT" "$RST"
    tail -n 12 "$LOG" | screen_safe | cut -c1-$(( cols - 12 )) \
      | sed "s/^/      ${MUT}│${RST} /"
    printf '\n      %sFull log: %s%s\n' "$DIM$MUT" "$LOG" "$RST"
  else
    printf '\n%s%s Step %d/%d failed: %s%s  (log: %s)\n' "$BOLD$RED" "$SYM_FAIL" "$((i + 1))" "$N" "${STEP_TITLE[i]}" "$RST" "$LOG"
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
printf '   %s%s%s Umbriel, %s%s\n' "$ACC" "$SYM_DOT" "$RST" "$SHELL_PKG" "$([[ $WITH_GREETER -eq 1 ]] && echo ", $GREETER_PKG (login screen)")"
if [[ $AMD_GPU == yes ]]; then
  printf '   %s%s%s AMD GPU drivers and LACT\n' "$ACC" "$SYM_DOT" "$RST"
else
  printf '   %s%s No AMD GPU found, so the AMD driver step will be skipped (use --amd-gpu to force it).%s\n' "$MUT" "$SYM_DOT" "$RST"
fi
printf '   %s%s%s kitty, zsh + Starship, fonts, Luciole, GNOME Keyring, GTK/Qt theming\n' "$ACC" "$SYM_DOT" "$RST"
printf '   %s%s%s Helium, Steam, Discord, Spotify, ProtonPlus, Claude Desktop, qBittorrent, Zed\n' "$ACC" "$SYM_DOT" "$RST"
printf '   %s%s%s MangoHud, GOverlay, Faugus Launcher, VM Curator\n' "$ACC" "$SYM_DOT" "$RST"
printf '   %s%s%s your Umbriel + Noctalia config (an existing one is backed up first)\n\n' "$ACC" "$SYM_DOT" "$RST"

confirm "Continue?" || exit 0

# Every other question is asked now, so nothing interrupts the install later.
WANT_MULTILIB=1
if ! multilib_enabled; then
  confirm "Enable the [multilib] repo? (32-bit libraries, needed by Steam and Proton)" || WANT_MULTILIB=0
fi
REMOVE_AMDVLK=0
if [[ $AMD_GPU == yes ]] && pacman -Qq amdvlk &>/dev/null; then
  confirm "Remove AMDVLK? (discontinued AMD Vulkan driver that can override the better RADV)" && REMOVE_AMDVLK=1
fi
REMOVE_NIRI=0
if pacman -Qq niri &>/dev/null; then
  confirm "Remove niri? (replaced by Umbriel; your ~/.config/niri is kept)" && REMOVE_NIRI=1
fi
REMOVE_NAUTILUS=0
if pacman -Qq nautilus &>/dev/null; then
  confirm "Remove Nautilus? (replaced by Luciole)" && REMOVE_NAUTILUS=1
fi
REMOVE_SPOTIFY_LAUNCHER=0
if pacman -Qq spotify-launcher &>/dev/null; then
  confirm "Remove spotify-launcher? (replaced by the AUR 'spotify' package)" && REMOVE_SPOTIFY_LAUNCHER=1
fi

# sudo: ask for the password once here, then hand it to every later sudo call
# (including the ones inside makepkg and paru), so nothing can stop and wait
# for a password behind the progress screen.
#   - The password is kept in a file only you can read, in your runtime
#     directory (in memory, not on disk), and deleted when the installer exits.
#   - A small `sudo` wrapper first on PATH runs the real sudo with -A, which
#     makes sudo ask that file (via SUDO_ASKPASS) instead of the terminal.
REAL_SUDO=$(command -v sudo)
sudo_needs_password() {
  "$REAL_SUDO" -k 2>/dev/null          # forget any cached login, then test
  ! "$REAL_SUDO" -n true 2>/dev/null
}
if sudo_needs_password; then
  [[ -t 0 ]] || die "sudo needs your password but there's no terminal to ask in. Run the installer interactively."
  SUDO_DIR=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/umbrinoc-sudo.XXXXXX")
  chmod 700 "$SUDO_DIR"
  printf '\n%s::%s Your password is needed for sudo. It is asked once and reused for the whole install.\n' "$ACC" "$RST"
  sudo_ok=0
  for _ in 1 2 3; do
    read -rsp "   Password: " SUDO_PW < /dev/tty; echo
    if printf '%s\n' "$SUDO_PW" | "$REAL_SUDO" -S -p '' -v 2>/dev/null; then sudo_ok=1; break; fi
    printf '   %sSorry, try again.%s\n' "$RED" "$RST"
  done
  [[ $sudo_ok -eq 1 ]] || die "Wrong password three times."
  ( umask 077; printf '%s\n' "$SUDO_PW" > "$SUDO_DIR/pw" )
  unset SUDO_PW
  printf '#!/bin/sh\ncat %q\n' "$SUDO_DIR/pw" > "$SUDO_DIR/askpass"
  mkdir -m 700 "$SUDO_DIR/bin"
  printf '#!/bin/sh\nexec %q -A "$@"\n' "$REAL_SUDO" > "$SUDO_DIR/bin/sudo"
  chmod 700 "$SUDO_DIR/askpass" "$SUDO_DIR/bin/sudo"
  export SUDO_ASKPASS="$SUDO_DIR/askpass"
  export PATH="$SUDO_DIR/bin:$PATH"
fi
# Keep sudo's login fresh too, so most calls don't even need the password file.
( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &
SUDO_KEEPALIVE=$!

# Faster AUR builds for this install only. Arch's makepkg.conf is tuned for its
# official packages: link-time optimisation (slow to link big C++ programs such
# as Umbriel), debug builds plus an extra -debug package, and each package's
# test suite. Here AUR packages are built without those, and the built package
# isn't compressed because it's installed straight away. Your makepkg.conf is
# not changed: this temporary config loads it (plus /etc/makepkg.conf.d/ and
# your own ~/.config/pacman/makepkg.conf) and adds the overrides last, which is
# where makepkg looks first. It's deleted when the installer exits.
BUILD_CONF_DIR=$(mktemp -d)
cat > "$BUILD_CONF_DIR/makepkg.conf" <<'EOF'
source /etc/makepkg.conf
for _conf in /etc/makepkg.conf.d/*.conf; do [[ -r $_conf ]] && source "$_conf"; done
for _conf in "${XDG_CONFIG_HOME:-$HOME/.config}/pacman/makepkg.conf" "$HOME/.makepkg.conf"; do
  if [[ -r $_conf ]]; then source "$_conf"; break; fi
done
unset _conf
OPTIONS+=('!debug' '!lto')
BUILDENV+=('!check')
PKGEXT='.pkg.tar'
EOF
export MAKEPKG_CONF="$BUILD_CONF_DIR/makepkg.conf"
export PKGEXT='.pkg.tar'

# Start a fresh log (keeping the previous one as .old).
if [[ -f $LOG ]]; then mv -f "$LOG" "$LOG.old"; fi
{
  echo "UMBRINOC installer — $(date)"
  echo "repo: $REPO_DIR ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo 'no git'))"
  echo "options: $*"
  echo "AMD GPU: $AMD_GPU   multilib: $WANT_MULTILIB   greeter: $WITH_GREETER   blur: $WITH_BLUR"
  echo "graphics devices (PCI):"; list_gpus
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
center "$SYM_OK All done in $((ELAPSED / 60))m $((ELAPSED % 60))s" "${BOLD}${GRN}${SYM_OK} All done in $((ELAPSED / 60))m $((ELAPSED % 60))s${RST}"
printf '\n\n'

if [[ -s $WARN_FILE ]]; then
  printf '  %sWorth a look:%s\n' "$BOLD$YLW" "$RST"
  sort -u "$WARN_FILE" | screen_safe | sed "s/^/   ${YLW}!${RST} /"
  echo
fi

printf '  %sNext:%s\n' "$BOLD" "$RST"
if [[ $WITH_GREETER -eq 1 ]]; then
  printf '   %s%s%s Reboot, then pick %sUmbriel%s at the Noctalia login screen.\n' "$ACC" "$SYM_DOT" "$RST" "$ACC" "$RST"
else
  printf '   %s%s%s Log out and start Umbriel from a TTY with: %sstart-umbriel%s\n' "$ACC" "$SYM_DOT" "$RST" "$ACC" "$RST"
fi
printf '   %s%s%s Press %sMod+Shift+/%s in Umbriel to see all keybinds.\n' "$ACC" "$SYM_DOT" "$RST" "$BOLD" "$RST"
printf '   %s%s%s Full log: %s\n\n' "$ACC" "$SYM_DOT" "$RST" "$LOG"

if [[ $ASSUME_YES -eq 0 && $WITH_GREETER -eq 1 ]]; then
  if confirm "Reboot now?"; then sudo systemctl reboot; fi
fi
