// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit
import FileProvider

/// The app's half of pasting remote files into the Finder; the other half is the File
/// Provider extension (FileProvider/FileProviderExtension.swift).
///
/// When Explorer copies files, the session reports their names and sizes. This publishes
/// them in the shared manifest, lets the system create placeholders for them in a hidden
/// File Provider domain, and puts the placeholders' paths on the pasteboard. To the Finder
/// they are ordinary files, so Paste is enabled at once and nothing has been transferred.
/// Only when the Finder copies one does the system ask the extension for its contents; the
/// extension leaves a request in the shared container, and this streams the bytes from the
/// remote into a transfer file the extension hands back — with the Finder's own progress,
/// and with the Finder never waiting on this app.
///
/// File promises were tried first: the Finder accepts them only by drag. A file URL fetched
/// lazily was tried next: the Finder reads it just to decide whether Paste is possible, so
/// opening the Edit menu started the download and froze the Finder until it ended.
final class RemoteClipboardServer {
    static let shared = RemoteClipboardServer()

    /// Visible on purpose. A hidden domain was the first choice — it holds only the last two
    /// copies, nothing worth browsing — but macOS 26 starts a new provider disabled until the
    /// user turns it on, and a hidden domain is created disabled with nowhere to turn it on:
    /// fileproviderd reported it "user-disabled" and refused every operation (-2011). Visible,
    /// it shows up as "mRemoteNXT" under Locations in the Finder, where it can be enabled.
    private let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(rawValue: RemoteClipboard.domainIdentifier),
        displayName: "mRemoteNXT")

    private final class WeakClient { weak var value: RDPClient?; init(_ c: RDPClient) { value = c } }
    /// Which session each generation's bytes come from. Only in memory: after a restart
    /// there is no session behind an old generation, so start() retires them all.
    private var clients: [String: WeakClient] = [:]
    private var latest: String?
    private var watcher: DispatchSourceFileSystemObject?
    private var rescan: Timer?
    private var handling = Set<String>()

    /// Reads to one session are answered one at a time, so transfers queue up too.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "mRemoteNXT.remote-clipboard"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    private static let chunk: UInt32 = 512 * 1024
    private static let retiredCap = 5000

    // MARK: Lifecycle

    /// Called once at launch: register the domain, clear what a previous run left, and
    /// start answering the extension.
    func start() {
        guard let requests = RemoteClipboard.requestsDir, let transfers = RemoteClipboard.transfersDir else {
            NSLog("mRemoteNXT: no app group container — pasting remote files is unavailable")
            return
        }
        let fm = FileManager.default
        for dir in [requests, transfers] {
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var m = RemoteClipboard.Manifest.load()
        if !m.generations.isEmpty {
            m.retired = Array((m.retired + m.allIdentifiers).suffix(Self.retiredCap))
            m.generations = []
            m.revision += 1
            try? m.save()
        }
        register()
        watch(requests)
    }

    /// Add the domain, replacing one that build 92-93 registered hidden: addDomain updates the
    /// display name of an existing domain but not whether it is hidden.
    private func register() {
        let domain = self.domain
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            let stale = domains.first { $0.identifier == domain.identifier && $0.isHidden }
            let add = {
                NSFileProviderManager.add(domain) { error in
                    if let error {
                        NSLog("mRemoteNXT: registering the remote clipboard domain failed: %@", String(describing: error))
                        return
                    }
                    NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
                }
            }
            if let stale {
                NSFileProviderManager.remove(stale) { _ in add() }
            } else {
                add()
            }
        }
    }

    // MARK: Offering a copy

    /// Explorer copied files. Called on the main thread.
    func offer(_ files: [RDPRemoteFile], from client: RDPClient) {
        var entries: [RemoteClipboard.Entry] = []
        for f in files {
            guard let parts = Self.safeComponents(f.remotePath) else {
                NSLog("mRemoteNXT: ignoring remote clipboard entry with an unsafe path")
                continue
            }
            entries.append(RemoteClipboard.Entry(path: parts, index: f.index, isDirectory: f.isDirectory,
                                                 size: f.size >= 0 ? f.size : nil, modified: f.modified))
        }
        guard !entries.isEmpty else { return }

        var m = RemoteClipboard.Manifest.load()
        let gen = RemoteClipboard.Generation(id: String(UUID().uuidString.prefix(8)),
                                             folder: String(m.revision + 1), entries: entries)
        // Keep the previous copy: the Finder may still be pasting out of it.
        let dropped = m.generations.dropLast()
        for g in dropped { clients[g.id] = nil }
        m.retired = Array((m.retired + dropped.flatMap { g in [g.id] + g.nodes.map { g.identifier(for: $0.path) } })
            .suffix(Self.retiredCap))
        m.generations = Array(m.generations.suffix(1)) + [gen]
        m.revision += 1
        do { try m.save() } catch {
            NSLog("mRemoteNXT: writing the remote clipboard manifest failed: %@", String(describing: error))
            return
        }
        clients[gen.id] = WeakClient(client)
        latest = gen.id
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: .workingSet) { _ in }
        publish(gen, manager: manager, client: client)
    }

    /// Wait for the system to create the placeholders, then put their paths on the pasteboard.
    private func publish(_ gen: RemoteClipboard.Generation, manager: NSFileProviderManager, client: RDPClient) {
        let roots = gen.nodes.filter { $0.path.count == 1 }
        DispatchQueue.global(qos: .userInitiated).async {
            var urls: [URL] = []
            let deadline = Date().addingTimeInterval(15)
            for node in roots {
                let id = NSFileProviderItemIdentifier(gen.identifier(for: node.path))
                while Date() < deadline {
                    let sem = DispatchSemaphore(value: 0)
                    var url: URL?
                    manager.getUserVisibleURL(for: id) { u, _ in url = u; sem.signal() }
                    sem.wait()
                    // stat only: it does not materialise a placeholder.
                    if let url, FileManager.default.fileExists(atPath: url.path) { urls.append(url); break }
                    usleep(200_000)
                }
            }
            DispatchQueue.main.async { [weak client] in
                // A newer copy may have come in while waiting; it owns the pasteboard now.
                guard self.latest == gen.id else { return }
                guard urls.count == roots.count else {
                    NSLog("mRemoteNXT: only %d of %d remote clipboard items appeared", urls.count, roots.count)
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(urls as [NSURL])
                // Without this the session's own poll would offer the paths back to the remote.
                client?.noteOwnPasteboardWrite()
            }
        }
    }

    // MARK: Answering the extension

    private func watch(_ dir: URL) {
        let fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.scan() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        }
        // Belt and braces: a directory event can be coalesced away under load.
        rescan = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.scan() }
    }

    private func scan() {
        guard let dir = RemoteClipboard.requestsDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard !handling.contains(id), let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(RemoteClipboard.Request.self, from: data) else { continue }
            // Taken: removing it keeps a rescan from serving it twice.
            try? FileManager.default.removeItem(at: url)
            handling.insert(id)
            let client = clients[request.generation]?.value
            queue.addOperation { [weak self] in
                Self.serve(request, id: id, client: client)
                DispatchQueue.main.async { self?.handling.remove(id) }
            }
        }
    }

    /// Stream one file from the remote into `<id>.partial`, then rename it `<id>.done`. On
    /// failure write the reason into `<id>.error` instead.
    private static func serve(_ request: RemoteClipboard.Request, id: String, client: RDPClient?) {
        guard let transfers = RemoteClipboard.transfersDir, let requests = RemoteClipboard.requestsDir else { return }
        let fm = FileManager.default
        let partial = transfers.appendingPathComponent(id + ".partial")
        let done = transfers.appendingPathComponent(id + ".done")
        let failed = transfers.appendingPathComponent(id + ".error")
        let cancel = requests.appendingPathComponent(id + ".cancel")
        defer { try? fm.removeItem(at: cancel) }

        func fail(_ reason: RemoteClipboard.Failure) {
            try? fm.removeItem(at: partial)
            try? Data(String(reason.rawValue).utf8).write(to: failed, options: .atomic)
        }
        guard let client else { fail(.sessionGone); return }
        do {
            let size = request.size > 0 ? request.size : try client.sizeOfRemoteFile(at: request.index).int64Value
            guard fm.createFile(atPath: partial.path, contents: nil) else { fail(.io); return }
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var offset: Int64 = 0
            while offset < size {
                if fm.fileExists(atPath: cancel.path) { fail(.cancelled); return }
                let want = UInt32(min(Int64(chunk), size - offset))
                let data = try client.readRemoteFile(at: request.index, offset: UInt64(offset), length: want)
                // An empty answer before the end would loop forever.
                guard !data.isEmpty else { fail(.refused); return }
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
            }
            try handle.close()
            try fm.moveItem(at: partial, to: done)
        } catch {
            let ns = error as NSError
            switch (ns.domain, ns.code) {
            case ("ro.cremenescu.mRemoteNXT.RemoteFiles", 10): fail(.sessionGone)
            case ("ro.cremenescu.mRemoteNXT.RemoteFiles", 11): fail(.timeout)
            case ("ro.cremenescu.mRemoteNXT.RemoteFiles", _):  fail(.refused)
            default:                                           fail(.io)
            }
        }
    }

    /// The paths come from the server and are treated as hostile: a component that is empty,
    /// "." or "..", or that holds a path separator, a drive colon or a NUL, drops the entry.
    private static func safeComponents(_ remotePath: String) -> [String]? {
        let parts = remotePath.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        for p in parts {
            if p.isEmpty || p == "." || p == ".." { return nil }
            if p.contains("/") || p.contains(":") || p.contains("\0") { return nil }
        }
        return parts
    }
}
