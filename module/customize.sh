#!/system/bin/sh
#################
# MicroG-Flasher
# Downloads the latest official microG apks from GitHub at install time
# and installs them systemlessly as privileged system apps.
# Masks real/Canta-removed Google packages so microG owns the names.
#
# Offline fallback: push apks to /sdcard/MicroG-Flasher/ (or Download):
#   adb push com.google.android.gms-252432034.apk  /sdcard/MicroG-Flasher/
#   adb push com.android.vending-84022634.apk      /sdcard/MicroG-Flasher/
#################

SKIPUNZIP=1

API="https://api.github.com/repos/microg/GmsCore/releases/latest"
PAGE_URL="https://github.com/microg/GmsCore/releases/latest"
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

# Volume-key prompt. 0 = Vol+ (yes), 1 = Vol- (no). Defaults to yes so a
# headless install is never stuck for minutes waiting for input.
choose() {
  local count=0
  say "  (Vol+ = yes, Vol- = abort; continuing in ~8s)"
  while [ $count -lt 4 ]; do
    timeout 2 /system/bin/getevent -lqc 1 > "$TMPDIR/events" 2>/dev/null
    if grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR/events" 2>/dev/null; then
      return 0
    elif grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR/events" 2>/dev/null; then
      return 1
    fi
    count=$((count + 1))
  done
  say "- No key press detected, continuing"
  return 0
}

# Robust downloader: curl, then wget, then Magisk's own busybox. Retries.
fetch() {
  local try
  for try in 1 2 3; do
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail --connect-timeout 15 --max-time 900 \
        -o "$2" "$1" >/dev/null 2>&1 && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
      wget -q -O "$2" "$1" >/dev/null 2>&1 && return 0
    fi
    if [ -x /data/adb/magisk/busybox ]; then
      /data/adb/magisk/busybox wget -q -O "$2" "$1" >/dev/null 2>&1 && return 0
    fi
    sleep 2
  done
  return 1
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

# Find an apk on internal storage. $1 = package name prefix,
# $2 = minimum size. Result in $REPLY. Skips -hw/-user variants.
find_local_apk() {
  local d f base
  for d in /sdcard/MicroG-Flasher /sdcard/Download /sdcard; do
    for f in "$d/$1"-*.apk "$d/$1.apk"; do
      base="$(basename "$f")"
      case "$base" in
        *-hw.apk|*-user.apk) continue ;;
      esac
      if check_apk "$f" "$2"; then REPLY="$f"; return 0; fi
    done
  done
  return 1
}

# ---------------- banner + guards ----------------

say " "
say "- MicroG Flasher"

if [ "$BOOTMODE" != "true" ]; then
  say "! Recovery installation is intentionally unsupported."
  die "Install through Magisk app > Modules > Install from storage."
fi

if [ -n "$MAGISK_VER_CODE" ]; then
  if [ "$MAGISK_VER_CODE" -lt 24000 ] 2>/dev/null; then
    die "Magisk v24.0+ required"
  fi
fi

SDK=$(getprop ro.build.version.sdk)
if [ -z "$SDK" ] || [ "$SDK" -lt 26 ] 2>/dev/null; then
  die "Android 8.0 (SDK 26) or newer required"
fi
say "- Android SDK: $SDK"

# Free space on /data (module lives there). GmsCore is ~110 MB.
FREE_KB=$(df -k /data 2>/dev/null | tail -n 1 | tr -s ' ' | cut -d ' ' -f4)
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 262144 ] 2>/dev/null; then
  say "! Less than 256 MB free on /data"
  die "microG needs ~120 MB. Free up space and retry."
fi

# ---------------- module files ----------------

say "- Extracting module files"
unzip -oq "$ZIPFILE" -d "$MODPATH" \
  'module.prop' 'system/*' 'service.sh' 'action.sh' 'uninstall.sh' \
  'post-fs-data.sh' >/dev/null 2>&1
[ -f "$MODPATH/module.prop" ] || die "Extraction failed"
set_perm_recursive "$MODPATH/system" 0 0 0755 0644

# ---------------- Google state detection ----------------
# microG cannot own com.google.android.gms while something else claims it:
#  1. Real GMS installed (GApps ROM) -> duplicate name, wrong signature,
#     PackageManager silently keeps the real one.
#  2. GMS "removed" with Canta/Shizuku (pm uninstall --user 0) -> the apk
#     stays on the partition and the claim persists even though pm path
#     shows nothing.
#  3. Real GMS updated into /data -> masking the system copy is not
#     enough, the data copy still claims the name. Must be cleaned first.

