# Roadmap

Milestones are cumulative. Each one leaves both apps usable. iOS builds come from CI and are installed with `xtool`, the same as the Music app.

| Milestone | Outcome |
|---|---|
| **M0** Foundations | Repo layout, `Package.swift` (Linux app + macOS tests), the Xcode project, the CI workflow producing `latest`, a local test server, a Core client that logs in |
| **M1** Watch | Home (Continue Watching, Next Up, Latest), libraries, details (movie/series/season/episode), search; playback with reporting, resume, track selection, segment skip, up next. AVPlayer on iOS, mpv on Linux. |
| **M2** iPhone essentials + desktop integration | Downloads and offline (iOS), PiP and AirPlay polish, multiple server addresses, MPRIS and the screen-saver inhibit on Linux, trickplay, roaming settings, Diagnostics |
| **M3** Music | Albums, artists, playlists, queue, gapless, lyrics, lock screen/MPRIS |
| **M4** Polish | Performance, iPad layouts, keyboard shortcuts, the papercuts |
| **M5** Extras | Remote control and hand-off, SyncPlay, admin views, photos; Live TV/Seerr if used |
| **M6** Maybe | MPVKit engine on iOS, mpv HDR window on Linux, books, CarPlay/widgets (paid account) |

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
| Scope creep | Milestones are cumulative and each is usable; M5/M6 are à la carte |
