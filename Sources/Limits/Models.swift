import Foundation

struct Account: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Each account keeps its own WebKit cookie jar, so two claude.ai logins never mix.
    var storeID: UUID
    var label: String
    var email: String?
    var orgID: String
    var orgName: String
    var plan: String?
    var color: Int
}

struct UsageLimit: Identifiable, Equatable {
    enum Kind { case session, week, model }

    var id: String
    var title: String
    var kind: Kind
    var percent: Double
    var resetsAt: Date?

    /// Once the reset time has passed the window is empty, even before the next fetch confirms it.
    func percent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return percent
    }
}

struct UsageSnapshot: Equatable {
    var limits: [UsageLimit]
    var fetchedAt: Date

    var session: UsageLimit? { limits.first { $0.kind == .session } }
    var week: UsageLimit? { limits.first { $0.kind == .week } }
}

enum AccountProblem: Equatable {
    case signedOut
    case browserCheck
    case failed(String)

    var shortText: String {
        switch self {
        case .signedOut: "Signed out"
        case .browserCheck: "Needs a browser check"
        case .failed: "Couldn't update"
        }
    }
}

struct AccountStatus: Equatable {
    var snapshot: UsageSnapshot?
    var problem: AccountProblem?
    var isLoading = false
}

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case session, week, icon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: "Session usage"
        case .week: "Weekly usage"
        case .icon: "Icon only"
        }
    }
}
