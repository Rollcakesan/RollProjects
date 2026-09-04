import Foundation

struct AgentMessage: Identifiable, Equatable, Sendable, Codable {
    enum Role: String, Sendable, Codable {
        case user
        case assistant
        case system

        var title: String {
            switch self {
            case .user: "YOU"
            case .assistant: "CODEX"
            case .system: "ROLLCODE"
            }
        }
    }

    let id: UUID
    let role: Role
    let text: String
    var senderName: String?

    init(role: Role, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.senderName = nil
    }

    init(id: UUID = UUID(), role: Role, text: String, senderName: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.senderName = senderName
    }

    var displayTitle: String {
        if let senderName { return senderName }
        return role.title
    }
}

struct AgentActivity: Identifiable, Equatable, Sendable, Codable {
    enum State: String, Sendable, Codable {
        case running
        case completed
        case failed

        var iconName: String {
            switch self {
            case .running: "circle.dotted"
            case .completed: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let state: State
}

enum AgentEntry: Identifiable, Equatable, Sendable, Codable {
    enum ID: Hashable, Sendable {
        case message(UUID)
        case activity(String)
        case changes
        case usage
    }

    case message(AgentMessage)
    case activity(AgentActivity)
    case changes([String])
    case usage(String)

    var id: ID {
        switch self {
        case .message(let message): .message(message.id)
        case .activity(let activity): .activity(activity.id)
        case .changes: .changes
        case .usage: .usage
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, message, activity, changes, usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "message":
            let msg = try container.decode(AgentMessage.self, forKey: .message)
            self = .message(msg)
        case "activity":
            let act = try container.decode(AgentActivity.self, forKey: .activity)
            self = .activity(act)
        case "changes":
            let files = try container.decode([String].self, forKey: .changes)
            self = .changes(files)
        case "usage":
            let txt = try container.decode(String.self, forKey: .usage)
            self = .usage(txt)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown AgentEntry type: \(type)")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let msg):
            try container.encode("message", forKey: .type)
            try container.encode(msg, forKey: .message)
        case .activity(let act):
            try container.encode("activity", forKey: .type)
            try container.encode(act, forKey: .activity)
        case .changes(let files):
            try container.encode("changes", forKey: .type)
            try container.encode(files, forKey: .changes)
        case .usage(let txt):
            try container.encode("usage", forKey: .type)
            try container.encode(txt, forKey: .usage)
        }
    }
}

enum CodexEvent: Equatable, Sendable {
    case threadStarted(String)
    case message(String)
    case activity(AgentActivity, changedFiles: [String])
    case usage(String)
    case error(String)
}

enum AgentProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case codex = "Codex"
    case gemini = "Gemini"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .codex: "sparkles"
        case .gemini: "bolt.fill"
        }
    }
}

struct AgentThread: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var provider: AgentProvider
    var codexThreadID: String?
    var title: String
    var updatedAt: Date
    var entries: [AgentEntry]

    init(
        id: UUID = UUID(),
        provider: AgentProvider = .codex,
        codexThreadID: String? = nil,
        title: String = "New Thread",
        updatedAt: Date = Date(),
        entries: [AgentEntry] = []
    ) {
        self.id = id
        self.provider = provider
        self.codexThreadID = codexThreadID
        self.title = title
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

struct CodexSessionSummary: Identifiable, Equatable, Sendable {
    let id: String
    let threadName: String
    let updatedAt: Date?

    var displayTitle: String {
        let trimmed = threadName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Session" : trimmed
    }
}

enum ANSIEscapeCleaner: Sendable {
    nonisolated(unsafe) private static let controlSequence = #/\u{001B}(?:\[[0-?]*[ -/]*[@-~]|\][^\u{0007}]*(?:\u{0007}|\u{001B}\\))/#

    static func clean(_ text: String) -> String {
        text.replacing(controlSequence, with: "")
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "")
    }

    static func stripEscapes(from text: String) -> String {
        text.replacing(controlSequence, with: "")
    }
}
