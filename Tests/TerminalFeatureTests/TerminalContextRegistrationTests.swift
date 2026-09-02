import Testing
import Foundation
import AinkradAppKit
@testable import TerminalFeature

@Suite("TerminalContextRegistration")
@MainActor
struct TerminalContextRegistrationTests {
    @Test("same host returns the same bridge (get-or-create)")
    func sameHostSameBridge() {
        let host = FakeHostServices(context: RecordingContextRegistry())
        let a = TerminalRuntime.contextBridge(for: host)
        let b = TerminalRuntime.contextBridge(for: host)
        #expect(a === b)
    }

    @Test("registers exactly one source with the host")
    func registersOnce() {
        let registry = RecordingContextRegistry()
        let host = FakeHostServices(context: registry)
        _ = TerminalRuntime.contextBridge(for: host)
        _ = TerminalRuntime.contextBridge(for: host)   // second call must not re-register
        #expect(registry.sources.count == 1)
    }

    @Test("the registered source returns the bridge's live snapshot")
    func registeredSourceReflectsBridge() {
        let registry = RecordingContextRegistry()
        let host = FakeHostServices(context: registry)
        let bridge = TerminalRuntime.contextBridge(for: host)

        #expect(registry.snapshots().isEmpty)          // no active view yet → nil, compacted away
        // Bound to a local: the bridge holds the source weakly (a live view is
        // retained by the view hierarchy), so a temporary would deallocate before
        // `snapshot()` reads it.
        let source = FakeBufferSource(buffer: "on screen", cwd: "/tmp")
        bridge.setActiveSource(source)
        let snaps = registry.snapshots()
        #expect(snaps.count == 1)
        #expect(snaps.first?.kind == "terminal")
        #expect(snaps.first?.text == "on screen")
        #expect(snaps.first?.title == "Rune — /tmp")
    }

    @Test("different hosts get different bridges and registrations")
    func differentHostsDifferentBridges() {
        let r1 = RecordingContextRegistry(); let h1 = FakeHostServices(context: r1)
        let r2 = RecordingContextRegistry(); let h2 = FakeHostServices(context: r2)
        let b1 = TerminalRuntime.contextBridge(for: h1)
        let b2 = TerminalRuntime.contextBridge(for: h2)
        #expect(b1 !== b2)
        #expect(r1.sources.count == 1)
        #expect(r2.sources.count == 1)
    }
}
