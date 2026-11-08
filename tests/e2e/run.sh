#!/usr/bin/env bash
source /tmp/opencode/chroot-e2e/harness.sh

echo "=== Scenario B: GApps ROM, real GMS active on /product + /system ==="
build_root active
prep_script
cp "$CACHE/gms.apk" "$SB/root/sdcard/Download/com.google.android.gms-252432034.apk"
# vending NOT pre-placed -> real in-chroot download through fetch()
run_in_chroot B
report B OK "$SB/root/data/adb/modules_update/MicroG_Flasher/system/product/priv-app/GmsCore/.replace"
masks
grep -E "Masked|release:|Downloading" "$SB/out-B.txt" | sed 's/^/    /'

echo
echo "=== Scenario C: Canta-debloated (files on disk, pm silent) ==="
build_root canta
prep_script
make_apk "$SB/root/product/priv-app/GmsCore/GmsCore.apk" 1000
make_apk "$SB/root/product/priv-app/GoogleServicesFramework/Gsf.apk" 400
cp "$CACHE/gms.apk" "$SB/root/sdcard/MicroG-Flasher/com.google.android.gms.apk"
cp "$CACHE/vending.apk" "$SB/root/sdcard/Download/com.android.vending-84022634.apk"
run_in_chroot C
report C OK "$SB/root/data/adb/modules_update/MicroG_Flasher/system/product/priv-app/GmsCore/.replace"
masks
grep -E "Masked|Found local" "$SB/out-C.txt" | sed 's/^/    /'

echo
echo "=== Scenario D: fully degoogled ROM ==="
build_root canta
prep_script
cp "$CACHE/gms.apk" "$SB/root/sdcard/Download/com.google.android.gms-252432034.apk"
cp "$CACHE/vending.apk" "$SB/root/sdcard/Download/com.android.vending-84022634.apk"
run_in_chroot D
report D OK
M=$(masks | wc -l); echo "    mask count: $M (expect 0)"

echo
echo "=== Scenario E: microG already installed (update in place) ==="
build_root microg-installed
prep_script
make_apk "$SB/root/system/priv-app/GmsCore/GmsCore.apk" 1000
cp "$CACHE/gms.apk" "$SB/root/sdcard/Download/com.google.android.gms-252432034.apk"
cp "$CACHE/vending.apk" "$SB/root/sdcard/Download/com.android.vending-84022634.apk"
run_in_chroot E
report E OK
grep "Existing microG" "$SB/out-E.txt" | sed 's/^/    /'

echo
echo "=== Scenario A: real GMS with /data update (must ABORT untouched) ==="
build_root active-dataupdate
prep_script
run_in_chroot A
report A ABORT
grep -E "updates in /data|Nothing was changed" "$SB/out-A.txt" | sed 's/^/    /'

echo
echo "=== Scenario G: old device (no /product), leftovers on /system ==="
build_root canta
prep_script
rm -rf "$SB/root/product" "$SB/root/system/product" 2>/dev/null
make_apk "$SB/root/system/priv-app/GmsCore/GmsCore.apk" 1000
make_apk "$SB/root/system/priv-app/GoogleServicesFramework/Gsf.apk" 400
cp "$CACHE/gms.apk" "$SB/root/sdcard/Download/com.google.android.gms-252432034.apk"
cp "$CACHE/vending.apk" "$SB/root/sdcard/Download/com.android.vending-84022634.apk"
run_in_chroot G
report G OK
M=$(masks); echo "$M"
if echo "$M" | grep -q "system/product"; then echo "    [FAIL] product subdir should be flattened"; else echo "    [PASS] no product subdir (flattened into system/)"; fi

echo
echo "=== ALL SCENARIOS DONE ==="
