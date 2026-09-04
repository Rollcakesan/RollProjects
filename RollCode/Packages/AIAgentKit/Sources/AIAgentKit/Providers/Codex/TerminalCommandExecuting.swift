import Foundation

@MainActor
public protocol TerminalCommandExecuting: AnyObject {
    var isVisible: Bool { get set }
    func send(_ command: String)
}
