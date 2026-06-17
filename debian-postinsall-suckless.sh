#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# NIRUCON Debian 13 dwm Postinstall v1.6.2
# =============================================================================
#
# Target:
#   Debian 13 / Trixie
#
# Purpose:
#   Install a clean, minimal, dwm-based X11 desktop on Debian with SDDM,
#   NIRUCON suckless tools, look and feel files, fish shell, optional laptop
#   packages and optional audio workstation optimization.
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

print_header() {
  clear || true
  echo
  echo "============================================================"
  echo "  NIRUCON Debian 13 dwm Postinstall"
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

INSTALL_AUDIO=0
INSTALL_TAILSCALE=0
INSTALL_SIGNAL=0
INSTALL_HELIUM=0
SET_FISH_DEFAULT=0
PATCH_STATUSBAR=1
PURGE_PLASMA=0

echo
ask_yes_no "Apply audio optimization and install Reaper/audio workstation tools?" "Y" && INSTALL_AUDIO=1
ask_yes_no "Install Tailscale?" "Y" && INSTALL_TAILSCALE=1
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

echo "Audio optimization: $([[ "$INSTALL_AUDIO" -eq 1 ]] && echo yes || echo no)"
echo "Tailscale:          $([[ "$INSTALL_TAILSCALE" -eq 1 ]] && echo yes || echo no)"
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
  network-manager network-manager-gnome rfkill iw wireless-tools \
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
  neovim vim micro \
  mpv vlc cmus kew ffmpeg ffmpegthumbnailer gimp imagemagick sxiv \
  arandr lxappearance papirus-icon-theme adwaita-icon-theme unrar-free p7zip-full \
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

if [[ "$INSTALL_AUDIO" -eq 1 ]]; then
  phase "Installing audio workstation packages"

  sudo apt install "${APT_FLAGS[@]}" \
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

  phase "Applying realtime audio configuration"

  say "Adding $USER to audio and video groups..."
  sudo usermod -aG audio,video "$USER" || true

  say "Writing realtime limits to /etc/security/limits.d/audio.conf..."
  sudo tee /etc/security/limits.d/audio.conf >/dev/null <<'EOF'
# Realtime audio limits for low-latency audio work.
# The user must be a member of the audio group.
@audio   -  rtprio     98
@audio   -  memlock    unlimited
@audio   -  nice      -19
EOF

  say "Writing basic audio sysctl tuning..."
  sudo tee /etc/sysctl.d/99-audio.conf >/dev/null <<'EOF'
# Basic desktop/audio tuning.
vm.swappiness=10
fs.inotify.max_user_watches=524288
EOF

  sudo sysctl --system >/dev/null || true

  mkdir -p "$LOCAL_BIN"

  cat > "$LOCAL_BIN/audio-performance.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Switch CPU governor to performance mode for audio recording/mixing sessions.
sudo cpupower frequency-set -g performance
echo "CPU governor set to performance."
EOF

  cat > "$LOCAL_BIN/audio-balanced.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Switch CPU governor back to a balanced mode after audio work.
sudo cpupower frequency-set -g schedutil 2>/dev/null || sudo cpupower frequency-set -g ondemand
echo "CPU governor set to balanced/schedutil."
EOF

  chmod +x "$LOCAL_BIN/audio-performance.sh" "$LOCAL_BIN/audio-balanced.sh"

  ok "Audio workstation packages and tuning applied."
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
# Debian-safe fish and terminal configuration
# -----------------------------------------------------------------------------

phase "Writing Debian-safe fish and terminal configuration"

mkdir -p "$HOME/.config/fish" "$HOME/.config/alacritty" "$HOME/.config/kitty"

if [[ -f "$HOME/.config/fish/config.fish" ]]; then
  cp "$HOME/.config/fish/config.fish" "$HOME/.config/fish/config.fish.bak.$(date +%Y%m%d-%H%M%S)"
fi

cat > "$HOME/.config/fish/config.fish" <<'EOF'
# NIRUCON Debian fish config.
# Debian-safe: no CachyOS, Arch, paru or yay assumptions.

# No default Fish welcome/help text.
set -g fish_greeting ""

# Environment.
fish_add_path -g $HOME/.local/bin /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /bin /sbin
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx PAGER less
set -gx MANPAGER "less -R"

# Clean terminal behaviour.
set -gx LESS "-R --use-color -Dd+r -Du+b"
set -gx BAT_THEME "base16"

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
    alias ll='eza -lah --icons=auto --group-directories-first --git'
    alias la='eza -a --icons=auto --group-directories-first'
    alias lt='eza --tree --icons=auto --level=2'
    alias tree='eza --tree --icons=auto'
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

# Useful shortcuts.
alias grep='grep --color=auto'
alias update='sudo apt update && sudo apt full-upgrade -y'
alias cleanup='sudo apt autoremove --purge -y && sudo apt clean'
alias ports='ss -tulpn'
alias df='df -h'
alias free='free -h'
alias music='kew'
alias gs='git status'
alias gp='git pull'
alias gcm='git commit -m'

# Optional: show system info manually with "ff".
if command -q fastfetch
    alias ff='fastfetch'
end

# Key bindings and fzf integration.
if status is-interactive
    if command -q fzf
        fzf --fish | source 2>/dev/null
    end
end
EOF

if [[ ! -f "$HOME/.config/starship.toml" ]]; then
  cat > "$HOME/.config/starship.toml" <<'EOF'
add_newline = false
format = "$directory$git_branch$git_status$cmd_duration$line_break$character"

[directory]
truncation_length = 4
truncate_to_repo = false
style = "bold cyan"

[git_branch]
format = "[$symbol$branch]($style) "
symbol = " "
style = "bold purple"

[git_status]
format = "[$all_status$ahead_behind]($style) "
style = "bold red"

[cmd_duration]
min_time = 2000
format = "[$duration]($style) "
style = "yellow"

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[✖](bold red)"
EOF
fi

if [[ ! -f "$HOME/.config/alacritty/alacritty.toml" ]]; then
  cat > "$HOME/.config/alacritty/alacritty.toml" <<'EOF'
[window]
padding = { x = 8, y = 8 }
dynamic_padding = true
opacity = 0.94

[font]
normal = { family = "JetBrainsMono Nerd Font", style = "Regular" }
bold = { family = "JetBrainsMono Nerd Font", style = "Bold" }
italic = { family = "JetBrainsMono Nerd Font", style = "Italic" }
size = 11.0

[terminal.shell]
program = "/usr/bin/fish"
EOF
fi

if [[ ! -f "$HOME/.config/kitty/kitty.conf" ]]; then
  cat > "$HOME/.config/kitty/kitty.conf" <<'EOF'
# NIRUCON Kitty config for Debian/dwm.

font_family JetBrainsMono Nerd Font
bold_font auto
italic_font auto
bold_italic_font auto
font_size 11.0

shell /usr/bin/fish

scrollback_lines 50000
enable_audio_bell no
confirm_os_window_close 0

background_opacity 0.94
dynamic_background_opacity yes
window_padding_width 8

copy_on_select clipboard
strip_trailing_spaces smart

cursor_shape beam
cursor_blink_interval 0.5

tab_bar_edge bottom
tab_bar_style powerline
EOF
fi

# Also remove the Fish greeting at universal-variable level for existing users.
if command -v fish >/dev/null 2>&1; then
  fish -c 'set -U fish_greeting ""' 2>/dev/null || true
fi

ok "Debian-safe fish, Kitty and Alacritty configuration written."

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
# Optional applications
# -----------------------------------------------------------------------------

install_signal() {
  phase "Installing Signal Desktop"

  wget -O- https://updates.signal.org/desktop/apt/keys.asc \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/signal-desktop-keyring.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/signal-desktop-keyring.gpg] https://updates.signal.org/desktop/apt xenial main" \
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

echo "Optional applications"
echo "  Helium:          $(command -v helium-browser || command -v helium || echo optional/missing)"
echo "  Signal:          $(command -v signal-desktop || echo optional/missing)"
echo "  Tailscale:       $(command -v tailscale || echo optional/missing)"
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

if [[ "$INSTALL_AUDIO" -eq 1 ]]; then
  ok "Audio profile installed."
  warn "You must log out/reboot before audio group membership is active."
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

if [[ "$INSTALL_AUDIO" -eq 1 ]]; then
  echo "Audio workstation commands:"
  echo "  audio-performance.sh   # use before recording/mixing"
  echo "  audio-balanced.sh      # use after audio work"
  echo
fi

if [[ "$INSTALL_TAILSCALE" -eq 1 ]]; then
  echo "Tailscale:"
  echo "  sudo tailscale up"
  echo
fi

echo "Reaper:"
echo "  Download and install the Linux build from reaper.fm manually."
echo
ok "Done."
