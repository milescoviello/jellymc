# jellymc scope

Scoping docs for **a personal, from-scratch, feature-rich Jellyfin client for iPhone/iPad and Linux**. It's for one user, built and sideloaded by that user, and never published to a store. Written 2026-10-18 against Jellyfin server **12.2**, the current stable release.

## The short version

- **What:** one app that does video and music really well on an iPhone, an iPad, and a Linux desktop (KDE Plasma on Wayland). Live TV, books and photos come later, and only if they get used.
- **Why personal changes things:** no App Store review, no licensing or codec-patent worries, no store pipelines, no translations, no other users to support. All of that time goes into features and playback quality instead.
- **Stack:** **native Swift on both platforms, sharing one core**, the way the Music app is built. iOS uses SwiftUI with AVPlayer (system PiP, AirPlay, Dolby Vision). Linux uses GTK 4/libadwaita through C interop, with libmpv for playback. See [tech-stack.md](tech-stack.md).
- **No Mac, and that's fine:** GitHub Actions compiles the iOS app into an ad-hoc-signed IPA, and `xtool` installs it, exactly as for the Music app. The shared core builds and tests locally on Linux. See [dev-workflow.md](dev-workflow.md).
- **Size:** about **19 focused full-time weeks to "1.0 for me"** (video + offline on iPhone + music). Evenings and weekends stretch that 3–4×. See [roadmap.md](roadmap.md).

## Documents

| Doc | What it answers |
|---|---|
| [landscape.md](landscape.md) | What state is the server API in, who else builds clients, and what we learn from them? |
| [tech-stack.md](tech-stack.md) | Which framework, players and libraries for iOS + Linux without a Mac, and why |
| [dev-workflow.md](dev-workflow.md) | Setting up Gentoo, the daily loop on Linux, building iOS in CI, sideloading, debugging an iPhone from Linux |
| [architecture.md](architecture.md) | How the code is organised: modules, data flow, offline sync, downloads, music pipeline |
| [playback.md](playback.md) | Playback end to end: engine choice, device profiles, direct play vs transcode, subtitles, HDR, reporting |
| [features.md](features.md) | The full feature catalogue, tagged by milestone |
| [roadmap.md](roadmap.md) | Milestones, spikes, testing, risks, and the few remaining decisions |

## Assumptions

These come from you, or from inspecting this machine on 2026-10-18. Correct any that are wrong.

| Assumption | Effect if wrong |
|---|---|
| Targets: **iPhone, iPad, and this Linux machine** | Adding Android or other desktops is mostly packaging, since the stack supports them, but the playback work grows |
| **No Mac available** | If you have one, the iOS dev loop gets much easier (hot reload on device, Xcode debugging), and Swift-heavy features get cheaper |
| **Free Apple ID** for sideloading (apps re-signed every 7 days) | A paid account ($99/yr) gives 1-year signing, TestFlight installs, and lets you request the CarPlay entitlement |
| **Your server runs 12.x** | 10.11 will probably work, since we only use the modern auth forms, but it won't be tested |
| **One server, one user** | The data model allows several. Only the UI for switching is deferred. |
| Linux machine: **Intel Arrow Lake iGPU + RTX 5090 Mobile, KDE Plasma 6.7 on Wayland, Gentoo** | Hardware video decoding and the HDR plan assume this GPU and compositor |

## Goals

1. **Plays everything in your library, without transcoding where the device can handle it.** MKV, HEVC, AV1, 10-bit, HDR10/HLG/Dolby Vision, styled ASS subtitles, PGS, lossless and surround audio.
2. **Feels right on each device.** One-handed use on an iPhone. Split View, keyboard and trackpad on the iPad. Keyboard and mouse, with mpv-style shortcuts, on Linux.
3. **The iPhone works offline.** Downloads in original or transcoded quality, for flights and commutes, with watch state that syncs back.
4. **Music is a first-class citizen.** Gapless playback, a persistent queue, synced lyrics, lock-screen and KDE media controls.
5. **Integrates with the OS.** On iOS: PiP, AirPlay, Now Playing on the lock screen and Dynamic Island, background audio. On Linux: MPRIS (KDE's media applet and media keys), notifications, screen-saver inhibit, HDR output on Plasma.
6. **The server is the source of truth.** No accounts of our own and no telemetry. Settings roam through the server.

## Non-goals

- Android, Windows, macOS, TVs, the web.
- App Store or any public distribution, store assets, a privacy policy, translations, or support for other users.
- Replacing jellyfin-web's admin dashboard. A light admin view comes later, since you are the admin.
- Emby/Plex support.
- Features that need restricted Apple entitlements or app extensions, unless you get a paid account: CarPlay, home-screen widgets, LAN discovery. See [dev-workflow.md](dev-workflow.md#free-apple-id-limits).

## Glossary

- **Direct play:** the client plays the original file as-is.
- **Direct stream:** the server remuxes into another container (for example MKV → HLS fMP4) or transcodes only the audio. The video isn't re-encoded, so it's cheap for the server.
- **Transcode:** the server re-encodes the video. This is expensive and lowers quality, so we avoid it.
- **Device profile:** the capability description the client sends to the server, which the server uses to choose among the three modes above.
- **Ticks:** Jellyfin's time unit. 1 tick = 100 ns, so 10,000,000 ticks = 1 s.
- **Media segments:** server-side ranges marking intros, outros, recaps, previews and commercials. They power the skip buttons.
- **Trickplay:** thumbnail tiles shown while scrubbing.
- **Sideloading:** installing an app you signed yourself, outside the App Store. Here that's `xtool install` with a free Apple ID, re-run weekly.
