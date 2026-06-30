# Android Deployment Reference

System-wide canonical reference for shipping Android apps from any project on this machine.

## Meta-rules

- **Consult first.** Any project planning or executing an Android deploy MUST read this file before designing or running the deployment.
- **Update on change.** Any time a project changes how it deploys Android, this file MUST be updated to reflect the new canonical process. If two projects diverge on a step, document both branches here with which project uses which.

## Testing / prototype deployment

This is the current default for every Android app on this machine. Source-of-truth project: **DanCode** (`~/projects/meta/DanCode/android/`). When porting to a new project, mirror this structure unless there's a deliberate reason to diverge — then document the divergence above.

### Toolchain (one-time, project-local)

```bash
bash <project>/android/scripts/bootstrap-toolchain.sh
```

- Installs JDK 17 (Temurin 17.0.12+7) and Android SDK (cmdline-tools, platform-tools, `platforms;android-35`, `build-tools;35.0.0`) under `<project>/android/.toolchain/` (gitignored).
- Idempotent. Does not touch the system `java`. SDK licenses accepted non-interactively.
- `<project>/android/gradlew` is the stock wrapper with a header that sources `.toolchain/env.sh` and `cd`s into `android/`, so any caller gets JDK 17 + project-local SDK without env changes.

### Signing

- **Debug-signed only.** `buildTypes { debug { isMinifyEnabled = false } }` is the only configured build type. No `release` block, no keystore configuration.
- The signing key is the standard AGP-generated `~/.android/debug.keystore` (auto-created on first `assembleDebug`, default passphrase `android`).
- No passphrase storage step. If `~/.android/debug.keystore` is missing, AGP regenerates it on the next build — the APK signature changes, so users must uninstall the prior debug build before reinstalling.

### Build

```bash
<project>/android/gradlew :app:assembleDebug   # debug-signed APK
<project>/android/gradlew test                 # headless unit tests
```

Outputs:

- APK → `<project>/android/app/build/outputs/apk/debug/app-debug.apk`
- Unit test reports → `<project>/android/app/build/reports/tests/testDebugUnitTest/`

### Version bumping

Manual edit of `<project>/android/app/build.gradle.kts`:

```kotlin
defaultConfig {
    versionCode = N        // bump integer for every published build
    versionName = "X.Y.Z"  // human-readable
}
```

No automation. Bump before running the publish script.

### Get the APK onto the phone (hosted-download path)

DanCode hosts the APK on its own server behind a pinned-TLS Caddy front, and the phone browser sideloads it. The pattern:

1. **Publish from the build host (the dev box).** Build + copy current APK into the served dir, snapshotting the prior build as `*.previous.apk` for rollback:

   ```bash
   bash <project>/android/reverse-proxy/scripts/publish-apk.sh
   ```

   - DanCode's defaults: `DST_DIR=/var/lib/dancode-apk`, current = `dancode-android-debug.apk`, previous = `dancode-android-debug.previous.apk`.
   - Override `DST_DIR=...` to publish into a different directory.

2. **Caddy serves the directory** over the same pinned-TLS origin the app talks to. DanCode's config (`<project>/android/reverse-proxy/Caddyfile`):

   ```
   https://<server-ip>:8443 {
       tls /etc/caddy/<project>-server.crt /etc/caddy/<project>-server.key { protocols tls1.2 tls1.3 }
       handle_path /downloads/* {
           root * /var/lib/<project>-apk
           file_server { browse; index off }
       }
       # ...rest proxies to the backend
   }
   ```

3. **Install Caddy config (one-time):**

   ```bash
   sudo <project>/android/reverse-proxy/install.sh
   sudo systemctl reload caddy
   ```

4. **Phone sideloads** by visiting `https://<server-ip>:8443/downloads/<apk-name>.apk` in the phone browser. Accept the self-signed cert warning once. Tap the APK to install (Android prompts for "install unknown apps" permission once per source app).

5. **Rollback:** re-sideload `*.previous.apk` from the same `/downloads/` directory.

### TLS pinning (only if the app pins its server)

If the app pins its server's cert (DanCode does — Techloq blocks new hostnames, so there's no domain, just a bare IP + self-signed cert + SPKI pin in `network_security_config.xml`):

```bash
bash <project>/android/reverse-proxy/scripts/generate-cert.sh   # mint cert (SAN=IP:<server-ip>)
bash <project>/android/reverse-proxy/scripts/sync-pin.sh        # copy cert into app raw/, rewrite pin in NSC.xml
# then rebuild + republish APK:
bash <project>/android/reverse-proxy/scripts/publish-apk.sh
```

The private key is gitignored; the cert is committed for reproducible tests.

### Manual smoke tests

Gated tests are headless (`./gradlew test`). The on-phone path is not gated — every phase ships with a manual smoke checklist in the project's `android/README.md` (DanCode example: "Manual smoke" sections per phase). When porting, write a smoke checklist for each user-visible slice.

### Key paths (DanCode reference layout)

```
<project>/android/
├── scripts/bootstrap-toolchain.sh
├── .toolchain/                  (gitignored — JDK 17 + Android SDK)
├── gradlew                      (wrapper, sources .toolchain/env.sh)
├── app/build.gradle.kts         (versionCode, versionName, debug block)
├── app/build/outputs/apk/debug/app-debug.apk
└── reverse-proxy/
    ├── Caddyfile
    ├── install.sh
    ├── certs/server.crt         (committed)
    ├── certs/server.key         (gitignored)
    └── scripts/
        ├── generate-cert.sh
        ├── sync-pin.sh
        └── publish-apk.sh
```

## Production deployment

Not configured. Everything on this machine is testing/prototype today. When the first production Android deployment happens — Play Store internal track, signed release APK with a real upload key, Firebase App Distribution, anything beyond debug-signed sideload — document the process here in the same structure (toolchain → signing → build → version bumping → distribution → rollback → smoke).
