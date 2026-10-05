// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit

/// Files copied in a remote Windows session, offered on the Mac's pasteboard so that a
/// paste in the Finder brings them over.
///
/// What goes on the pasteboard is one item per thing copied, each promising a file URL
/// without having one yet. The Finder enables Paste on that alone. When it actually pastes,
/// it asks for the URLs, and only then are the files read from the remote — in chunks, into
/// a folder in the app's cache — and the Finder copies them from there. A copy in Explorer
/// that is pasted back inside Windows, or never pasted at all, moves nothing but the list of
/// names and sizes, which the session fetched when the copy happened.
///
/// File promises were the first attempt and are the more natural fit, but the Finder takes
/// them only by drag and drop: offered on the general pasteboard, its Paste stays greyed out.
///
/// The paths come from the server and are treated as hostile: a component that is empty,
/// "." or "..", or that holds a path separator, a drive colon or a NUL, drops the entry.
/// Without that a malicious server could name a file "..\..\.ssh\authorized_keys".
final class RemoteFileClipboard: NSObject, NSPasteboardItemDataProvider {
    /// The set on the pasteboard now, and the one before it. The previous set's files stay
    /// on disk because the Finder may still be copying out of them when the next copy
    /// happens; anything older is deleted.
    private static var current: RemoteFileClipboard?
    private static var previous: RemoteFileClipboard?
    private static var cacheCleared = false

