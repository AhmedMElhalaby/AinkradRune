import Foundation
import AinkradAppKit

/// Bridges Terminal's static `AinkradApp` entry points to a single shared,
/// observable `TerminalSettingsStore` per host. `makeRootView(host:)` and
/// `makeSettingsView(host:)` receive the same host instance, so every Terminal
/// pane and the settings pane share one store — a settings edit restyles all
/// running terminals live. Keyed by host object identity (the host is always a
/// reference type — `HostServicesImpl`).
@MainActor
enum TerminalRuntime {
    private static let stores = PluginInstanceStorage<TerminalSettingsStore>()
    private static let bridges = PluginInstanceStorage<TerminalContextBridge>()
    private static let contextTokens = PluginInstanceStorage<PluginContextToken>()
    private static let actionTokens = PluginInstanceStorage<AgentActionToken>()
    /// Cached per host so the assistant reads the SAME bridge the on-screen
    /// terminal registers itself with. A fresh server per call would capture a
    /// fresh bridge with a nil source and always answer "no terminal open".
    private static let mcpServers = PluginInstanceStorage<MCPAppServer>()

    /// The instance key for `host`.
    ///
    /// A generation-8 host mints one. A generation-7 host does not implement
    /// `PluginInstanceIdentity`, so fall back to the OLD per-host object
    /// identity — collapsing every legacy host onto one shared key would make
    /// two hosts share a settings store, a regression rather than a fallback.
    /// The address-reuse hazard therefore remains only on the legacy path,
    /// exactly as before, and is gone on generation 8.
    static func instance(of host: HostServices) -> PluginInstanceID {
        if let identified = host as? PluginInstanceIdentity { return identified.instanceID }
        let key = ObjectIdentifier(host as AnyObject)
        if let existing = legacyIDs[key] { return existing }
        let minted = PluginInstanceID()
        legacyIDs[key] = minted
        return minted
    }
    private static var legacyIDs: [ObjectIdentifier: PluginInstanceID] = [:]

    static func settingsStore(for host: HostServices) -> TerminalSettingsStore {
        stores.value(for: instance(of: host)) { TerminalSettingsStore(documents: host.documents) }
    }

    /// The per-host agent-context bridge. Created and **registered with the host
    /// once** on first request (mirroring `settingsStore` — a Block's root and
    /// settings views share the one host, hence one bridge). Never removed: the
    /// registered closure returns nil once the view is gone.
    static func contextBridge(for host: HostServices) -> TerminalContextBridge {
        let id = instance(of: host)
        var created = false
        let bridge = bridges.value(for: id) { created = true; return TerminalContextBridge() }
        // Register only on first creation, and KEEP the token so `teardown`
        // can remove it — "never removed" left a dead context source
        // registered with the host for every instance ever opened.
        if created {
            _ = contextTokens.value(for: id) { host.context.register { bridge.snapshot() } }
        }
        return bridge
    }

    /// The per-host MCP server, built over this host's context bridge.
    static func mcpServer(for host: HostServices) -> MCPAppServer {
        mcpServers.value(for: instance(of: host)) {
            let (server, failures) = TerminalMCPServer.make(
                appID: RuneApp.id, bridge: contextBridge(for: host))
            // A dropped resource is a silently missing capability — say so
            // rather than let the assistant just never see it.
            if !failures.isEmpty {
                host.log.error("Terminal MCP: resources rejected — \(failures.joined(separator: ", "))")
            }
            return server
        }
    }

    /// Register this host's gated action handlers **once**. The `terminal.echo`
    /// handler decodes {command, output} and renders it into the active terminal
    /// via the per-host context bridge. Never torn down — a gone view means the
    /// bridge's weak source is nil and the echo is a no-op.
    static func registerActions(for host: HostServices) {
        let bridge = contextBridge(for: host)
        _ = actionTokens.value(for: instance(of: host)) {
            host.actions.register(actionID: "terminal.echo") { json in
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let command = obj["command"] as? String else {
                    return AgentActionResult(text: "terminal.echo: malformed input", isError: true)
                }
                let output = obj["output"] as? String ?? ""
                bridge.echo(command: command, output: output)
                return AgentActionResult(text: "echoed", isError: false)
            }
        }
    }

    /// Releases everything scoped to `instance` and unregisters it from the
    /// host. All four registries above were `static` and never evicted, so a
    /// closed Terminal left its settings store, its context source and its
    /// `terminal.echo` handler live for the rest of the process.
    static func teardown(instance: PluginInstanceID, host: HostServices?) {
        stores.remove(instance)
        bridges.remove(instance)
        // The server's resource providers capture the bridge — leaving it
        // registered would keep a closed instance's bridge alive and let the
        // assistant keep reading a terminal that is gone.
        mcpServers.remove(instance)
        if let token = contextTokens.remove(instance) { host?.context.remove(token) }
        if let token = actionTokens.remove(instance) { host?.actions.remove(token) }
    }
}
