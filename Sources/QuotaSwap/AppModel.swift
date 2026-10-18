import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    struct Row: Identifiable {
        let profile: Profile
        var usage: Usage?
        var error: String?
        var loading = false
        var id: String { profile.name }
    }

    enum Action: Equatable {
        case switchTo(String)
        case save
        case add
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var currentUUID: String?
    @Published private(set) var unsavedAccount: String?  // signed in but no snapshot yet
    @Published private(set) var failedChecks: [CheckResult] = []
    @Published private(set) var claudeVersion: String?
    @Published private(set) var claudeUpdated = false
    @Published private(set) var busy: String?
    @Published var message: String?
    @Published var pending: Action?

    private var lastUsageFetch = Date.distantPast
    private var timer: Timer?

    init() {
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
    }

    var blocked: Bool { !failedChecks.isEmpty }
    var currentRow: Row? { rows.first { $0.profile.uuid == currentUUID } }

    /// Reloads local state; refetches usage when forced or older than a minute.
    func refresh(force: Bool = false) {
        guard busy == nil else { return }
        reloadLocal()
        if force || Date().timeIntervalSince(lastUsageFetch) > 60 { refreshUsage() }
    }

    private func reloadLocal() {
        let cfg = try? ClaudeConfig.read()
        currentUUID = cfg?["lastKnownAccountUuid"] as? String
        let signedIn = cfg.map(ClaudeConfig.isSignedIn) ?? false
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = Profiles.all().map { p in
            var row = Row(profile: p)
            row.usage = previous[p.name]?.usage
            row.error = previous[p.name]?.error
            return row
        }
        unsavedAccount = signedIn && Profiles.forUUID(currentUUID) == nil
            ? (EmailDetector.email(for: currentUUID) ?? currentUUID ?? "unknown account") : nil

        claudeVersion = ClaudeApp.version
        let lastVerified = SelfCheck.lastVerifiedVersion
        failedChecks = SelfCheck.run().filter { !$0.ok }
        if failedChecks.isEmpty {
            claudeUpdated = lastVerified != nil && lastVerified != claudeVersion
            SelfCheck.recordVerified(version: claudeVersion)
        }
    }

    private func refreshUsage() {
        lastUsageFetch = Date()
        let current = currentUUID
        let profiles = rows.map(\.profile)
        for i in rows.indices { rows[i].loading = true }
        Task.detached { [weak self] in
            await withTaskGroup(of: (String, Usage?, String?).self) { group in
                for p in profiles {
                    group.addTask {
                        do { return (p.name, try await UsageClient.fetch(for: p, current: p.uuid == current), nil) }
                        catch { return (p.name, nil, error.localizedDescription) }
                    }
                }
                for await (name, usage, error) in group {
                    await self?.applyUsage(name: name, usage: usage, error: error)
                }
            }
        }
    }

    private func applyUsage(name: String, usage: Usage?, error: String?) {
        guard let i = rows.firstIndex(where: { $0.id == name }) else { return }
        rows[i].loading = false
        rows[i].error = error
        if let usage { rows[i].usage = usage }  // keep the last good numbers on failure
    }

    // MARK: actions

    func perform(_ action: Action) {
        pending = nil
        message = nil
        switch action {
        case .switchTo(let name): busy = "Switching to \(rows.first { $0.id == name }?.profile.email ?? name) ..."
        case .save: busy = "Saving the signed-in account ..."
        case .add: busy = "Signing Claude out locally ..."
        }
        Task.detached { [weak self] in
            let lines = LineBuffer()
            var failure: String?
            do {
                switch action {
                case .switchTo(let name):
                    guard let profile = Profiles.load(name) else { throw QSError("Account '\(name)' no longer exists.") }
                    try Accounts.use(profile, log: lines.append)
                case .save:
                    try Accounts.save(name: nil, log: lines.append)
                case .add:
                    try Accounts.add(log: lines.append)
                }
            } catch {
                failure = error.localizedDescription
            }
            let summary = failure ?? Self.summary(for: action, log: lines.all)
            await self?.finish(message: summary)
        }
    }

    nonisolated private static func summary(for action: Action, log: [String]) -> String {
        switch action {
        case .add: return "Sign in to the new account in Claude, then come back here to save it."
        default: return log.last { $0.hasPrefix("switched") || $0.hasPrefix("saved") || $0.contains("already signed in") } ?? "Done."
        }
    }

    private func finish(message: String) {
        busy = nil
        self.message = message
        refresh(force: true)
    }
}

/// Collects log lines from a background operation.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
