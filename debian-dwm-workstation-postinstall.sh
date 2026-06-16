#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# NIRUCON Debian 13 dwm/Reaper Workstation Postinstall
# Target: Debian 13 Stable/Trixie
#
# Installs:
# - dwm, st, dmenu, slock from nirucon/suckless
# - lookandfeel from nirucon/suckless_lookandfeel
# - SDDM login session
# - English system locale + Swedish keyboard
# - NetworkManager laptop/workstation setup
# - PipeWire/WirePlumber audio stack for Reaper
# - xss-lock + slock
# - Nerd Font
# - Tailscale optional
# - Signal optional
# - Spotify via Flatpak optional
# - Basic pro-audio/dev/media tools
#
# Run as normal user, not root.
# =============================================================================

SUCKLESS_REPO="https://github.com/nirucon/suckless.git"
LOOKANDFEEL_REPO="https://github.com/nirucon/suckless_lookandfeel.git"

SUCKLESS_DIR="$HOME/.config/suckless"
LOOKANDFEEL_DIR="$HOME/.cache/dwm-setup/lookandfeel"

SESSION_WRAPPER="/usr/local/bin/dwm-session"
SESSION_DESKTOP="/usr/share/xsessions/dwm.desktop"

LOCAL_BIN="$HOME/.local/bin"
LOCAL_SHARE="$HOME/.local/share"
XINITRC_DIR="$HOME/.config/xinitrc.d"

