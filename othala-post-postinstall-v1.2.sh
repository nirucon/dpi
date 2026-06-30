#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# OTHALA Debian post-postinstall v1.2
# =============================================================================
# Machine-specific setup for HP Z2 Tower G5 "othala".
# Safe by default: fixes fstab, mountpoints, monitor helper, and verification.
# Destructive media preparation only happens with --prepare-media-disk DEV and
# two exact confirmations.
#
# Run normally:
#   ./othala-post-postinstall-v1.2.sh
#
# Dry-run:
#   ./othala-post-postinstall-v1.2.sh --dry-run
#
# Optional destructive mode:
#   ./othala-post-postinstall-v1.2.sh --prepare-media-disk /dev/nvme1n1
# =============================================================================

NC="\033[0m"; BOLD="\033[1m"; GRN="\033[1;32m"; RED="\033[1;31m"; YLW="\033[1;33m"; BLU="\033[1;34m"; MAG="\033[1;35m"; CYN="\033[1;36m"
say()   { printf "${BLU}[info]${NC} %s\n" "$*"; }
phase() { printf "\n${MAG}==>${NC} ${BOLD}%s${NC}\n" "$*"; }
ok()    { printf "${GRN}[ ok ]${NC} %s\n" "$*"; }
warn()  { printf "${YLW}[warn]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[fail]${NC} %s\n" "$*" >&2; }
trap 'fail "Aborted at line $LINENO while running: ${BASH_COMMAND:-unknown}"' ERR

DRY_RUN=0
PREPARE_MEDIA_DISK=0
MEDIA_DEVICE=""

# Current Othala storage UUIDs after the Debian reinstall.
MEDIA_UUID="164f7792-3e7e-47c0-b639-c2dd352420e8"
STORAGE_1TB_UUID="97629dc1-5c1c-4857-a734-0c79548c30c5"
STORAGE_500GB_UUID="dde9c8f2-f54d-4267-ae28-9e6153b8ef71"
STORAGE_128GB_UUID="e548e698-4925-46eb-ad00-a28c17934546"
BACKUP_USB_UUID="08c2ecbb-28a6-4cb3-b2b8-8e7ad554bb4f"

# Stale UUIDs observed during the Debian migration. These must never remain active.
STALE_MEDIA_UUID="d762b8bd-57f6-43ee-921f-4fd7a62c0b60"
STALE_128GB_UUID="c1bc43c2-800c-46e8-9181-7c6567a6fb23"

usage() {
  cat <<EOFUSAGE
Usage:
  $0
  $0 --dry-run
  $0 --prepare-media-disk /dev/nvme1n1

Options:
  --dry-run                  Show what would be done without changing the system.
  --prepare-media-disk DEV   ERASE DEV completely and create a new Btrfs media partition.
  -h, --help                 Show this help.
EOFUSAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --prepare-media-disk)
      PREPARE_MEDIA_DISK=1
      MEDIA_DEVICE="${2:-}"
      [[ -n "$MEDIA_DEVICE" ]] || { fail "Missing device after --prepare-media-disk"; exit 1; }
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %q ' "$@"; echo
  else
    "$@"
  fi
}

run_sudo() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] sudo %q ' "$@"; echo
  else
    sudo "$@"
  fi
}

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

