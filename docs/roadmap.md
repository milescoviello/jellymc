# Roadmap

## Assumptions

- **One developer (you)**, building on this Linux machine, with no Mac.
- Durations are **focused full-time weeks**. Evenings and weekends stretch them about 3–4×.
- They're planning ranges, not promises. The spikes in M0 exist to make the later estimates honest.

| Milestone | Focused weeks | Cumulative | Outcome |
|---|---|---|---|
| **M0** Foundations + spikes | 3 | 3 | Toolchain, repo, API client, login. iOS build → sideload pipeline working. Every risky playback question answered. |
| **M1** Watch | 6 | 9 | Browse and play video well on Linux, then on the iPhone and iPad |
| **M2** iPhone essentials + Linux integration | 4 | 13 | Downloads and offline, PiP, AirPlay, real HDR on both platforms, Now Playing/MPRIS, LAN↔remote switching |
| **M3** Music | 4 | 17 | Gapless, queue, lyrics, offline music, lock screen and KDE controls |
| **M4** Polish ("1.0 for me") | 2 | **19** | The bugs you've been tolerating, performance, deep links, settings roaming everywhere |
| **M5** Extras | 6–8 | | À la carte: remote control/hand-off, SyncPlay, admin views, photos, Live TV and Seerr if you use them |
| **M6** Maybe | open | | Books and audiobooks, mpv PiP on iOS, Chromecast, CarPlay and widgets (paid account), other platforms |

## M0: Foundations and spikes (3 weeks)

