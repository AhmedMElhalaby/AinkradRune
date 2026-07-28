import Foundation
import AinkradAppKit

/// Publishes Terminal's read side to the host assistant as MCP resources.
///
/// Terminal is the third adopter after Git Mage (35 tools) and Lore (8 tools +
/// 1 resource), and the first that publishes **no tools at all**. That is
/// deliberate, not an unfinished state:
///
/// - **`run_terminal` stays host-owned.** It drives `ExecutionRouter`, the
///   sandbox tiers and live output streaming into the timeline. Re-publishing
///   it here would move a command-execution gate out of the host for reasons
///   that have nothing to do with MCP, and weaken it in the process.
/// - **`terminal.echo` is host→app plumbing**, not agent-facing: the host has
///   already run the command and captured the output, and the action just
///   paints it into the visible buffer. It stays a gated `AgentAction`.
///
/// What is left, and what an app is uniquely able to answer, is the READ side:
/// what is on screen, and where the shell is.
@MainActor
enum TerminalMCPServer {
    /// The active terminal's scrollback, untruncated.
    static let bufferResourceURI = "terminal://buffer"
    /// The active terminal's working directory.
    static let cwdResourceURI = "terminal://cwd"

    /// What both resources return when no terminal is live.
    ///
    /// Phrased as an instruction rather than a status because the model is the
    /// reader: it says what is true, and what the model can do about it. The
    /// `workspace_control` `openApp` action makes "ask the user to open one" a
    /// real, reachable next step rather than a dead end. Deliberately NOT an
    /// empty string and NOT a plausible-looking placeholder — either would read
    /// as "the terminal is empty" / "the cwd is /", both of which are lies the
    /// model would then act on.
    static let noTerminalMessage =
        "No terminal is currently open in Ainkrad, so there is no buffer or working "
        + "directory to read. Ask the user to open the Terminal app (or open it with "
        + "workspace_control's openApp action) and run something first."

    /// Builds the server around a live bridge.
    ///
    /// Returns the URIs of any resources `addResource` refused alongside the
    /// server: a dropped resource is a silently missing capability, so the
    /// caller must not be able to ignore it by accident. Mirrors
    /// `LoreMCPServer.make`'s failure accumulation — there are only two
    /// registrations here, but the failure mode (a URI collision after an edit)
    /// is identical and equally silent.
    static func make(appID: String, bridge: TerminalContextBridge)
        -> (server: MCPAppServer, failures: [String]) {
        let server = MCPAppServer(appID: appID)
        var failures: [String] = []

        var buffer = MCPResourceSpec(
            uri: bufferResourceURI,
            title: "Terminal buffer",
            provider: {
                // Untruncated on purpose — see `activeBufferText()`. This is the
                // pull-based complement to the 8000-char tail the push-based
                // <workspace_context> snapshot publishes; bounding it here would
                // erase the only reason to read it.
                guard let text = bridge.activeBufferText() else { return noTerminalMessage }
                return text
            })
        // FALSE, and this is the first real judgement call on this flag, so:
        //
        // `requiresLiveApp` makes the host OPEN the app before reading. The
        // tempting reading is "this resource needs live state, and `activeSource`
        // is nil when Terminal is closed, so set it true". That reading is wrong
        // here, because opening a closed Terminal does not produce the data
        // being asked for: a fresh window comes up with an EMPTY buffer and no
        // restored session. The user's previous scrollback is gone either way.
        // Setting it true would therefore spend an unasked-for window AND still
        // answer "empty" — strictly worse than answering "nothing is open, ask
        // the user", which is what the provider does.
        //
        // So the flag means **"opening the app makes this work"**, not "this
        // needs live state". A future resource whose data the app would
        // reconstruct on launch (a store it reloads, a document it reopens)
        // should set it true; one that only observes ephemeral live state
        // should not.
        buffer.requiresLiveApp = false
        if !server.addResource(buffer) { failures.append(bufferResourceURI) }

        var cwd = MCPResourceSpec(
            uri: cwdResourceURI,
            title: "Terminal working directory",
            provider: {
                guard bridge.hasActiveSource else { return noTerminalMessage }
                guard let path = bridge.activeCurrentDirectory(), !path.isEmpty else {
                    // A live terminal that has not emitted OSC 7 — a real and
                    // distinct case from "no terminal", and one the model can
                    // resolve itself by running `pwd`.
                    return "A terminal is open, but it has not reported a working directory "
                        + "(the shell has not emitted OSC 7). Run `pwd` in it to find out."
                }
                return path
            })
        // Same reasoning as above: a freshly opened Terminal's cwd is the
        // default launch directory, not the one that was being asked about.
        cwd.requiresLiveApp = false
        if !server.addResource(cwd) { failures.append(cwdResourceURI) }

        return (server, failures)
    }
}
