# Android Deployment Reference

System-wide canonical reference for shipping Android apps from any project on this machine.

## Meta-rules

- **Consult first.** Any project planning or executing an Android deploy MUST read this file before designing or running the deployment.
- **Update on change.** Any time a project changes how it deploys Android, this file MUST be updated to reflect the new canonical process. If two projects diverge on a step, document both branches here with which project uses which.

## Testing / prototype deployment

This is the current default for native-Kotlin Android apps on this machine. The structure below originated in **DanCode** (`~/projects/meta/DanCode/android/`), which remains the historical pattern source — but **DanCode is dormant; never target it for new work.** New projects should adopt the **android-framework** (`~/projects/android-framework`, see "Automated testing" section below); its `testapp/android/` is the current reference implementation of this layout (same `bootstrap-toolchain.sh` + gradlew-header conventions, plus the test layers). When porting to a new project, mirror this structure unless there's a deliberate reason to diverge — then document the divergence.

**Divergent branches:**
- **T3 Code** is an Expo/React Native app and deploys differently — see the "T3 Code (Expo/React Native)" section below.
- **Alfred** follows this layout but owns no Caddy config, publishes one file per version behind a download page, and ships a **trust anchor** instead of an SPKI pin — see the "Alfred" section below. It is the reference for a framework-pattern app that has actually shipped to a phone.

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

### TLS trust anchor (the other option — and the one that also fixes WebViews)

Pinning by SPKI is not the only way to talk to a bare-IP self-signed origin, and it is
the wrong way if the app renders any of that origin in a **WebView or Custom Tab**.
Ship the server cert as an *additional trust anchor* instead:

```xml
<!-- res/xml/network_security_config.xml -->
<base-config cleartextTrafficPermitted="false">
    <trust-anchors>
        <certificates src="system" />
        <certificates src="@raw/<project>_server" />
    </trust-anchors>
</base-config>
```

- Covers **OkHttp and the WebView in one declaration**, with **no `onReceivedSslError`
  override anywhere** — an override is a security hole and reviewers treat it as one.
- This is the general answer to the **abba-bank blocker** recorded under "Adopting
  projects": a Chrome Custom Tab / TWA uses *Chrome's* trust store and cannot be taught
  about the cert, so it fails where a plain `WebView` inside the app succeeds. If a
  project needs a self-signed origin on screen, render it in a WebView.
- No pin to rotate: **do not add `sync-pin.sh`-style SPKI pinning on top**; the two
  mechanisms both have to be right, and the pin is the one that silently expires.
- Re-minted cert ⇒ re-fetch the leaf and rebuild:

  ```bash
  openssl s_client -connect <server-ip>:<port> </dev/null 2>/dev/null \
    | openssl x509 > <project>/android/app/src/main/res/raw/<project>_server.crt
  <project>/android/gradlew :app:assembleDebug
  ```

- Keep cleartext permitted for `10.0.2.2` / `127.0.0.1` / `localhost` only, so
  instrumented tests can point at a loopback `MockWebServer`.

**Alfred uses this branch; DanCode uses the SPKI pin above.**

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

### Emulator gotchas (learned the hard way; apply to every project)

