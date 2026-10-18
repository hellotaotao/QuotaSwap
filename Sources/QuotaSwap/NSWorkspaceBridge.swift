import AppKit

/// AppKit calls kept in one place so the engine files stay Foundation-only.
enum NSWorkspaceBridge {
    static func urlForApplication(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func terminate(bundleID: String) {
        // terminate() sends a regular quit event; it needs no Automation permission.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }
}
