# Dev workflow: Linux desktop + sideloaded iPhone, no Mac

The rule that makes this work: **write and debug everything on the Linux build. Treat the iPhone as a release-build test device.** An iOS app can only be compiled on macOS, and Flutter debug builds on a physical iPhone need Xcode to launch. So no hot reload and no debugger on the phone. iOS builds come from a CI Mac, and you install them through SideStore.

## One-time Linux setup (Gentoo, this machine)

Already installed here, as of 2026-10-18:

- `dev-build/cmake`, `dev-build/ninja`, `llvm-core/clang`, `x11-libs/gtk+:3`, `dev-util/pkgconf`
- `app-crypt/libsecret` (Secret Service is provided by gnome-keyring-daemon)
- `media-libs/libva-intel-media-driver`
- usbmuxd and libimobiledevice (`idevicesyslog`, `idevicecrashreport`, `ideviceinstaller`)
- Docker

Still needed:

1. **libmpv:** `media-video/mpv` (0.41 in the tree) with `USE="libmpv vaapi wayland pipewire"`. `libmpv`, `egl` and `vulkan` are on by default; `vaapi`, `wayland` and `pipewire` are not. `cli` is worth keeping too, for comparing behaviour against stock mpv.
2. **Flutter SDK:** not packaged in Gentoo. Clone the stable channel to `~/sdk/flutter`, or use FVM, and pin the version in `.fvmrc`. Then run `flutter config --no-analytics --enable-linux-desktop` and `flutter doctor`. Ignore the Android and Xcode warnings.
3. **Hardware decoding check:** run `vainfo` (from `media-video/libva-utils`). It should list HEVC Main10, VP9 profile 2 and AV1 decode on the Arrow Lake iGPU. Leave the app on the iGPU: no `__NV_PRIME_RENDER_OFFLOAD`.
4. **A scratch Jellyfin server (optional):** `docker run jellyfin/jellyfin:<your server's version>` with a few fixture files. Use it for destructive tests (playlist edits, admin actions) so your real library stays clean. Day-to-day work points at your real server.

## Daily loop on Linux

- `flutter run -d linux` gives hot reload against your real server.
- **Phone and iPad layouts:** a dev-only `device_preview` toggle renders the app inside iPhone and iPad frames (safe areas, notch, text scale). Resizing the window exercises the breakpoints.
  - iPhone ≈ 393×852 logical px
  - iPad 11" ≈ 834×1194 logical px
- **iOS-only services have Linux fakes** behind the same interfaces, so the flows still run on Linux. Examples: PiP becomes an always-on-top mini window, AirPlay becomes a dummy route picker, and background `URLSession` becomes an in-process downloader.
- **Platform checks** go through a single `PlatformInfo` provider, never `Platform.isIOS` scattered around. A dev setting can then make the Linux build *pretend* to be iOS: compact layout, touch gestures, iOS engine rules backed by mpv.
- **Before pushing:** `just check` runs format, analyze, unit and golden tests, and a Linux integration smoke test.

## Building for iOS in CI

Use a GitHub Actions macOS runner, triggered manually or on a tag. The build is unsigned; SideStore signs it with your Apple ID at install time.

```yaml
# .github/workflows/ios.yml (sketch)
name: ios
on:
  workflow_dispatch:
  push:
    tags: ["v*"]
jobs:
  ipa:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: 3.47.x # keep in sync with .fvmrc
          cache: true
      - run: flutter build ios --release --no-codesign
        working-directory: app
      - name: Package unsigned IPA
        working-directory: app
        run: |
          mkdir -p Payload
          cp -R build/ios/iphoneos/Runner.app Payload/
          zip -qry jellymc.ipa Payload
      - uses: actions/upload-artifact@v4
        with:
          name: jellymc-ipa
          path: app/jellymc.ipa
```

- **Minutes:** a **public** repo gets standard runners for free. A **private** repo on the Free plan has 2,000 minutes a month, and macOS minutes reportedly count 10×. That's roughly 200 macOS minutes, or about 12–15 iOS builds a month. Verify against GitHub's current pricing page before relying on it.
  - Stretch it with caching, by building iOS only on tags or manual runs, and by running every check you can on the Linux job.
  - Codemagic is an alternative CI with a free macOS allowance.
- A second workflow, `linux.yml`, runs analyze, tests, and the Linux build on every push. It's cheap.

## Sideloading with SideStore (free Apple ID)

**One-time:**

1. Get **iloader** (github.com/nab138/iloader; AppImage, DEB or RPM). It needs usbmuxd, which is already installed.
2. Plug in the iPhone by USB and tap **Trust**.
3. In iloader, sign in with your Apple ID. It installs SideStore and its pairing file for you.
4. On the iPhone, enable **Settings → Privacy & Security → Developer Mode** and reboot. iOS 16+ requires this for self-signed apps.
5. Repeat for the iPad.

**For each build:**

- `gh run download -n jellymc-ipa` fetches the IPA.
- Get it to the phone: open it in SideStore from the Files app (via a shared folder, KDE Connect, or your server), or point SideStore at a URL.
- **Better: your own SideStore source.** Host an AltStore-format `source.json` and the IPA on your own server (for example behind the reverse proxy that already fronts Jellyfin), and have CI upload new builds there. SideStore then shows updates and installs them over the air. GitHub release assets from a *private* repo need authentication, so they can't be used for this directly.

### Free Apple ID limits

These come from community sources, not official Apple documentation.

| Limit | What it means for us |
|---|---|
| Apps expire after **7 days** | SideStore refreshes them on-device in the background with its VPN helper. Open SideStore occasionally. An expired app keeps its data; it just won't launch until refreshed. |
| **3 active sideloaded apps** per device (SideStore counts as one) | Fine for jellymc. LiveContainer can host more if you need them. |
| **10 App IDs per 7 days**, and every app extension uses one | **Don't add app extensions:** no widgets, share extensions, or Live Activity targets. |
| No restricted entitlements | **No CarPlay**, and no multicast networking, so no LAN server discovery (you type the URL once anyway). Standard capabilities should work: background audio, PiP, Keychain, background downloads. Verify in spike S0. |

**Paid Apple Developer account ($99/yr), if these limits start to annoy you:**

- 1-year signing.
- TestFlight internal testing: CI uploads, the phone updates over the air, and builds last 90 days with no review for internal testers.
- Lets you request the CarPlay audio entitlement.
- Allows widgets and other extensions.

You don't need it to start.

## Debugging the iPhone from Linux

- **Logs:** `idevicesyslog -m flutter` streams the app's Dart `print`/log output and native logs over USB. The app also has a built-in log console (an in-memory ring buffer plus a file) that can export logs or send them to your server through `/ClientLog/Document`.
- **Crashes:** `idevicecrashreport -e ./crashes` pulls crash reports. Symbolicating native crashes needs the dSYMs, so upload them as a CI artifact next to the IPA.
- **Native code** compiles only in CI, so keep it tiny, keep it behind plugins, and test the Dart side through Linux fakes.
- **When stuck on Swift**, for example while building the AVPlayer engine fallback, rent a cloud Mac for a day or borrow one. The plan avoids needing this for 1.0.
- **Network debugging:** the app's stats overlay shows the play method and the server's transcode reasons. For HTTP-level issues, run the same flow on Linux with a proxy (mitmproxy) attached.
