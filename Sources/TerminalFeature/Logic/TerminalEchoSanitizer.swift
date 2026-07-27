import Foundation

/// Strips control sequences from text the host echoes into the terminal on the
/// agent's behalf.
///
/// ## Why echoed output is not the same as terminal output
///
/// `feed(text:)` hands bytes to the emulator's **parser**, which acts on them.
/// That is correct for the PTY — that is how a shell draws. It is not correct
/// for `agentEcho`, whose payload is the captured stdout of a command the agent
/// chose to run. That content routinely comes from somewhere untrusted: the
/// body of a fetched page, a file in a cloned repo, a container log, a
/// filename. Feeding it raw makes any of those able to drive the emulator:
///
/// * **`CSI 6n` (Device Status Report)** — the emulator *replies by writing to
///   the PTY*. The reply lands on the shell's stdin as if typed. Combined with
///   a trailing newline in the same payload, that is command injection into the
///   user's live shell from the text of a file the agent merely printed.
/// * **`OSC 52`** — sets the system clipboard.
/// * **`OSC 0/2`** — rewrites the window title.
/// * **`CSI` cursor movement + bare `CR`** — overwrite previously drawn text,
///   so output can be made to misrepresent what a command actually printed.
///
/// The user approved *running* a command. They did not approve its output
/// steering their terminal.
///
/// ## What survives
///
/// Colour and text style (`CSI … m`, SGR) — dropping those would turn every
/// echoed `ls`, `git diff` and build log into unreadable monochrome, and SGR
/// cannot move the cursor, write the clipboard, or generate a reply. Plus
/// newline and tab. Everything else is removed.
enum TerminalEchoSanitizer {

    /// Text safe to hand to `feed(text:)`.
    static func sanitize(_ input: String) -> String {
        var out = String()
        out.reserveCapacity(input.count)

        let scalars = Array(input.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]

            if scalar == "\u{1B}" {                     // ESC
                i = skipEscapeSequence(scalars, from: i, appendingSGRTo: &out)
                continue
            }

            switch scalar.value {
            case 0x0A:                                   // LF — keep
                out.unicodeScalars.append(scalar); i += 1
            case 0x09:                                   // TAB — keep
                out.unicodeScalars.append(scalar); i += 1
            case 0x0D:                                   // CR
                // `\r\n` becomes `\n`; a BARE `\r` is dropped rather than kept,
                // because returning to column zero is what lets output overwrite
                // what it already printed.
                if i + 1 < scalars.count, scalars[i + 1].value == 0x0A {
                    out.unicodeScalars.append("\u{0A}"); i += 2
                } else {
                    i += 1
                }
            case 0x00...0x1F, 0x7F:                      // other C0 + DEL — drop
                i += 1
            case 0x80...0x9F:                            // C1 controls (incl. 8-bit CSI/OSC) — drop
                i += 1
            default:
                out.unicodeScalars.append(scalar); i += 1
            }
        }
        return out
    }

    /// Consumes one escape sequence starting at `start` (which must be ESC).
    /// Appends it to `out` only when it is an SGR (`CSI … m`) sequence.
    /// Returns the index just past the sequence.
    private static func skipEscapeSequence(
        _ scalars: [Unicode.Scalar], from start: Int, appendingSGRTo out: inout String
    ) -> Int {
        let i = start + 1
        guard i < scalars.count else { return i }        // trailing lone ESC

        switch scalars[i] {
        case "[":                                        // CSI
            let paramsStart = i + 1
            var j = paramsStart
            // Parameter and intermediate bytes, then one final byte 0x40–0x7E.
            while j < scalars.count, (0x30...0x3F).contains(scalars[j].value) { j += 1 }
            while j < scalars.count, (0x20...0x2F).contains(scalars[j].value) { j += 1 }
            guard j < scalars.count else { return scalars.count }
            let final = scalars[j]
            if final == "m" {
                // SGR — colour/style only. Re-emit verbatim.
                out.append("\u{1B}[")
                for k in paramsStart..<j { out.unicodeScalars.append(scalars[k]) }
                out.append("m")
            }
            return j + 1

        case "]":                                        // OSC — runs to BEL or ST (ESC \)
            var j = i + 1
            while j < scalars.count {
                if scalars[j].value == 0x07 { return j + 1 }                    // BEL
                if scalars[j] == "\u{1B}", j + 1 < scalars.count, scalars[j + 1] == "\\" {
                    return j + 2                                                // ST
                }
                j += 1
            }
            return scalars.count                          // unterminated — drop the rest

        case "P", "X", "^", "_":                          // DCS / SOS / PM / APC — run to ST
            var j = i + 1
            while j < scalars.count {
                if scalars[j] == "\u{1B}", j + 1 < scalars.count, scalars[j + 1] == "\\" {
                    return j + 2
                }
                j += 1
            }
            return scalars.count

        default:
            // Two-character escapes (ESC c full reset, ESC 7/8 cursor save,
            // charset selection, …). Drop the pair.
            return i + 1
        }
    }
}
