# E2E simulation tests

Runs the **unmodified** `module/customize.sh` inside a chroot that mimics an
Android device: real `/system`, `/product`, `/system_ext`, `/vendor`,
`/data`, `/sdcard` paths, mocked `pm`/`getprop`/`getevent`, real `curl`
doing a real download from the microG GitHub release.

Requires Linux with unprivileged user namespaces (`unshare -rm`). No root.

```sh
# pre-cache the official apks once (~112 MB) so most scenarios skip downloading
mkdir -p /tmp/opencode/e2e-cache
curl -sL -o /tmp/opencode/e2e-cache/gms.apk \
  "https://github.com/microg/GmsCore/releases/latest/download/com.google.android.gms-252432034.apk"
curl -sL -o /tmp/opencode/e2e-cache/vending.apk \
  "https://github.com/microg/GmsCore/releases/latest/download/com.android.vending-84022634.apk"

bash tests/e2e/run.sh
```

## Scenarios

| Scenario | Device state | Expected result |
| --- | --- | --- |
| B | GApps ROM, real GMS active on `/product` + `/system` | masks created under `system/product/...`, apks installed, live download works |
| C | Canta/Shizuku-debloated (apks on disk, `pm path` silent) | leftovers found by partition scan, masked, install proceeds |
| D | Fully degoogled ROM | zero masks, straight install |
| E | microG already installed | "updating in place", no bogus masking |
| A | Real GMS **updated into /data** | abort with cleanup instructions, device untouched |
| G | Old device (no `/product` partition) | product overlay flattened into `system/` |

`harness.sh` builds a throwaway rootfs per scenario, bind-mounts host
userland, and runs the installer via `chroot` inside `unshare -rm`.
Assertions check the resulting module tree (`.replace` masks, priv-app
apks, XMLs) and the install output.
