import Foundation
import AinkradAppKit

/// Rune's notification vocabulary, in one place so the kinds stay consistent
/// and every emission decision is visible together.
///
/// **Rune reports sessions, not commands.** Per-command reporting would need
/// shell integration (OSC 133) that Rune does not have, and inventing it from
/// PTY output would be guesswork. A session is what Rune actually knows about.
@MainActor
struct RuneSignalReporter {
    let signals: PluginSignalEmitter

    /// Emitted when a terminal session's process ends.
    ///
    /// **A clean local exit is deliberately silent.** The user typed `exit` or
    /// closed the pane; telling them what they just did is noise, and a feed
    /// full of noise is one nobody reads. Two cases do warrant a notification:
    ///
    /// - a **non-zero exit**, which is a shell that died rather than one that
    ///   was dismissed;
    /// - **any SSH session ending**, clean or not, because a dropped remote
    ///   connection is something that happened *to* the user rather than
    ///   something they did.
    func sessionEnded(exitCode: Int32?, isRemote: Bool, host: String?, sessionID: UUID) {
        let failed = (exitCode ?? 0) != 0
        guard failed || isRemote else { return }

        let title: String
        if isRemote {
            title = host.map { "SSH session to \($0) ended" } ?? "SSH session ended"
        } else {
            title = "Terminal session ended"
        }

        var body: String?
        if let exitCode, exitCode != 0 {
            body = "Exit code \(exitCode)."
        }

        signals.emit(
            kind: failed ? "session.failed" : "session.ended",
            severity: failed ? .warning : .info,
            title: title,
            body: body,
            // `.normal`, never `.urgent`: a dead shell is worth knowing about
            // and is not worth interrupting a focused user for.
            importance: .normal,
            // Per session, so a reconnect loop coalesces into one row with a
            // count instead of filling the feed.
            dedupeKey: "rune.session:\(sessionID.uuidString)")
    }

    /// The program running in a pane rang the terminal bell.
    ///
    /// **Deliberately not reported.** The first cut emitted a row per bell, and
    /// the shells ring it for ambiguous tab-completion — so the feed filled
    /// with rows the user did not ask for. Real agents announce themselves
    /// through OSC 9 (below), which carries text and a state; a bare BEL
    /// carries one byte and cannot say who rang or why.
    ///
    /// Kept as a no-op rather than deleted: the capture in
    /// `AinkradTerminalView` is the hard part, and a future setting could
    /// reasonably turn this back on.
    func bellRang(sessionID: UUID) {}

    /// A program in the pane asked to show a notification, via OSC 9.
    ///
    /// This is the path that actually carries coding agents: Claude Code's
    /// notification hook writes `ESC ] 9 ; conterm-agent:claude:attention:<path>
    /// BEL`, and the trailing BEL is the sequence terminator rather than a
    /// bell — so a terminal listening only for bells hears nothing.
    ///
    /// Lifecycle states (start, prompt, idle) are dropped by the parser; only
    /// attention, finished and failed reach the feed.
    func agentNotification(payload: String, sessionID: UUID) {
        guard let parsed = TerminalOSCNotification.parse(payload) else { return }

        let severity: SignalSeverity = parsed.kind == .failed ? .warning : .info
        signals.emit(
            kind: kindName(for: parsed.kind),
            severity: severity,
            title: parsed.title,
            body: parsed.body,
            // `.urgent` only when the agent is BLOCKED on the user: that is the
            // case where not knowing costs the whole wait. "Finished" can wait
            // for the user to look.
            importance: parsed.kind == .attention ? .urgent : .normal,
            // Clicking the row focuses the PANE holding this session, not
            // merely the app. `locator` is the field the host is allowed to
            // compare, and it matches what the pane reported through
            // `ainkradPaneLocator`; the payload stays opaque and keeps
            // carrying the transcript path for Rune's own use.
            //
            // "a future Rune can jump to the right pane" is now this Rune.
            deepLink: SignalDeepLink(
                appID: "rune",
                payload: Data("\(sessionID.uuidString)|\(parsed.detail ?? "")".utf8),
                locator: sessionID.uuidString),
            // Per session and per KIND, not per title: an agent that asks for
            // attention repeatedly is one situation, and the host coalesces it
            // into a single row with a count.
            dedupeKey: "rune.agent:\(sessionID.uuidString):\(kindName(for: parsed.kind))")
    }

    private func kindName(for kind: TerminalOSCNotification.Kind) -> String {
        switch kind {
        case .attention: return "terminal.agent-attention"
        case .finished: return "terminal.agent-finished"
        case .failed: return "terminal.agent-error"
        case .message, .lifecycle: return "terminal.message"
        }
    }

    /// A configured shell or working directory was rejected at startup. Rune
    /// already shows these inline in the block; the feed keeps them after the
    /// block is gone, which is when the user usually wonders what happened.
    func startupNotices(_ notices: [String], sessionID: UUID) {
        guard !notices.isEmpty else { return }
        signals.emit(
            kind: "session.startup-notice",
            severity: .warning,
            title: notices.count == 1 ? "Terminal startup notice" : "Terminal startup notices",
            body: notices.joined(separator: "\n"),
            importance: .normal,
            dedupeKey: "rune.startup:\(sessionID.uuidString)")
    }
}
