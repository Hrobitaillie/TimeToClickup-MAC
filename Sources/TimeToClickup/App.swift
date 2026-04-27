import AppKit

@main
@MainActor
struct TimeToClickupApp {
    static let bundleId = "com.local.timetoclickup"

    static func main() {
        ensureSingleInstance()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Replace any older instances. We terminate them and wait until
    /// they're really gone so we never end up with two status items
    /// and two overlays stacked under the notch.
    private static func ensureSingleInstance() {
        let mine = ProcessInfo.processInfo.processIdentifier

        func othersAlive() -> [NSRunningApplication] {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId)
                .filter { $0.processIdentifier != mine && !$0.isTerminated }
        }

        var others = othersAlive()
        guard !others.isEmpty else { return }

        for app in others { app.terminate() }

        // Up to ~2 seconds for graceful shutdown, then force-kill stragglers.
        for _ in 0..<40 {
            others = othersAlive()
            if others.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        for app in othersAlive() { app.forceTerminate() }
    }
}
