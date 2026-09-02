import Testing
import Foundation
import AinkradAppKit
@testable import TerminalFeature

@MainActor
@Suite("Rune signal reporting")
struct RuneSignalReporterTests {
    /// Records what Rune asked the host to publish.
    final class RecordingEmitter: PluginSignalEmitter {
        struct Call {
            let kind: String
            let severity: SignalSeverity
            let title: String
            let body: String?
            let importance: SignalImportance
            let dedupeKey: String?
        }
        private(set) var calls: [Call] = []
        func emit(kind: String, severity: SignalSeverity, title: String, body: String?,
                  importance: SignalImportance, deepLink: SignalDeepLink?,
                  actions: [SignalAction], dedupeKey: String?) {
            calls.append(Call(kind: kind, severity: severity, title: title, body: body,
                              importance: importance, dedupeKey: dedupeKey))
        }
        func own(limit: Int) -> [SignalEvent] { [] }
        func handleAction(_ actionID: String,
                          _ handler: @escaping @MainActor () async -> Void) -> AgentActionToken {
            AgentActionToken()
        }
        func removeActionHandler(_ token: AgentActionToken) {}
    }

    private func reporter() -> (RuneSignalReporter, RecordingEmitter) {
        let emitter = RecordingEmitter()
        return (RuneSignalReporter(signals: emitter), emitter)
    }

    @Test("a clean local exit says nothing — the user closed it themselves")
    func cleanLocalExitIsSilent() {
        let (reporter, emitter) = self.reporter()
        reporter.sessionEnded(exitCode: 0, isRemote: false, host: nil, sessionID: UUID())
        #expect(emitter.calls.isEmpty,
                "reporting what the user just did is noise, and noise makes the feed unread")
    }

    @Test("a non-zero local exit is reported as a failure")
    func failedLocalExitReports() {
        let (reporter, emitter) = self.reporter()
        reporter.sessionEnded(exitCode: 137, isRemote: false, host: nil, sessionID: UUID())
        #expect(emitter.calls.count == 1)
        #expect(emitter.calls[0].kind == "session.failed")
        #expect(emitter.calls[0].severity == .warning)
        #expect(emitter.calls[0].body == "Exit code 137.")
    }

    @Test("a clean SSH exit still reports — a dropped remote is not a user action")
    func cleanRemoteExitReports() {
        let (reporter, emitter) = self.reporter()
        reporter.sessionEnded(exitCode: 0, isRemote: true, host: "build-box", sessionID: UUID())
        #expect(emitter.calls.count == 1)
        #expect(emitter.calls[0].kind == "session.ended")
        #expect(emitter.calls[0].severity == .info)
        #expect(emitter.calls[0].title == "SSH session to build-box ended")
    }

    @Test("a failed SSH exit names the host and the code")
    func failedRemoteExitReports() {
        let (reporter, emitter) = self.reporter()
        reporter.sessionEnded(exitCode: 255, isRemote: true, host: "build-box", sessionID: UUID())
        #expect(emitter.calls[0].kind == "session.failed")
        #expect(emitter.calls[0].title == "SSH session to build-box ended")
        #expect(emitter.calls[0].body == "Exit code 255.")
    }

    @Test("an unknown exit code is treated as clean, not as a failure")
    func unknownExitCode() {
        let (reporter, emitter) = self.reporter()
        reporter.sessionEnded(exitCode: nil, isRemote: false, host: nil, sessionID: UUID())
        #expect(emitter.calls.isEmpty, "guessing a failure from missing data would cry wolf")
    }

    @Test("the dedupe key is per session, so a reconnect loop coalesces")
    func dedupeKeyIsPerSession() {
        let (reporter, emitter) = self.reporter()
        let id = UUID()
        reporter.sessionEnded(exitCode: 1, isRemote: false, host: nil, sessionID: id)
        reporter.sessionEnded(exitCode: 1, isRemote: false, host: nil, sessionID: id)
        #expect(emitter.calls.allSatisfy { $0.dedupeKey == "rune.session:\(id.uuidString)" })
    }

    @Test("startup notices are reported once, joined, and only when present")
    func startupNotices() {
        let (reporter, emitter) = self.reporter()
        reporter.startupNotices([], sessionID: UUID())
        #expect(emitter.calls.isEmpty)

        reporter.startupNotices(["Shell /bin/nope not found", "Directory /tmp/gone missing"],
                                sessionID: UUID())
        #expect(emitter.calls.count == 1)
        #expect(emitter.calls[0].kind == "session.startup-notice")
        #expect(emitter.calls[0].title == "Terminal startup notices")
        #expect(emitter.calls[0].body?.contains("/bin/nope") == true)
        #expect(emitter.calls[0].body?.contains("/tmp/gone") == true)
    }

    @Test("a terminal bell is reported as an attention request, not a problem")
    func bellIsReported() {
        let (reporter, emitter) = self.reporter()
        reporter.bellRang(sessionID: UUID())
        #expect(emitter.calls.count == 1)
        #expect(emitter.calls[0].kind == "terminal.bell")
        #expect(emitter.calls[0].severity == .info,
                "a bell is an attention request; some shells ring it for tab completion")
        #expect(emitter.calls[0].title == "Terminal needs your attention")
    }

    @Test("repeated bells in one session share a dedupe key, so they coalesce")
    func bellsCoalescePerSession() {
        let (reporter, emitter) = self.reporter()
        let id = UUID()
        for _ in 0..<5 { reporter.bellRang(sessionID: id) }
        #expect(Set(emitter.calls.map(\.dedupeKey)).count == 1,
                "a run of bells must be one row with a count, not five rows")
    }

    @Test("bells from different sessions do not coalesce into each other")
    func bellsAreScopedToSession() {
        let (reporter, emitter) = self.reporter()
        reporter.bellRang(sessionID: UUID())
        reporter.bellRang(sessionID: UUID())
        #expect(Set(emitter.calls.map(\.dedupeKey)).count == 2)
    }

    @Test("Claude Code's real hook payload becomes an urgent attention event")
    func agentAttention() {
        let (reporter, emitter) = self.reporter()
        reporter.agentNotification(
            payload: "conterm-agent:claude:attention:/tmp/t.jsonl", sessionID: UUID())
        #expect(emitter.calls.count == 1)
        #expect(emitter.calls[0].kind == "terminal.agent-attention")
        #expect(emitter.calls[0].title == "Claude needs your attention")
        #expect(emitter.calls[0].body == "/tmp/t.jsonl")
        #expect(emitter.calls[0].importance == .urgent,
                "an agent blocked on you is the case where not knowing costs the whole wait")
    }

    @Test("an agent error is a warning with its own kind")
    func agentError() {
        let (reporter, emitter) = self.reporter()
        reporter.agentNotification(payload: "conterm-agent:claude:error:boom", sessionID: UUID())
        #expect(emitter.calls[0].kind == "terminal.agent-error")
        #expect(emitter.calls[0].severity == .warning)
    }

    @Test("attention and finished are separate rows, but a repeat of either coalesces")
    func agentDedupeKeys() {
        let (reporter, emitter) = self.reporter()
        let id = UUID()
        reporter.agentNotification(payload: "conterm-agent:claude:attention:a", sessionID: id)
        reporter.agentNotification(payload: "conterm-agent:claude:attention:b", sessionID: id)
        reporter.agentNotification(payload: "conterm-agent:claude:done:", sessionID: id)
        let keys = emitter.calls.map(\.dedupeKey)
        #expect(keys[0] == keys[1], "two attention pings are one situation")
        #expect(keys[2] != keys[0], "finishing is a different situation from waiting")
    }

    @Test("an empty OSC payload emits nothing")
    func emptyPayloadIsSilent() {
        let (reporter, emitter) = self.reporter()
        reporter.agentNotification(payload: "  ", sessionID: UUID())
        #expect(emitter.calls.isEmpty)
    }

    @Test("every kind Rune emits is one the host will accept")
    func kindsAreValid() {
        let (reporter, emitter) = self.reporter()
        reporter.sessionEnded(exitCode: 1, isRemote: false, host: nil, sessionID: UUID())
        reporter.sessionEnded(exitCode: 0, isRemote: true, host: "h", sessionID: UUID())
        reporter.startupNotices(["x"], sessionID: UUID())
        reporter.bellRang(sessionID: UUID())
        reporter.agentNotification(payload: "conterm-agent:claude:attention:x", sessionID: UUID())
        reporter.agentNotification(payload: "conterm-agent:claude:error:x", sessionID: UUID())
        // The host rejects an invalid kind SILENTLY, which is how
        // `session.needsInput` was lost during planning. Assert, do not assume.
        for call in emitter.calls {
            #expect(SignalKind.isValid(call.kind), "invalid kind: \(call.kind)")
        }
    }
}

