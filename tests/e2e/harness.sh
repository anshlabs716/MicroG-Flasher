#!/usr/bin/env bash
# Faithful E2E: runs the UNMODIFIED module/customize.sh inside a chroot
# where /system, /product, /system_ext, /vendor, /data, /sdcard exist for
# real. Host userland is bind-mounted in. User namespace => no host root.
set -e
REPO=/tmp/opencode/MicroG-Flasher
SB=/tmp/opencode/chroot-rootfs
ZIP="$REPO/dist/$(ls "$REPO/dist" | grep '\.zip$' | head -1)"

build_root() { # $1 = pm mode: active|canta|microg-installed|active-dataupdate
  rm -rf "$SB"
  local R="$SB/root"
  mkdir -p "$R"/{usr,bin,lib,lib64,etc,dev,opt/mock,tmp} \
           "$R"/system/{bin,priv-app,etc/permissions,etc/default-permissions,etc/sysconfig} \
           "$R"/{product,system_ext,vendor}/priv-app \
           "$R"/data/adb/modules_update/MicroG_Flasher \
           "$R"/sdcard/{MicroG-Flasher,Download}
  cp "$ZIP" "$R/installer.zip"

  # --- device mocks ---
  cat > "$R/opt/mock/pm" <<EOF
#!/bin/bash
mode="$1"
case "\$1 \$2" in
  "path com.google.android.gms")
    [ "\$mode" = "active" ] && echo "package:/product/priv-app/GmsCore/GmsCore.apk" && echo "package:/product/priv-app/GmsCore/split_arm64.apk"
    [ "\$mode" = "active-dataupdate" ] && echo "package:/product/priv-app/GmsCore/GmsCore.apk" && echo "package:/data/app/gms-data/base.apk"
    [ "\$mode" = "microg-installed" ] && echo "package:/system/priv-app/GmsCore/GmsCore.apk"
    ;;
  "path com.google.android.gsf")
    [ "\$mode" = "active" ] && echo "package:/product/priv-app/GoogleServicesFramework/Gsf.apk"
    ;;
  "path com.android.vending")
    { [ "\$mode" = "active" ] || [ "\$mode" = "active-dataupdate" ]; } && echo "package:/system/priv-app/Phonesky/Phonesky.apk"
    ;;
  "dump com.google.android.gms")
    [ "\$mode" = "microg-installed" ] && echo "android.permission.fake_package_signature"
    ;;
esac
exit 0
EOF
  cat > "$R/opt/mock/getprop" <<'EOF'
#!/bin/bash
case "$1" in
  ro.build.version.sdk) echo 34 ;;
  ro.lineage.version) echo "21.0-20260101-t2s" ;;
esac
EOF
  # getevent that instantly "presses" Vol+
  printf '#!/bin/bash\necho "/dev/input/event1: 0001 0073 00000001"\n' > "$R/system/bin/getevent"
  chmod +x "$R/opt/mock/pm" "$R/opt/mock/getprop" "$R/system/bin/getevent"
}

make_apk() { mkdir -p "$(dirname "$1")"; printf 'PK\003\004' > "$1"; head -c "$2" /dev/zero >> "$1"; }

run_in_chroot() { # $1 = scenario label
  unshare -rm bash -e -c '
    R="'"$SB"'/root"
    mount --rbind /usr  "$R/usr"
    mount --rbind /bin  "$R/bin"
    mount --rbind /lib  "$R/lib"
    [ -d /lib64 ] && mount --rbind /lib64 "$R/lib64"
    mount --rbind /etc  "$R/etc"
    mount --rbind /dev  "$R/dev"
    /usr/sbin/chroot "$R" /bin/bash -c "
      export PATH=/opt/mock:/usr/local/bin:/usr/bin:/bin
      export MODPATH=/data/adb/modules_update/MicroG_Flasher
      export TMPDIR=/tmp ZIPFILE=/installer.zip BOOTMODE=true MAGISK_VER_CODE=27000
      ui_print() { echo \"\$1\"; }
      abort() { ui_print \"! \$1\"; touch /tmp/ABORTED; exit 1; }
      set_perm() { :; }
      set_perm_recursive() { :; }
      . /customize.sh
    "
  ' > "$SB/out-$1.txt" 2>&1 || true
}

prep_script() { cp "$REPO/module/customize.sh" "$SB/root/customize.sh"; }

report() { # $1 label, $2 expect OK|ABORT, $3 optional extra file (host path)
  local label="$1" expect="$2" extra="$3" res=FAIL detail=""
  local MP="$SB/root/data/adb/modules_update/MicroG_Flasher"
  if [ "$expect" = "ABORT" ]; then
    [ -f "$SB/root/tmp/ABORTED" ] && res=PASS || detail="$(tail -3 "$SB/out-$label.txt")"
  else
    if [ ! -f "$SB/root/tmp/ABORTED" ] \
       && [ -f "$MP/system/priv-app/GmsCore/GmsCore.apk" ] \
       && [ -f "$MP/system/priv-app/FakeStore/FakeStore.apk" ] \
       && { [ -z "$extra" ] || [ -f "$extra" ]; }; then
      res=PASS
    else
      detail="$(tail -5 "$SB/out-$label.txt")"
    fi
  fi
  echo "[$res] scenario=$label expect=$expect ${detail:+| $detail}"
}

masks() { find "$SB/root/data/adb/modules_update/MicroG_Flasher/system" -name .replace 2>/dev/null \
  | sed "s|.*/MicroG_Flasher/system/||;s/^/    mask: /"; }

CACHE=/tmp/opencode/e2e-cache
