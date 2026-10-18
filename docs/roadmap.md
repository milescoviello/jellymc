# Roadmap

## Team assumptions

All durations assume **two full-time engineers**: one strong in Flutter/Dart, and one comfortable in Kotlin and Swift for the player and platform plugins. They also assume a part-time designer for M1–M4. Scale the durations roughly linearly with team size; playback work parallelizes poorly below two people. The estimates are planning ranges, not commitments.

| Milestone | Duration | Cumulative | Outcome |
|---|---|---|---|
| **M0** Foundations + spikes | 4 wk | 4 wk | Repo, CI, API client, auth. Every risky playback question answered. |
| **M1** Watch MVP | 8 wk | 12 wk | Browse and play video well on all five platforms (internal builds) |
| **M2** Offline + platform integration | 6 wk | 18 wk | Downloads, PiP, Cast/AirPlay, media sessions, controllable by other clients |
| **M3** Music | 6 wk | 24 wk | A full music client: gapless, lyrics, Android Auto/CarPlay, offline |
| **M4** 1.0 hardening + launch | 4 wk | **28 wk (~6.5 months)** | Store releases on all platforms |
| **M5** Social & power | 8–10 wk | | SyncPlay, remote control, Live TV/DVR, Seerr, light admin, photos |
| **M6** Expansion | 10–12 wk | | TV builds, books/comics/audiobooks, desktop HDR output, widgets |

## M0: Foundations and spikes (4 weeks)

**Build:**

