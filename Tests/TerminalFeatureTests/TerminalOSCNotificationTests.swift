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
        #expect(parsed?.body == "/Users/me/.claude/projects/x/abc.jsonl")
    }

    @Test("a completion state reads as finished, not as attention")
    func completionState() {
        #expect(TerminalOSCNotification.parse("conterm-agent:codex:done:")?.title
                == "Codex finished")
    }

    @Test("an error state is recognised as an error")
    func errorState() {
        #expect(TerminalOSCNotification.parse("conterm-agent:claude:error:boom")?.title
                == "Claude hit an error")
        #expect(TerminalOSCNotification.isError("conterm-agent:claude:error:boom"))
        #expect(!TerminalOSCNotification.isError("conterm-agent:claude:attention:x"))
    }

    @Test("an unknown state still surfaces, rather than being swallowed")
    func unknownState() {
        let parsed = TerminalOSCNotification.parse("conterm-agent:claude:pondering:x")
        #expect(parsed?.title == "Claude: pondering",
                "inventing silence for an unrecognised word loses the notification")
    }

    @Test("a plain iTerm2 message is the whole payload")
    func plainMessage() {
        let parsed = TerminalOSCNotification.parse("Build finished")
        #expect(parsed?.title == "Build finished")
        #expect(parsed?.body == nil)
    }

    @Test("a path containing colons survives — it is rejoined, not truncated")
    func pathWithColons() {
        let parsed = TerminalOSCNotification.parse("conterm-agent:claude:attention:a:b:c")
        #expect(parsed?.body == "a:b:c", "splitting on every colon would corrupt the detail")
    }

    @Test("an empty payload yields nothing")
    func emptyPayload() {
        #expect(TerminalOSCNotification.parse("") == nil)
        #expect(TerminalOSCNotification.parse("   ") == nil)
    }

    @Test("a truncated conterm payload degrades to a plain message")
    func truncatedContermPayload() {
        // Two segments, so it is not the agent shape; better to show the raw
        // text than to drop it.
        #expect(TerminalOSCNotification.parse("conterm-agent:claude")?.title
                == "conterm-agent:claude")
    }
}