    /// Reads to one session are answered one at a time, so writes queue up too. Not the
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

    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ro.cremenescu.mRemoteNXT/RemoteClipboard", isDirectory: true)
    }

    /// Kept in step with the codes RDPClient.m reports.
    enum ErrorCode: Int {
        case unavailable = 10, timeout = 11, refused = 12, malformed = 13, closed = 20, short = 21

        var message: String {
            switch self {
            case .unavailable: return t("RemoteFiles.Error.Unavailable")
            case .timeout:     return t("RemoteFiles.Error.Timeout")
            case .refused:     return t("RemoteFiles.Error.Refused")
            case .malformed:   return t("RemoteFiles.Error.Malformed")
            case .closed:      return t("RemoteFiles.Error.Closed")
            case .short:       return t("RemoteFiles.Error.Short")
            }
        }
    }
    static let errorDomain = "ro.cremenescu.mRemoteNXT.RemoteFiles"

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
    /// This set's own folder in the cache.
    private let directory: URL
    private var rootOfItem: [ObjectIdentifier: Int] = [:]
    /// Roots already brought over: a second paste of the same copy reuses them.
    private var delivered: [Int: URL] = [:]

    private init(files: [RDPRemoteFile], client: RDPClient) {
        self.client = client
        self.directory = Self.cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        let fm = FileManager.default
        // Whatever a previous run of the app left behind is no longer on any pasteboard.
        if !cacheCleared {
            try? fm.removeItem(at: cacheRoot)
            cacheCleared = true
        }
        let set = RemoteFileClipboard(files: files, client: client)
        guard !set.roots.isEmpty else { return }
        let items: [NSPasteboardItem] = set.roots.indices.map { i in
            let item = NSPasteboardItem()
            item.setDataProvider(set, forTypes: [.fileURL])
            set.rootOfItem[ObjectIdentifier(item)] = i
            return item
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items)
        if let old = previous { try? fm.removeItem(at: old.directory) }
        previous = current
        current = set
        // Without this the session's own pasteboard poll would see the change and offer
        // the items straight back to the remote they came from.
        client.noteOwnPasteboardWrite()
    }

    // MARK: NSPasteboardItemDataProvider

    /// The Finder is pasting and wants the file. It waits for the answer, so this waits for
    /// the transfer — but keeps this app's run loop turning meanwhile, so its sessions stay
    /// live and the progress panel can be drawn and cancelled.
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL, let i = rootOfItem[ObjectIdentifier(item)] else { return }
        if let url = delivered[i] {
            item.setData(url.dataRepresentation, forType: .fileURL)
            return
        }
        let root = roots[i]
        let url = directory.appendingPathComponent(root.name, isDirectory: root.isDirectory)
        let progress = Progress(totalUnitCount: 0)
        progress.isCancellable = true

        var outcome: Result<Void, Error>?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            outcome = .failure(error)
        }
        if outcome == nil {
            Self.queue.addOperation {
                let result = Result { try self.write(root, to: url, progress: progress) }
                DispatchQueue.main.async { outcome = result }
            }
        }

        // A panel only for transfers that take a moment; a small file comes and goes unseen.
        var panel: RemoteCopyPanel?
        let started = Date()
        while outcome == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            if panel == nil, Date().timeIntervalSince(started) > 0.5 {
                panel = RemoteCopyPanel(name: root.name, progress: progress)
            }
            panel?.refresh()
        }
        panel?.close()

        switch outcome {
        case .success?:
            delivered[i] = url
            item.setData(url.dataRepresentation, forType: .fileURL)
        case .failure(let error)?:
            NSLog("mRemoteNXT: pasting %@ from the remote failed: %@", root.name, String(describing: error))
            if !progress.isCancelled { Self.report(error) }
        case nil:
            break
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}

    // MARK: Writing

    /// Build the item next to its destination under a hidden name, then move it into place,
    /// so a transfer that fails half-way leaves nothing behind that looks complete.
    private func write(_ root: Root, to url: URL, progress: Progress) throws {
        guard let client else { throw Self.error(.closed) }
        let fm = FileManager.default
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".mRemoteNXT-\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: staging) }

        if root.isDirectory {
            let inside = entries.filter { $0.components.count > 1 && $0.components[0] == root.name }
            var sizes: [UInt32: Int64] = [:]
            for e in inside where !e.isDirectory { sizes[e.index] = try size(of: e, client: client) }
            progress.totalUnitCount = max(sizes.values.reduce(0, +), 1)

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
            progress.totalUnitCount = max(total, 1)
            try download(e, size: total, to: staging, client: client, progress: progress)
            if let m = e.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: staging.path) }
        }

        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: staging, to: url)
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
            guard !data.isEmpty else { throw Self.error(.short) }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress.completedUnitCount += Int64(data.count)
        }
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

    private static func error(_ code: ErrorCode) -> NSError {
        NSError(domain: errorDomain, code: code.rawValue, userInfo: nil)
    }

    /// The Finder only learns that nothing arrived; this says why. Deferred, so it never runs
    /// inside the pasteboard's request.
    private static func report(_ error: Error) {
        let ns = error as NSError
        let text = (ns.domain == errorDomain ? ErrorCode(rawValue: ns.code)?.message : nil)
            ?? ns.localizedDescription
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = t("RemoteFiles.Failed")
            alert.informativeText = text
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

/// Small floating panel shown while a paste waits on the remote. It floats because the
/// Finder is in front — the paste was made there — and this app is not.
private final class RemoteCopyPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let progress: Progress
    private let bytes = ByteCountFormatter()

    init(name: String, progress: Progress) {
        self.progress = progress
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 112),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "mRemoteNXT"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        label.stringValue = String(format: t("RemoteFiles.Copying"), name)
        label.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bytes.countStyle = .file
        let cancel = NSButton(title: t("RemoteFiles.Cancel"), target: nil, action: nil)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelTapped)

        let stack = NSStackView(views: [label, bar, detail, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            label.widthAnchor.constraint(equalTo: bar.widthAnchor),
        ])
        panel.contentView = content
        refresh()
        panel.center()
        panel.orderFrontRegardless()
    }

    func refresh() {
        let total = progress.totalUnitCount
        let done = progress.completedUnitCount
        bar.doubleValue = total > 0 ? Double(done) / Double(total) : 0
        detail.stringValue = total > 1
            ? String(format: t("RemoteFiles.Bytes"), bytes.string(fromByteCount: done), bytes.string(fromByteCount: total))
            : ""
    }

    func close() { panel.orderOut(nil) }

    @objc private func cancelTapped() { progress.cancel() }
}
