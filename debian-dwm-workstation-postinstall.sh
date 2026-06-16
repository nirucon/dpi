#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# NIRUCON Debian 13 dwm Postinstall
# Profiles:
#   1) Laptop
#   2) Audio Workstation / Reaper
#   3) Both
#
# Target: Debian 13 / Trixie
# Run as normal user, not root.
# =============================================================================

SUCKLESS_REPO="https://github.com/nirucon/suckless.git"
LOOKANDFEEL_REPO="https://github.com/nirucon/suckless_lookandfeel.git"

SUCKLESS_DIR="$HOME/.config/suckless"
LOOKANDFEEL_DIR="$HOME/.cache/dwm-setup/lookandfeel"

LOCAL_BIN="$HOME/.local/bin"
LOCAL_SHARE="$HOME/.local/share"
XINITRC_DIR="$HOME/.config/xinitrc.d"

SESSION_WRAPPER="/usr/local/bin/dwm-session"
SESSION_DESKTOP="/usr/share/xsessions/dwm.desktop"

NC="\033[0m"; GRN="\033[1;32m"; RED="\033[1;31m"; YLW="\033[1;33m"; BLU="\033[1;34m"; MAG="\033[1;35m"
say()  { printf "${BLU}[postinstall]${NC} %s\n" "$*"; }
step() { printf "${MAG}[phase]${NC} %s\n" "$*"; }
ok()   { printf "${GRN}[ ok ]${NC} %s\n" "$*"; }
warn() { printf "${YLW}[warn]${NC} %s\n" "$*"; }
fail() { printf "${RED}[fail]${NC} %s\n" "$*" >&2; }

trap 'fail "Aborted at line $LINENO while running: ${BASH_COMMAND:-unknown}"' ERR

[[ "$EUID" -ne 0 ]] || { fail "Run as normal user, not root."; exit 1; }
command -v sudo >/dev/null 2>&1 || { fail "sudo saknas."; exit 1; }

ask_yes_no() {
  local prompt="$1" default="${2:-N}" answer
  if [[ "$default" == "Y" ]]; then
    read -r -p "$prompt [Y/n] " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
  else
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
  fi
}

echo
say "NIRUCON Debian 13 dwm Postinstall"
echo
echo "Select profile:"
echo "  1) Laptop"
echo "  2) Audio Workstation / Reaper"
echo "  3) Both"
read -r -p "Choice [1/2/3]: " PROFILE_CHOICE

IS_LAPTOP=0
IS_AUDIO=0

case "$PROFILE_CHOICE" in
  1) IS_LAPTOP=1 ;;
  2) IS_AUDIO=1 ;;
  3) IS_LAPTOP=1; IS_AUDIO=1 ;;
  *) fail "Invalid profile choice."; exit 1 ;;
esac

INSTALL_TAILSCALE=0
INSTALL_SIGNAL=0
INSTALL_SPOTIFY=0
INSTALL_HELIUM=0
PURGE_PLASMA=0
PATCH_STATUSBAR=1

ask_yes_no "Install Tailscale?" "Y" && INSTALL_TAILSCALE=1
ask_yes_no "Install Signal Desktop?" "Y" && INSTALL_SIGNAL=1
ask_yes_no "Install Spotify via Debian repo/.deb method?" "Y" && INSTALL_SPOTIFY=1
ask_yes_no "Install Helium Browser from latest .deb release?" "Y" && INSTALL_HELIUM=1
ask_yes_no "Patch dwm-status.sh for Debian?" "Y" && PATCH_STATUSBAR=1 || PATCH_STATUSBAR=0
ask_yes_no "Purge Plasma/KDE desktop packages if present, but keep SDDM?" "N" && PURGE_PLASMA=1

step "Updating Debian"
sudo apt update
sudo apt full-upgrade -y

