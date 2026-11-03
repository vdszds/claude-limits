import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class AccountStore {
    static let maxAccounts = 10

    private(set) var accounts: [Account] = []
    private(set) var status: [UUID: AccountStatus] = [:]
    private(set) var collapsed: Set<UUID> = []
    private(set) var lastRefresh: Date?

    var refreshMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshMinutes, forKey: Keys.refreshMinutes)
            scheduleTimer()
        }
    }

    var menuBarMetric: MenuBarMetric {
        didSet { UserDefaults.standard.set(menuBarMetric.rawValue, forKey: Keys.menuBarMetric) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Claude Limits: launch at login failed: \(error.localizedDescription)")
            }
        }
    }

    var isRefreshing: Bool { status.values.contains { $0.isLoading } }

    var canAddAccount: Bool { accounts.count < Self.maxAccounts }

    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var resetTimer: Timer?

    private enum Keys {
        static let accounts = "accounts"
        static let refreshMinutes = "refreshMinutes"
        static let menuBarMetric = "menuBarMetric"
        static let collapsed = "collapsedAccounts"
    }

    init() {
        isDemo = false
        let defaults = UserDefaults.standard
        refreshMinutes = defaults.object(forKey: Keys.refreshMinutes) as? Int ?? 5
        menuBarMetric = MenuBarMetric(rawValue: defaults.string(forKey: Keys.menuBarMetric) ?? "") ?? .session
        if let data = defaults.data(forKey: Keys.accounts), let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        }
        collapsed = Set((defaults.stringArray(forKey: Keys.collapsed) ?? []).compactMap(UUID.init(uuidString:)))

        scheduleTimer()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // Give the network a moment to come back after sleep.
                try? await Task.sleep(for: .seconds(5))
                await self?.refreshAll()
            }
        }
        Task {
            await refreshAll()
            await refreshPlans()
        }
    }

    // MARK: Refreshing

    func refreshAll() async {
        guard !isDemo else { return }
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.refresh(account.id) }
            }
        }
        lastRefresh = .now
        scheduleResetRefresh()
    }

    func refreshIfStale() {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 60 { return }
        Task { await refreshAll() }
    }

    func refresh(_ id: UUID) async {
        guard !isDemo, let account = accounts.first(where: { $0.id == id }), status[id]?.isLoading != true else { return }
        status[id, default: AccountStatus()].isLoading = true

        var snapshot: UsageSnapshot?
        var problem: AccountProblem?
        do {
            let limits = try await ClaudeWeb.usage(orgID: account.orgID, store: ClaudeWeb.dataStore(account.storeID))
            snapshot = UsageSnapshot(limits: limits, fetchedAt: .now)
        } catch {
            problem = Self.problem(for: error)
        }

        guard accounts.contains(where: { $0.id == id }) else { return }
        var next = status[id] ?? AccountStatus()
        next.snapshot = snapshot ?? next.snapshot
        next.problem = problem
        next.isLoading = false
        status[id] = next
    }

    /// Plans rarely change, so they are only checked once per launch.
    private func refreshPlans() async {
        for account in accounts {
            let store = ClaudeWeb.dataStore(account.storeID)
            guard let organization = try? await ClaudeWeb.organizations(store: store).first(where: { $0.id == account.orgID }) else { continue }
            update(account.id) {
                $0.plan = organization.plan
                $0.orgName = organization.name
                $0.email = organization.email ?? $0.email
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard !isDemo else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshMinutes * 60), repeats: true) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
        timer?.tolerance = 15
    }

    /// Fetches again just after the next reset, so the numbers drop without waiting for the regular timer.
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        let now = Date.now
        let next = status.values.compactMap(\.snapshot).flatMap(\.limits).compactMap(\.resetsAt).filter { $0 > now }.min()
        guard let next else { return }
        resetTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now) + 15, repeats: false) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
    }

    private static func problem(for error: Error) -> AccountProblem {
        switch error as? ClaudeWebError {
        case .signedOut: return .signedOut
        case .browserCheck: return .browserCheck
        case .rateLimited: return .failed("claude.ai asked to slow down")
        case .http(let code): return .failed("claude.ai answered with error \(code)")
        case .badResponse, .noOrganization: return .failed("claude.ai sent an answer this app doesn't understand")
        case nil:
            if let urlError = error as? URLError, urlError.code == .notConnectedToInternet { return .failed("You're offline") }
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Menu bar

    /// Percentages only stay readable for one or two accounts; more are drawn as bars from `menuBarLevels`.
    func menuBarText(at now: Date = .now) -> String? {
        guard menuBarMetric != .icon, (1...2).contains(accounts.count) else { return nil }
        return menuBarLevels(at: now).map { $0.map { "\(Int($0.rounded()))%" } ?? "–" }.joined(separator: " · ")
    }

    var showsMenuBarBars: Bool { menuBarMetric != .icon && accounts.count > 2 }

    func menuBarLevels(at now: Date = .now) -> [Double?] {
        accounts.map { account in
            guard let snapshot = status[account.id]?.snapshot else { return nil }
            // Verified Ultra accounts have no session limit, only weekly ones, so they show the week instead.
            let limit = menuBarMetric == .week ? snapshot.week : (snapshot.session ?? snapshot.week)
            return limit?.percent(at: now)
        }
    }

    // MARK: Accounts

    func toggleCollapsed(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        saveCollapsed()
    }

    func beginAdd() {
        guard canAddAccount else { return }
        SignInController.present(.add, store: self)
    }
    func beginSignIn(_ account: Account) { SignInController.present(.signInAgain(account), store: self) }
    func openUsagePage(_ account: Account) { SignInController.present(.usagePage(account), store: self) }

    func add(storeID: UUID, organization: Organization) {
        // Signing in to an account that is already listed refreshes that entry instead of duplicating it.
        if let existing = accounts.first(where: { $0.orgID == organization.id }) {
            let oldStore = existing.storeID
            update(existing.id) {
                $0.storeID = storeID
                $0.plan = organization.plan
                $0.email = organization.email ?? $0.email
            }
            if oldStore != storeID { Task { await ClaudeWeb.removeDataStore(oldStore) } }
            Task { await refresh(existing.id) }
            return
        }
        guard canAddAccount else { return }

        let used = Set(accounts.map(\.color))
        let color = (0..<Palette.avatars.count).first { !used.contains($0) } ?? accounts.count % Palette.avatars.count
        let account = Account(
            storeID: storeID,
            label: organization.displayName,
            email: organization.email,
            orgID: organization.id,
            orgName: organization.name,
            plan: organization.plan,
            color: color
        )
        accounts.append(account)
        save()
        Task {
            await refresh(account.id)
            scheduleResetRefresh()
        }
    }

    func reconnected(_ id: UUID, organization: Organization) {
        update(id) {
            $0.orgID = organization.id
            $0.orgName = organization.name
            $0.plan = organization.plan
            $0.email = organization.email ?? $0.email
        }
        Task { await refresh(id) }
    }

    func rename(_ id: UUID, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.label = trimmed }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let from = accounts.firstIndex(where: { $0.id == id }), accounts.indices.contains(from + offset) else { return }
        accounts.swapAt(from, from + offset)
        save()
    }

    func remove(_ id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        accounts.removeAll { $0.id == id }
        status[id] = nil
        collapsed.remove(id)
        save()
        saveCollapsed()
        Task { await ClaudeWeb.removeDataStore(account.storeID) }
    }

    private func update(_ id: UUID, _ change: (inout Account) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index])
        save()
    }

    private func save() {
        guard !isDemo, let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: Keys.accounts)
    }

    private func saveCollapsed() {
        guard !isDemo else { return }
        UserDefaults.standard.set(collapsed.map(\.uuidString), forKey: Keys.collapsed)
    }

    // MARK: Demo data for snapshots

    enum Demo { case accounts, problem, empty, many }

    init(demo: Demo) {
        isDemo = true
        refreshMinutes = 5
        menuBarMetric = .session
        guard demo != .empty else { return }

        let now = Date.now
        typealias Sample = (label: String, email: String, plan: String, session: Double?, sessionResets: TimeInterval?, week: Double, weekResets: TimeInterval)
        let samples: [Sample] = [
            ("Personal", "me@example.com", "Ultra", 42, 2 * 3600 + 14 * 60, 18, 3 * 86400 + 5 * 3600),
            ("Studio", "me@studio.example", "Max 5x", 93, 38 * 60, 74, 86400 + 2 * 3600),
            ("Research", "lab@example.com", "Pro", 12, 4 * 3600 + 2 * 60, 55, 2 * 86400),
            ("Agency", "ops@agency.example", "Ultra", nil, nil, 97, 5 * 3600),
            ("Side project", "hello@side.example", "Pro", 0, nil, 31, 4 * 86400),
            ("Team", "team@example.com", "Team", 67, 3 * 3600, 40, 6 * 86400),
        ]

        for (index, sample) in samples.prefix(demo == .many ? samples.count : 2).enumerated() {
            let account = Account(storeID: UUID(), label: sample.label, email: sample.email, orgID: "\(index)", orgName: "", plan: sample.plan, color: index)
            var limits = [
                sample.session.map { percent in
                    UsageLimit(id: "session", title: "Session", kind: .session, percent: percent, resetsAt: sample.sessionResets.map { now + $0 })
                },
                UsageLimit(id: "week", title: "Week", kind: .week, percent: sample.week, resetsAt: now + sample.weekResets),
            ].compactMap { $0 }
            if index == 0 {
                limits.append(UsageLimit(id: "model-Sonnet", title: "Week · Sonnet", kind: .model, percent: 6, resetsAt: now + sample.weekResets))
            }
            let signedOut = (demo == .problem && index == 1) || (demo == .many && index == 4)
            accounts.append(account)
            status[account.id] = AccountStatus(snapshot: UsageSnapshot(limits: limits, fetchedAt: now), problem: signedOut ? .signedOut : nil)
            if demo == .many && index >= 2 { collapsed.insert(account.id) }
        }
        lastRefresh = now - 120
    }
}
