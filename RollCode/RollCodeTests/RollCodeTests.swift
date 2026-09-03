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

    @Test("WorkspaceSearch finds case-insensitive matches by line and replaces literal text")
    func workspaceSearchFindsAndReplacesLiteralText() throws {
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let first = WorkspaceSearchFile(
            url: root.appendingPathComponent("Sources/App.swift"),
            text: "let value = RollCode\n// rollcode and RollCode"
        )
        let second = WorkspaceSearchFile(
            url: root.appendingPathComponent("README.md"),
            text: "Nothing here"
        )

        let matches = WorkspaceSearch.matches(for: "rollcode", in: [first, second], relativeTo: root)
        #expect(matches.map(\.line) == [1, 2])
        #expect(matches.map(\.occurrences) == [1, 2])
        #expect(matches.first?.relativePath == "Sources/App.swift")

        let replacements = WorkspaceSearch.replacements(
            of: "RollCode",
            with: "$EDITOR\\name",
            in: [first, second]
        )
        let replacement = try #require(replacements.first)
        #expect(replacement.occurrences == 3)
        #expect(replacement.text == "let value = $EDITOR\\name\n// $EDITOR\\name and $EDITOR\\name")
    }

    @Test("GitDiffService returns tracked and untracked changes")
    func gitDiffServiceReturnsWorkingTreeChanges() throws {
        try withTemporaryDirectory { root in
            try runGit(["init", "--quiet"], in: root)
            try runGit(["config", "user.email", "rollcode@example.com"], in: root)
            try runGit(["config", "user.name", "RollCode Tests"], in: root)

            let tracked = root.appendingPathComponent("tracked.txt")
            try "before\n".write(to: tracked, atomically: true, encoding: .utf8)
            try runGit(["add", "tracked.txt"], in: root)
            try runGit(["commit", "--quiet", "-m", "Initial"], in: root)

            try "after\n".write(to: tracked, atomically: true, encoding: .utf8)
            try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

            let changes = try GitDiffService.changes(in: root)
            #expect(changes.map(\.path) == ["new.txt", "tracked.txt"])
            #expect(changes.first(where: { $0.path == "tracked.txt" })?.diff.contains("+after") == true)
            #expect(changes.first(where: { $0.path == "new.txt" })?.diff.contains("new file mode") == true)
        }
    }

    @Test("GitDiffService shows staged files before the first commit")
    func gitDiffServiceSupportsRepositoryWithoutHead() throws {
        try withTemporaryDirectory { root in
            try runGit(["init", "--quiet"], in: root)
            let file = root.appending(path: "first.txt")
            try "first".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", "first.txt"], in: root)

            let changes = try GitDiffService.changes(in: root)
            #expect(changes.map(\.path) == ["first.txt"])
            #expect(changes.first?.diff.contains("+first") == true)
        }
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

    @Test("WorkspaceModel manages and persists font size zoom levels")
    @MainActor
    func workspaceManagesFontSizeZoom() throws {
        let suiteName = "RollCodeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = WorkspaceModel(defaults: defaults, restoresLastWorkspace: false)
        #expect(workspace.fontSize == 12.5)

        workspace.zoomIn()
        #expect(workspace.fontSize == 13.5)

        workspace.zoomOut()
        workspace.zoomOut()
        #expect(workspace.fontSize == 11.5)

        workspace.resetZoom()
        #expect(workspace.fontSize == 12.5)

        workspace.setFontSize(35)
        #expect(workspace.fontSize == 32)

        workspace.setFontSize(5)
        #expect(workspace.fontSize == 9)

        let restored = WorkspaceModel(defaults: defaults, restoresLastWorkspace: false)
        #expect(restored.fontSize == 9)
    }

    @Test("WorkspaceModel creates files and folders and moves to Trash")
    @MainActor
    func workspaceCreatesAndDeletesItems() throws {
        try withTemporaryDirectory { root in
            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openWorkspace(root)

            workspace.requestCreateFile(in: root)
            workspace.creatingItemName = "test.swift"
            workspace.confirmCreateItem()

            let createdFile = root.appendingPathComponent("test.swift")
            #expect(FileManager.default.fileExists(atPath: createdFile.path))
            #expect(workspace.activeDocument?.url == createdFile)

            workspace.requestCreateFolder(in: root)
            workspace.creatingItemName = "Subfolder"
            workspace.confirmCreateItem()

            let createdFolder = root.appendingPathComponent("Subfolder")
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: createdFolder.path, isDirectory: &isDir) && isDir.boolValue)

            workspace.requestDeleteItem(at: createdFile)
            #expect(FileManager.default.fileExists(atPath: createdFile.path))
            workspace.confirmDeleteItem()
            #expect(!FileManager.default.fileExists(atPath: createdFile.path))
            #expect(workspace.activeDocument == nil)
        }
    }

    @Test("WorkspaceModel does not trash an open file with unsaved changes")
    @MainActor
    func workspaceProtectsDirtyFileFromDeletion() throws {
        try withTemporaryDirectory { root in
            let file = root.appending(path: "dirty.txt")
            try "saved".write(to: file, atomically: true, encoding: .utf8)
            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openFile(file)
            workspace.activeDocument?.text = "unsaved"

            workspace.requestDeleteItem(at: file)
            workspace.confirmDeleteItem()

            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(workspace.activeDocument?.text == "unsaved")
            #expect(workspace.alertMessage != nil)
        }
    }

    @Test("GitDiffService commits changes and updates status")
    func gitDiffServiceCommitsChanges() throws {
        try withTemporaryDirectory { root in
            try runGit(["init"], in: root)
            try runGit(["config", "user.email", "tester@example.com"], in: root)
            try runGit(["config", "user.name", "Tester"], in: root)

            let testFile = root.appendingPathComponent("file.txt")
            try "hello".write(to: testFile, atomically: true, encoding: .utf8)

            let changesBefore = try GitDiffService.changes(in: root)
            #expect(!changesBefore.isEmpty)

            try GitDiffService.commit(in: root, message: "Initial commit")

            let changesAfter = try GitDiffService.changes(in: root)
            #expect(changesAfter.isEmpty)
        }
    }

    @Test("GitDiffService limits changes and commits to an opened repository subfolder")
    func gitDiffServiceScopesOperationsToWorkspace() throws {
        try withTemporaryDirectory { root in
            try runGit(["init", "--quiet"], in: root)
            try runGit(["config", "user.email", "tester@example.com"], in: root)
            try runGit(["config", "user.name", "Tester"], in: root)
            let subfolder = root.appending(path: "Subproject")
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
            let outside = root.appending(path: "outside.txt")
            let inside = subfolder.appending(path: "inside.txt")
            try "base".write(to: outside, atomically: true, encoding: .utf8)
            try "base".write(to: inside, atomically: true, encoding: .utf8)
            try runGit(["add", "-A"], in: root)
            try runGit(["commit", "--quiet", "-m", "Base"], in: root)

            try "outside change".write(to: outside, atomically: true, encoding: .utf8)
            try "inside change".write(to: inside, atomically: true, encoding: .utf8)

            let changes = try GitDiffService.changes(in: subfolder)
            #expect(changes.map(\.path) == ["inside.txt"])
            #expect(changes.first?.diff.contains("+inside change") == true)

            try GitDiffService.commit(in: subfolder, message: "Update subproject")
            #expect(try GitDiffService.changes(in: subfolder).isEmpty)
            #expect(try GitDiffService.changedPaths(in: root) == ["outside.txt"])
            #expect(try runGitOutput(["show", "--pretty=format:", "--name-only", "HEAD"], in: root).trimmed == "Subproject/inside.txt")
        }
    }

    @Test("GitDiffService restores staging state when commit fails")
    func gitDiffServiceRestoresIndexAfterFailedCommit() throws {
        try withTemporaryDirectory { root in
            try runGit(["init", "--quiet"], in: root)
            try runGit(["config", "user.email", "tester@example.com"], in: root)
            try runGit(["config", "user.name", "Tester"], in: root)
            let file = root.appending(path: "file.txt")
            try "base".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", "-A"], in: root)
            try runGit(["commit", "--quiet", "-m", "Base"], in: root)

            try "changed".write(to: file, atomically: true, encoding: .utf8)
            let hook = root.appending(path: ".git/hooks/pre-commit")
            try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

            #expect(throws: GitDiffError.self) {
                try GitDiffService.commit(in: root, message: "Rejected")
            }
            #expect(try runGitOutput(["diff", "--cached", "--name-only"], in: root).trimmed.isEmpty)
            #expect(try GitDiffService.changedPaths(in: root) == ["file.txt"])
        }
    }

    @Test("WorkspaceModel saves edited documents before Git commit")
    @MainActor
    func workspaceSavesDocumentsBeforeGitCommit() async throws {
        try await withTemporaryDirectory { root in
            try runGit(["init", "--quiet"], in: root)
            try runGit(["config", "user.email", "tester@example.com"], in: root)
            try runGit(["config", "user.name", "Tester"], in: root)
            let file = root.appending(path: "file.txt")
            try "base".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", "-A"], in: root)
            try runGit(["commit", "--quiet", "-m", "Base"], in: root)

            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openWorkspace(root)
            workspace.openFile(file)
            workspace.activeDocument?.text = "editor change"

            try await workspace.gitCommit(message: "Save editor change")

            #expect(try String(contentsOf: file, encoding: .utf8) == "editor change")
            #expect(workspace.activeDocument?.isDirty == false)
            #expect(try GitDiffService.changedPaths(in: root).isEmpty)
        }
    }

    @Test("WorkspaceModel keeps Save As bound to the initiating document")
    @MainActor
    func workspaceSaveAsKeepsOriginalDocument() throws {
        try withTemporaryDirectory { root in
            let firstURL = root.appending(path: "first.txt")
            let secondURL = root.appending(path: "second.txt")
            let destination = root.appending(path: "renamed.txt")
            try "first".write(to: firstURL, atomically: true, encoding: .utf8)
            try "second".write(to: secondURL, atomically: true, encoding: .utf8)
            try "first".write(to: destination, atomically: true, encoding: .utf8)

            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openFile(firstURL)
            let firstDocument = try #require(workspace.activeDocument)
            workspace.saveActiveDocumentAs()
            workspace.openFile(secondURL)

            workspace.completeSaveActiveDocumentAs(destination: destination)

            #expect(firstDocument.url == destination)
            #expect(workspace.activeDocument?.url == secondURL)
        }
    }

    @Test("WorkspaceModel safely prompts for unsaved document on close")
    @MainActor
    func workspacePromptsForUnsavedDocumentOnClose() throws {
        try withTemporaryDirectory { root in
            let file = root.appending(path: "dirty.txt")
            try "initial".write(to: file, atomically: true, encoding: .utf8)

            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openFile(file)
            let doc = try #require(workspace.activeDocument)
            doc.text = "modified"

            workspace.closeDocument(doc)
            #expect(workspace.unconfirmedClosingDocument?.id == doc.id)
            #expect(workspace.documents.count == 1)

            workspace.cancelCloseDocument()
            #expect(workspace.unconfirmedClosingDocument == nil)
            #expect(workspace.documents.count == 1)

            workspace.closeDocument(doc)
            workspace.confirmCloseDocument(save: true)
            #expect(workspace.unconfirmedClosingDocument == nil)
            #expect(workspace.documents.isEmpty)
            #expect(try String(contentsOf: file, encoding: .utf8) == "modified")
        }
    }

    @Test("WorkspaceModel handles external change conflicts without blocking")
    @MainActor
    func workspaceHandlesExternalChangeConflict() throws {
        try withTemporaryDirectory { root in
            let file = root.appending(path: "conflict.txt")
            try "disk original".write(to: file, atomically: true, encoding: .utf8)

            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openFile(file)
            let doc = try #require(workspace.activeDocument)
            doc.text = "editor edit"

            try "disk modified".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(2)],
                ofItemAtPath: file.path
            )

            workspace.checkForExternalChanges()
            #expect(workspace.externalConflict?.documentID == doc.id)
            #expect(workspace.externalConflict?.diskText == "disk modified")
            #expect(doc.text == "editor edit")

            workspace.resolveExternalConflict(reload: true)
            #expect(workspace.externalConflict == nil)
            #expect(doc.text == "disk modified")
        }
    }

    @Test("CodexAuthService parses ChatGPT login mode and credentials")
    @MainActor
    func codexAuthServiceParsesChatGPTLogin() throws {
        try withTemporaryDirectory { root in
            let authFile = root.appending(path: "auth.json")
            let payload = """
            {"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20iLCJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9wbGFuX3R5cGUiOiJwbHVzIn19.signature","access_token":"mock"}}
            """
            try payload.write(to: authFile, atomically: true, encoding: .utf8)

            let service = CodexAuthService(authFileURL: authFile, isCLIAvailable: { true })
            #expect(service.status == .loggedIn(mode: "ChatGPT", email: "test@example.com", plan: "plus"))
            #expect(service.status.displayText == "test@example.com (Plus)")
        }
    }

    @Test("CodexAuthService detects API key authentication")
    @MainActor
    func codexAuthServiceDetectsAPIKey() throws {
        try withTemporaryDirectory { root in
            let authFile = root.appending(path: "auth.json")
            let payload = """
            {"OPENAI_API_KEY":"sk-proj-test1234"}
            """
            try payload.write(to: authFile, atomically: true, encoding: .utf8)

            let service = CodexAuthService(authFileURL: authFile, isCLIAvailable: { true })
            #expect(service.status == .apiKey)
            #expect(service.status.displayText == "API Key")
        }
    }

    @Test("AgentSession supports multiple threads and switching")
    @MainActor
    func agentSessionSupportsMultipleThreads() throws {
        let session = AgentSession(executableURL: nil)
        #expect(session.entries.isEmpty)
        #expect(session.threads.isEmpty)

        session.entries = [.message(AgentMessage(role: .user, text: "First question"))]
        let firstThreadID = session.activeThread.id

        session.newThread()
        #expect(session.entries.isEmpty)
        #expect(session.threads.count == 1)
        #expect(session.threads.first?.id == firstThreadID)

        session.entries = [.message(AgentMessage(role: .user, text: "Second question"))]

        let firstThread = session.threads.first!
        session.switchToThread(firstThread)
        #expect(session.activeThread.id == firstThreadID)
        #expect(session.entries.count == 1)
        #expect(session.threads.count == 2)
    }

    @Test("AgentSession resumes past Codex session into new thread")
    @MainActor
    func agentSessionResumesPastCodexSession() throws {
        let session = AgentSession(executableURL: nil)
        let past = CodexSessionSummary(id: "test-thread-123", threadName: "Past Discussion", updatedAt: Date())
        session.resumePastCodexSession(past)

        #expect(session.threadID == "test-thread-123")
        #expect(session.activeThreadTitle == "Past Discussion")
        #expect(session.entries.count == 1)
    }

    @Test("AgentSession toggles between latest Codex and Gemini threads independently")
    @MainActor
    func agentSessionTogglesBetweenProviders() throws {
        let session = AgentSession(executableURL: nil, geminiExecutableURL: nil)
        #expect(session.selectedProvider == .codex)

        session.entries = [.message(AgentMessage(role: .user, text: "Codex prompt"))]
        #expect(session.entries.count == 1)

        session.selectProvider(.gemini)
        #expect(session.selectedProvider == .gemini)
        #expect(session.entries.isEmpty)

        session.entries = [.message(AgentMessage(role: .user, text: "Gemini prompt"))]
        #expect(session.entries.count == 1)

        session.selectProvider(.codex)
        #expect(session.selectedProvider == .codex)
        #expect(session.entries.count == 1)
        if case .message(let msg) = session.entries.first {
            #expect(msg.text == "Codex prompt")
        } else {
            Issue.record("Expected Codex message")
        }

        session.selectProvider(.gemini)
        #expect(session.entries.count == 1)
        if case .message(let msg) = session.entries.first {
            #expect(msg.text == "Gemini prompt")
        } else {
            Issue.record("Expected Gemini message")
        }
    }

    @Test("CodexEventParser ignores deprecation warning error items")
    func codexEventParserIgnoresDeprecationWarnings() {
        let line = """
        {"type":"item.completed","item":{"id":"item_0","type":"error","message":"`[features].web_search_request` is deprecated because web search is enabled by default."}}
        """
        let event = CodexEventParser.parse(line)
        #expect(event == nil)
    }

    @Test("WorkspaceModel manages restoreLastWorkspace preference and restores workspace on launch")
    @MainActor
    func workspaceRestoresLastWorkspacePreference() throws {
        try withTemporaryDirectory { root in
            let defaults = UserDefaults(suiteName: "TestWorkspaceDefaults_\(UUID().uuidString)")!
            let workspace = WorkspaceModel(defaults: defaults, restoresLastWorkspace: true)
            #expect(workspace.restoresLastWorkspace == true)

            workspace.openWorkspace(root)
            #expect(workspace.lastWorkspacePath == root.standardizedFileURL.path)

            workspace.setRestoresLastWorkspace(false)
            #expect(workspace.restoresLastWorkspace == false)

            // When disabled, a new instance should not reopen
            let reopenedDisabled = WorkspaceModel(defaults: defaults, restoresLastWorkspace: true)
            #expect(reopenedDisabled.rootURL == nil)

            // When re-enabled, a new instance should reopen the last project
            reopenedDisabled.setRestoresLastWorkspace(true)
            let reopenedEnabled = WorkspaceModel(defaults: defaults, restoresLastWorkspace: true)
            #expect(reopenedEnabled.rootURL?.path == root.standardizedFileURL.path)
        }
    }

    @Test("AgentSession persists and restores conversation threads for a workspace")
    @MainActor
    func agentSessionPersistsThreadsAcrossSessions() throws {
        try withTemporaryDirectory { root in
            let session1 = AgentSession(executableURL: nil, geminiExecutableURL: nil)
            session1.loadThreads(for: root)
            #expect(session1.entries.isEmpty)

            session1.entries.append(.message(AgentMessage(role: .user, text: "Hello AI")))
            session1.entries.append(.message(AgentMessage(role: .assistant, text: "Hello User")))
            session1.saveCurrentThreads()

            let session2 = AgentSession(executableURL: nil, geminiExecutableURL: nil)
            session2.loadThreads(for: root)
            #expect(session2.entries.count == 2)
            if case .message(let userMsg) = session2.entries.first {
                #expect(userMsg.text == "Hello AI")
            }
            if case .message(let botMsg) = session2.entries.last {
                #expect(botMsg.text == "Hello User")
            }
        }
    }

    @Test("TerminalSession manages multiple tabs and tab switching")
    @MainActor
    func terminalSessionManagesMultipleTabs() {
        let terminal = TerminalSession()
        #expect(terminal.tabs.count == 1)
        let firstTab = terminal.tabs[0]
        #expect(terminal.activeTabID == firstTab.id)

        let secondTab = terminal.createTab(title: "Build Task")
        #expect(terminal.tabs.count == 2)
        #expect(terminal.activeTabID == secondTab.id)
        #expect(terminal.activeTab?.id == secondTab.id)

        terminal.selectTab(id: firstTab.id)
        #expect(terminal.activeTabID == firstTab.id)

        terminal.closeTab(id: firstTab.id)
        #expect(terminal.tabs.count == 1)
        #expect(terminal.activeTabID == secondTab.id)
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

private func runGit(_ arguments: [String], in directory: URL) throws {
    _ = try runGitOutput(arguments, in: directory)
}

private func runGitOutput(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitDiffError.commandFailed(String(decoding: data, as: UTF8.self))
    }
    return String(decoding: data, as: UTF8.self)
}
