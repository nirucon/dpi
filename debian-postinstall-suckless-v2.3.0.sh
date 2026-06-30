#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# NIRUCON Debian 13 dwm Postinstall v2.3.0
# =============================================================================
#
# Target:
#   Debian 13 / Trixie
#
# Purpose:
#   Install a clean, minimal, dwm-based X11 desktop on Debian with SDDM,
#   NIRUCON suckless tools, look and feel files, fish shell, optional laptop
#   packages and complete selectable audio profiles for Reaper/studio/Windows-VST use,
#   plus an integrated NIRU Noir Fish/Kitty/Starship terminal profile and robust studio profile handling.
#
# Design goals:
#   - Keep the system clean and stable.
#   - Use dwm/X11, not Plasma.
#   - Keep SDDM as the display manager.
#   - Avoid KDE/Plasma applications and desktop meta packages.
#   - Use --no-install-recommends where appropriate to avoid large dependency pulls.
#   - Install the NIRU Noir SDDM theme correctly as theme id "niru-noir".
#   - Be clear and verbose during installation.
#
# Run:
#   chmod +x nirucon-debian-dwm-postinstall.sh
#   ./nirucon-debian-dwm-postinstall.sh
#
# Important:
#   Run as your normal user, not as root.
#
# =============================================================================

# -----------------------------------------------------------------------------
# Repositories
# -----------------------------------------------------------------------------

SUCKLESS_REPO="https://github.com/nirucon/suckless.git"
LOOKANDFEEL_REPO="https://github.com/nirucon/suckless_lookandfeel.git"
SDDM_THEME_REPO="https://github.com/nirucon/nirucon-sddm.git"

# The SDDM theme metadata uses:
#   Theme-Id=niru-noir
# Therefore the installed directory and SDDM Current value should be niru-noir.
SDDM_THEME_ID="niru-noir"

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------

SUCKLESS_DIR="$HOME/.config/suckless"
LOOKANDFEEL_DIR="$HOME/.cache/nirucon-dwm-setup/lookandfeel"
SDDM_THEME_CACHE="$HOME/.cache/nirucon-dwm-setup/sddm-theme"

LOCAL_BIN="$HOME/.local/bin"
LOCAL_SHARE="$HOME/.local/share"
XINITRC_DIR="$HOME/.config/xinitrc.d"

SESSION_WRAPPER="/usr/local/bin/dwm-session"
SESSION_DESKTOP="/usr/share/xsessions/dwm.desktop"

APT_FLAGS=(-y --no-install-recommends)

# -----------------------------------------------------------------------------
# Colors and output helpers
# -----------------------------------------------------------------------------

NC="\033[0m"
BOLD="\033[1m"
GRN="\033[1;32m"
RED="\033[1;31m"
YLW="\033[1;33m"
BLU="\033[1;34m"
MAG="\033[1;35m"
CYN="\033[1;36m"

say()   { printf "${BLU}[info]${NC} %s\n" "$*"; }
phase() { printf "\n${MAG}==>${NC} ${BOLD}%s${NC}\n" "$*"; }
ok()    { printf "${GRN}[ ok ]${NC} %s\n" "$*"; }
warn()  { printf "${YLW}[warn]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[fail]${NC} %s\n" "$*" >&2; }
note()  { printf "${CYN}[note]${NC} %s\n" "$*"; }

trap 'fail "Aborted at line $LINENO while running: ${BASH_COMMAND:-unknown}"' ERR

# -----------------------------------------------------------------------------
# Basic checks
# -----------------------------------------------------------------------------

[[ "$EUID" -ne 0 ]] || {
  fail "Run this script as your normal user, not as root."
  exit 1
}

command -v sudo >/dev/null 2>&1 || {
  fail "sudo is missing."
  echo
  echo "Fix as root first:"
  echo "  apt install sudo"
  echo "  /usr/sbin/usermod -aG sudo $USER"
  echo "  reboot"
  exit 1
}

if ! grep -qi "trixie\|13" /etc/debian_version 2>/dev/null; then
  warn "This does not look like Debian 13/Trixie. Continuing anyway."
fi

# -----------------------------------------------------------------------------
# Interactive helpers
# -----------------------------------------------------------------------------

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  if [[ "$default" == "Y" ]]; then
    read -r -p "$prompt [Y/n] " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
  else
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
  fi
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    sudo cp -a "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

backup_user_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp -a "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

ensure_debian_components() {
  # Steam and some firmware packages require contrib/non-free/non-free-firmware.
  # Support both modern deb822 .sources files and classic sources.list lines.
  local components="main contrib non-free non-free-firmware"
  local f

  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    sudo cp -a "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"

    if [[ "$f" == *.sources ]]; then
      sudo awk -v comps="$components" '
        BEGIN { n=split(comps, wanted, " ") }
        /^Components:/ {
          line=$0
          for (i=1;i<=n;i++) {
            if (line !~ "(^| )" wanted[i] "( |$)") line=line " " wanted[i]
          }
          print line
          next
        }
        { print }
      ' "$f" | sudo tee "$f.tmp" >/dev/null
      sudo mv "$f.tmp" "$f"
    else
      sudo awk -v comps="$components" '
        BEGIN { n=split(comps, wanted, " ") }
        /^deb / && $0 !~ /^#/ {
          line=$0
          for (i=1;i<=n;i++) {
            if (line !~ "(^| )" wanted[i] "( |$)") line=line " " wanted[i]
          }
          print line
          next
        }
        { print }
      ' "$f" | sudo tee "$f.tmp" >/dev/null
      sudo mv "$f.tmp" "$f"
    fi
  done
}

apt_has_candidate() {
  local pkg="$1"
  apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vqE '^\(none\)$|^$'
}

apt_install_available() {
  local pkg available=() missing=()
  for pkg in "$@"; do
    if apt_has_candidate "$pkg"; then
      available+=("$pkg")
    else
      missing+=("$pkg")
    fi
  done

  if [[ "${#available[@]}" -gt 0 ]]; then
    sudo DEBIAN_FRONTEND=noninteractive apt install "${APT_FLAGS[@]}" "${available[@]}"
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    warn "Skipped unavailable APT packages: ${missing[*]}"
  fi
}

print_header() {
  clear || true
  echo
  echo "============================================================"
  echo "  NIRUCON Debian 13 dwm Postinstall v2.3.0"
  echo "============================================================"
  echo
  echo "This script installs:"
  echo "  - dwm, dmenu, st and slock from your suckless repo"
  echo "  - SDDM with the NIRU Noir theme"
  echo "  - fish shell"
  echo "  - PipeWire audio base"
  echo "  - Minimal X11/dwm desktop tools"
  echo
  echo "It avoids Plasma/KDE desktop packages."
  echo
}

# -----------------------------------------------------------------------------
# User choices
# -----------------------------------------------------------------------------

print_header

echo "Select machine type:"
echo "  1) Laptop"
echo "  2) Workstation"
echo
read -r -p "Choice [1/2]: " MACHINE_CHOICE

IS_LAPTOP=0
IS_WORKSTATION=0

case "$MACHINE_CHOICE" in
  1) IS_LAPTOP=1 ;;
  2) IS_WORKSTATION=1 ;;
  *)
    fail "Invalid machine choice."
    exit 1
    ;;
esac

AUDIO_PROFILE="base"
INSTALL_AUDIO_TOOLS=0
APPLY_AUDIO_TUNING=0
INSTALL_WINE_AUDIO=0
INSTALL_YABRIDGE=0
INSTALL_TOONTRACK_TWEAKS=0
INSTALL_NAM_HELPER=0
INSTALL_GAMING=0
INSTALL_GAMESCOPE=0
INSTALL_MULTIMONITOR_HELPERS=1
INSTALL_TAILSCALE=0
INSTALL_SSH=0
INSTALL_CUPS=0
INSTALL_SIGNAL=0
INSTALL_HELIUM=0
SET_FISH_DEFAULT=0
PATCH_STATUSBAR=1
PURGE_PLASMA=0

echo
echo "Select audio profile:"
echo "  1) Base desktop audio only"
echo "     PipeWire base from the normal install. Good for non-studio laptops."
echo "  2) Reaper safe studio"
echo "     Install studio tools and helper scripts, but preserve existing audio tuning."
echo "  3) Reaper full studio"
echo "     Install studio tools and apply realtime/system tuning. Best for new studio installs."
echo "  4) Reaper full studio + Windows VST"
echo "     Full studio profile plus Wine, Winetricks, yabridge and optional Toontrack tweaks."
echo
read -r -p "Audio choice [1/2/3/4, default 2]: " AUDIO_CHOICE
AUDIO_CHOICE="${AUDIO_CHOICE:-2}"

case "$AUDIO_CHOICE" in
  1)
    AUDIO_PROFILE="base"
    INSTALL_AUDIO_TOOLS=0
    APPLY_AUDIO_TUNING=0
    ;;
  2)
    AUDIO_PROFILE="reaper-safe"
    INSTALL_AUDIO_TOOLS=1
    APPLY_AUDIO_TUNING=0
    ;;
  3)
    AUDIO_PROFILE="reaper-full"
    INSTALL_AUDIO_TOOLS=1
    APPLY_AUDIO_TUNING=1
    ;;
  4)
    AUDIO_PROFILE="reaper-full-windows-vst"
    INSTALL_AUDIO_TOOLS=1
    APPLY_AUDIO_TUNING=1
    INSTALL_WINE_AUDIO=1
    INSTALL_YABRIDGE=1
    ;;
  *)
    fail "Invalid audio choice."
    exit 1
    ;;
esac

if [[ "$INSTALL_AUDIO_TOOLS" -eq 1 && "$INSTALL_WINE_AUDIO" -eq 0 ]]; then
  ask_yes_no "Install Wine/Winetricks support for Windows VST experiments?" "N" && INSTALL_WINE_AUDIO=1 || INSTALL_WINE_AUDIO=0
