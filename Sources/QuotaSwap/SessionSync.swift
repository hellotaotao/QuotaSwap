import Foundation

/// Merges the desktop app's per-account Code session lists, so every account
/// shows every session. Transcripts live in ~/.claude/projects and are shared
/// already; only the small index files under claude-code-sessions differ.
/// Must run while Claude is closed.
enum SessionSync {
    struct Op {
        enum Kind: String { case tomb, delete, add, update }
        let kind: Kind
        let src: String?
        let dst: String
    }

    /// <account>/<org> dirs that already hold sessions. Empty org dirs are
    /// skipped so sessions don't leak into an org the account never used.
    static func stores(root: String = Env.sessionsRoot) -> [String] {
        FS.list(root).flatMap { account in FS.list(root + "/" + account).map { root + "/" + account + "/" + $0 } }
            .filter { FS.isDir($0) && !localFiles($0).isEmpty }
    }

    static func localFiles(_ store: String) -> [String] {
        FS.list(store).filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.map { store + "/" + $0 }
    }

    static func activity(_ path: String) -> (Double, Double) {
        guard let obj = FS.readObject(path) else { return (-1, -1) }
        let last = number(obj["lastActivityAt"]).flatMap { $0 > 0 ? $0 : nil } ?? number(obj["createdAt"]) ?? 0
        return (last, FS.mtime(path))
    }

    static func plan(_ stores: [String]) -> [Op] {
        var tombs: [String: String] = [:]  // session uuid -> a tombstone file
        for store in stores {
            for name in FS.list(store) where name.hasPrefix("deleted_") {
                let uuid = String(name.dropFirst("deleted_".count))
                if tombs[uuid] == nil { tombs[uuid] = store + "/" + name }
            }
        }

        var best: [String: String] = [:]  // file name -> newest copy
        for store in stores {
            for path in localFiles(store) {
                let name = (path as NSString).lastPathComponent
                let uuid = String(name.dropFirst("local_".count).dropLast(".json".count))
                if tombs[uuid] != nil { continue }
                if let current = best[name], activity(path) <= activity(current) { continue }
                best[name] = path
            }
        }

        var ops: [Op] = []
        for store in stores {
            for (uuid, src) in tombs.sorted(by: { $0.key < $1.key }) {
                let tomb = store + "/deleted_" + uuid
                if !FS.exists(tomb) { ops.append(Op(kind: .tomb, src: src, dst: tomb)) }
                let victim = store + "/local_" + uuid + ".json"
                if FS.exists(victim) { ops.append(Op(kind: .delete, src: nil, dst: victim)) }
            }
            for (name, src) in best.sorted(by: { $0.key < $1.key }) {
                let dst = store + "/" + name
                if src == dst { continue }
                if !FS.exists(dst) {
                    ops.append(Op(kind: .add, src: src, dst: dst))
                } else if activity(src) > activity(dst) {
                    ops.append(Op(kind: .update, src: src, dst: dst))
                }
            }
        }
        return ops
    }

    static func rebuildArchiveIndex(_ store: String) throws {
        let archived = localFiles(store).compactMap { path -> String? in
            guard let obj = FS.readObject(path), obj["isArchived"] as? Bool == true else { return nil }
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        try FS.writeObject(["v": 1, "archived": archived], to: store + "/archived-sessions.idx")
    }

    static func backup(root: String) throws -> String {
        let backups = (root as NSString).deletingLastPathComponent + "/claude-code-sessions-backups"
        try FS.makeDir(backups)
        let dest = backups + "/sessions-" + localTimestamp(format: "yyyyMMdd-HHmmss") + ".tgz"
        let parent = (root as NSString).deletingLastPathComponent
        let status = runProcess("/usr/bin/tar", ["-czf", dest, "-C", parent, (root as NSString).lastPathComponent])
        guard status == 0 else { throw QSError("Backup of the session index failed.") }
        for old in FS.list(backups).filter({ $0.hasPrefix("sessions-") }).dropLast(20) {
            try? FS.remove(backups + "/" + old)
        }
        return dest
    }

    static func run(root: String = Env.sessionsRoot, dryRun: Bool, log: Log) throws {
        let stores = stores(root: root)
        guard stores.count >= 2 else {
            throw QSError("found \(stores.count) account session list(s); need at least 2")
        }
        let ops = plan(stores)
        let counts = Dictionary(grouping: ops, by: \.kind.rawValue).mapValues(\.count)
        let summary = counts.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        log("sessions: \(stores.map { String(localFiles($0).count) }.joined(separator: " / ")); planned: \(summary.isEmpty ? "nothing to do" : summary)")
        if dryRun {
            for op in ops { log("  \(op.kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(op.dst.replacingOccurrences(of: root + "/", with: ""))") }
            return
        }
        guard !ops.isEmpty else { return }
        log("backup: \(try backup(root: root))")
        for op in ops {
            switch op.kind {
            case .delete: try FS.remove(op.dst)
            default: try FS.copyReplacing(op.src!, op.dst)
            }
        }
        for store in stores { try rebuildArchiveIndex(store) }
        log("sessions now: \(stores.map { String(localFiles($0).count) }.joined(separator: " / "))")
    }
}
