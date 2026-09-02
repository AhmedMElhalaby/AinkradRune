import Testing
import SwiftTerm
@testable import TerminalFeature

/// Proves the bell override is actually wired, rather than assuming it because
/// the code reads correctly.
///
/// `LocalProcessTerminalView` forwards only four callbacks to its
/// `processDelegate`, and `bell` is not one of them — so this behaviour exists
/// only because `AinkradTerminalView` overrides it. If a SwiftTerm bump ever
/// changes that method's shape, the override silently stops being an override
/// and the terminal goes quiet again. This test fails when that happens.
@MainActor
@Suite("Terminal bell capture")
struct AinkradTerminalViewBellTests {
    @Test("a bell from the terminal reaches onBell")
    func bellReachesTheHandler() {
        let view = AinkradTerminalView(frame: .zero)
        var rang = 0
        view.onBell = { rang += 1 }

        view.bell(source: view.getTerminal())
        #expect(rang == 1)

        view.bell(source: view.getTerminal())
        #expect(rang == 2, "every bell counts; coalescing is the feed's job, not the view's")
    }

    @Test("a view with no handler does not crash on a bell")
    func bellWithoutHandlerIsSafe() {
        let view = AinkradTerminalView(frame: .zero)
        view.bell(source: view.getTerminal())
        #expect(view.onBell == nil)
    }
}
