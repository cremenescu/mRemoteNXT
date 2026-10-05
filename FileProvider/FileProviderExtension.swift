// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import FileProvider
import UniformTypeIdentifiers

/// Shows what was copied in a remote session as files the Finder can paste — the way the
/// Windows client does it, where nothing travels until the paste.
///
/// Every item here is a placeholder: it has a name, a size and a date, and no contents.
/// The Finder enables Paste for it like for any file and copies it like any file; reading
/// it is what makes the system call fetchContents, which asks the app for the bytes. The
/// domain is read-only, hidden from the sidebar, and holds only the last two copies.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    init(domain: NSFileProviderDomain) { super.init() }

    func invalidate() {}

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let item = RemoteItem.anyItem(for: identifier, in: .load()) {
            completionHandler(item, nil)
        } else {
            completionHandler(nil, NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier))
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer { throw CocoaError(.featureUnsupported) }
        return RemoteEnumerator(container: containerItemIdentifier)
    }

    // MARK: Contents

    /// Hand the Finder's read over to the app, then wait for the transfer file it writes.
    /// Progress is read off that file's size, so the Finder's copy bar moves with the bytes.
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let manifest = RemoteClipboard.Manifest.load()
        guard let item = RemoteItem.nodeItem(for: itemIdentifier, in: manifest),
              let entry = item.node.entry, !entry.isDirectory,
              let requests = RemoteClipboard.requestsDir, let transfers = RemoteClipboard.transfersDir else {
            completionHandler(nil, nil, NSError.fileProviderErrorForNonExistentItem(withIdentifier: itemIdentifier))
            return Progress()
        }
        let size = entry.size ?? 0
        let progress = Progress(totalUnitCount: max(size, 1))
        let id = UUID().uuidString
        let requestURL = requests.appendingPathComponent(id + ".json")
        let cancelURL = requests.appendingPathComponent(id + ".cancel")
        let partial = transfers.appendingPathComponent(id + ".partial")
        let done = transfers.appendingPathComponent(id + ".done")
        let failed = transfers.appendingPathComponent(id + ".error")

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: requests, withIntermediateDirectories: true)
            try fm.createDirectory(at: transfers, withIntermediateDirectories: true)
            let body = RemoteClipboard.Request(generation: item.generation.id, index: entry.index, size: size,
                                               name: item.filename)
            try JSONEncoder().encode(body).write(to: requestURL, options: .atomic)
        } catch {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            return progress
        }

        progress.cancellationHandler = {
            FileManager.default.createFile(atPath: cancelURL.path, contents: nil)
        }

        // Poll rather than watch: the files are in a container both processes write to, and a
        // fifth of a second is nothing next to a remote read.
        let queue = DispatchQueue(label: "mRemoteNXT.fetch.\(id)")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let started = Date()
        var lastSize: Int64 = -1
        var lastGrowth = Date()
        var finished = false
        func finish(_ url: URL?, _ error: Error?) {
            guard !finished else { return }
            finished = true
            timer.cancel()
            let fm = FileManager.default
            try? fm.removeItem(at: requestURL)
            if error != nil { try? fm.removeItem(at: partial); try? fm.removeItem(at: done) }
            try? fm.removeItem(at: failed)
            completionHandler(url, url == nil ? nil : item, error)
        }
        timer.schedule(deadline: .now() + 0.1, repeating: 0.2)
        timer.setEventHandler {
            let fm = FileManager.default
            if progress.isCancelled {
                fm.createFile(atPath: cancelURL.path, contents: nil)
                finish(nil, CocoaError(.userCancelled)); return
            }
            if fm.fileExists(atPath: done.path) {
                progress.completedUnitCount = progress.totalUnitCount
                // The system takes the file from here; it is not ours to delete afterwards.
                finish(done, nil); return
            }
            if let data = try? Data(contentsOf: failed) {
                let code = Int(String(decoding: data, as: UTF8.self)) ?? 0
                finish(nil, Self.error(for: RemoteClipboard.Failure(rawValue: code))); return
            }
            let now = Date()
            if let attrs = try? fm.attributesOfItem(atPath: partial.path),
               let bytes = (attrs[.size] as? NSNumber)?.int64Value {
                if bytes != lastSize { lastSize = bytes; lastGrowth = now }
                progress.completedUnitCount = min(bytes, progress.totalUnitCount)
                // A minute and a half without a byte: the remote has gone quiet for good.
                if now.timeIntervalSince(lastGrowth) > 90 {
                    fm.createFile(atPath: cancelURL.path, contents: nil)
                    finish(nil, NSFileProviderError(.serverUnreachable))
                }
            } else if now.timeIntervalSince(started) > 15 {
                // Nobody picked the request up: the app is not running.
                finish(nil, NSFileProviderError(.serverUnreachable))
            }
        }
        timer.resume()
        return progress
    }

    private static func error(for failure: RemoteClipboard.Failure?) -> Error {
        switch failure {
        case .cancelled?: return CocoaError(.userCancelled)
        case .refused?:   return NSFileProviderError(.cannotSynchronize)
        default:          return NSFileProviderError(.serverUnreachable)
        }
    }

    // MARK: Read-only

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
                    contents url: URL?, options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.featureUnsupported))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.featureUnsupported))
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(CocoaError(.featureUnsupported))
        return Progress()
    }
}