confirm_exact() {
  local expected="$1" prompt="$2" answer
  echo "$prompt"
  read -r -p "Type exactly '$expected' to continue: " answer
  [[ "$answer" == "$expected" ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "Missing command: $1"
    echo "Install required tools first: sudo apt install btrfs-progs gdisk parted util-linux x11-xserver-utils arandr autorandr"
    exit 1
  }
}

get_dev_by_uuid() { blkid -U "$1" 2>/dev/null || true; }
get_label_by_uuid() { local d; d="$(get_dev_by_uuid "$1")"; [[ -n "$d" ]] && lsblk -no LABEL "$d" 2>/dev/null | head -1 || true; }

verify_uuid_required() {
  local name="$1" uuid="$2" expected_label="${3:-}" dev label
  dev="$(get_dev_by_uuid "$uuid")"
  [[ -n "$dev" ]] || { fail "$name UUID not found: $uuid"; return 1; }
  label="$(get_label_by_uuid "$uuid")"
  printf "  %-18s %-38s %-16s %s\n" "$name" "$uuid" "${label:-no-label}" "$dev"
  if [[ -n "$expected_label" && "$label" != "$expected_label" ]]; then
    warn "$name label is '$label', expected '$expected_label'. Continuing because UUID is authoritative."
  fi
}

verify_uuid_optional() {
  local name="$1" uuid="$2" expected_label="${3:-}" dev label
  dev="$(get_dev_by_uuid "$uuid")"
  if [[ -z "$dev" ]]; then
    warn "$name not currently present: $uuid"
    return 0
  fi
  label="$(get_label_by_uuid "$uuid")"
  printf "  %-18s %-38s %-16s %s\n" "$name" "$uuid" "${label:-no-label}" "$dev"
}

remove_managed_and_mountpoint_lines() {
  local src="$1" dst="$2"
  awk '
    BEGIN { skip=0 }
    /^# BEGIN OTHALA STORAGE/ { skip=1; next }
    /^# END OTHALA STORAGE/ { skip=0; next }
    skip==1 { next }
    $2=="/mnt/media" { next }
    $2=="/mnt/1tb-storage" { next }
    $2=="/mnt/500gb-storage" { next }
    $2=="/mnt/128gb-storage" { next }
    $2=="/mnt/backup-usb" { next }
    { print }
  ' "$src" > "$dst"
}

append_othala_fstab_block() {
  local file="$1"
  {
    echo ""
    echo "# BEGIN OTHALA STORAGE"
    echo "# Managed by othala-post-postinstall-v1.2.sh"
    echo "UUID=$MEDIA_UUID /mnt/media btrfs defaults,noatime,compress=zstd:1,ssd,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0"
    echo "UUID=$STORAGE_1TB_UUID /mnt/1tb-storage btrfs defaults,noatime,compress=zstd:3,ssd,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0"
    echo "UUID=$STORAGE_500GB_UUID /mnt/500gb-storage btrfs defaults,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0"
    if [[ -n "$(get_dev_by_uuid "$STORAGE_128GB_UUID")" ]]; then
      echo "UUID=$STORAGE_128GB_UUID /mnt/128gb-storage btrfs defaults,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0"
    else
      echo "# 128gb-storage not present: UUID=$STORAGE_128GB_UUID"
    fi
    if [[ -n "$(get_dev_by_uuid "$BACKUP_USB_UUID")" ]]; then
      echo "UUID=$BACKUP_USB_UUID /mnt/backup-usb btrfs defaults,noatime,compress=zstd:1,nofail,x-systemd.device-timeout=10 0 0"
    else
      echo "# backup-usb not present: UUID=$BACKUP_USB_UUID"
    fi
    echo "# END OTHALA STORAGE"
  } >> "$file"
}

validate_no_duplicate_mountpoints() {
  local duplicates
  duplicates="$(awk '$2 ~ /^\/mnt\// {count[$2]++} END {for (m in count) if (count[m] > 1) print m, count[m]}' /etc/fstab || true)"
  if [[ -n "$duplicates" ]]; then
    fail "Duplicate /mnt mountpoints remain in /etc/fstab:"
    echo "$duplicates"
    return 1
  fi
}

validate_no_stale_uuids() {
  if grep -qE "$STALE_MEDIA_UUID|$STALE_128GB_UUID" /etc/fstab; then
    fail "Stale Othala UUID remains in /etc/fstab. Refusing to continue."
    grep -nE "$STALE_MEDIA_UUID|$STALE_128GB_UUID" /etc/fstab || true
    return 1
  fi
}

[[ "$EUID" -ne 0 ]] || { fail "Run as normal user, not root."; exit 1; }
command -v sudo >/dev/null 2>&1 || { fail "sudo missing."; exit 1; }

phase "Othala host check"
HOST="$(hostname)"
if [[ "$HOST" != "othala" ]]; then
  warn "Hostname is '$HOST', expected 'othala'."
  ask_yes_no "Continue anyway?" "N" || exit 1
else
  ok "Hostname is othala."
fi
[[ "$DRY_RUN" -eq 1 ]] && warn "DRY-RUN mode: no changes will be written."

phase "Required tools"
for cmd in lsblk blkid findmnt mount umount grep awk sed tee sort uniq; do require_cmd "$cmd"; done
if ! command -v btrfs >/dev/null 2>&1 || ! command -v sgdisk >/dev/null 2>&1 || ! command -v parted >/dev/null 2>&1; then
  say "Installing required disk tools..."
  run_sudo apt update
  run_sudo apt install -y btrfs-progs gdisk parted util-linux x11-xserver-utils arandr autorandr
fi
ok "Required tools are available."

phase "Current disks"
lsblk -f

if [[ "$PREPARE_MEDIA_DISK" -eq 1 ]]; then
  [[ "$DRY_RUN" -eq 0 ]] || { fail "Refusing destructive --prepare-media-disk in --dry-run mode."; exit 1; }
  phase "Prepare new media disk"
  [[ -b "$MEDIA_DEVICE" ]] || { fail "Not a block device: $MEDIA_DEVICE"; exit 1; }
  echo "Selected device to ERASE: $MEDIA_DEVICE"
  lsblk -f "$MEDIA_DEVICE" || true
  echo
  if findmnt -rn -S "$MEDIA_DEVICE" >/dev/null 2>&1 || lsblk -nr -o MOUNTPOINT "$MEDIA_DEVICE" | grep -qv '^$'; then
    fail "$MEDIA_DEVICE or one of its partitions is mounted. Unmount it first."
    exit 1
  fi
  warn "This will permanently erase ALL partitions and data on $MEDIA_DEVICE."
  confirm_exact "ERASE $MEDIA_DEVICE" "Destructive confirmation required." || { warn "Cancelled."; exit 1; }
  confirm_exact "MEDIA" "Second confirmation required." || { warn "Cancelled."; exit 1; }
  sudo wipefs -a "$MEDIA_DEVICE"
  sudo sgdisk --zap-all "$MEDIA_DEVICE"
  sudo partprobe "$MEDIA_DEVICE" || true
  sleep 2
  sudo parted -s "$MEDIA_DEVICE" mklabel gpt
  sudo parted -s "$MEDIA_DEVICE" mkpart primary btrfs 1MiB 100%
  sudo partprobe "$MEDIA_DEVICE" || true
  sleep 2
  MEDIA_PART="${MEDIA_DEVICE}p1"
  if [[ "$MEDIA_DEVICE" =~ [0-9]$ && ! "$MEDIA_DEVICE" =~ nvme|mmcblk ]]; then MEDIA_PART="${MEDIA_DEVICE}1"; fi
  [[ -b "$MEDIA_PART" ]] || { fail "Expected new partition not found: $MEDIA_PART"; exit 1; }
  sudo mkfs.btrfs -f -L media "$MEDIA_PART"
  MEDIA_UUID="$(blkid -s UUID -o value "$MEDIA_PART")"
  ok "Created media filesystem: $MEDIA_PART UUID=$MEDIA_UUID"
fi

phase "Verifying known storage UUIDs"
verify_uuid_required "media" "$MEDIA_UUID" "media"
verify_uuid_required "1tb-storage" "$STORAGE_1TB_UUID" "1tb-storage"
verify_uuid_required "500gb-storage" "$STORAGE_500GB_UUID" "500gb-storage"
verify_uuid_optional "128gb-storage" "$STORAGE_128GB_UUID" ""
verify_uuid_optional "backup-usb" "$BACKUP_USB_UUID" "backup"

phase "Creating mountpoints"
run_sudo mkdir -p /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb
ok "Mountpoints exist."

phase "Updating /etc/fstab idempotently"
FSTAB_BACKUP="/etc/fstab.bak.othala.$(date +%Y%m%d-%H%M%S)"
TMPFSTAB="$(mktemp)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  remove_managed_and_mountpoint_lines /etc/fstab "$TMPFSTAB"
  append_othala_fstab_block "$TMPFSTAB"
  echo "--- proposed /etc/fstab /mnt block ---"
  grep -nE 'OTHALA STORAGE|/mnt/' "$TMPFSTAB" || true
  rm -f "$TMPFSTAB"
else
  sudo cp -a /etc/fstab "$FSTAB_BACKUP"
  ok "Backup written: $FSTAB_BACKUP"
  sudo cp /etc/fstab "$TMPFSTAB.in"
  remove_managed_and_mountpoint_lines "$TMPFSTAB.in" "$TMPFSTAB"
  append_othala_fstab_block "$TMPFSTAB"
  sudo cp "$TMPFSTAB" /etc/fstab
  rm -f "$TMPFSTAB" "$TMPFSTAB.in"
  sudo systemctl daemon-reload
  validate_no_duplicate_mountpoints
  validate_no_stale_uuids
  ok "fstab updated, deduplicated and systemd reloaded."
fi

phase "Mounting storage"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] sudo mount -av"
else
  sudo mount -av
