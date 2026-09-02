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
    /// Human-readable subtitle for the row.
    let body: String?
    /// Machine detail (the transcript path), carried in the deep link rather
    /// than shown: a `.jsonl` path under `~/.claude/projects` tells the user
    /// nothing and crowds out the part that does.
    let detail: String?

    /// What the agent is telling us. Only some of these are worth a
    /// notification.
    enum Kind: Equatable {
        /// The agent is blocked on the user.
        case attention
        /// The agent finished its work.
        case finished
        /// The agent failed.
        case failed
        /// Lifecycle chatter — start, prompt, idle. NOT a notification.
        case lifecycle
        /// A plain iTerm2 message with no agent convention.
        case message
    }

    let kind: Kind

    /// Parses an OSC 9 payload, or returns nil when there is nothing to show.
    ///
    /// Two shapes, because two things emit them:
    ///
    /// - `conterm-agent:<agent>:<state>:<detail>` — the convention coding-agent
    ///   hooks use.
    /// - anything else — iTerm2's plain `ESC]9;message`.
    ///
    /// **Unrecognised agent states are lifecycle chatter and are dropped.**
    /// The first cut surfaced them on the reasoning that inventing silence
    /// would lose a real notification. Running it against Claude Code disproved
    /// that immediately: one session produced `prompt` seven times, `idle`
    /// three times and `start` once, against three real `attention` pings.
    /// A feed that reports an agent's every heartbeat is one nobody reads, and
    /// it buried the pings that mattered.
    static func parse(_ payload: String) -> TerminalOSCNotification? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.components(separatedBy: ":")
        guard parts.count >= 3, parts[0] == "conterm-agent" else {
            return TerminalOSCNotification(title: trimmed, body: nil,
                                           detail: nil, kind: .message)
        }

        let agent = parts[1].isEmpty ? "An agent" : parts[1].capitalized
        let state = parts[2]
        let detail = parts.count > 3
            ? parts[3...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
            : ""

        let kind: Kind
        let title: String
        switch state {
        case "attention", "waiting", "input":
            kind = .attention
            title = "\(agent) needs your attention"
        case "done", "complete", "completed", "finished":
            kind = .finished
            title = "\(agent) finished"
        case "error", "failed":
            kind = .failed
            title = "\(agent) hit an error"
        default:
            kind = .lifecycle
            title = "\(agent): \(state)"
        }
        guard kind != .lifecycle else { return nil }

        return TerminalOSCNotification(
            title: title,
            // Human-readable, not the raw transcript path. The path is machine
            // detail — it belongs in the deep link, not on screen.
            body: "In Rune. Click to open the terminal.",
            detail: detail.isEmpty ? nil : detail,
            kind: kind)
    }
}