- Monorepo skeleton (see [architecture.md](architecture.md#repository-layout)), FVM-pinned Flutter, melos scripts, lint rules.
- CI on GitHub Actions: Linux runners for Android, Linux and the unit tests; macOS for iOS and macOS; Windows. Every PR builds all five targets.
- `jellyfin_api` generated from the vendored 12.2 spec, plus the `JellyfinClient` facade, `ServerCapabilities`, and the auth header.
- Dockerized Jellyfin **10.11.x and 12.x**, set up automatically through the `/Startup/*` routes and `/Library/VirtualFolders`, with a seeded fixture library.
- Account flow: add server, log in (password and Quick Connect), multiple servers and users, secure storage.
- Design tokens and the adaptive shell.

**Spikes** (each time-boxed, each ending in a written decision in `docs/decisions/`):

| # | Question | Pass criteria |
|---|---|---|
| S1 | Can libmpv render through a Flutter texture well on all five platforms? | 4K HEVC 10-bit 60 fps with hardware decoding and no dropped frames on reference hardware. Works on Wayland and X11, and on Windows with both NVIDIA and Intel. |
| S2 | Media3 in a Flutter platform view on Android | HDR10 and DV output on an HDR phone, PiP, acceptable overhead from hybrid composition |
| S3 | **iOS engine bake-off:** our own libmpv xcframework vs AetherEngine vs AVPlayer with server remux | PiP feasibility with mpv (sample-buffer layer), DV handling, binary size, acceptance by TestFlight/App Store review. **Decide the iOS default.** |
| S4 | Generated-client quality | Clean compile and acceptable build time. Round-trip tests pass against both server versions. |
| S5 | Transcoded downloads | Progressive transcode vs HLS segment download: resumability, iOS background transfer, seekable result |
| S6 | Music engine | Forked just_audio + audio_service: gapless on all five platforms, an Android Auto browse tree, a CarPlay template proof of concept |

**Admin tasks with long lead times:** request the Apple **multicast networking** and **CarPlay audio** entitlements. Register the bundle IDs and the Play Console app. Get code-signing certificates: Apple Developer, a Windows signing certificate, and Flathub app ID verification.

**Exit:** all spikes are decided, CI is green on five targets, and a debug build logs in on every platform.

## M1: Watch MVP (8 weeks)

**Scope** (the M1 rows in [features.md](features.md)):

- Home rows (resume, next up, latest).
- Library browsing with sort, filter and alphabet jump.
- Detail pages, search, played and favourite actions.
- The full video player:
  - engine selection and the device profile builder
  - direct play, direct stream and transcode
  - tracks, subtitles with styling, trickplay, chapters, segment skip, up next, the stats overlay
  - progress reporting
  - mpv tone-mapping
- The cache layer with WebSocket invalidation.
- Diagnostics and "send logs to server".

**Exit:**

- The conformance matrix passes the agreed bar on reference devices: 100% of fixtures play by *some* method, and direct play happens where the engine supports it.
- Cold start and scroll budgets are met.
- Internal dogfooding has started on all five platforms.

## M2: Offline and platform integration (6 weeks)

**Scope:**

- Downloads (original and transcoded), offline mode, and the sync queue.
- Auto-download rules.
- PiP, background audio, and media sessions for video.
- Chromecast and AirPlay.
- Being controllable by other clients.
- Native HDR output through Media3 and AVPlayer.
- Audio passthrough.
- LAN/WAN switching, custom headers, TLS pinning.
- Roaming settings and the customizable home.
- Desktop tray and media keys.

**Exit:**

- A full flight-mode test passes: download, watch offline, and progress syncs on reconnect.
- Casting works end to end.
- Beta channels are open (TestFlight, Play open testing, Flathub beta, a Windows preview build).

## M3: Music (6 weeks)

**Scope:** the M3 rows: library, queue, gapless, normalization, Instant Mix, synced lyrics, playlists, offline music, Android Auto, CarPlay, and MPRIS/SMTC.

**Exit:**

- Gapless playback is verified on live albums across all five platforms.
- Android Auto and CarPlay are checked against the platforms' quality guidelines.
- A 4-hour background playback soak test shows no memory growth.

## M4: 1.0 hardening and launch (4 weeks)

**Scope:**

- Bug bash and performance pass.
- Accessibility audit, RTL, the Weblate pipeline with first community translations.
- SSO login, theme music, voice search, Discord presence.
- Store listings and screenshots.
- Privacy policy (no data collection), docs site, issue templates.

**Exit:** live in the App Store (iOS and, optionally, macOS), Google Play, F-Droid, GitHub Releases, Flathub, winget/Microsoft Store, and a Homebrew cask.

## M5 / M6 (post-1.0)

Ordered by user value per unit of effort:

1. Remote control of other sessions.
2. SyncPlay. Budget 3–4 weeks: time sync, the buffering/ready protocol, and the group queue.
3. Live TV: channels and playback first, then the EPG grid, then DVR.
4. Seerr.
5. Light admin.
6. Photos.
7. TV builds (Android TV first; tvOS after a spike).
8. Audiobooks.
9. EPUB, PDF and comics readers.
10. Desktop HDR output.
11. Widgets.

## Testing

- **Unit tests** for `jellymc_core`, in pure Dart: repositories, the sync queue, `DeviceProfileBuilder` snapshot tests per (platform, engine, probe), `EngineSelector` scoring tables, ticks and URL helpers.
- **API contract tests** run against the dockerized 10.11.x and 12.x servers on every PR, with the generated client exercised end to end: login, browse, `PlaybackInfo`, reporting, WebSocket events.
- **Widget and golden tests** per width class (compact, medium, expanded) in light and dark themes, for key screens.
- **On-device E2E** with `patrol` on an Android emulator and an iOS simulator in CI, plus `integration_test` on Linux desktop.
- **The conformance suite** (see [playback.md](playback.md#conformance-suite)) runs per release candidate on a small device lab:
  - a mid-range Android phone
  - an Android phone with a Dolby Vision decoder
  - an older iPhone (A14-class) and a current one
  - an Apple Silicon Mac
  - a Windows PC with an NVIDIA GPU and one with an Intel iGPU
  - a Linux laptop under Wayland
- **Soak tests:** 4 hours of music in the background, 3 hours of video, and a 500-item download queue.

## Release engineering

- **Channels:** nightly (CI artifacts), beta (TestFlight, Play open testing, Flathub beta), and stable. Versions use semver, with per-platform build numbers taken from CI.
- **Store pipeline:** Fastlane for App Store and Play uploads; signing secrets stay in CI only.
- **macOS outside the store:** notarized DMG and a Homebrew cask.
- **Windows:** signed MSIX for the Microsoft Store and winget, plus an Inno Setup installer.
- **Linux:** Flathub (primary), AppImage, and an AUR package.
- **F-Droid flavor:** no Google Cast SDK and no proprietary dependencies, with reproducible builds.
- **In-app update notices** for non-store desktop builds, checked against GitHub Releases.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Playback fragmentation across 3 engines × 5 platforms | High | High | M0 spikes first, a single engine interface, the conformance matrix in CI, and the fallback chain |
| iOS playback: MPVKit is "for learning", AetherEngine is very new | High | High | Spike S3. Own the libmpv xcframework build. AVPlayer as the guaranteed baseline. |
| Flutter media plugins (media_kit, just_audio, audio_service) have small maintainer pools | High | Med | Vendor or fork from day one behind our own interfaces; budget maintenance time |
| HDR fidelity through Flutter textures | Med | Med | Tone-map in 1.0; native surfaces (platform views / native windows) for real HDR |
| Server API drift (12.0 already broke legacy auth) | Med | Med | Pinned spec, `ServerCapabilities`, CI against several server versions, a spec diff report on regeneration |
| Apple entitlements (multicast, CarPlay) delayed or refused | Med | Med | Apply in M0; manual-URL fallback; CarPlay ships when granted |
| App Store review: LGPL dynamic libs, codecs, "media piracy" perception | Med | High | MPL-2.0 license, LGPL dynamic frameworks, no bundled content, a clear "connect to your own server" onboarding with a demo server for reviewers |
| Codec patent exposure in a paid product | Low (free) / Med (paid) | High | Legal review before any monetization; prefer OS hardware decoders |
| Scope creep ("many features") | High | High | Milestone gates. Nothing from M5/M6 enters before 1.0. The catalogue in features.md is the contract. |
| Performance on huge libraries (50k+ items) | Med | Med | Lean `Fields`, paging, virtualized grids, synthetic large-library fixtures |

## Open decisions

These need your call. Each has a recommendation, and the docs assume it until you say otherwise.

1. **License:** MPL-2.0 *(recommended)*, GPL-3.0 (App Store friction), or Apache-2.0 (permissive).
2. **Business model:** free and open source *(assumed)*, or a paid or freemium tier. A paid tier changes the codec legal review and the store setup.
3. **Minimum server version:** 10.11 *(recommended)*, or 12.0+ only like Findroid (simpler, but it excludes admins who haven't upgraded yet).
4. **TV in 1.0?** No *(recommended)*. The UI is focus-first, so TV follows in M6.
5. **Team:** the estimates assume 2 engineers plus a part-time designer. With one engineer, expect roughly 1.8–2× the calendar time.
6. **Name and branding:** "jellymc" is a working name. Check the Jellyfin trademark guidance before choosing the final name and icon.
7. **Emby support:** no *(recommended)*. Moonfin does it, but it doubles the compatibility surface.
8. **Companion server plugin** (as Moonfin has one): none required *(recommended)*. DisplayPreferences covers settings roaming, so revisit only if a feature truly needs server-side code.
