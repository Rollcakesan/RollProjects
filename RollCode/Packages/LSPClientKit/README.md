# MCP Tool Specification: LSPClientKit

> **Role**: Language Server Protocol (JSON-RPC 2.0 stdio) manager for code intelligence (completions, formatting, document synchronization).  
> **Concurrency**: Managed by `@MainActor` singleton `LSPManager.shared`. Background server tasks run on isolated sub-processes.  
> **Package**: `import LSPClientKit`

---

## Tool Definitions

### `lsp_request_completions`
- **Method**: `LSPManager.shared.requestCompletions(for: LSPDocumentLanguage, url: URL, text: String, line: Int, character: Int, workspaceURL: URL? = nil) async -> [LSPCompletionItem]`
- **Description**: Requests code completion items at a specific 0-based line/character cursor position. Synchronizes document content with the LSP server via `didOpen`/`didChange` before querying.
- **Parameters**:
  - `for` (`LSPDocumentLanguage`): Target language (`.swift`, `.typescript`, `.python`, `.rust`, `.go`, etc.).
  - `url` (`URL`): Document file URL.
  - `text` (`String`): Current buffer snapshot.
  - `line` (`Int`): 0-based line index.
  - `character` (`Int`): 0-based UTF-16 character offset.
  - `workspaceURL` (`URL?`): Optional workspace root; falls back to parent directory of `url`.
- **Returns**: `[LSPCompletionItem]`
  - `label` (`String`): Display name in autocomplete popup.
  - `insertText` (`String`): Text to insert into editor.
  - `filterText` (`String?`): Custom prefix match query.
  - `detail` (`String?`): Type signature or short documentation.
  - `replacementRange` (`NSRange?`): Range in editor buffer to replace.

### `lsp_format_document`
- **Method**: `LSPManager.shared.formatDocument(for: LSPDocumentLanguage, url: URL, text: String, tabWidth: Int, workspaceURL: URL? = nil) async -> String?`
- **Description**: Formats the entire document using the active language server (`textDocument/formatting`). Returns the transformed text, or `nil` if formatting failed or is unsupported.
- **Parameters**:
  - `for` (`LSPDocumentLanguage`): Target language enum.
  - `url` (`URL`): Document file URL.
  - `text` (`String`): Current buffer content.
  - `tabWidth` (`Int`): Indentation spaces (e.g. 2 or 4).
  - `workspaceURL` (`URL?`): Workspace root directory.
- **Returns**: `String?` (formatted source string or `nil`).

### `lsp_close_document`
- **Method**: `LSPManager.shared.closeDocument(_ url: URL)`
- **Description**: Emits `textDocument/didClose` across all active language servers to free server-side document buffers.
- **Parameters**:
  - `url` (`URL`): Document file URL.

### `lsp_activate_workspace`
- **Method**: `LSPManager.shared.activateWorkspace(_ workspaceURL: URL)`
- **Description**: Evicts and terminates language server processes whose root path does not match `workspaceURL`.

### `lsp_stop_all_servers`
- **Method**: `LSPManager.shared.stopAllServers()`
- **Description**: Gracefully shuts down all active background LSP server processes (`shutdown` followed by `exit`).

---

## Language Support & Auto-Discovery

Auto-discovers binaries via standard PATH and developer tools:
- **Swift / C-Family**: `sourcekit-lsp` (Xcode bundled / toolchains)
- **TypeScript / JavaScript**: `typescript-language-server`
- **Python**: `pyright-langserver`, `pylsp`
- **Rust**: `rust-analyzer`
- **Go**: `gopls`
- **HTML / CSS / JSON**: `vscode-*-language-server`
- **Shell**: `bash-language-server`
- **YAML**: `yaml-language-server`

---

## Constraints & Guardrails
1. **Position Encoding**: LSP uses 0-based UTF-16 code unit offsets for `character`.
2. **Process Isolation**: Servers run in child processes with dedicated stdin/stdout pipes and automatic zombie cleanup on deinit.
