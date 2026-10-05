// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit
import UniformTypeIdentifiers

/// Files copied in a remote Windows session, offered on the Mac's pasteboard as file
/// promises: one per item that was copied, a folder standing for everything inside it.
///
/// Nothing moves when Explorer copies — only the list of names and sizes, which the session
/// fetched already. The bytes travel when a paste in the Finder fulfils a promise, read
/// from the remote in chunks straight into the destination, so a copy of a large folder
/// costs nothing until it is pasted, and costs nothing at all if it never is.
///
/// The paths come from the server and are treated as hostile: a component that is empty,
/// "." or "..", or that holds a path separator, a drive colon or a NUL, drops the entry.
/// Without that a malicious server could name a file "..\..\.ssh\authorized_keys".
final class RemoteFileClipboard: NSObject, NSFilePromiseProviderDelegate {
    /// The set currently advertised. NSFilePromiseProvider holds its delegate weakly, so
    /// something must keep it alive for as long as the pasteboard still offers it.
    private static var current: RemoteFileClipboard?

    /// Requests to one session are answered one at a time, so writes queue up too. Not the
    /// main queue: every read blocks until the remote answers.
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "mRemoteNXT.remote-files"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Read size per request. The server may answer with less; the loop simply continues
    /// from where the answer ended.
    private static let chunk: UInt32 = 512 * 1024

    struct Entry {
        let index: UInt32
        let components: [String]
        let isDirectory: Bool
        let size: Int64?
        let modified: Date?
    }

    /// One top-level item: what the user selected in Explorer.
    struct Root {
        let name: String
        let isDirectory: Bool
        let entry: Entry?      // nil for a folder implied only by its contents
    }

    private weak var client: RDPClient?
    private let entries: [Entry]
    private let roots: [Root]

    private init(files: [RDPRemoteFile], client: RDPClient) {
        self.client = client
        var entries: [Entry] = []
        for f in files {
            guard let parts = Self.safeComponents(f.remotePath) else {
                NSLog("mRemoteNXT: ignoring remote clipboard entry with an unsafe path")
                continue
            }
            entries.append(Entry(index: f.index, components: parts, isDirectory: f.isDirectory,
                                 size: f.size >= 0 ? f.size : nil, modified: f.modified))
        }
        self.entries = entries
        // Roots in the order the remote listed them. A folder may only be implied by the
        // paths of its contents, so roots are collected from first components, not only
        // from single-component entries.
        var roots: [Root] = []
        var seen = Set<String>()
        for e in entries where !seen.contains(e.components[0]) {
            let name = e.components[0]
            seen.insert(name)
            let own = entries.first { $0.components.count == 1 && $0.components[0] == name }
            let hasChildren = entries.contains { $0.components.count > 1 && $0.components[0] == name }
            roots.append(Root(name: name, isDirectory: (own?.isDirectory ?? false) || hasChildren, entry: own))
        }
        self.roots = roots
    }

