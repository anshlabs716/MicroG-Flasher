#!/system/bin/sh
# MicroG Flasher - post-boot
# Legacy spoofing ROMs expose FAKE_PACKAGE_SIGNATURE as a grantable
# permission; modern (microG-aware) ROMs grant it automatically to
# priv-apps. This is best-effort and harmless if it fails.

MODDIR=${0%/*}

(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done
  pm grant com.google.android.gms android.permission.FAKE_PACKAGE_SIGNATURE >/dev/null 2>&1
  pm grant com.android.vending android.permission.FAKE_PACKAGE_SIGNATURE >/dev/null 2>&1
) &
