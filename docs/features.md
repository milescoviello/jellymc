# Feature catalogue

Every feature is tagged with the milestone that delivers it. Milestones are defined in [roadmap.md](roadmap.md).

| Tag | Milestone |
|---|---|
| **M1** | Watch MVP |
| **M2** | Offline + platform integration |
| **M3** | Music |
| **M4** | 1.0 hardening |
| **M5** | Post-1.0: social & power |
| **M6** | Expansion |

The API references are 12.2 routes.

## 1. Onboarding, servers, accounts

| Feature | Tag | Notes |
|---|---|---|
| Add a server by URL, with `/System/Info/Public` validation and version check | M1 | Friendly errors for "not Jellyfin", "too old", TLS problems |
| LAN server discovery (UDP 7359) | M1 | iOS needs the multicast entitlement, and falls back to manual entry until it's granted |
| Username/password login | M1 | `/Users/AuthenticateByName`; the public user list shows avatars when the server exposes it |
| Quick Connect login (code shown on this device) | M1 | `POST /QuickConnect/Initiate` → poll `Connect` → `AuthenticateWithQuickConnect` |
| Authorize another device's Quick Connect code | M2 | `POST /QuickConnect/Authorize`, so the phone can sign in the TV |
| Multiple servers, multiple users each, fast switching | M1 | Tokens per user in secure storage |
| LAN/WAN address auto-switching | M2 | Probe on network change |
| Custom HTTP headers per server (Cloudflare Access, auth proxies) | M2 | |
| Self-signed certificates via trust-on-first-use pinning, client certificates | M2 | |
| Reverse-proxy base paths | M1 | |
| SSO login (OIDC plugin) | M4 | In-app browser flow |
| Profile PIN / biometric lock, kid-safe profile switching | M5 | Local lock on top of server parental controls |
| First-run server setup wizard (for a brand-new server) | M6 | `/Startup/*` routes |

## 2. Home and discovery

| Feature | Tag | Notes |
|---|---|---|
| Continue Watching | M1 | `/UserItems/Resume` |
| Next Up | M1 | `/Shows/NextUp`, with an optional rewatching mode |
| Latest per library | M1 | `/Items/Latest` |
| Library tiles | M1 | `/UserViews` |
| Hero/spotlight carousel (backdrops, logos) | M1 | Random unplayed or recently added items |
| Favourites rows | M1 | |
| Customizable home: reorder, hide, add rows (genre, collection, playlist, smart filters) | M2 | Roams via DisplayPreferences |
| "Because you watched…" (Similar) rows | M2 | `/Items/{id}/Similar` |
| Recently added episodes grouped by series | M2 | |
| Collections spotlight | M2 | |
| Seerr "trending / request" row | M5 | When Seerr is configured |

## 3. Library browsing

| Feature | Tag | Notes |
|---|---|---|
| Grid / list / banner / thumb views, adjustable density | M1 | Per-library memory |
| Sorting: name, date added, release date, rating, runtime, play count, last played, random | M1 | |
| Filters: played/unplayed, favourites, genres, years, decades, official rating, tags, studios | M1 | `/Items/Filters2` provides the filter values |
| Technical filters: 4K, HDR, Dolby Vision, codec, 3D, subtitles available | M2 | |
| Alphabet jump bar for large libraries | M1 | |
| Shuffle a library or a filtered view | M1 | |
| Series → seasons → episodes, with missing/unaired episode display (toggle) | M1 | |
| Collections (box sets): browse; create/edit for admins | M1 / M5 | `/Collections` |
| People pages (actor/director filmography) | M1 | `/Persons` |
| Genre, studio and year pages | M2 | |
| Multi-select: mark played, favourite, add to playlist or collection, download | M2 | Desktop gets shift/ctrl-click |
| Folder view for mixed or home-video libraries | M2 | |

## 4. Item details

