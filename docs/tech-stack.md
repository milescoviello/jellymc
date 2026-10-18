# Tech stack

## Decision

**Flutter (Dart) for UI and all app logic. Playback goes through our own `PlayerEngine` interface, with libmpv on both platforms and AVPlayer on iOS.**

| Platform | Engines | What each is for |
|---|---|---|
| **Linux** (this machine) | **libmpv**, the system library, through media_kit's Linux bindings (vendored), rendered into a Flutter texture | Plays everything in-app. Hardware decoding through VA-API on the Intel Arrow Lake iGPU. HDR is tone-mapped to SDR. |
| | **libmpv in HDR window mode**: the same library, but mpv opens its own Wayland window with `vo=gpu-next` | Real HDR output on Plasma's HDR mode. Our app keeps driving playback and reporting while mpv draws its own on-screen controls. |
| **iPhone / iPad** | **libmpv**, using media_kit's prebuilt iOS libmpv, so no Swift is needed | The long tail: MKV with styled ASS, PGS, DTS/TrueHD decoding, anything AVPlayer can't open. |
| | **AVPlayer**, through an existing Flutter plugin (spike S3 picks one; see below) | The default when it can play the item, either directly or through a cheap server remux: PiP, AirPlay, HDR/Dolby Vision on the iPhone's OLED display, best battery life. |

