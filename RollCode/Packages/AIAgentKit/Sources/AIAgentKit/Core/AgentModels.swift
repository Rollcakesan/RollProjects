import Foundation

public struct AgentMessage: Identifiable, Equatable, Sendable, Codable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
        case system

        public var title: String {
            switch self {
            case .user: "YOU"
            case .assistant: "CODEX"
            case .system: "ROLLCODE"
            }
        }
    }

    public let id: UUID
    public let role: Role
    public let text: String
    public var senderName: String?

    public init(role: Role, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.senderName = nil
    }

    public init(id: UUID = UUID(), role: Role, text: String, senderName: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.senderName = senderName
    }

    public var displayTitle: String {
        if let senderName { return senderName }
        return role.title
    }
}

public struct AgentActivity: Identifiable, Equatable, Sendable, Codable {
    public enum State: String, Sendable, Codable {
        case running
        case completed
        case failed

        public var iconName: String {
            switch self {
            case .running: "circle.dotted"
            case .completed: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    public let id: String
    public let title: String
    public let detail: String
    public let state: State

    public init(id: String, title: String, detail: String, state: State) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public enum AgentEntry: Identifiable, Equatable, Sendable, Codable {
    public enum ID: Hashable, Sendable {
        case message(UUID)
        case activity(String)
        case changes
        case usage
    }

    case message(AgentMessage)
    case activity(AgentActivity)
    case changes([String])
    case usage(String)

    public var id: ID {
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

public enum CodexEvent: Equatable, Sendable {
    case threadStarted(String)
    case message(String)
    case activity(AgentActivity, changedFiles: [String])
    case usage(String)
    case error(String)
}

public enum AgentProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case codex = "Codex"
    case gemini = "Gemini"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .codex: "sparkles"
        case .gemini: "bolt.fill"
        }
    }
}

public struct AgentTokenUsage: Equatable, Sendable, Codable {
    public var inputTokens: Int
    public var cachedTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, cachedTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
    }

    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    public static func parse(from description: String) -> AgentTokenUsage? {
        let inputMatch = description.firstMatch(of: #/(\d+)\s+input/#)
        let cachedMatch = description.firstMatch(of: #/(\d+)\s+cached/#)
        let outputMatch = description.firstMatch(of: #/(\d+)\s+output/#)

        guard inputMatch != nil || outputMatch != nil else { return nil }

        let input = inputMatch.flatMap { Int($0.output.1) } ?? 0
        let cached = cachedMatch.flatMap { Int($0.output.1) } ?? 0
        let output = outputMatch.flatMap { Int($0.output.1) } ?? 0

        return AgentTokenUsage(inputTokens: input, cachedTokens: cached, outputTokens: output)
    }
}

public struct AgentThread: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var provider: AgentProvider
    public var codexThreadID: String?
    public var title: String
    public var updatedAt: Date
    public var entries: [AgentEntry]
    public var model: String?
    public var reasoningEffort: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedTokens: Int
    public var lastDurationSeconds: Double?

    public init(
        id: UUID = UUID(),
        provider: AgentProvider = .codex,
        codexThreadID: String? = nil,
        title: String = "New Thread",
        updatedAt: Date = Date(),
        entries: [AgentEntry] = [],
        model: String? = nil,
        reasoningEffort: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedTokens: Int = 0,
        lastDurationSeconds: Double? = nil
    ) {
        self.id = id
        self.provider = provider
        self.codexThreadID = codexThreadID
        self.title = title
        self.updatedAt = updatedAt
        self.entries = entries
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.lastDurationSeconds = lastDurationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, codexThreadID, title, updatedAt, entries
        case model, reasoningEffort, inputTokens, outputTokens, cachedTokens, lastDurationSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.provider = try container.decode(AgentProvider.self, forKey: .provider)
        self.codexThreadID = try container.decodeIfPresent(String.self, forKey: .codexThreadID)
        self.title = try container.decode(String.self, forKey: .title)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.entries = try container.decode([AgentEntry].self, forKey: .entries)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        self.cachedTokens = try container.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0
        self.lastDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .lastDurationSeconds)
    }
}

public struct CodexSessionSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let threadName: String
    public let updatedAt: Date?

    public init(id: String, threadName: String, updatedAt: Date?) {
        self.id = id
        self.threadName = threadName
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        let trimmed = threadName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Session" : trimmed
    }
}

#if canImport(TerminalCoreKit)
@_exported import TerminalCoreKit
#endif
