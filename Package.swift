// swift-tools-version: 6.0
import PackageDescription

// Two packages in one manifest, chosen by the machine building it — the Music app's
// arrangement.
//
// On macOS this is tests only. The iOS app is built by Jellymc.xcodeproj; this package
// exists so the pure logic can be tested with `swift test` on a plain macOS runner. It
// compiles the *same* files the app compiles, listed explicitly: every file here must be
// Foundation-only, and naming them keeps a future UIKit import from silently breaking the
// test job.
//
// On Linux it is the desktop app. `Linux/Sources/JellyCore/Core` is a symlink to
// `App/Core`, so the client, the models, the profiles and the playback logic are the
// iPhone's own code; the files that are Apple frameworks through and through are left out,
// and each has a Linux counterpart under `Linux/Sources/JellyCore/Platform` with the same
// name and shape. The UI is GTK 4 and libadwaita; video is libmpv.

#if os(Linux)

/// The Core files that are Apple frameworks through and through. Each is replaced, not
/// patched, by a file of the same name in `Platform/`.
let appleOnly = [
    "Keychain.swift",
    "Reachability.swift",
].map { "Core/\($0)" }

let package = Package(
    name: "Jellymc",
    targets: [
        .systemLibrary(name: "CGtk", path: "Linux/Modules/CGtk", pkgConfig: "gtk4 libadwaita-1"),
        .systemLibrary(name: "CSecret", path: "Linux/Modules/CSecret", pkgConfig: "libsecret-1"),
        .systemLibrary(name: "CMpv", path: "Linux/Modules/CMpv", pkgConfig: "mpv egl gtk4"),
        .target(
            name: "JellyCore",
            dependencies: ["CGtk", "CSecret", "CMpv"],
            path: "Linux/Sources/JellyCore",
            exclude: appleOnly
        ),
        .executableTarget(
            name: "jellymc",
            dependencies: ["JellyCore"],
            path: "Linux/Sources/jellymc"
        ),
        .testTarget(
            name: "JellyCoreTests",
            dependencies: ["JellyCore"],
            path: "Tests/JellyCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)

#else

let package = Package(
    name: "JellyCore",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "JellyCore",
            path: "App/Core",
            sources: [
                "Models.swift",
                "JSONCoding.swift",
                "JellyfinClient.swift",
                "DeviceProfiles.swift",
                "PlaybackPlan.swift",
                "PlaybackSession.swift",
                "Preferences.swift",
                "Paths.swift",
                "Diagnostics.swift",
                "ResponseCache.swift",
            ]
        ),
        .testTarget(
            name: "JellyCoreTests",
            dependencies: ["JellyCore"],
            path: "Tests/JellyCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)

#endif