- **One runner per AVD.** A Maestro flow and an instrumented test driving the same AVD fight over the UiAutomation connection, and the symptom is misleading: a permission dialog "never appeared" (it did — nothing could see it). When more than one agent shares this box, take a lock first; Alfred's convention is `mkdir /tmp/alfred-emu.lock` and `rmdir` it when done.
- **Never toggle airplane mode on an emulator.** `cmd connectivity airplane-mode enable` through the instrumentation shell takes the emulator's Bluetooth stack down with it — `com.android.bluetooth` dies, its crash dialog steals the foreground, and the *next* instrumented class fails with "no activities in stage RESUMED" for reasons unrelated to the code. Simulate "no signal" at the socket instead: a `MockWebServer` returning `SocketPolicy.DISCONNECT_AT_START` is exactly what an offline app sees, and it is instant and reversible. (Alfred's `OutboxDrainTest`, WP15 → WP16.)
- **`adb kill-server` after a killed `emu.sh start`.** Killing that script mid-flight (a `timeout`, a Ctrl-C) leaves the `flock` on `/tmp/android-framework/lifecycle.lock` held by the adb fork-server, which inherited the fd; every later `emu.sh` call then blocks forever on `flock -x 9`. The daemon restarts itself on the next adb call, so killing it costs nothing.
- **A dead emulator needs `start`, not `restart`.** A heavy WebView page has killed the emulator process outright (`Failed to find EmulatedEglImage` in `<avd>.log`); `emu.sh start <avd>` clears stale state itself, while `restart` and `stop` both refuse to act on a state file whose PID is dead.
- **Runtime permissions: grant, never revoke.** `grantRuntimePermission` is safe; a revoke kills the app process, which is also the instrumentation process. Test a denied path from the fresh-install state instead.
- **A grant survives `install -r`.** Gradle's connected-test install is an upgrade, so a suite that needs a fresh-install *denial* (Alfred's `CallIntentTest.t1`, the only place the real `CALL_PHONE` dialog can be observed) must `adb uninstall` the package immediately before layer 3. Anything that left the app on the device — a manual sideload, a Maestro run, the test runner's own post-Espresso reinstall — otherwise hands it a pre-granted permission.
- **Stop the AVD and `adb kill-server` when a test session ends**, so the next agent starts from a known state.

### Adopting projects

- **testapp** (`~/projects/android-framework/testapp/`) — the reference guinea-pig app; all four layers green via `testapp/run-all-tests.sh`.
- **abba-bank** (`~/projects/abba-bank/android/`) — first real adopter: a framework-based **TWA** (Trusted Web Activity wrapping the existing Next.js PWA, per `plans/abba-android.md`), built on the framework from day one on branch `android-framework-adoption` (commit `e3202a4`). Uses the framework toolchain/gradlew conventions and targets the framework emulator + `flow.sh` for its smoke flow. `android/` scaffold committed (`app/`, `gradle/`, `gradlew`, `scripts/bootstrap-toolchain.sh`, `maestro/`), debug APK builds and installs on the emulator (`app-debug.apk`, appId `com.abbabank.twa`), and `android/maestro/smoke.yaml` is green but **entry-state-only** (asserts the "Abba Bank" / "Email address" / "Send magic link" entry screen + screenshot) — the full magic-link sign-in → balance flow is **not** automated: Chrome rejects the self-signed NextAuth origin cert, and chromeless TWA mode needs HTTPS + Digital Asset Links to work around it. Deferred pending that; see `abba-bank/android/README.md`.
- **alfred** (`~/projects/alfred/android`) — **the reference adopter that has actually shipped to a phone.** Native Kotlin, View Binding, no Compose, no Room, appId `com.dgordon.alfred`, scaffolded from `android-framework/testapp/android/`. All four layers green via **`bash android/run-all-tests.sh`** (`--jvm-only` stops after Roborazzi, for work without an emulator); that script is the model to copy — it starts `test35` if needed, reinstalls the APK after Espresso, and `adb uninstall`s before it. Published **v1.0.0 (versionCode 2)** on 2026-09-16. Two deliberate divergences from the reference layout — **no `android/reverse-proxy/`** (it does not own its Caddy config) and **`minSdk 33`** — plus the trust-anchor TLS branch above. Full detail in the "Alfred" section below and in `~/projects/alfred/android/README.md`.
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

## Alfred (`~/projects/alfred/android`) — divergent branch

Dan's multi-surface assistant; the Android surface of the system mapped in
`~/.claude/system-map.md`. Native Kotlin on the **android-framework pattern**, so
everything in "Testing / prototype deployment" and "Automated testing" above applies
as written **except** the points below. Project doc: `~/projects/alfred/android/README.md`
— the source of truth for this section; update it there first.

**Live since:** v0.1.0 (versionCode 1) 2026-09-16, **v1.0.0 (versionCode 2)** the same day.

**Alfred updates itself from v1.4.0 on** — see "In-app updates" below. It is the only
project on this machine that does; every other one is still a browser sideload.

