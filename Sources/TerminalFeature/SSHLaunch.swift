import Foundation
import AinkradAppKit

/// Terminal's view of the SSH launch contract.
///
/// The wire type is now `AinkradAppKit.SSHLaunchPayload` — ONE definition
/// shared with Leyline, versioned and validated. This file used to hold a
/// second, independent `Decodable` mirror of Leyline's `Encodable` struct: two
/// hand-synced definitions of one format across two repos, with nothing to
/// detect the moment they diverged.
///
/// `SSHLaunch` remains as a thin alias so the rest of Terminal is unchanged.
typealias SSHLaunch = SSHLaunchPayload

extension SSHLaunchPayload {
    /// Decodes a pending launch payload, **rejecting anything unsafe**.
    ///
    /// `validated()` is what stops `-oProxyCommand=<cmd>` and friends: every
    /// field here ends up in an `ssh` argv, and `ssh`'s option surface runs
    /// shell commands. Returning nil on a bad payload means a hostile launch
    /// opens a plain terminal instead of executing something.
    static func pending(from json: String?) -> SSHLaunchPayload? {
        guard let payload = SSHLaunchPayload(json: json) else { return nil }
        return try? payload.validated()
    }
}

/// Builds the `/usr/bin/ssh` invocation for a launch.
enum SSHInvocation {
    static let executable = "/usr/bin/ssh"
    static func argv(_ l: SSHLaunch) -> [String] {
        var a: [String] = []
        if let f = l.identityFile, !f.isEmpty { a += ["-i", f] }
        if l.port != 22 { a += ["-p", String(l.port)] }
        a.append(l.username.isEmpty ? l.host : "\(l.username)@\(l.host)")
        return a
    }
}