| Feature | Tag | Notes |
|---|---|---|
| Rich detail page: backdrop, logo, overview, ratings, genres, runtime, ends-at time | M1 | |
| Media info panel: versions, video/audio/subtitle tracks, codecs, bitrate, HDR type | M1 | |
| Choose version, audio track and subtitle track before playing | M1 | |
| Resume or start over | M1 | |
| Cast & crew with photos | M1 | |
| Seasons/episodes with progress, played state, and a "next up" highlight | M1 | |
| Trailers (local + remote), special features, extras | M2 | `/Items/{id}/SpecialFeatures`, `RemoteTrailers` |
| Theme music/video on detail pages (opt-in) | M4 | `/Items/{id}/ThemeMedia` |
| Similar items | M2 | |
| Mark played/unplayed, favourite, user rating | M1 | `/UserPlayedItems`, `/UserFavoriteItems`, `/UserItems/{id}/Rating` |
| Add to playlist, add to collection | M2 | |
| Download (with quality picker) | M2 | |
| Share deep link (`jellymc://item/{serverId}/{itemId}`) | M2 | Opens the right server and user |
| Admin: refresh metadata, identify, edit images and metadata | M5 | `/Items/RemoteSearch/*`, `/Items/{id}/RemoteImages` |

## 5. Search

| Feature | Tag | Notes |
|---|---|---|
| Instant search across all libraries, grouped by type | M1 | `/Search/Hints` plus `/Items?searchTerm=` |
| Recent searches, suggestions | M2 | |
| Search filters (type, library, year, played) | M2 | |
| Voice search (mobile) | M4 | Platform speech-to-text |
| Seerr results for titles not in the library ("Request") | M5 | |

## 6. Video player

| Feature | Tag | Notes |
|---|---|---|
| Multi-engine playback with automatic engine selection | M1 | See [playback.md](playback.md) |
| Direct play / direct stream / transcode negotiation | M1 | |
| Audio and subtitle track switching | M1 | |
| Full ASS/SSA styling, PGS, VobSub | M1 | Through mpv |
| Subtitle styling (size, colour, outline, background, position), ASS override | M1 | |
| Subtitle and audio delay adjustment | M1 | |
| External subtitle loading (from server; a local file on desktop) | M1 / M2 | |
| Online subtitle search and download | M4 | When the server has a provider plugin |
| Trickplay thumbnails while scrubbing | M1 | |
| Chapters: markers, list, next/previous | M1 | |
| Skip intro / recap / preview / commercial; per-type auto-skip | M1 | `/MediaSegments/{id}` |
| Up next with countdown; "Are you still watching?" | M1 | |
| Resume position and progress reporting | M1 | |
| Quality selector (auto, original, bitrate ladder) | M1 | |
| Playback speed with pitch correction | M1 | |
| Aspect / zoom / crop modes, pinch-to-zoom | M1 | |
| Gestures: swipe seek, brightness/volume, double-tap ±10 s | M1 | |
| Desktop: keyboard shortcuts (mpv-like), scroll volume, double-click fullscreen | M1 | |
| HDR tone-mapping everywhere; native HDR output on Android/Apple | M1 / M2 | |
| Audio passthrough (AC-3, E-AC-3/Atmos, DTS, TrueHD) | M2 | |
| Playback info overlay (stats for nerds, transcode reasons) | M1 | |
| Video queue: play series from here, playlists, shuffle | M1 | |
| Screenshots (desktop) | M4 | |
| Picture-in-picture | M2 | |
| Background audio for video (keep listening with the screen off) | M2 | Opt-in |
| Sleep timer (end of episode / N minutes) | M2 | |
| Lock controls (child lock) | M2 | |
| Cinema mode: trailers and pre-rolls before the feature | M5 | `/Items/{id}/Intros` |
| Custom mpv config for power users (desktop) | M4 | |
| 3D (SBS/TAB) handling | M6 | |
| True HDR output on desktop | M6 | Native-window mpv |

## 7. Offline and downloads

