# Dev workflow

It's the same loop as the Music app. **Linux is where code is written, built and tested. GitHub Actions is the iOS compiler. `xtool` signs and installs the app on the iPhone and iPad.**

## Linux

The toolchain is already on this machine:

- Swift 6.3.1 (swiftly)
- gtk4 4.20 and libadwaita 1.8
- libsecret
- mpv 0.41 with `libmpv` (the global USE flags already include `libmpv vaapi wayland pipewire`)
- EGL/epoxy
- FFmpeg 8.1

```sh
swift build                 # Core + GTK app
swift run jellymc           # the desktop app
swift test                  # Core tests (the same tests CI runs on macOS)
```

`Package.swift` is two packages in one manifest, chosen by the machine building it, exactly as in the Music app:

- **On Linux** it builds the desktop app. `Linux/Sources/JellyCore/Core` is a symlink to `App/Core`. Apple-only Core files are excluded by name, and each has a counterpart in `Linux/Sources/JellyCore/Platform`.
- **On macOS** it's tests only. It compiles the Foundation-only Core files, listed explicitly, so a stray `import UIKit` can't silently break the test job.

## iPhone / iPad

1. **Push.** `.github/workflows/ios.yml` runs on a `macos-26` runner:
   - `swift test` on the pure logic.
   - `xcodebuild archive` with ad-hoc signing. It's ad-hoc rather than unsigned because a binary with no `LC_CODE_SIGNATURE` can't be reliably re-signed, and iOS then refuses to launch it.
   - Packages `Jellymc.ipa`.
   - Uploads it as an artifact and to the rolling **`latest`** prerelease.
2. **Install or refresh** (a free certificate lasts 7 days):

   ```sh
   gh release download latest -p Jellymc.ipa -D dist --clobber
   xtool install dist/Jellymc.ipa
   ```

   Never put a timeout on `xtool install`: an interrupted install collides with the next one. If it stalls at *Verifying*, the app is playing something, and iOS won't replace an app that holds an active audio session.

`Jellymc.xcodeproj` uses a file-system synchronized group, so new Swift files under `App/` are picked up without editing the project file.

**The repo is private**, so macOS minutes count against the Free plan's allowance, reportedly at 10×. Push in batches rather than per commit, and use `workflow_dispatch` when a build is wanted without a push.

## Debugging the phone from Linux

- `idevicesyslog -m Jellymc` streams the app's logs over USB.
- `idevicecrashreport -e ./crashes` pulls crash reports.
- The in-app Diagnostics screen shows the play method, transcode reasons and recent errors, and can send logs to the server (`/ClientLog/Document`).

## Test server

The real server (`.148`) has Jellyfin stopped on purpose. Development uses a throwaway local server instead:

```sh
tools/testserver/make-media.sh   # FFmpeg-generated movies and a series (with ASS, SRT, chapters)
tools/testserver/up.sh           # Jellyfin 12.2 in Docker on :8096, first-run wizard scripted, libraries added
```

Credentials are `jellymc` / `jellymc`. Data lives in `~/.local/share/jellymc-testserver`.
