// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// Microsoft's .rdp connection files, and the rdp:// links that carry the same settings.
///
/// The format is one setting per line, `name:type:value`, where type is `s` (string), `i`
/// (integer) or `b` (binary, hex). Names are case-insensitive and may contain spaces
/// ("full address"). mstsc writes the file as UTF-16LE with a BOM; most other tools write
/// UTF-8.
///
/// Only what has a home in mRemoteNG's own attributes is carried over, so the connection
/// stays the same when the file is opened by mRemoteNG on Windows. Passwords never are:
/// mstsc stores them DPAPI-encrypted, readable only by the Windows account that saved them.
public enum RDPFile {

    /// Settings by lowercased name, values without their type prefix.
    public typealias Settings = [String: String]

    // MARK: - Reading

    public static func parse(data: Data) -> Settings {
        parse(text: decode(data))
    }

    public static func parse(text: String) -> Settings {
        var out: Settings = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // name:type:value — the name may hold spaces but no colon, the value may hold
            // anything (a host with a port, a path).
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, ["s", "i", "b"].contains(parts[1].lowercased()) else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            out[name] = String(parts[2])
        }
        return out
    }

    /// `rdp://full%20address=s:host:3389&username=s:me` — Microsoft's Remote Desktop URI
    /// scheme: the same settings, as `name=type:value` pairs joined by `&`. nil when the
    /// string is not such a link.
    public static func parse(uri: String) -> Settings? {
        guard let schemeEnd = uri.range(of: "://"), uri[..<schemeEnd.lowerBound].lowercased() == "rdp"
        else { return nil }
        var body = String(uri[schemeEnd.upperBound...])
        if body.hasSuffix("/") { body.removeLast() }
        var lines: [String] = []
        for pair in body.split(separator: "&") {
            let decoded = (String(pair).removingPercentEncoding ?? String(pair))
            guard let eq = decoded.firstIndex(of: "=") else { continue }
            lines.append(decoded[..<eq] + ":" + decoded[decoded.index(after: eq)...])
        }
        let settings = parse(text: lines.joined(separator: "\n"))
        return settings.isEmpty ? nil : settings
    }

    /// The text of a file in whichever encoding it was saved.
    private static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        }
        // No BOM: UTF-16 still shows itself by a zero in every other byte of ASCII text.
        let sample = data.prefix(64)
        if sample.count >= 4, sample.enumerated().filter({ $0.offset % 2 == 1 && $0.element == 0 }).count > sample.count / 4 {
            return String(data: data, encoding: .utf16LittleEndian) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    }

    // MARK: - Mapping

    /// The address to connect to and its port, nil when the settings name no host.
    public static func address(_ s: Settings) -> (host: String, port: Int)? {
        let raw = (s["full address"] ?? "").isEmpty ? (s["alternate full address"] ?? "") : (s["full address"] ?? "")
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let fallbackPort = Int(s["server port"] ?? "") ?? 3389
        return splitHostPort(value, defaultPort: fallbackPort)
    }

    /// `host:port`, with an IPv6 address written in brackets when it carries a port.
    public static func splitHostPort(_ value: String, defaultPort: Int) -> (host: String, port: Int) {
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { return (host, p) }
            return (host, defaultPort)
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let p = Int(parts[1]) { return (String(parts[0]), p) }
        return (value, defaultPort)
    }

    /// Whether the file had a saved password that could not be carried over.
    public static func hadPassword(_ s: Settings) -> Bool {
        !(s["password 51"] ?? "").isEmpty
    }

    /// A new RDP connection with the settings mapped onto mRemoteNG's attributes, nil when
    /// there is no address to connect to.
    public static func makeConnection(name: String, settings s: Settings) -> MRNGNode? {
        guard let (host, port) = address(s) else { return nil }
        let node = MRNGNode.makeConnection(name: name.isEmpty ? host : name,
                                           protocolType: "RDP", hostname: host)
        var a = node.attributes
        a["Port"] = String(port)

        // DOMAIN\user is how mstsc saves an account; split it so the domain lands in its
        // own field, as a connection typed in here would have it. user@domain stays whole.
        var user = s["username"] ?? ""
        var domain = s["domain"] ?? ""
        if domain.isEmpty, let r = user.range(of: "\\") {
            domain = String(user[..<r.lowerBound])
            user = String(user[r.upperBound...])
        }
        a["Username"] = user
        a["Domain"] = domain

        // Gateway. gatewayusagemethod: 1 always, 2 detect, 0 and 4 never, 3 "the default".
        let gwHost = (s["gatewayhostname"] ?? "").trimmingCharacters(in: .whitespaces)
        if !gwHost.isEmpty {
            switch s["gatewayusagemethod"] {
            case "0", "4": a["RDGatewayUsageMethod"] = "Never"
            case "2": a["RDGatewayUsageMethod"] = "Detect"
            default: a["RDGatewayUsageMethod"] = "Always"
            }
            a["RDGatewayHostname"] = gwHost
            let gwUser = s["gatewayusername"] ?? ""
            if s["gatewaycredentialssource"] == "1" {
                a["RDGatewayUseConnectionCredentials"] = "SmartCard"
            } else if !gwUser.isEmpty || s["promptcredentialonce"] == "0" {
                a["RDGatewayUseConnectionCredentials"] = "No"
                a["RDGatewayUsername"] = gwUser
                a["RDGatewayDomain"] = s["gatewaydomain"] ?? ""
            } else {
                a["RDGatewayUseConnectionCredentials"] = "Yes"
            }
        }

        func flag(_ key: String) -> String? {
            guard let v = s[key] else { return nil }
            return v == "0" ? "false" : "true"
        }
        if let v = flag("redirectprinters") { a["RedirectPrinters"] = v }
        if let v = flag("redirectsmartcards") { a["RedirectSmartCards"] = v }
        if let v = flag("redirectcomports") { a["RedirectPorts"] = v }
        // Drives are left alone on purpose: here the attribute shares the folder chosen in
        // Settings, and a file someone sent should not be what turns that on.
        switch s["audiomode"] {
        case "0": a["RedirectSound"] = "BringToThisComputer"
        case "1": a["RedirectSound"] = "LeaveAtRemoteComputer"
        case "2": a["RedirectSound"] = "DoNotPlay"
        default: break
        }
        switch s["session bpp"] {
        case "8": a["Colors"] = "Colors256"
        case "15": a["Colors"] = "Colors15Bit"
        case "16": a["Colors"] = "Colors16Bit"
        case "24": a["Colors"] = "Colors24Bit"
        case "32": a["Colors"] = "Colors32Bit"
        default: break
        }
        if s["screen mode id"] == "2" {
            a["Resolution"] = "Fullscreen"
        } else if s["smart sizing"] == "1" {
            a["Resolution"] = "SmartSize"
        }
        switch s["authentication level"] {
        case "0": a["RDPAuthenticationLevel"] = "NoAuth"
        case "1": a["RDPAuthenticationLevel"] = "AuthRequired"
        case "2": a["RDPAuthenticationLevel"] = "WarnOnFailedAuth"
        default: break
        }
        if s["enablecredsspsupport"] == "0" { a["UseCredSsp"] = "false" }
        if s["administrative session"] == "1" || s["connect to console"] == "1" {
            a["ConnectToConsole"] = "true"
        }
        if let lb = s["loadbalanceinfo"], !lb.isEmpty { a["LoadBalanceInfo"] = lb }

        node.attributes = a
        return node
    }
}
