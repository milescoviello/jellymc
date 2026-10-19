# Tech stack

## Decision

**Native Swift on both platforms, sharing one core. This is the same architecture as the Music app (`milescoviello/music`).**

| Layer | iPhone / iPad | Linux (KDE Plasma, Wayland) |
|---|---|---|
| UI | SwiftUI: the system's scrolling, swipe-back, tab bar and sheets | GTK 4 + libadwaita, through C interop and the small declarative wrapper the Music app's Linux build already has (`Linux/Sources/JellyCore/GTK`) |
| Core | `App/Core`: Jellyfin client, models, session, device profiles, playback negotiation and reporting, queues, outbox, caches. Foundation-only, except for a few named Apple-only files. | **The same files**: `Linux/Sources/JellyCore/Core` is a symlink to `App/Core`. Apple-only files are excluded, and each has a Linux file of the same name and shape under `Platform/`. |
| Video | **AVPlayer** (`AVPlayerViewController`): PiP, AirPlay, Dolby Vision/HDR, Now Playing, all from the system. The server remuxes to HLS (or transcodes) whatever AVPlayer can't open. | **libmpv** through its render API into a `GtkGLArea` (OpenGL via EGL), with VA-API decoding on the Arrow Lake iGPU. Every container, codec and subtitle format, including ASS with fonts. |
| Secrets | Keychain | libsecret (Secret Service) |
| Media controls | MPNowPlayingInfoCenter / MPRemoteCommandCenter | MPRIS on D-Bus (Plasma's media applet, media keys, KDE Connect) |
| Network status | `NWPathMonitor` | GIO `GNetworkMonitor` |
| Keep awake | idle timer | `org.freedesktop.ScreenSaver` inhibit |

There are no third-party Swift packages on iOS. On Linux, everything comes from system libraries through `systemLibrary` targets: gtk4, libadwaita-1, libsecret-1, mpv, egl.

## Why

- **It's the pattern you already ship.** The Music app is native SwiftUI with no Mac anywhere in the loop. GitHub Actions compiles it, `xtool` installs it, and its Linux build shares the same Core (238 tests passing on Linux). Following the same layout keeps jellymc familiar, and Linux pieces can be copied across: the GTK wrapper, the libsecret Keychain, MPRIS, the GIO network monitor.
- **Native iOS feel.** The system provides scrolling, swipe-back and the tab bar. `AVPlayerViewController` gives PiP (including auto-PiP when leaving the app), AirPlay, Dolby Vision on the OLED display, and the lock screen, with no plugin risk.
- **The core is tested locally.** Swift 6.3.1 (installed with swiftly) builds and tests the shared Core on Linux, so most bugs are caught before a CI run. CI only has to confirm that the iOS-specific Swift compiles.
- **mpv on the desktop** handles everything in the library at full fidelity. That makes Linux the "plays everything directly" client, while the iPhone leans on the server for the long tail.

## Tradeoffs we accept

- **Two UIs.** The UI is written twice (SwiftUI and GTK); the core once. The UI layer is thin: screens over shared view state from Core.
- **iOS direct-play breadth is AVPlayer's.** MKV, styled ASS and PGS on the iPhone go through a server remux (cheap) or a transcode or burn-in. That uses the server's RTX 4070 Ti for NVENC. An mpv engine for iOS (MPVKit) is a later, optional milestone.
- **The iOS UI is verified only on the device**, as with the Music app. Keep logic out of views so it lives in Core and gets tested on Linux.

## Rejected

| Option | Why not |
|---|---|
| Flutter (the previous plan) | One UI codebase, but a non-native iOS feel, plugin risk around media (media_kit, AVPlayer PiP plugins), and it ignores a native workflow you've already proven |
| React Native / Expo | No Linux |
| Tauri / Electron | WebView codec limits on iOS; a web UI where the Music app deliberately has none |
| Qt/QML + MpvQt on Linux | Excellent on Plasma, but in C++/QML it can't share the Swift core |

## Engines

| Engine | Where | Strengths | Weaknesses |
|---|---|---|---|
| **libmpv** (render API → `GtkGLArea`) | Linux | Widest format support; libass; PGS/VobSub; libplacebo tone-mapping; VA-API | HDR is tone-mapped in-window. Real HDR output needs mpv's own window (`vo=gpu-next`), which is a later item. |
| **AVPlayer** | iOS | PiP, AirPlay, DV/HDR10, Atmos (E-AC-3 JOC) to AirPods, Now Playing, best battery life | No MKV, no ASS/PGS rendering; needs server HLS for the rest |
| MPVKit (later, optional) | iOS | Direct play of anything | Swift glue plus a large binary; no PiP |

## Licensing

There are no constraints for a personal, sideloaded build. Code can be borrowed freely from your own Music app and from GPL projects.
