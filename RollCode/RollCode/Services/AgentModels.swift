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

struct AgentTokenUsage: Equatable, Sendable, Codable {
    var inputTokens: Int
    var cachedTokens: Int
    var outputTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    static func parse(from description: String) -> AgentTokenUsage? {
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

struct AgentThread: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var provider: AgentProvider
    var codexThreadID: String?
    var title: String
    var updatedAt: Date
    var entries: [AgentEntry]
    var model: String?
    var reasoningEffort: String?
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int
    var lastDurationSeconds: Double?

    init(
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

    init(from decoder: Decoder) throws {
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