fi

if [[ "$INSTALL_WINE_AUDIO" -eq 1 && "$INSTALL_YABRIDGE" -eq 0 ]]; then
  ask_yes_no "Install yabridge from latest GitHub release?" "Y" && INSTALL_YABRIDGE=1 || INSTALL_YABRIDGE=0
fi

if [[ "$INSTALL_YABRIDGE" -eq 1 ]]; then
  ask_yes_no "Apply optional Toontrack compatibility tweaks through winetricks?" "N" && INSTALL_TOONTRACK_TWEAKS=1 || INSTALL_TOONTRACK_TWEAKS=0
fi

if [[ "$INSTALL_AUDIO_TOOLS" -eq 1 ]]; then
  ask_yes_no "Create NAM/Neural Amp Modeler helper notes?" "Y" && INSTALL_NAM_HELPER=1 || INSTALL_NAM_HELPER=0
fi

ask_yes_no "Install gaming profile: Steam, RetroArch, GameMode, MangoHud and AMD/Vulkan support?" "Y" && INSTALL_GAMING=1 || INSTALL_GAMING=0
if [[ "$INSTALL_GAMING" -eq 1 ]]; then
  ask_yes_no "Try installing Gamescope if available?" "N" && INSTALL_GAMESCOPE=1 || INSTALL_GAMESCOPE=0
fi

ask_yes_no "Install multi-monitor helpers: arandr, autorandr, xrandr helper scripts?" "Y" && INSTALL_MULTIMONITOR_HELPERS=1 || INSTALL_MULTIMONITOR_HELPERS=0

ask_yes_no "Install Tailscale?" "Y" && INSTALL_TAILSCALE=1
ask_yes_no "Install OpenSSH server?" "N" && INSTALL_SSH=1 || INSTALL_SSH=0
ask_yes_no "Install CUPS printer support?" "N" && INSTALL_CUPS=1 || INSTALL_CUPS=0
ask_yes_no "Install Signal Desktop?" "Y" && INSTALL_SIGNAL=1
ask_yes_no "Install Helium Browser from latest .deb release?" "Y" && INSTALL_HELIUM=1
ask_yes_no "Set fish as default shell for $USER?" "N" && SET_FISH_DEFAULT=1
ask_yes_no "Patch dwm-status.sh for Debian?" "Y" && PATCH_STATUSBAR=1 || PATCH_STATUSBAR=0
ask_yes_no "Remove Plasma/KDE packages if present?" "N" && PURGE_PLASMA=1 || PURGE_PLASMA=0

echo
phase "Selected configuration"

if [[ "$IS_LAPTOP" -eq 1 ]]; then
  echo "Machine type:      Laptop"
else
  echo "Machine type:      Workstation"
fi

echo "Audio profile:       $AUDIO_PROFILE"
echo "Wine audio support:  $([[ "$INSTALL_WINE_AUDIO" -eq 1 ]] && echo yes || echo no)"
echo "yabridge:            $([[ "$INSTALL_YABRIDGE" -eq 1 ]] && echo yes || echo no)"
echo "Toontrack tweaks:    $([[ "$INSTALL_TOONTRACK_TWEAKS" -eq 1 ]] && echo yes || echo no)"
echo "NAM helper:          $([[ "$INSTALL_NAM_HELPER" -eq 1 ]] && echo yes || echo no)"
echo "Gaming profile:      $([[ "$INSTALL_GAMING" -eq 1 ]] && echo yes || echo no)"
echo "Gamescope attempt:   $([[ "$INSTALL_GAMESCOPE" -eq 1 ]] && echo yes || echo no)"
echo "Multi-monitor tools: $([[ "$INSTALL_MULTIMONITOR_HELPERS" -eq 1 ]] && echo yes || echo no)"
echo "Tailscale:          $([[ "$INSTALL_TAILSCALE" -eq 1 ]] && echo yes || echo no)"
echo "OpenSSH server:     $([[ "$INSTALL_SSH" -eq 1 ]] && echo yes || echo no)"
echo "CUPS printer:       $([[ "$INSTALL_CUPS" -eq 1 ]] && echo yes || echo no)"
echo "Signal:             $([[ "$INSTALL_SIGNAL" -eq 1 ]] && echo yes || echo no)"
echo "Helium:             $([[ "$INSTALL_HELIUM" -eq 1 ]] && echo yes || echo no)"
echo "fish default shell: $([[ "$SET_FISH_DEFAULT" -eq 1 ]] && echo yes || echo no)"
echo "Patch statusbar:    $([[ "$PATCH_STATUSBAR" -eq 1 ]] && echo yes || echo no)"
echo "Purge Plasma/KDE:   $([[ "$PURGE_PLASMA" -eq 1 ]] && echo yes || echo no)"
echo

ask_yes_no "Continue with installation?" "Y" || {
  warn "Installation cancelled."
  exit 0
}

# -----------------------------------------------------------------------------
# APT base setup
# -----------------------------------------------------------------------------

phase "Updating Debian"

say "Ensuring Debian repository components: main contrib non-free non-free-firmware..."
ensure_debian_components

say "Running apt update..."
sudo apt update

say "Running full upgrade..."
sudo apt full-upgrade -y

# -----------------------------------------------------------------------------
# Clean dwm/X11 base packages
# -----------------------------------------------------------------------------

phase "Installing clean dwm/X11 base packages"

note "Using --no-install-recommends to avoid unnecessary desktop packages."

sudo apt install "${APT_FLAGS[@]}" \
  build-essential gcc make pkg-config git curl wget rsync unzip zip tar tree \
  findutils coreutils grep sed gawk diffutils file xdg-utils xdg-user-dirs dbus-x11 \
  ca-certificates gnupg lsb-release apt-transport-https \
  xorg xinit x11-xserver-utils x11-utils x11-xkb-utils xclip xsel \
  sddm \
  network-manager network-manager-gnome rfkill iw \
  libx11-dev libxft-dev libxinerama-dev libxrandr-dev libxext-dev \
  libxrender-dev libxfixes-dev libharfbuzz-dev libimlib2-dev \
  fontconfig fonts-dejavu fonts-noto fonts-noto-color-emoji fonts-font-awesome \
  fonts-jetbrains-mono \
  feh picom rofi dunst libnotify-bin \
  kitty alacritty fish starship zoxide maim slop flameshot scrot brightnessctl playerctl pamixer pavucontrol \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  alsa-utils alsa-ucm-conf rtkit \
  pcmanfm gvfs gvfs-backends udisks2 udiskie blueman xss-lock pkexec polkitd lxpolkit \
  fastfetch btop htop glances ncdu duf jq fzf ripgrep fd-find eza bat pv sshfs ntfs-3g \
  lm-sensors smartmontools pciutils usbutils \
  neovim vim micro \
  mpv vlc cmus kew ffmpeg ffmpegthumbnailer gimp imagemagick sxiv \
  arandr autorandr lxappearance papirus-icon-theme adwaita-icon-theme unrar-free p7zip-full \
  nextcloud-desktop \
  upower acpi

ok "Base dwm/X11 package set installed."

# -----------------------------------------------------------------------------
# Laptop packages
# -----------------------------------------------------------------------------

if [[ "$IS_LAPTOP" -eq 1 ]]; then
  phase "Installing laptop power management packages"

  sudo apt install "${APT_FLAGS[@]}" power-profiles-daemon acpid

  sudo systemctl enable acpid
  sudo systemctl enable power-profiles-daemon

  ok "Laptop power packages installed and enabled."
fi

# -----------------------------------------------------------------------------
# Machine profile tuning
# -----------------------------------------------------------------------------

phase "Applying machine profile tuning"

if [[ "$IS_LAPTOP" -eq 1 ]]; then
  say "Applying conservative laptop defaults: balanced power, lower swap pressure and lid handling."

  sudo tee /etc/sysctl.d/90-nirucon-laptop.conf >/dev/null <<'EOF'
# NIRUCON laptop profile.
vm.swappiness=20
fs.inotify.max_user_watches=524288
EOF

  sudo mkdir -p /etc/systemd/logind.conf.d
  sudo tee /etc/systemd/logind.conf.d/90-nirucon-laptop.conf >/dev/null <<'EOF'
[Login]
HandlePowerKey=poweroff
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

  if command -v powerprofilesctl >/dev/null 2>&1; then
    powerprofilesctl set balanced 2>/dev/null || true
  fi

  ok "Laptop tuning applied."
else
  say "Applying workstation defaults: performance-friendly profile without aggressive laptop power saving."

  sudo tee /etc/sysctl.d/90-nirucon-workstation.conf >/dev/null <<'EOF'
# NIRUCON workstation profile.
vm.swappiness=10
fs.inotify.max_user_watches=1048576
EOF

  sudo mkdir -p /etc/systemd/logind.conf.d
  sudo tee /etc/systemd/logind.conf.d/90-nirucon-workstation.conf >/dev/null <<'EOF'
[Login]
HandlePowerKey=poweroff
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

  ok "Workstation tuning applied."
fi

sudo sysctl --system >/dev/null || true

# -----------------------------------------------------------------------------
# Audio workstation packages and tuning
# -----------------------------------------------------------------------------