step "Installing base system packages"
sudo apt install -y \
  build-essential gcc make pkg-config git curl wget rsync unzip zip tar tree \
  findutils coreutils grep sed gawk diffutils file xdg-utils dbus-x11 \
  ca-certificates gnupg lsb-release apt-transport-https \
  xorg xinit x11-xserver-utils x11-utils x11-xkb-utils xclip xsel \
  sddm network-manager network-manager-gnome rfkill iw wireless-tools \
  libx11-dev libxft-dev libxinerama-dev libxrandr-dev libxext-dev \
  libxrender-dev libxfixes-dev libharfbuzz-dev libimlib2-dev \
  fontconfig fonts-dejavu fonts-noto fonts-noto-color-emoji fonts-font-awesome \
  fonts-jetbrains-mono \
  feh picom rofi dunst libnotify-bin \
  kitty maim slop brightnessctl playerctl pavucontrol \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber qpwgraph \
  alsa-utils alsa-ucm-conf rtkit \
  pcmanfm thunar thunar-archive-plugin gvfs gvfs-backends \
  udisks2 udiskie blueman xss-lock \
  fastfetch btop htop glances ncdu duf jq fzf ripgrep fd-find pv \
  neovim vim micro \
  mpv vlc cmus ffmpeg ffmpegthumbnailer gimp imagemagick sxiv \
  arandr lxappearance filelight unrar p7zip-full \
  nextcloud-desktop \
  upower acpi

if [[ "$IS_LAPTOP" -eq 1 ]]; then
  step "Installing laptop power packages"
  sudo apt install -y power-profiles-daemon acpid
  sudo systemctl enable acpid
  sudo systemctl enable power-profiles-daemon
fi

if [[ "$IS_AUDIO" -eq 1 ]]; then
  step "Installing Reaper/audio workstation packages"
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
    sox \
    linux-cpupower \
    irqbalance

  sudo systemctl enable irqbalance

  step "Applying realtime audio limits"
  sudo usermod -aG audio,video "$USER" || true

  sudo tee /etc/security/limits.d/audio.conf >/dev/null <<'EOF'
@audio   -  rtprio     98
@audio   -  memlock    unlimited
@audio   -  nice      -19
EOF

  sudo tee /etc/sysctl.d/99-audio.conf >/dev/null <<'EOF'
vm.swappiness=10
fs.inotify.max_user_watches=524288
EOF

  sudo sysctl --system >/dev/null || true

  mkdir -p "$LOCAL_BIN"

  cat > "$LOCAL_BIN/audio-performance.sh" <<'EOF'
#!/usr/bin/env bash
sudo cpupower frequency-set -g performance
echo "CPU governor set to performance."
EOF

  cat > "$LOCAL_BIN/audio-balanced.sh" <<'EOF'
#!/usr/bin/env bash
sudo cpupower frequency-set -g schedutil 2>/dev/null || sudo cpupower frequency-set -g ondemand
echo "CPU governor set to balanced/schedutil."
EOF

  chmod +x "$LOCAL_BIN/audio-performance.sh" "$LOCAL_BIN/audio-balanced.sh"
fi

step "Installing firmware and microcode"
sudo apt install -y firmware-linux firmware-misc-nonfree || true

if lscpu | grep -qi intel; then
  sudo apt install -y intel-microcode || true
elif lscpu | grep -qi amd; then
  sudo apt install -y amd64-microcode || true
fi

step "Setting English locale and Swedish keyboard"
sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sudo sed -i 's/^# *sv_SE.UTF-8 UTF-8/sv_SE.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
sudo update-locale LANG=en_US.UTF-8
sudo localectl set-x11-keymap se || true

rm -f "$HOME/.config/plasma-localerc" 2>/dev/null || true
mkdir -p "$HOME/.config"
printf 'en_US\n' > "$HOME/.config/user-dirs.locale"
LANG=en_US.UTF-8 xdg-user-dirs-update --force || true

step "Enabling services"
sudo systemctl enable NetworkManager
sudo systemctl enable sddm
systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null || true

step "Preparing NetworkManager"
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

step "Cloning/updating suckless"
mkdir -p "$(dirname "$SUCKLESS_DIR")"

if [[ -d "$SUCKLESS_DIR/.git" ]]; then
  git -C "$SUCKLESS_DIR" fetch --all --prune
  git -C "$SUCKLESS_DIR" pull --ff-only || true
