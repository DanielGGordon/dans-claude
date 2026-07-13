# Android Deployment Reference

System-wide canonical reference for shipping Android apps from any project on this machine.

## Meta-rules

- **Consult first.** Any project planning or executing an Android deploy MUST read this file before designing or running the deployment.
- **Update on change.** Any time a project changes how it deploys Android, this file MUST be updated to reflect the new canonical process. If two projects diverge on a step, document both branches here with which project uses which.

## Testing / prototype deployment

This is the current default for native-Kotlin Android apps on this machine. The structure below originated in **DanCode** (`~/projects/meta/DanCode/android/`), which remains the historical pattern source — but **DanCode is dormant; never target it for new work.** New projects should adopt the **android-framework** (`~/projects/android-framework`, see "Automated testing" section below); its `testapp/android/` is the current reference implementation of this layout (same `bootstrap-toolchain.sh` + gradlew-header conventions, plus the test layers). When porting to a new project, mirror this structure unless there's a deliberate reason to diverge — then document the divergence.

**Divergent branch:** T3 Code is an Expo/React Native app and deploys differently — see the "T3 Code (Expo/React Native)" section below.

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

Manual checklists are now the **fallback, not the default** — the android-framework's emulator layers (see "Automated testing" below) cover UI flows, screenshots, and instrumented behavior automatically. New user-visible slices ship a Maestro flow or instrumented test *first*; a manual-checklist entry in the project's `android/README.md` is reserved for what the emulator genuinely can't cover (real TLS-pin behavior against production Caddy, camera, OEM installer prompts), and each such entry should name why it can't be automated. A *thin* release-candidate phone checklist remains forever.

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

## Automated testing (android-framework emulator layer) — canonical

**Framework repo: `~/projects/android-framework`.** This is the canonical testing/emulator layer for all Android work on this machine (adopted as canonical 2026-07-13, end of its Phase 5). Any project doing Android testing MUST use it rather than inventing its own emulator/test tooling. The agent guide is **`~/projects/android-framework/docs/agent-driving.md`** — read it before driving the emulator; it is the contract (exact commands, guardrails, multi-AVD use).

### Emulator lifecycle — `scripts/emu.sh`

```bash
cd ~/projects/android-framework
scripts/emu.sh start test35      # idempotent; quickboot snapshot, ~9 s warm start
scripts/emu.sh wait test35
scripts/emu.sh status test35
scripts/emu.sh restart test35    # recovery verb (also: --no-snapshot for pristine runs)
scripts/emu.sh stop test35       # graceful (adb emu kill → snapshot save), verified-PID fallback
```

- Headless official emulator on native KVM; machine-level SDK at `~/Android/Sdk` with `google_apis` (not `playstore`) x86_64 images. One-time provisioning: `WITH_EMULATOR=1 scripts/bootstrap-toolchain.sh`.
- **Multi-AVD:** start any installed AVD by name; console/adb port pairs are allocated automatically (5554/5555, 5556/5557, …). Guardrails: 4096 MiB / 4 cores per AVD, refuses below 16 GiB host `MemAvailable`, 3–4 concurrent AVDs max.
- **Serial resolution — never hardcode `emulator-5554`.** Each AVD's state lives at `/tmp/android-framework/<avd>.state`; resolve the serial from it:

  ```bash
  serial=$(awk -F= '$1 == "SERIAL" {print $2}' /tmp/android-framework/test35.state)
  adb -s "$serial" install -r app/build/outputs/apk/debug/app-debug.apk
  ```

  Framework scripts (`flow.sh`, `screenshot.sh`, `run-all-tests.sh`) do this themselves; set `ANDROID_AVD=<name>` to target a non-default AVD.
- Agents use these scripts only — never raw `emulator` commands.

### Test layers (cheapest-first; put each test at the cheapest layer that catches the bug)

1. **JVM unit tests** — `./gradlew test`. Unchanged from the deployment sections above.
2. **Roborazzi screenshot tests** — Robolectric-based, run on the JVM, no emulator. `recordRoborazziDebug` writes baselines, `verifyRoborazziDebug` diffs against them. **Baseline PNGs are committed as fixtures** (e.g. `app/src/test/.../__screenshots__/`); treat re-records as reviewed diffs.
3. **Espresso connected tests** — `./gradlew connectedDebugAndroidTest` against the running emulator. **Gotcha: `connectedDebugAndroidTest` uninstalls the app under test when it finishes**; the framework's `testapp/run-all-tests.sh` reinstalls the debug APK afterward so the emulator stays usable for Maestro/manual driving — mirror that in project test runners.
4. **Maestro flows** — black-box UI flows, committed at `<project>/android/maestro/*.yaml`, run via **`scripts/flow.sh <flow>`** (boots/waits for the AVD, resolves the recorded serial; exit 0 = all assertions passed). Artifacts (screenshots, diagnostics) land under **`artifacts/maestro/`**, with `artifacts/maestro/LATEST` pointing at the newest run.

Visual verification: `scripts/screenshot.sh out.png [avd]` — the agent Reads the PNG and evaluates it (Android analogue of `~/.claude/playwright.md`).

### Adopting projects

