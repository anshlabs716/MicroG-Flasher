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
LOG="/sdcard/MicroG-Flasher-install.log"
echo "=== MicroG Flasher install $(date) ===" >> "$LOG" 2>/dev/null

# ---------------- helpers ----------------

# ui_print + persistent log so failures are diagnosable after the fact
say() {
  ui_print "$1"
  echo "$1" >> "$LOG" 2>/dev/null
}

die() {
  say "! $1"
  abort "! $1"
}

# Volume-key prompt (idea from google_reinstall_module).
# Returns 0 = Vol+ (yes), 1 = Vol- (no). Falls back to 0 on no input.
choose() {
  [ "$1" ] && local delay=$1 || local delay=8
  local count=0
  while [ $count -le 12 ]; do
    timeout $delay /system/bin/getevent -lqc 1 2>&1 > "$TMPDIR/events" &
    sleep 0.5
    count=$((count + 1))
    if grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR/events" 2>/dev/null; then
      return 0
    elif grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR/events" 2>/dev/null; then
      return 1
    fi
  done
  say "- No key press detected, continuing"
  return 0
}

# Hide a system package systemlessly by replacing its containing
# directory with an empty .replace stub (Magisk magic mount).
mask_dir() {
  local d="$1" rel mdir
  case "$d" in
    # module "system/" maps onto the /system partition itself;
    # product/system_ext/vendor keep their name under system/
    /system/*) rel="${d#/system}" ;;
    *)         rel="$d" ;;
  esac
  mdir="$MODPATH/system$rel"
  [ -f "$mdir/.replace" ] && return 0
  mkdir -p "$mdir"
  touch "$mdir/.replace"
  say "- Masked $(basename "$d") ($d)"
}

# Global list (space separated) of dirs to mask. Accumulated via globals
# on purpose - no command substitution, so say() output can never leak
# into the list.
MASK_DIRS=""

add_mask_dir() {
  case " $MASK_DIRS " in
    *" $1 "*) return 0 ;;
  esac
  MASK_DIRS="$MASK_DIRS $1"
}

# Append install dirs of a package from PackageManager (active installs)
scan_pm_package() {
  local pkg="$1" p
  p=$(pm path "$pkg" 2>/dev/null | sed 's/^package://')
  for p in $p; do
    case "$p" in
      /system/*|/product/*|/system_ext/*|/vendor/*) add_mask_dir "${p%/*}" ;;
      /data/*)
        say "! $pkg is a user-installed app ($p)"
        say "  Uninstall it before flashing, or it shadows microG."
        ;;
    esac
  done
}

# Append leftover Google dirs on read-only partitions.
# Canta/Shizuku "uninstalls" only remove the app for user 0 - the apk
# stays on disk and PackageManager still honors the name claim, which
# silently rejects microG. These leftovers must be masked too.
scan_remnant_dirs() {
  local part base d
  for part in /system /product /system_ext /vendor; do
    for base in priv-app app; do
      [ -d "$part/$base" ] || continue
      for d in "$part/$base"/*; do
        [ -d "$d" ] || continue
        case "$(basename "$d")" in
          GmsCore|GoogleServicesFramework|Gsf|GsfLogin|GsfProxy|\
Phonesky|Vending|GooglePlay*|Play*Store*) add_mask_dir "$d" ;;
        esac
      done
    done
  done
}

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

say "- Extracting module files"
unzip -oq "$ZIPFILE" -d "$MODPATH" \
  'module.prop' 'system/*' 'service.sh' 'uninstall.sh' >/dev/null 2>&1
[ -f "$MODPATH/module.prop" ] || die "Extraction failed"
set_perm_recursive "$MODPATH" 0 0 0755 0644

# ---------------- environment check ----------------

SDK=$(getprop ro.build.version.sdk)
say "- Android SDK: ${SDK:-unknown}"

# Free space on /data (module lives there). GmsCore is ~110 MB.
FREE_KB=$(df -k /data 2>/dev/null | tail -n 1 | tr -s ' ' | cut -d ' ' -f4)
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 262144 ] 2>/dev/null; then
  say "! Less than 256 MB free on /data"
  die "microG needs ~120 MB. Free up space and retry."
fi

# ---------------- existing / leftover Google packages ----------------
# Two cases block microG from owning com.google.android.gms:
#  1. Real GMS still installed (GApps ROM) -> duplicate name, different
#     signatures, PackageManager silently keeps the real one.
#  2. GMS "removed" with Canta/Shizuku (pm uninstall --user 0) -> the apk
#     stays on the partition and the name claim persists. pm path shows
#     nothing, so we also scan the partitions for leftovers.
# Fix for both: mask the dirs systemlessly (reversible - disable the
# module to restore stock behavior).

MASK=false

if command -v pm >/dev/null 2>&1; then
  for pkg in com.google.android.gms com.google.android.gsf \
             com.google.android.gsf.login com.android.vending; do
    scan_pm_package "$pkg"
  done
fi
scan_remnant_dirs

if [ -n "$MASK_DIRS" ]; then
  say "! Google leftovers found on the system partitions"
  say "  (installed or Canta/Shizuku-removed)."
  say "  microG cannot take over while they exist."
  say "  Mask them systemlessly? (reversible by"
  say "  disabling this module) Vol+ = yes, Vol- = abort"
  if choose 8; then
    MASK=true
  else
    die "Aborted by user. Restore/uninstall Google packages first."
  fi
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
[ -n "$GMS_SRC" ] && say "- Found local GmsCore: $GMS_SRC"
[ -n "$VENDING_SRC" ] && say "- Found local FakeStore: $VENDING_SRC"

# 2) Download whatever is missing from the latest official release
if [ -z "$GMS_SRC" ] || [ -z "$VENDING_SRC" ]; then
  say "- Fetching latest microG release info"
  JSON="$TMPDIR/release.json"
  download "$API" "$JSON" || die "No network access (or no downloader). Pre-push apks to /sdcard/MicroG-Flasher/ and retry."
  TAG=$(grep -oE '"tag_name":[[:space:]]*"[^"]*"' "$JSON" | head -n 1 | sed 's/.*: *"//;s/"//')
  [ -n "$TAG" ] || die "Could not parse release info"
  say "- microG release: $TAG"

  GMS_URL=$(grep -oE '"browser_download_url":[[:space:]]*"[^"]*com\.google\.android\.gms-[0-9]+\.apk"' "$JSON" | head -n 1 | sed 's/.*: *"//;s/"//')
  VENDING_URL=$(grep -oE '"browser_download_url":[[:space:]]*"[^"]*com\.android\.vending-[0-9]+\.apk"' "$JSON" | head -n 1 | sed 's/.*: *"//;s/"//')
  [ -n "$GMS_URL" ] || die "GmsCore apk not found in release"
  [ -n "$VENDING_URL" ] || die "FakeStore apk not found in release"

  if [ -z "$GMS_SRC" ]; then
    say "- Downloading GmsCore (~110 MB)"
    download "$GMS_URL" "$TMPDIR/$GMS_NAME" || die "GmsCore download failed"
    check_apk "$TMPDIR/$GMS_NAME" 50000000 || die "GmsCore download is corrupt"
    GMS_SRC="$TMPDIR/$GMS_NAME"
  fi
  if [ -z "$VENDING_SRC" ]; then
    say "- Downloading FakeStore (~4 MB)"
    download "$VENDING_URL" "$TMPDIR/$VENDING_NAME" || die "FakeStore download failed"
    check_apk "$TMPDIR/$VENDING_NAME" 1000000 || die "FakeStore download is corrupt"
    VENDING_SRC="$TMPDIR/$VENDING_NAME"
  fi
fi

# ---------------- masking (before install) ----------------

if [ "$MASK" = "true" ]; then
  for d in $MASK_DIRS; do
    mask_dir "$d"
  done
fi

# ---------------- install ----------------

say "- Installing microG systemlessly"
mkdir -p "$MODPATH/system/priv-app/GmsCore" \
         "$MODPATH/system/priv-app/FakeStore"
cp -f "$GMS_SRC"     "$MODPATH/system/priv-app/GmsCore/GmsCore.apk"
cp -f "$VENDING_SRC" "$MODPATH/system/priv-app/FakeStore/FakeStore.apk"
set_perm "$MODPATH/system/priv-app/GmsCore/GmsCore.apk"  0 0 0644 \
  u:object_r:system_file:s0
set_perm "$MODPATH/system/priv-app/FakeStore/FakeStore.apk" 0 0 0644 \
  u:object_r:system_file:s0

say "- Installed GmsCore + FakeStore"
say "  (permission XMLs + sysconfig included)"
say " "
say "- Done. Reboot, then open the microG app"
say "  and run Self-Check."
say "  'System spoofs signature' must be green."
say " "
echo "=== install finished OK $(date) ===" >> "$LOG" 2>/dev/null
