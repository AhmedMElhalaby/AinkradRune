import Testing
import Foundation
import AinkradAppKit
@testable import TerminalFeature

/// Covers Terminal's resources-only MCP surface. Every test drives the real
/// `MCPAppServer` over JSON-RPC rather than calling the providers directly, so
/// what is asserted is what the assistant actually sees. No real terminal
/// process is involved — the bridge's source is `FakeBufferSource`.
@Suite("TerminalMCPServer")
@MainActor
struct TerminalMCPServerTests {
    /// Builds a server plus its bridge, attaching `source` when given.
    ///
    /// The source is returned so the CALLER holds the only strong reference:
    /// the bridge keeps it weakly by design, so a fake created and dropped
    /// inside this helper would deallocate before the resource is ever read and
    /// every "live source" test would silently exercise the nil path instead.
    private func makeServer(source: FakeBufferSource? = nil)
        -> (server: MCPAppServer, bridge: TerminalContextBridge,
            source: FakeBufferSource?, failures: [String]) {
        let bridge = TerminalContextBridge()
        if let source { bridge.setActiveSource(source) }
        let (server, failures) = TerminalMCPServer.make(appID: "terminal", bridge: bridge)
        return (server, bridge, source, failures)
    }

    /// Sends one request and returns its decoded `result` object.
    private func call(_ server: MCPAppServer, _ method: String,
                      params: [String: Any] = [:]) async throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let reply = await server.handle(json)
        let root = try #require(
            (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any])
        #expect(root["error"] == nil, "unexpected JSON-RPC error: \(reply)")
        return try #require(root["result"] as? [String: Any])
    }

    /// Reads one resource's text via `resources/read`.
    private func read(_ server: MCPAppServer, _ uri: String) async throws -> String {
        let result = try await call(server, "resources/read", params: ["uri": uri])
        let contents = try #require(result["contents"] as? [[String: Any]])
        return try #require(contents.first?["text"] as? String)
    }

    // MARK: - registration

    @Test("every addResource call succeeded")
    func noRegistrationFailures() {
        #expect(makeServer().failures.isEmpty)
    }

    @Test("resources/list reports both resources", .timeLimit(.minutes(1)))
    func listsBothResources() async throws {
        let result = try await call(makeServer().server, "resources/list")
        let resources = try #require(result["resources"] as? [[String: Any]])
        let uris = resources.compactMap { $0["uri"] as? String }.sorted()
        #expect(uris == ["terminal://buffer", "terminal://cwd"])
    }

    @Test("no tools are published", .timeLimit(.minutes(1)))
    func publishesNoTools() async throws {
        // Resources-only is the design, not an oversight: `run_terminal` stays
        // host-owned and `terminal.echo` is host→app plumbing.
        let result = try await call(makeServer().server, "tools/list")
        #expect((result["tools"] as? [[String: Any]])?.isEmpty == true)
    }

    /// Pins the judgement call recorded in `TerminalMCPServer`: the flag means
    /// "opening the app makes this work", and opening a closed Terminal yields a
    /// FRESH, EMPTY buffer — the previous session is not restored — so opening
    /// does not make the requested data appear. Flipping either of these to true
    /// must fail here.
    @Test("requiresLiveApp is false on both resources", .timeLimit(.minutes(1)))
    func requiresLiveAppIsFalse() async throws {
        let result = try await call(makeServer().server, "resources/list")
        let resources = try #require(result["resources"] as? [[String: Any]])
        #expect(resources.count == 2)
        for resource in resources {
            let annotations = resource["annotations"] as? [String: Any]
            let uri = resource["uri"] as? String ?? "?"
            #expect(annotations?["ainkrad/requiresLiveApp"] as? Bool == false,
                    "\(uri) must not force the app open: a fresh Terminal comes up empty, so opening it cannot answer the question")
        }
    }

    // MARK: - live source

    @Test("buffer resource returns the active terminal's scrollback", .timeLimit(.minutes(1)))
    func bufferReturnsScrollback() async throws {
        let (server, _, source, _) = makeServer(source: FakeBufferSource(buffer: "hello scrollback"))
        #expect(try await read(server, TerminalMCPServer.bufferResourceURI) == "hello scrollback")
        withExtendedLifetime(source) {}
    }

    @Test("cwd resource returns the working directory", .timeLimit(.minutes(1)))
    func cwdReturnsDirectory() async throws {
        let (server, _, source, _) = makeServer(source: FakeBufferSource(buffer: "x", cwd: "/Users/x/proj"))
        #expect(try await read(server, TerminalMCPServer.cwdResourceURI) == "/Users/x/proj")
        withExtendedLifetime(source) {}
    }

    /// THE point of the resource. The push-based `<workspace_context>` snapshot
    /// tail-truncates at 8000 chars; this pull-based resource exists so the model
    /// can get the rest. If it truncated too, it would answer the same question
    /// the model already had an answer to.
    @Test("buffer resource is NOT truncated at 8000 chars", .timeLimit(.minutes(1)))
    func bufferIsNotTruncated() async throws {
        let long = String(repeating: "a", count: 20_000) + "TAIL-MARKER"
        let source = FakeBufferSource(buffer: long)
        let (server, bridge, _, _) = makeServer(source: source)

        let text = try await read(server, TerminalMCPServer.bufferResourceURI)
        #expect(text == long)
        #expect(text.count == long.count)
        #expect(!text.contains("earlier output truncated"))

        // And the push path is UNCHANGED — still bounded, still carrying the
        // truncation marker. The two paths must not have been collapsed.
        let snapshot = bridge.snapshot()
        #expect(snapshot?.text.contains("earlier output truncated") == true)
        #expect((snapshot?.text.count ?? 0) < long.count)
        withExtendedLifetime(source) {}
    }

    @Test("an empty live buffer is returned as empty, not as the no-terminal message",
          .timeLimit(.minutes(1)))
    func emptyLiveBufferIsDistinguishable() async throws {
        let (server, _, source, _) = makeServer(source: FakeBufferSource(buffer: ""))
        #expect(try await read(server, TerminalMCPServer.bufferResourceURI) == "")
        withExtendedLifetime(source) {}
    }

    // MARK: - no terminal open

    @Test("buffer resource explains that no terminal is open", .timeLimit(.minutes(1)))
    func bufferWithoutSource() async throws {
        let text = try await read(makeServer().server, TerminalMCPServer.bufferResourceURI)
        #expect(text == TerminalMCPServer.noTerminalMessage)
        #expect(!text.isEmpty)
        // Actionable, not just a status: it must tell the model what to do next.
        #expect(text.contains("open"))
    }

    @Test("cwd resource explains that no terminal is open", .timeLimit(.minutes(1)))
    func cwdWithoutSource() async throws {
        let text = try await read(makeServer().server, TerminalMCPServer.cwdResourceURI)
        #expect(text == TerminalMCPServer.noTerminalMessage)
    }

    @Test("a deallocated terminal view falls back to the no-terminal message",
          .timeLimit(.minutes(1)))
    func bufferAfterSourceDeallocates() async throws {
        let bridge = TerminalContextBridge()
        do {
            let source = FakeBufferSource(buffer: "gone")
            bridge.setActiveSource(source)
        }
        let (server, _) = TerminalMCPServer.make(appID: "terminal", bridge: bridge)
        // The bridge holds the source weakly, so this exercises the nil path
        // without crashing.
        #expect(try await read(server, TerminalMCPServer.bufferResourceURI)
                == TerminalMCPServer.noTerminalMessage)
    }

    @Test("a live terminal with no OSC 7 cwd says so distinctly", .timeLimit(.minutes(1)))
    func cwdUnknownButTerminalOpen() async throws {
        let (server, _, source, _) = makeServer(source: FakeBufferSource(buffer: "x", cwd: nil))
        let text = try await read(server, TerminalMCPServer.cwdResourceURI)
        withExtendedLifetime(source) {}
        #expect(text != TerminalMCPServer.noTerminalMessage)
        #expect(text.contains("pwd"))
    }
}
