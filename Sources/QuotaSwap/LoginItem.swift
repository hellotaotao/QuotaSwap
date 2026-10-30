import ServiceManagement

/// Starting at login, through the system's own Login Items list, so users can
/// also see and turn it off in System Settings.
enum LoginItem {
    enum State {
        case on
        case off
        case needsApproval  // turned off for this app in System Settings
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else if state != .off {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static let approvalHint = "Allow QuotaSwap in System Settings > General > Login Items."
}
