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
            Text("\(percent(usage.fiveHour?.utilization)) · \(percent(usage.sevenDay?.utilization))")
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
        Notice(color: .accentColor) {
            Text("Signed in as \(account), not saved yet.").font(.callout)
            if model.pending == .save {
                ConfirmRow(text: "Claude will restart.", confirm: "Save") { model.perform(.save) } cancel: { model.pending = nil }
            } else {
                Button("Save this account") { model.pending = .save }
                    .disabled(model.blocked || model.busy != nil)
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.pending == .add {
                ConfirmRow(text: "Claude will restart signed out.", confirm: "Continue") { model.perform(.add) } cancel: { model.pending = nil }
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
                    Button("Switch") { model.pending = .switchTo(row.id) }
                        .disabled(model.blocked || model.busy != nil || model.unsavedAccount != nil)
                }
            }
            if model.pending == .switchTo(row.id) {
                ConfirmRow(text: "Claude will restart.", confirm: "Switch") { model.perform(.switchTo(row.id)) } cancel: { model.pending = nil }
            }
            UsageBar(title: "5h", window: row.usage?.fiveHour, loaded: row.usage != nil)
            UsageBar(title: "Week", window: row.usage?.sevenDay, loaded: row.usage != nil)
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
    let loaded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            if let value = window?.utilization {
                ProgressView(value: min(max(value, 0), 100), total: 100)
                    .tint(value >= 90 ? .red : value >= 75 ? .orange : .accentColor)
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

struct ConfirmRow: View {
    let text: String
    let confirm: String
    let action: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: cancel).buttonStyle(.borderless)
            Button(confirm, action: action).buttonStyle(.borderedProminent).controlSize(.small)
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
