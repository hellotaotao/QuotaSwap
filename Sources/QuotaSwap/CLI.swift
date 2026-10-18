import Foundation

enum CLI {
    static let commands: Set<String> = ["list", "usage", "doctor", "use", "save", "add", "rename", "sync", "help", "--help", "-h"]

    static let help = """
    QuotaSwap: switch the Claude desktop app between accounts and watch their usage.
    Run without arguments for the menu bar app.

      quotaswap list                 saved accounts, * marks the signed-in one
      quotaswap usage                5-hour and weekly usage of every saved account
      quotaswap doctor               check the Claude internals QuotaSwap relies on
      quotaswap use ACCOUNT          switch Claude to ACCOUNT (name, email, or a unique prefix)
      quotaswap save [NAME]          save the signed-in account
      quotaswap add                  sign Claude out locally to add another account
      quotaswap rename OLD NEW       change a saved account's short name
      quotaswap sync [--dry-run]     merge Code session lists across accounts
    """

    static func run(_ args: [String]) -> Int32 {
        let log: Log = { print($0) }
        do {
            switch (args.first ?? "help", args.count) {
            case ("list", 1): list()
            case ("usage", 1): usage()
            case ("doctor", 1): return doctor()
            case ("use", 2): try Accounts.use(try Profiles.resolve(args[1]), log: log)
            case ("save", 1), ("save", 2): try Accounts.save(name: args.count == 2 ? args[1] : nil, log: log)
            case ("add", 1): try Accounts.add(log: log)
            case ("rename", 3):
                let renamed = try Accounts.rename(try Profiles.resolve(args[1]), to: args[2])
                print("renamed '\(args[1])' -> \(renamed.label)")
            case ("sync", 1), ("sync", 2):
                let dryRun = args.count == 2 && args[1] == "--dry-run"
                if args.count == 2 && !dryRun { print(help); return 2 }
                if dryRun {
                    try SessionSync.run(dryRun: true, log: log)
                } else {
                    try SelfCheck.requirePassing()
                    let wasRunning = try ClaudeApp.quit(log: log)
                    defer { if wasRunning { ClaudeApp.open(log: log) } }
                    try SessionSync.run(dryRun: false, log: log)
                }
            default:
                print(help)
                return args.first.map { ["help", "--help", "-h"].contains($0) } == true ? 0 : 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    private static func list() {
        let current = ClaudeConfig.currentUUID()
        let rows = Profiles.all()
        if rows.isEmpty { print("no saved accounts; sign in to Claude and run: quotaswap save") }
        let width = max(4, rows.map(\.name.count).max() ?? 0)
        for p in rows {
            let mark = p.uuid == current ? "*" : " "
            let email = (p.email ?? "(email unknown)").padding(toLength: 28, withPad: " ", startingAt: 0)
            print("\(mark) \(p.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(email) saved \((p.savedAt ?? "").replacingOccurrences(of: "T", with: " "))")
        }
        if let current, Profiles.forUUID(current) == nil,
           let cfg = try? ClaudeConfig.read(), ClaudeConfig.isSignedIn(cfg) {
            print("  signed in now: \(EmailDetector.email(for: current) ?? current) (not saved)")
        }
    }

    private static func usage() {
        let current = ClaudeConfig.currentUUID()
        let profiles = Profiles.all()
        let results = blocking {
            await withTaskGroup(of: (String, Result<Usage, Error>).self) { group in
                for p in profiles {
                    group.addTask {
                        do { return (p.name, .success(try await UsageClient.fetch(for: p, current: p.uuid == current))) }
                        catch { return (p.name, .failure(error)) }
                    }
                }
                var out: [String: Result<Usage, Error>] = [:]
                for await (name, result) in group { out[name] = result }
                return out
            }
        }
        for p in profiles {
            print("\(p.uuid == current ? "*" : " ") \(p.name)  \(p.email ?? p.uuid ?? "")")
            switch results[p.name] {
            case .success(let u):
                print("    5h    \(describe(u.fiveHour))")
                print("    week  \(describe(u.sevenDay))")
            case .failure(let error):
                print("    \(error.localizedDescription)")
            case nil:
                break
            }
        }
    }

    private static func describe(_ window: UsageWindow?) -> String {
        guard let window else { return "n/a" }
        let pct = window.utilization.map { String(format: "%3.0f%%", $0) } ?? "  ?"
        guard let reset = window.resetsAt else { return pct }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "\(pct)  resets \(f.string(from: reset)) (in \(shortDuration(until: reset) ?? "?"))"
    }

    private static func doctor() -> Int32 {
        let results = SelfCheck.run()
        for r in results { print("\(r.ok ? "ok  " : "FAIL") \(r.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(r.detail)") }
        let ok = results.allSatisfy(\.ok)
        if ok { SelfCheck.recordVerified(version: ClaudeApp.version) }
        print(ok ? "all checks passed" : "some checks failed; switching is disabled until QuotaSwap is updated")
        return ok ? 0 : 1
    }

    private static func blocking<T>(_ work: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task.detached {
            result = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }
}

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, CLI.commands.contains(first) {
            exit(CLI.run(args))
        }
        QuotaSwapApp.main()
    }
}
