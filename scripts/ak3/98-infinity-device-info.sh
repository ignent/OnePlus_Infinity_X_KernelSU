#!/system/bin/sh

while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

# Project Infinity X reads only these properties for its Settings device-info page.
resetprop_bin=/data/adb/ksu/bin/resetprop
[ -x "$resetprop_bin" ] || exit 0

"$resetprop_bin" -n ro.infinity.buildtype OFFICIAL
"$resetprop_bin" -n ro.infinity.version 3.12
"$resetprop_bin" -n ro.infinity.maintainer NullCode1337
"$resetprop_bin" -n ro.infinity.device ktm
"$resetprop_bin" -n ro.infinity.soc "Snapdragon 8 Elite"
"$resetprop_bin" -n ro.infinity.camera "50MP + 8MP"
