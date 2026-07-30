#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
payload="$repo_root/scripts/ak3/99-bbr3.sh"
device_info_payload="$repo_root/scripts/ak3/98-infinity-device-info.sh"

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s <AnyKernel3 directory>\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

ak3_dir=$1
anykernel="$ak3_dir/anykernel.sh"

[[ -d "$ak3_dir" ]] || { printf 'AnyKernel3 directory is missing: %s\n' "$ak3_dir" >&2; exit 1; }
[[ -f "$anykernel" ]] || { printf 'AnyKernel3 install script is missing: %s\n' "$anykernel" >&2; exit 1; }
[[ -f "$payload" ]] || { printf 'BBR3 service payload is missing: %s\n' "$payload" >&2; exit 1; }
[[ -f "$device_info_payload" ]] || { printf 'Infinity-X device-info payload is missing: %s\n' "$device_info_payload" >&2; exit 1; }

cp "$payload" "$ak3_dir/99-bbr3.sh"
chmod 0644 "$ak3_dir/99-bbr3.sh"
cp "$device_info_payload" "$ak3_dir/98-infinity-device-info.sh"
chmod 0644 "$ak3_dir/98-infinity-device-info.sh"

if ! grep -Fqx '# BBR3 service installation' "$anykernel"; then
  printf '\n' >> "$anykernel"
  cat >> "$anykernel" <<'EOF'
# BBR3 service installation
if [ -f "$AKHOME/99-bbr3.sh" ]; then
  ui_print "Installing BBR3 boot service..."
  if mkdir -p /data/adb/service.d \
    && cp -f "$AKHOME/99-bbr3.sh" /data/adb/service.d/99-bbr3.sh \
    && chmod 0755 /data/adb/service.d/99-bbr3.sh; then
    ui_print "BBR3 boot service installed."
  else
    ui_print "Warning: could not install BBR3 boot service."
  fi
fi
EOF
fi

if ! grep -Fqx '# Infinity-X device-info compatibility service installation' "$anykernel"; then
  printf '\n' >> "$anykernel"
  cat >> "$anykernel" <<'EOF'
# Infinity-X device-info compatibility service installation
if [ -f "$AKHOME/98-infinity-device-info.sh" ]; then
  ui_print "Installing Infinity-X device-info service..."
  if mkdir -p /data/adb/service.d \
    && cp -f "$AKHOME/98-infinity-device-info.sh" /data/adb/service.d/98-infinity-device-info.sh \
    && chmod 0755 /data/adb/service.d/98-infinity-device-info.sh; then
    ui_print "Infinity-X device-info service installed."
  else
    ui_print "Warning: could not install Infinity-X device-info service."
  fi
fi
EOF
fi
