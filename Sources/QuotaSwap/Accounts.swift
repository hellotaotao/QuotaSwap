import Foundation

/// The parts of Claude's config.json that belong to the signed-in account.
enum ClaudeConfig {
    static let accountKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid", "bootSidebarPlaceholder"]
    static let knownOAuthKeys: Set<String> = ["oauth:tokenCache", "oauth:tokenCacheV2"]
    /// Files under the Claude directory swapped wholesale per account.
    static let statePaths = ["Cookies", "Cookies-journal"]

    static func read() throws -> [String: Any] {
        guard let cfg = FS.readObject(Env.config) else { throw QSError("Cannot read \(Env.config)") }
        return cfg
    }

    static func write(_ cfg: [String: Any]) throws {
        let mode = ((try? FS.fm.attributesOfItem(atPath: Env.config))?[.posixPermissions] as? Int) ?? 0o600
        try FS.writeObject(cfg, to: Env.config, pretty: true, mode: mode)
    }

    static func isSignedIn(_ cfg: [String: Any]) -> Bool {
        accountKeys.prefix(2).contains { !((cfg[$0] as? String) ?? "").isEmpty }
    }

    static func currentUUID() -> String? {
        FS.readObject(Env.config)?["lastKnownAccountUuid"] as? String
    }
}

struct Profile: Identifiable {
    let name: String
    let meta: [String: Any]

    var id: String { name }
    var uuid: String? { meta["accountUuid"] as? String }
    var email: String? { meta["email"] as? String }
    var savedAt: String? { meta["savedAt"] as? String }
    var dir: String { Profiles.dir(name) }
    var label: String { "'\(name)' (\(email ?? uuid ?? "unknown"))" }
}

enum Profiles {
    static var root: String { Env.store + "/profiles" }
    static func dir(_ name: String) -> String { root + "/" + name }

    static func load(_ name: String) -> Profile? {
        FS.readObject(dir(name) + "/meta.json").map { Profile(name: name, meta: $0) }
    }

    static func all() -> [Profile] {
        FS.list(root).filter { !$0.hasSuffix(".tmp") && !$0.hasPrefix(".") }.compactMap(load)
    }

    static func forUUID(_ uuid: String?) -> Profile? {
        guard let uuid else { return nil }
        return all().first { $0.uuid == uuid }
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// Exact short name or email first, then a unique case-insensitive prefix of either.
    static func resolve(_ query: String) throws -> Profile {
        let rows = all()
        let q = query.lowercased()
        if let exact = rows.first(where: { $0.name.lowercased() == q || ($0.email ?? "").lowercased() == q }) {
            return exact
        }
        let hits = rows.filter { $0.name.lowercased().hasPrefix(q) || ($0.email ?? "").lowercased().hasPrefix(q) }
        if hits.count == 1 { return hits[0] }
        if hits.isEmpty {
            let saved = rows.map(\.label).joined(separator: ", ")
            throw QSError("No saved account matches '\(query)'. Saved: \(saved.isEmpty ? "none" : saved)")
        }
        throw QSError("'\(query)' matches several accounts: \(hits.map(\.name).joined(separator: ", "))")
    }
}

/// Finds an account's email in configs Claude Code already caches locally.
enum EmailDetector {
    static func email(for uuid: String?) -> String? {
        guard let uuid else { return nil }
        if let email = oauthEmail(Env.cliConfig, uuid) { return email }
        // Cowork sessions keep their own .claude.json under
        // local-agent-mode-sessions/<account>/<org>/[agent/]<session>/.claude/.
        let base = Env.claudeDir + "/local-agent-mode-sessions/" + uuid
        for org in FS.list(base) {
            for parent in [base + "/" + org, base + "/" + org + "/agent"] {
                for session in FS.list(parent) {
                    if let email = oauthEmail(parent + "/" + session + "/.claude/.claude.json", uuid) { return email }
                }
            }
        }
        return nil
    }

    private static func oauthEmail(_ path: String, _ uuid: String) -> String? {
        guard let account = FS.readObject(path)?["oauthAccount"] as? [String: Any],
              account["accountUuid"] as? String == uuid else { return nil }
        return account["emailAddress"] as? String
    }
}

/// Saving, restoring and switching account snapshots.
enum Accounts {
    // MARK: snapshots

    static func snapshot(_ name: String, log: Log) throws {
        let cfg = try ClaudeConfig.read()
        let uuid = cfg["lastKnownAccountUuid"] as? String
        guard ClaudeConfig.isSignedIn(cfg) else { throw QSError("Claude is not signed in; nothing to save.") }
        let previous = Profiles.forUUID(uuid)
        if let previous, previous.name != name {
            log("note: this account was saved as '\(previous.name)'; renaming it to '\(name)'")
        }
        let email = EmailDetector.email(for: uuid) ?? previous?.email

        try FS.makeDir(Profiles.root)
        let dir = Profiles.dir(name)
        let tmp = dir + ".tmp"
        try FS.remove(tmp)
        try FS.makeDir(tmp)
        var keys: [String: Any] = [:]
        for key in ClaudeConfig.accountKeys { keys[key] = cfg[key] }
        try FS.writeObject(keys, to: tmp + "/config-keys.json")
        for rel in ClaudeConfig.statePaths where FS.exists(Env.claudeDir + "/" + rel) {
            try FS.copyReplacing(Env.claudeDir + "/" + rel, tmp + "/" + rel)
            try FS.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp + "/" + rel)
        }
        let meta: [String: Any] = ["accountUuid": uuid ?? NSNull(), "email": email ?? NSNull(),
                                   "savedAt": localTimestamp()]
        try FS.writeObject(meta, to: tmp + "/meta.json")
        if let previous, previous.name != name { try FS.remove(previous.dir) }
        try FS.remove(dir)
        try FS.fm.moveItem(atPath: tmp, toPath: dir)
        log("saved \(Profile(name: name, meta: meta).label)")
    }