### Divergences from the reference layout

1. **No `android/reverse-proxy/`.** Alfred does not own a Caddy config. Its `:6443`
   site, plus a `/alfred/*` mirror spliced into T3 Code's `:7443` site (Dan's
   phone content filter allows `:7443`, not `:6443` — that mirror is now the
   app's **primary** origin), live in the machine's single
   `/etc/caddy/Caddyfile` (documented in `~/projects/alfred/docs/CADDY.md`, and
   in `system-map.md` under "Caddy"), which is shared with T3 Code, DanCode and
   Abba Bank — a careless edit there takes all of them down. The publish script
   therefore lives at **`android/scripts/publish-apk.sh`**, not
   `android/reverse-proxy/scripts/publish-apk.sh`, and there is no `install.sh`,
   no `generate-cert.sh` and no `sync-pin.sh` in this project.
2. **`minSdk 33`** (the framework default is 26). Two reasons, both hard: Dan's phone is
   a Galaxy S23 on Android 13, and 33 is the floor for `POST_NOTIFICATIONS`, which the
   app's reply notifications need. `compileSdk`/`targetSdk` stay at 35.
3. **Trust anchor, not SPKI pin** — see "TLS trust anchor" above.

### Publish (no sudo, no Caddy restart)

```bash
bash ~/projects/alfred/android/scripts/publish-apk.sh    # builds assembleDebug, then publishes
```

- Reads `versionName`/`versionCode` straight out of `android/app/build.gradle.kts`;
  **bump them by hand first** (see "Version bumping" above — nothing derives them).
- Writes into **`/var/lib/alfred-apk`** (dgordon-owned, 755; override with `DST_DIR=`).
  Publishing is a plain file copy: **no `sudo`, no `systemctl restart caddy`**, because
  the route is a static `handle_path /downloads/*` `file_server` that is already there.
- Names — **Alfred keeps one file per version**, unlike DanCode's
  `<app>-android-debug{,.previous}.apk`:

  | File | What |
  |---|---|
  | `alfred-<versionName>.apk` | this build, kept forever |
  | `alfred-latest.apk` | what the phone downloads |
  | `alfred-previous.apk` | the previous `alfred-latest.apk` — rollback by re-sideloading it |
  | `index.html` | generated install page: version, versionCode, size, SHA-256, build time, the sideload steps, and the upgrade-in-place note |
  | `latest.json` | the update manifest installed phones poll (v1.4.0+, see below) |

- **Server base URL (pairing):** `https://15.204.108.12:7443/alfred` — also the
  default for `bin/alfred-pair-link.mjs --base`, for the same phone-content-filter
  reason as the sideload URLs below.
- **Sideload URLs (primary):** page
  `https://15.204.108.12:7443/alfred/downloads/index.html`, APK
  `https://15.204.108.12:7443/alfred/downloads/alfred-latest.apk` — use these;
  Dan's phone content filter allows `:7443`, not `:6443`. The unchanged mirror
  at `https://15.204.108.12:6443/downloads/{index.html,alfred-latest.apk}` is
  still live. Both sites set `index off`, so bare `/downloads/` lists files
  rather than serving the page — link the explicit `index.html`.
- Verify after publishing:

  ```bash
  curl -skI https://15.204.108.12:7443/alfred/downloads/alfred-latest.apk   # 200 (primary)
  sha256sum /var/lib/alfred-apk/alfred-latest.apk                           # matches the page
  ```

### In-app updates (v1.4.0+, Alfred only)

The sideload page is no longer how a *new* build reaches a phone that already has
Alfred. `publish-apk.sh` writes one more file and the app does the rest:

```json
// /var/lib/alfred-apk/latest.json — served at <base>/downloads/latest.json
{ "versionCode": 8, "versionName": "1.4.0", "apk": "alfred-1.4.0.apk",
  "sha256": "…64 hex…", "sizeBytes": 13004112,
  "builtAt": "2026-09-20 16:40 UTC", "notes": "In-app updates." }
```

