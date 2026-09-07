import Testing
@testable import TerminalFeature

@Suite("OSC 9 notification parsing")
struct TerminalOSCNotificationTests {
    @Test("the payload Claude Code's hook actually writes")
    func realClaudeCodePayload() {
        // Verbatim from the user's ~/.claude/settings.json Notification hook.
        let parsed = TerminalOSCNotification.parse(
            "conterm-agent:claude:attention:/Users/me/.claude/projects/x/abc.jsonl")
        #expect(parsed?.title == "Claude needs your attention")
        #expect(parsed?.kind == .attention)
        #expect(parsed?.body == "In Rune. Click to open the terminal.",
                "the body is for a human; the path is machine detail")
        #expect(parsed?.detail == "/Users/me/.claude/projects/x/abc.jsonl",
                "but the path is still carried, for the deep link")
    }

    /// The states one real Claude Code session produced, with their counts.
    /// `prompt` seven times and `idle` three times against three real
    /// `attention` pings is why lifecycle states are dropped.
    @Test(arguments: ["start", "prompt", "idle", "thinking", "tool"])
    func lifecycleStatesAreDropped(state: String) {
        #expect(TerminalOSCNotification.parse("conterm-agent:claude:\(state):/tmp/t") == nil,
                "an agent's heartbeat is not a notification")
    }

    @Test("the three states that ARE notifications survive")
    func realNotificationsSurvive() {
        #expect(TerminalOSCNotification.parse("conterm-agent:claude:attention:x")?.kind == .attention)
        #expect(TerminalOSCNotification.parse("conterm-agent:codex:done:")?.kind == .finished)
        #expect(TerminalOSCNotification.parse("conterm-agent:claude:error:boom")?.kind == .failed)
    }

    @Test("a completion names the agent")
    func completionNaming() {
        #expect(TerminalOSCNotification.parse("conterm-agent:codex:done:")?.title == "Codex finished")
    }

    @Test("a plain iTerm2 message is the whole payload and is kept")
    func plainMessage() {
        let parsed = TerminalOSCNotification.parse("Build finished")
        #expect(parsed?.title == "Build finished")
        #expect(parsed?.kind == .message)
    }

    @Test("a path containing colons survives — it is rejoined, not truncated")
    func pathWithColons() {
        #expect(TerminalOSCNotification.parse("conterm-agent:claude:attention:a:b:c")?.detail
                == "a:b:c")
    }

    @Test("an empty payload yields nothing")
    func emptyPayload() {
        #expect(TerminalOSCNotification.parse("") == nil)
        #expect(TerminalOSCNotification.parse("   ") == nil)
    }

    @Test("a truncated conterm payload degrades to a plain message")
    func truncatedContermPayload() {
        #expect(TerminalOSCNotification.parse("conterm-agent:claude")?.kind == .message)
    }
}
