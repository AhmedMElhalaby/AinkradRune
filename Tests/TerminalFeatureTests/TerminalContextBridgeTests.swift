import Testing
import Foundation
import AinkradAppKit
@testable import TerminalFeature

@Suite("TerminalContextBridge")
@MainActor
struct TerminalContextBridgeTests {
    @Test("no active source yields nil")
    func nilWhenNoSource() {
        let bridge = TerminalContextBridge()
        #expect(bridge.snapshot() == nil)
    }

    @Test("active source publishes buffer text tagged terminal")
    func publishesBuffer() {
        let bridge = TerminalContextBridge()
        let source = FakeBufferSource(buffer: "hello world")
        bridge.setActiveSource(source)
        let snap = bridge.snapshot()
        #expect(snap?.kind == "terminal")
        #expect(snap?.text == "hello world")
    }

    @Test("title uses cwd when present")
    func titleUsesCwd() {
        let bridge = TerminalContextBridge()
        let source = FakeBufferSource(buffer: "x", cwd: "/Users/x/proj")
        bridge.setActiveSource(source)
        #expect(bridge.snapshot()?.title == "Rune — /Users/x/proj")
    }

    @Test("title falls back to Terminal when no cwd")
    func titleFallback() {
        let bridge = TerminalContextBridge()
        let source = FakeBufferSource(buffer: "x", cwd: nil)
        bridge.setActiveSource(source)
        #expect(bridge.snapshot()?.title == "Rune")
    }

    @Test("blank/whitespace buffer yields nil")
    func blankBufferNil() {
        let bridge = TerminalContextBridge()
        // Bind to a local so the weakly-held source stays alive across snapshot()
        // — this genuinely exercises the whitespace→nil branch, not a nil ref.
        let source = FakeBufferSource(buffer: "   \n\n  ")
        bridge.setActiveSource(source)
        #expect(bridge.snapshot() == nil)
    }

    @Test("clearing the active source yields nil")
    func clearYieldsNil() {
        let bridge = TerminalContextBridge()
        let source = FakeBufferSource(buffer: "hello")
        bridge.setActiveSource(source)
        bridge.clearActiveSource(source)
        #expect(bridge.snapshot() == nil)
    }

    @Test("clearing a different source is a no-op")
    func clearDifferentIsNoOp() {
        let bridge = TerminalContextBridge()
        let active = FakeBufferSource(buffer: "keep me")
        let other = FakeBufferSource(buffer: "other")
        bridge.setActiveSource(active)
        bridge.clearActiveSource(other)
        #expect(bridge.snapshot()?.text == "keep me")
    }

    @Test("oversized buffer is trimmed to a bounded tail with a marker")
    func boundedTail() {
        let bridge = TerminalContextBridge()
        let big = String(repeating: "a", count: 5000) + "TAIL_MARKER_" + String(repeating: "b", count: 5000)
        let source = FakeBufferSource(buffer: big)
        bridge.setActiveSource(source)
        let text = bridge.snapshot()!.text
        #expect(text.count <= 8000 + 32)          // bounded near the budget
        #expect(text.contains("TAIL_MARKER_"))    // keeps the recent tail
        #expect(text.hasPrefix("…[earlier output truncated]"))
    }
}
