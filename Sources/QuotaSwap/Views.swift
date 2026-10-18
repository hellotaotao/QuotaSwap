import SwiftUI

struct QuotaSwapApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.blocked {
            Image(systemName: "exclamationmark.triangle")
        } else if let usage = model.currentRow?.usage {
            Text("5h \(percent(usage.fiveHour?.utilization)) · Wk \(percent(usage.sevenDay?.utilization))")
                .monospacedDigit()
        } else {
            Image(systemName: "person.2.circle")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.blocked { blockedNotice }
            if let account = model.unsavedAccount { unsavedNotice(account) }
            if model.rows.isEmpty && model.unsavedAccount == nil {
                Text("No saved accounts yet. Sign in to Claude, then reopen this menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                AccountRow(row: row, model: model)
            }
            if let busy = model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout)
                }
            } else if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("QuotaSwap").font(.headline)
            Spacer()
            if let version = model.claudeVersion {
                Text(model.blocked ? "Claude \(version) · checks failed"
                     : model.claudeUpdated ? "Claude \(version) · re-verified" : "Claude \(version)")
                    .font(.caption).foregroundStyle(model.blocked ? .orange : .secondary)
            }
        }
    }

    private var blockedNotice: some View {
        Notice(color: .orange) {
            Text("Claude's internal layout changed, so switching is disabled until QuotaSwap is updated.")
                .font(.callout)
            ForEach(model.failedChecks, id: \.name) { check in
                Text("• \(check.name): \(check.detail)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func unsavedNotice(_ account: String) -> some View {
        UnsavedNotice(account: account, confirming: model.pending == .save,
                      disabled: model.blocked || model.busy != nil,
                      ask: { model.pending = .save }, confirm: { model.perform(.save) }, cancel: { model.pending = nil })
    }

    private var footer: some View {
        HStack {
            if model.pending == .add {
                ConfirmRow(text: "Claude restarts at the sign-in screen."
                           + (model.currentRow?.profile.email.map { " \($0) stays saved." } ?? ""),
                           confirm: "Continue") { model.perform(.add) } cancel: { model.pending = nil }
            } else {
                Button("Add account…") { model.pending = .add }
                    .disabled(model.blocked || model.busy != nil || model.unsavedAccount != nil)
                    .help(model.unsavedAccount != nil ? "Save the signed-in account first" : "Sign Claude out locally, then sign in to another account")
                Spacer()
                Button { model.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh usage")
                    .disabled(model.busy != nil)
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .buttonStyle(.borderless)
    }
}

struct AccountRow: View {
    let row: AppModel.Row
    @ObservedObject var model: AppModel

    private var isCurrent: Bool { row.profile.uuid == model.currentUUID }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.profile.email ?? row.profile.name).fontWeight(.medium).lineLimit(1)
                    Text(isCurrent ? "\(row.profile.name) · signed in" : row.profile.name)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if row.loading { ProgressView().controlSize(.small) }
                if !isCurrent && model.pending != .switchTo(row.id) {
                    Button("Use account") { model.pending = .switchTo(row.id) }
                        .disabled(model.blocked || model.busy != nil || model.unsavedAccount != nil)
                        .help("Switch Claude to \(row.profile.email ?? row.profile.name)")
                }
            }
            if model.pending == .switchTo(row.id) {
                ConfirmRow(text: "Claude restarts signed in as \(row.profile.email ?? row.profile.name).", confirm: "Switch") {
                    model.perform(.switchTo(row.id))
                } cancel: { model.pending = nil }
            }
            UsageBar(title: "5h", window: row.usage?.fiveHour, length: 5 * 3600, loaded: row.usage != nil)
            UsageBar(title: "Week", window: row.usage?.sevenDay, length: 7 * 86400, loaded: row.usage != nil)
            if let error = row.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isCurrent ? 0.08 : 0.035)))
    }
}

struct UsageBar: View {
    let title: String
    let window: UsageWindow?
    let length: TimeInterval
    let loaded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            if let value = window?.utilization {
                let elapsed = elapsedFraction(resetsAt: window?.resetsAt, length: length)
                PaceBar(used: min(max(value, 0), 100) / 100, elapsed: elapsed,
                        color: Pace(usedPercent: value, elapsed: elapsed).color)
                    .help(elapsed.map { "\(percent(value)) used, \(percent($0 * 100)) of the window elapsed" } ?? "\(percent(value)) used")
                Text(percent(value)).font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
                Text(shortDuration(until: window?.resetsAt).map { "↻ \($0)" } ?? "")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 62, alignment: .trailing)
            } else {
                Text(loaded ? "not reported" : "—").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

/// Usage bar with a tick marking how much of the window has elapsed.
struct PaceBar: View {
    let used: Double  // 0...1
    let elapsed: Double?  // 0...1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: used > 0 ? max(6, geo.size.width * used) : 0)
                if let elapsed {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 2, height: 11)
                        .offset(x: min(max(geo.size.width * elapsed - 1, 0), geo.size.width - 2))
                }
            }
        }
        .frame(height: 6)
    }
}

