import Foundation
import AinkradAppKit

/// The minimal read-only surface `TerminalContextBridge` needs from a live
/// terminal. Kept as a protocol (not the concrete AppKit view) so the bridge is
/// unit-testable without a window server. Class-constrained so the bridge can
/// hold it weakly and compare identity.
@MainActor
protocol TerminalBufferSource: AnyObject {
    /// The current buffer contents as plain text (may be empty / whitespace).
    func agentBufferText() -> String
    /// The shell's reported working directory, if known (OSC 7), else nil.
    func agentCurrentDirectory() -> String?
    /// Render an agent-run command and its captured output into the visible
    /// terminal (best-effort; no-op when unimplemented in a headless test).
    func agentEcho(command: String, output: String)
}

/// Per-host bridge that publishes the active terminal's buffer as read-only
/// agent context. Registered once per host by `TerminalRuntime`; holds a weak
/// reference to the currently-live terminal view and reads it on demand. Returns
/// nil when no view is active or the buffer is empty — so a torn-down view (weak
/// ref gone) simply produces no context, with no teardown call needed.
@MainActor
final class TerminalContextBridge {
    private weak var activeSource: (any TerminalBufferSource)?

    /// The just-attached terminal view becomes the source of context.
    func setActiveSource(_ source: any TerminalBufferSource) {
        activeSource = source
    }

    /// Clears the source only if `source` is still the active one — so a
    /// late-dismantled view can't wipe a newer view's registration.
    func clearActiveSource(_ source: any TerminalBufferSource) {
        if activeSource === source { activeSource = nil }
    }

    /// The current read-only snapshot, or nil when there is nothing to show.
    func snapshot() -> AgentContextSnapshot? {
        guard let source = activeSource else { return nil }
        let text = boundedTail(source.agentBufferText())
        guard !text.isEmpty else { return nil }
        let title: String
        if let cwd = source.agentCurrentDirectory(), !cwd.isEmpty {
            title = "Terminal — \(cwd)"
        } else {
            title = "Terminal"
        }
        return AgentContextSnapshot(kind: "terminal", title: title, text: text)
    }

    // MARK: - pull-based reads (MCP)

    /// The active terminal's FULL scrollback, or nil when no terminal is live.
    ///
    /// Deliberately separate from `snapshot()`, and deliberately UNTRUNCATED.
    /// `snapshot()` is the push path — every turn pays for that text, so it
    /// tail-bounds at 8000 chars. This is the pull path, read only when the
    /// model asks, and it asks precisely because it needs what that bound cut
    /// off; re-applying the bound here would make the resource answer the same
    /// question the model already had an answer to. Returns nil (not "") when
    /// there is no source, so a caller can tell "no terminal open" from
    /// "terminal open, nothing printed yet".
    func activeBufferText() -> String? {
        activeSource?.agentBufferText()
    }

    /// The active terminal's shell-reported working directory (OSC 7).
    ///
    /// Two distinguishable nils collapse here — no terminal live, or a live
    /// terminal that never emitted OSC 7 — so a caller that must tell them
    /// apart checks `hasActiveSource` first.
    func activeCurrentDirectory() -> String? {
        activeSource?.agentCurrentDirectory()
    }

    /// Whether a terminal view is currently live.
    var hasActiveSource: Bool { activeSource != nil }

    /// Echo an agent-run command + output into the active terminal, if any.
    func echo(command: String, output: String) {
        activeSource?.agentEcho(command: command, output: output)
    }

    /// Trims to the most-recent `maxChars` so recent output always survives
    /// (the host also truncates per-source; publishing a pre-trimmed tail keeps
    /// the newest output regardless of the host's truncation direction).
    private func boundedTail(_ raw: String, maxChars: Int = 8000) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        return "…[earlier output truncated]\n" + String(trimmed.suffix(maxChars))
    }
}

extension AinkradTerminalView: TerminalBufferSource {
    func agentBufferText() -> String {
        let data = getTerminal().getBufferAsData()
        return String(data: data, encoding: .utf8) ?? ""
    }
    func agentCurrentDirectory() -> String? {
        getTerminal().hostCurrentDirectory
    }
    func agentEcho(command: String, output: String) {
        // Display-only: the host already executed `command` and captured
        // `output`. We must NOT re-run it — `send(txt:)` writes keystrokes to
        // the live PTY, which would re-execute the command (dangerous for
        // non-idempotent/destructive commands the user approved exactly
        // once). Feed the command line + output straight to the terminal's
        // display buffer instead.
        //
        // Both the command line and the output are SANITIZED first. `feed`
        // runs the emulator's parser, which *acts* on control sequences — and
        // this payload is captured stdout, routinely carrying untrusted bytes
        // (a fetched page, a file in a cloned repo, a filename). Unsanitized, a
        // `CSI 6n` in that text makes the emulator write its reply onto the
        // shell's stdin: command injection into the user's live shell from
        // output the agent merely printed. See `TerminalEchoSanitizer`.
        feed(text: "$ \(TerminalEchoSanitizer.sanitize(command))\r\n")
        let safeOutput = TerminalEchoSanitizer.sanitize(output)
        if !safeOutput.isEmpty {
            feed(text: safeOutput.hasSuffix("\n") ? safeOutput : safeOutput + "\n")
        }
    }
}