Engine choice is a simple per-item rule, and you can override it (see [playback.md](playback.md#engine-selection)).

## Why Flutter, for iOS + Linux without a Mac

- **It's the only practical single codebase covering both platforms.**
  - SwiftUI doesn't run on Linux, and GTK/Qt don't produce good iOS apps.
  - React Native has no Linux target.
  - Compose Multiplatform runs on both, but desktop video on its JVM target is do-it-yourself.
  - Tauri's iOS WebView can't play MKV, styled ASS, or DTS/TrueHD.
  - Fladder and Moonfin already ship Flutter Jellyfin clients on exactly this pair of platforms.
- **The no-Mac constraint favours Flutter more than any other option.**
  - Nearly all the app is Dart, which runs, hot-reloads and debugs on the Linux desktop build.
  - iOS-specific pieces come from plugins that already contain working iOS code: media_kit, just_audio, audio_service, background_downloader, flutter_secure_storage. So we compile them in CI rather than write and debug Swift blind.
- **The Linux build doubles as the iOS UI dev loop.** iPad landscape layouts are close to desktop layouts, and phone layouts get exercised by resizing the window or with `device_preview` (see [dev-workflow.md](dev-workflow.md#daily-loop-on-linux)).

### Alternatives considered

| Option | One codebase for iOS + Linux | Workable without a Mac | Playback ceiling | Verdict |
|---|---|---|---|---|
| **Flutter + existing plugins** | Yes | Yes: CI builds iOS, and Swift stays minimal | High (mpv + AVPlayer) | **Chosen** |
| Two native apps: SwiftUI + GTK4 (Rust) or Qt | No (two UIs) | **No**: SwiftUI work needs Xcode constantly | Highest on each platform | Rejected: double the UI work, and the iOS half can't really be developed without a Mac |
| Kotlin Multiplatform + Compose | Yes | Partly (same CI approach) | Media players on iOS and JVM desktop are DIY | Rejected |
| React Native / Expo | No Linux | Yes (EAS cloud builds) | Good on iOS (Streamyfin uses mpv) | Rejected: no Linux |
| Tauri 2 | Yes | Yes (cloud builds) | Weak on iOS: WebView codec limits | Rejected |
| Use Swiftfin/Streamyfin on iOS + Jellyfin Desktop on Linux | n/a | Yes | Good | Not the brief, but it's the bar to beat |

### Stack risks and mitigations

| Risk | Mitigation |
|---|---|
| media_kit on iOS: performance, HDR handling, and the `-framework Mpv` conflicts Moonfin hit when mixing it with another engine | Spike S2. Fall back to an MPVKit build, or to AVPlayer-only on iOS with server remux/transcode for the long tail. |
| The AVPlayer plugin's maturity: candidates are around 0.2.x | Spike S3 evaluates `better_native_video_player` (AVPlayerViewController with PiP and auto-PiP on background) and `video_player` + `video_player_pip`. Fallback: our own ~1–2k-line Swift engine, compiled in CI. |
| Flutter + media_kit on Wayland: Moonfin had to patch `media_kit_video` because frames stopped presenting when idle | Spike S1 on Plasma 6.7. Borrow Moonfin's patch if needed; its GPL licence is fine for a personal build. |
| Hybrid graphics (Intel iGPU + NVIDIA) | Run on the Intel iGPU, which is the default with no PRIME offload. Use VA-API decoding: Arrow Lake's media engine handles HEVC 10-bit, VP9 and AV1. NVIDIA isn't needed for playback. |
| The media plugin ecosystem has small maintainer pools | Pin versions. Vendor or fork when patches are needed. App code only sees our own interfaces. |

## Library choices

"Precedent" marks libraries already used by another Jellyfin Flutter client.

| Concern | Choice | Notes |
|---|---|---|
| API client | **Generated** with `swagger_dart_code_generator` + `chopper` | Precedent: Fladder and Finamp run it against the Jellyfin spec. The spec is vendored at `tools/openapi/jellyfin-12.2.json` and regenerated on purpose, never at build time. Wrapped in a hand-written `JellyfinClient` facade. |
| HTTP | `chopper` on `package:http`; on iOS, swap in `cupertino_http` (NSURLSession) | NSURLSession brings HTTP/2, the system VPN/proxy, and iOS certificate trust (so a self-signed CA installed as a profile just works) |
| State | **Riverpod** | Precedent: Fladder, Moonfin, Finamp |
| Navigation | `go_router` | Deep links (`jellymc://item/{itemId}`) |
| Local DB | **drift** (SQLite) | Precedent: Fladder, Moonfin. Holds the offline cache, the download index, and the sync queue. |
| Models | `freezed` + `json_serializable` | |
| Secure storage | `flutter_secure_storage` | iOS Keychain. On Linux, libsecret talks to the Secret Service, which gnome-keyring-daemon provides on this machine. |
| Downloads | `background_downloader` | Precedent: Fladder, Moonfin. iOS background `URLSession`; on Linux, runs in-process. |
| Music | `just_audio` (AVQueuePlayer on iOS; `just_audio_media_kit` on Linux) + `audio_service` (Now Playing and remote commands on iOS) + `audio_service_mpris` (Linux) | Finamp's setup. Expect to fork, as Finamp did. |
| Images | Our own cache keyed on `(itemId, imageType, tag, width)` + `flutter_blurhash` | Jellyfin image tags are content hashes, so a tagged URL is immutable: cache it forever and evict by size |
| AirPlay | Route-picker button (`AVRoutePickerView`) through a tiny plugin | Video AirPlay comes for free with the AVPlayer engine |
| Keep screen awake | `wakelock_plus` | The idle timer on iOS; the D-Bus screen-saver inhibit on Linux |
| Linux desktop | `window_manager` (fullscreen, always-on-top mini-player), `tray_manager` (StatusNotifierItem on KDE), `flutter_local_notifications` | |
| Layout preview | `device_preview` (dev builds only) | Phone and iPad frames on the Linux desktop |
| Testing | `flutter_test`, `mocktail`, golden tests, `integration_test` on Linux | See [roadmap.md](roadmap.md#testing) |
| Repo tooling | Dart pub workspace (app + `jellyfin_api`) and a `justfile` | No melos needed at this size |

## Playback engine notes

| Engine | Where | Strengths | Weaknesses |
|---|---|---|---|
| **libmpv** | Linux, iOS | Widest container and codec support (FFmpeg); libass for full ASS styling; PGS/VobSub; gapless; libplacebo tone-mapping; HDR passthrough on Wayland when mpv owns the window | The Flutter texture path is SDR. No PiP on iOS: that would need a sample-buffer-layer bridge, which is Swift-heavy and deferred. |
| **AVPlayer** | iOS | Native PiP (including auto-PiP when leaving the app), AirPlay, Dolby Vision and HDR10 on the iPhone display, Atmos (E-AC-3 JOC), best battery life, Now Playing integration | No MKV and no ASS/PGS rendering. Needs a server remux (cheap) or a transcode for anything else. |
| AetherEngine / VLCKit | iOS | Fallback options if media_kit's iOS libmpv disappoints (Moonfin uses AetherEngine on Apple) | Both need Swift glue, compiled in CI |

## Licensing

There are no constraints for a personal, sideloaded build. GPL builds of mpv and FFmpeg are fine. Code can be borrowed from GPL projects (Fladder GPL-3.0, Moonfin GPL-2.0, Findroid GPL-3.0). Codec patents and Jellyfin branding don't matter. **If you ever publish the app**, choose a licence compatible with whatever you borrowed (GPL), and revisit App Store constraints then.
