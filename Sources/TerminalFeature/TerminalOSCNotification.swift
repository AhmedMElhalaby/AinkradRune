import Foundation

/// A notification a program in the terminal asked to show, via OSC 9.
///
/// `ESC ] 9 ; <payload> BEL` is iTerm2's notification sequence, and it is what
/// coding agents actually use — Claude Code's notification hook writes
/// `conterm-agent:claude:attention:<transcript path>` through it. Note the
/// trailing BEL is the sequence TERMINATOR, not a bell: a terminal that only
/// listens for bells sees nothing at all, which is exactly how this went
/// unnoticed.
struct TerminalOSCNotification: Equatable {
    /// A short title for the feed row.
    let title: String
    /// Optional detail — the transcript path, or the raw message.
    let body: String?

    /// Parses an OSC 9 payload.
    ///
    /// Two shapes, because two things emit them:
    ///
    /// - `conterm-agent:<agent>:<state>:<detail>` — the convention coding-agent
    ///   hooks use. Named, so the row can say *which* agent wants you.
    /// - anything else — iTerm2's plain `ESC]9;message`, where the whole
    ///   payload is the message.
    static func parse(_ payload: String) -> TerminalOSCNotification? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.components(separatedBy: ":")
        guard parts.count >= 3, parts[0] == "conterm-agent" else {
            // A plain message. Truncated by the host at ingest, so no need here.
            return TerminalOSCNotification(title: trimmed, body: nil)
        }

        let agent = parts[1].isEmpty ? "An agent" : parts[1].capitalized
        let state = parts[2]
        let detail = parts.count > 3
            ? parts[3...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
            : ""

        let title: String
        switch state {
        case "attention", "waiting", "input":
            title = "\(agent) needs your attention"
        case "done", "complete", "completed", "finished":
            title = "\(agent) finished"
        case "error", "failed":
            title = "\(agent) hit an error"
        default:
            // An unknown state is still worth surfacing: the agent asked for
            // attention, and inventing silence for a word we do not recognise
            // would lose exactly the notification the user wanted.
            title = "\(agent): \(state)"
        }
        return TerminalOSCNotification(title: title, body: detail.isEmpty ? nil : detail)
    }

    /// Severity for the parsed state, so an agent error reads as one.
    static func isError(_ payload: String) -> Bool {
        let parts = payload.components(separatedBy: ":")
        guard parts.count >= 3, parts[0] == "conterm-agent" else { return false }
        return parts[2] == "error" || parts[2] == "failed"
    }
}
