import CGtk
import Foundation

/// The entry point: a GTK application whose main loop also drains Swift's main actor.
public enum JellymcApplication {
    @MainActor
    public static func run() {
        MainLoop.install()
        MainLoop.run()
    }
}
