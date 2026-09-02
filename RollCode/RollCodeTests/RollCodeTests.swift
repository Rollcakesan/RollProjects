import Foundation
import Testing
@testable import RollCode

@Suite("RollCode Test Suite")
struct RollCodeTests {
    @Test("CodexEventParser reads thread started, messages, command execution, and file changes")
    func codexEventParserReadsThreadMessagesCommandsAndChanges() throws {
        let thread = try #require(CodexEventParser.parse(
            #"{"type":"thread.started","thread_id":"thread-123"}"#
        ))
        #expect(thread == .threadStarted("thread-123"))

        let message = try #require(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"Done"}}"#
        ))
        #expect(message == .message("Done"))

        let command = try #require(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"item-2","type":"command_execution","command":"swift test","aggregated_output":"ok","exit_code":0,"status":"completed"}}"#
        ))
        guard case .activity(let commandActivity, let commandFiles) = command else {
            Issue.record("Expected a command activity")
            return
        }
        #expect(commandActivity.title == "swift test")
        #expect(commandActivity.detail == "ok")
        #expect(commandActivity.state == .completed)
        #expect(commandFiles == [])

        let change = try #require(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"item-3","type":"file_change","changes":[{"path":"/tmp/App.swift","kind":"update"}],"status":"completed"}}"#
        ))
        guard case .activity(let changeActivity, let changedFiles) = change else {
            Issue.record("Expected a file change activity")
            return
        }
        #expect(changedFiles == ["/tmp/App.swift"])
        #expect(changeActivity.state == .completed)
    }

    @Test("CodexEventParser reads usage tokens and failure events")
    func codexEventParserReadsUsageAndFailures() throws {
        let completed = try #require(CodexEventParser.parse(
            #"{"type":"turn.completed","usage":{"input_tokens":20,"cached_input_tokens":10,"output_tokens":5}}"#
        ))
        #expect(completed == .usage("20 input · 10 cached · 5 output"))

        let failed = try #require(CodexEventParser.parse(
            #"{"type":"turn.failed","error":{"message":"Authentication required"}}"#
        ))
        #expect(failed == .error("Authentication required"))
    }

    @Test("CodexEventParser decodes structured JSON tool call results")
    func codexEventParserDecodesStructuredToolResults() throws {
        let event = try #require(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"tool-1","type":"mcp_tool_call","server":"files","tool":"read","result":{"ok":true,"count":2}}}"#
        ))
        guard case .activity(let activity, _) = event else {
            Issue.record("Expected a tool activity")
            return
        }
        #expect(activity.title == "files · read")
        #expect(activity.detail.contains("\"ok\":true"))
        #expect(activity.detail.contains("\"count\":2"))
    }

    @Test("WorkspaceSnapshot detects added, changed, and deleted files")
    func workspaceSnapshotDetectsAddedChangedAndDeletedFiles() throws {
        try withTemporaryDirectory { root in
            let changed = root.appendingPathComponent("changed.txt")
            let deleted = root.appendingPathComponent("deleted.txt")
            try "before".write(to: changed, atomically: true, encoding: .utf8)
            try "delete".write(to: deleted, atomically: true, encoding: .utf8)
            let before = WorkspaceSnapshot.capture(at: root)

            try "after with a different size".write(to: changed, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: deleted)
            try "new".write(to: root.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
            let after = WorkspaceSnapshot.capture(at: root)

            #expect(before.changedFiles(comparedTo: after) == ["added.txt", "changed.txt", "deleted.txt"])
        }
    }

    @Test("AgentSession streams Codex JSON Lines and tracks state changes")
    @MainActor
    func agentSessionStreamsCodexJSONLines() async throws {
        try await withTemporaryDirectory { root in
            let executable = root.appendingPathComponent("fake-codex")
            let script = """
            #!/bin/zsh
            printf '%s\\n' '{"type":"thread.started","thread_id":"fake-thread"}'
            printf '%s\\n' '{"type":"item.completed","item":{"id":"change","type":"file_change","changes":[{"path":"Sources/App.swift","kind":"update"}],"status":"completed"}}'
            printf '%s\\n' '{"type":"item.completed","item":{"id":"message","type":"agent_message","text":"Finished"}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":3,"cached_input_tokens":1,"output_tokens":2}}'
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let agent = AgentSession(executableURL: executable)
            agent.send("Do the work", in: root)
            for _ in 0..<40 where agent.isRunning {
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            #expect(!agent.isRunning)
            #expect(agent.threadID == "fake-thread")
            #expect(agent.entries.contains { entry in
                guard case .message(let message) = entry else { return false }
                return message.role == .assistant && message.text == "Finished"
            })
            #expect(agent.entries.contains(.changes(["Sources/App.swift"])))
            #expect(agent.entries.contains(.usage("3 input · 1 cached · 2 output")))
        }
    }

    @Test(
        "Code language detection from file extension",
        arguments: [
            ("/tmp/App.swift", CodeLanguage.swift),
            ("/tmp/view.tsx", CodeLanguage.typescript),
            ("/tmp/README.md", CodeLanguage.markdown),
            ("/tmp/main.rs", CodeLanguage.rust),
            ("/tmp/config.yml", CodeLanguage.yaml),
            ("/tmp/LICENSE", CodeLanguage.plainText),
        ]
    )
    func codeLanguageDetection(path: String, expected: CodeLanguage) {
        #expect(CodeLanguage(url: URL(fileURLWithPath: path)) == expected)
    }

    @Test("FileNode.buildTree sorts directories before files and skips ignored folders")
    func treeSortsDirectoriesBeforeFilesAndSkipsHeavyFolders() throws {
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
            try "let value = 1".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

            let tree = FileNode.buildTree(at: root)
            #expect(tree.children?.map(\.name) == ["Sources", "main.swift"])
        }
    }

    @Test("FileNode.matchingFiles finds nested files case-insensitively")
    func treeFindsNestedFilesCaseInsensitively() throws {
        try withTemporaryDirectory { root in
            let sources = root.appendingPathComponent("Sources")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try "".write(to: sources.appendingPathComponent("WorkspaceModel.swift"), atomically: true, encoding: .utf8)

            let matches = FileNode.buildTree(at: root).matchingFiles("workspace")
            #expect(matches.map(\.name) == ["WorkspaceModel.swift"])
        }
    }

    @Test("QuickOpenMatcher ranks tighter fuzzy matches higher")
    func quickOpenMatcherSupportsFuzzyPathsAndRanksTighterMatchesHigher() {
        let tight = QuickOpenMatcher.score(query: "wsm", candidate: "WorkspaceModel.swift")
        let loose = QuickOpenMatcher.score(query: "wsm", candidate: "Views/WorkspaceMenu.swift")

        #expect(tight != nil)
        #expect(loose != nil)
        #expect((tight ?? 0) > (loose ?? 0))
        #expect(QuickOpenMatcher.score(query: "xyz", candidate: "WorkspaceModel.swift") == nil)
    }

    @Test("EditorSmartEditing auto-closes pairs and wraps selected ranges")
    func smartEditingPairsAndWrapsCharacters() throws {
        let emptyPair = try #require(EditorSmartEditing.edit(for: "(", in: "", range: NSRange(location: 0, length: 0)))
        #expect(emptyPair.replacement == "()")
        #expect(emptyPair.selection == NSRange(location: 1, length: 0))

        let wrapped = try #require(EditorSmartEditing.edit(for: "{", in: "value", range: NSRange(location: 0, length: 5)))
        #expect(wrapped.replacement == "{value}")
        #expect(wrapped.selection == NSRange(location: 1, length: 5))

        let skipClosing = try #require(EditorSmartEditing.edit(for: ")", in: "()", range: NSRange(location: 1, length: 0)))
        #expect(skipClosing.replacement == "")
        #expect(skipClosing.selection.location == 2)
    }

    @Test("EditorSmartEditing automatically indents new lines and expands empty blocks")
    func smartEditingIndentsNewLinesAndExpandsEmptyBlocks() throws {
        let indented = try #require(EditorSmartEditing.edit(
            for: "\n",
            in: "    let value = {",
            range: NSRange(location: 17, length: 0)
        ))
        #expect(indented.replacement == "\n        ")

        let block = try #require(EditorSmartEditing.edit(
            for: "\n",
            in: "{}",
            range: NSRange(location: 1, length: 0)
        ))
        #expect(block.replacement == "\n    \n")
        #expect(block.selection.location == 6)

        let twoSpaces = try #require(EditorSmartEditing.edit(
            for: "\n",
            in: "{}",
            range: NSRange(location: 1, length: 0),
            tabWidth: 2
        ))
        #expect(twoSpaces.replacement == "\n  \n")
        #expect(twoSpaces.selection.location == 4)
    }

    @Test("WorkspaceModel opens, modifies, and saves text files")
    @MainActor
    func workspaceOpensAndSavesTextFile() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("note.txt")
            try "before".write(to: file, atomically: true, encoding: .utf8)

            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openFile(file)
            #expect(workspace.activeDocument?.text == "before")
            workspace.activeDocument?.text = "after"
            #expect(workspace.activeDocument?.isDirty == true)
            #expect(workspace.saveAllDocuments())
            #expect(try String(contentsOf: file, encoding: .utf8) == "after")
        }
    }

    @Test("WorkspaceModel reloads clean files changed externally on disk")
    @MainActor
    func workspaceReloadsCleanFileChangedOnDisk() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("external.txt")
            try "before".write(to: file, atomically: true, encoding: .utf8)

            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openFile(file)
            try "after".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(2)],
                ofItemAtPath: file.path
            )
            workspace.checkForExternalChanges()

            #expect(workspace.activeDocument?.text == "after")
            #expect(workspace.activeDocument?.isDirty == false)
        }
    }

    @Test("WorkspaceModel renames open file and updates document URL with Typed Throws")
    @MainActor
    func workspaceRenamesOpenFileAndUpdatesDocumentURL() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("old.swift")
            let destination = root.appendingPathComponent("new.swift")
            try "let value = 1".write(to: source, atomically: true, encoding: .utf8)

            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openFile(source)
            try workspace.renameItem(at: source, to: "new.swift")

            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(workspace.activeDocument?.url == destination)
        }
    }

    @Test("TerminalSession executes command and delivers output in workspace")
    @MainActor
    func terminalExecutesCommandInWorkspace() async throws {
        try await withTemporaryDirectory { directory in
            let terminal = TerminalSession()
            terminal.start(in: directory)
            defer { terminal.stop() }
            #expect(terminal.isRunning)

            terminal.send("printf '%s\\n' \"$((40 + 2))\"")
            for _ in 0..<30 where !terminal.output.contains("42") {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(terminal.output.contains("42"))
        }
    }

    // @Test("TerminalSession interrupts running foreground command with Ctrl+C")
    @MainActor
    func terminalInterruptsForegroundCommand() async throws {
        try await withTemporaryDirectory { directory in
            let terminal = TerminalSession()
            terminal.start(in: directory)
            defer { terminal.stop() }

            terminal.send("sleep 5")
            try await Task.sleep(nanoseconds: 100_000_000)
            terminal.interrupt()
            terminal.send("printf '%s\\n' \"$((60 + 3))\"")

            for _ in 0..<40 where !terminal.output.contains("63") {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(terminal.output.contains("63"))
        }
    }

    @Test("TerminalSession command history moves backward and forward")
    @MainActor
    func terminalCommandHistoryMovesBackwardAndForward() {
        let terminal = TerminalSession()
        terminal.send("first")
        terminal.send("second")

        #expect(terminal.previousCommand() == "second")
        #expect(terminal.previousCommand() == "first")
        #expect(terminal.nextCommand() == "second")
        #expect(terminal.nextCommand() == "")
    }

    @Test("WorkspaceModel persists and restores last opened folder")
    @MainActor
    func workspacePersistsAndRestoresLastFolder() throws {
        let suiteName = "RollCodeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try withTemporaryDirectory { root in
            let firstWorkspace = WorkspaceModel(defaults: defaults, restoresLastWorkspace: false)
            firstWorkspace.openWorkspace(root)
            let restoredWorkspace = WorkspaceModel(defaults: defaults)

            #expect(restoredWorkspace.rootURL == root.standardizedFileURL)
        }
    }
}

@MainActor
private func withTemporaryDirectory<T>(_ operation: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await operation(root)
}

private func withTemporaryDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try operation(root)
}
