# Feature catalogue

Every feature is tagged with the milestone that delivers it. Milestones are defined in [roadmap.md](roadmap.md).

| Tag | Milestone |
|---|---|
| **M1** | Watch |
| **M2** | iPhone essentials + Linux integration |
| **M3** | Polish ("1.0 for me") |
| **M4** | Extras |
| **M5** | Maybe |

The **Where** column says which platform gets the feature: Both, iOS (iPhone/iPad), or Linux. API references are 12.2 routes.

## 1. Server and account

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Add server by URL, with `/System/Info/Public` check | M1 | Both | Friendly errors for "not Jellyfin", "too old", TLS |
| Username/password login | M1 | Both | Token in the Keychain, or a private file on Linux |
| Multiple addresses per server (LAN + remote) with auto-switching on network change | M2 | Both | Matters most on the iPhone |
| Reverse-proxy base path, custom headers, your own CA | M2 | Both | Only if your setup needs them |
| Approve another device's Quick Connect code from the app | M4 | Both | `POST /QuickConnect/Authorize`, handy for signing in TV apps |
| Quick Connect login (code shown on this device) | M5 | Both | Rarely needed for one user |
| Multi-server / multi-user switching UI | M5 | Both | The data model already supports it |
| LAN discovery | — | — | Needs the iOS multicast entitlement (not on a free Apple ID), and you know your URL |

## 2. Home and discovery

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Continue Watching | M1 | Both | `/UserItems/Resume` |
| Next Up | M1 | Both | `/Shows/NextUp` |
| Latest per library | M1 | Both | `/Items/Latest` |
| Library tiles | M1 | Both | `/UserViews` |
| Hero/spotlight carousel (backdrops, logos) | M1 | Both | |
| Favourites rows | M1 | Both | |
| Customizable home: reorder, hide, add rows (genre, collection, playlist, smart filter) | M2 | Both | Roams through DisplayPreferences, so it's the same on all devices |
| "Because you watched…" rows | M2 | Both | `/Items/{id}/Similar` |
| Recently added episodes grouped by series | M2 | Both | |
| "Downloaded" row when offline | M2 | iOS | |

## 3. Library browsing

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Grid / list / thumb views, adjustable density | M1 | Both | Remembered per library |
| Sorting: name, date added, release date, rating, runtime, play count, last played, random | M1 | Both | |
| Filters: played/unplayed, favourites, genres, years, rating, tags, studios | M1 | Both | Values from `/Items/Filters2` |
| Technical filters: 4K, HDR, Dolby Vision, codec, subtitles available | M2 | Both | |
| Alphabet jump bar | M1 | Both | |
| Shuffle a library or filtered view | M1 | Both | |
| Series → seasons → episodes, with missing-episode toggle | M1 | Both | |
| Collections (box sets): browse; create and edit | M1 / M4 | Both | `/Collections` |
| People pages (filmography) | M1 | Both | `/Persons` |
| Genre, studio and year pages | M2 | Both | |
| Multi-select: mark played, favourite, add to playlist, download | M2 | Both | Shift/ctrl-click on Linux; long-press on iOS |
| Folder view for home videos and mixed libraries | M2 | Both | |

## 4. Item details

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Detail page: backdrop, logo, overview, ratings, genres, runtime, ends-at time | M1 | Both | |
| Media info: versions, tracks, codecs, bitrate, HDR type, and **which engine will play it and how** | M1 | Both | Shows the engine rule's decision before you press play |
| Pick version, audio track and subtitle track before playing | M1 | Both | |
| Resume or start over | M1 | Both | |
| Cast & crew | M1 | Both | |
| Seasons/episodes with progress and a next-up highlight | M1 | Both | |
| Trailers (local + remote), special features, extras | M2 | Both | `/Items/{id}/SpecialFeatures` |
| Mark played/unplayed, favourite, rating | M1 | Both | `/UserPlayedItems`, `/UserFavoriteItems`, `/UserItems/{id}/Rating` |
| Add to playlist or collection | M2 | Both | |
| Download with a quality picker | M2 | Both | Mainly iOS |
| Share a deep link (`jellymc://item/{itemId}`) | M3 | Both | E.g. send from Linux to the phone through KDE Connect |
| Admin: refresh metadata, identify, edit images and metadata | M4 | Both | You're the admin. `/Items/RemoteSearch/*` |

## 5. Search

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Instant search across libraries, grouped by type | M1 | Both | `/Search/Hints` + `/Items?searchTerm=` |
| Recent searches | M2 | Both | |
| Search filters (type, library, year, played) | M2 | Both | |
| Global "/" or Ctrl+K search shortcut | M1 | Linux, iPad keyboard | |
| Dictation | — | iOS | Comes free with the iOS keyboard |

## 6. Video player