**Set up** (see [dev-workflow.md](dev-workflow.md#one-time-linux-setup-gentoo-this-machine)): the Flutter SDK, mpv with `USE="libmpv vaapi wayland pipewire"`, and check `vainfo`.

**Build:**

- Repo skeleton: `app/` + `packages/jellyfin_api` as a pub workspace, a `justfile`, and lint rules, including "no Flutter imports in `lib/core`".
- `jellyfin_api` generated from the vendored 12.2 spec, plus the `JellyfinClient` facade and the auth header.
- Login, the server session with multiple addresses, and token storage on both platforms.
- Design tokens, the adaptive shell, and the `device_preview` toggle.
- `linux.yml` CI (analyze, test, build) and `ios.yml` (unsigned IPA).
- **`just census`, early,** so the census report of your library (see [playback.md](playback.md#testing-playback-against-your-own-library)) shapes what M1 must get right.

**Spikes.** Each is time-boxed and ends with a short written decision in `docs/decisions/`. **Do S0 first: everything iOS depends on it.**

| # | Question | Pass criteria |
|---|---|---|
| **S0** | Does the iOS pipeline work end to end? | CI builds the IPA. iloader + SideStore install it on the iPhone and the iPad. It launches, refreshes after 7 days, and `idevicesyslog` shows its logs. Background audio and PiP capabilities survive free-account signing. |
| **S1** | mpv on Linux | media_kit texture on Plasma 6.7 Wayland with VA-API on the Arrow Lake iGPU: 4K HEVC 10-bit 60 fps without drops, ASS with attached fonts, no idle-presentation stalls (otherwise apply Moonfin's patch). HDR window mode shows real HDR with Plasma HDR on. |
| **S2** | mpv on iOS | media_kit's iOS libmpv: 4K HEVC 10-bit on the iPhone, ASS and PGS, tone-mapping quality, battery drain per hour vs AVPlayer, app size |
| **S3** | AVPlayer plugin | `better_native_video_player` vs `video_player` + `video_player_pip`: PiP and auto-PiP, AirPlay, Jellyfin HLS with WebVTT subtitles, DV P8.1 and P5 through a Jellyfin remux, and **coexisting with media_kit in one app** without framework conflicts |
| **S4** | Generated client | Clean compile and tolerable build time; round-trip calls against your server |
| **S5** | Transcoded downloads | Progressive transcode vs HLS segments: completes under iOS background `URLSession`, is resumable, and the file plays and seeks in AVPlayer |
| **S6** | Music engine | `just_audio` + `audio_service`: gapless on iOS and Linux (mpv), lock screen and MPRIS controls working |

**If S2 or S3 fails:** iOS falls back to AVPlayer only, with the server remuxing or transcoding the long tail. Or adopt MPVKit or AetherEngine with Swift glue, budgeting a day of rented-Mac time.

**Exit:** all spikes decided, both CI jobs green, and a real build logs in on Linux, the iPhone and the iPad.

## M1: Watch (6 weeks)

**Scope** (the M1 rows in [features.md](features.md)):

- Home rows, library browsing, detail pages with the "how will this play" panel, search, and played/favourite actions.
- The full player:
  - the engine rule and the device profile builder
  - direct play, direct stream and transcode
  - tracks, subtitles with styling, trickplay, chapters, segment skip, up next, the stats overlay
  - progress reporting
- The cache with WebSocket invalidation.
- Diagnostics, including "send logs to server".

Build and dogfood on Linux first. Ship an IPA to the phone every week.

**Exit:**

- Every bucket in the census checklist plays on Linux.
- On the iPhone, every bucket plays by *some* method, and AVPlayer is used wherever the rule says it should be.
- The cold-start and scroll budgets are met.

## M2: iPhone essentials + Linux integration (4 weeks)

**Scope:**

- Downloads (original and transcoded), offline mode, the sync queue, auto-download rules.
- PiP and auto-PiP, AirPlay, and background audio for video.
- Real HDR/DV through AVPlayer, and the mpv HDR window on Linux.
- Now Playing for video, and MPRIS.
- LAN↔remote address switching and remote bitrate detection.
- Roaming settings and the customizable home.
- Being a cast target on Linux.
- Tray icon, mini-player window, iPad keyboard and trackpad support.

**Exit:**

- Flight-mode test: download a season at home, watch offline, and progress syncs on reconnect.
- Walk-out test: playback continues (or recovers within seconds) when the phone moves from home Wi-Fi to cellular.

## M3: Music (4 weeks)

**Scope:** the M3 rows: library, queue, gapless, normalization, Instant Mix, synced lyrics, playlists, offline music, lock screen/Dynamic Island/AirPods controls, KDE media applet and media keys.

**Exit:**

- Gapless playback is verified on a live album on both platforms.
- Four hours of locked-screen background playback on the iPhone with no memory growth.
- The queue survives an app kill and the 7-day re-sign.

## M4: Polish (2 weeks)

Fix the papercuts you've collected. Do a performance pass on your largest library. Add deep links, screenshot-to-file, custom `mpv.conf`, and settings import/export. Finish the release-to-self automation (see below).

## M5 / M6

Pick in order of what you'll actually use. The suggested order for value per effort:

1. Remote control and hand-off between phone and Linux.
2. Admin views: sessions, scan library, activity.
3. SyncPlay (budget 2–3 weeks).
4. Photos.
5. Live TV, if you have a tuner.
6. Seerr, if you run it.
7. Audiobooks, then the readers.
8. mpv PiP on iOS.
9. A paid Apple account for CarPlay and widgets.

## Testing

- **Unit:** `lib/core` and `jellyfin_api`, in pure Dart on Linux. That covers repositories, the sync queue, the engine rule tables, `DeviceProfileBuilder` snapshots per (engine, probe), and ticks/URL helpers.
- **API contract tests:** read-only tests against your real server; destructive ones (playlists, played state, admin) against the scratch Docker server.
- **Widget and golden tests** at compact, medium and expanded widths, in dark and light themes.
- **Linux integration tests** (`integration_test`) for login → browse → play → stop, using the FFmpeg fixtures.
- **The census checklist** (see [playback.md](playback.md#testing-playback-against-your-own-library)) is re-run before every tagged build.
- **On-device pass per IPA:** a 15-minute checklist on the iPhone and the iPad, covering launch, resume, PiP, AirPlay, a download, offline play, and lock-screen music.
- **Soak tests:** 4 hours of background music on the iPhone and 3 hours of video on Linux.

## Releasing to yourself

- **iPhone/iPad:**
  1. Tag `vX.Y.Z`.
  2. `ios.yml` builds the unsigned IPA (with dSYMs as an artifact).
  3. A follow-up step uploads it and an updated AltStore-format `source.json` to your server.
  4. SideStore on each device shows the update and installs it, re-signing with your Apple ID.
- **Linux:** `just install` builds the release bundle into `~/.local/opt/jellymc`, installs a `.desktop` file and icon into `~/.local/share/`, and registers the `jellymc://` URL handler. An ebuild in a personal overlay is optional if you want Portage to own it.
- **Versioning:** semver tags. The build number comes from CI. Settings and the DB migrate forward, never backward.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **No Mac:** native iOS problems are hard to see and fix | Med | High | Plugins over custom Swift; on-device logs and stats overlay; Linux fakes for iOS flows; rent a Mac for a day as a last resort |
| media_kit on iOS or the AVPlayer plugin fails its spike | Med | High | S2/S3 in week 1–2; AVPlayer-only + server remux/transcode fallback; MPVKit/AetherEngine with Swift glue |
| Free Apple ID friction: 7-day expiry, 3 apps, App ID limits | High | Low | SideStore background refresh; no app extensions; a paid account if it gets annoying |
| macOS CI minutes run out on a private repo | Med | Low | Build iOS on tags only; make the repo public; or Codemagic |
| Flutter + media_kit quirks on Wayland | Med | Med | S1; Moonfin's patch; vendored media_kit |
| Hybrid GPU: the app ends up on NVIDIA, or VA-API interop breaks | Low | Med | Keep the app on the iGPU; document the env vars; check `vainfo` in `just doctor` |
| A server upgrade breaks something | Low | Med | Pinned spec; `ServerCapabilities`; re-run contract tests after upgrading the server |
| Scope creep ("many features") | High | High | Milestone gates; M5/M6 are à la carte; nothing past M4 before "1.0 for me" |

## Defaults assumed (change any of these)

1. **Free Apple ID**, not a paid developer account. Upgrade only for CarPlay, widgets, or relief from the 7-day re-sign.
2. **Private repo**, with iOS builds only on tags and the IPA plus SideStore source hosted on your own server.
3. **No access to a Mac**, even occasionally. If you do have one, Swift-heavy items like mpv PiP and CarPlay get much cheaper.
4. **Optional domains:** Live TV, Seerr, books and photos are deferred until you say you use them.
5. **Remote access:** handled by a reverse proxy/domain or a VPN like Tailscale. Either works, and the app just stores both addresses.