fi

phase "Storage verification"
if [[ "$DRY_RUN" -eq 0 ]]; then
  missing=0
  for mp in /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb; do
    if findmnt "$mp" >/dev/null 2>&1; then
      ok "$mp mounted from $(findmnt -rn -o SOURCE "$mp")"
    else
      warn "$mp not mounted"
      [[ "$mp" == "/mnt/128gb-storage" || "$mp" == "/mnt/backup-usb" ]] || missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || { fail "Required storage mount missing."; exit 1; }
  echo
  df -h /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb 2>/dev/null || true
fi

phase "Media directory skeleton"
run_sudo mkdir -p /mnt/media/Music /mnt/media/Movies /mnt/media/Pictures /mnt/media/Documents /mnt/media/Downloads
if [[ "$DRY_RUN" -eq 0 ]]; then
  sudo chown "$USER:$USER" /mnt/media /mnt/media/Music /mnt/media/Movies /mnt/media/Pictures /mnt/media/Documents /mnt/media/Downloads || true
fi
ok "Media directories ready."

phase "Writing Othala monitor helper"
run mkdir -p "$HOME/.local/bin"
if [[ "$DRY_RUN" -eq 0 ]]; then
  cat > "$HOME/.local/bin/othala-xrandr.sh" <<'EOX'
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DISPLAY:-}" ]]; then
  echo "No DISPLAY detected. Run this inside the local X11/dwm session, not over plain SSH."
  exit 0
