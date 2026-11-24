// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

// Credentials kept in 1Password instead of the file, as mRemoteNG does it: the connection
// holds a reference (ExternalCredentialProvider="OnePassword" + UserViaAPI="op://vault/item")
// and the 1Password command line tool, op, reads the item when the connection is opened.

/// A reference to an item, in the form mRemoteNG stores it: `op://<vault>/<item>?account=<account>`.
public struct OnePasswordReference: Equatable {
    /// The value of ExternalCredentialProvider that selects 1Password.
    public static let providerName = "OnePassword"

    public var vault: String
    public var item: String
    /// Empty unless the reference names an account, which is only needed with several.
    public var account: String

    public init(vault: String, item: String, account: String = "") {
        self.vault = vault
        self.item = item
        self.account = account
    }

    /// Reads a reference as it stands in a file. Decoded the way mRemoteNG decodes it
    /// (percent escapes, and "+" for a space) so both apps look for the same item; unlike
    /// mRemoteNG, whose URI parser refuses them, plain spaces are fine anywhere.
    ///
    /// Everything after the vault is the item, also as in mRemoteNG: an item may have a
    /// slash in its name. `pasted` is for the other case.
    public init?(_ text: String) {
        guard let parts = Self.split(text) else { return nil }
        let item = Self.decode(parts.path)
        // A lone dash would have op read the item's name from standard input.
        guard !item.isEmpty, item != "-" else { return nil }
        self.init(vault: Self.decode(parts.vault), item: item, account: parts.account)
    }

    /// Reads what "Copy Secret Reference" in 1Password puts on the clipboard, which names a
    /// field: `op://vault/item/field` or `op://vault/item/section/field`. The field is
    /// dropped. Surrounding quotes, which 1Password adds when a name has spaces, go too.
    public init?(pasted text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, let quote = trimmed.first, quote == "\"" || quote == "'", trimmed.last == quote {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        guard let parts = Self.split(trimmed) else { return nil }
        let item = parts.path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let decoded = Self.decode(item)
        guard !decoded.isEmpty, decoded != "-" else { return nil }
        self.init(vault: Self.decode(parts.vault), item: decoded, account: parts.account)
    }

    /// The reference to write in the file. Identifiers and ordinary names need no escaping;
    /// what would be read back as something else is escaped.
    public var text: String {
        var out = "op://" + Self.encode(vault) + "/" + Self.encode(item)
        if !account.isEmpty { out += "?account=" + Self.encode(account) }
        return out
    }

    private static func split(_ text: String) -> (vault: String, path: String, account: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("op://") else { return nil }
        var rest = String(trimmed.dropFirst("op://".count))
        var account = ""
        if let mark = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: mark)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2, kv[0].lowercased() == "account" { account = decode(String(kv[1])) }
            }
            rest = String(rest[..<mark])
        }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let path = rest[rest.index(after: slash)...].drop { $0 == "/" }
        return (String(rest[..<slash]), String(path), account)
    }

    private static func decode(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "+", with: " ")
        return (spaced.removingPercentEncoding ?? spaced).trimmingCharacters(in: .whitespaces)
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?&=+%#;")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// What a connection takes from an item.
public struct OnePasswordCredentials: Equatable {
    public var username: String
    public var password: String
    public var domain: String
    /// The public half of an SSH Key item, in authorized_keys form. The private half is
    /// never read out of the answer: ssh gets the key from the 1Password agent.
    public var publicKey: String

    public init(username: String = "", password: String = "", domain: String = "", publicKey: String = "") {
        self.username = username
        self.password = password
        self.domain = domain
        self.publicKey = publicKey
    }
}

/// An item, as `op item get --format json` describes it.
public struct OnePasswordItem: Equatable {
    public var title: String
    public var vaultName: String
    public var credentials: OnePasswordCredentials

    private struct Field: Decodable {
        var id: String?
        var type: String?
        var purpose: String?
        var label: String?
        var value: String?
    }
    private struct Vault: Decodable { var name: String? }
    private struct Payload: Decodable {
        var title: String?
        var vault: Vault?
        var fields: [Field]?
    }

    /// The fields are matched by mRemoteNG's rules: first by purpose, which Login items have,
    /// then a text field by id, then by label. Concealed fields count as text for the
    /// password, because the password of a Server item has no purpose and is concealed —
    /// the one case mRemoteNG misses (mRemoteNG/mRemoteNG#3092).
    public init(json: Data) throws {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json) else {
            throw OnePasswordError.unreadableAnswer
        }
        let fields = payload.fields ?? []

        func value(_ match: (Field) -> Bool) -> String? {
            fields.first { match($0) && !($0.value ?? "").isEmpty }?.value
        }
        func find(purpose: String, named name: String, types: Set<String>) -> String {
            value { $0.purpose == purpose }
                ?? value { types.contains($0.type ?? "") && $0.id?.lowercased() == name }
                ?? value { types.contains($0.type ?? "") && $0.label?.lowercased() == name }
                ?? ""
        }

