#!/system/bin/sh
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 1
done

echo bbr3 > /proc/sys/net/ipv4/tcp_congestion_control
