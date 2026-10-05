// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// What the app and its File Provider extension share about files copied in a remote
/// session. Compiled into both targets; the two processes meet only through the app group
/// container, never through memory.
///
/// The extension cannot talk to an RDP session — that lives in the app. So the app
/// publishes the remote clipboard's file list here as a manifest, the extension turns it
/// into items the Finder can see, and when the Finder copies one the extension leaves a
/// request file that the app answers by streaming the bytes from the remote into a
/// transfer file next to it.
enum RemoteClipboard {
    /// Team-prefixed: on macOS that is what lets a Developer ID app and its extension share
    /// a container without a provisioning profile.
    static let appGroup = "FU62DHV366.ro.cremenescu.mRemoteNXT"
    static let domainIdentifier = "RemoteClipboard"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("RemoteClipboard", isDirectory: true)
    }
    static var manifestURL: URL? { container?.appendingPathComponent("manifest.json") }

    /// A line in `diag.log` next to the manifest, from either process. The unified log is not
    /// readable from everywhere a problem has to be looked at, and this one is a plain file
    /// both halves can write. Kept under a megabyte: the older half is dropped.
    static func log(_ message: String, file: String = #fileID) {
        guard let url = container?.appendingPathComponent("diag.log") else { return }
        let who = Bundle.main.bundleIdentifier?.hasSuffix(".RemoteClipboard") == true ? "ext" : "app"
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(who)] \(message)\n"
        logQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 1_000_000,
               let data = try? Data(contentsOf: url) {
                try? data.suffix(500_000).write(to: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
    private static let logQueue = DispatchQueue(label: "mRemoteNXT.remote-clipboard.log")
    static var requestsDir: URL? { container?.appendingPathComponent("requests", isDirectory: true) }
    static var transfersDir: URL? { container?.appendingPathComponent("transfers", isDirectory: true) }

    /// Error codes the app writes into a transfer's `.error` file.
    enum Failure: Int, Codable {
        case sessionGone = 1     // the session the files came from is closed, or the app restarted
        case refused = 2         // the remote declined: its clipboard changed since the copy
        case timeout = 3         // the remote stopped answering
        case cancelled = 4
        case io = 5              // writing the transfer file failed
    }

    /// One copy made in a remote session. Its files appear under a folder of their own, so
    /// a later copy of a file with the same name never collides with one still being pasted.
    struct Generation: Codable {
        var id: String           // short, unique; prefixes every item identifier below it
        var folder: String       // the folder's name in the domain
        var entries: [Entry]
        /// When the copy was made: the date of its folder, and of folders the remote only implied.
        var created: Date?
    }

    struct Entry: Codable {
        var path: [String]       // sanitised components, relative to the copy
        var index: UInt32        // position in the remote's list: what the bytes are asked by
        var isDirectory: Bool
        var size: Int64?
        var modified: Date?
    }

    struct Manifest: Codable {
        var revision: Int = 0
        var generations: [Generation] = []
        /// Identifiers that existed in earlier revisions, reported to the system as deleted
        /// so their placeholders and any downloaded copies go away with them.
        var retired: [String] = []

        static func load() -> Manifest {
            guard let url = manifestURL, let data = try? Data(contentsOf: url),
                  let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return Manifest() }
            return m
        }

        func save() throws {
            guard let url = manifestURL else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        }

        /// Every identifier this manifest describes, implied folders included.
        var allIdentifiers: [String] {
            generations.flatMap { g in [g.id] + g.nodes.map { g.identifier(for: $0.path) } }
        }
    }

    /// A request left by the extension for one file's bytes.
    struct Request: Codable {
        var generation: String
        var index: UInt32
        var size: Int64
        /// For the app's transfer window; the index is what the bytes are asked by.
        var name: String?
    }
}

extension RemoteClipboard.Generation {
    /// A file or folder as the domain shows it. Folders are not always listed by the remote
    /// on their own — a path can imply them — so nodes are the entries plus every folder a
    /// path passes through.
    struct Node {
        var path: [String]
        var entry: RemoteClipboard.Entry?
        var isDirectory: Bool { entry?.isDirectory ?? true }
    }

    var nodes: [Node] {
        var byPath: [[String]: Node] = [:]
        var order: [[String]] = []
        func add(_ path: [String], _ entry: RemoteClipboard.Entry?) {
            if byPath[path] == nil { order.append(path) }
            if let entry { byPath[path] = Node(path: path, entry: entry) }
            else if byPath[path] == nil { byPath[path] = Node(path: path, entry: nil) }
        }
        for e in entries {
            for depth in 1..<e.path.count { add(Array(e.path.prefix(depth)), nil) }
            add(e.path, e)
        }
        return order.compactMap { byPath[$0] }
    }

    /// "<generation>:<a/b/c>". Paths are already free of "/" (sanitised), so the joined form
    /// is unambiguous.
    func identifier(for path: [String]) -> String {
        "\(id):" + path.joined(separator: "/")
    }

    func parentIdentifier(for path: [String]) -> String {
        path.count <= 1 ? id : identifier(for: Array(path.dropLast()))
    }

    func node(for identifier: String) -> Node? {
        let prefix = "\(id):"
        guard identifier.hasPrefix(prefix) else { return nil }
        let path = identifier.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return nodes.first { $0.path == path }
    }
}
