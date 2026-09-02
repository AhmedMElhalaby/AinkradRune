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
            let deepLink: SignalDeepLink?
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
            calls.append(Call(kind: kind, deepLink: deepLink, severity: severity,
                              title: title, body: body,
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

    @Test("the bell no longer files a row — OSC 9 carries real agents")
    func bellIsSilent() {
        let (reporter, emitter) = self.reporter()
        for _ in 0..<5 { reporter.bellRang(sessionID: UUID()) }
        #expect(emitter.calls.isEmpty,
                "shells ring the bell for tab completion; a row per bell was pure noise")
    }

    @Test("Claude Code's real hook payload becomes one urgent, clickable event")
    func agentAttention() {
        let (reporter, emitter) = self.reporter()
        reporter.agentNotification(
            payload: "conterm-agent:claude:attention:/tmp/t.jsonl", sessionID: UUID())
        #expect(emitter.calls.count == 1)
        #expect(emitter.calls[0].kind == "terminal.agent-attention")
        #expect(emitter.calls[0].title == "Claude needs your attention")
        #expect(emitter.calls[0].importance == .urgent)
        #expect(emitter.calls[0].deepLink?.appID == "rune", "the row must open Rune")
    }

    @Test("lifecycle chatter files nothing at all")
    func lifecycleIsSilent() {
        let (reporter, emitter) = self.reporter()
        for state in ["start", "prompt", "idle"] {
            reporter.agentNotification(payload: "conterm-agent:claude:\(state):/tmp/t",
                                       sessionID: UUID())
        }
        #expect(emitter.calls.isEmpty,
                "one real session produced eleven of these against three real pings")
    }

    @Test("repeated attention in one session is ONE row, whatever the detail")
    func attentionCoalesces() {
        let (reporter, emitter) = self.reporter()
        let id = UUID()
        reporter.agentNotification(payload: "conterm-agent:claude:attention:a", sessionID: id)
        reporter.agentNotification(payload: "conterm-agent:claude:attention:b", sessionID: id)
        reporter.agentNotification(payload: "conterm-agent:claude:attention:c", sessionID: id)
        #expect(Set(emitter.calls.map(\.dedupeKey)).count == 1,
                "keying on the title split 'attention' from 'Claude: prompt' into many rows")
    }

    @Test("finishing is a different row from waiting")
    func finishedIsSeparate() {
        let (reporter, emitter) = self.reporter()
        let id = UUID()
        reporter.agentNotification(payload: "conterm-agent:claude:attention:a", sessionID: id)
        reporter.agentNotification(payload: "conterm-agent:claude:done:", sessionID: id)
        #expect(emitter.calls[0].dedupeKey != emitter.calls[1].dedupeKey)
        #expect(emitter.calls[1].importance == .normal, "finished can wait for the user to look")
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
