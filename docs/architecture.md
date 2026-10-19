# Architecture

It's the Music app's layout, applied to Jellyfin: one shared Swift core, a SwiftUI app on iOS, and a GTK 4 app on Linux.

## Repository layout

```
App/                          the iOS app (file-system synchronized group in Jellymc.xcodeproj)
  JellymcApp.swift
  Core/                       shared with Linux: client, models, session, profiles, playback, stores
  Features/<Screen>/          SwiftUI screens
  Assets.xcassets/
Jellymc.xcodeproj/
Jellymc-Info.plist
Linux/
  Modules/                    C modules: CGtk (gtk4 + libadwaita), CMpv (libmpv + EGL), CSecret (libsecret)
  Sources/JellyCore/Core      → symlink to App/Core
  Sources/JellyCore/Platform  Linux counterparts of Apple-only Core files (same name, same shape)
  Sources/JellyCore/GTK       the declarative GTK wrapper (from the Music app)
  Sources/JellyCore/UI        GTK screens
  Sources/jellymc/main.swift
Package.swift                 Linux: the desktop app + tests. macOS: Foundation-only Core tests.
Tests/JellyCoreTests/
tools/testserver/             local Jellyfin 12.2 + generated media
.github/workflows/ios.yml     test + ad-hoc IPA + rolling `latest` release
docs/
```

## Core

Everything here is Foundation plus Observation. That's what makes it shareable, and testable on Linux.

| File | What it does |
|---|---|
| `JellyfinClient.swift` | `URLSession` async/await (FoundationNetworking on Linux). Sends the `Authorization: MediaBrowser …` header, typed endpoints, and builds stream and image URLs with `ApiKey=`. It never uses `X-Emby-Token`, `api_key` or `/emby` routes, which 12.0 rejects. |
| `Models.swift` | Hand-written `Codable` DTOs for only the fields we use: `BaseItem`, `MediaSource`, `MediaStream`, `UserData`, `PlaybackInfoResponse`, `MediaSegment`, `TrickplayInfo`, … |
| `Ticks.swift` | Conversion between ticks (100 ns) and seconds/`Duration`, and runtime formatting |
| `DeviceProfiles.swift` | `DeviceProfile` for AVPlayer (iOS) and for mpv (Linux): direct-play, transcoding, codec and subtitle profiles |
| `PlaybackSession.swift` | `PlaybackInfo` negotiation, choosing direct play vs stream vs transcode, the URL, reporting (start/progress/stopped/ping), track switching, segments, up next |
| `Session.swift` | The signed-in server and user: multiple addresses with fall-through, token in the Keychain/libsecret, device id |
| `Library.swift` | Observable view state for home, libraries, items, search, details. Each screen reads one of these. |
| `ImageURLs.swift` | `/Items/{id}/Images/{type}?tag=&maxWidth=&quality=` |
| `Outbox.swift` | Mutations queued while offline (played, favourite, progress), replayed in order |
| `Cache.swift` | A JSON disk cache: stale-while-revalidate for home rows and library pages |
| `Diagnostics.swift` | A ring-buffer log that scrubs tokens; "send logs to server" |
| `Keychain.swift`, `Reachability.swift`, `NowPlayingCenter.swift`, `ScreenAwake.swift` | **Apple-only.** Replaced on Linux by libsecret, GIO `GNetworkMonitor`, MPRIS, and the ScreenSaver inhibit. |

Rules:

- **Views hold no logic.** Anything worth testing lives in Core and is covered by `swift test` on Linux, before CI ever runs.
- **Platform differences are separate files, not `#if` thickets.** An Apple-only file gets a Linux twin of the same name and shape. Small differences use guarded branches (`#if canImport(FoundationNetworking)`).
- **Swift 6 language mode.** UI-facing state is `@MainActor @Observable`. Network and decode work runs off the main actor.

## Server session

- One server and one user in the UI. The model is keyed by server `Id` and user id, so more can be added later without a migration.
- **Several addresses per server** (LAN, remote domain, Tailscale). On each network change, try them in order with a short timeout and keep the first that answers.
- Login with username/password (`/Users/AuthenticateByName`). The token is stored in the Keychain or libsecret. The DeviceId is a random id generated once per install.

## Data

- **Cache:** JSON files per query key (`home`, `library/{id}/{sort}/{page}`, `item/{id}`) under Application Support or `$XDG_DATA_HOME/jellymc`. Screens render from the cache instantly, then refresh.
- **Roaming settings** use `/DisplayPreferences/jellymc?client=jellymc` with `CustomPrefs`: subtitle language rules, skip rules and so on.
- **Outbox:** offline mutations are replayed in order on reconnect. Offline progress goes to `POST /UserItems/{id}/UserData`.

## Playback

See [playback.md](playback.md).

- **iOS:** `AVPlayerViewController`, with our overlay for skip-segment and up-next buttons. PiP (`canStartPictureInPictureAutomaticallyFromInline`), AirPlay and Now Playing come from AVKit.
- **Linux:** `MpvPlayer` drives libmpv through `mpv_render_context` (OpenGL) inside a `GtkGLArea`. mpv's update callback is posted to the GTK main loop and queues a render. Controls are GTK widgets in an overlay; keyboard shortcuts are mpv-like.

## Platform services

| Service | iOS / iPadOS | Linux (KDE Plasma, Wayland) |
|---|---|---|
| Media controls | MPNowPlayingInfoCenter + MPRemoteCommandCenter | MPRIS (Plasma applet, media keys, KDE Connect) |
| PiP | AVPlayerViewController (auto-PiP on leaving the app) | — (a later mini window) |
| AirPlay | AVRoutePickerView / AVPlayerViewController | — |
| Background | `audio` background mode | always running |
| Keep awake | `isIdleTimerDisabled` during video | `org.freedesktop.ScreenSaver` inhibit |
| Secrets | Keychain | libsecret (gnome-keyring on this machine) |
| Network | `NWPathMonitor` | `GNetworkMonitor` |

## UI

- **iOS:** a `TabView` with Home, Library, Search and Settings, plus a `NavigationStack` per tab.
  - Detail pages for movies, series, seasons and episodes.
  - iPad gets wider grids and a `NavigationSplitView` for libraries.
  - The player is presented full screen.
- **Linux:** an `AdwApplicationWindow` with an `AdwNavigationSplitView`.
  - The sidebar holds Home, libraries, Search and Settings; the content is an `AdwNavigationView` of pages.
  - The player is a full-window overlay page with an mpv `GtkGLArea`.
- Both UIs read the same Core view state, so screens behave the same and differ only in presentation.

## Performance budgets

- Cold start to a cached home screen: < 1 s on Linux, < 1.5 s on the iPhone.
- Grids at 60 fps (120 Hz ProMotion where possible), with images requested at cell size.
- Time to first frame for a direct-play file on LAN: < 1.5 s.