REAL_GMS=0
if command -v pm >/dev/null 2>&1; then
  GMS_PATH=$(pm path com.google.android.gms 2>/dev/null | head -n 1 | sed 's/^package://')
  if [ -n "$GMS_PATH" ]; then
    # If the installed GMS already has the spoofing permission it is
    # (almost certainly) microG from a previous flash - leave it alone.
    if pm dump com.google.android.gms 2>/dev/null | grep -qi 'fake_package_signature'; then
      say "- Existing microG install detected, updating in place"
    else
      REAL_GMS=1
    fi
  fi
fi

# Collect dirs to mask (global list, no command-substitution capture)
MASK_DIRS=""
add_mask_dir() {
  case " $MASK_DIRS " in
    *" $1 "*) return 0 ;;
  esac
  MASK_DIRS="$MASK_DIRS $1"
}

# Partition dirs of a package from PackageManager (active installs only)
scan_pm_package() {
  local pkg="$1" p
  p=$(pm path "$pkg" 2>/dev/null | sed 's/^package://')
  for p in $p; do
    case "$p" in
      /system/*|/product/*|/system_ext/*|/vendor/*) add_mask_dir "${p%/*}" ;;
      /data/*)
        say "! $pkg has a copy in /data ($p)"
        ;;
    esac
  done
}

# Leftover Google dirs on read-only partitions (Canta/Shizuku leftovers)
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

# Count /data copies of the real Google packages
data_copies_of() {
  pm path "$1" 2>/dev/null | sed 's/^package://' | grep -c '^/data/'
}

if [ "$REAL_GMS" = "1" ]; then
  DATA_COPIES=0
  for pkg in com.google.android.gms com.android.vending com.google.android.gsf; do
    DATA_COPIES=$((DATA_COPIES + $(data_copies_of "$pkg")))
  done
  if [ "$DATA_COPIES" -gt 0 ]; then
    say "! Real Google Play services has updates in /data."
    say "  Masking the system copy is not enough - the data"
    say "  copy keeps claiming the package and Google apps"
    say "  would break after reboot. Clean it first:"
    say "    1. Turn off Wi-Fi and mobile data"
    say "    2. Settings > Apps > show system apps"
    say "    3. For Google Play services / Play Store /"
    say "       Google Services Framework: uninstall"
    say "       updates, then clear storage"
    say "    4. Reboot, then flash this module again"
    die "Nothing was changed. Your device is untouched."
  fi
  for pkg in com.google.android.gms com.android.vending com.google.android.gsf; do
    scan_pm_package "$pkg"
  done
fi

scan_remnant_dirs

if [ -n "$MASK_DIRS" ]; then
  say "! Google leftovers found on the system partitions"
  say "  (installed or Canta/Shizuku-removed)."
  say "  microG cannot take over while they exist."
  say "  Mask them systemlessly? Reversible: disable"
  say "  this module and everything comes back."
  if choose; then
    MASK=true
  else
    die "Aborted by user. Restore/uninstall Google packages first."
  fi
else
  MASK=false
fi

# ---------------- locate apks ----------------

GMS_SRC=""
VENDING_SRC=""

if find_local_apk "com.google.android.gms" 50000000; then
  GMS_SRC="$REPLY"
  say "- Found local GmsCore: $GMS_SRC"
fi
if find_local_apk "com.android.vending" 1000000; then
  VENDING_SRC="$REPLY"
  say "- Found local FakeStore: $VENDING_SRC"
fi

if [ -z "$GMS_SRC" ] || [ -z "$VENDING_SRC" ]; then
  say "- Fetching latest microG release info"
  JSON="$TMPDIR/release.json"
  fetch "$API" "$JSON"
  if [ -f "$JSON" ]; then
    TAG=$(grep -oE '"tag_name":[[:space:]]*"[^"]*"' "$JSON" | head -n 1 | sed 's/.*: *"//;s/"//')
    GMS_URL=$(grep -oE '"browser_download_url":[[:space:]]*"[^"]*com\.google\.android\.gms-[0-9]+\.apk"' "$JSON" | head -n 1 | sed 's/.*: *"//;s/"//')
    VENDING_URL=$(grep -oE '"browser_download_url":[[:space:]]*"[^"]*com\.android\.vending-[0-9]+\.apk"' "$JSON" | head -n 1 | sed 's/.*: *"//;s/"//')
  fi
  # Fallback: scrape the releases page (works when the API is rate-limited)
  if [ -z "$GMS_URL" ] || [ -z "$VENDING_URL" ]; then
    say "- API unavailable, trying releases page"
    HTML="$TMPDIR/releases.html"
    fetch "$PAGE_URL" "$HTML" || true
    if [ -f "$HTML" ]; then
      [ -z "$TAG" ] && TAG=$(grep -oE 'releases/tag/v[0-9.]+' "$HTML" | head -n 1 | sed 's|.*/tag/||')
      GMS_URL=$(grep -oE '/microg/GmsCore/releases/download/[^"]*com\.google\.android\.gms-[0-9]+\.apk' "$HTML" | head -n 1)
      [ -n "$GMS_URL" ] && GMS_URL="https://github.com$GMS_URL"
      VENDING_URL=$(grep -oE '/microg/GmsCore/releases/download/[^"]*com\.android\.vending-[0-9]+\.apk' "$HTML" | head -n 1)
      [ -n "$VENDING_URL" ] && VENDING_URL="https://github.com$VENDING_URL"
    fi
  fi
  [ -n "$TAG" ] && say "- microG release: $TAG"
  [ -n "$GMS_URL" ] || die "GmsCore apk not found. Push it to /sdcard/MicroG-Flasher/ and retry."
  [ -n "$VENDING_URL" ] || die "FakeStore apk not found. Push it to /sdcard/MicroG-Flasher/ and retry."

  if [ -z "$GMS_SRC" ]; then
    say "- Downloading GmsCore (~110 MB)"
    fetch "$GMS_URL" "$TMPDIR/gms.apk" || die "GmsCore download failed"
    check_apk "$TMPDIR/gms.apk" 50000000 || die "GmsCore download is corrupt"
    GMS_SRC="$TMPDIR/gms.apk"
  fi
  if [ -z "$VENDING_SRC" ]; then
    say "- Downloading FakeStore (~4 MB)"
    fetch "$VENDING_URL" "$TMPDIR/vending.apk" || die "FakeStore download failed"
    check_apk "$TMPDIR/vending.apk" 1000000 || die "FakeStore download is corrupt"
    VENDING_SRC="$TMPDIR/vending.apk"
  fi
fi

# ---------------- masking (before install) ----------------

if [ "$MASK" = "true" ]; then
  for d in $MASK_DIRS; do
    # module "system/" maps onto the /system partition itself;
    # product/system_ext keep their name under system/
    case "$d" in
      /system/*) rel="${d#/system}" ;;
      *)         rel="$d" ;;
    esac
    mdir="$MODPATH/system$rel"
    [ -f "$mdir/.replace" ] && continue
    mkdir -p "$mdir"
    : > "$mdir/.replace"
    say "- Masked $(basename "$d") ($d)"
  done
fi

# ---------------- install ----------------

say "- Installing microG systemlessly"
mkdir -p "$MODPATH/system/priv-app/GmsCore" \
         "$MODPATH/system/priv-app/FakeStore"
cp -f "$GMS_SRC"     "$MODPATH/system/priv-app/GmsCore/GmsCore.apk"
cp -f "$VENDING_SRC" "$MODPATH/system/priv-app/FakeStore/FakeStore.apk"
set_perm "$MODPATH/system/priv-app/GmsCore/GmsCore.apk" 0 0 0644 \
  u:object_r:system_file:s0
set_perm "$MODPATH/system/priv-app/FakeStore/FakeStore.apk" 0 0 0644 \
  u:object_r:system_file:s0

# Old devices (pre-dynamic partitions): /product is not a mount point, so
# consolidate everything into system/ instead.
if [ "$SDK" -lt 28 ] || { [ ! -d /product ] && [ ! -L /system/product ]; }; then
  if [ -d "$MODPATH/system/product" ]; then
    cp -a "$MODPATH/system/product/." "$MODPATH/system/" 2>/dev/null
    rm -rf "$MODPATH/system/product"
    say "- Legacy device: consolidated product overlay into system/"
  fi
fi

# ---------------- signature spoofing expectation ----------------

SPOOF="unknown"
for prop in ro.calyxos.version ro.iode.version ro.e.version ro.divest.version; do
  [ -n "$(getprop "$prop" 2>/dev/null)" ] && SPOOF="yes"
done
[ "$SPOOF" = "unknown" ] && [ -n "$(getprop ro.lineage.version 2>/dev/null)" ] && SPOOF="likely"
if [ "$SPOOF" = "unknown" ]; then
  say "! This ROM is not a known spoofing ROM. If microG"
  say "  Self-Check shows 'System spoofs signature' red"
  say "  after reboot, the ROM lacks signature spoofing"
  say "  (stock ROMs need LSPosed + FakeGApps)."
fi

say "- Installed GmsCore + FakeStore"
say " "
say "- Done. First boot may take 2-5 minutes while"
say "  PackageManager optimizes microG - do not force"
say "  reboot during it."
say "- Then open the microG app and run Self-Check."
say " "
echo "=== install finished OK $(date) ===" >> "$LOG" 2>/dev/null
