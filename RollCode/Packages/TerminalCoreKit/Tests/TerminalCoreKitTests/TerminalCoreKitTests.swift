import Testing
import Foundation
@testable import TerminalCoreKit

@Suite("TerminalCoreKit Tests")
struct TerminalCoreKitTests {
    @Test("ANSIEscapeCleaner removes control sequences and carriage returns")
    func testANSIEscapeCleaner() {
        let raw = "\u{001B}[31mError:\u{001B}[0m File not found\r\n"
        let cleaned = ANSIEscapeCleaner.clean(raw)
        #expect(cleaned == "Error: File not found\n")
    }

    @Test("TerminalSession manages tabs and commands", .serialized)
    @MainActor
    func testTerminalSessionTabs() {
        let session = TerminalSession()
        #expect(session.tabs.count == 1)

        let tab2 = session.createTab(title: "Custom Tab")
        #expect(session.tabs.count == 2)
        #expect(session.activeTabID == tab2.id)

        session.selectTab(id: session.tabs[0].id)
        #expect(session.activeTabID == session.tabs[0].id)

        session.closeTab(id: tab2.id)
        #expect(session.tabs.count == 1)
        session.stop()
    }
}
