import SwiftUI

struct PopoverView: View {
    let store: AccountStore
    /// Snapshots draw this account's header as hovered.
    var previewHoverIndex: Int?
    @State private var listHeight: CGFloat = 0

    /// Ten expanded accounts are taller than most screens, so past this the list scrolls.
    static var maxListHeight: CGFloat { max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 140) }

    var body: some View {
        VStack(spacing: 0) {
            if store.accounts.isEmpty {
                EmptyAccounts(store: store)
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(spacing: 0) {
                            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                                if index > 0 { Divider().padding(.horizontal, 16) }
                                AccountSection(store: store, account: account, index: index, now: context.date, previewHover: index == previewHoverIndex)
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(listHeight, Self.maxListHeight))
            }
            Divider()
            FooterBar(store: store)
        }
        .frame(width: StatusController.width)
    }
}

private struct EmptyAccounts: View {
    let store: AccountStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.icon)
            VStack(spacing: 5) {
                Text("Add your Claude accounts")
                    .font(.system(size: 13, weight: .semibold))
                Text("See each account's session and weekly usage, and exactly when each one resets.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Add account") { store.beginAdd() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }
}

private struct AccountSection: View {
    let store: AccountStore
    let account: Account
    let index: Int
    let now: Date
    var previewHover = false

    /// The header row sits `rowInset` inside the card, so its highlight's corners are concentric with the card's
    /// (16 − 8 = 8). Collapsed or not, the header keeps the same position; only the rows below it come and go.
    private enum Layout {
        static let rowInset: CGFloat = 8
        static let rowPadding: CGFloat = 8
        static let rowRadius: CGFloat = 8
        static let contentInset: CGFloat = 16
    }

    @State private var renaming = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var nameFocused: Bool

    private var status: AccountStatus { store.status[account.id] ?? AccountStatus() }
    private var isCollapsed: Bool { store.collapsed.contains(account.id) }

    private var subtitle: String {
        var parts: [String] = []
        if let plan = account.plan { parts.append(plan) }
        if let email = account.email, email != account.label { parts.append(email) }
        return parts.isEmpty ? account.orgName : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 12) {
                    if let problem = status.problem {
                        ProblemRow(problem: problem) { act(on: problem) }
                    }
                    if let snapshot = status.snapshot {
                        ForEach(snapshot.limits) { LimitRow(limit: $0, now: now) }
                    } else if status.problem == nil {
                        Group {
                            LimitRow(limit: UsageLimit(id: "a", title: "Session", kind: .session, percent: 0, resetsAt: nil), now: now)
                            LimitRow(limit: UsageLimit(id: "b", title: "Week", kind: .week, percent: 0, resetsAt: nil), now: now)
                        }
                        .redacted(reason: .placeholder)
                    }
                }
                .padding(.horizontal, Layout.contentInset - Layout.rowInset)
                .padding(.top, 6)
                .padding(.bottom, Layout.contentInset - Layout.rowInset)
            }
        }
        .padding(Layout.rowInset)
    }

    /// The whole row highlights on hover; everything but the menu button toggles the account.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Avatar(label: account.label, color: Palette.avatar(account.color))
                VStack(alignment: .leading, spacing: 1) {
                    if renaming {
                        TextField("Name", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .focused($nameFocused)
                            .onAppear { nameFocused = true }
                            .onSubmit(commitRename)
                            .onExitCommand { renaming = false }
                            .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }
                    } else {
                        Text(account.label)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if isCollapsed, let summary {
                        summary
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .lineLimit(1)
                    } else {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if status.isLoading && status.snapshot != nil {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.icon)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(.snappy(duration: 0.18), value: isCollapsed)
                    .frame(width: 12)
            }
            .padding([.leading, .vertical], Layout.rowPadding)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !renaming else { return }
                store.toggleCollapsed(account.id)
            }
            Menu {
                Button("Rename") {
                    draft = account.label
                    renaming = true
                }
                Button("Show usage page") { store.openUsagePage(account) }
                Button("Sign in again") { store.beginSignIn(account) }
                if index > 0 || index < store.accounts.count - 1 {
                    Divider()
                    if index > 0 { Button("Move up") { store.move(account.id, by: -1) } }
                    if index < store.accounts.count - 1 { Button("Move down") { store.move(account.id, by: 1) } }
                }
                Divider()
                Button("Remove account", role: .destructive) { store.remove(account.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.icon)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: Layout.rowRadius, style: .continuous)
                .fill(hovering || previewHover ? Palette.rowHover : .clear)
        )
        .onHover { hovering = $0 }
    }

    /// What a collapsed account shows under its name: session and week usage, or what's wrong.
    private var summary: Text? {
        if let problem = status.problem {
            return Text(problem.shortText).foregroundStyle(Palette.warning)
        }
        guard let snapshot = status.snapshot else { return nil }
        let parts = [snapshot.session, snapshot.week].compactMap { $0 }.map { limit in
            let percent = limit.percent(at: now)
            return Text("\(limit.title) ").foregroundStyle(.secondary)
                + Text("\(Int(percent.rounded()))%").foregroundStyle(Palette.emphasis(for: percent))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text("  ·  ").foregroundStyle(.secondary) + $1 }
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        store.rename(account.id, to: draft)
    }

    private func act(on problem: AccountProblem) {
        switch problem {
        case .signedOut: store.beginSignIn(account)
        case .browserCheck: store.openUsagePage(account)
        case .failed: Task { await store.refresh(account.id) }
        }
    }
}

