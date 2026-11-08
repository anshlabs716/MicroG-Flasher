#!/system/bin/sh
# MicroG Flasher - nothing systemless to clean up. Removing the module in
# the Magisk app unmounts the priv-app entries, the permission XMLs and
# the Google-package masks on reboot; stock GMS (if any) comes back.
rm -f /data/adb/microg_flasher_boot_pending /data/adb/microg_flasher_disabled_reason
