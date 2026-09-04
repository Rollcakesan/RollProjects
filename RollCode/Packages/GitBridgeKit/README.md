# GitBridgeKit

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![macOS 14.0+](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A lightweight, zero-dependency Swift package for inspecting, parsing, and committing Git repository changes.

Designed for IDEs, text editors, and developer tools that need unified diff line numbering (for gutter markers), status inspection, and safe staging transactions with rollback on failure.

---

## 🌟 Key Features

- **Safe Commit Transactions**: Automatically captures a snapshot of the Git index (`.git/index`) prior to staging and restores it atomically if committing fails.
- **Subfolder / Monorepo Aware**: Correctly handles workspaces opened at a subfolder of a repository, scoping diffs and commits to that specific folder.
- **Diff Line Number Parsing**: Parses unified diff hunks (`@@ -1,3 +1,5 @@`) into concrete 1-based line numbers for real-time editor gutter markers (added/modified lines).
- **Null-Delimited Fast Status**: Parses `git status --porcelain=v1 -z` to safely handle filenames with spaces, unicode, or special characters.
- **Zero Dependencies**: Requires only macOS Foundation and `/usr/bin/git`.

---

## 🚀 Quickstart

```swift
import GitBridgeKit

let workspaceURL = URL(fileURLWithPath: "/path/to/repo")

// 1. Inspect all modifications (staged, unstaged, untracked)
let changes = try GitBridgeService.changes(in: workspaceURL)
for change in changes {
    print("\(change.status): \(change.path)")
    
    // 2. Compute gutter line markers for each modified file
    let (addedLines, modifiedLines) = GitBridgeService.diffLineNumbers(for: change.diff)
    print("Added lines in editor: \(addedLines)")
}

// 3. Commit changes with automatic rollback on error
do {
    try GitBridgeService.commit(in: workspaceURL, message: "feat: add new feature")
    print("Committed successfully!")
} catch {
    print("Commit failed: \(error)")
}
```

---

## 📚 API Reference

### `GitBridgeService`

| Method | Description |
| :--- | :--- |
| `changes(in: URL) throws -> [GitChange]` | Returns all modified, added, and untracked files with full diffs. |
| `changedPaths(in: URL) throws -> [String]` | Fast query returning just the list of changed relative file paths. |
| `diffLineNumbers(for: String) -> (added: Set<Int>, modified: Set<Int>)` | Extracts 1-indexed line numbers for editor gutter highlights. |
| `commit(in: URL, message: String) throws` | Stages files within the workspace root and executes `git commit`. |

### Data Models

#### `GitChange`
```swift
public struct GitChange: Identifiable, Sendable, Equatable {
    public let path: String    // Workspace-relative file path
    public let status: String  // Porcelain status (e.g., " M", "A ", "??")
    public let diff: String    // Full unified diff output
}
```
