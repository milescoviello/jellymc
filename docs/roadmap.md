# Roadmap

Milestones are cumulative. Each one leaves both apps usable. iOS builds come from CI and are installed with `xtool`, the same as the Music app.

## Where it stands (2026-10-19)

M0, M1 and M2 are built, and the layout follows Plex's (the app replaces Plex here: Home, a library's Recommended/Library/Collections/Categories, pre-play pages, cards that open rather than play). Remote control and live updates from M4 are in too. The Linux app is checked screen by screen on a test desktop, against the local test server and a real one; the iPhone app compiles in CI on every push and has not yet been run on the phone, so its screens are unverified.

Left before calling it 1.0:

- **The iPhone app on the device:** a first run, and the fixes it turns up.
- **Video on a real GPU on Linux:** the test desktop renders in software (mpv falls back to 8-bit framebuffers and its fast profile there); the laptop's GPU path is untested.
- **iPad layouts** (M3): the iPhone layout scaled up today.
- From M4: hand-off, SyncPlay, admin views. From M5: an mpv engine on iOS, an HDR window on Linux.

| Milestone | Outcome |
|---|---|
| **M0** Foundations | Repo layout, `Package.swift` (Linux app + macOS tests), the Xcode project, the CI workflow producing `latest`, a local test server, a Core client that logs in |
| **M1** Watch | Home (Continue Watching, Next Up, Latest), libraries, details (movie/series/season/episode), search; playback with reporting, resume, track selection, segment skip, up next. AVPlayer on iOS, mpv on Linux. |
| **M2** iPhone essentials + desktop integration | Downloads and offline (iOS), PiP and AirPlay polish, multiple server addresses, MPRIS and the screen-saver inhibit on Linux, trickplay, roaming settings, Diagnostics |
| **M3** Polish | Performance, iPad layouts, keyboard shortcuts, the papercuts |
| **M4** Extras | Remote control and hand-off, SyncPlay, admin views; Seerr if used |
| **M5** Maybe | MPVKit engine on iOS, mpv HDR window on Linux, widgets (paid account) |

## M0: Foundations

- `App/` (iOS) and `Linux/` (GTK), with `Linux/Sources/JellyCore/Core → App/Core`.
- `Package.swift`: on Linux, the `JellyCore` library (Core + Platform + GTK + UI), the `jellymc` executable and tests. On macOS, Foundation-only Core files and tests.
- `Jellymc.xcodeproj` with a file-system synchronized `App` group, iPhone + iPad, iOS 18.
- `.github/workflows/ios.yml`: `swift test`, an ad-hoc-signed archive, `Jellymc.ipa` uploaded as an artifact and to the rolling `latest` release.
- `tools/testserver`: Jellyfin 12.2 in Docker, the first-run wizard scripted, and generated media.
- Core: `JellyfinClient`, the auth header, `/System/Info/Public`, `AuthenticateByName`, the session in the Keychain/libsecret.

**Exit:** `swift test` passes on Linux; the GTK app logs in to the test server; CI publishes an IPA that `xtool install` puts on the phone.

## M1: Watch

**Exit:** every test-server fixture plays on Linux (direct play) and on the iPhone (direct play, direct stream or transcode as appropriate), progress shows up in the server dashboard, and resume works across both devices.

## Testing

- **`swift test` on Linux** before every push: models decoding recorded 12.2 responses, profile builders, playback decisions, URL building, the outbox, ticks.
- **CI** runs the same tests on macOS and compiles the iOS app.
- **By hand:** the Linux app against the test server, and the iPhone after each `xtool install`.

## Risks

| Risk | Mitigation |
|---|---|
| iOS UI bugs are only visible on the device | Keep logic in Core (tested on Linux); Diagnostics screen; `idevicesyslog` |
| macOS CI minutes on a private repo | Batch pushes; `workflow_dispatch` |
| Free certificate: 7-day expiry, 3 apps | Weekly `xtool install` (or adapt the Music app's phone-refresh tool) |
| GTK + libmpv rendering on Wayland | `GtkGLArea` with the mpv render API is the Celluloid approach; VA-API interop through EGL |
| Server upgrades | DTOs decode leniently (all optional) and are tested against recorded responses |
| Scope creep | Milestones are cumulative and each is usable; M4/M5 are à la carte |
