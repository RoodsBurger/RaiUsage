import Foundation

/// A remote machine (e.g. an EC2 instance) the user also runs Claude Code on.
/// Its `~/.claude/projects` JSONL logs are pulled over SSH into a local cache
/// so History, activity, and cost can include them alongside this Mac.
struct RemoteInstance: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    /// Hostname or IP. Charset-validated (`RemoteInstanceValidation.isValidHost`).
    var host: String
    /// SSH user (e.g. `ubuntu`). Charset-validated.
    var user: String
    var enabled: Bool
    /// Optional friendly name the user types (e.g. "prod-worker"). Drives the
    /// source-dropdown label when set.
    var nickname: String?

    init(id: UUID = UUID(), host: String, user: String, enabled: Bool = true, nickname: String? = nil) {
        self.id = id
        self.host = host
        self.user = user
        self.enabled = enabled
        self.nickname = nickname
    }

    /// `user@host`, the SSH target, regardless of any nickname.
    var sshTarget: String { "\(user)@\(host)" }

    /// Row / menu display name: the nickname if set and non-blank, else `user@host`.
    var displayLabel: String {
        if let nickname, !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nickname
        }
        return sshTarget
    }
}

/// Host / user validation at the input boundary. The strings are passed to
/// rsync as literal argv elements (never through a shell), but rejecting shell
/// metacharacters and whitespace here is defense in depth.
enum RemoteInstanceValidation {
    /// Hostnames / IPs: letters, digits, dot, colon (IPv6), hyphen, underscore.
    /// Mirrors `^[A-Za-z0-9._:-]+$` plus underscore, non-empty, length-bounded.
    static func isValidHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...255).contains(trimmed.count) else { return false }
        return trimmed.unicodeScalars.allSatisfy { hostAllowed.contains($0) }
    }

    /// SSH users: letters, digits, dot, hyphen, underscore. Mirrors
    /// `^[A-Za-z0-9._-]+$`, non-empty, length-bounded.
    static func isValidUser(_ user: String) -> Bool {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(trimmed.count) else { return false }
        return trimmed.unicodeScalars.allSatisfy { userAllowed.contains($0) }
    }

    private static let hostAllowed = makeSet("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
    private static let userAllowed = makeSet("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    private static func makeSet(_ chars: String) -> Set<Unicode.Scalar> {
        Set(chars.unicodeScalars)
    }
}

/// Where a session log came from: this Mac or a specific remote instance.
/// Identity is the `id` string alone, so a renamed instance (new `label`) still
/// matches a previously-stored selection.
enum LogSource: Sendable, Identifiable {
    case local
    case instance(id: UUID, label: String)

    var id: String {
        switch self {
        case .local: return "local"
        case .instance(let id, _): return id.uuidString
        }
    }
}

extension LogSource: Hashable {
    static func == (lhs: LogSource, rhs: LogSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One scan root handed to `SessionHistoryService`: a directory plus the
/// `LogSource` its files should be tagged with.
struct ScanRoot: Sendable {
    let source: LogSource
    let url: URL
}
