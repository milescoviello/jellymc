# jellymc

A personal Jellyfin client for **iPhone/iPad** and **Linux** (GTK 4 + libadwaita), laid out the way Plex is: films and shows only, sideloaded rather than published. Both apps share one Swift core (`App/Core`); the iPhone app is SwiftUI with AVPlayer, the Linux app is GTK with libmpv.

## What it does

- **Home:** Continue Watching (what was left part way, newest first, one card per show, then each show's next episode), then Recently Added for each library. Which libraries appear is the server's own Home setting, changed from Settings.
- **Libraries,** as Plex has them: **Recommended** (Continue Watching, Recently Released, Recently Added, the server's "Because You Watched…", "Top Movies by…", "Top Movies Starring…", Top Rated, "Top … in <genre>", Recently Viewed, Rediscover; for shows New Episodes and Start Watching), **Library** (a grid with Plex's sorts, filters for watched state, genre, decade, content rating and resolution, and an A–Z bar), **Collections**, and **Categories** (a tile per genre). Every row's See All opens the library sorted its way.
- **Cards** open their item's page; play is there or in the card's menu (right click on Linux, long press on iOS): Resume, Play from Beginning, Mark as Watched, Remove from Continue Watching, Add to Playlist, Go to Show or Season. They carry Plex's gold unwatched corner, a show's count of unwatched episodes, and the progress bar.
- **Pre-play pages:** poster and title (or logo), year, length, rating, when it would end, audience and critic scores, genres; Play/Resume, from the beginning, Shuffle, trailer, watched, favourite, download; video, audio and subtitle choices; summary, credits; a show's seasons, a season's episodes; Cast & Crew, Extras, More Like This, and what is in the file.
- **Playback:** direct play wherever the device can (mpv on Linux plays everything; the iPhone uses the server's remux or transcode for what AVPlayer cannot), resume and progress reporting, media segments (skip intro, recap, credits), up next with the next episode's still (and never an "Are you still watching?"), Shuffle and collection/playlist queues, chapters, trickplay previews on the seek bar (Linux), quality, speed, audio and subtitle delay (Linux), the sleep timer, subtitle size.
- **Offline:** downloads (the original file, or an AVPlayer-ready conversion on the iPhone), played with no server at all; where you stopped reaches the server when it is back.
- **A PIN** (Settings › PIN), asked for when the app opens and when you come back to it after a while away, never while a video plays. It only hides the app; a forgotten one gives way to your Jellyfin password. A lock button (on Home on the phone, in the sidebar or Ctrl+L on Linux) locks it at once.
- **Everywhere:** search with recent searches, playlists, remote control from other Jellyfin apps (play here, pause, seek, stop, messages), live updates when something changes on another device, settings that follow you between devices (subtitle and skip choices; quality stays per device), several server addresses tried in turn, Play On another device (send what is on screen to another Jellyfin app).
- **Linux extras:** MPRIS media controls and media keys, no screen saver during a video (GNOME and Plasma), keyboard shortcuts (Ctrl+F or / to search, Ctrl+R refresh, Ctrl+, settings; in the player space, ←/→, ↑/↓, m, f, s, v, i, n, `,` and `.`), your own `~/.config/jellymc/mpv.conf`.

## Install

**Linux** (Swift 6, GTK 4, libadwaita, libmpv, libepoxy, libsoup 3):

```sh
Linux/install.sh            # builds a release and installs jellymc for this user
jellymc-update              # later: pull, rebuild, reinstall, restart
Linux/install.sh --uninstall
```

It says which packages are missing on Fedora, Debian/Ubuntu, Arch and Gentoo. On this Gentoo machine pass the toolchain flags `tools/swiftw` uses: `SWIFT_BUILD_FLAGS="-Xlinker --allow-shlib-undefined" LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat Linux/install.sh`.

**iPhone / iPad:** every push to `MM` or `main` builds an IPA on GitHub Actions into the rolling `latest` release; install or refresh it (a free Apple ID's signature lasts 7 days) with

```sh
gh release download latest -p Jellymc.ipa -D dist --clobber
xtool install dist/Jellymc.ipa
```

Or let plugging the phone in do it: `tools/phone/install.sh` starts a watcher (and adds it to KDE autostart) that installs the newest build every time the iPhone is plugged in and again every 15 minutes while it stays plugged in (a fresh seven-day signature each time; iOS waits while the app is in use).

## Developing

See [docs/dev-workflow.md](docs/dev-workflow.md): `tools/swiftw build|test` on Linux, a throwaway Jellyfin test server with generated media (`tools/testserver`), and `tools/vm` for driving a test desktop VM. The scoping documents that started the project are in [docs/](docs/README.md).
