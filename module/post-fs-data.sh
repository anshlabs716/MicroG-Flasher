#!/system/bin/sh
# MicroG Flasher - bootloop watchdog.
# service.sh removes the pending marker when a boot completes. If we get
# here and the marker already exists, the previous boot never completed.
# After 2 consecutive failed boots, disable this module (and only this
# module) so the device recovers instead of looping.

MODDIR=${0%/*}
PENDING=/data/adb/microg_flasher_boot_pending
REASON=/data/adb/microg_flasher_disabled_reason
LIMIT=2

if [ -f "$PENDING" ]; then
  n=$(cat "$PENDING" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  if [ "$n" -ge "$LIMIT" ]; then
    : > "$MODDIR/disable"
    rm -f "$PENDING"
    echo "MicroG Flasher disabled automatically after $n boots that never completed." > "$REASON"
    echo "Re-enable it in the Magisk app once the cause is fixed." >> "$REASON"
    exit 0
  fi
  echo "$n" > "$PENDING"
else
  echo 1 > "$PENDING"
fi
exit 0