say()  { printf '\033[1;34m[postinstall]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; }

trap 'fail "Aborted at line $LINENO while running: ${BASH_COMMAND:-unknown}"' ERR

if [[ "$EUID" -eq 0 ]]; then
  fail "Run as normal user, not root."
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  fail "sudo saknas. Installera sudo och lägg användaren i sudo-gruppen först."
  exit 1
fi

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

# -----------------------------------------------------------------------------
# Options
# -----------------------------------------------------------------------------

INSTALL_TAILSCALE=0
INSTALL_SIGNAL=0
INSTALL_SPOTIFY_FLATPAK=0
INSTALL_REAPER_DEPS=1
PURGE_PLASMA=0
PATCH_STATUSBAR=1

echo
say "NIRUCON Debian 13 dwm/Reaper Workstation Postinstall"
echo

ask_yes_no "Install Tailscale?" "Y" && INSTALL_TAILSCALE=1
ask_yes_no "Install Signal Desktop?" "Y" && INSTALL_SIGNAL=1
ask_yes_no "Install Spotify via Flatpak?" "N" && INSTALL_SPOTIFY_FLATPAK=1
ask_yes_no "Purge Plasma/KDE desktop packages if present, but keep SDDM?" "N" && PURGE_PLASMA=1
ask_yes_no "Patch dwm-status.sh for Debian where needed?" "Y" && PATCH_STATUSBAR=1 || PATCH_STATUSBAR=0

# -----------------------------------------------------------------------------
# System update
# -----------------------------------------------------------------------------

say "Updating Debian..."
sudo apt update
sudo apt full-upgrade -y

# -----------------------------------------------------------------------------
# Base packages
# -----------------------------------------------------------------------------

say "Installing base dwm/workstation packages..."

sudo apt install -y \
  build-essential gcc make pkg-config git curl wget rsync unzip zip tar tree \
  findutils coreutils grep sed gawk diffutils file xdg-utils dbus-x11 \
  ca-certificates gnupg lsb-release software-properties-common \
  xorg xinit x11-xserver-utils x11-utils x11-xkb-utils xclip xsel \
  sddm network-manager network-manager-gnome rfkill iw wireless-tools \
  libx11-dev libxft-dev libxinerama-dev libxrandr-dev libxext-dev \
  libxrender-dev libxfixes-dev libharfbuzz-dev libimlib2-dev \
  fontconfig fonts-dejavu fonts-noto fonts-noto-color-emoji fonts-font-awesome \
  fonts-jetbrains-mono \
  feh picom rofi dunst libnotify-bin \
  kitty maim slop brightnessctl playerctl pavucontrol \
  pipewire pipewire-alsa pipewire-pulse wireplumber pipewire-jack qpwgraph \
  alsa-utils alsa-ucm-conf rtkit \
  pcmanfm thunar thunar-archive-plugin gvfs gvfs-backends \
  udisks2 udiskie blueman xss-lock \
  fastfetch btop htop glances ncdu duf jq fzf ripgrep fd-find pv \
  neovim vim micro \
  mpv vlc cmus ffmpeg ffmpegthumbnailer gimp imagemagick sxiv \
  arandr lxappearance filelight unrar p7zip-full \
  nextcloud-desktop \
  flatpak

# -----------------------------------------------------------------------------
# Reaper / pro audio packages
# -----------------------------------------------------------------------------

if [[ "$INSTALL_REAPER_DEPS" -eq 1 ]]; then
  say "Installing Reaper/pro-audio support packages..."

  sudo apt install -y \
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
    sox

  say "Adding user to audio/video groups..."
  sudo usermod -aG audio,video "$USER" || true

  say "Setting basic realtime audio limits..."
  sudo tee /etc/security/limits.d/audio.conf >/dev/null <<'EOF'
@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice      -19
EOF
fi

# -----------------------------------------------------------------------------
# Firmware / microcode
# -----------------------------------------------------------------------------

say "Installing firmware and microcode..."

sudo apt install -y firmware-linux firmware-misc-nonfree || true

if lscpu | grep -qi intel; then
  sudo apt install -y intel-microcode || true
elif lscpu | grep -qi amd; then
  sudo apt install -y amd64-microcode || true
fi

# -----------------------------------------------------------------------------
# Locale / keyboard
# -----------------------------------------------------------------------------

say "Setting English system locale and Swedish keyboard..."

sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sudo sed -i 's/^# *sv_SE.UTF-8 UTF-8/sv_SE.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
sudo update-locale LANG=en_US.UTF-8
sudo localectl set-x11-keymap se || true

rm -f "$HOME/.config/plasma-localerc" 2>/dev/null || true
mkdir -p "$HOME/.config"
printf 'en_US\n' > "$HOME/.config/user-dirs.locale"
LANG=en_US.UTF-8 xdg-user-dirs-update --force || true

# -----------------------------------------------------------------------------
# Services
# -----------------------------------------------------------------------------

say "Enabling services..."

sudo systemctl enable NetworkManager
sudo systemctl enable sddm

systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || true

# -----------------------------------------------------------------------------
# NetworkManager cleanup
# -----------------------------------------------------------------------------

say "Preparing NetworkManager to own WiFi/Ethernet..."

if [[ -f /etc/network/interfaces ]]; then
  sudo cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d-%H%M%S)"
  sudo tee /etc/network/interfaces >/dev/null <<'EOF'
# Managed for NetworkManager desktop use.
# Loopback only. WiFi/Ethernet should be handled by NetworkManager.

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

# -----------------------------------------------------------------------------
# Clone/build suckless
# -----------------------------------------------------------------------------

say "Cloning/updating suckless repo..."

mkdir -p "$(dirname "$SUCKLESS_DIR")"

if [[ -d "$SUCKLESS_DIR/.git" ]]; then
  git -C "$SUCKLESS_DIR" fetch --all --prune
  git -C "$SUCKLESS_DIR" pull --ff-only || true
else
  git clone "$SUCKLESS_REPO" "$SUCKLESS_DIR"
fi

say "Applying Debian slock nobody/nogroup fix..."

if [[ -f "$SUCKLESS_DIR/slock/config.h" ]]; then
  sed -i 's/static const char \*group = "nobody";/static const char *group = "nogroup";/' "$SUCKLESS_DIR/slock/config.h"
fi

if [[ -f "$SUCKLESS_DIR/slock/config.def.h" ]]; then
  sed -i 's/static const char \*group = "nobody";/static const char *group = "nogroup";/' "$SUCKLESS_DIR/slock/config.def.h"
fi

say "Building dwm, dmenu, st, slock..."