/// Compares usage with elapsed time: ahead of the clock is red, behind is
/// green, within 5 points either way is yellow.
enum Pace {
    case under, even, over

    init(usedPercent: Double, elapsed: Double?) {
        if usedPercent >= 100 {
            self = .over
        } else if let elapsed {
            let lead = usedPercent - elapsed * 100
            self = lead > 5 ? .over : lead < -5 ? .under : .even
        } else {
            self = .under  // window not started yet
        }
    }

    var color: Color {
        switch self {
        case .under: return .green
        case .even: return Color(red: 0.95, green: 0.72, blue: 0.1)
        case .over: return .red
        }
    }
}

func elapsedFraction(resetsAt: Date?, length: TimeInterval, now: Date = Date()) -> Double? {
    guard let resetsAt else { return nil }
    return min(max(1 - resetsAt.timeIntervalSince(now) / length, 0), 1)
}

struct ConfirmRow: View {
    let text: String
    let confirm: String
    let action: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.borderless)
                Button(confirm, action: action).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Shown when Claude is signed in to an account QuotaSwap has no snapshot of,
/// typically right after "Add account".
struct UnsavedNotice: View {
    let account: String
    let confirming: Bool
    let disabled: Bool
    let ask: () -> Void
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        Notice(color: .accentColor) {
            Text("New account signed in").font(.callout.weight(.semibold))
            Text("Save \(account) to switch to it later and see its usage.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if confirming {
                ConfirmRow(text: "Claude restarts once to capture the login.", confirm: "Save", action: confirm, cancel: cancel)
            } else {
                Button("Save this account", action: ask)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(disabled)
                    .padding(.top, 2)
            }
        }
    }
}

struct Notice<Content: View>: View {
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
    }
}

func percent(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))%" } ?? "—"
}

#if DEBUG
/// `QuotaSwap render-preview out.png` (debug builds only): renders the usage
/// bars with fixed sample data so layout changes can be checked without a menu bar.
@MainActor
enum PreviewRenderer {
    static func render(to path: String) -> Int32 {
        let now = Date()
        func window(_ used: Double, resetIn: TimeInterval) -> UsageWindow {
            UsageWindow(utilization: used, resetsAt: now.addingTimeInterval(resetIn))
        }
        let samples: [(String, UsageWindow?, TimeInterval)] = [
            ("5h", window(23, resetIn: 4 * 3600 + 40 * 60), 5 * 3600),
            ("Week", window(24, resetIn: 2 * 86400 + 3 * 3600), 7 * 86400),
            ("5h", window(0, resetIn: 3 * 3600 + 40 * 60), 5 * 3600),
            ("Week", window(88, resetIn: 86400 + 12 * 3600), 7 * 86400),
            ("5h", window(50, resetIn: 2.5 * 3600), 5 * 3600),
            ("Week", nil, 7 * 86400),
        ]
        let view = VStack(alignment: .leading, spacing: 8) {
            Text("5h 23% · Wk 24%").monospacedDigit()
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                UsageBar(title: s.0, window: s.1, length: s.2, loaded: true)
            }
            HStack {
                Text("bob@example.com").fontWeight(.medium)
                Spacer()
                Button("Use account") {}
            }
            ConfirmRow(text: "Claude restarts signed in as bob@example.com.", confirm: "Switch", action: {}, cancel: {})
            ConfirmRow(text: "Claude restarts at the sign-in screen. alice@example.com stays saved.",
                       confirm: "Continue", action: {}, cancel: {})
            UnsavedNotice(account: "new@example.com", confirming: false, disabled: false, ask: {}, confirm: {}, cancel: {})
            UnsavedNotice(account: "new@example.com", confirming: true, disabled: false, ask: {}, confirm: {}, cancel: {})
        }
        .padding(14)
        .frame(width: 340)
        .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return 1 }
        return (try? png.write(to: URL(fileURLWithPath: path))) == nil ? 1 : 0
    }
}
#endif
