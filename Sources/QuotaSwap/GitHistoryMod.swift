import Foundation
import JavaScriptCore

/// The Git history mod for Claude Code, shipped inside the app. QuotaSwap
/// installs it as a one-plugin marketplace in ~/.claude and switches it with a
/// flag file the mod reads every five seconds, so running Claude sessions
/// follow the menu's checkbox without reloading their plugins.
enum GitHistoryMod {
    static let pluginID = "git-history@quotaswap"
    private static let defaultsKey = "showGitHistoryButton"

    static var marketplaceDir: String { Env.claudeHome + "/plugins/marketplaces/quotaswap" }
    static var pluginDir: String { marketplaceDir + "/plugins/git-history" }
    /// The mod reads it as `${$.plugin.root}/../../git-history.json`.
    static var flagFile: String { marketplaceDir + "/git-history.json" }
    static var settingsFile: String { Env.claudeHome + "/settings.json" }
    static var bundled: String { Env.modsDir + "/git-history" }

    /// Claude Code is set up on this Mac and this build carries the mod.
    static var isAvailable: Bool { FS.isDir(Env.claudeHome) && FS.isDir(bundled) }

    static var isOn: Bool {
        get { Env.defaults.object(forKey: defaultsKey) as? Bool ?? true }
        set { Env.defaults.set(newValue, forKey: defaultsKey) }
    }

    /// Brings the installed copy, its marketplace, the switch and Claude Code's
    /// settings up to date. `enable` turns the plugin on in the settings even
    /// where someone turned it off there; otherwise only a missing entry is added.
    static func install(enable: Bool, log: Log) throws {
        guard isAvailable else { return }
        if try copyIfChanged() { log("installed the Git history mod in \(pluginDir)") }
        try writeIfChanged(["name": "quotaswap", "owner": ["name": "QuotaSwap"],
                            "plugins": [["name": "git-history", "source": "./plugins/git-history"]]],
                           to: marketplaceDir + "/.claude-plugin/marketplace.json")
        try writeFlag()
        if try register(enable: enable) { log("added the Git history mod to \(settingsFile)") }
    }

    /// Shows or hides the band button in every running Claude session.
    static func set(_ on: Bool, log: Log) throws {
        isOn = on
        if on {
            try install(enable: true, log: log)
        } else if FS.isDir(marketplaceDir) {
            try writeFlag()
        }
    }

    /// Replaces the installed copy when a bundled file is missing from it or
    /// differs, so an app update ships the mod's update.
    private static func copyIfChanged() throws -> Bool {
        let files = (FS.fm.enumerator(atPath: bundled)?.allObjects as? [String] ?? [])
            .filter { !FS.isDir(bundled + "/" + $0) }
        if !files.isEmpty && files.allSatisfy({
            FS.fm.contents(atPath: bundled + "/" + $0) == FS.fm.contents(atPath: pluginDir + "/" + $0)
        }) { return false }
        let staging = pluginDir + ".new"
        try FS.makeDir(marketplaceDir + "/plugins")
        try FS.copyReplacing(bundled, staging)
        try FS.remove(pluginDir)
        try FS.fm.moveItem(atPath: staging, toPath: pluginDir)
        return true
    }

    private static func writeFlag() throws {
        var flag: [String: Any] = ["showButton": isOn]
        if let appPath { flag["appPath"] = appPath }
        try writeIfChanged(flag, to: flagFile)
    }

    /// Where this app lives, which the mod checks so that deleting QuotaSwap
    /// hides the button. Left out for a build run outside an app bundle and for
    /// a translocated copy, whose path is gone once it quits.
    private static var appPath: String? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", !url.path.contains("/AppTranslocation/") else { return nil }
        return url.path
    }

    private static func writeIfChanged(_ object: [String: Any], to path: String) throws {
        if let current = FS.readObject(path), NSDictionary(dictionary: current).isEqual(to: object) { return }
        try FS.makeDir((path as NSString).deletingLastPathComponent)
        try FS.writeObject(object, to: path, pretty: true, mode: 0o644)
    }

    /// Adds the marketplace to Claude Code's user settings and the plugin to
    /// its enabled plugins, changing nothing else. JavaScript's JSON keeps the
    /// file's key order and Claude Code's own formatting, which
    /// JSONSerialization would not. A file that is not a JSON object is left
    /// alone. Returns whether it wrote the file.
    private static func register(enable: Bool) throws -> Bool {
        let path = URL(fileURLWithPath: settingsFile).resolvingSymlinksInPath().path
        let data = FS.fm.contents(atPath: path)
        let text = data.flatMap { String(data: $0, encoding: .utf8) }
        let merge = """
            ((text, dir, id, enable) => {
              const settings = text === null ? {} : JSON.parse(text)
              const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value)
              if (!isObject(settings)) throw new Error('not an object')
              const child = key => isObject(settings[key]) ? settings[key] : (settings[key] = {})
              child('extraKnownMarketplaces').quotaswap = { source: { source: 'directory', path: dir } }
              const plugins = child('enabledPlugins')
              if (enable || !(id in plugins)) plugins[id] = true
              return JSON.stringify(settings, null, 2)
            })
            """
        guard data == nil || text != nil, let context = JSContext(),
              let merged = context.evaluateScript(merge)?
                  .call(withArguments: [text.map { $0 as Any } ?? NSNull(), marketplaceDir, pluginID, enable]),
              context.exception == nil, merged.isString, let json = merged.toString() else {
            throw QSError("\(settingsFile) is not a valid JSON object, so QuotaSwap left it alone and Claude does not load the Git history mod.")
        }
        let output = json + (text?.hasSuffix("\n") == false ? "" : "\n")
        if text == output { return false }
        let mode = (try? FS.fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int ?? 0o600
        try Data(output.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FS.fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return true
    }
}
