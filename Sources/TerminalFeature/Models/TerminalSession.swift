import Foundation
import Observation

/// One Terminal Block's local state — created when its root view appears
/// and torn down when it disappears. Not shared across app launches, not
/// persisted. See Terminal App Architecture.md.
@MainActor
@Observable
final class TerminalSession {
    let id: UUID
    var workingDirectory: URL
    var shellPath: String
    /// Calm, non-blocking messages about configured values that were
    /// rejected during resolution (invalid shell / working directory) —
    /// surfaced inline by the Terminal Block, never as a modal. See
    /// Terminal App Architecture.md.
    let startupNotices: [String]
    /// Overrides the spawned executable/args (e.g. `/usr/bin/ssh …`) when this
    /// session was created from an SSH launch payload. `nil` for the normal
    /// login-shell case.
    let launchExecutable: String?
    let launchArgs: [String]?
    private(set) var isRunning = true

    init(
        id: UUID = UUID(),
        workingDirectory: URL,
        shellPath: String,
        startupNotices: [String] = [],
        launchExecutable: String? = nil,
        launchArgs: [String]? = nil
    ) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.shellPath = shellPath
        self.startupNotices = startupNotices
        self.launchExecutable = launchExecutable
        self.launchArgs = launchArgs
    }

    func terminate() {
        isRunning = false
    }

    /// The remote host, for a session launched over SSH.
    ///
    /// Derived from the invocation rather than stored: `SSHInvocation.argv`
    /// puts the destination last, optionally as `user@host`, and the username
    /// is not part of what a notification should say — "SSH session to
    /// build-box ended" reads better than "to deploy@build-box", and the
    /// username can be a shared account that identifies nothing.
    var remoteHost: String? {
        guard launchExecutable != nil, let destination = launchArgs?.last else { return nil }
        guard let at = destination.lastIndex(of: "@") else { return destination }
        let host = String(destination[destination.index(after: at)...])
        return host.isEmpty ? nil : host
    }
}