    /// Put what the remote copied on the pasteboard. Called on the main thread.
    static func offer(_ files: [RDPRemoteFile], from client: RDPClient) {
        let set = RemoteFileClipboard(files: files, client: client)
        guard !set.roots.isEmpty else { return }
        let providers: [NSFilePromiseProvider] = set.roots.enumerated().map { i, root in
            let type: String
            if root.isDirectory {
                type = UTType.folder.identifier
            } else {
                let ext = (root.name as NSString).pathExtension
                type = (ext.isEmpty ? nil : UTType(filenameExtension: ext))?.identifier ?? UTType.data.identifier
            }
            let provider = NSFilePromiseProvider(fileType: type, delegate: set)
            provider.userInfo = i
            return provider
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(providers)
        current = set
        // Without this the session's own pasteboard poll would see the change and offer
        // the promises straight back to the remote they came from.
        client.noteOwnPasteboardWrite()
    }

    // MARK: NSFilePromiseProviderDelegate

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        root(of: provider)?.name ?? "Untitled"
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { Self.queue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let root = root(of: provider) else {
            completionHandler(CocoaError(.fileNoSuchFile)); return
        }
        do {
            try write(root, to: url)
            completionHandler(nil)
        } catch {
            NSLog("mRemoteNXT: pasting %@ from the remote failed: %@", root.name, error.localizedDescription)
            completionHandler(error)
        }
    }

    // MARK: Writing

    private func root(of provider: NSFilePromiseProvider) -> Root? {
        guard let i = provider.userInfo as? Int, roots.indices.contains(i) else { return nil }
        return roots[i]
    }

    /// Build the item next to its destination under a hidden name, then move it into place,
    /// so a transfer that fails half-way leaves nothing behind and replaces nothing.
    private func write(_ root: Root, to url: URL) throws {
        guard let client else {
            throw Self.error("The remote session this was copied from is closed.")
        }
        let fm = FileManager.default
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".mRemoteNXT-\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: staging) }

        if root.isDirectory {
            let inside = entries.filter { $0.components.count > 1 && $0.components[0] == root.name }
            var sizes: [UInt32: Int64] = [:]
            for e in inside where !e.isDirectory { sizes[e.index] = try size(of: e, client: client) }
            let progress = Self.publishProgress(for: url, total: sizes.values.reduce(0, +))
            defer { progress.unpublish() }

            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            var dated: [(URL, Date)] = []
            for e in inside {
                let target = e.components.dropFirst().reduce(staging) { $0.appendingPathComponent($1) }
                if e.isDirectory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try download(e, size: sizes[e.index] ?? 0, to: target, client: client, progress: progress)
                }
                if let m = e.modified { dated.append((target, m)) }
            }
            // Folders last and deepest first: writing a child moves its parent's date.
            if let m = root.entry?.modified { dated.append((staging, m)) }
            for (u, m) in dated.sorted(by: { $0.0.pathComponents.count > $1.0.pathComponents.count }) {
                try? fm.setAttributes([.modificationDate: m], ofItemAtPath: u.path)
            }
        } else {
            guard let e = root.entry else { throw CocoaError(.fileNoSuchFile) }
            let total = try size(of: e, client: client)
            let progress = Self.publishProgress(for: url, total: total)
            defer { progress.unpublish() }
            try download(e, size: total, to: staging, client: client, progress: progress)
            if let m = e.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: staging.path) }
        }

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: url)
        }
    }

    private func size(of e: Entry, client: RDPClient) throws -> Int64 {
        if let s = e.size { return s }
        return try client.sizeOfRemoteFile(at: e.index).int64Value
    }

    private func download(_ e: Entry, size: Int64, to url: URL, client: RDPClient, progress: Progress) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < size {
            if progress.isCancelled { throw CocoaError(.userCancelled) }
            let want = UInt32(min(Int64(Self.chunk), size - offset))
            let data = try client.readRemoteFile(at: e.index, offset: UInt64(offset), length: want)
            // An empty answer before the end would loop forever.
            guard !data.isEmpty else { throw Self.error("The remote computer sent less than the file's size.") }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress.completedUnitCount += Int64(data.count)
        }
    }

    /// Published on the destination, so the Finder draws the transfer on the icon.
    private static func publishProgress(for url: URL, total: Int64) -> Progress {
        let p = Progress(totalUnitCount: max(total, 1))
        p.kind = .file
        p.fileOperationKind = .downloading
        p.fileURL = url
        p.isCancellable = true
        p.publish()
        return p
    }

    private static func safeComponents(_ remotePath: String) -> [String]? {
        let parts = remotePath.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        for p in parts {
            if p.isEmpty || p == "." || p == ".." { return nil }
            if p.contains("/") || p.contains(":") || p.contains("\0") { return nil }
        }
        return parts
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "ro.cremenescu.mRemoteNXT.RemoteFiles", code: 2,
                userInfo: [NSLocalizedDescriptionKey: text])
    }
}