for app in dwm dmenu st slock; do
  if [[ -d "$SUCKLESS_DIR/$app" ]]; then
    say "Building $app..."
    make -C "$SUCKLESS_DIR/$app" clean
    make -C "$SUCKLESS_DIR/$app" -j"$(nproc)"
    sudo make -C "$SUCKLESS_DIR/$app" PREFIX=/usr/local install
    ok "$app installed"
  else
    warn "Missing component: $app"
  fi
done

# -----------------------------------------------------------------------------
# Look and feel
# -----------------------------------------------------------------------------

say "Cloning/updating lookandfeel repo..."

mkdir -p "$(dirname "$LOOKANDFEEL_DIR")"

if [[ -d "$LOOKANDFEEL_DIR/.git" ]]; then
  git -C "$LOOKANDFEEL_DIR" fetch --all --prune
  git -C "$LOOKANDFEEL_DIR" pull --ff-only || true
else
  git clone "$LOOKANDFEEL_REPO" "$LOOKANDFEEL_DIR"
fi

say "Deploying lookandfeel files..."

mkdir -p "$HOME/.config" "$LOCAL_BIN" "$LOCAL_SHARE"

if [[ -d "$LOOKANDFEEL_DIR/config" ]]; then
  rsync -a "$LOOKANDFEEL_DIR/config/" "$HOME/.config/"
fi

if [[ -d "$LOOKANDFEEL_DIR/local/bin" ]]; then
  rsync -a "$LOOKANDFEEL_DIR/local/bin/" "$LOCAL_BIN/"
  chmod +x "$LOCAL_BIN/"* 2>/dev/null || true
fi

if [[ -d "$LOOKANDFEEL_DIR/local/share" ]]; then
  rsync -a "$LOOKANDFEEL_DIR/local/share/" "$LOCAL_SHARE/"
fi

touch "$HOME/.bash_profile"
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bash_profile" || \
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bash_profile"

# -----------------------------------------------------------------------------
# Nerd Font
# -----------------------------------------------------------------------------

say "Installing JetBrainsMono Nerd Font..."

mkdir -p "$HOME/.local/share/fonts/JetBrainsMonoNerd"
TMPFONT="$(mktemp -d)"

if wget -q -O "$TMPFONT/JetBrainsMono.zip" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"; then
  unzip -oq "$TMPFONT/JetBrainsMono.zip" -d "$HOME/.local/share/fonts/JetBrainsMonoNerd"
  fc-cache -fv >/dev/null
  ok "JetBrainsMono Nerd Font installed"
else
  warn "Could not download JetBrainsMono Nerd Font"
fi

rm -rf "$TMPFONT"

# -----------------------------------------------------------------------------
# Debian patch for dwm-status.sh
# -----------------------------------------------------------------------------

if [[ "$PATCH_STATUSBAR" -eq 1 && -f "$LOCAL_BIN/dwm-status.sh" ]]; then
  say "Patching dwm-status.sh for Debian..."

  cp "$LOCAL_BIN/dwm-status.sh" "$LOCAL_BIN/dwm-status.sh.bak.$(date +%Y%m%d-%H%M%S)"

  # Make PATH include sbin tools too.
  sed -i 's|export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"|export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"|' "$LOCAL_BIN/dwm-status.sh"

  # Debian has no checkupdates. Disable Arch-specific update counter by default.
  sed -i 's/^SHOW_UPDATES=1/SHOW_UPDATES=0/' "$LOCAL_BIN/dwm-status.sh"

  chmod +x "$LOCAL_BIN/dwm-status.sh"
fi

# -----------------------------------------------------------------------------
# SDDM / dwm session
# -----------------------------------------------------------------------------

say "Creating dwm session wrapper..."

sudo tee "$SESSION_WRAPPER" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm

[[ -r "$HOME/.profile" ]] && . "$HOME/.profile"
[[ -r "$HOME/.bash_profile" ]] && . "$HOME/.bash_profile"
[[ -r "$HOME/.bashrc" ]] && . "$HOME/.bashrc"