if [[ "$INSTALL_AUDIO_TOOLS" -eq 1 ]]; then
  phase "Installing Reaper/studio audio packages"

  note "This installs native Linux audio tools. Reaper itself is still installed manually from reaper.fm."

  AUDIO_BACKUP_DIR="$HOME/.cache/nirucon-dwm-setup/audio-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$AUDIO_BACKUP_DIR/user-config" "$AUDIO_BACKUP_DIR/etc"

  say "Saving lightweight audio/Reaper configuration backup to: $AUDIO_BACKUP_DIR"
  for d in "$HOME/.config/REAPER" "$HOME/.config/pipewire" "$HOME/.config/wireplumber" "$HOME/.config/yabridge"; do
    if [[ -e "$d" ]]; then
      rsync -a "$d" "$AUDIO_BACKUP_DIR/user-config/" 2>/dev/null || true
    fi
  done
  sudo find /etc/security/limits.d /etc/sysctl.d -maxdepth 1 -type f \
    \( -iname '*audio*' -o -iname '*pipewire*' -o -iname '*jack*' -o -iname '*nirucon*' \) \
    -exec cp -a {} "$AUDIO_BACKUP_DIR/etc/" \; 2>/dev/null || true

  # Avoid jackd2 debconf prompts during unattended postinstall.
  echo "jackd2 jackd/tweak_rt_limits boolean true" | sudo debconf-set-selections 2>/dev/null || true

  sudo DEBIAN_FRONTEND=noninteractive apt install "${APT_FLAGS[@]}" \
    qpwgraph \
    jackd2 qjackctl \
    libasound2-plugins \
    calf-plugins \
    lsp-plugins \
    zam-plugins \
    x42-plugins \
    guitarix \
    audacity \
    soundconverter \
    mediainfo \
    sox \
    linux-cpupower \
    irqbalance

  sudo systemctl enable irqbalance

  say "Adding $USER to audio and video groups..."
  sudo usermod -aG audio,video "$USER" || true

  if [[ "$INSTALL_WINE_AUDIO" -eq 1 ]]; then
    phase "Installing Wine support for Windows VST"

    sudo dpkg --add-architecture i386 || true
    sudo apt update

    # Some Debian installations do not expose winetricks through the active APT
    # sources. Wine itself should not fail just because winetricks is unavailable.
    # Try the full Wine/Vulkan set first, then fall back to a smaller safe set.
    if ! sudo DEBIAN_FRONTEND=noninteractive apt install "${APT_FLAGS[@]}" \
      wine wine64 wine32 cabextract p7zip-full unzip \
      vulkan-tools mesa-vulkan-drivers mesa-vulkan-drivers:i386; then
      warn "Full Wine/Vulkan package set failed. Retrying with a smaller safe Wine set."
      sudo DEBIAN_FRONTEND=noninteractive apt install "${APT_FLAGS[@]}" \
        wine wine64 cabextract p7zip-full unzip || \
        warn "Wine installation failed. Windows VST support may be incomplete."
    fi

    phase "Installing Winetricks if available"

    mkdir -p "$LOCAL_BIN"

    if command -v winetricks >/dev/null 2>&1; then
      ok "winetricks already installed: $(command -v winetricks)"
    elif apt-cache policy winetricks 2>/dev/null | grep -q 'Candidate: [^()]'; then
      sudo DEBIAN_FRONTEND=noninteractive apt install "${APT_FLAGS[@]}" winetricks || \
        warn "APT winetricks installation failed. Continuing without winetricks."
    else
      warn "winetricks has no APT candidate in the active Debian repositories. Trying upstream script fallback."
      if curl -fsSL -o "$LOCAL_BIN/winetricks" "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"; then
        chmod +x "$LOCAL_BIN/winetricks"
        export PATH="$LOCAL_BIN:$PATH"
        ok "winetricks installed to $LOCAL_BIN/winetricks"
      else
        warn "Could not download winetricks. Continuing without Toontrack tweaks."
      fi
    fi

    mkdir -p \
      "$HOME/.wine" \
      "$HOME/.vst" \
      "$HOME/.vst3" \
      "$HOME/.clap" \
      "$HOME/.local/share/yabridge" \
      "$HOME/.wine/drive_c/Program Files/VstPlugins" \
      "$HOME/.wine/drive_c/Program Files/Common Files/VST3"

    if [[ "$INSTALL_YABRIDGE" -eq 1 ]]; then
      phase "Installing yabridge from latest GitHub release"

      YABRIDGE_TMP="$(mktemp -d)"
      YABRIDGE_URL="$(curl -fsSL https://api.github.com/repos/robbert-vdh/yabridge/releases/latest \
        | grep browser_download_url \
        | grep -E 'yabridge-[0-9].*\.tar\.gz' \
        | grep -v 'source' \
        | head -n1 \
        | cut -d '"' -f4 || true)"

      if [[ -n "${YABRIDGE_URL:-}" ]]; then
        say "Downloading yabridge from: $YABRIDGE_URL"
        wget -O "$YABRIDGE_TMP/yabridge.tar.gz" "$YABRIDGE_URL"
        tar -xzf "$YABRIDGE_TMP/yabridge.tar.gz" -C "$YABRIDGE_TMP"
        YABRIDGE_EXTRACTED="$(find "$YABRIDGE_TMP" -maxdepth 3 -type f -name yabridgectl -printf '%h\n' | head -n1 || true)"
        if [[ -n "${YABRIDGE_EXTRACTED:-}" ]]; then
          rsync -a "$YABRIDGE_EXTRACTED/" "$HOME/.local/share/yabridge/"
          chmod +x "$HOME/.local/share/yabridge/yabridge" "$HOME/.local/share/yabridge/yabridgectl" 2>/dev/null || true
          grep -qxF 'export PATH="$HOME/.local/share/yabridge:$PATH"' "$HOME/.profile" || \
            echo 'export PATH="$HOME/.local/share/yabridge:$PATH"' >> "$HOME/.profile"
          export PATH="$HOME/.local/share/yabridge:$PATH"
          ok "yabridge installed to $HOME/.local/share/yabridge"
        else
          warn "Downloaded yabridge archive, but could not find yabridgectl inside it."
        fi
      else
        warn "Could not resolve latest yabridge release URL."
      fi
      rm -rf "$YABRIDGE_TMP"
    fi

    if command -v yabridgectl >/dev/null 2>&1 || [[ -x "$HOME/.local/share/yabridge/yabridgectl" ]]; then
      YCTL="$(command -v yabridgectl || echo "$HOME/.local/share/yabridge/yabridgectl")"
      "$YCTL" add "$HOME/.vst" 2>/dev/null || true
      "$YCTL" add "$HOME/.vst3" 2>/dev/null || true
      "$YCTL" add "$HOME/.clap" 2>/dev/null || true
      "$YCTL" add "$HOME/.wine/drive_c/Program Files/VstPlugins" 2>/dev/null || true
      "$YCTL" add "$HOME/.wine/drive_c/Program Files/Common Files/VST3" 2>/dev/null || true
      "$YCTL" sync 2>/dev/null || warn "yabridgectl sync failed or no Windows plugins were present yet."
      ok "yabridge paths prepared."
    fi

    if [[ "$INSTALL_TOONTRACK_TWEAKS" -eq 1 ]]; then
      phase "Applying optional Toontrack/Windows plugin compatibility tweaks"
      if command -v winetricks >/dev/null 2>&1; then
        warn "This can take a while and may open Wine/Winetricks dialogs."
        WINEPREFIX="$HOME/.wine" winetricks -q corefonts gdiplus vcrun2019 2>/dev/null || \
          warn "Some winetricks components failed. You can rerun manually: winetricks corefonts gdiplus vcrun2019"
        note "dotnet48 is intentionally not forced. Install it manually only if a specific installer requires it."
      else
        warn "Toontrack tweaks skipped because winetricks is not installed."
      fi
    fi
  fi

  phase "Creating audio helper scripts"

  mkdir -p "$LOCAL_BIN"

  cat > "$LOCAL_BIN/audio-performance.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Studio mode for recording/mixing.
# Requires linux-cpupower and sudo rights.
if command -v powerprofilesctl >/dev/null 2>&1; then
  powerprofilesctl set performance 2>/dev/null || true
fi

if command -v cpupower >/dev/null 2>&1; then
  sudo cpupower frequency-set -g performance
  echo "CPU governor set to performance."
else
  echo "cpupower missing. Install linux-cpupower."
fi
EOF

  cat > "$LOCAL_BIN/audio-balanced.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Balanced mode after audio work.
if command -v powerprofilesctl >/dev/null 2>&1; then
  powerprofilesctl set balanced 2>/dev/null || true
fi

if command -v cpupower >/dev/null 2>&1; then
  sudo cpupower frequency-set -g schedutil 2>/dev/null || sudo cpupower frequency-set -g ondemand 2>/dev/null || true
  echo "CPU governor set to balanced/schedutil when available."
else
  echo "cpupower missing."
fi
EOF

  cat > "$LOCAL_BIN/audio-status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "== User / groups =="
id

echo
echo "== PipeWire services =="
systemctl --user --no-pager status pipewire pipewire-pulse wireplumber 2>/dev/null | sed -n '1,80p' || true

echo
echo "== pactl info =="
pactl info 2>/dev/null || true

echo
echo "== Audio sinks =="
pactl list short sinks 2>/dev/null || true

echo
echo "== Audio sources =="
pactl list short sources 2>/dev/null || true

echo
echo "== ALSA playback devices =="
aplay -l 2>/dev/null || true

echo
echo "== ALSA capture devices =="
arecord -l 2>/dev/null || true

echo
echo "== CPU governor =="
if command -v cpupower >/dev/null 2>&1; then
  cpupower frequency-info -p 2>/dev/null || true
else
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true
fi
EOF

  cat > "$LOCAL_BIN/reaper-audio-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "== Reaper audio quick check =="
echo

echo "1) Reaper config:"
if [[ -d "$HOME/.config/REAPER" ]]; then
  echo "   Found: $HOME/.config/REAPER"
else
  echo "   Missing: $HOME/.config/REAPER"
fi

echo

echo "2) Native plugin folders:"
for d in "$HOME/.vst" "$HOME/.vst3" "$HOME/.clap" "$HOME/.lv2" "/usr/lib/vst" "/usr/lib/vst3" "/usr/lib/lv2"; do
  [[ -d "$d" ]] && echo "   Found: $d"
done

echo

echo "3) Wine/yabridge hints:"
command -v wine >/dev/null 2>&1 && echo "   wine: $(command -v wine)" || echo "   wine: missing"
if command -v yabridgectl >/dev/null 2>&1; then
  echo "   yabridgectl: $(command -v yabridgectl)"