private struct Avatar: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label.first(where: \.isLetter).map { String($0).uppercased() } ?? "•")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(color))
    }
}

private struct LimitRow: View {
    let limit: UsageLimit
    let now: Date

    var body: some View {
        let percent = limit.percent(at: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(percent.rounded()))% used")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            UsageBar(fraction: percent / 100, color: Palette.bar(for: percent))
            HStack {
                Text(ResetText.countdown(limit.resetsAt, now: now))
                Spacer()
                if let resetsAt = limit.resetsAt, resetsAt > now {
                    Text(ResetText.clock(resetsAt, now: now))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                if clamped > 0 {
                    Capsule().fill(color).frame(width: max(geometry.size.height, geometry.size.width * clamped))
                }
            }
        }
        .frame(height: 6)
    }
}

private struct ProblemRow: View {
    let problem: AccountProblem
    let action: () -> Void

    private var message: String {
        switch problem {
        case .signedOut: "Signed out of claude.ai."
        case .browserCheck: "claude.ai wants a quick browser check."
        case .failed(let reason): "Couldn't update. \(reason)."
        }
    }

    private var actionTitle: String {
        switch problem {
        case .signedOut: "Sign in"
        case .browserCheck: "Open"
        case .failed: "Retry"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.warning)
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.problemFill))
    }
}

private struct FooterBar: View {
    @Bindable var store: AccountStore

    var body: some View {
        HStack(spacing: 2) {
            if store.accounts.isEmpty {
                EmptyView()
            } else if store.canAddAccount {
                FooterButton(action: { store.beginAdd() }) {
                    Label("Add account", systemImage: "plus")
                        .labelStyle(FooterLabelStyle())
                }
            } else {
                Text("\(store.accounts.count) of \(AccountStore.maxAccounts) accounts")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 4)
            if !store.accounts.isEmpty {
                if let last = store.lastRefresh {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(ResetText.updated(last, now: context.date))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.trailing, 2)
                }
                FooterButton(action: { Task { await store.refreshAll() } }) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.icon)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            Menu {
                Picker("Menu bar shows", selection: $store.menuBarMetric) {
                    ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0) }
                }
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Open at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
                Divider()
                Button("Quit Claude Limits") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.icon)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

private struct FooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.icon)
            configuration.title
                .font(.system(size: 12, weight: .medium))
        }
    }
}

private struct FooterButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 7)
                .frame(minWidth: 28, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.rowHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum ResetText {
    static func countdown(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not started" }
        let seconds = date.timeIntervalSince(now)
        return seconds > 0 ? "Resets in \(duration(seconds))" : "Just reset"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let restMinutes = minutes % 60
        if hours < 24 { return restMinutes == 0 ? "\(hours)h" : "\(hours)h \(restMinutes)m" }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0 ? "\(days)d" : "\(days)d \(restHours)h"
    }

    static func clock(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        if date.timeIntervalSince(now) < 6 * 86400 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }

    static func updated(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? "Updated just now" : "Updated \(minutes) min ago"
    }
}
