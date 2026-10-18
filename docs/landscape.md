# Landscape

The facts here are time-sensitive. Each was checked on 2026-10-18, and sources are listed at the bottom.

## Server: Jellyfin 12.x

- **Current stable is 12.2** (2026-10-05), following 12.0 (2026-09-08) and 12.1. The project dropped the leading `10.`: what would have been 10.12 shipped as 12.0. The maintainers' stated reason is that no hard API break is planned and the old scheme confused people about what counted as "major".
- **Supported upgrade paths into 12.x** start from 10.10.7 or 10.11.x. The database migration means a server can't roll back without a full restore, so admins will sit on 10.11 for a while.
- **Client-breaking changes in 12.0** that we must design for:
  - **Legacy authorization is off by default, including on upgraded servers.** `X-Emby-Token`, `X-MediaBrowser-Token` and the `api_key` query parameter return 401. What works is the `Authorization: MediaBrowser Client="…", Device="…", DeviceId="…", Version="…", Token="…"` header, or the `ApiKey` query parameter (needed for the WebSocket handshake and for URLs handed to players).
  - The `/emby/*` and `/mediabrowser/*` route prefixes are gone.
  - Six obsolete routes were removed, including `GET /QuickConnect/Initiate`. Use `POST` instead.
  - Image endpoints no longer upscale beyond the source resolution, so cards must handle small source art.
  - Name sorting now uses `SortName`/`CleanName`, so ordering can differ from 10.11.
- **OpenAPI:** the stable spec at `api.jellyfin.org` reports version 12.2.0 and has 294 paths. It declares a single security scheme: an API key in the `Authorization` header.
  - The dynamic HLS routes (`master.m3u8` and friends) are **not** in the published stable spec. Clients should use the `TranscodingUrl` that `PlaybackInfo` returns rather than building HLS URLs by hand.
- **SDKs:** `jellyfin-sdk-kotlin` is still **JVM and Android only, not Kotlin Multiplatform**. There is a TypeScript SDK and no official Dart SDK. Whatever stack we pick, we generate our own client from the spec.
- **Server features a modern client is expected to use** (all confirmed in the 12.2 spec):
  - Media segments: `GET /MediaSegments/{itemId}`, with the types Intro, Outro, Recap, Preview, Commercial and Unknown.
  - Trickplay: `GET /Videos/{itemId}/Trickplay/{width}/{index}.jpg` and `tiles.m3u8`.
  - Lyrics: `GET /Audio/{itemId}/Lyrics`.
  - SyncPlay: 22 routes plus the `SyncPlayCommand`/`SyncPlayGroupUpdate` WebSocket messages.
  - Quick Connect, in both directions: `Initiate`, `Connect`, `Authorize`, and `AuthenticateWithQuickConnect`.
  - User-scoped routes that drop `{userId}` from the path: `/UserItems/Resume`, `/UserViews`, `/UserPlayedItems/{id}`, `/UserFavoriteItems/{id}`, and `/UserItems/{id}/UserData`.
  - `VideoRangeType`, which distinguishes SDR, HDR10, HDR10+, HLG and several Dolby Vision variants (`DOVIWithHDR10`, `DOVIWithEL`, and others).
  - Backup routes (`/Backup*`), new in the 10.11/12 era, which are admin-only.

**Decision:** support **10.11.x and 12.x**. Use only the `Authorization` header (`ApiKey` where a URL must carry the token) and only non-prefixed routes. CI runs the integration suite against both versions. Supporting 10.10 costs little extra and can be decided later.

## Existing clients

| Client | Stack | Platforms | Playback | License | Notes |
|---|---|---|---|---|---|
| **jellyfin-web** (official) | Web | Browser, and wrapped by the official mobile and desktop apps | HTML5 video | GPL-2.0 | Reference implementation. Codec support is limited by the browser. |
| **Jellyfin Desktop** (official, formerly Jellyfin Media Player) | Qt 6 + MpvQt, embedding jellyfin-web | Linux (Flathub, AUR); Windows and macOS builds lag | mpv | GPL-2.0 | 2.0 (Dec 2025) renamed the app and moved it to Qt 6 without migrating settings. A further CEF-based rewrite is in progress. |
| **Swiftfin** (official) | SwiftUI | iOS, tvOS | VLCKit + native AVKit | MPL-2.0 | Two players, with tradeoffs between them: VLCKit has audio-delay and TLS 1.3 issues, while AVKit can't render baked-in subtitles. |
| **Findroid** | Kotlin, native | Android only (TV planned) | ExoPlayer + mpv | GPL-3.0 | Downloads, trickplay, segment skip, PiP. Requires **server 12.0+**. No SyncPlay or Chromecast yet. ~4.3k stars. |
| **Streamyfin** | React Native / Expo | iOS, Android, TV target | mpv on all platforms (MPVKit on iOS) | MPL-2.0 | Downloads (experimental, transcoded via HLS→FFmpeg), Chromecast, Seerr, custom auth headers. Has said music support is unlikely soon. ~5.3k stars. |
| **Fladder** | Flutter | Android, Android TV, iOS, macOS, Windows, Linux, web | media_kit (a **vendored fork**) plus fvp/video_player | GPL-3.0 | Downloads with progress sync, trickplay, segment skip, Seerr, comics (cbz/cbr), multi-server and multi-profile. No Chromecast yet. v0.11.1 (2026-09). ~2.7k stars. |
| **Moonfin** | Flutter (3.47+) | Phones and tablets, Windows, macOS, Linux, Android TV, Apple TV, web, experimental Tizen; Roku/webOS in separate repos | media_kit/libmpv on Android and desktop, with **forked** libs packages; **AetherEngine** on Apple through its own native package since 2.3.2 | GPL-2.0 | Our closest competitor in breadth: SyncPlay, Google Cast/DLNA/AirPlay, music with synced lyrics, Live TV/DVR, Seerr, original or transcoded downloads. Also supports Emby. Ships a companion server plugin. ~860 stars. |
| **Finamp** | Flutter | Android, iOS, plus desktop through just_audio_media_kit | **Forked** just_audio and audio_service | MPL-2.0 | Music only. 1.0.1 (2026-10-11) shipped the long-running redesign: gapless, ReplayGain, offline, transcoding, experimental Android Auto. ~4.3k stars. |
| **Feishin / Supersonic / Symfonium** | Electron / Go / native Android (paid) | Desktop / desktop / Android | various | various | Music specialists. Symfonium is the audiophile benchmark on Android. |
| **Infuse, SenPlayer, VidHub** | Native, commercial | Apple (+ others) | Proprietary | Closed | The polish benchmark on Apple devices. Infuse needs Pro for full Jellyfin integration. |