elif [[ -x "$HOME/.local/share/yabridge/yabridgectl" ]]; then
  echo "   yabridgectl: $HOME/.local/share/yabridge/yabridgectl"
else
  echo "   yabridgectl: missing"
fi
if [[ -d "$HOME/.wine/drive_c/Program Files/Toontrack" ]]; then
  echo "   Toontrack folder: found"
fi

echo

echo "4) Recommended Reaper audio backend on this setup:"
echo "   PipeWire JACK usually works best: Audio system = JACK"
echo "   Use qpwgraph to inspect routing."
EOF

  cat > "$LOCAL_BIN/yabridge-sync.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/share/yabridge:$PATH"

if ! command -v yabridgectl >/dev/null 2>&1; then
  echo "yabridgectl not found. Install yabridge first."
  exit 1
fi

mkdir -p \
  "$HOME/.vst" \
  "$HOME/.vst3" \
  "$HOME/.clap" \
  "$HOME/.wine/drive_c/Program Files/VstPlugins" \
  "$HOME/.wine/drive_c/Program Files/Common Files/VST3"

yabridgectl add "$HOME/.vst" || true
yabridgectl add "$HOME/.vst3" || true
yabridgectl add "$HOME/.clap" || true
yabridgectl add "$HOME/.wine/drive_c/Program Files/VstPlugins" || true
yabridgectl add "$HOME/.wine/drive_c/Program Files/Common Files/VST3" || true
yabridgectl sync
EOF

  if [[ "$INSTALL_NAM_HELPER" -eq 1 ]]; then
    cat > "$LOCAL_BIN/nam-notes.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'TXT'
NAM / Neural Amp Modeler notes for Debian/Reaper:

1) Prefer native Linux builds/plugins when available.
2) Put native plugins in one of these folders:
   ~/.vst3
   ~/.clap
   ~/.lv2
3) In REAPER: Options > Preferences > Plug-ins > VST > Re-scan.
4) For Windows NAM-related plugins, place them under:
   ~/.wine/drive_c/Program Files/Common Files/VST3
   then run: yabridgectl sync
TXT
EOF
    chmod +x "$LOCAL_BIN/nam-notes.sh"
  fi

  chmod +x "$LOCAL_BIN/audio-performance.sh" "$LOCAL_BIN/audio-balanced.sh" "$LOCAL_BIN/audio-status.sh" "$LOCAL_BIN/reaper-audio-check.sh" "$LOCAL_BIN/yabridge-sync.sh"

  ok "Audio helper scripts created."

  if [[ "$APPLY_AUDIO_TUNING" -eq 1 ]]; then
    phase "Applying realtime audio tuning"

    say "Writing realtime limits to /etc/security/limits.d/99-nirucon-audio.conf..."
    backup_file /etc/security/limits.d/99-nirucon-audio.conf
    sudo tee /etc/security/limits.d/99-nirucon-audio.conf >/dev/null <<'EOF'
# NIRUCON realtime audio limits for low-latency audio work.
# The user must be a member of the audio group.
@audio   -  rtprio     98
@audio   -  memlock    unlimited
@audio   -  nice      -19
EOF

    say "Writing basic audio sysctl tuning to /etc/sysctl.d/99-nirucon-audio.conf..."
    backup_file /etc/sysctl.d/99-nirucon-audio.conf
    sudo tee /etc/sysctl.d/99-nirucon-audio.conf >/dev/null <<'EOF'
# NIRUCON desktop/audio tuning.
vm.swappiness=10
fs.inotify.max_user_watches=1048576
EOF

    sudo sysctl --system >/dev/null || true

    ok "Realtime audio tuning applied."
  else
    note "Audio profile is safe mode: existing realtime/sysctl tuning was preserved."
  fi

  ok "Reaper/studio audio package phase completed."
fi


# -----------------------------------------------------------------------------
# Gaming packages and AMD/Vulkan support
# -----------------------------------------------------------------------------

if [[ "$INSTALL_GAMING" -eq 1 ]]; then
  phase "Installing gaming profile"

  AMD_GPU=0
  GPU_INFO="$(lspci -nn | grep -Ei 'VGA|3D|Display' || true)"

  if echo "$GPU_INFO" | grep -Eiq 'AMD|ATI|Radeon'; then
    AMD_GPU=1
    ok "AMD/Radeon GPU detected."
    echo "$GPU_INFO"
  else
    note "No AMD/Radeon GPU detected. GPU list:"
    echo "$GPU_INFO"
  fi

  say "Enabling i386 architecture for Steam/Proton..."
  sudo dpkg --add-architecture i386 || true
  sudo apt update

  say "Installing Steam, RetroArch, GameMode, MangoHud and Vulkan support..."
  sudo DEBIAN_FRONTEND=noninteractive apt install "${APT_FLAGS[@]}" \
    steam-installer \
    steam-devices \
    retroarch \
    retroarch-assets \
    gamemode \
    mangohud \
    goverlay \
    vulkan-tools \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386 \
    libgl1-mesa-dri \
    libgl1-mesa-dri:i386 \
    mesa-va-drivers \
    mesa-vdpau-drivers \
    libvulkan1 \
    libvulkan1:i386

  if [[ "$AMD_GPU" -eq 1 ]]; then
    say "Installing AMD-specific X11/Mesa/video acceleration packages..."
    sudo DEBIAN_FRONTEND=noninteractive apt install "${APT_FLAGS[@]}" \
      xserver-xorg-video-amdgpu \
      firmware-amd-graphics \
      vainfo \
      vdpauinfo
  fi

  if [[ "$INSTALL_GAMESCOPE" -eq 1 ]]; then
    phase "Trying to install Gamescope"

    if apt-cache policy gamescope 2>/dev/null | grep -q 'Candidate: [^()]'; then
      apt_install_available gamescope || \
        warn "Gamescope installation failed. Continuing without it."
    else
      warn "Gamescope is not available from the active APT sources. Skipping."
      warn "You can install it later from backports if you enable trixie-backports."
    fi
  fi

  phase "Creating gaming helper scripts"

  mkdir -p "$LOCAL_BIN"

  cat > "$LOCAL_BIN/gaming-performance.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if command -v powerprofilesctl >/dev/null 2>&1; then
  powerprofilesctl set performance 2>/dev/null || true
fi

if command -v cpupower >/dev/null 2>&1; then
  sudo cpupower frequency-set -g performance 2>/dev/null || true
fi

echo "Gaming performance mode requested."
EOF

  cat > "$LOCAL_BIN/gaming-balanced.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if command -v powerprofilesctl >/dev/null 2>&1; then
  powerprofilesctl set balanced 2>/dev/null || true
fi

if command -v cpupower >/dev/null 2>&1; then
  sudo cpupower frequency-set -g schedutil 2>/dev/null || sudo cpupower frequency-set -g ondemand 2>/dev/null || true
fi

echo "Balanced mode requested."
EOF

  cat > "$LOCAL_BIN/gaming-status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "== GPU =="
lspci -nn | grep -Ei 'VGA|3D|Display' || true

echo
echo "== Vulkan =="
if command -v vulkaninfo >/dev/null 2>&1; then
  vulkaninfo --summary 2>/dev/null || vulkaninfo 2>/dev/null | sed -n '1,100p' || true
else
  echo "vulkaninfo missing"
fi

echo
echo "== Steam / RetroArch / tools =="
for c in steam retroarch gamemoderun mangohud goverlay gamescope; do
  printf "%-14s %s\n" "$c:" "$(command -v "$c" || echo missing)"
done

echo
echo "== GameMode =="
if command -v gamemoded >/dev/null 2>&1; then
  gamemoded -s 2>/dev/null || true
else
  echo "gamemoded missing"
fi
EOF

  chmod +x "$LOCAL_BIN/gaming-performance.sh" "$LOCAL_BIN/gaming-balanced.sh" "$LOCAL_BIN/gaming-status.sh"

  phase "Preparing RetroArch directories"

  mkdir -p \
    "$HOME/Games/roms" \
    "$HOME/Games/bios" \
    "$HOME/.config/retroarch" \
    "$HOME/.local/share/retroarch/saves" \
    "$HOME/.local/share/retroarch/states" \
    "$HOME/Pictures/RetroArch"

  if [[ ! -f "$HOME/.config/retroarch/retroarch.cfg" ]]; then
    cat > "$HOME/.config/retroarch/retroarch.cfg" <<EOF
# NIRUCON RetroArch baseline.
# This is intentionally conservative. RetroArch may rewrite this file from its GUI.
video_driver = "vulkan"
audio_driver = "pulse"
joypad_driver = "udev"
savestate_directory = "$HOME/.local/share/retroarch/states"
savefile_directory = "$HOME/.local/share/retroarch/saves"
screenshot_directory = "$HOME/Pictures/RetroArch"
rgui_browser_directory = "$HOME/Games/roms"
system_directory = "$HOME/Games/bios"
EOF
    ok "RetroArch baseline config written."
  else
    note "Existing RetroArch config preserved: $HOME/.config/retroarch/retroarch.cfg"
  fi

  ok "Gaming profile completed."
fi

# -----------------------------------------------------------------------------
# Multi-monitor helpers for dwm/X11
# -----------------------------------------------------------------------------

if [[ "$INSTALL_MULTIMONITOR_HELPERS" -eq 1 ]]; then
  phase "Creating multi-monitor helper scripts"

  mkdir -p "$LOCAL_BIN" "$HOME/.screenlayout"

  cat > "$LOCAL_BIN/monitor-status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "== Connected outputs =="
xrandr --query | awk '/ connected/{print}'

echo
echo "== Current layout =="
xrandr --query | sed -n '/Screen 0/,/ disconnected/p'