| Feature | Tag | Notes |
|---|---|---|
| Download original file | M2 | Includes subtitles, trickplay, chapters, segments, images |
| Download transcoded (quality presets) | M2 | Spike S5 picks the mechanism |
| Download queue: pause, resume, retry, reorder; survives restarts | M2 | Background transfers on iOS and Android |
| Wi-Fi-only, storage cap, storage location (SD card / external drive) | M2 | |
| Offline mode: browse and play downloads with no connection | M2 | |
| Played state and progress sync back on reconnect | M2 | Offline mutation queue |
| Auto-download the next N episodes; delete after watched | M2 | |
| Series/season download in one tap | M2 | |
| Music: download albums, playlists, artists; keep playlists synced | M3 | |
| Downloads screen with per-server grouping and storage use | M2 | |

## 8. Music

| Feature | Tag | Notes |
|---|---|---|
| Artists, album artists, albums, songs, genres, playlists | M3 | `/Artists`, `/Artists/AlbumArtists` |
| Album/artist pages: discography, appears-on, similar artists | M3 | `/Artists/{id}/Similar` |
| Now playing: full-screen with dynamic colours, mini-player, desktop sidebar | M3 | |
| Queue: play next, add to queue, reorder, clear; persisted across restarts | M3 | |
| Shuffle and repeat (one/all) | M3 | |
| Gapless playback | M3 | |
| ReplayGain-style normalization (track/album mode) | M3 | `NormalizationGain`, `AlbumNormalizationGain` |
| Instant Mix from song, album, artist, genre or playlist | M3 | `/…/InstantMix` |
| Synced lyrics (line and word-level), tap to seek | M3 | `/Audio/{id}/Lyrics` (`Start`, `Cues`) |
| Playlists: create, edit, reorder, share with users | M3 | `/Playlists/{id}/Items/{itemId}/Move/{newIndex}`, `/Playlists/{id}/Users` |
| Favourite songs, "liked" smart views | M3 | |
| Streaming quality per network (original, or transcoded bitrate) | M3 | `/Audio/{id}/universal` |
| Lock screen, notification, Bluetooth, media keys, MPRIS/SMTC | M3 | |
| Android Auto | M3 | |
| CarPlay | M3 | Needs the Apple entitlement; apply in M0 |
| Sleep timer | M3 | |
| Crossfade | M5 | Desktop first |
| Equalizer | M6 | |
| Music videos linked to tracks | M6 | |
| Last.fm/ListenBrainz scrobbling | — | Handled server-side by plugins; no client work |

## 9. Audiobooks, books, comics

| Feature | Tag | Notes |
|---|---|---|
| Audiobooks: chapters, per-book progress, speed, sleep timer, skip ±30 s | M6 | Uses the music pipeline |
| Podcasts-style "continue listening" row | M6 | |
| EPUB reader | M6 | |
| PDF reader | M6 | |
| Comics (CBZ/CBR) reader: page/strip modes | M6 | |
| Reading progress sync | M6 | The server has no native page-progress field; needs a design spike |

## 10. Photos and home videos

| Feature | Tag | Notes |
|---|---|---|
| Photo albums, grid, zoomable viewer, EXIF info | M5 | |
| Slideshow with music | M6 | |
| Home videos through the normal player | M1 | |

## 11. Live TV and DVR

| Feature | Tag | Notes |
|---|---|---|
| Channel list with now/next | M5 | `/LiveTv/Channels` |
| EPG guide grid (time × channel), favourite channels, categories | M5 | `/LiveTv/Programs` |
| Watch live, channel up/down | M5 | `AutoOpenLiveStream`, `/LiveStreams/Close` |
| Recordings library | M5 | `/LiveTv/Recordings` |
| Schedule recordings, series timers, conflicts | M5 | `/LiveTv/Timers`, series timers |
| Timer notifications | M5 | `TimerCreated`/`SeriesTimerCreated` WebSocket messages |
| Timeshift (pause/rewind live) | M6 | Depends on tuner support |

## 12. Casting, remote control, SyncPlay

