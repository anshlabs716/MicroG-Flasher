#!/system/bin/sh
# MicroG Flasher - post-boot
# 1) Legacy spoofing ROMs expose FAKE_PACKAGE_SIGNATURE as a grantable
#    permission; modern (microG-aware) ROMs grant it automatically to
#    priv-apps. Best-effort, harmless if it fails.
# 2) If the package name was "uninstalled" for user 0 before (Canta/
#    Shizuku debloat), the per-user hidden state can stick to the name
#    and keep the freshly flashed microG invisible. pm install-existing
#    revives it. Resolves to our microG because the real GMS is masked.

MODDIR=${0%/*}

(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done
  pm grant com.google.android.gms android.permission.FAKE_PACKAGE_SIGNATURE >/dev/null 2>&1
  pm grant com.android.vending android.permission.FAKE_PACKAGE_SIGNATURE >/dev/null 2>&1
  pm install-existing com.google.android.gms >/dev/null 2>&1
  pm install-existing com.android.vending >/dev/null 2>&1
) &