@MainActor
@Suite("Terminal session remote host")
struct TerminalSessionRemoteHostTests {
    private func session(executable: String?, args: [String]?) -> TerminalSession {
        TerminalSession(workingDirectory: URL(fileURLWithPath: "/tmp"),
                        shellPath: "/bin/zsh",
                        launchExecutable: executable,
                        launchArgs: args)
    }

    @Test("a local session has no remote host")
    func localSessionHasNone() {
        #expect(session(executable: nil, args: nil).remoteHost == nil)
    }

    @Test("a bare destination is the host")
    func bareDestination() {
        #expect(session(executable: "/usr/bin/ssh", args: ["build-box"]).remoteHost == "build-box")
    }

    @Test("the username is stripped — it is not what a notification should say")
    func stripsUsername() {
        #expect(session(executable: "/usr/bin/ssh",
                        args: ["deploy@build-box"]).remoteHost == "build-box")
    }

    @Test("flags before the destination do not confuse it")
    func ignoresFlags() {
        // SSHInvocation.argv puts -i/-p first and the destination last.
        #expect(session(executable: "/usr/bin/ssh",
                        args: ["-i", "/k/id", "-p", "2222", "ops@10.0.0.4"]).remoteHost == "10.0.0.4")
    }

    @Test("a trailing @ yields nothing rather than an empty host name")
    func trailingAt() {
        #expect(session(executable: "/usr/bin/ssh", args: ["deploy@"]).remoteHost == nil)
    }
}