echo
echo "Hints:"
echo "  arandr                 # GUI layout editor"
echo "  autorandr --save NAME  # save current layout"
echo "  autorandr --change     # auto-apply saved matching layout"
echo "  xrandr --output HDMI-1 --rotate normal|left|right|inverted"
EOF

  cat > "$LOCAL_BIN/monitor-gui.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if command -v arandr >/dev/null 2>&1; then
  exec arandr
else
  echo "arandr missing. Install it with: sudo apt install arandr"
  exit 1
fi
EOF

  cat > "$LOCAL_BIN/monitor-save.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

name="${1:-}"
if [[ -z "$name" ]]; then
  echo "Usage: monitor-save.sh PROFILE_NAME"
  echo "Example: monitor-save.sh home-dual-vertical"
  exit 1
fi

if ! command -v autorandr >/dev/null 2>&1; then
  echo "autorandr missing. Install it with: sudo apt install autorandr"
  exit 1
fi

autorandr --save "$name"
echo "Saved monitor profile: $name"
EOF

  cat > "$LOCAL_BIN/monitor-apply.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if command -v autorandr >/dev/null 2>&1; then
  autorandr --change || true
else
  echo "autorandr missing. Install it with: sudo apt install autorandr"
  exit 1
fi
EOF

  cat > "$LOCAL_BIN/monitor-rotate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output="${1:-}"
rotation="${2:-normal}"

if [[ -z "$output" ]]; then
  echo "Usage: monitor-rotate.sh OUTPUT normal|left|right|inverted"
  echo
  echo "Connected outputs:"
  xrandr --query | awk '/ connected/{print "  "$1}'
  exit 1
fi

case "$rotation" in
  normal|left|right|inverted) ;;
  *) echo "Invalid rotation: $rotation"; exit 1 ;;
esac

xrandr --output "$output" --rotate "$rotation"
EOF

  chmod +x \
    "$LOCAL_BIN/monitor-status.sh" \
    "$LOCAL_BIN/monitor-gui.sh" \
    "$LOCAL_BIN/monitor-save.sh" \
    "$LOCAL_BIN/monitor-apply.sh" \
    "$LOCAL_BIN/monitor-rotate.sh"

  ok "Multi-monitor helpers created."
fi

# -----------------------------------------------------------------------------
# Firmware and microcode
# -----------------------------------------------------------------------------

phase "Installing firmware and CPU microcode"

sudo apt install -y firmware-linux firmware-misc-nonfree || true

if lscpu | grep -qi intel; then
  say "Intel CPU detected. Installing intel-microcode..."
  sudo apt install -y intel-microcode || true
elif lscpu | grep -qi amd; then
  say "AMD CPU detected. Installing amd64-microcode..."
  sudo apt install -y amd64-microcode || true
else
  warn "Could not detect Intel or AMD CPU."
fi

ok "Firmware/microcode phase completed."

# -----------------------------------------------------------------------------
# Locale, keyboard and user dirs
# -----------------------------------------------------------------------------

phase "Setting locale and Swedish keyboard"

sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sudo sed -i 's/^# *sv_SE.UTF-8 UTF-8/sv_SE.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
sudo update-locale LANG=en_US.UTF-8
sudo localectl set-x11-keymap se || true

mkdir -p "$HOME/.config"
printf 'en_US\n' > "$HOME/.config/user-dirs.locale"
LANG=en_US.UTF-8 xdg-user-dirs-update --force || true

ok "Locale and keyboard configured."

# -----------------------------------------------------------------------------
# fish shell
# -----------------------------------------------------------------------------

if [[ "$SET_FISH_DEFAULT" -eq 1 ]]; then
  phase "Setting fish as default shell"

  FISH_PATH="$(command -v fish)"

  if [[ -z "$FISH_PATH" ]]; then
    fail "fish is not installed or not found in PATH."
    exit 1
  fi

  grep -qxF "$FISH_PATH" /etc/shells || echo "$FISH_PATH" | sudo tee -a /etc/shells >/dev/null
  sudo chsh -s "$FISH_PATH" "$USER"

  ok "fish set as default shell for $USER."
else
  note "fish installed, but default shell left unchanged."
fi

# -----------------------------------------------------------------------------
# Services
# -----------------------------------------------------------------------------

phase "Enabling core services"

sudo systemctl enable NetworkManager
sudo systemctl enable sddm

systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || true

ok "NetworkManager, SDDM and PipeWire user services configured."

# -----------------------------------------------------------------------------
# NetworkManager configuration
# -----------------------------------------------------------------------------

phase "Preparing NetworkManager configuration"

if [[ -f /etc/network/interfaces ]]; then
  sudo cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d-%H%M%S)"
  sudo tee /etc/network/interfaces >/dev/null <<'EOF'
# Managed for NetworkManager desktop use.
auto lo
iface lo inet loopback
EOF
fi

sudo tee /etc/NetworkManager/NetworkManager.conf >/dev/null <<'EOF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true
EOF

ok "NetworkManager configuration prepared."

# -----------------------------------------------------------------------------
# Clone and build suckless tools
# -----------------------------------------------------------------------------

phase "Cloning or updating suckless repository"

mkdir -p "$(dirname "$SUCKLESS_DIR")"

if [[ -d "$SUCKLESS_DIR/.git" ]]; then
  say "Updating existing suckless repository..."
  git -C "$SUCKLESS_DIR" fetch --all --prune
  git -C "$SUCKLESS_DIR" pull --ff-only || true
else
  say "Cloning suckless repository..."
  git clone "$SUCKLESS_REPO" "$SUCKLESS_DIR"
fi

phase "Applying Debian slock group fix"

for cfg in "$SUCKLESS_DIR/slock/config.h" "$SUCKLESS_DIR/slock/config.def.h"; do
  if [[ -f "$cfg" ]]; then
    sed -i 's/static const char \*group = "nobody";/static const char *group = "nogroup";/' "$cfg"
    ok "Patched $cfg"
  fi
done

phase "Building and installing dwm, dmenu, st and slock"

for app in dwm dmenu st slock; do
  if [[ -d "$SUCKLESS_DIR/$app" ]]; then
    say "Building $app..."
    make -C "$SUCKLESS_DIR/$app" clean
    make -C "$SUCKLESS_DIR/$app" -j"$(nproc)"
    sudo make -C "$SUCKLESS_DIR/$app" PREFIX=/usr/local install
    ok "$app installed."
  else
    warn "Missing component: $app"
  fi
done

# -----------------------------------------------------------------------------
# Look and feel
# -----------------------------------------------------------------------------

phase "Cloning or updating look and feel repository"

mkdir -p "$(dirname "$LOOKANDFEEL_DIR")"

if [[ -d "$LOOKANDFEEL_DIR/.git" ]]; then
  say "Updating existing look and feel repository..."
  git -C "$LOOKANDFEEL_DIR" fetch --all --prune
  git -C "$LOOKANDFEEL_DIR" pull --ff-only || true
else
  say "Cloning look and feel repository..."
  git clone "$LOOKANDFEEL_REPO" "$LOOKANDFEEL_DIR"
fi

phase "Deploying look and feel files"

mkdir -p "$HOME/.config" "$LOCAL_BIN" "$LOCAL_SHARE"

[[ -d "$LOOKANDFEEL_DIR/config" ]] && rsync -a "$LOOKANDFEEL_DIR/config/" "$HOME/.config/"
[[ -d "$LOOKANDFEEL_DIR/local/bin" ]] && rsync -a "$LOOKANDFEEL_DIR/local/bin/" "$LOCAL_BIN/"
[[ -d "$LOOKANDFEEL_DIR/local/share" ]] && rsync -a "$LOOKANDFEEL_DIR/local/share/" "$LOCAL_SHARE/"

chmod +x "$LOCAL_BIN/"* 2>/dev/null || true

touch "$HOME/.profile"
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.profile" || \
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"

ok "Look and feel deployed."

# -----------------------------------------------------------------------------
# Remove non-Debian shell remnants from imported look and feel
# -----------------------------------------------------------------------------

phase "Removing non-Debian fish remnants"

mkdir -p "$HOME/.config/fish"

# Old Arch/CachyOS fish snippets can be imported by the look-and-feel repo and
# then loaded automatically by fish from conf.d/functions. Back them up and
# remove only the offending lines/files instead of deleting the whole fish tree.
if [[ -d "$HOME/.config/fish" ]]; then
  find "$HOME/.config/fish" -type f     \( -iname '*cachy*' -o -iname '*arch*' -o -iname '*paru*' -o -iname '*yay*' \)     -print0 2>/dev/null | while IFS= read -r -d '' f; do
      cp "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
      rm -f "$f"
      warn "Removed non-Debian fish file: $f"
    done

  grep -RIlE 'cachyos|/usr/share/cachyos|paru|yay|pacman -|pacman\s' "$HOME/.config/fish" 2>/dev/null | while IFS= read -r f; do
    cp "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i -E '/cachyos|\/usr\/share\/cachyos|paru|yay|pacman -|pacman[[:space:]]/d' "$f"
    warn "Sanitized non-Debian references in: $f"
  done
fi

ok "Fish remnants cleaned."

# -----------------------------------------------------------------------------
# Integrated NIRU Noir fish and terminal configuration
# -----------------------------------------------------------------------------

phase "Writing integrated NIRU Noir fish and terminal configuration"

mkdir -p "$HOME/.config/fish" "$HOME/.config/alacritty" "$HOME/.config/kitty" "$HOME/.config/bat"

backup_user_file "$HOME/.config/fish/config.fish"
backup_user_file "$HOME/.config/starship.toml"
backup_user_file "$HOME/.config/kitty/kitty.conf"
backup_user_file "$HOME/.config/alacritty/alacritty.toml"
backup_user_file "$HOME/.config/bat/config"

cat > "$HOME/.config/fish/config.fish" <<'EOF'
# ~/.config/fish/config.fish
# NIRUCON Debian fish config with integrated NIRU Noir terminal profile.
# Debian-safe: no CachyOS, Arch, pacman, paru or yay assumptions.

