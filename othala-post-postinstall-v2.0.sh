#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Othala post-postinstall v2.0
# =============================================================================
# Machine-specific finishing script for HP Z2 Tower G5 "othala" after the
# generic NIRUCON Debian/dwm postinstall.
#
# It configures only Othala-specific things:
#   - permanent data mounts by UUID
#   - PCManFM/GTK bookmarks for /mnt volumes
#   - Othala fixed xrandr layout
#   - SDDM startup delay needed on this HP/AMD machine
#   - verification/doctor output
#
# It will NOT erase or repartition anything unless called with:
#   ./othala-post-postinstall-v2.0.sh --prepare-media-disk
# =============================================================================

MEDIA_DEV="/dev/nvme1n1"
MEDIA_PART="/dev/nvme1n1p1"
MEDIA_UUID="164f7792-3e7e-47c0-b639-c2dd352420e8"
STORAGE_1TB_UUID="97629dc1-5c1c-4857-a734-0c79548c30c5"
STORAGE_500_UUID="dde9c8f2-f54d-4267-ae28-9e6153b8ef71"
STORAGE_128_UUID="e548e698-4925-46eb-ad00-a28c17934546"
BACKUP_UUID="08c2ecbb-28a6-4cb3-b2b8-8e7ad554bb4f"

MARK_BEGIN="# BEGIN OTHALA DATA MOUNTS"
MARK_END="# END OTHALA DATA MOUNTS"
FSTAB="/etc/fstab"

NC="\033[0m"; GRN="\033[1;32m"; RED="\033[1;31m"; YLW="\033[1;33m"; BLU="\033[1;34m"; MAG="\033[1;35m"
say(){ printf "${BLU}[info]${NC} %s\n" "$*"; }
ok(){ printf "${GRN}[ ok ]${NC} %s\n" "$*"; }
warn(){ printf "${YLW}[warn]${NC} %s\n" "$*"; }
fail(){ printf "${RED}[fail]${NC} %s\n" "$*" >&2; }
phase(){ printf "\n${MAG}==>${NC} %s\n" "$*"; }

usage(){
  cat <<USAGE
Usage: $0 [--doctor] [--prepare-media-disk]

Default mode configures Othala safely without erasing disks.

Options:
  --doctor              Only verify current state.
  --prepare-media-disk  DANGER: erase ${MEDIA_DEV}, create one Btrfs media partition.
USAGE
}

MODE="configure"
case "${1:-}" in
  "") MODE="configure" ;;
  --doctor) MODE="doctor" ;;
  --prepare-media-disk) MODE="prepare_media" ;;
  -h|--help) usage; exit 0 ;;
  *) fail "Unknown option: $1"; usage; exit 1 ;;
esac

require_sudo(){
  command -v sudo >/dev/null 2>&1 || { fail "sudo is missing"; exit 1; }
  sudo -v
}

check_hostname(){
  local host
  host="$(hostname)"
  if [[ "$host" != "othala" ]]; then
    warn "Hostname is '$host', expected 'othala'."
    read -r -p "Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
  fi
}

uuid_exists(){ blkid -U "$1" >/dev/null 2>&1; }

show_block_summary(){
  lsblk -f
}

verify_required_uuids(){
  local missing=0
  local item
  for item in \
    "$MEDIA_UUID:/mnt/media" \
    "$STORAGE_1TB_UUID:/mnt/1tb-storage" \
    "$STORAGE_500_UUID:/mnt/500gb-storage" \
    "$STORAGE_128_UUID:/mnt/128gb-storage" \
    "$BACKUP_UUID:/mnt/backup-usb"; do
    local uuid="${item%%:*}" mp="${item#*:}"
    if uuid_exists "$uuid"; then
      ok "Found UUID for $mp: $uuid"
    else
      fail "Missing UUID for $mp: $uuid"
      missing=1
    fi
  done
  return "$missing"
}