else
  git clone "$SUCKLESS_REPO" "$SUCKLESS_DIR"
fi

step "Applying Debian slock fix: nobody/nogroup"
if [[ -f "$SUCKLESS_DIR/slock/config.h" ]]; then
  sed -i 's/static const char \*group = "nobody";/static const char *group = "nogroup";/' "$SUCKLESS_DIR/slock/config.h"
fi
if [[ -f "$SUCKLESS_DIR/slock/config.def.h" ]]; then
  sed -i 's/static const char \*group = "nobody";/static const char *group = "nogroup";/' "$SUCKLESS_DIR/slock/config.def.h"
fi

step "Building dwm, dmenu, st, slock"
for app in dwm dmenu st slock; do
  if [[ -d "$SUCKLESS_DIR/$app" ]]; then
    say "Building $app"
    make -C "$SUCKLESS_DIR/$app" clean
    make -C "$SUCKLESS_DIR/$app" -j"$(nproc)"
    sudo make -C "$SUCKLESS_DIR/$app" PREFIX=/usr/local install
    ok "$app installed"
  else
    warn "Missing component: $app"
  fi
done

step "Cloning/updating lookandfeel"
mkdir -p "$(dirname "$LOOKANDFEEL_DIR")"

if [[ -d "$LOOKANDFEEL_DIR/.git" ]]; then
  git -C "$LOOKANDFEEL_DIR" fetch --all --prune
  git -C "$LOOKANDFEEL_DIR" pull --ff-only || true
else
  git clone "$LOOKANDFEEL_REPO" "$LOOKANDFEEL_DIR"
fi

step "Deploying lookandfeel"
mkdir -p "$HOME/.config" "$LOCAL_BIN" "$LOCAL_SHARE"

[[ -d "$LOOKANDFEEL_DIR/config" ]] && rsync -a "$LOOKANDFEEL_DIR/config/" "$HOME/.config/"
[[ -d "$LOOKANDFEEL_DIR/local/bin" ]] && rsync -a "$LOOKANDFEEL_DIR/local/bin/" "$LOCAL_BIN/"
[[ -d "$LOOKANDFEEL_DIR/local/share" ]] && rsync -a "$LOOKANDFEEL_DIR/local/share/" "$LOCAL_SHARE/"
chmod +x "$LOCAL_BIN/"* 2>/dev/null || true

touch "$HOME/.bash_profile"
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bash_profile" || \
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bash_profile"

step "Installing JetBrainsMono Nerd Font"
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

if [[ "$PATCH_STATUSBAR" -eq 1 && -f "$LOCAL_BIN/dwm-status.sh" ]]; then
  step "Patching dwm-status.sh for Debian"
  cp "$LOCAL_BIN/dwm-status.sh" "$LOCAL_BIN/dwm-status.sh.bak.$(date +%Y%m%d-%H%M%S)"

  sed -i 's|export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"|export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"|' "$LOCAL_BIN/dwm-status.sh"
  sed -i 's/^SHOW_UPDATES=1/SHOW_UPDATES=0/' "$LOCAL_BIN/dwm-status.sh"

  chmod +x "$LOCAL_BIN/dwm-status.sh"
fi

step "Creating SDDM dwm session"
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

sudo mkdir -p /etc/sddm.conf.d
sudo tee /etc/sddm.conf.d/10-nirucon.conf >/dev/null <<'EOF'
[Users]
RememberLastUser=true

[General]
RememberLastSession=true
EOF

step "Creating xinitrc.d hooks"
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

step "Creating .xinitrc fallback"
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

install_signal() {
  step "Installing Signal Desktop"
  wget -O- https://updates.signal.org/desktop/apt/keys.asc \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/signal-desktop-keyring.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/signal-desktop-keyring.gpg] https://updates.signal.org/desktop/apt xenial main" \
    | sudo tee /etc/apt/sources.list.d/signal-xenial.list >/dev/null

  sudo apt update
  sudo apt install -y signal-desktop || warn "Signal installation failed"
}

