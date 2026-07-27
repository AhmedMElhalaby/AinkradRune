import Testing
import Foundation
@testable import TerminalFeature

/// Wave 2: agent-echoed output was fed straight into the emulator's parser.
/// That payload is captured stdout — a fetched page, a file from a cloned
/// repo, a filename — and the parser *acts* on what it contains.
@Suite("Terminal echo sanitizer")
struct TerminalEchoSanitizerTests {

    // MARK: - The dangerous sequences

    @Test("Device Status Report is removed")
    func stripsDeviceStatusReport() {
        // The worst one: the emulator answers `CSI 6n` by WRITING to the PTY.
        // That reply lands on the shell's stdin as if typed — so this, inside
        // the output of a file the agent merely printed, is command injection
        // into the user's live shell.
        let hostile = "totally normal log line\u{1B}[6n\n"
        let clean = TerminalEchoSanitizer.sanitize(hostile)
        #expect(!clean.contains("\u{1B}"))
        #expect(clean == "totally normal log line\n")
    }

    @Test("OSC 52 clipboard writes are removed")
    func stripsClipboardWrite() {
        let hostile = "before\u{1B}]52;c;aGVsbG8=\u{07}after"
        #expect(TerminalEchoSanitizer.sanitize(hostile) == "beforeafter")
    }

    @Test("OSC terminated by ST is removed")
    func stripsOSCWithStringTerminator() {
        let hostile = "a\u{1B}]0;new window title\u{1B}\\b"
        #expect(TerminalEchoSanitizer.sanitize(hostile) == "ab")
    }

    @Test("Cursor movement is removed")
    func stripsCursorMovement() {
        // Cursor repositioning lets output overwrite what it already printed,
        // so the visible transcript can misrepresent what really ran.
        #expect(TerminalEchoSanitizer.sanitize("a\u{1B}[2Ab") == "ab")
        #expect(TerminalEchoSanitizer.sanitize("a\u{1B}[HXb") == "aXb")
        #expect(TerminalEchoSanitizer.sanitize("a\u{1B}[2Jb") == "ab")
    }

    @Test("A bare carriage return is dropped, CRLF becomes LF")
    func handlesCarriageReturns() {
        // Bare CR returns to column zero — the other way to overwrite.
        #expect(TerminalEchoSanitizer.sanitize("real output\rFAKE") == "real outputFAKE")
        #expect(TerminalEchoSanitizer.sanitize("line\r\nnext") == "line\nnext")
    }

    @Test("DCS, APC, PM and SOS payloads are removed")
    func stripsStringSequences() {
        #expect(TerminalEchoSanitizer.sanitize("a\u{1B}P1;2q payload \u{1B}\\b") == "ab")
        #expect(TerminalEchoSanitizer.sanitize("a\u{1B}^private\u{1B}\\b") == "ab")
        #expect(TerminalEchoSanitizer.sanitize("a\u{1B}_apc\u{1B}\\b") == "ab")
    }

    @Test("Two-character escapes are removed")
    func stripsShortEscapes() {
        #expect(TerminalEchoSanitizer.sanitize("a\u{1B}cb") == "ab")   // full reset
        #expect(TerminalEchoSanitizer.sanitize("a\u{1B}7b") == "ab")   // save cursor
    }

    @Test("8-bit C1 controls are removed")
    func stripsC1Controls() {
        // \u{9B} is 8-bit CSI — the same attacks without an ESC byte.
        #expect(TerminalEchoSanitizer.sanitize("a\u{9B}6nb") == "a6nb")
        #expect(!TerminalEchoSanitizer.sanitize("a\u{9D}52;c;x\u{07}b").contains("\u{9D}"))
    }

    @Test("Unterminated sequences don't leak their payload")
    func unterminatedSequenceIsDropped() {
        // An OSC with no terminator must not fall through as visible text that
        // a later feed could complete.
        #expect(TerminalEchoSanitizer.sanitize("a\u{1B}]52;c;never-closed") == "a")
        #expect(TerminalEchoSanitizer.sanitize("trailing\u{1B}") == "trailing")
    }

    // MARK: - What must survive

    @Test("Colour and style are preserved")
    func keepsSGR() {
        // Dropping SGR would make every echoed ls, git diff and build log
        // unreadable — and SGR cannot move the cursor, write the clipboard or
        // produce a reply.
        let colored = "\u{1B}[31mred\u{1B}[0m normal"
        #expect(TerminalEchoSanitizer.sanitize(colored) == colored)
        #expect(TerminalEchoSanitizer.sanitize("\u{1B}[1;38;5;204mbold\u{1B}[m")
                == "\u{1B}[1;38;5;204mbold\u{1B}[m")
    }

    @Test("Ordinary text, newlines, tabs and unicode are untouched")
    func keepsOrdinaryText() {
        let text = "total 24\ndrwxr-xr-x\t5 user  staff\n✓ done — café 日本\n"
        #expect(TerminalEchoSanitizer.sanitize(text) == text)
    }

    @Test("Empty input stays empty")
    func emptyInput() {
        #expect(TerminalEchoSanitizer.sanitize("") == "")
        // An all-control payload sanitizes to nothing, and the caller skips
        // feeding empty output entirely.
        #expect(TerminalEchoSanitizer.sanitize("\u{1B}[6n\u{1B}[6n") == "")
    }

    @Test("A realistic hostile payload keeps its readable text and loses its teeth")
    func realisticPayload() {
        // What `cat`-ing a hostile file could look like.
        let payload = "README\n\u{1B}]52;c;cGF5bG9hZA==\u{07}"
            + "\u{1B}[31mERROR\u{1B}[0m: nothing to see\n"
            + "\u{1B}[6n"
            + "\rrm -rf ~\n"
        let clean = TerminalEchoSanitizer.sanitize(payload)
        #expect(clean.contains("README"))
        #expect(clean.contains("\u{1B}[31mERROR"))       // colour survives
        #expect(!clean.contains("]52"))                   // clipboard write gone
        #expect(!clean.contains("[6n"))                   // DSR gone
        #expect(!clean.contains("\r"))                    // overwrite trick gone
    }
}
