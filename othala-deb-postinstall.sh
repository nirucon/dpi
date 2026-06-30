#!/usr/bin/env bash
set -Eeuo pipefail

echo "== Othala post-postinstall =="

HOST="$(hostname)"
if [[ "$HOST" != "othala" ]]; then
  echo "Warning: hostname is '$HOST', expected 'othala'."
  read -r -p "Continue anyway? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

echo "== Installing required tools =="
sudo apt update
sudo apt install -y btrfs-progs x11-xserver-utils arandr autorandr

echo "== Creating mountpoints =="
sudo mkdir -p \
  /mnt/media \
  /mnt/1tb-storage \
  /mnt/500gb-storage \
  /mnt/128gb-storage \
  /mnt/backup-usb

echo "== Backing up /etc/fstab =="
sudo cp -a /etc/fstab "/etc/fstab.bak.othala.$(date +%Y%m%d-%H%M%S)"

echo "== Adding Othala storage mounts if missing =="

add_fstab_line() {
  local uuid="$1"
  local mountpoint="$2"
  local opts="$3"

  if grep -q "$uuid" /etc/fstab || grep -q "[[:space:]]$mountpoint[[:space:]]" /etc/fstab; then
    echo "Already present: $mountpoint"
  else
    echo "Adding: $mountpoint"
    echo "UUID=$uuid $mountpoint btrfs $opts 0 0" | sudo tee -a /etc/fstab >/dev/null
  fi
}

add_fstab_line "d762b8bd-57f6-43ee-921f-4fd7a62c0b60" "/mnt/media"        "subvol=@media,defaults,noatime,compress=zstd:3,ssd,space_cache=v2,nofail,x-systemd.device-timeout=10"
add_fstab_line "97629dc1-5c1c-4857-a734-0c79548c30c5" "/mnt/1tb-storage"  "defaults,noatime,compress=zstd:3,ssd,space_cache=v2,nofail,x-systemd.device-timeout=10"
add_fstab_line "dde9c8f2-f54d-4267-ae28-9e6153b8ef71" "/mnt/500gb-storage" "defaults,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=10"
add_fstab_line "c1bc43c2-800c-46e8-9181-7c6567a6fb23" "/mnt/128gb-storage" "subvol=@storage,defaults,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=10"
add_fstab_line "08c2ecbb-28a6-4cb3-b2b8-8e7ad554bb4f" "/mnt/backup-usb"    "defaults,noatime,compress=zstd,nofail,x-systemd.device-timeout=10"

echo "== Mounting disks =="
sudo mount -a

echo "== Current mounted storage =="
findmnt /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/128gb-storage /mnt/backup-usb || true

echo "== Writing monitor script =="
mkdir -p "$HOME/.local/bin"

cat > "$HOME/.local/bin/othala-xrandr.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

xrandr \
  --output DisplayPort-5 --mode 2560x1440 --pos 0x0 --rotate inverted \
  --output DisplayPort-4 --mode 2560x1440 --pos 0x1440 --rotate normal \
  --output DisplayPort-3 --off \
  --output HDMI-A-3 --off
EOF

chmod +x "$HOME/.local/bin/othala-xrandr.sh"

echo "== Applying monitor layout =="
"$HOME/.local/bin/othala-xrandr.sh" || true

echo "== Saving autorandr profile =="
if command -v autorandr >/dev/null 2>&1; then
  autorandr --save othala-home || true
fi

echo
echo "Done."
echo
echo "Verify with:"
echo "  df -h /mnt/media /mnt/1tb-storage /mnt/500gb-storage /mnt/backup-usb"
echo "  xrandr"
echo "  autorandr --current"