Other active projects worth watching: Wholphin and JellyWatch (Android TV), Jellify (React Native, music), Delfin and tsukimi (GTK), FluentFin (WinUI 3), and Blink (Flutter).

## What this tells us

1. **Flutter is the proven multi-platform route.** The two clients that ship on all five of our platforms, Moonfin and Fladder, are both Flutter. No React Native, Compose Multiplatform or Tauri Jellyfin client covers desktop *and* mobile with serious playback.
2. **Playback is where clients differ, and where they hurt.** Every serious client ended up with more than one engine: Swiftfin has VLCKit + AVKit, Findroid ExoPlayer + mpv, Moonfin mpv + AetherEngine. Plan for this from day one instead of discovering it in year two.
3. **Apple is the hardest playback platform.** AVPlayer won't open MKV and has narrow codec support. MPVKit's own README says it is "only suitable for learning" and is infrequently maintained, and points to AetherEngine (about two months old) for production use. We need a plan for Apple playback that we control (see [tech-stack.md](tech-stack.md) and [playback.md](playback.md)).
4. **Music + video in one app is rare, and done well it's rarer still.** Moonfin is trying. Everyone else picks one.
5. **Downloads are table stakes, and transcoded downloads are still experimental** in most clients. That's an opportunity to differentiate.
6. **SyncPlay and Chromecast** are on almost every roadmap and missing from most shipped apps.
7. **The server moves under you.** 12.0 broke clients that used legacy auth. Pin the spec, test against several server versions, and keep version-conditional behaviour in one place.
8. **Licensing shapes distribution.** GPL-3.0 apps have had trouble with the App Store, and MPL-2.0 (Swiftfin, Streamyfin, Finamp) is the common choice for clients that ship there. libmpv must be the LGPL build, linked dynamically.
9. **Every serious Flutter media client forks its media stack.** Fladder vendors media_kit. Moonfin forks media_kit_video (to fix Wayland frame presentation), the Windows libmpv package (for a newer libmpv), and background_downloader. Finamp forks just_audio and audio_service. Budget for owning these layers from day one, not for consuming them off the shelf.

## Sources

- Jellyfin releases (12.0 notes, 12.1, 12.2): https://github.com/jellyfin/jellyfin/releases
- Jellyfin 12.0 and legacy auth removal: https://www.helpnetsecurity.com/2026/09/08/jellyfin-12-0-security-fixes/
- `ApiKey`/`Authorization` migration example (Anchorr v1.6.1): https://newreleases.io/project/github/openVESSL/Anchorr/release/v1.6.1
- Versioning change to 12.0: https://jellywatch.app/blog/jellyfin-version-12-0-versioning-change-roadmap-2026
- OpenAPI stable spec: https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json
- jellyfin-sdk-kotlin: https://github.com/jellyfin/jellyfin-sdk-kotlin
- Jellyfin Desktop 2.0: https://alternativeto.net/news/2025/12/jellyfin-desktop-2-0-launches-with-rebranding-qt-6-upgrade-and-fresh-features
- Swiftfin player notes: https://github.com/jellyfin/swiftfin/releases, https://forum.jellyfin.org/t-swiftfin-tvos-subtitles-native-player
- Findroid: https://github.com/jarnedemeulemeester/findroid
- Streamyfin: https://github.com/streamyfin/streamyfin
- Fladder: https://github.com/DonutWare/Fladder
- Moonfin: https://github.com/Moonfin-Client/Moonfin-Core, https://newreleases.io/project/github/Moonfin-Client/Moonfin-Core/release/2.3.2
- Finamp 1.0: https://newreleases.io/project/github/finamp-app/finamp/release/1.0.1
- MPVKit: https://github.com/mpvkit/MPVKit
- AetherEngine: https://swiftpackageindex.com/superuser404notfound/AetherEngine
- Client roundup: https://jellywatch.app/blog/best-jellyfin-clients-apps-2026

- Dependency facts (forks, engines) come from each project's `pubspec.yaml` on its default branch, read through the GitHub API on 2026-10-18.

**Not verified:** exact current versions and release dates for Findroid and Streamyfin. Star counts are approximate.