| Feature | Tag | Where | Notes |
|---|---|---|---|
| mpv engine with full direct play | M1 | Both | |
| AVPlayer engine and the iOS engine rule | M1 | iOS | See [playback.md](playback.md#engine-selection) |
| Direct play / direct stream / transcode negotiation | M1 | Both | |
| Audio and subtitle track switching | M1 | Both | |
| Full ASS styling, PGS, VobSub | M1 | Both (mpv) | |
| Subtitle styling, "override ASS styles", vertical position | M1 | Both | Roams |
| Subtitle and audio delay | M1 | Both | |
| Trickplay thumbnails | M1 | Both | |
| Chapters: markers, list, next/previous | M1 | Both | |
| Skip intro / recap / preview / commercial; per-type auto-skip | M1 | Both | `/MediaSegments/{id}` |
| Up next countdown (no "Still watching?": if it plays, someone is) | M1 | Both | |
| Resume and progress reporting | M1 | Both | |
| Quality selector (auto, original, bitrate ladder) | M1 | Both | |
| Playback speed with pitch correction | M1 | Both | |
| Aspect, zoom and crop; pinch to fill | M1 | Both | |
| Touch gestures: swipe seek, brightness/volume, double-tap ±10 s | M1 | iOS | |
| mpv-style keyboard shortcuts, scroll volume, double-click fullscreen | M1 | Linux, iPad keyboard | |
| Stats overlay (engine, play method, transcode reasons, dropped frames) | M1 | Both | |
| Video queue: play series from here, playlists, shuffle | M1 | Both | |
| HDR tone-mapping in mpv | M1 | Both | |
| Real HDR / Dolby Vision through AVPlayer | M2 | iOS | |
| Real HDR through the mpv HDR window on Plasma | M2 | Linux | Your panel and Plasma HDR mode |
| Picture-in-picture, including auto-PiP when leaving the app | M2 | iOS (AVPlayer) | |
| Always-on-top mini-player window | M2 | Linux | |
| AirPlay to Apple TV or AirPlay TVs | M2 | iOS | |
| Background audio for video (keep listening, screen off) | M2 | iOS | Opt-in |
| Sleep timer (end of episode / N minutes) | M2 | Both | |
| Touch lock | M2 | iOS | |
| Screenshot to file | M3 | Linux | |
| Custom `mpv.conf` passthrough | M3 | Linux | For power tweaks (shaders, scalers) |
| Cinema mode (trailers before the feature) | M4 | Both | `/Items/{id}/Intros` |
| HDMI audio passthrough | M4 | Linux | Only if you connect a receiver |
| mpv PiP on iOS (sample-buffer layer bridge) | M5 | iOS | Swift-heavy; only if mpv-only titles in PiP matter |

## 7. Offline and downloads

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Download original file (with subtitles, fonts, trickplay, chapters, segments, images) | M2 | Both | |
| Download transcoded, as AVPlayer-friendly HEVC/AAC MP4 | M2 | Both | PiP and HDR work offline |
| Download queue: pause, resume, retry; survives suspension | M2 | Both | iOS background `URLSession` |
| Wi-Fi-only, storage cap, "show in Files app" | M2 | iOS | |
| Offline mode: browse and play with no connection | M2 | Both | |
| Played state and progress sync back on reconnect | M2 | Both | |
| Auto-download the next N episodes; delete after watched | M2 | Both | |
| Series/season download in one tap | M2 | Both | |

## 8. Remote control, SyncPlay, casting

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Be a cast target: receive "Play on jellymc (Linux)" from jellyfin-web or the phone | M2 | Linux (and iOS in the foreground) | `/Sessions/Capabilities/Full` + WebSocket |
| Use the iPhone as a remote for the Linux app or other sessions | M4 | iOS | `/Sessions/{id}/Playing`, `/Command` |
| Hand-off: "continue on Linux" / "continue on phone" at the current position | M4 | Both | Built on the remote-control commands |
| SyncPlay: watch in sync with friends | M4 | Both | 22 `/SyncPlay/*` routes + WebSocket; time sync via `/GetUtcTime` |
| Chromecast | M5 | iOS | Only if you own a Chromecast |

## 9. Light admin (you're the admin)

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Active sessions: who's playing what, transcode reasons, stop a session | M4 | Both | `/Sessions` |
| Scheduled tasks: run a library scan, see progress | M4 | Both | `/ScheduledTasks` + WebSocket progress |
| Refresh a library or item | M4 | Both | `/Library/Refresh` |
| Activity log | M4 | Both | `/System/ActivityLog/Entries` |
| Server log viewer | M5 | Linux | `/System/Logs` |
| Plugin updates | M5 | Both | `/Plugins`, `/Packages` |
| Everything else | — | — | Deep-link to jellyfin-web |

## 10. Integrations

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Intro Skipper (or any media-segment plugin) | M1 | Both | Generic through media segments |
| Seerr: discover and request | M4 | Both | Only if you run Seerr |

## 11. Platform polish

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Adaptive layouts: iPhone, iPad Split View / Stage Manager, desktop window sizes | M1 | Both | |
| iPad keyboard and trackpad: shortcuts, hover, context menus | M2 | iOS | Shared with Linux |
| Tray icon, single instance, remembered window state | M2 | Linux | StatusNotifierItem on KDE |
| Screen-saver inhibit during playback | M1 | Linux | |
| Notifications (download done, library scan done) | M2 / M4 | Both | |
| Deep links | M3 | Both | |
| Discord Rich Presence | M4 | Linux | Opt-in |
| Home-screen widgets, Live Activities, share extension | — | iOS | Each extension uses a free-account App ID, so only with a paid account |

## 12. Settings

| Feature | Tag | Where | Notes |
|---|---|---|---|
| Theme (dark/light/AMOLED), dynamic colour from artwork | M1 | Both | |
| Language rules for audio and subtitles | M1 | Both | |
| Playback: engine overrides, bitrate for LAN/remote/cellular, max resolution, skip rules, autoplay, keep ASS styling | M1 / M2 | Both | |
| Roaming settings through DisplayPreferences | M2 | Both | |
| Diagnostics: log viewer, export, "send logs to server" | M1 | Both | `/ClientLog/Document`; essential on iOS without a debugger |
| Data saver on cellular | M2 | iOS | |

## Dropped from the earlier public, five-platform scope

These no longer apply:

- Android, Windows and macOS builds, and TV builds.
- App Store, Play, F-Droid and Flathub distribution.
- Translations and RTL.
- A formal accessibility audit (good practice stays).
- SSO, parental controls and profile PINs.
- Voice search.
- Music, audiobooks, Live TV, photos and books: the app is for films and shows.
- Emby support.
