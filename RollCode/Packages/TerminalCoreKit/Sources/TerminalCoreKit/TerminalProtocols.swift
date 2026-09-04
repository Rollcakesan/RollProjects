import Foundation

/// Defines an interface for components capable of dispatching shell commands to an active terminal session.
@MainActor
public protocol TerminalCommandExecuting: AnyObject {
    var isVisible: Bool { get set }
    func send(_ command: String)
}

/// ANSI control sequence cleaning utilities.
public enum ANSIEscapeCleaner: Sendable {
    nonisolated(unsafe) private static let controlSequence = #/\u{001B}(?:\[[0-?]*[ -/]*[@-~]|\][^\u{0007}]*(?:\u{0007}|\u{001B}\\))/#

    public static func clean(_ text: String) -> String {
        text.replacing(controlSequence, with: "")
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "")
    }

    public static func stripEscapes(from text: String) -> String {
        text.replacing(controlSequence, with: "")
    }
}