if command -v xrdb >/dev/null 2>&1 && [[ -r "$HOME/.Xresources" ]]; then
  xrdb -merge "$HOME/.Xresources"
fi

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v dbus-run-session >/dev/null 2>&1 && [[ "${1:-}" != "--dbus-started" ]]; then
  exec dbus-run-session "$0" --dbus-started "$@"
fi

[[ "${1:-}" == "--dbus-started" ]] && shift || true

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

# -----------------------------------------------------------------------------
# xinitrc hooks
# -----------------------------------------------------------------------------

say "Creating xinitrc.d hooks..."

mkdir -p "$XINITRC_DIR"

cat > "$XINITRC_DIR/10-env.sh" <<'EOF'
#!/usr/bin/env bash
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm
command -v setxkbmap >/dev/null 2>&1 && setxkbmap se
command -v xsetroot >/dev/null 2>&1 && xsetroot -solid "#111111"
EOF

cat > "$XINITRC_DIR/20-lookandfeel.sh" <<'EOF'
#!/usr/bin/env bash

command -v dunst >/dev/null 2>&1 && ! pgrep -x dunst >/dev/null 2>&1 && dunst &

if command -v picom >/dev/null 2>&1 && ! pgrep -x picom >/dev/null 2>&1; then
  if [[ -f "$HOME/.config/picom/picom.conf" ]]; then
    picom --config "$HOME/.config/picom/picom.conf" --daemon 2>/dev/null || picom --daemon &
  else
    picom --daemon &
  fi
fi

command -v blueman-applet >/dev/null 2>&1 && ! pgrep -x blueman-applet >/dev/null 2>&1 && blueman-applet &
command -v udiskie >/dev/null 2>&1 && ! pgrep -x udiskie >/dev/null 2>&1 && udiskie --tray &
command -v nextcloud >/dev/null 2>&1 && ! pgrep -x nextcloud >/dev/null 2>&1 && nextcloud --background &
EOF

cat > "$XINITRC_DIR/30-wallpaper.sh" <<'EOF'
#!/usr/bin/env bash

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

if [[ -x "$HOME/.local/bin/dwm-status.sh" ]]; then
  pkill -u "$USER" -f "$HOME/.local/bin/dwm-status.sh" 2>/dev/null || true
  "$HOME/.local/bin/dwm-status.sh" &
fi
EOF

cat > "$XINITRC_DIR/50-lock.sh" <<'EOF'
#!/usr/bin/env bash

if command -v xss-lock >/dev/null 2>&1 && command -v slock >/dev/null 2>&1 && ! pgrep -x xss-lock >/dev/null 2>&1; then
  xss-lock slock &
fi
EOF

cat > "$XINITRC_DIR/60-audio.sh" <<'EOF'
#!/usr/bin/env bash

systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
EOF

cat > "$XINITRC_DIR/90-local.sh" <<'EOF'
#!/usr/bin/env bash
# Add local machine-specific startup commands here.
EOF

chmod +x "$XINITRC_DIR/"*.sh

say "Creating .xinitrc fallback..."

cat > "$HOME/.xinitrc" <<'EOF'
#!/usr/bin/env bash
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm

[[ -r "$HOME/.profile" ]] && . "$HOME/.profile"
[[ -r "$HOME/.bash_profile" ]] && . "$HOME/.bash_profile"
[[ -r "$HOME/.bashrc" ]] && . "$HOME/.bashrc"

if command -v xrdb >/dev/null 2>&1 && [[ -r "$HOME/.Xresources" ]]; then
  xrdb -merge "$HOME/.Xresources"
fi

for f in "$HOME/.config/xinitrc.d/"*.sh; do
  [[ -r "$f" ]] && . "$f"
done

exec dwm
EOF

chmod +x "$HOME/.xinitrc"

# -----------------------------------------------------------------------------
# Optional apps
# -----------------------------------------------------------------------------

