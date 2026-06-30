#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# OTHALA Debian post-postinstall v1.1
# =============================================================================
# Purpose:
#   Machine-specific setup for Nicklas' HP Z2 Tower G5 "othala" after the
#   generic NIRUCON Debian/dwm postinstall.
#
# What it does safely:
#   - Verifies this is host "othala" or asks before continuing.
#   - Verifies known storage filesystems by UUID.
#   - Creates mountpoints.
#   - Adds/removes Othala managed fstab block idempotently.
#   - Mounts storage and verifies result.
#   - Writes Othala monitor helper script for the known dual-monitor layout.
#   - Skips xrandr/autorandr automatically when run over SSH/no DISPLAY.
#
# Optional destructive mode:
#   --prepare-media-disk /dev/nvme1n1
#     Completely erases the chosen disk and formats it as Btrfs label "media".
#     Requires multiple confirmations and refuses if the disk is mounted.
#
# Run:
#   chmod +x othala-post-postinstall-v1.1.sh
#   ./othala-post-postinstall-v1.1.sh
#
# Optional:
#   ./othala-post-postinstall-v1.1.sh --prepare-media-disk /dev/nvme1n1
# =============================================================================

NC="\033[0m"; BOLD="\033[1m"; GRN="\033[1;32m"; RED="\033[1;31m"; YLW="\033[1;33m"; BLU="\033[1;34m"; MAG="\033[1;35m"; CYN="\033[1;36m"
say()   { printf "${BLU}[info]${NC} %s\n" "$*"; }
phase() { printf "\n${MAG}==>${NC} ${BOLD}%s${NC}\n" "$*"; }
ok()    { printf "${GRN}[ ok ]${NC} %s\n" "$*"; }
warn()  { printf "${YLW}[warn]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[fail]${NC} %s\n" "$*" >&2; }
trap 'fail "Aborted at line $LINENO while running: ${BASH_COMMAND:-unknown}"' ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "Missing command: $1"
    echo "Install required tools first: sudo apt install btrfs-progs gdisk parted util-linux x11-xserver-utils arandr autorandr"
    exit 1
  }
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

# Known current Othala storage UUIDs after Debian reinstall.
MEDIA_UUID="164f7792-3e7e-47c0-b639-c2dd352420e8"
STORAGE_1TB_UUID="97629dc1-5c1c-4857-a734-0c79548c30c5"
STORAGE_500GB_UUID="dde9c8f2-f54d-4267-ae28-9e6153b8ef71"
STORAGE_128GB_UUID="e548e698-4925-46eb-ad00-a28c17934546"
BACKUP_USB_UUID="08c2ecbb-28a6-4cb3-b2b8-8e7ad554bb4f"

MEDIA_DEVICE=""
PREPARE_MEDIA_DISK=0

usage() {
  cat <<EOFUSAGE
Usage:
  $0
  $0 --prepare-media-disk /dev/nvme1n1

Options:
  --prepare-media-disk DEV   ERASE DEV completely and create new Btrfs media partition.
  -h, --help                 Show this help.
EOFUSAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare-media-disk)
      PREPARE_MEDIA_DISK=1
      MEDIA_DEVICE="${2:-}"
      [[ -n "$MEDIA_DEVICE" ]] || { fail "Missing device after --prepare-media-disk"; exit 1; }
      shift 2
      ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      fail "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

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

phase "Required tools"
for cmd in lsblk blkid findmnt mount umount grep awk sed tee; do require_cmd "$cmd"; done
if ! command -v btrfs >/dev/null 2>&1 || ! command -v sgdisk >/dev/null 2>&1 || ! command -v parted >/dev/null 2>&1; then
  say "Installing required disk tools..."
  sudo apt update
  sudo apt install -y btrfs-progs gdisk parted util-linux x11-xserver-utils arandr autorandr
fi
ok "Required tools are available."

get_dev_by_uuid() {
  local uuid="$1"
  blkid -U "$uuid" 2>/dev/null || true
}

require_uuid_present() {
  local name="$1" uuid="$2" required="$3" dev
  dev="$(get_dev_by_uuid "$uuid")"
  if [[ -n "$dev" ]]; then
    printf "  %-18s %-38s %s\n" "$name" "$uuid" "$dev"
    return 0
  fi
  if [[ "$required" == "required" ]]; then
    fail "$name UUID not found: $uuid"
    return 1
  fi
  warn "$name UUID not found: $uuid"
  return 0
}

phase "Current disks"
lsblk -f

if [[ "$PREPARE_MEDIA_DISK" -eq 1 ]]; then
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
  warn "Only do this if this is the old CachyOS disk you intentionally want to reuse as media."
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
  if [[ "$MEDIA_DEVICE" =~ [0-9]$ && ! "$MEDIA_DEVICE" =~ nvme|mmcblk ]]; then
    MEDIA_PART="${MEDIA_DEVICE}1"
  fi
  [[ -b "$MEDIA_PART" ]] || { fail "Expected new partition not found: $MEDIA_PART"; exit 1; }

  sudo mkfs.btrfs -f -L media "$MEDIA_PART"
  MEDIA_UUID="$(blkid -s UUID -o value "$MEDIA_PART")"
  ok "Created media filesystem: $MEDIA_PART UUID=$MEDIA_UUID"