        let hasKey = fields.contains { $0.type == "SSHKEY" }
        credentials = OnePasswordCredentials(
            username: find(purpose: "USERNAME", named: "username", types: ["STRING"]),
            password: find(purpose: "PASSWORD", named: "password", types: ["STRING", "CONCEALED"]),
            domain: value { $0.type == "STRING" && $0.label?.lowercased() == "domain" } ?? "",
            publicKey: hasKey ? Self.firstLine(value { $0.id == "public_key" || $0.label?.lowercased() == "public key" }) : ""
        )
        title = payload.title ?? ""
        vaultName = payload.vault?.name ?? ""
        guard hasKey || !credentials.password.isEmpty else { throw OnePasswordError.noSecret }
    }

    /// A key is one line; anything after it would become further lines of the file ssh reads.
    private static func firstLine(_ s: String?) -> String {
        (s ?? "").split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// One row of the item picker. Comes from `op item list`, which answers without secrets.
public struct OnePasswordListedItem: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let vaultID: String
    public let vaultName: String
    public let category: String
    /// The line 1Password shows under the title, usually the user name.
    public let detail: String

    private struct Vault: Decodable { var id: String?; var name: String? }
    private struct Payload: Decodable {
        var id: String
        var title: String?
        var vault: Vault?
        var category: String?
        var additional_information: String?
        var state: String?
    }

    public static func list(json: Data) throws -> [OnePasswordListedItem] {
        guard let rows = try? JSONDecoder().decode([Payload].self, from: json) else {
            throw OnePasswordError.unreadableAnswer
        }
        return rows
            .filter { $0.state != "ARCHIVED" }
            .map {
                // op fills the line with a lone dash when there is nothing to say.
                let detail = $0.additional_information ?? ""
                return OnePasswordListedItem(id: $0.id, title: $0.title ?? "", vaultID: $0.vault?.id ?? "",
                                             vaultName: $0.vault?.name ?? "", category: $0.category ?? "",
                                             detail: detail == "—" || detail == "-" ? "" : detail)
            }
            .sorted { ($0.title.lowercased(), $0.vaultName.lowercased(), $0.id) < ($1.title.lowercased(), $1.vaultName.lowercased(), $1.id) }
    }
}

/// A 1Password account op knows about.
public struct OnePasswordAccount: Identifiable, Equatable {
    public let id: String
    public let email: String
    public let url: String

    private struct Payload: Decodable {
        var account_uuid: String?
        var email: String?
        var url: String?
    }

    public static func list(json: Data) throws -> [OnePasswordAccount] {
        guard let rows = try? JSONDecoder().decode([Payload].self, from: json) else {
            throw OnePasswordError.unreadableAnswer
        }
        return rows.compactMap { row in
            guard let id = row.account_uuid, !id.isEmpty else { return nil }
            return OnePasswordAccount(id: id, email: row.email ?? "", url: row.url ?? "")
        }
    }
}

public enum OnePasswordError: Error, Equatable {
    /// op is not installed, or not where it is looked for.
    case notInstalled
    /// The connection's reference is empty or not of the op:// form.
    case badReference(String)
    /// The app integration is off: no accounts, or the 1Password app can't be reached.
    case notIntegrated(String)
    /// The authorization prompt was dismissed.
    case declined
    /// Nobody answered the prompt, or op did not finish.
    case timedOut
    /// No such item, vault or account.
    case notFound(String)
    /// Several items match the name.
    case ambiguous(String)
    /// The item has neither a password nor an SSH key.
    case noSecret
    case unreadableAnswer
    /// Anything else, in op's own words.
    case failed(String)

    /// Sorts op's message into the cases above. The messages are not a documented contract,
    /// so what matches nothing is passed on as it is rather than explained wrongly.
    public static func classify(_ stderr: String) -> OnePasswordError {
        let message = clean(stderr)
        let low = message.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { low.contains($0) } }

        if has("prompt dismissed", "authorization denied", "user denied", "was cancelled", "was canceled") { return .declined }
        if has("authorization timeout", "timed out", "timeout waiting") { return .timedOut }
        if has("no accounts configured", "connecting to desktop app", "not currently signed in",
               "desktop app integration", "cannot connect to 1password app", "account is not signed in") {
            return .notIntegrated(message)
        }
        if has("more than one item matches") { return .ambiguous(message) }
        if has("isn't an item", "isn't a vault", "isn’t an item", "isn’t a vault", "no item found",
               "found no accounts", "no account found", "item not found") {
            return .notFound(message)
        }
        return .failed(message)
    }

    /// Drops op's "[ERROR] 2026/11/24 19:00:00 " prefix and keeps it to a readable length.
    static func clean(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { line -> String in
            line.replacingOccurrences(of: #"^\[[A-Z]+\]\s+\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+"#,
                                      with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return String(lines.filter { !$0.isEmpty }.joined(separator: "\n").prefix(600))
    }
}