if [[ "$INSTALL_SIGNAL" -eq 1 ]]; then
  say "Installing Signal Desktop..."

  wget -O- https://updates.signal.org/desktop/apt/keys.asc \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/signal-desktop-keyring.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/signal-desktop-keyring.gpg] https://updates.signal.org/desktop/apt xenial main" \
    | sudo tee /etc/apt/sources.list.d/signal-xenial.list >/dev/null

  sudo apt update
  sudo apt install -y signal-desktop || warn "Signal installation failed"
fi

if [[ "$INSTALL_SPOTIFY_FLATPAK" -eq 1 ]]; then
  say "Installing Spotify via Flatpak..."

  sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak install -y flathub com.spotify.Client || warn "Spotify Flatpak installation failed"
fi

if [[ "$INSTALL_TAILSCALE" -eq 1 ]]; then
  say "Installing Tailscale..."

  curl -fsSL https://tailscale.com/install.sh | sh
  sudo systemctl enable --now tailscaled
  warn "Run after reboot/login if not already authenticated: sudo tailscale up"
fi

# -----------------------------------------------------------------------------
# Optional Plasma purge
# -----------------------------------------------------------------------------

if [[ "$PURGE_PLASMA" -eq 1 ]]; then
  say "Purging Plasma/KDE desktop packages while keeping SDDM..."

  sudo apt purge -y \
    plasma-desktop plasma-workspace plasma-discover plasma-discover-backend-fwupd \
    plasma-disks plasma-firewall plasma-nm plasma-pa plasma-systemmonitor \
    plasma-thunderbolt plasma-vault plasma-welcome \
    kde-spectacle gwenview ark || true

  sudo apt autoremove --purge -y
fi

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------

say "Final cleanup..."

sudo apt autoremove --purge -y
sudo apt clean

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------

echo
say "Verification"
echo "Debian:          $(cat /etc/debian_version 2>/dev/null || echo unknown)"
echo "Kernel:          $(uname -r)"
echo "Locale file:     $(grep '^LANG=' /etc/default/locale 2>/dev/null || echo missing)"
echo "X11 keymap:      $(localectl status 2>/dev/null | grep 'X11 Layout' || echo unknown)"
echo "dwm:             $(command -v dwm || echo missing)"
echo "st:              $(command -v st || echo missing)"
echo "dmenu:           $(command -v dmenu || echo missing)"
echo "slock:           $(command -v slock || echo missing)"
echo "kitty:           $(command -v kitty || echo missing)"
echo "rofi:            $(command -v rofi || echo missing)"
echo "picom:           $(command -v picom || echo missing)"
echo "dunst:           $(command -v dunst || echo missing)"
echo "xss-lock:        $(command -v xss-lock || echo missing)"
echo "NetworkManager:  $(systemctl is-enabled NetworkManager 2>/dev/null || echo unknown)"
echo "SDDM:            $(systemctl is-enabled sddm 2>/dev/null || echo unknown)"
echo "PipeWire:        $(command -v pipewire || echo missing)"
echo "WirePlumber:     $(command -v wireplumber || echo missing)"
echo "Nerd Font:       $(fc-match 'JetBrainsMono Nerd Font' | head -1)"
echo

if fc-match "JetBrainsMono Nerd Font" | grep -qi "JetBrainsMono"; then
  ok "Nerd Font appears available"
else
  warn "Nerd Font may not be matched correctly"
fi

if command -v slock >/dev/null 2>&1; then
  ok "slock installed. Test manually after login: slock"
fi

echo
ok "Postinstall complete."
echo
echo "Recommended next step:"
echo "  sudo reboot"
echo
echo "After reboot:"
echo "  1. Choose dwm in SDDM."
echo "  2. Connect WiFi via nmcli/nm-applet if needed."
echo "  3. Run: sudo tailscale up   # if Tailscale was installed"
echo "  4. Verify:"
echo "       nmcli device status"
echo "       pgrep -a picom"
echo "       pgrep -a dunst"
echo "       pgrep -a xss-lock"
echo "       pactl info"
echo
echo "Reaper:"
echo "  Download Linux build from reaper.fm and install manually."
echo "  Audio stack installed: PipeWire + WirePlumber + JACK compatibility."