install_spotify() {
  step "Installing Spotify via official Debian repo"

  sudo rm -f /etc/apt/sources.list.d/spotify.list
  sudo rm -f /usr/share/keyrings/spotify.gpg /etc/apt/keyrings/spotify.gpg

  sudo install -d -m 0755 /etc/apt/keyrings

  if curl -fsSL https://download.spotify.com/debian/pubkey_6224F9941A8AA6D1.gpg \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/spotify.gpg >/dev/null; then

    echo "deb [signed-by=/etc/apt/keyrings/spotify.gpg] https://repository.spotify.com stable non-free" \
      | sudo tee /etc/apt/sources.list.d/spotify.list >/dev/null

    if sudo apt update && sudo apt install -y spotify-client; then
      ok "Spotify installed"
    else
      warn "Spotify repo failed. Removing repo to avoid broken apt updates."
      sudo rm -f /etc/apt/sources.list.d/spotify.list
      sudo apt update || true
    fi
  else
    warn "Could not import Spotify key"
  fi
}

install_helium() {
  step "Installing Helium Browser from latest .deb release"

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

  if wget -O "$tmp/helium.deb" "$url"; then
    sudo apt install -y "$tmp/helium.deb" || warn "Helium installation failed"
  else
    warn "Could not download Helium .deb"
  fi

  rm -rf "$tmp"
}

[[ "$INSTALL_SIGNAL" -eq 1 ]] && install_signal
[[ "$INSTALL_SPOTIFY" -eq 1 ]] && install_spotify
[[ "$INSTALL_HELIUM" -eq 1 ]] && install_helium

if [[ "$INSTALL_TAILSCALE" -eq 1 ]]; then
  step "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo systemctl enable --now tailscaled
  warn "Run after reboot/login if needed: sudo tailscale up"
fi

if [[ "$PURGE_PLASMA" -eq 1 ]]; then
  step "Purging Plasma/KDE desktop packages while keeping SDDM"
  sudo apt purge -y \
    plasma-desktop plasma-workspace plasma-discover plasma-discover-backend-fwupd \
    plasma-disks plasma-firewall plasma-nm plasma-pa plasma-systemmonitor \
    plasma-thunderbolt plasma-vault plasma-welcome \
    kde-spectacle gwenview ark || true
  sudo apt autoremove --purge -y
fi

step "Final cleanup"
sudo apt autoremove --purge -y
sudo apt clean

echo
step "Verification"
echo "Debian:          $(cat /etc/debian_version 2>/dev/null || echo unknown)"
echo "Kernel:          $(uname -r)"
echo "Locale:          $(grep '^LANG=' /etc/default/locale 2>/dev/null || echo missing)"
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
echo "Helium:          $(command -v helium-browser || command -v helium || echo optional/missing)"
echo "Spotify:         $(command -v spotify || echo optional/missing)"
echo "Signal:          $(command -v signal-desktop || echo optional/missing)"
echo "Tailscale:       $(command -v tailscale || echo optional/missing)"
echo

if fc-match "JetBrainsMono Nerd Font" | grep -qi "JetBrainsMono"; then
  ok "Nerd Font appears available"
else
  warn "Nerd Font may not be matched correctly"
fi

if [[ "$IS_AUDIO" -eq 1 ]]; then
  ok "Audio profile installed. After reboot, verify with: pactl info"
  warn "For recording sessions, run: audio-performance.sh"
fi

if [[ "$IS_LAPTOP" -eq 1 ]]; then
  ok "Laptop profile installed."
fi

ok "Postinstall complete."
echo
echo "Recommended next step:"
echo "  sudo reboot"
echo
echo "After reboot:"
echo "  Choose dwm in SDDM."
echo "  nmcli device status"
echo "  pgrep -a picom"
echo "  pgrep -a dunst"
echo "  pgrep -a xss-lock"
echo "  pactl info"
echo "  slock"
echo
echo "If Tailscale was installed:"
echo "  sudo tailscale up"
echo
echo "Reaper:"
echo "  Download and install Linux build from reaper.fm manually."