fi

# Othala home dual monitor layout:
# DisplayPort-5 = top monitor, physically upside down, rotated inverted.
# DisplayPort-4 = bottom monitor, normal.
xrandr \
  --output DisplayPort-5 --mode 2560x1440 --pos 0x0 --rotate inverted \
  --output DisplayPort-4 --mode 2560x1440 --pos 0x1440 --rotate normal \
  --output DisplayPort-3 --off \
  --output HDMI-A-3 --off \
  --output DP-1-1 --off \
  --output HDMI-1-1 --off \
  --output DP-1-2 --off \
  --output HDMI-1-2 --off \
  --output DP-1-3 --off \
  --output HDMI-1-3 --off
EOX
  chmod +x "$HOME/.local/bin/othala-xrandr.sh"
fi
ok "Othala monitor helper ready: $HOME/.local/bin/othala-xrandr.sh"

phase "Monitor application"
warn "Not applying xrandr automatically. After first local dwm login, run: othala-xrandr.sh && monitor-save.sh othala-home"

phase "Final checks"
if [[ "$DRY_RUN" -eq 0 ]]; then
  grep -nE 'OTHALA STORAGE|/mnt/' /etc/fstab || true
  validate_no_duplicate_mountpoints
  validate_no_stale_uuids
fi

echo
ok "Othala post-postinstall v1.2 complete."