# No default Fish welcome/help text.
set -g fish_greeting ""

# PATH.
fish_add_path -g $HOME/.local/bin $HOME/.local/share/yabridge /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /bin /sbin

# Editor/tools.
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx PAGER less
set -gx MANPAGER "less -R"
set -gx LESS "-R --use-color -Dd+r -Du+b"
set -gx BAT_THEME "TwoDark"

# NIRU Noir / Fish colors.
if status is-interactive
    set fish_color_normal d6d1c4
    set fish_color_command c8b46a
    set fish_color_keyword c8b46a
    set fish_color_param e0ddd2
    set fish_color_quote b8ad8a
    set fish_color_redirection a39a7a
    set fish_color_end 8f8f8f
    set fish_color_error 9a5a4f
    set fish_color_operator c8b46a
    set fish_color_escape d6c27a
    set fish_color_autosuggestion 666666
    set fish_color_comment 666666
    set fish_color_selection --background=35322a
    set fish_color_search_match --background=35322a
    set fish_color_valid_path --underline
end

# eza colors: folders gold, files bone/grey, links grey, executables muted gold.
set -gx EZA_COLORS "di=38;5;180:fi=38;5;252:ln=38;5;245:ex=38;5;222"

# Prompt.
if command -q starship
    starship init fish | source
end

# Smart cd.
if command -q zoxide
    zoxide init fish | source
end

# Modern ls, with safe fallback.
if command -q eza
    alias ls='eza --icons=auto --group-directories-first'
    alias ll='eza -lah --icons=auto --group-directories-first'
    alias la='eza -a --icons=auto --group-directories-first'
    alias lt='eza --tree --icons=auto --group-directories-first'
    alias tree='eza --tree --icons=auto --group-directories-first'
else
    alias ll='ls -lah --color=auto'
    alias la='ls -A --color=auto'
    alias l='ls -CF --color=auto'
end

# Modern cat, Debian may expose bat as batcat.
if command -q batcat
    alias cat='batcat --style=plain --paging=never'
    alias batp='batcat --paging=always'
else if command -q bat
    alias cat='bat --style=plain --paging=never'
    alias batp='bat --paging=always'
end

# Debian's fd binary is usually fdfind.
if command -q fdfind
    alias fd='fdfind'
end

# Navigation.
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Search. Keep grep as grep, but add rg shortcut.
alias grep='grep --color=auto'
if command -q rg
    alias rgg='rg'
end

# Git.
alias gs='git status'
alias gp='git pull'
alias gl='git log --oneline --graph --decorate -20'
alias gcm='git commit -m'

# Debian/system helpers.
alias c='clear'
alias update='sudo apt update && sudo apt full-upgrade -y'
alias install='sudo apt install'
alias search='apt search'
alias cleanup='sudo apt autoremove --purge -y && sudo apt clean'
alias ports='ss -tulpn'
alias df='df -h'
alias free='free -h'
alias top='btop'
alias music='kew'

# Optional system info manually with "ff".
if command -q fastfetch
    alias ff='fastfetch'
end

# fzf integration, if supported by the packaged version.
if status is-interactive
    if command -q fzf
        fzf --fish | source 2>/dev/null
    end
end
EOF

cat > "$HOME/.config/starship.toml" <<'EOF'
# NIRU Noir Starship prompt.
add_newline = true

format = """
$directory\
$git_branch\
$git_status\
$cmd_duration\
$line_break\
$character
"""

[directory]
style = "bold #c8b46a"
truncation_length = 4
truncate_to_repo = false

[git_branch]
format = "[$symbol$branch]($style) "
symbol = "◈ "
style = "#9c8a5b"

[git_status]
format = "[$all_status$ahead_behind]($style) "
style = "#7a7a7a"

[cmd_duration]
min_time = 2000
format = "[$duration]($style) "
style = "#8f8f8f"

[character]
success_symbol = "[❯](bold #d6d1c4)"
error_symbol = "[❯](bold #9a5a4f)"
EOF

cat > "$HOME/.config/kitty/kitty.conf" <<'EOF'
# ~/.config/kitty/kitty.conf
# NIRU Noir for Debian/dwm.

font_family JetBrainsMono Nerd Font
bold_font auto
italic_font auto
bold_italic_font auto
font_size 12.0

shell /usr/bin/fish

background #0b0b0b
foreground #d6d1c4

selection_background #35322a
selection_foreground #f2ead3

cursor #c8b46a
cursor_text_color #0b0b0b
cursor_shape beam
cursor_blink_interval 0.5

url_color #c8b46a

color0  #0b0b0b
color1  #7a3f35
color2  #8a805f
color3  #c8b46a
color4  #8f8f8f
color5  #a39a7a
color6  #b8b8b8
color7  #d6d1c4
color8  #4a4a4a
color9  #9a5a4f
color10 #a8a080
color11 #d6c27a
color12 #b0b0b0
color13 #b8ad8a
color14 #cccccc
color15 #f2ead3

scrollback_lines 50000
enable_audio_bell no
visual_bell_duration 0
confirm_os_window_close 0

window_padding_width 10
background_opacity 0.96
dynamic_background_opacity yes

copy_on_select clipboard
strip_trailing_spaces smart

tab_bar_edge bottom
tab_bar_style hidden

map ctrl+shift+t new_tab
map ctrl+shift+w close_tab
map ctrl+shift+enter new_window
EOF

cat > "$HOME/.config/alacritty/alacritty.toml" <<'EOF'
# NIRU Noir Alacritty fallback config.

[window]
padding = { x = 10, y = 10 }
dynamic_padding = true
opacity = 0.96

[font]
normal = { family = "JetBrainsMono Nerd Font", style = "Regular" }
bold = { family = "JetBrainsMono Nerd Font", style = "Bold" }
italic = { family = "JetBrainsMono Nerd Font", style = "Italic" }
size = 12.0

[terminal.shell]
program = "/usr/bin/fish"

[colors.primary]
background = "#0b0b0b"
foreground = "#d6d1c4"

[colors.cursor]
text = "#0b0b0b"
cursor = "#c8b46a"
EOF

cat > "$HOME/.config/bat/config" <<'EOF'
--theme=TwoDark
--style=plain
--paging=never
EOF

# Also remove the Fish greeting at universal-variable level for existing users.
if command -v fish >/dev/null 2>&1; then
  fish -c 'set -U fish_greeting ""' 2>/dev/null || true
fi

ok "Integrated NIRU Noir fish, Kitty, Alacritty, Starship and bat configuration written."

# -----------------------------------------------------------------------------
# Nerd Font
# -----------------------------------------------------------------------------

phase "Installing JetBrainsMono Nerd Font"

mkdir -p "$HOME/.local/share/fonts/JetBrainsMonoNerd"
TMPFONT="$(mktemp -d)"

if wget -q -O "$TMPFONT/JetBrainsMono.zip" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"; then
  unzip -oq "$TMPFONT/JetBrainsMono.zip" -d "$HOME/.local/share/fonts/JetBrainsMonoNerd"
  fc-cache -fv >/dev/null
  ok "JetBrainsMono Nerd Font installed."
else
  warn "Could not download JetBrainsMono Nerd Font."
fi

rm -rf "$TMPFONT"

# -----------------------------------------------------------------------------
# Optional statusbar patch
# -----------------------------------------------------------------------------

if [[ "$PATCH_STATUSBAR" -eq 1 && -f "$LOCAL_BIN/dwm-status.sh" ]]; then
  phase "Patching dwm-status.sh for Debian"

  cp "$LOCAL_BIN/dwm-status.sh" "$LOCAL_BIN/dwm-status.sh.bak.$(date +%Y%m%d-%H%M%S)"

  sed -i 's|export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"|export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"|' "$LOCAL_BIN/dwm-status.sh"
  sed -i 's/^SHOW_UPDATES=1/SHOW_UPDATES=0/' "$LOCAL_BIN/dwm-status.sh"

  chmod +x "$LOCAL_BIN/dwm-status.sh"

  ok "dwm-status.sh patched."
fi

# -----------------------------------------------------------------------------
# SDDM theme
# -----------------------------------------------------------------------------

phase "Installing NIRU Noir SDDM theme"

mkdir -p "$(dirname "$SDDM_THEME_CACHE")"

if [[ -d "$SDDM_THEME_CACHE/.git" ]]; then
  say "Updating existing SDDM theme repository..."
  git -C "$SDDM_THEME_CACHE" fetch --all --prune
  git -C "$SDDM_THEME_CACHE" pull --ff-only || true
else
  say "Cloning SDDM theme repository..."
  git clone "$SDDM_THEME_REPO" "$SDDM_THEME_CACHE"
fi

# The actual SDDM theme files are stored in the repo subdirectory "theme".
if [[ -d "$SDDM_THEME_CACHE/theme" ]]; then
  SDDM_THEME_SOURCE="$SDDM_THEME_CACHE/theme"
else
  SDDM_THEME_SOURCE="$SDDM_THEME_CACHE"
fi

if [[ ! -f "$SDDM_THEME_SOURCE/metadata.desktop" ]]; then
  fail "metadata.desktop is missing in the SDDM theme source: $SDDM_THEME_SOURCE"
  exit 1
fi

if [[ ! -f "$SDDM_THEME_SOURCE/Main.qml" ]]; then
  fail "Main.qml is missing in the SDDM theme source: $SDDM_THEME_SOURCE"
  exit 1
fi

if ! grep -q '^MainScript=Main.qml' "$SDDM_THEME_SOURCE/metadata.desktop"; then
  fail "SDDM theme metadata.desktop does not define MainScript=Main.qml."
  exit 1
fi

if ! grep -q '^Theme-Id=niru-noir' "$SDDM_THEME_SOURCE/metadata.desktop"; then
  warn "Theme-Id=niru-noir not found. Installing as niru-noir anyway."
fi

