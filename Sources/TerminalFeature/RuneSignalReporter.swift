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
    /// This is the "a CLI wants you" case — Claude Code's terminal-bell channel
    /// writes BEL when a turn finishes or it needs input, and so does anything
    /// else that has no UI of its own.
    ///
    /// `.info`, not `.warning`: a bell is an attention request, not a problem,
    /// and some shells also ring it for ambiguous tab-completion. The dedupe key
    /// is the session, so a run of bells coalesces into one row with a count
    /// rather than a wall of identical rows — which is what makes it safe to
    /// report something a shell can emit incidentally.
    func bellRang(sessionID: UUID) {
        signals.emit(
            kind: "terminal.bell",
            severity: .info,
            title: "Terminal needs your attention",
            body: nil,
            importance: .normal,
            dedupeKey: "rune.bell:\(sessionID.uuidString)")
    }

    /// A program in the pane asked to show a notification, via OSC 9.
    ///
    /// This is the path that actually carries coding agents: Claude Code's
    /// notification hook writes `ESC ] 9 ; conterm-agent:claude:attention:<path>
    /// BEL`, and the trailing BEL is the sequence terminator rather than a
    /// bell — so a terminal listening only for bells hears nothing.
    ///
    /// Unlike `bellRang`, this carries text, so the row can say which agent
    /// wants you and why.
    func agentNotification(payload: String, sessionID: UUID) {
        guard let parsed = TerminalOSCNotification.parse(payload) else { return }
        let isError = TerminalOSCNotification.isError(payload)
        signals.emit(
            kind: isError ? "terminal.agent-error" : "terminal.agent-attention",
            severity: isError ? .warning : .info,
            title: parsed.title,
            body: parsed.body,
            // `.urgent` for attention: an agent that is BLOCKED on you is the
            // single most valuable notification in the product — it is the case
            // where not knowing costs you the whole wait.
            importance: isError ? .urgent : .urgent,
            // Per session AND per title, so "needs attention" and "finished"
            // are separate rows while a repeat of either coalesces.
            dedupeKey: "rune.agent:\(sessionID.uuidString):\(parsed.title)")
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