- **testapp** (`~/projects/android-framework/testapp/`) — the reference guinea-pig app; all four layers green via `testapp/run-all-tests.sh`.
- **abba-bank** (`~/projects/abba-bank/android/`) — first real adopter: a framework-based **TWA** (Trusted Web Activity wrapping the existing Next.js PWA, per `plans/abba-android.md`), built on the framework from day one on branch `android-framework-adoption`. Uses the framework toolchain/gradlew conventions and targets the framework emulator + `flow.sh` for its smoke flow. As of 2026-07-13: `android/` scaffold in place (`app/`, `gradle/`, `gradlew`, `scripts/bootstrap-toolchain.sh`, `maestro/`), debug APK builds (`app-debug.apk`, appId `com.abbabank.twa`), and `android/maestro/smoke.yaml` exists but is **entry-state-only** (asserts the "Abba Bank" / "Email address" / "Send magic link" entry screen + screenshot) — the full magic-link sign-in → balance flow was not automated in the first pass. The adoption run's final commit was still completing when this was written — check the branch for final state.
- **DanCode** — dormant; historical pattern source only. Do not adopt the framework into it.
- Expo/RN projects (T3 Code): emulator + Maestro layers apply as-is; Roborazzi does not (use Maestro screenshots for visual regression). Note x86_64 emulator images need an x86_64/universal build variant, not arm64-only.

## T3 Code (Expo/React Native) — divergent branch

Project: `~/projects/meta/t3code-v2` (fork of `pingdotgg/t3code`), app at `apps/mobile`. First deployed 2026-07-08 from branch `t3code/android-deploy-sideload`. Diverges from the DanCode structure because the `android/` project is **generated** by `expo prebuild`, not committed — so there is no project-local toolchain dir.

### Host identity gotcha (read first)

The build host, the T3 server, and the DanCode server are all the **same machine**: `dancode` = 15.204.108.12. Claude agent sessions for T3 run *inside* `t3code.service` on this box — `systemctl --user restart t3code.service` kills every running agent session (including your own commands, mid-flight). Restart it only at the very end of a work sequence, and expect the session to resume afterward.

### Toolchain (machine-level, one-time)

- JDK 17 via mise (`JAVA_HOME=$(mise where java)`).
- Android SDK at `~/Android/Sdk`: `cmdline-tools/latest`, `platform-tools`, `platforms;android-36`, `build-tools;36.0.0`, `ndk;27.1.12297006`, `cmake;3.22.1` (RN 0.85 pins; Gradle auto-downloads additional pinned packages). Installed via `sdkmanager`, licenses accepted with `yes |`. Note: no `unzip` on this box — extract cmdline-tools with `python3 -m zipfile -e`.

### Build (sideloadable APK)

```bash
cd apps/mobile
export JAVA_HOME=$(mise where java) ANDROID_HOME=$HOME/Android/Sdk
APP_VARIANT=preview EXPO_NO_GIT_STATUS=1 npx expo prebuild --clean --platform android
cd android && ./gradlew :app:assembleRelease -PreactNativeArchitectures=arm64-v8a
# → app/build/outputs/apk/release/app-release.apk (~90MB, first build ~8 min, warm ~3-5)
```

- **Variant:** `preview` ("T3 Code Preview", `com.t3tools.t3code.preview`) — installable side-by-side with any future store build.
- **Signing:** the stock Expo template signs `release` with `~/.android/debug.keystore` — debug-signed sideload, same keystore caveats as DanCode (regenerated keystore ⇒ uninstall before reinstall).
- **ABI:** `-PreactNativeArchitectures=arm64-v8a` halves build time; drop it for a universal APK.
- **expo-updates** is enabled and points at upstream's EAS project, but the `fingerprint` runtime-version policy means no foreign OTA can apply to a local build. Harmless; leave it.

### Self-signed TLS trust (required for pairing)

The app pairs to `https://15.204.108.12:7443` (Caddy, self-signed cert, Techloq-driven bare-IP pattern). Android rejects self-signed TLS unless the app ships a trust anchor:

- `apps/mobile/plugins/withAndroidSelfSignedServerTrust.cjs` writes a `network_security_config.xml` trusting `apps/mobile/certs/t3-server.crt` (committed; SAN=IP:15.204.108.12, expires 2036) alongside system CAs, and keeps cleartext permitted for tailnet/LAN.
- If the cert is ever re-minted: re-fetch it (`openssl s_client -connect 15.204.108.12:7443 -showcerts`), replace `certs/t3-server.crt`, rebuild.

### Publish + sideload

```bash
bash apps/mobile/scripts/publish-android-apk.sh   # copies APK → /var/lib/t3code-apk, keeps *.previous.apk
```

- Caddy serves `/var/lib/t3code-apk` at `https://15.204.108.12:7443/downloads/` (handle_path block inside the :7443 site; `admin off` means config changes need `systemctl restart caddy`, not reload).
- Phone: browse to `https://15.204.108.12:7443/downloads/t3code-android-preview.apk`, accept the cert warning (browser only — the app itself trusts the cert), install.
- Pair: mint a token on the server (`t3 auth pairing create`, one-time, ~5 min expiry), then in the app enter host `https://15.204.108.12:7443` + the token (or scan the QR).
- Rollback: sideload `t3code-android-preview.previous.apk` from the same directory.

### Server-version skew

The mobile app and `t3code.service` must run compatible `packages/contracts`. Deploy them from the same branch: build the APK and fast-forward `~/projects/meta/t3code-v2` to the same commit, `pnpm install`, then restart the service (see gotcha above).

## Production deployment

Not configured. Everything on this machine is testing/prototype today. When the first production Android deployment happens — Play Store internal track, signed release APK with a real upload key, Firebase App Distribution, anything beyond debug-signed sideload — document the process here in the same structure (toolchain → signing → build → version bumping → distribution → rollback → smoke).