sudo mkdir -p "/usr/share/sddm/themes/$SDDM_THEME_ID"
sudo rsync -a --delete "$SDDM_THEME_SOURCE/" "/usr/share/sddm/themes/$SDDM_THEME_ID/"
sudo chown -R root:root "/usr/share/sddm/themes/$SDDM_THEME_ID"

ok "SDDM theme installed to /usr/share/sddm/themes/$SDDM_THEME_ID"

# -----------------------------------------------------------------------------
# dwm SDDM session
# -----------------------------------------------------------------------------

phase "Creating dwm SDDM session"

sudo tee "$SESSION_WRAPPER" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# This wrapper starts a clean dwm session from SDDM.

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm

[[ -r "$HOME/.profile" ]] && . "$HOME/.profile"

if command -v xrdb >/dev/null 2>&1 && [[ -r "$HOME/.Xresources" ]]; then
  xrdb -merge "$HOME/.Xresources"
fi

# Ensure a DBus session exists.
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v dbus-run-session >/dev/null 2>&1 && [[ "${1:-}" != "--dbus-started" ]]; then
  exec dbus-run-session "$0" --dbus-started "$@"
fi

[[ "${1:-}" == "--dbus-started" ]] && shift || true

# Source modular X session startup hooks.
for f in "$HOME/.config/xinitrc.d/"*.sh; do
  [[ -r "$f" ]] && . "$f"
done

exec dwm
EOF

sudo chmod +x "$SESSION_WRAPPER"

sudo tee "$SESSION_DESKTOP" >/dev/null <<EOF
[Desktop Entry]
Name=dwm
Comment=Dynamic window manager
Exec=$SESSION_WRAPPER
TryExec=/usr/local/bin/dwm
Type=Application
DesktopNames=dwm
EOF

sudo mkdir -p /etc/sddm.conf.d

sudo tee /etc/sddm.conf.d/10-nirucon.conf >/dev/null <<EOF
[Theme]
Current=$SDDM_THEME_ID

[Users]
RememberLastUser=true

[General]
RememberLastSession=true
EOF

ok "dwm SDDM session created."

# -----------------------------------------------------------------------------
# X session hooks
# -----------------------------------------------------------------------------

phase "Creating modular X session hooks"

mkdir -p "$XINITRC_DIR"

cat > "$XINITRC_DIR/10-env.sh" <<'EOF'
#!/usr/bin/env bash

# Basic dwm/X11 environment.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm

command -v setxkbmap >/dev/null 2>&1 && setxkbmap se
command -v xsetroot >/dev/null 2>&1 && xsetroot -solid "#111111"
command -v autorandr >/dev/null 2>&1 && autorandr --change >/dev/null 2>&1 || true
EOF

cat > "$XINITRC_DIR/20-lookandfeel.sh" <<'EOF'
#!/usr/bin/env bash

# Notification daemon.
command -v dunst >/dev/null 2>&1 && ! pgrep -x dunst >/dev/null 2>&1 && dunst &

# PolicyKit authentication agent for minimal window managers.
command -v lxpolkit >/dev/null 2>&1 && ! pgrep -x lxpolkit >/dev/null 2>&1 && lxpolkit &

# Compositor.
if command -v picom >/dev/null 2>&1 && ! pgrep -x picom >/dev/null 2>&1; then
  if [[ -f "$HOME/.config/picom/picom.conf" ]]; then
    picom --config "$HOME/.config/picom/picom.conf" --daemon 2>/dev/null || picom --daemon &
  else
    picom --daemon &
  fi
fi

# Useful tray/background tools.
command -v blueman-applet >/dev/null 2>&1 && ! pgrep -x blueman-applet >/dev/null 2>&1 && blueman-applet &
command -v udiskie >/dev/null 2>&1 && ! pgrep -x udiskie >/dev/null 2>&1 && udiskie --tray &
command -v nextcloud >/dev/null 2>&1 && ! pgrep -x nextcloud >/dev/null 2>&1 && nextcloud --background &
EOF

cat > "$XINITRC_DIR/30-wallpaper.sh" <<'EOF'
#!/usr/bin/env bash

# Wallpaper handling.
if [[ -x "$HOME/.local/bin/wallrotate.sh" ]]; then
  "$HOME/.local/bin/wallrotate.sh" &
elif [[ -x "$HOME/.local/bin/wallpaperchange.sh" ]]; then
  "$HOME/.local/bin/wallpaperchange.sh" &
elif command -v feh >/dev/null 2>&1 && [[ -d "$HOME/Pictures" ]]; then
  feh --randomize --bg-fill "$HOME/Pictures" &
fi
EOF

cat > "$XINITRC_DIR/40-statusbar.sh" <<'EOF'
#!/usr/bin/env bash

# dwm statusbar.
if [[ -x "$HOME/.local/bin/dwm-status.sh" ]]; then
  pkill -u "$USER" -f "$HOME/.local/bin/dwm-status.sh" 2>/dev/null || true
  "$HOME/.local/bin/dwm-status.sh" &
fi
EOF

cat > "$XINITRC_DIR/50-lock.sh" <<'EOF'
#!/usr/bin/env bash

# Automatic locking through xss-lock and slock.
if command -v xss-lock >/dev/null 2>&1 && command -v slock >/dev/null 2>&1 && ! pgrep -x xss-lock >/dev/null 2>&1; then
  xss-lock slock &
fi
EOF

cat > "$XINITRC_DIR/60-audio.sh" <<'EOF'
#!/usr/bin/env bash

# Make sure PipeWire services are started for the user session.
systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
EOF

cat > "$XINITRC_DIR/90-local.sh" <<'EOF'
#!/usr/bin/env bash

# Add local machine-specific startup commands here.
EOF

chmod +x "$XINITRC_DIR/"*.sh

ok "X session hooks created."

# -----------------------------------------------------------------------------
# .xinitrc fallback
# -----------------------------------------------------------------------------

phase "Creating .xinitrc fallback"

cat > "$HOME/.xinitrc" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Fallback startx session for dwm.

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm

[[ -r "$HOME/.profile" ]] && . "$HOME/.profile"

if command -v xrdb >/dev/null 2>&1 && [[ -r "$HOME/.Xresources" ]]; then
  xrdb -merge "$HOME/.Xresources"
fi

for f in "$HOME/.config/xinitrc.d/"*.sh; do
  [[ -r "$f" ]] && . "$f"
done

exec dwm
EOF

chmod +x "$HOME/.xinitrc"

ok ".xinitrc fallback created."

# -----------------------------------------------------------------------------
# Optional system services
# -----------------------------------------------------------------------------

if [[ "$INSTALL_SSH" -eq 1 ]]; then
  phase "Installing OpenSSH server"
  sudo apt install "${APT_FLAGS[@]}" openssh-server
  sudo systemctl enable --now ssh
  ok "OpenSSH server installed and enabled."
fi

if [[ "$INSTALL_CUPS" -eq 1 ]]; then
  phase "Installing CUPS printer support"
  sudo apt install "${APT_FLAGS[@]}" cups system-config-printer printer-driver-gutenprint
  sudo systemctl enable --now cups
  sudo usermod -aG lpadmin "$USER" || true
  ok "CUPS installed and enabled."
fi

# -----------------------------------------------------------------------------
# Optional applications
# -----------------------------------------------------------------------------

install_signal() {
  phase "Installing Signal Desktop"

  wget -O- https://updates.signal.org/desktop/apt/keys.asc \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/signal-desktop-keyring.gpg >/dev/null

  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/signal-desktop-keyring.gpg] https://updates.signal.org/desktop/apt xenial main" \
    | sudo tee /etc/apt/sources.list.d/signal-xenial.list >/dev/null

  sudo apt update
  sudo apt install -y signal-desktop || warn "Signal installation failed."

  ok "Signal phase completed."
}

install_helium() {
  phase "Installing Helium Browser"

  local tmp url
  tmp="$(mktemp -d)"

  url="$(curl -fsSL https://api.github.com/repos/imputnet/helium-linux/releases/latest \
    | grep browser_download_url \
    | grep -Ei 'amd64\.deb|x86_64\.deb' \
    | head -n1 \
    | cut -d '"' -f4 || true)"

  if [[ -z "${url:-}" ]]; then
    warn "Could not find Helium .deb release URL."
    rm -rf "$tmp"
    return 0
  fi

  say "Downloading Helium from:"
  echo "  $url"

  if wget -O "$tmp/helium.deb" "$url"; then
    sudo apt install -y "$tmp/helium.deb" || warn "Helium installation failed."
  else
    warn "Could not download Helium .deb."
  fi

  rm -rf "$tmp"

  ok "Helium phase completed."
}

[[ "$INSTALL_SIGNAL" -eq 1 ]] && install_signal
[[ "$INSTALL_HELIUM" -eq 1 ]] && install_helium

if [[ "$INSTALL_GAMING" -eq 1 ]]; then
  echo "Gaming workstation commands:"
  echo "  gaming-status.sh       # inspect Vulkan/Steam/RetroArch/GameMode"
  echo "  gaming-performance.sh  # request performance mode before gaming"
  echo "  gaming-balanced.sh     # return to balanced mode"
  echo
fi

if [[ "$INSTALL_MULTIMONITOR_HELPERS" -eq 1 ]]; then
  echo "Multi-monitor commands:"
  echo "  monitor-status.sh              # show connected outputs and layout"
  echo "  monitor-gui.sh                 # open arandr GUI"
  echo "  monitor-rotate.sh OUTPUT right # rotate one screen"
  echo "  monitor-save.sh home-dual      # save current layout with autorandr"
  echo "  monitor-apply.sh               # auto-apply saved matching layout"
  echo
fi

if [[ "$INSTALL_TAILSCALE" -eq 1 ]]; then
  phase "Installing Tailscale"

  curl -fsSL https://tailscale.com/install.sh | sh
  sudo systemctl enable --now tailscaled

  warn "After reboot/login, run if needed:"
  echo "  sudo tailscale up"

  ok "Tailscale installed."
