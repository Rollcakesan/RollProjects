# LSPClientKit

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![macOS 14.0+](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A pure-Swift, zero-dependency client library for communicating with **Language Server Protocol (LSP)** servers over standard I/O (JSON-RPC 2.0).

Built for macOS code editors, IDEs, and developer tools. Provides automated binary discovery, process pooling, document synchronization (`didOpen`, `didChange`, `didClose`), auto-completion, and document formatting.

---

## 🌟 Supported Language Servers

`LSPClientKit` automatically discovers and connects to standard language servers installed via Homebrew, Xcode, Cargo, or Go:

| Language | Language Server | Auto-Discovered Commands |
| :--- | :--- | :--- |
| **Swift / C / Obj-C** | `sourcekit-lsp` | `sourcekit-lsp` (Xcode bundled) |
| **TypeScript / JavaScript** | `typescript-language-server` | `typescript-language-server --stdio` |
| **Python** | `pyright` / `pylsp` | `pyright-langserver --stdio`, `pylsp` |
| **Rust** | `rust-analyzer` | `rust-analyzer` |
| **Go** | `gopls` | `gopls` |
| **HTML / CSS / JSON** | VS Code Language Servers | `vscode-html-language-server`, `vscode-css-language-server`, `vscode-json-language-server` |
| **Shell** | `bash-language-server` | `bash-language-server start` |
| **YAML** | `yaml-language-server` | `yaml-language-server --stdio` |

---

## 📐 Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                    Your macOS App / IDE                     │
│               (e.g., RollCode, Code Editor)                 │
└──────────────────────────────┬──────────────────────────────┘
                               │ Swift Async/Await
┌──────────────────────────────▼──────────────────────────────┐
│                         LSPManager                          │
│   - Process Pooling by (Workspace Root + Server ID)         │
│   - Language Server Discovery & Resolution                  │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                         LSPClient                           │
│   - JSON-RPC 2.0 over Stdio Pipes (Content-Length Framing)  │
│   - Document Sync (didOpen / didChange / didClose)          │
│   - Position Encoding Negotiation (UTF-8, UTF-16, UTF-32)   │
│   - Completion & Formatting Response Decoders               │
└──────────────────────────────┬──────────────────────────────┘
                               │ Standard I/O (Pipes)
┌──────────────────────────────▼──────────────────────────────┐
│            sourcekit-lsp / pyright / rust-analyzer          │
└─────────────────────────────────────────────────────────────┘
```

---

## 🚀 Quickstart

```swift
import LSPClientKit

@MainActor
func requestSwiftCompletions() async {
    let manager = LSPManager.shared

    let fileURL = URL(fileURLWithPath: "/path/to/MyFile.swift")
    let sourceText = """
    import Foundation

    func test() {
        print("Hello")
    }
    """

    // Query completion suggestions at line 4, character 8
    let suggestions = await manager.requestCompletions(
        for: .swift,
        url: fileURL,
        text: sourceText,
        line: 4,
        character: 8
    )

    for item in suggestions {
        print("\(item.label) -> \(item.insertText) (\(item.detail ?? ""))")
    }
}
```

---

## 📚 API Reference

### `LSPManager`
High-level singleton managing process pools across multiple active workspace folders.

| Method | Description |
| :--- | :--- |
| `requestCompletions(for:url:text:line:character:workspaceURL:) async -> [LSPCompletionItem]` | Fetches auto-completion suggestions. |
| `formatDocument(for:url:text:tabWidth:workspaceURL:) async -> String?` | Formats the document using the language server. |
| `activateWorkspace(URL)` | Evicts inactive language server processes when switching workspaces. |
| `closeDocument(URL)` | Sends `textDocument/didClose` notification to active language servers. |
| `stopAllServers()` | Gracefully terminates all active language server background processes. |

### Data Models

#### `LSPCompletionItem`
```swift
public struct LSPCompletionItem: Hashable, Identifiable, Sendable {
    public let label: String
    public let insertText: String
    public let filterText: String
    public let detail: String?
    public let replacementRange: NSRange?
}
```