// MARK: - Items

final class RemoteItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let generation: RemoteClipboard.Generation
    let node: RemoteClipboard.Generation.Node
    private let isFolder: Bool

    init(identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, filename: String,
         generation: RemoteClipboard.Generation, node: RemoteClipboard.Generation.Node, isFolder: Bool) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename
        self.generation = generation
        self.node = node
        self.isFolder = isFolder
    }

    var contentType: UTType {
        if isFolder { return .folder }
        let ext = (filename as NSString).pathExtension
        return (ext.isEmpty ? nil : UTType(filenameExtension: ext)) ?? .data
    }

    /// Writable, though nothing written here is kept. Without it the system locks every item
    /// (the uchg flag) and makes it r--------, and the Finder carries both onto the copy it
    /// pastes: the user got a locked, read-only file. The domain is still never changed —
    /// create, modify and delete are refused below.
    var capabilities: NSFileProviderItemCapabilities {
        isFolder ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] : [.allowsReading, .allowsWriting]
    }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        isFolder ? [.userReadable, .userWritable, .userExecutable] : [.userReadable, .userWritable]
    }

    var documentSize: NSNumber? { isFolder ? nil : node.entry?.size.map { NSNumber(value: $0) } }
    /// The remote's own date; folders it only implied take the time of the copy.
    var contentModificationDate: Date? { node.entry?.modified ?? generation.created }
    var creationDate: Date? { node.entry?.modified ?? generation.created }

    /// The remote's copy never changes under an identifier — a new copy gets new ones.
    var itemVersion: NSFileProviderItemVersion {
        let v = Data(itemIdentifier.rawValue.utf8)
        return NSFileProviderItemVersion(contentVersion: v, metadataVersion: v)
    }

    /// The generation folder itself, or a node inside one.
    static func anyItem(for identifier: NSFileProviderItemIdentifier, in manifest: RemoteClipboard.Manifest) -> NSFileProviderItem? {
        if identifier == .rootContainer { return RootItem() }
        for g in manifest.generations {
            if identifier.rawValue == g.id { return folder(of: g) }
            if let node = g.node(for: identifier.rawValue) { return item(for: node, in: g) }
        }
        return nil
    }

    static func nodeItem(for identifier: NSFileProviderItemIdentifier, in manifest: RemoteClipboard.Manifest) -> RemoteItem? {
        for g in manifest.generations {
            if let node = g.node(for: identifier.rawValue) { return item(for: node, in: g) }
        }
        return nil
    }

    static func folder(of g: RemoteClipboard.Generation) -> RemoteItem {
        RemoteItem(identifier: NSFileProviderItemIdentifier(g.id), parent: .rootContainer, filename: g.folder,
                   generation: g, node: .init(path: [], entry: nil), isFolder: true)
    }

    static func item(for node: RemoteClipboard.Generation.Node, in g: RemoteClipboard.Generation) -> RemoteItem {
        RemoteItem(identifier: NSFileProviderItemIdentifier(g.identifier(for: node.path)),
                   parent: NSFileProviderItemIdentifier(g.parentIdentifier(for: node.path)),
                   filename: node.path.last ?? "?", generation: g, node: node, isFolder: node.isDirectory)
    }

    /// Everything the manifest describes, for the working set.
    static func all(in manifest: RemoteClipboard.Manifest) -> [NSFileProviderItem] {
        manifest.generations.flatMap { g in [folder(of: g)] + g.nodes.map { item(for: $0, in: g) } }
    }

    static func children(of container: NSFileProviderItemIdentifier, in manifest: RemoteClipboard.Manifest) -> [NSFileProviderItem] {
        if container == .rootContainer { return manifest.generations.map { folder(of: $0) } }
        for g in manifest.generations {
            if container.rawValue == g.id {
                return g.nodes.filter { $0.path.count == 1 }.map { item(for: $0, in: g) }
            }
            if let parent = g.node(for: container.rawValue) {
                return g.nodes.filter { $0.path.count == parent.path.count + 1 && Array($0.path.dropLast()) == parent.path }
                    .map { item(for: $0, in: g) }
            }
        }
        return []
    }
}

final class RootItem: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "mRemoteNXT" }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8))
    }
}

// MARK: - Enumeration

/// Containers list their children from the manifest. The working set reports the whole
/// manifest as updated and everything retired as deleted: it is small, and saying it all
/// every time means an anchor can never be too old to answer.
final class RemoteEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier) { self.container = container }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let manifest = RemoteClipboard.Manifest.load()
        let items = container == .workingSet
            ? RemoteItem.all(in: manifest)
            : RemoteItem.children(of: container, in: manifest)
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let manifest = RemoteClipboard.Manifest.load()
        let current = container == .workingSet
            ? RemoteItem.all(in: manifest)
            : RemoteItem.children(of: container, in: manifest)
        if !manifest.retired.isEmpty {
            observer.didDeleteItems(withIdentifiers: manifest.retired.map { NSFileProviderItemIdentifier($0) })
        }
        if !current.isEmpty { observer.didUpdate(current) }
        observer.finishEnumeratingChanges(upTo: Self.anchor(manifest), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor(.load()))
    }

    private static func anchor(_ m: RemoteClipboard.Manifest) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(m.revision).utf8))
    }
}