| Feature | Tag | Notes |
|---|---|---|
| Be controllable from other Jellyfin clients (receive Play, Playstate, GeneralCommand) | M2 | Register via `/Sessions/Capabilities/Full` |
| Chromecast (Google Cast) with the Jellyfin receiver | M2 | Not in the F-Droid flavor |
| AirPlay (video through AVPlayer, audio through route picker) | M2 | |
| Control other sessions ("play on living-room TV"), as a remote with seek/volume/tracks | M5 | `/Sessions`, `/Sessions/{id}/Playing`, `/Command` |
| Send a message to a session | M5 | |
| SyncPlay: create/join groups, synced play/pause/seek, group queue | M5 | 22 `/SyncPlay/*` routes + WebSocket; time sync via `/GetUtcTime` |
| DLNA rendering | M6 | |

## 13. Platform integration

| Feature | Tag | Notes |
|---|---|---|
| Media session / Now Playing on every platform | M2 (video), M3 (music) | |
| PiP on Android/iOS; always-on-top mini-player on desktop | M2 | |
| Desktop: system tray, global media keys, single-instance, window state memory | M2 | |
| Discord Rich Presence (desktop, opt-in) | M4 | |
| Deep links and "open in jellymc" | M2 | |
| Home-screen widgets (Continue Watching, Now Playing) | M6 | |
| iOS Handoff / Android "Continue on…" | M6 | |
| Foldables and tablets: list-detail layouts | M1 | Adaptive shell |
| Notifications: download complete, recording scheduled | M2 / M5 | |

## 14. Settings and personalization

| Feature | Tag | Notes |
|---|---|---|
| Theme (light/dark/AMOLED), accent, dynamic colour from artwork | M1 | |
| Default audio and subtitle language rules | M1 | |
| Playback: preferred engine, bitrate per network type, max resolution, passthrough, auto-skip rules, autoplay | M1 / M2 | |
| Roaming settings via server DisplayPreferences | M2 | |
| Per-library view preferences | M1 | |
| Data saver mode | M2 | |
| Import/export settings | M4 | |
| Diagnostics: logs viewer, "send logs to server" | M1 | `/ClientLog/Document` |

## 15. Integrations

| Feature | Tag | Notes |
|---|---|---|
| Intro Skipper and other media-segment plugins | M1 | Generic through media segments |
| Seerr (Jellyseerr/Overseerr successor): discover, request, request status | M5 | Direct Seerr API with the user's credentials |
| Trakt, Last.fm, ListenBrainz | — | Server plugins; nothing in the client |

## 16. Light admin (admins only, read-mostly)

| Feature | Tag | Notes |
|---|---|---|
| Active sessions dashboard: who's watching what, transcode reasons, stop or message a session | M5 | `/Sessions` |
| Activity log | M5 | `/System/ActivityLog/Entries` |
| Scheduled tasks: run library scan, see progress | M5 | `/ScheduledTasks`, `ScheduledTasksInfo` WebSocket messages |
| Refresh a library or item | M5 | `/Library/Refresh` |
| User list, enable/disable, reset password | M6 | `/Users` |
| Server logs viewer | M6 | `/System/Logs` |
| Plugins list and updates | M6 | `/Plugins`, `/Packages` |
| Everything else | — | Deep-link to jellyfin-web's dashboard |

## 17. Accessibility and localization

| Feature | Tag | Notes |
|---|---|---|
| Screen-reader labels, focus order, large text, reduced motion | M1 (baseline), M4 (audit) | |
| Full keyboard navigation | M1 | Focus-first design |
| RTL layouts | M4 | |
| Translations through Weblate | M4 | English at M1; the string pipeline is in place from M1 |

## 18. TV / 10-foot UI

| Feature | Tag | Notes |
|---|---|---|
| Android TV / Google TV / Fire TV build | M6 | Same app, TV layout, D-pad focus (already focus-first) |
| tvOS build | M6 | Flutter tvOS support is community-maintained, so treat it as a spike |
| Leanback-style home, remote-friendly player | M6 | |