fi

# -----------------------------------------------------------------------------
# Remove Plasma/KDE desktop packages if present
# -----------------------------------------------------------------------------

if [[ "$PURGE_PLASMA" -eq 1 ]]; then
  phase "Removing Plasma/KDE desktop packages if present, while keeping SDDM"

  note "This removes common Plasma/KDE desktop packages, but keeps/reinstalls SDDM."

  sudo apt purge -y \
    plasma-desktop plasma-workspace plasma-workspace-data plasma-discover \
    plasma-discover-backend-fwupd plasma-disks plasma-firewall plasma-nm \
    plasma-pa plasma-systemmonitor plasma-thunderbolt plasma-vault plasma-welcome \
    plasma-widgets-addons plasma-wallpapers-addons \
    kde-plasma-desktop kde-standard kde-full task-kde-desktop \
    dolphin konsole kate kscreen kde-spectacle gwenview ark okular filelight \
    2>/dev/null || true

  sudo apt autoremove --purge -y

  say "Ensuring SDDM is still installed..."
  sudo apt install -y sddm
  sudo systemctl enable sddm

  ok "Plasma/KDE cleanup completed."
fi

# -----------------------------------------------------------------------------
# Final cleanup
# -----------------------------------------------------------------------------

phase "Final cleanup"

sudo apt autoremove --purge -y
sudo apt clean

ok "APT cleanup completed."

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------

phase "Verification"

echo "System"
echo "  Debian:          $(cat /etc/debian_version 2>/dev/null || echo unknown)"
echo "  Kernel:          $(uname -r)"
echo "  User:            $USER"
echo "  Shell:           $(getent passwd "$USER" | cut -d: -f7)"
echo

echo "Locale / keyboard"
echo "  Locale:          $(grep '^LANG=' /etc/default/locale 2>/dev/null || echo missing)"
echo "  X11 keymap:      $(localectl status 2>/dev/null | grep 'X11 Layout' || echo unknown)"
echo

echo "Core desktop"
echo "  dwm:             $(command -v dwm || echo missing)"
echo "  st:              $(command -v st || echo missing)"
echo "  dmenu:           $(command -v dmenu || echo missing)"
echo "  slock:           $(command -v slock || echo missing)"
echo "  SDDM:            $(systemctl is-enabled sddm 2>/dev/null || echo unknown)"
echo "  SDDM theme:      $(grep -R '^Current=' /etc/sddm.conf.d 2>/dev/null | head -1 || echo missing)"
echo

echo "Desktop tools"
echo "  fish:            $(command -v fish || echo missing)"
echo "  kitty:           $(command -v kitty || echo missing)"
echo "  alacritty:       $(command -v alacritty || echo missing)"
echo "  rofi:            $(command -v rofi || echo missing)"
echo "  picom:           $(command -v picom || echo missing)"
echo "  dunst:           $(command -v dunst || echo missing)"
echo "  lxpolkit:        $(command -v lxpolkit || echo missing)"
echo "  xss-lock:        $(command -v xss-lock || echo missing)"
echo "  NetworkManager:  $(systemctl is-enabled NetworkManager 2>/dev/null || echo unknown)"
echo

echo "Audio"
echo "  PipeWire:        $(command -v pipewire || echo missing)"
echo "  WirePlumber:     $(command -v wireplumber || echo missing)"
echo "  pactl:           $(command -v pactl || echo missing)"
echo "  pamixer:         $(command -v pamixer || echo missing)"
echo "  qpwgraph:        $(command -v qpwgraph || echo optional/missing)"
echo "  qjackctl:        $(command -v qjackctl || echo optional/missing)"
echo "  audio-status:    $(command -v audio-status.sh || echo optional/missing)"
echo "  Wine:            $(command -v wine || echo optional/missing)"
if command -v yabridgectl >/dev/null 2>&1; then
  echo "  yabridgectl:     $(command -v yabridgectl)"
elif [[ -x "$HOME/.local/share/yabridge/yabridgectl" ]]; then
  echo "  yabridgectl:     $HOME/.local/share/yabridge/yabridgectl"
else
  echo "  yabridgectl:     optional/missing"
fi
echo "  UMC1820:         $(lsusb 2>/dev/null | grep -qi "UMC1820\|Behringer" && echo detected || echo not-detected)"
echo

echo "Fonts"
echo "  Nerd Font:       $(fc-match 'JetBrainsMono Nerd Font' | head -1)"
echo "  starship:        $(command -v starship || echo missing)"
echo "  zoxide:          $(command -v zoxide || echo missing)"
echo "  eza:             $(command -v eza || echo missing)"
echo "  bat/batcat:      $(command -v batcat || command -v bat || echo missing)"
echo "  fzf:             $(command -v fzf || echo missing)"
echo "  kew:             $(command -v kew || echo missing)"
echo

echo "Gaming"
echo "  Steam:           $(command -v steam || echo optional/missing)"
echo "  RetroArch:       $(command -v retroarch || echo optional/missing)"
echo "  GameMode:        $(command -v gamemoderun || echo optional/missing)"
echo "  MangoHud:        $(command -v mangohud || echo optional/missing)"
echo "  GOverlay:        $(command -v goverlay || echo optional/missing)"
echo "  Gamescope:       $(command -v gamescope || echo optional/missing)"
echo "  Vulkaninfo:      $(command -v vulkaninfo || echo optional/missing)"
echo "  Gaming status:   $(command -v gaming-status.sh || echo optional/missing)"
echo

echo "Multi-monitor"
echo "  arandr:          $(command -v arandr || echo optional/missing)"
echo "  autorandr:       $(command -v autorandr || echo optional/missing)"
echo "  xrandr:          $(command -v xrandr || echo missing)"
echo "  monitor-status:  $(command -v monitor-status.sh || echo optional/missing)"
echo

echo "Optional applications"
echo "  Helium:          $(command -v helium-browser || command -v helium || echo optional/missing)"
echo "  Signal:          $(command -v signal-desktop || echo optional/missing)"
echo "  Tailscale:       $(command -v tailscale || echo optional/missing)"
echo "  SSH server:      $(systemctl is-enabled ssh 2>/dev/null || echo optional/missing)"
echo "  CUPS:            $(systemctl is-enabled cups 2>/dev/null || echo optional/missing)"
echo

echo "Plasma/KDE check"
if apt list --installed 2>/dev/null | grep -Eiq '^(plasma-desktop|plasma-workspace|kde-plasma-desktop|kde-standard|kde-full|task-kde-desktop)/'; then
  warn "Some Plasma/KDE desktop meta/workspace packages still appear installed."
else
  ok "No obvious Plasma desktop meta/workspace packages installed."
fi

if [[ -d "/usr/share/sddm/themes/$SDDM_THEME_ID" ]]; then
  ok "NIRU Noir SDDM theme exists: /usr/share/sddm/themes/$SDDM_THEME_ID"
else
  warn "NIRU Noir SDDM theme directory is missing."
fi

if [[ "$INSTALL_AUDIO_TOOLS" -eq 1 ]]; then
  ok "Audio profile installed: $AUDIO_PROFILE"
  warn "You must log out/reboot before audio/video group membership is active."
fi

if [[ "$IS_LAPTOP" -eq 1 ]]; then
  ok "Laptop profile installed."
else
  ok "Workstation profile installed."
fi

# -----------------------------------------------------------------------------
# Final instructions
# -----------------------------------------------------------------------------

echo
phase "Postinstall complete"

echo "Recommended next step:"
echo "  sudo reboot"
echo
echo "After reboot:"
echo "  1) Select dwm in SDDM."
echo "  2) Verify networking:"
echo "       nmcli device status"
echo "  3) Verify desktop background services:"
echo "       pgrep -a picom"
echo "       pgrep -a dunst"
echo "       pgrep -a xss-lock"
echo "  4) Verify audio:"
echo "       pactl info"
echo "  5) Test lock screen:"
echo "       slock"
echo

if [[ "$INSTALL_AUDIO_TOOLS" -eq 1 ]]; then
  echo "Audio workstation commands:"
  echo "  audio-status.sh         # inspect PipeWire/JACK/ALSA state"
  echo "  reaper-audio-check.sh   # quick Reaper/plugin environment check"
  echo "  audio-performance.sh    # use before recording/mixing"
  echo "  audio-balanced.sh       # use after audio work"
  echo "  yabridge-sync.sh        # sync Windows VST paths when yabridge is installed"
  [[ "$INSTALL_NAM_HELPER" -eq 1 ]] && echo "  nam-notes.sh            # NAM/Neural Amp Modeler notes" || true
  echo
fi

if [[ "$INSTALL_GAMING" -eq 1 ]]; then
  echo "Gaming workstation commands:"
  echo "  gaming-status.sh       # inspect Vulkan/Steam/RetroArch/GameMode"
  echo "  gaming-performance.sh  # request performance mode before gaming"
  echo "  gaming-balanced.sh     # return to balanced mode"
  echo
fi

if [[ "$INSTALL_MULTIMONITOR_HELPERS" -eq 1 ]]; then
  echo "Multi-monitor commands:"
  echo "  monitor-status.sh              # show connected outputs and layout"
  echo "  monitor-gui.sh                 # open arandr GUI"
  echo "  monitor-rotate.sh OUTPUT right # rotate one screen"
  echo "  monitor-save.sh home-dual      # save current layout with autorandr"
  echo "  monitor-apply.sh               # auto-apply saved matching layout"
  echo
fi

if [[ "$INSTALL_TAILSCALE" -eq 1 ]]; then
  echo "Tailscale:"
  echo "  sudo tailscale up"
  echo
fi

echo "Reaper:"
echo "  Download and install the Linux build from reaper.fm manually."
echo "  Recommended first test: run audio-status.sh, open qpwgraph, then set Reaper audio system to JACK/PipeWire JACK."
echo
ok "Done."
