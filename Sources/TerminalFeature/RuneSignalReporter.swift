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
