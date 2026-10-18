import Foundation

struct CheckResult {
    let name: String
    let ok: Bool
    let detail: String
}

/// Verifies the undocumented Claude internals QuotaSwap depends on. Any
/// failure blocks every operation that writes, so an app update that changes
/// the layout can never be met with a half-applied switch.
enum SelfCheck {
    static func run() -> [CheckResult] {
        var results: [CheckResult] = []
        func add(_ name: String, _ ok: Bool, _ detail: String) { results.append(CheckResult(name: name, ok: ok, detail: detail)) }

        if Env.manageApp {
            if let version = ClaudeApp.version {
                add("Claude app", true, "version \(version)")
            } else {
                add("Claude app", false, "Claude.app not found")
            }
        }

        guard let cfg = FS.readObject(Env.config) else {
            add("config.json", false, "missing or not JSON")
            return results
        }
        add("config.json", true, "readable")

        let signedIn = ClaudeConfig.isSignedIn(cfg)
        let uuid = cfg["lastKnownAccountUuid"] as? String
        if !signedIn {
            add("account id", true, "not signed in")
        } else if let uuid {
            add("account id", isUUID(uuid), isUUID(uuid) ? "ok" : "lastKnownAccountUuid is not a uuid")
        } else {
            add("account id", false, "lastKnownAccountUuid missing")
        }

        let unknown = cfg.keys.filter { $0.hasPrefix("oauth:") && !ClaudeConfig.knownOAuthKeys.contains($0) }.sorted()
        add("token fields", unknown.isEmpty, unknown.isEmpty ? "known fields only" : "new fields: " + unknown.joined(separator: ", "))
        if let cache = cfg["oauth:tokenCacheV2"] {
            let ok = (cache as? String).flatMap { Data(base64Encoded: $0) }.map(SafeStorage.isV10) ?? false
            add("token encryption", ok, ok ? "v10" : "unexpected format")
        }

        results.append(checkCookies(signedIn: signedIn))
        results.append(contentsOf: checkSessions())
        return results
    }

    private static func checkCookies(signedIn: Bool) -> CheckResult {
        let name = "cookie database"
        guard FS.exists(Env.cookies) else {
            return CheckResult(name: name, ok: !signedIn, detail: signedIn ? "Cookies file missing" : "none (signed out)")
        }
        do {
            let columns = try CookieDB.columns(Env.cookies)
            let missing = ["host_key", "name", "encrypted_value"].filter { !columns.contains($0) }
            guard missing.isEmpty else { return CheckResult(name: name, ok: false, detail: "missing columns: " + missing.joined(separator: ", ")) }
            guard signedIn else { return CheckResult(name: name, ok: true, detail: "schema ok") }
            let rows = try CookieDB.claudeRows(Env.cookies)
            let absent = ["sessionKey", "lastActiveOrg"].filter { n in !rows.contains { $0.name == n } }
            guard absent.isEmpty else { return CheckResult(name: name, ok: false, detail: "missing cookies: " + absent.joined(separator: ", ")) }
            let encrypted = rows.filter { $0.name == "sessionKey" }.allSatisfy { SafeStorage.isV10($0.value) }
            return CheckResult(name: name, ok: encrypted, detail: encrypted ? "session cookie present" : "session cookie not v10")
        } catch {
            return CheckResult(name: name, ok: false, detail: error.localizedDescription)
        }
    }

    private static func checkSessions() -> [CheckResult] {
        let stores = SessionSync.stores()
        guard !stores.isEmpty else { return [CheckResult(name: "session index", ok: true, detail: "no Code sessions yet")] }
        var total = 0, malformed = 0, withTranscriptID = 0, badIndex = 0
        var recent: [(Double, String)] = []
        for store in stores {
            for path in SessionSync.localFiles(store) {
                total += 1
                guard let obj = FS.readObject(path), obj["sessionId"] is String,
                      number(obj["lastActivityAt"]) != nil, obj["isArchived"] is Bool else {
                    malformed += 1
                    continue
                }
                if let cli = obj["cliSessionId"] as? String {
                    withTranscriptID += 1
                    recent.append((number(obj["lastActivityAt"]) ?? 0, cli))
                }
            }
            let indexPath = store + "/archived-sessions.idx"
            if FS.exists(indexPath) {
                let index = FS.readObject(indexPath)
                if number(index?["v"]) != 1 || !(index?["archived"] is [Any]) { badIndex += 1 }
            }
        }
        var problems: [String] = []
        if malformed > 0 { problems.append("\(malformed) of \(total) entries lack sessionId/lastActivityAt/isArchived") }
        if withTranscriptID * 10 < total * 8 { problems.append("only \(withTranscriptID) of \(total) entries have cliSessionId") }
        if badIndex > 0 { problems.append("archived-sessions.idx format changed") }
        var results = [CheckResult(name: "session index", ok: problems.isEmpty,
                                   detail: problems.isEmpty ? "\(total) sessions in \(stores.count) lists" : problems.joined(separator: "; "))]

        // Recent transcripts should exist; old ones may have been cleaned up by Claude Code.
        let sample = recent.sorted { $0.0 > $1.0 }.prefix(10).map(\.1)
        if !sample.isEmpty {
            let projects = FS.list(Env.projectsDir).map { Env.projectsDir + "/" + $0 }
            let found = sample.filter { id in projects.contains { FS.exists($0 + "/" + id + ".jsonl") } }.count
            results.append(CheckResult(name: "transcripts", ok: found > 0,
                                       detail: found > 0 ? "\(found) of \(sample.count) recent found" : "none of the recent transcripts found in \(Env.projectsDir)"))
        }
        return results
    }

    static func requirePassing() throws {
        let failed = run().filter { !$0.ok }
        guard failed.isEmpty else {
            throw QSError("Self-check failed, nothing changed: " + failed.map { "\($0.name): \($0.detail)" }.joined(separator: "; "))
        }
    }

    // MARK: verified version, so the UI can say when Claude changed

    private static var statePath: String { Env.stateDir + "/state.json" }

    static var lastVerifiedVersion: String? { FS.readObject(statePath)?["verifiedClaudeVersion"] as? String }

    static func recordVerified(version: String?) {
        guard let version, version != lastVerifiedVersion else { return }
        try? FS.makeDir(Env.stateDir)
        try? FS.writeObject(["verifiedClaudeVersion": version, "verifiedAt": localTimestamp()], to: statePath)
    }
}