    static func restore(_ profile: Profile) throws {
        guard let keys = FS.readObject(profile.dir + "/config-keys.json") else {
            throw QSError("Snapshot of \(profile.label) is incomplete.")
        }
        var cfg = try ClaudeConfig.read()
        for key in ClaudeConfig.accountKeys {
            cfg[key] = keys[key]
        }
        for rel in ClaudeConfig.statePaths {
            let src = profile.dir + "/" + rel, dst = Env.claudeDir + "/" + rel
            if FS.exists(src) { try FS.copyReplacing(src, dst) } else { try FS.remove(dst) }
        }
        try ClaudeConfig.write(cfg)
    }

    static func clearLogin() throws {
        var cfg = try ClaudeConfig.read()
        for key in ClaudeConfig.accountKeys where key != "lastKnownAccountUuid" {
            cfg.removeValue(forKey: key)
        }
        for rel in ClaudeConfig.statePaths { try FS.remove(Env.claudeDir + "/" + rel) }
        try ClaudeConfig.write(cfg)
    }

    static func backupCurrent() throws {
        let backups = Env.store + "/backups"
        let dest = backups + "/" + localTimestamp(format: "yyyyMMdd-HHmmss-SSS")
        try FS.makeDir(dest)
        try FS.fm.copyItem(atPath: Env.config, toPath: dest + "/config.json")
        for rel in ClaudeConfig.statePaths where FS.exists(Env.claudeDir + "/" + rel) {
            try FS.fm.copyItem(atPath: Env.claudeDir + "/" + rel, toPath: dest + "/" + rel)
        }
        for old in FS.list(backups).dropLast(20) { try? FS.remove(backups + "/" + old) }
    }

    @discardableResult
    static func saveCurrentIfKnown(log: Log) throws -> Profile? {
        guard let profile = Profiles.forUUID(ClaudeConfig.currentUUID()) else { return nil }
        try snapshot(profile.name, log: log)
        return profile
    }

    static func requireCurrentSaved() throws {
        let cfg = try ClaudeConfig.read()
        let uuid = cfg["lastKnownAccountUuid"] as? String
        if ClaudeConfig.isSignedIn(cfg), Profiles.forUUID(uuid) == nil {
            throw QSError("The signed-in account (\(EmailDetector.email(for: uuid) ?? uuid ?? "unknown")) is not saved yet; save it first.")
        }
    }

    /// The existing short name of the signed-in account, else its email's local part.
    static func defaultName() throws -> String {
        let uuid = ClaudeConfig.currentUUID()
        if let existing = Profiles.forUUID(uuid) { return existing.name }
        guard let email = EmailDetector.email(for: uuid) else {
            throw QSError("Could not find this account's email; give it a name.")
        }
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return local.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    }

    // MARK: user-facing operations (each runs the self-check first)

    static func save(name: String?, log: Log) throws {
        try SelfCheck.requirePassing()
        let name = try name ?? defaultName()
        guard Profiles.isValidName(name) else { throw QSError("Account names may use letters, digits, - and _ only.") }
        let wasRunning = try ClaudeApp.quit(log: log)
        defer { if wasRunning { ClaudeApp.open(log: log) } }
        try snapshot(name, log: log)
    }

    static func use(_ target: Profile, log: Log) throws {
        try SelfCheck.requirePassing()
        try requireCurrentSaved()
        _ = try ClaudeApp.quit(log: log)
        defer { ClaudeApp.open(log: log) }
        let current = try saveCurrentIfKnown(log: log)
        if current?.name == target.name {
            log("\(target.label) is already signed in")
            return
        }
        try backupCurrent()
        syncSessions(log: log)
        try restore(target)
        log("switched to \(target.label)")
    }

    static func add(log: Log) throws {
        try SelfCheck.requirePassing()
        try requireCurrentSaved()
        _ = try ClaudeApp.quit(log: log)
        defer { ClaudeApp.open(log: log) }
        try saveCurrentIfKnown(log: log)
        try backupCurrent()
        syncSessions(log: log)
        try clearLogin()
        log("signed out locally; sign in to the other account in Claude, then save it")
    }

    static func rename(_ profile: Profile, to name: String) throws -> Profile {
        guard Profiles.isValidName(name) else { throw QSError("Account names may use letters, digits, - and _ only.") }
        guard !FS.exists(Profiles.dir(name)) else { throw QSError("'\(name)' already exists.") }
        try FS.fm.moveItem(atPath: profile.dir, toPath: Profiles.dir(name))
        return Profiles.load(name) ?? profile
    }

    /// Claude is already closed here, so a full two-way merge is safe.
    private static func syncSessions(log: Log) {
        do {
            try SessionSync.run(dryRun: false, log: log)
        } catch {
            log("warning: Code session sync skipped: \(error.localizedDescription)")
        }
    }
}