prepare_media_disk(){
  phase "DANGER: preparing ${MEDIA_DEV} as new media disk"
  require_sudo

  echo "This will ERASE ALL DATA on: ${MEDIA_DEV}"
  echo
  lsblk -f "$MEDIA_DEV" || true
  echo
  read -r -p "Type ERASE-OTHALA-MEDIA to continue: " confirm
  [[ "$confirm" == "ERASE-OTHALA-MEDIA" ]] || { warn "Cancelled."; exit 0; }

  sudo umount /mnt/oldroot 2>/dev/null || true
  sudo umount /mnt/media 2>/dev/null || true
  sudo wipefs -a "$MEDIA_DEV"
  sudo sgdisk --zap-all "$MEDIA_DEV"
  sudo parted -s "$MEDIA_DEV" mklabel gpt
  sudo parted -s "$MEDIA_DEV" mkpart primary btrfs 1MiB 100%
  sudo partprobe "$MEDIA_DEV" || true
  sleep 2
  sudo mkfs.btrfs -f -L media "$MEDIA_PART"

  local new_uuid
  new_uuid="$(blkid -s UUID -o value "$MEDIA_PART")"
  ok "New media UUID: $new_uuid"
  warn "Update MEDIA_UUID inside this script if it changed. Current script expects: $MEDIA_UUID"
}

create_mountpoints(){
  phase "Creating mountpoints"
  sudo mkdir -p /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb
  ok "Mountpoints exist."
}

write_fstab_section(){
  phase "Writing Othala fstab section"
  sudo cp -a "$FSTAB" "$FSTAB.bak.othala.$(date +%Y%m%d-%H%M%S)"

  # Remove prior managed section if present.
  sudo awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    skip != 1 { print }
  ' "$FSTAB" | sudo tee "$FSTAB.tmp" >/dev/null
  sudo mv "$FSTAB.tmp" "$FSTAB"

  # Remove known obsolete Othala rows that caused boot waits earlier.
  sudo sed -i \
    -e '/d762b8bd-57f6-43ee-921f-4fd7a62c0b60/d' \
    -e '/c1bc43c2-800c-46e8-9181-7c6567a6fb23/d' \
    "$FSTAB"

  sudo tee -a "$FSTAB" >/dev/null <<FSTAB_EOF
$MARK_BEGIN
UUID=$MEDIA_UUID /mnt/media btrfs defaults,noatime,compress=zstd:3,ssd,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0
UUID=$STORAGE_1TB_UUID /mnt/1tb-storage btrfs defaults,noatime,compress=zstd:3,ssd,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0
UUID=$STORAGE_500_UUID /mnt/500gb-storage btrfs defaults,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0
UUID=$STORAGE_128_UUID /mnt/128gb-storage btrfs defaults,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0
UUID=$BACKUP_UUID /mnt/backup-usb btrfs defaults,noatime,compress=zstd,nofail,x-systemd.device-timeout=10 0 0
$MARK_END
FSTAB_EOF

  sudo systemctl daemon-reload
  ok "fstab updated."
}

mount_and_verify(){
  phase "Mounting and verifying Othala data volumes"
  sudo mount -a
  local mp failed=0
  for mp in /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb; do
    if findmnt -rn "$mp" >/dev/null; then
      ok "Mounted: $mp"
      if sudo -u "$USER" test -w "$mp"; then
        ok "Writable by $USER: $mp"
      else
        warn "Not writable by $USER: $mp — setting mount root owner to $USER:$USER"
        sudo chown "$USER:$USER" "$mp"
      fi
    else
      fail "Not mounted: $mp"
      failed=1
    fi
  done
  df -h /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb || true
  return "$failed"
}

create_media_dirs(){
  phase "Creating media directory baseline"
  mkdir -p /mnt/media/Music /mnt/media/Movies /mnt/media/Pictures /mnt/media/Documents /mnt/media/Downloads
  ok "Media directories prepared."
}

install_pcmanfm_bookmarks(){
  phase "Writing GTK/PCManFM bookmarks"
  local bookmark_file="$HOME/.config/gtk-3.0/bookmarks"
  mkdir -p "$(dirname "$bookmark_file")"
  touch "$bookmark_file"

  add_bm(){
    local path="$1" label="$2" line="file://$path $label"
    [[ -d "$path" ]] || return 0
    grep -qxF "$line" "$bookmark_file" || echo "$line" >> "$bookmark_file"
  }

  add_bm /mnt/media media
  add_bm /mnt/1tb-storage 1tb-storage
  add_bm /mnt/500gb-storage 500gb-storage
  add_bm /mnt/128gb-storage 128gb-storage
  add_bm /mnt/backup-usb backup-usb
  ok "Bookmarks written to $bookmark_file"
}

