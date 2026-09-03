import Foundation

struct AgentMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable {
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

    let id = UUID()
    let role: Role
    let text: String
}

struct AgentActivity: Identifiable, Equatable, Sendable {
    enum State: Sendable {
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

enum AgentEntry: Identifiable, Equatable, Sendable {
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
}

enum CodexEvent: Equatable, Sendable {
    case threadStarted(String)
    case message(String)
    case activity(AgentActivity, changedFiles: [String])
    case usage(String)
    case error(String)
}

enum AgentProvider: String, CaseIterable, Identifiable, Sendable {
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

struct AgentThread: Identifiable, Equatable, Sendable {
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

