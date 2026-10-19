import CGtk
import Foundation

/// The entry point: a libadwaita application whose main loop also drains Swift's main
/// actor, so every `Task { @MainActor in }` and `await` runs on GTK's thread.
public enum JellymcApplication {
    @MainActor
    public static func run() {
        // The video is drawn with OpenGL; GTK's GL renderer puts it on screen as it is,
        // where the Vulkan one copies every frame across. Unless asked for another.
        setenv("GSK_RENDERER", "gl", 0)
        MainLoop.install()
        let application = adw_application_new(Desktop.applicationID, GApplicationFlags(rawValue: 0))!
        Desktop.application = OpaquePointer(application)
        Signal.connect(application, "activate") {
            if let window = Desktop.window {
                gtk_window_present(window.cast())
                return
            }
            let window = MainWindow(application: OpaquePointer(application))
            Desktop.window = window.window
            Desktop.main = window
        }
        let status = g_application_run(application.cast(), CommandLine.argc, CommandLine.unsafeArgv)
        exit(status)
    }
}

extension Desktop {
    @MainActor static var main: MainWindow?
}
