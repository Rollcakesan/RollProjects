# MCP Tool Specification: TerminalCoreKit

> **Role**: Interactive PTY / zsh shell process management, multi-tab terminal session controller, command history buffering, and ANSI escape sequence parsing.  
> **Concurrency**: `TerminalSession` and `TerminalInstance` are `@MainActor` `@Observable` classes. Sub-process standard I/O pipes are processed asynchronously.  
> **Package**: `import TerminalCoreKit`

---

## Tool Definitions

### `terminal_send_command`
- **Method**: `TerminalSession.send(_ command: String)`
- **Description**: Writes a line-terminated command string to the active terminal tab's stdin pipe, appends to the scrollback buffer, and records it in history.
- **Parameters**:
  - `command` (`String`): Shell command to execute (e.g. `swift test`).

### `terminal_create_tab`
- **Method**: `TerminalSession.createTab(in directory: URL? = nil, title: String? = nil) -> TerminalInstance`
- **Description**: Spawns a new zsh child process (`/bin/zsh -l -i`) in the specified directory, creating an isolated tab session and setting it as active.
- **Parameters**:
  - `directory` (`URL?`): Working directory for the new shell.
  - `title` (`String?`): Display title (defaults to `Terminal <N>`).
- **Returns**: Newly created `TerminalInstance`.

### `terminal_interrupt`
- **Method**: `TerminalSession.interrupt()`
- **Description**: Sends SIGINT interrupt to the running foreground process in the active terminal tab.

### `terminal_close_tab`
- **Method**: `TerminalSession.closeTab(id: UUID)`
- **Description**: Terminates the shell process associated with the tab and removes it from the session tabs list.

### `terminal_clean_ansi`
- **Method**: `ANSIEscapeCleaner.clean(_ text: String) -> String`
- **Description**: Strips ANSI escape sequences and normalizes line endings (`\r\n` -> `\n`) for clean text presentation.
- **Parameters**:
  - `text` (`String`): Raw terminal output.
- **Returns**: Cleaned plain text string.

---

## Shared Protocols

### `TerminalCommandExecuting`
Interface implemented by classes capable of receiving background commands (used across AI agents and UI toolbars):
```swift
@MainActor
public protocol TerminalCommandExecuting: AnyObject {
    var isVisible: Bool { get set }
    func send(_ command: String)
}
```

---

## Constraints & Guardrails
1. **Buffer Ceiling**: Output scrollback buffers are automatically truncated if they exceed 1,000,000 characters to prevent memory degradation.
2. **Process Cleanup**: Active sub-processes are terminated automatically on `deinit` or when calling `stop()`.