- **No new service and no new route.** The manifest sits in the directory Caddy already
  serves, so publishing is still a file copy — no sudo, no reload. `NOTES="…"` on the
  publish command puts a line in the notification and on the download page.
- **The phone checks three ways**: the 15-minute briefing beat (`work/BriefingWorker`),
  every `onResume` of Home (throttled to 10 minutes), and Settings → *Check for updates*.
  Only a strictly greater `versionCode` counts; the manifest is rejected unless `apk` is
  a bare `*.apk` file name and `sha256` is 64 hex.
- **One notification per `versionCode`**, on its own channel. Tapping it opens Settings,
  which downloads the APK, **verifies the SHA-256 before anything else sees the file**,
  and hands it to the system installer through a `FileProvider` `content://` URI.
- **`REQUEST_INSTALL_PACKAGES` is declared**, and the first update stops at Android's
  "allow this app to install apps" toggle for Alfred's own row. That grant is one-time
  and the app deep-links to it.
- `apk` is deliberately the versioned file name, not `alfred-latest.apk`: the phone
  checksums what it downloads, and a `latest` overwritten mid-download would fail that
  check for no reason.

Porting this to another project is mostly copying `android/scripts/publish-apk.sh`'s
manifest step and `app/src/main/java/com/dgordon/alfred/update/` (three files, no
dependencies beyond OkHttp) — the only project-specific parts are the base URL and the
`FileProvider` authority. Do not add it to a project whose APKs are release-signed by a
key that might rotate.

### Signing and upgrades

Debug-signed with `~/.android/debug.keystore`, built by `assembleDebug`; there is no
release build type at all (`androidComponents` disables the release variant outright).
Because the key never changes, **a new version installs over the old one** — no
uninstall, and the pairing, the settings and anything still queued in the outbox all
survive. That is a promise the download page makes to Dan, so it has a cost:
**do not delete or regenerate `~/.android/debug.keystore`.** If it ever is regenerated,
the signature changes, the upgrade is refused, and the only way back is an uninstall
that throws away the pairing and the queue.

### Testing

`bash ~/projects/alfred/android/run-all-tests.sh` runs all four layers cheapest-first
and prints **"All four layers green"**; `--jvm-only` stops after Roborazzi for work
without an emulator. It starts `test35` if the framework has no state for it, `adb
uninstall`s before the Espresso layer and reinstalls the APK after it. Read the
"Emulator gotchas" list above before driving the emulator — several of its entries were
learned in this project.

### What stays manual (and why)

The emulator layers cover the UI, so Alfred's checklist is only what a headless AVD
genuinely cannot be. Each entry names its reason; keep that rule when adding one.

- **A SIM** — placing the actual call.
- **A real speech recogniser** — `test35` reports `isRecognitionAvailable() == true`
  and then produces no transcript, so every automated test exercises the *fallback*.
  Real speech, with signal and without, is phone-only.
- **Driving mode** — a car, a dock, Bluetooth mic routing, a hotspot flapping between
  LTE and nothing. The reason the voice screen exists.
- **A real dead zone** — one bar is not a clean switch the way airplane mode is.
- **Doze on Samsung** — `TestDriver` proves the periodic worker is *right*, never *when*
  the OEM lets it run.
- **Notification tap-through from a lock screen** — the shade, the lock screen and
  Samsung's own grouping.
- **The OEM installer** — the browser cert warning, "install unknown apps", and
  **installing over the previous build** — including the in-app update path end to end:
  notification → Settings → download → Samsung's *Update* dialog → pairing and outbox
  still intact.
- **Which apps linkify `alfred://`** — a phone question, not an emulator one.
- **TLS from Dan's carrier** — the emulator proves the trust anchor; the phone proves
  Techloq/DNS.

## Production deployment

Not configured. Everything on this machine is testing/prototype today. When the first production Android deployment happens — Play Store internal track, signed release APK with a real upload key, Firebase App Distribution, anything beyond debug-signed sideload — document the process here in the same structure (toolchain → signing → build → version bumping → distribution → rollback → smoke).
