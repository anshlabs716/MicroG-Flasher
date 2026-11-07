#!/system/bin/sh
#################
# MicroG-Flasher
# Downloads the latest official microG apks from GitHub at install time
# and installs them systemlessly as privileged system apps.
#
# Offline fallback: pre-push the apks to /sdcard/MicroG-Flasher/
#   adb push com.google.android.gms.apk  /sdcard/MicroG-Flasher/
#   adb push com.android.vending.apk     /sdcard/MicroG-Flasher/
#################

SKIPUNZIP=1

API="https://api.github.com/repos/microg/GmsCore/releases/latest"
GMS_NAME="com.google.android.gms.apk"
VENDING_NAME="com.android.vending.apk"

# ---------------- helpers ----------------

ui_print " "
ui_print "- MicroG Flasher"

if [ -n "$MAGISK_VER_CODE" ]; then
  if [ "$MAGISK_VER_CODE" -lt 26100 ] 2>/dev/null; then
    abort "! Magisk v26.1+ required"
  fi
fi

# Downloader: try curl, then wget (busybox or system)
download() {
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --connect-timeout 20 -o "$2" "$1" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1" >/dev/null 2>&1
  else
    return 1
  fi
}

# Sanity check: non-empty, plausible size, and actually a zip (PK header)
check_apk() {
  local f="$1" min="$2"
  [ -f "$f" ] || return 1
  local size
  size=$(wc -c < "$f")
  [ "$size" -ge "$min" ] || return 1
  [ "$(dd if="$f" bs=2 count=1 2>/dev/null)" = "PK" ] || return 1
  return 0
}

# ---------------- module files ----------------

ui_print "- Extracting module files"
unzip -oq "$ZIPFILE" -d "$MODPATH" \
  'module.prop' 'system/*' 'service.sh' 'uninstall.sh' >/dev/null 2>&1
[ -f "$MODPATH/module.prop" ] || abort "! Extraction failed"
set_perm_recursive "$MODPATH" 0 0 0755 0644

# ---------------- environment check ----------------

SDK=$(getprop ro.build.version.sdk)
ui_print "- Android SDK: ${SDK:-unknown}"

# Free space on /data (module lives there). GmsCore is ~110 MB.
FREE_KB=$(df -k /data 2>/dev/null | tail -n 1 | tr -s ' ' | cut -d ' ' -f4)
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 262144 ] 2>/dev/null; then
  ui_print "! Less than 256 MB free on /data"
  abort "! microG needs ~120 MB. Free up space and retry."
fi

# ---------------- pre-flight warning ----------------

if command -v pm >/dev/null 2>&1 && pm path com.google.android.gms >/dev/null 2>&1; then
  ui_print "! Google Play services is already installed"
  ui_print "  on this ROM. If that is real Google GMS on a"
  ui_print "  ROM without signature spoofing, microG cannot"
  ui_print "  take over and Google-checking apps will break."
  ui_print "  Uninstall the existing package first if unsure."
fi

# ---------------- locate apks ----------------

GMS_SRC=""
VENDING_SRC=""

# 1) Pre-placed local apks (offline path)
for d in /sdcard/MicroG-Flasher /sdcard/Download /sdcard; do
  if [ -z "$GMS_SRC" ] && check_apk "$d/$GMS_NAME" 50000000; then
    GMS_SRC="$d/$GMS_NAME"
  fi
  if [ -z "$VENDING_SRC" ] && check_apk "$d/$VENDING_NAME" 1000000; then
    VENDING_SRC="$d/$VENDING_NAME"
  fi
done
[ -n "$GMS_SRC" ] && ui_print "- Found local GmsCore: $GMS_SRC"
[ -n "$VENDING_SRC" ] && ui_print "- Found local FakeStore: $VENDING_SRC"

# 2) Download whatever is missing from the latest official release
if [ -z "$GMS_SRC" ] || [ -z "$VENDING_SRC" ]; then
  ui_print "- Fetching latest microG release info"
  JSON="$TMPDIR/release.json"
  download "$API" "$JSON" || abort "! No network access (or no downloader). Pre-push apks to /sdcard/MicroG-Flasher/ and retry."
  TAG=$(grep -oE '"tag_name":[[:space:]]*"[^"]*"' "$JSON" | head -n 1 | sed 's/.*: *"//;s/"//')
  [ -n "$TAG" ] || abort "! Could not parse release info"
  ui_print "- microG release: $TAG"

  GMS_URL=$(grep -oE '"browser_download_url":[[:space:]]*"[^"]*com\.google\.android\.gms-[0-9]+\.apk"' "$JSON" | head -n 1 | sed 's/.*: *"//;s/"//')
  VENDING_URL=$(grep -oE '"browser_download_url":[[:space:]]*"[^"]*com\.android\.vending-[0-9]+\.apk"' "$JSON" | head -n 1 | sed 's/.*: *"//;s/"//')
  [ -n "$GMS_URL" ] || abort "! GmsCore apk not found in release"
  [ -n "$VENDING_URL" ] || abort "! FakeStore apk not found in release"

  if [ -z "$GMS_SRC" ]; then
    ui_print "- Downloading GmsCore (~110 MB)"
    download "$GMS_URL" "$TMPDIR/$GMS_NAME" || abort "! GmsCore download failed"
    check_apk "$TMPDIR/$GMS_NAME" 50000000 || abort "! GmsCore download is corrupt"
    GMS_SRC="$TMPDIR/$GMS_NAME"
  fi
  if [ -z "$VENDING_SRC" ]; then
    ui_print "- Downloading FakeStore (~4 MB)"
    download "$VENDING_URL" "$TMPDIR/$VENDING_NAME" || abort "! FakeStore download failed"
    check_apk "$TMPDIR/$VENDING_NAME" 1000000 || abort "! FakeStore download is corrupt"
    VENDING_SRC="$TMPDIR/$VENDING_NAME"
  fi
fi

# ---------------- install ----------------

ui_print "- Installing microG systemlessly"
mkdir -p "$MODPATH/system/priv-app/GmsCore" \
         "$MODPATH/system/priv-app/FakeStore"
cp -f "$GMS_SRC"     "$MODPATH/system/priv-app/GmsCore/GmsCore.apk"
cp -f "$VENDING_SRC" "$MODPATH/system/priv-app/FakeStore/FakeStore.apk"
set_perm "$MODPATH/system/priv-app/GmsCore/GmsCore.apk"  0 0 0644 \
  u:object_r:system_file:s0
set_perm "$MODPATH/system/priv-app/FakeStore/FakeStore.apk" 0 0 0644 \
  u:object_r:system_file:s0

ui_print "- Installed GmsCore + FakeStore"
ui_print "  (permission XMLs + sysconfig included)"
ui_print " "
ui_print "- Done. Reboot, then open the microG app"
ui_print "  and run Self-Check."
ui_print "  'System spoofs signature' must be green."
ui_print " "