install_monitor_layout(){
  phase "Installing Othala monitor layout"
  mkdir -p "$HOME/.local/bin" "$HOME/.config/xinitrc.d"

  cat > "$HOME/.local/bin/othala-xrandr.sh" <<'XRANDR_EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DISPLAY:-}" ]]; then
  echo "No DISPLAY detected. Skipping Othala xrandr layout."
  exit 0
fi

xrandr --output DisplayPort-4 --primary --mode 2560x1440 --pos 0x1440 --rotate normal --output DisplayPort-5 --mode 2560x1440 --pos 0x0 --rotate inverted
XRANDR_EOF
  chmod +x "$HOME/.local/bin/othala-xrandr.sh"

  cat > "$HOME/.config/xinitrc.d/25-othala-monitor.sh" <<'HOOK_EOF'
#!/usr/bin/env bash

if command -v othala-xrandr.sh >/dev/null 2>&1; then
  othala-xrandr.sh
fi
HOOK_EOF
  chmod +x "$HOME/.config/xinitrc.d/25-othala-monitor.sh"
  ok "Monitor layout installed. It is applied when dwm starts."
}

install_sddm_delay(){
  phase "Installing Othala SDDM startup delay"
  sudo mkdir -p /etc/systemd/system/sddm.service.d
  sudo tee /etc/systemd/system/sddm.service.d/10-othala-delay.conf >/dev/null <<'SDDM_EOF'
[Service]
ExecStartPre=/bin/sleep 4
SDDM_EOF
  sudo systemctl daemon-reload
  ok "SDDM delay installed for Othala."
}

install_theme_packages(){
  phase "Installing Othala desktop polish packages"
  sudo apt update
  sudo apt install -y arc-theme breeze-gtk-theme papirus-icon-theme libspa-0.2-bluetooth mesa-utils
  ok "Theme/audio helper packages installed."
}

doctor(){
  phase "Othala doctor"
  echo "Hostname: $(hostname)"
  echo
  echo "== Mounts =="
  df -h /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb 2>/dev/null || true
  echo
  echo "== fstab Othala section =="
  awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
    $0 == begin { show=1 }
    show { print }
    $0 == end { show=0 }
  ' "$FSTAB" || true
  echo
  echo "== Writable check =="
  for mp in /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb; do
    if sudo -u "$USER" test -w "$mp"; then
      printf "OK       %s\n" "$mp"
    else
      printf "NOT WRITE %s\n" "$mp"
    fi
  done
  echo
  echo "== Graphics =="
  command -v glxinfo >/dev/null 2>&1 && glxinfo -B | grep -E 'OpenGL vendor|OpenGL renderer|Accelerated' || true
  command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' || true
  echo
  echo "== Desktop =="
  systemctl is-active sddm 2>/dev/null | sed 's/^/sddm: /' || true
  pgrep -a dwm || true
  pgrep -a picom || true
  pgrep -a dunst || true
  pgrep -a xss-lock || true
  echo
  echo "== Monitor hook =="
  ls -l "$HOME/.local/bin/othala-xrandr.sh" "$HOME/.config/xinitrc.d/25-othala-monitor.sh" 2>/dev/null || true
}

main(){
  check_hostname

  if [[ "$MODE" == "prepare_media" ]]; then
    prepare_media_disk
    exit 0
  fi

  if [[ "$MODE" == "doctor" ]]; then
    doctor
    exit 0
  fi

  require_sudo
  phase "Othala post-postinstall v2.0"
  show_block_summary
  verify_required_uuids
  create_mountpoints
  write_fstab_section
  mount_and_verify
  create_media_dirs
  install_pcmanfm_bookmarks
  install_monitor_layout
  install_sddm_delay
  install_theme_packages
  doctor
  ok "Othala configuration complete. Reboot recommended."
}

main "$@"
