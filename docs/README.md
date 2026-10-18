# jellymc scope

Scoping docs for a from-scratch, feature-rich Jellyfin client for **iOS, Android, Windows, macOS and Linux**. Written 2026-10-18 against Jellyfin server **12.2** (the current stable release).

## The short version

- **What:** one app that does video, music, and eventually Live TV, books and photos well, on phones, tablets and desktops. It should be the client people install on every device they own.
- **Where we can win:** No Jellyfin client today is excellent on all five platforms *and* across media types. Video-first clients treat music as an afterthought, or don't support it at all (Streamyfin says it's unlikely to support music soon). The best music clients don't do video. Desktop is served by web wrappers. Our edge is real direct-play breadth (mpv-class codec and subtitle support) combined with native platform features (PiP, media sessions, CarPlay/Android Auto, offline) in a single codebase.
- **Stack (recommended):** **Flutter** for UI and app logic, with a **pluggable native playback layer**: libmpv on every platform, plus Media3 on Android and AVPlayer on Apple where they work better (HDR, PiP, AirPlay, battery). See [tech-stack.md](tech-stack.md).
- **Hardest part:** playback, by a wide margin. The plan front-loads playback spikes on all five platforms before any feature work (milestone M0).
- **Size:** roughly **6–7 months to a public 1.0** (video + offline + music) for a two-person team, then SyncPlay, Live TV, TV/10-foot UI and books after 1.0. See [roadmap.md](roadmap.md).

## Documents

| Doc | What it answers |
|---|---|
| [landscape.md](landscape.md) | What state is the server API in, who else is building clients, and what we learn from them? |
| [tech-stack.md](tech-stack.md) | Which framework, players, and libraries, and why? What were the alternatives? |
| [architecture.md](architecture.md) | How is the code organised: modules, data flow, offline/sync, the server-compatibility layer |
| [playback.md](playback.md) | How playback works end to end: device profiles, engine selection, direct play vs transcode, subtitles, HDR, reporting |
| [features.md](features.md) | The full feature catalogue, grouped by domain and tagged with a milestone |
| [roadmap.md](roadmap.md) | Milestones, spikes, exit criteria, team assumptions, testing and release, risks, open decisions |

## Goals

1. **Plays everything the server has, without transcoding where the device can handle it.** MKV, HEVC, AV1, 10-bit, HDR10/HLG/Dolby Vision, styled ASS subtitles, PGS, lossless and surround audio.
2. **Feels native on each form factor.** Phone, tablet and desktop are all first-class: adaptive layouts, keyboard and mouse on desktop, gestures on touch screens. TV is designed for from the start and ships later.
3. **Works offline.** Downloads in original or transcoded quality, with watch state that syncs back when the device reconnects.
4. **Video and music are equal citizens.** Gapless playback, queues, lyrics, CarPlay/Android Auto: music is not bolted on.
5. **Integrates with the operating system.** PiP, lock-screen and notification controls, MPRIS/SMTC/Now Playing, Chromecast, AirPlay, media keys.
6. **Respects the server.** No accounts of our own, no telemetry by default, and server-side settings and permissions are the source of truth.

## Non-goals (for 1.0)

- Replacing the server admin web UI. A light admin surface comes later; full server configuration stays in jellyfin-web.
- Emby/Plex support. The API layer is Jellyfin-specific on purpose.
- A web build. Flutter web can't use libmpv, and jellyfin-web already exists.
- Smart-TV platforms that Flutter can't target (Roku, webOS, Tizen).
- Server plugins of our own. We use existing plugins (Intro Skipper, SSO, Seerr) and don't require any.

## Glossary

- **Direct play:** the client plays the original file as-is.
- **Direct stream:** the server remuxes or copies streams into a different container without re-encoding video.
- **Transcode:** the server re-encodes. This costs server CPU/GPU and quality, so we try to avoid it.
- **Device profile:** the capability description the client sends to the server, which the server uses to decide among the three modes above.
- **Ticks:** Jellyfin's time unit. 1 tick = 100 ns, so 10,000,000 ticks = 1 s.
- **Media segments:** server-side markers for intro, outro, recap, preview and commercial ranges. They power skip buttons.
- **Trickplay:** thumbnail tiles shown while scrubbing.
