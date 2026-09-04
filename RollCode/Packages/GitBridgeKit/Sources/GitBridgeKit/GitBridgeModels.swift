import Foundation

/// Represents a detected change in a Git working tree.
public struct GitChange: Identifiable, Sendable, Equatable {
    public let path: String
    public let status: String
    public let diff: String

    public var id: String { path }

    public init(path: String, status: String, diff: String) {
        self.path = path
        self.status = status
        self.diff = diff
    }
}

/// Errors thrown by `GitBridgeService`.
public enum GitDiffError: LocalizedError, Sendable, Equatable {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        }
    }
}
