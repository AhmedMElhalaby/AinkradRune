import Foundation
import AinkradAppKit
@testable import TerminalFeature

/// Builds a `HostThemeTokens` snapshot with the given theme id. Match-Theme
/// resolution reads only `tokens.themeID`, so the color values are irrelevant
/// to these assertions — black stands in for all of them.
func tokens(themeID: String) -> HostThemeTokens {
    HostThemeTokens(themeID: themeID, background: .black, surface: .black, surfaceElevated: .black,
                    accentPrimary: .black, accentSecondary: .black, accentTertiary: .black, foreground: .black)
}

/// Test-only documents: `Codable` values keyed by a stable `documentID`.
protocol TestDocument: Codable {
    static var documentID: String { get }
}

extension TerminalSettings: TestDocument {}

/// An in-memory persistence store used by the moved settings tests. Encodes on
/// save and decodes on load, exercising the same `Codable` path as disk.
final class InMemoryPersistenceStore {
    private var storage: [String: Data] = [:]

    func load<T: TestDocument>(_ type: T.Type) -> T? {
        guard let data = storage[T.documentID] else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: TestDocument>(_ document: T) {
        guard let data = try? JSONEncoder().encode(document) else { return }
        storage[T.documentID] = data
    }

    func delete<T: TestDocument>(_ type: T.Type) {
        storage[T.documentID] = nil
    }
}

/// A test double for the live-terminal surface `TerminalContextBridge` reads.
/// Lets the bridge be tested without constructing an AppKit terminal view.
@MainActor
final class FakeBufferSource: TerminalBufferSource {
    var buffer: String
    var cwd: String?
    private(set) var echoedCommands: [(command: String, output: String)] = []
    init(buffer: String = "", cwd: String? = nil) {
        self.buffer = buffer
        self.cwd = cwd
    }
    func agentBufferText() -> String { buffer }
    func agentCurrentDirectory() -> String? { cwd }
    func agentEcho(command: String, output: String) { echoedCommands.append((command, output)) }
}

/// Records every context source registered against it, so tests can assert the
/// registration count and invoke the registered closure.
@MainActor
final class RecordingContextRegistry: PluginContextRegistry {
    private(set) var sources: [PluginContextToken: @MainActor () -> AgentContextSnapshot?] = [:]
    func register(_ source: @escaping @MainActor () -> AgentContextSnapshot?) -> PluginContextToken {
        let token = PluginContextToken()
        sources[token] = source
        return token
    }
    func remove(_ token: PluginContextToken) { sources[token] = nil }
    /// Convenience: the snapshots all currently-registered sources produce.
    func snapshots() -> [AgentContextSnapshot] { sources.values.compactMap { $0() } }
}

/// Records every gated action handler registered against it, so tests can
/// assert registration counts and invoke a handler by action id.
@MainActor
final class RecordingActionRegistry: AgentActionProvider {
    private(set) var handlers: [AgentActionToken: (String) async -> AgentActionResult] = [:]
    private(set) var ids: [AgentActionToken: String] = [:]
    func register(actionID: String,
                  handler: @escaping @MainActor (String) async -> AgentActionResult) -> AgentActionToken {
        let token = AgentActionToken()
        handlers[token] = handler
        ids[token] = actionID
        return token
    }
    func remove(_ token: AgentActionToken) { handlers[token] = nil; ids[token] = nil }
    func invoke(actionID: String, input: String) async -> AgentActionResult? {
        guard let token = ids.first(where: { $0.value == actionID })?.key,
              let handler = handlers[token] else { return nil }
        return await handler(input)
    }
}

private final class FakeDocs: PluginDocumentStore {
    func data(forKey key: String) -> Data? { nil }
    func setData(_ data: Data?, forKey key: String) {}
}
private final class FakeSecrets: PluginSecretStore {
    func secret(forKey key: String) -> String? { nil }
    func setSecret(_ value: String?, forKey key: String) {}
}
private final class FakeLogger: PluginLogger {
    func info(_ message: String) {}
    func error(_ message: String) {}
}
private final class FakeAppLauncher: PluginAppLauncher {
    func open(appID: String, payload: String?) {}
    func takePendingLaunch() -> String? { nil }
}
private final class FakePresentationControl: PluginPresentationControl {
    private(set) var current: PluginPresentation = .pane
    func set(_ presentation: PluginPresentation) { current = presentation }
    func reset() { current = .pane }
}

/// A minimal reference-type `HostServices` for registration tests. Only
/// `context` carries behavior; the rest are inert doubles. Reference type so
/// `ObjectIdentifier(host as AnyObject)` gives it stable identity (matching how
/// `TerminalRuntime` keys per host).
@MainActor
final class FakeHostServices: HostServices {
    let documents: PluginDocumentStore = FakeDocs()
    let secrets: PluginSecretStore = FakeSecrets()
    let theme: HostTheme = HostTheme(tokens(themeID: "test"))
    let log: PluginLogger = FakeLogger()
    let apps: PluginAppLauncher = FakeAppLauncher()
    let presentation: PluginPresentationControl = FakePresentationControl()
    /// Generation 9. A no-op is right for a fake: the tests are about Rune, not
    /// about what the host does with an event.
    let signals: PluginSignalEmitter = NoopSignalEmitter()
    let context: PluginContextRegistry
    let actions: AgentActionProvider

    /// Keeps every fake host alive for the whole test process. `TerminalRuntime`
    /// keys its per-host `bridges` map by `ObjectIdentifier(host)` (address-based)
    /// and never removes entries — mirroring the production `stores` pattern. If a
    /// short-lived fake host deallocated, its address could be reused by a later
    /// test, colliding with the stale bridge entry and defeating register-once.
    /// Retaining every instance guarantees each test's host has a unique identity.
    private static var liveInstances: [FakeHostServices] = []

    init(context: PluginContextRegistry, actions: AgentActionProvider = RecordingActionRegistry()) {
        self.context = context
        self.actions = actions
        Self.liveInstances.append(self)
    }
}
