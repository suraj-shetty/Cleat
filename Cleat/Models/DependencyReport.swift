import Foundation

struct DependencyCheck: Identifiable, Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case ok
        case warning
        case failed
        case checking

        var isBlocking: Bool { self == .failed }
    }

    var id: String
    var title: String
    var status: Status
    var detail: String
    /// Shell commands the user can copy and run themselves. The app never runs these
    /// for you: they install software system-wide and touch Homebrew, which is the
    /// user's to decide on.
    var fixCommands: [String] = []
    /// A System Settings pane or download page relevant to the fix.
    var fixURL: URL?
    var fixButtonTitle: String?
}

struct DependencyReport: Sendable, Equatable {
    var checks: [DependencyCheck] = []
    /// Absolute path of an ntfs-3g binary that is correctly linked against FUSE-T.
    var usableNTFS3GPath: String?
    /// Backend the helper should be asked for, given what is actually installed.
    var backend: FUSEBackend = .nfs
    var lastRun: Date = .distantPast

    var isReady: Bool { usableNTFS3GPath != nil && !checks.contains { $0.status == .failed } }
    var blockingChecks: [DependencyCheck] { checks.filter { $0.status == .failed } }
    var warningChecks: [DependencyCheck] { checks.filter { $0.status == .warning } }
}