fi

phase "Verifying known storage UUIDs"
require_uuid_present "media" "$MEDIA_UUID" "required"
require_uuid_present "1tb-storage" "$STORAGE_1TB_UUID" "required"
require_uuid_present "500gb-storage" "$STORAGE_500GB_UUID" "required"
require_uuid_present "128gb-storage" "$STORAGE_128GB_UUID" "optional"
require_uuid_present "backup-usb" "$BACKUP_USB_UUID" "optional"

phase "Creating mountpoints"
sudo mkdir -p \
  /mnt/media \
  /mnt/1tb-storage \
  /mnt/500gb-storage \
  /mnt/128gb-storage \
  /mnt/backup-usb
ok "Mountpoints exist."

phase "Updating /etc/fstab"
FSTAB_BACKUP="/etc/fstab.bak.othala.$(date +%Y%m%d-%H%M%S)"
sudo cp -a /etc/fstab "$FSTAB_BACKUP"
ok "Backup written: $FSTAB_BACKUP"

# Remove old Othala block if present.
sudo sed -i '/# BEGIN OTHALA STORAGE/,/# END OTHALA STORAGE/d' /etc/fstab

# Remove stale duplicate lines for these mountpoints outside the managed block.
# This prevents an older incorrect /mnt/media UUID from overriding the new one.
TMPFSTAB="$(mktemp)"
sudo awk '
  $2=="/mnt/media" {next}
  $2=="/mnt/1tb-storage" {next}
  $2=="/mnt/500gb-storage" {next}
  $2=="/mnt/128gb-storage" {next}
  $2=="/mnt/backup-usb" {next}
  {print}
' /etc/fstab > "$TMPFSTAB"
sudo cp "$TMPFSTAB" /etc/fstab
rm -f "$TMPFSTAB"

{
  echo ""
  echo "# BEGIN OTHALA STORAGE"
  echo "# Managed by othala-post-postinstall-v1.1.sh"
  echo "UUID=$MEDIA_UUID /mnt/media btrfs defaults,noatime,compress=zstd:1,ssd,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0"
  echo "UUID=$STORAGE_1TB_UUID /mnt/1tb-storage btrfs defaults,noatime,compress=zstd:3,ssd,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0"
  echo "UUID=$STORAGE_500GB_UUID /mnt/500gb-storage btrfs defaults,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0"
  if [[ -n "$(get_dev_by_uuid "$STORAGE_128GB_UUID")" ]]; then
    echo "UUID=$STORAGE_128GB_UUID /mnt/128gb-storage btrfs defaults,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=10 0 0"
  else
    echo "# 128gb-storage currently not present: UUID=$STORAGE_128GB_UUID"
  fi
  if [[ -n "$(get_dev_by_uuid "$BACKUP_USB_UUID")" ]]; then
    echo "UUID=$BACKUP_USB_UUID /mnt/backup-usb btrfs defaults,noatime,compress=zstd:1,nofail,x-systemd.device-timeout=10 0 0"
  else
    echo "# backup-usb currently not present: UUID=$BACKUP_USB_UUID"
  fi
  echo "# END OTHALA STORAGE"
} | sudo tee -a /etc/fstab >/dev/null

sudo systemctl daemon-reload
ok "fstab updated and systemd reloaded."

phase "Mounting storage"
sudo mount -a

phase "Storage verification"
for mp in /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb; do
  if findmnt "$mp" >/dev/null 2>&1; then
    ok "$mp mounted from $(findmnt -rn -o SOURCE "$mp")"
  else
    warn "$mp not mounted"
  fi
done

echo
df -h /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb 2>/dev/null || true

phase "Media directory skeleton"
sudo mkdir -p \
  /mnt/media/Music \
  /mnt/media/Movies \
  /mnt/media/Pictures \
  /mnt/media/Documents \
  /mnt/media/Downloads
sudo chown -R "$USER:$USER" /mnt/media
ok "Media directories created and owned by $USER."

phase "Writing Othala monitor helper"
mkdir -p "$HOME/.local/bin"
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
ok "Wrote $HOME/.local/bin/othala-xrandr.sh"

phase "Optional monitor apply/save"
if [[ -n "${DISPLAY:-}" ]]; then
  "$HOME/.local/bin/othala-xrandr.sh" || warn "Could not apply Othala monitor layout."
  if command -v autorandr >/dev/null 2>&1; then
    autorandr --save othala-home || warn "Could not save autorandr profile."
  fi
else
  note_msg="No DISPLAY detected. Skipping xrandr/autorandr now. After local dwm login, run: othala-xrandr.sh && monitor-save.sh othala-home"
  warn "$note_msg"
fi

phase "Done"
echo "Recommended checks:"
echo "  findmnt /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/backup-usb"
echo "  df -h /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/backup-usb"
echo "  lsblk -f"
echo "  tail -40 /etc/fstab"
echo
ok "Othala post-postinstall complete."
