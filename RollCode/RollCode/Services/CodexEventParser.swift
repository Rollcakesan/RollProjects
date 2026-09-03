import Foundation

private struct RawCodexEvent: Decodable, Sendable {
    struct Usage: Decodable, Sendable {
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct Change: Decodable, Sendable {
        let path: String
        let kind: String?
    }

    struct Item: Decodable, Sendable {
        let id: String?
        let type: String
        let status: String?
        let text: String?
        let command: String?
        let aggregatedOutput: String?
        let changes: [Change]?
        let server: String?
        let tool: String?
        let result: AnyJSON?
        let query: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case id, type, status, text, command, changes, server, tool, result, query, message
            case aggregatedOutput = "aggregated_output"
        }
    }

    enum Failure: Decodable, Sendable {
        case message(String)

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self = .message(text)
                return
            }
            let container = try decoder.container(keyedBy: MessageKey.self)
            self = .message(try container.decode(String.self, forKey: .message))
        }

        private enum MessageKey: CodingKey { case message }
    }

    let type: String
    let threadID: String?
    let usage: Usage?
    let message: String?
    let error: Failure?
    let item: Item?

    enum CodingKeys: String, CodingKey {
        case type, usage, message, error, item
        case threadID = "thread_id"
    }
}

enum CodexEventParser {
    static func parse(_ line: String) -> CodexEvent? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(RawCodexEvent.self, from: data) else { return nil }

        switch event.type {
        case "thread.started":
            guard let threadID = event.threadID else { return nil }
            return .threadStarted(threadID)
        case "turn.completed":
            guard let usage = event.usage else { return nil }
            return .usage("\(usage.inputTokens) input · \(usage.cachedInputTokens) cached · \(usage.outputTokens) output")
        case "turn.failed", "error":
            return .error(errorDescription(event))
        case "item.started", "item.updated", "item.completed":
            guard let item = event.item else { return nil }
            return parseItem(item, eventType: event.type)
        default:
            return nil
        }
    }

    private static func parseItem(_ item: RawCodexEvent.Item, eventType: String) -> CodexEvent? {
        let identifier = item.id ?? UUID().uuidString
        let state = activityState(item.status, eventType: eventType)

        switch item.type {
        case "agent_message":
            guard eventType == "item.completed", let text = item.text, !text.isEmpty else { return nil }
            return .message(text)
        case "reasoning":
            let text = truncated(item.text ?? "Thinking")
            return .activity(AgentActivity(
                id: identifier,
                title: "Reasoning",
                detail: text,
                state: state
            ), changedFiles: [])
        case "command_execution":
            let command = item.command ?? "Running command"
            let output = truncated(item.aggregatedOutput ?? "")
            return .activity(AgentActivity(
                id: identifier,
                title: command,
                detail: output,
                state: state
            ), changedFiles: [])
        case "file_change":
            let changes = item.changes ?? []
            let paths = changes.map(\.path)
            let detail = changes.map { "\($0.kind ?? "update") · \($0.path)" }.joined(separator: "\n")
            return .activity(AgentActivity(
                id: identifier,
                title: paths.count == 1 ? "Changed 1 file" : "Changed \(paths.count) files",
                detail: detail,
                state: state
            ), changedFiles: paths)
        case "mcp_tool_call":
            let server = item.server ?? "MCP"
            let tool = item.tool ?? "tool"
            return .activity(AgentActivity(
                id: identifier,
                title: "\(server) · \(tool)",
                detail: truncated(item.result?.displayText ?? ""),
                state: state
            ), changedFiles: [])
        case "web_search":
            return .activity(AgentActivity(
                id: identifier,
                title: "Web search",
                detail: item.query ?? "",
                state: state
            ), changedFiles: [])
        case "error":
            guard let msg = item.message, !msg.isEmpty else { return nil }
            if isDeprecationOrWarning(msg) { return nil }
            return .error(msg)
        default:
            return nil
        }
    }

    private static func isDeprecationOrWarning(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("deprecated") || lower.contains("warning:")
    }

    private static func activityState(_ rawValue: String?, eventType: String) -> AgentActivity.State {
        if rawValue == "failed" { return .failed }
        if rawValue == "completed" || eventType == "item.completed" { return .completed }
        return .running
    }

    private static func errorDescription(_ event: RawCodexEvent) -> String {
        if let message = event.message { return message }
        if case .message(let message) = event.error { return message }
        return "Codex could not complete the request."
    }

    private static func truncated(_ text: String, limit: Int = 8_000) -> String {
        guard text.count > limit else { return text }
        return "…\n" + text.suffix(limit)
    }
}
import Foundation

enum AnyJSON: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: AnyJSON].self) { self = .object(value) }
        else { self = .array(try container.decode([AnyJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var displayText: String {
        if case .string(let value) = self { return value }
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
