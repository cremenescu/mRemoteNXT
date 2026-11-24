// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation
import MRNGCore

/// 1Password as the app uses it: finds op, reads items, remembers what picked items are called.
/// Nothing that is read is kept here; a logon lives in the session that asked for it.
@MainActor
final class OnePasswordService: ObservableObject {
    static let shared = OnePasswordService()

    enum Tool: Equatable {
        case unknown, missing
        case found(path: String, version: String)
    }
    /// For Settings; see checkTool().
    @Published private(set) var tool: Tool = .unknown

    /// The shell's PATH, asked for once and only when op is not in the usual places.
    private var shellPath: String?
    private var askedShell = false

    func cli() async throws -> OnePasswordCLI {
        if let found = OnePasswordCLI.find() { return OnePasswordCLI(executable: found) }
        if !askedShell {
            askedShell = true
            shellPath = await OnePasswordCLI.shellPath()
        }
        guard let found = OnePasswordCLI.find(path: shellPath) else { throw OnePasswordError.notInstalled }
        return OnePasswordCLI(executable: found)
    }

    /// Reads the item a connection refers to. Puts up 1Password's prompt unless the app was
    /// allowed to read a moment ago.
    func item(_ reference: String) async throws -> OnePasswordItem {
        guard let parsed = OnePasswordReference(reference) else { throw OnePasswordError.badReference(reference) }
        let item = try await cli().item(parsed)
        OnePasswordNames.shared.remember(parsed, title: item.title, vault: item.vaultName)
        return item
    }

    func checkTool() async {
        askedShell = false
        do {
            let cli = try await cli()
            tool = .found(path: cli.executable.path, version: try await cli.version())
        } catch {
            tool = .missing
        }
    }
}

/// What the items referred to by identifier are called. The file only has the identifiers;
/// the names are for this Mac's editor and stay on it.
@MainActor
final class OnePasswordNames {
    static let shared = OnePasswordNames()

    struct Name: Codable, Equatable {
        var title: String
        var vault: String
    }

    private let file = AppSupport.directory.appendingPathComponent("1password-names.json")
    private lazy var names: [String: Name] =
        (try? JSONDecoder().decode([String: Name].self, from: Data(contentsOf: file))) ?? [:]

    func name(of reference: String) -> Name? {
        OnePasswordReference(reference).flatMap { names[Self.key($0)] }
    }

    func remember(_ reference: OnePasswordReference, title: String, vault: String) {
        guard reference.isByID, !title.isEmpty else { return }
        let name = Name(title: title, vault: vault), key = Self.key(reference)
        guard names[key] != name else { return }
        names[key] = name
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Without the account: it only says which copy of 1Password's data to ask.
    private static func key(_ r: OnePasswordReference) -> String { r.vault + "/" + r.item }
}

/// The app's folder in Application Support, created when first asked for.
enum AppSupport {
    static var directory: URL {
        let fm = FileManager.default
        let base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("mRemoteNXT", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

/// Why a logon could not be had, beyond what op itself reports.
enum LogonError: Error {
    /// The item is an SSH key and the 1Password agent, which signs with it, is off.
    case agentOff
    /// The item has no password, and this kind of connection needs one.
    case noPassword
}

/// What a tab says when its logon could not be read.
struct LogonFailure: Equatable {
    /// Which of the session's logons it is.
    let part: LogonPart
    let message: String
    /// op's own words, when they add something.
    var detail = ""
    /// The file holds a password that could be used instead.
    let fileHasPassword: Bool
}

extension OnePasswordService {
    /// The message for the user, and op's own words where they say more than it does.
    static func describe(_ error: Error, reference: String) -> (message: String, detail: String) {
        switch error {
        case LogonError.agentOff: return (t("OnePassword.Error.AgentOff"), "")
        case LogonError.noPassword: return (t("OnePassword.Error.NoPassword"), "")
        case is CancellationError: return (t("OnePassword.Error.Stopped"), "")
        case let error as OnePasswordError:
            switch error {
            case .notInstalled: return (t("OnePassword.Error.NotInstalled"), "")
            case .badReference(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed.isEmpty ? t("OnePassword.Error.NoItem")
                                        : String(format: t("OnePassword.Error.BadReference"), trimmed), "")
            case .notIntegrated(let words): return (t("OnePassword.Error.NotIntegrated") + permissionHint, words)
            case .declined: return (t("OnePassword.Error.Declined"), "")
            case .timedOut: return (t("OnePassword.Error.TimedOut"), "")
            case .notFound(let words):
                // The common case, in the file's own terms. A vault or account that is not
                // there is told by op, which says which of them it is.
                if words.contains("an item"), let r = OnePasswordReference(reference), !r.vault.isEmpty {
                    let name = OnePasswordNames.shared.name(of: reference)
                    return (String(format: t("OnePassword.Error.NoSuchItem"), name?.title ?? r.item, name?.vault ?? r.vault), "")
                }
                return (t("OnePassword.Error.NotFound"), words)
            case .ambiguous(let words): return (t("OnePassword.Error.Ambiguous"), words)
            case .noSecret: return (t("OnePassword.Error.NoSecret"), "")
            case .unreadableAnswer: return (t("OnePassword.Error.UnreadableAnswer"), "")
            case .failed(let words): return (t("OnePassword.Error.Failed") + permissionHint, words)
            }
        default:
            return (error.localizedDescription, "")
        }
    }

    /// macOS 27 asks before an app may read data another one shares, and a "no" there looks
    /// to op as if 1Password were not running.
    private static var permissionHint: String {
        let macOS27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(macOS27) ? " " + t("OnePassword.Error.Permission") : ""
    }
}
