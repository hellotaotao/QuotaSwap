import Foundation

struct QSError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

typealias Log = (String) -> Void

/// Locations of everything QuotaSwap reads or writes. The QUOTASWAP_* variables
/// point the engine at a fake Claude directory for tests; when the Claude
/// directory is overridden the real app is never quit or opened.
enum Env {
    static let vars = ProcessInfo.processInfo.environment
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var claudeDir: String { vars["QUOTASWAP_CLAUDE_DIR"] ?? home + "/Library/Application Support/Claude" }
    static var store: String { vars["QUOTASWAP_STORE"] ?? home + "/Library/Application Support/Claude-accounts" }
    static var stateDir: String { vars["QUOTASWAP_STATE_DIR"] ?? home + "/Library/Application Support/QuotaSwap" }
    static var cliConfig: String { vars["QUOTASWAP_CLI_CONFIG"] ?? home + "/.claude.json" }
    static var projectsDir: String { vars["QUOTASWAP_PROJECTS_DIR"] ?? home + "/.claude/projects" }
    static var manageApp: Bool { vars["QUOTASWAP_CLAUDE_DIR"] == nil }

    static var config: String { claudeDir + "/config.json" }
    static var cookies: String { claudeDir + "/Cookies" }
    static var sessionsRoot: String { claudeDir + "/claude-code-sessions" }

    static let claudeBundleID = "com.anthropic.claudefordesktop"
}

enum FS {
    static let fm = FileManager.default

    static func exists(_ path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path)) != nil  // also true for dangling symlinks
    }

    static func isDir(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    static func list(_ path: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    static func readObject(_ path: String) -> [String: Any]? {
        guard let data = fm.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func writeObject(_ object: Any, to path: String, pretty: Bool = false, mode: Int = 0o600) throws {
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    static func remove(_ path: String) throws {
        if exists(path) { try fm.removeItem(atPath: path) }
    }

    static func copyReplacing(_ src: String, _ dst: String) throws {
        try remove(dst)
        try fm.copyItem(atPath: src, toPath: dst)
    }

    static func makeDir(_ path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
    }

    static func mtime(_ path: String) -> Double {
        ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
}

func isUUID(_ s: String) -> Bool {
    s.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
}

func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
}

/// Local time without zone, matching the format the Python tools wrote.
func localTimestamp(_ date: Date = Date(), format: String = "yyyy-MM-dd'T'HH:mm:ss") -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f.string(from: date)
}

@discardableResult
func runProcess(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

enum ClaudeApp {
    static var bundleURL: URL? {
        if let override = Env.vars["QUOTASWAP_CLAUDE_APP"] { return URL(fileURLWithPath: override) }
        return NSWorkspaceBridge.urlForApplication(Env.claudeBundleID)
    }

    static var version: String? {
        guard let url = bundleURL, let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else {
            return nil
        }
        return info["CFBundleShortVersionString"] as? String
    }

    static var isRunning: Bool { runProcess("/usr/bin/pgrep", ["-x", "Claude"]) == 0 }

    /// Quits Claude and waits for it to exit. Returns whether it was running.
    static func quit(log: Log) throws -> Bool {
        guard Env.manageApp, isRunning else { return false }
        log("quitting Claude ...")
        NSWorkspaceBridge.terminate(bundleID: Env.claudeBundleID)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !isRunning {
                Thread.sleep(forTimeInterval: 1)  // let helpers flush the cookie database
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw QSError("Claude did not quit within 30s; nothing changed.")
    }

    static func open(log: Log) {
        guard Env.manageApp else { return }
        log("opening Claude ...")
        runProcess("/usr/bin/open", ["-b", Env.claudeBundleID])
    }
}
