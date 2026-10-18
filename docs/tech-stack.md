# Tech stack

## Decision

**Flutter (Dart) for UI and all app logic. Playback lives in our own federated Flutter plugin, `jellymc_player`, with several native engines behind one Dart interface.**

| Platform | Default engine | Secondary engine | Why we need the secondary |
|---|---|---|---|
| Windows, macOS, Linux | libmpv | libmpv rendering into its own native window (later) | HDR passthrough, which needs a native surface instead of a Flutter texture |
| Android | libmpv | Media3/ExoPlayer, in a `SurfaceView` platform view | HDR10/Dolby Vision on device decoders, tunneled playback, battery life, Cast handoff |
| iOS | libmpv (our own LGPL xcframework build) | AVPlayer, in an `AVPlayerLayer` platform view | Native PiP, AirPlay video, Dolby Vision on Apple hardware, and server HLS transcodes |

For music, the queue/gapless/media-session layer is a separate audio pipeline (see [architecture.md](architecture.md#music-pipeline)). It isn't the video player in audio-only mode.

## Why Flutter

**One codebase for five platforms, plus precedent.** The only Jellyfin clients shipping on all five targets today, Moonfin and Fladder, are Flutter apps (see [landscape.md](landscape.md)). Flutter 3.47 (August 2026) is the current stable release, and its desktop targets are production-grade.

**Flutter's known weakness is media, and the weakness is in the ecosystem, not the framework.** Every serious Flutter media client has forked media_kit, just_audio or audio_service. media_kit has one active maintainer and about 340 open issues. So we **own the player plugin** from day one:

- Start from media_kit's libmpv FFI and texture code, vendored.
- Keep our own Dart interface, so no third-party API shape leaks into the app.
- Write the Media3 and AVPlayer engines ourselves. Each is a few thousand lines of Kotlin or Swift, which is well understood.

### Alternatives considered

Scores run from ●●● (best) to ○○○ (poor).

| Option | 5-platform coverage | Playback ceiling | One UI codebase | Media ecosystem | Jellyfin precedent | Verdict |
|---|---|---|---|---|---|---|
| **Flutter + own player plugin** | ●●● | ●●● (native engines via plugin) | ●●● | ●○○ (forks needed, but we budget for them) | ●●● Moonfin, Fladder | **Chosen** |
| **Kotlin Multiplatform + Compose Multiplatform** | ●●○ (iOS stable since CMP 1.8.0, May 2025; desktop is JVM) | ●●○ (Media3 is great on Android; libmpv on JVM desktop and on iOS is DIY) | ●●● | ●○○ (no libmpv-backed CMP player; ComposeMediaPlayer uses GStreamer, Media Foundation and AVPlayer) | ○○○ for desktop+mobile. `jellyfin-sdk-kotlin` is JVM/Android only. | **Runner-up.** Pick it if the team is Kotlin-first and Android matters most. |
| **React Native / Expo** | ●○○ (no Linux) | ●●○ (Streamyfin ships MPVKit) | ●●○ | ●●○ | ●●○ Streamyfin, mobile only | Rejected: Linux is a hard requirement |
| **Tauri 2 / Electron (web UI + native player)** | ●●○ | ●●○ desktop, ●○○ mobile (WebViews can't play MKV/HEVC/AC-3, so we'd need native player overlays) | ●●● | ●●○ | ●●○ Jellyfin Desktop does web + mpv on desktop | Rejected: the mobile story is weak, and WebKitGTK on Linux is slow |
| **Native per platform** (SwiftUI + Jetpack Compose + desktop toolkit) | ●●● | ●●● | ○○○ (3–4 UIs) | ●●● | ●●● Swiftfin, Findroid | Rejected for a small team: 3–4× the UI work |
| **Shared Rust core (UniFFI) + native UIs** | ●●● | ●●● | ○○○ | ●●○ | ○○○ | Rejected: only the logic is shared, and the UI is still 3–4× |
| **.NET MAUI/Avalonia + LibVLCSharp**, **Qt 6/QML + mpv** | ●●○ / ●●● | ●●○ / ●●● | ●●● | ●○○ / ●●○ | ○○○ / ●●○ (Jellyfin Desktop is Qt) | Rejected: mobile UI quality and hiring pool |

### Known Flutter risks and mitigations

- **HDR through textures.** Flutter's `Texture` path is effectively SDR. mpv tone-maps HDR to SDR well (libplacebo), and we do that in 1.0. Real HDR output comes through platform views: Media3 and AVPlayer on mobile now, and mpv in a native child window on desktop later.
- **Platform-view cost.** Android hybrid composition costs frames. Player screens are mostly full-screen video under a light overlay, so this is acceptable. We'll measure it in the M0 spikes.
- **Ecosystem churn.** Material and Cupertino are being split out of the core framework. That's mostly irrelevant to us, because we build our own design system. Pin the Flutter version with FVM, and upgrade once per quarter after the stable release.

## Library choices

All choices are swappable behind our interfaces. "Precedent" marks libraries already used by another Jellyfin Flutter client.

| Concern | Choice | Notes |
|---|---|---|
| API client | **Generated from the OpenAPI spec** with `swagger_dart_code_generator` + `chopper` | Precedent: Fladder and Finamp both run it against the Jellyfin spec. Vendor the spec at `api/openapi/jellyfin-12.2.json` and regenerate on purpose, never at build time. Wrap it in a hand-written `JellyfinClient` facade. |
| HTTP | `chopper` on `package:http`, with interceptors for auth, custom headers, retries and the per-server base URL | Swap the transport for `cronet_http` (Android) or `cupertino_http` (Apple) to get HTTP/2, the system proxy, and user-installed CAs. |
| State | **Riverpod** | Precedent: Fladder, Moonfin, Finamp. |
| Navigation | `go_router` | Deep links (`jellymc://item/{id}`), adaptive shells. |
| Local DB | **drift** (SQLite) | Precedent: Fladder, Moonfin. Typed queries and migrations; used for the offline cache, download index and sync queue. Avoid Isar, which survives only as forks. |
| Models | `freezed` + `json_serializable` | For our domain models. Generated DTOs stay at the edge. |
| Secure storage | `flutter_secure_storage` | Access tokens per server/user, client certificates. |
| Downloads | `background_downloader` | Precedent: Fladder, Moonfin (forked). iOS background `URLSession`, Android WorkManager, desktop isolates. |
| Media session | `audio_service` + `audio_session` on mobile/macOS, `audio_service_mpris` on Linux, an SMTC binding on Windows | Expect to fork, as Finamp did. The interface we code against is ours. |
| Images | Our own cache keyed on `(itemId, imageType, tag, width)` + `flutter_blurhash` | Jellyfin image tags are content hashes, so a tagged URL is immutable: cache it forever and evict by LRU size. |
| Casting | Thin platform channels to the Google Cast SDK (Android/iOS) and to `AVRoutePickerView` | Uses Jellyfin's official Chromecast receiver app. Ship an F-Droid build flavor without the Cast SDK. |
| Desktop windowing | `window_manager`, plus our own code for fullscreen, mini-player and always-on-top | |
| Localization | Flutter `gen-l10n` (ARB files) + Weblate | |
| Crash reporting | None by default; opt-in Sentry (self-hostable) | Privacy is a selling point in this community. |
| Testing | `flutter_test`, `mocktail`, golden tests, `patrol` for on-device E2E | See [roadmap.md](roadmap.md#testing). |
| Monorepo | Dart pub workspaces + `melos` scripts | See [architecture.md](architecture.md#repository-layout). |

## Playback engine notes

| Engine | Platforms | Strengths | Weaknesses | License |
|---|---|---|---|---|
| **libmpv** | All five | Widest container and codec support (FFmpeg); libass for full ASS styling; PGS/VobSub; gapless; S/PDIF and HDMI passthrough on desktop; libplacebo tone-mapping; scriptable | No first-party mobile SDK; we own the builds. On Apple, MPVKit calls itself "only suitable for learning". The Flutter texture path is SDR. | LGPL build required. No `--enable-gpl` components, which means no SMB. |
| **Media3 / ExoPlayer** | Android | Hardware HDR10/HLG/DV output, tunneling, low power, first-class `MediaSession` / Android Auto / Cast integration; the FFmpeg extension adds audio codecs | Limited ASS styling; narrower container and codec coverage than FFmpeg; video codecs depend on the device's decoders | Apache-2.0; FFmpeg extension is LGPL |
| **AVPlayer** | iOS, macOS | Native PiP, AirPlay, Dolby Vision (profiles 5/8) on Apple hardware, Atmos via E-AC-3 JOC, best battery life | No MKV, narrow codec set, no ASS/PGS rendering. Effectively needs server HLS (remux or transcode) for anything off the happy path. | System |
| **AetherEngine** | iOS, tvOS, macOS | FFmpeg demux + VideoToolbox/dav1d; HDR10/HDR10+/DV/HLG; Atmos passthrough. Moonfin adopted it on Apple in 2.3.2. | About two months old, one main author, fast-moving versions | Check before adopting |
| **VLCKit 4** | Apple | Mature and widely shipped (including on the App Store) | Swiftfin reports audio-delay and TLS 1.3 issues | LGPL/MPL |

**Apple plan:** in spike S3 (see [roadmap.md](roadmap.md)), bake off our own libmpv xcframework (built from the MPVKit/libmpv build scripts, LGPL) against AetherEngine. AVPlayer stays as the PiP/AirPlay/HLS engine either way. Choose by the end of M0.

## Licensing

- **App license: MPL-2.0 (recommended).** It's file-level copyleft that works with the App Store, and it's what Swiftfin, Streamyfin and Finamp use. GPL-3.0 creates App Store distribution problems. Apache-2.0 is the permissive alternative. **This is an open decision for you** (see [roadmap.md](roadmap.md#open-decisions)).
- **libmpv/FFmpeg:** LGPL builds only, linked dynamically (dynamic frameworks on iOS). Ship source and relinking information to satisfy the LGPL.
- **Codec patents** (HEVC, E-AC-3, DTS, TrueHD software decoders in FFmpeg): commonly shipped by FOSS players, but **get legal review before any paid or commercial release.** Hardware decoders reached through OS APIs (VideoToolbox, MediaCodec) sidestep most of this. This isn't legal advice.
- **Branding:** don't use the Jellyfin logo as our app icon or "Jellyfin" as the leading word of the name without checking the Jellyfin project's trademark and branding guidance.
