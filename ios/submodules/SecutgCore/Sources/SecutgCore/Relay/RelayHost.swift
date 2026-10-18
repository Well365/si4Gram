import Foundation

/// A relay base address, classified the way PLAN.md 3.48.1 / 3.48.4 need: structural validity for the `u`
/// field, plus the "insecure connection" / "local network address" facts the receiving card and the settings
/// gate on. Checked against the Web oracle's `host.ts` (`isValidRelayAddress` / `classifyRelayHost`) field by
/// field — in particular, validity does NOT depend on the host's letter case (only the scheme does, and only
/// because the oracle's grammar is lowercase-literal `https?`), so `classify` never lowercases-then-compares.
///
/// Identification of an `L1:` message never depends on this type (shape alone decides that, in `RelayL1`); this
/// type only decides what the *address itself* means once a wire has already been accepted.
public struct RelayHost: Equatable {
    public let urlString: String
    public let scheme: String
    public let host: String
    public let port: Int?
    public let isSecure: Bool
    public let isLAN: Bool

    /// Strict: `scheme://host[:port]` only — lowercase `http`/`https`, no userinfo, no path (not even `/`), no
    /// query, no fragment. `host` keeps whatever case the input had (the oracle never normalises it either);
    /// `urlString` is the input unchanged, since by the time every other check has passed, the input already
    /// IS the canonical form.
    public static func classify(_ urlString: String) -> RelayHost? {
        guard let components = URLComponents(string: urlString) else { return nil }
        // Case-sensitive on purpose: the oracle's grammar is the literal `https?`, not `[Hh][Tt][Tt][Pp]...`.
        guard let scheme = components.scheme, scheme == "http" || scheme == "https" else { return nil }
        guard components.user == nil, components.password == nil else { return nil }
        guard components.query == nil, components.fragment == nil else { return nil }
        guard components.path.isEmpty else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        if let port = components.port {
            guard port >= 1 && port <= 65535 else { return nil }
        }
        return RelayHost(urlString: urlString, scheme: scheme, host: host, port: components.port, isSecure: scheme == "https", isLAN: classifyLAN(host))
    }

    /// Lenient: trims whitespace and normalises a user-typed address (settings → 添加中转) into the canonical,
    /// lowercase-scheme-and-host form this app stores — a convenience for OUR OWN storage, unrelated to (and
    /// looser than, by design) the strict byte-for-byte grammar `classify` checks an already-received wire
    /// against. nil when it cannot be made into one at all (unsupported scheme, no host, credentials, query,
    /// fragment, or any path).
    public static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard components.user == nil, components.password == nil else { return nil }
        guard components.query == nil, components.fragment == nil else { return nil }
        guard components.path.isEmpty || components.path == "/" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        if let port = components.port {
            guard port >= 1 && port <= 65535 else { return nil }
        }
        let portSuffix = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(portSuffix)"
    }

    // MARK: - LAN classification (mirrors host.ts's isLanHost/isPrivateIpv4/isPrivateIpv6 exactly)

    /// `localhost`, `*.local`, loopback/private/"this network" IPv4, and loopback/unspecified/link-local/
    /// unique-local IPv6 — PLAN.md 3.48.4's "局域网地址". Case-insensitive (the oracle lowercases before every
    /// comparison here, even though `host` itself is returned with its original case).
    private static func classifyLAN(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") { return true }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return isPrivateIPv6(String(host.dropFirst().dropLast()))
        }
        if let ipv4 = parseIPv4(host) { return isPrivateIPv4(ipv4) }
        return false
    }

    private static func parseIPv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0, value <= 255, part == String(value) else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch octets[0] {
        case 0: return true // "this network"
        case 10: return true // 10.0.0.0/8
        case 127: return true // loopback
        case 169: return octets[1] == 254 // link-local
        case 172: return octets[1] >= 16 && octets[1] <= 31 // 172.16.0.0/12
        case 192: return octets[1] == 168 // 192.168.0.0/16
        default: return false
        }
    }

    private static func isPrivateIPv6(_ bracketed: String) -> Bool {
        let lower = bracketed.lowercased()
        if lower == "::1" || lower == "::" { return true } // loopback / unspecified
        if lower.range(of: "^f[cd][0-9a-f]{2}:", options: .regularExpression) != nil { return true } // fc00::/7
        if lower.range(of: "^fe[89ab][0-9a-f]:", options: .regularExpression) != nil { return true } // fe80::/10
        return false
    }
}
