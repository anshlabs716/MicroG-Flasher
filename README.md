# MicroG-Flasher

A Magisk module that **actually flashes microG**. Instead of bundling stale apks, it downloads the **latest official, signed microG apks** straight from the [microG GmsCore releases](https://github.com/microg/GmsCore/releases) at install time, and installs them systemlessly as privileged system apps with the correct permission allowlists.

- **GmsCore** (`com.google.android.gms`) — microG Services
- **FakeStore** (`com.android.vending`) — the Play Store stub
- `privapp-permissions-microg.xml` — privileged permission allowlist
- `microg-permissions.xml` — default permission grants
- `microg.xml` — sysconfig (battery/data/location allowlists, push broadcasts)

## Install

1. Download the latest zip from [Releases](https://github.com/anshlabs716/MicroG-Flasher/releases) (or build it yourself with `./build.sh`).
2. Magisk app → **Modules → Install from storage** → pick the zip.
3. Keep Wi-Fi on: the module downloads ~115 MB of apks during install.
4. Reboot, open the **microG** app, run **Self-Check** — "System spoofs signature" must be green. In Aurora Store, set the installer to *Aurora Services* and log in anonymously.

### Offline install (no network during flash)

Pre-push the apks and the module picks them up automatically:

```sh
adb push com.google.android.gms.apk  /sdcard/MicroG-Flasher/
adb push com.android.vending.apk     /sdcard/MicroG-Flasher/
```

Filenames matter exactly as above. `/sdcard/Download` and `/sdcard` also work as search paths.

### Safety features

- **Bootloop watchdog** — if the device fails to boot twice after flashing, the module disables itself (reason in `/data/adb/microg_flasher_disabled_reason`).
- **"Action" button** — Magisk app → module → Action: re-runs the post-boot fixup (`pm install-existing` + legacy spoofing grants) if microG is installed but invisible.
- **/data-update guard** — if real GMS has been updated into `/data` (common on GApps ROMs that auto-update Play Store), the installer aborts untouched with cleanup instructions instead of leaving you with broken Google apps.

## ROM compatibility

microG needs **signature spoofing**. Since Feb 2024, many ROMs ship "microG-tied" spoofing: they auto-spoof the official microG signature when it's installed as a priv-app — which is exactly what this module does, using only official release apks.

| ROM state | Result |
| --- | --- |
| LineageOS (2024-02+), e/OS, CalyxOS, iodéOS, DivestOS, most LineageOS forks | ✅ Works out of the box |
| Older custom ROMs with the classic spoofing toggle | ✅ Enable spoofing for microG in ROM settings |
| **GApps ROM** (real Google Play services present) | ✅ The installer offers to **mask real GMS systemlessly** (Vol+ at the prompt) so microG owns `com.google.android.gms`. Reversible: disable the module and stock GMS is back. |
| **GApps debloated with Canta/Shizuku** (`pm uninstall --user 0`) | ✅ Same masking flow — the apks stay on `/product`/`/system_ext` after a user-0 uninstall and still block microG; the installer scans the partitions directly and masks what it finds. A boot-time `pm install-existing` also clears any stuck per-user "uninstalled" flag. |
| Stock ROM / ROM without spoofing | ⚠️ Installs, but Google-signature-checking apps break. Add spoofing with **LSPosed + FakeGApps** (Android ≤ 15). Stock Android 16: no supported path yet. |

### Debugging an install

Every install appends a log to `/sdcard/MicroG-Flasher-install.log` — if a flash "does nothing", check that file first.
| ROM with real Google Play Services installed | ⚠️ Not recommended — the module warns at install. Degoogled ROMs are the target. |

The definitive check is always the microG **Self-Check** page, not third-party signature checker apps.

## Test it without a phone

`tests/e2e/run.sh` simulates the whole install inside a chroot (mocked Android
environment, real downloads) across six device states: GApps ROM, Canta-debloated,
degoogled, existing-microG, GMS-with-data-updates, and legacy non-`/product`
devices. See [tests/e2e/README.md](tests/e2e/README.md).

## Build

```sh
./build.sh   # → dist/MicroG-Flasher-vX.Y.Z.zip
```

CI builds the zip on every `v*` tag and attaches it to the GitHub release
(tags containing `beta` are marked pre-release automatically).

## Roadmap

- [ ] Recovery-flashable mode (TWRP/OrangeFox, `BOOTMODE=false` path)
- [ ] Optional `-hw` GmsCore variant

## Credits

- [microG team](https://github.com/microg) — GmsCore, FakeStore
- [TheHitMan7](https://github.com/TheHitMan7)'s microG Installer (NOU fork) — permission XML references
- [topjohnwu](https://github.com/topjohnwu/Magisk) — Magisk module template

## License

GPL-3.0 — see [LICENSE](LICENSE).
