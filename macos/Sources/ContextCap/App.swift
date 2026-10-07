import AppKit
import Darwin
@main struct ContextCapApp {
    @MainActor static func main() {
        umask(0o077)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
