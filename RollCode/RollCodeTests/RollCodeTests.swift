import XCTest
@testable import RollCode

final class RollCodeTests: XCTestCase {
    func testCodeLanguageDetection() {
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/App.swift")), .swift)
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/view.tsx")), .typescript)
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/README.md")), .markdown)
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/main.rs")), .rust)
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/config.yml")), .yaml)
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/LICENSE")), .plainText)
    }

    func testTreeSortsDirectoriesBeforeFilesAndSkipsHeavyFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "let value = 1".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let tree = FileNode.buildTree(at: root)
        XCTAssertEqual(tree.children?.map(\.name), ["Sources", "main.swift"])
    }

    func testTreeFindsNestedFilesCaseInsensitively() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "".write(to: sources.appendingPathComponent("WorkspaceModel.swift"), atomically: true, encoding: .utf8)

        let matches = FileNode.buildTree(at: root).matchingFiles("workspace")
        XCTAssertEqual(matches.map(\.name), ["WorkspaceModel.swift"])
    }

    @MainActor
    func testWorkspaceOpensAndSavesTextFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)

        let workspace = WorkspaceModel()
        workspace.openFile(file)
        XCTAssertEqual(workspace.activeDocument?.text, "before")
        workspace.activeDocument?.text = "after"
        XCTAssertTrue(workspace.activeDocument?.isDirty == true)
        XCTAssertTrue(workspace.saveAllDocuments())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after")
    }

    @MainActor
    func testTerminalExecutesCommandInWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory
        let terminal = TerminalSession()
        terminal.start(in: directory)
        defer { terminal.stop() }
        XCTAssertTrue(terminal.isRunning)

        terminal.send("printf '%s\\n' \"$((40 + 2))\"")
        for _ in 0..<30 where !terminal.output.contains("\n42\n") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(terminal.output.contains("\n42\n"))
    }
}
