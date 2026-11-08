#!/system/bin/sh
# MicroG Flasher - "Action" button in the Magisk app.
# Re-runs the post-boot fixup on demand: revives microG for user 0 if a
# stale per-user uninstall flag is hiding it, and re-applies the legacy
# signature-spoofing grants.

ui_print() { echo "$1"; }

ui_print "- MicroG Flasher fixup"
pm install-existing com.google.android.gms 2>&1 | head -n 1
pm install-existing com.android.vending 2>&1 | head -n 1
pm grant com.google.android.gms android.permission.FAKE_PACKAGE_SIGNATURE 2>/dev/null
pm grant com.android.vending android.permission.FAKE_PACKAGE_SIGNATURE 2>/dev/null
ui_print "- Done. If things still look wrong, reboot and run"
ui_print "  microG Self-Check. Install log: /sdcard/MicroG-Flasher-install.log"
