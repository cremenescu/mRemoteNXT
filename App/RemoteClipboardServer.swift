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
                                             folder: String(m.revision + 1), entries: entries, created: Date())
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
            let panel = TransferPanel(name: request.name ?? "?", total: request.size,
                                      cancel: dir.appendingPathComponent(id + ".cancel"))
            queue.addOperation { [weak self] in
                let failure = Self.serve(request, id: id, client: client) { done, total in
                    DispatchQueue.main.async { panel.update(done: done, total: total) }
                }
                DispatchQueue.main.async {
                    panel.finish(failure)
                    self?.handling.remove(id)
                }
            }
        }
    }

    /// Stream one file from the remote into `<id>.partial`, then rename it `<id>.done`. On
    /// failure write the reason into `<id>.error` instead, and return it.
    @discardableResult
    private static func serve(_ request: RemoteClipboard.Request, id: String, client: RDPClient?,
                              progress: (Int64, Int64) -> Void = { _, _ in }) -> RemoteClipboard.Failure? {
        guard let transfers = RemoteClipboard.transfersDir, let requests = RemoteClipboard.requestsDir else { return .io }
        let fm = FileManager.default
        let partial = transfers.appendingPathComponent(id + ".partial")
        let done = transfers.appendingPathComponent(id + ".done")
        let failed = transfers.appendingPathComponent(id + ".error")
        let cancel = requests.appendingPathComponent(id + ".cancel")
        defer { try? fm.removeItem(at: cancel) }

        func fail(_ reason: RemoteClipboard.Failure) -> RemoteClipboard.Failure {
            try? fm.removeItem(at: partial)
            try? Data(String(reason.rawValue).utf8).write(to: failed, options: .atomic)
            return reason
        }
        guard let client else { return fail(.sessionGone) }
        do {
            let size = request.size > 0 ? request.size : try client.sizeOfRemoteFile(at: request.index).int64Value
            guard fm.createFile(atPath: partial.path, contents: nil) else { return fail(.io) }
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var offset: Int64 = 0
            progress(0, size)
            while offset < size {
                if fm.fileExists(atPath: cancel.path) { return fail(.cancelled) }
                let want = UInt32(min(Int64(chunk), size - offset))
                let data = try client.readRemoteFile(at: request.index, offset: UInt64(offset), length: want)
                // An empty answer before the end would loop forever.
                guard !data.isEmpty else { return fail(.refused) }
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
                progress(offset, size)
            }
            try handle.close()
            try fm.moveItem(at: partial, to: done)
            return nil
        } catch {
            let ns = error as NSError
            switch (ns.domain, ns.code) {
            case ("ro.cremenescu.mRemoteNXT.RemoteFiles", 10): return fail(.sessionGone)
            case ("ro.cremenescu.mRemoteNXT.RemoteFiles", 11): return fail(.timeout)
            case ("ro.cremenescu.mRemoteNXT.RemoteFiles", _):  return fail(.refused)
            default:                                           return fail(.io)
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

/// What the Finder does not show. While the system fetches a file for a paste, the Finder's
/// copy window says "Preparing to copy" and nothing else — no bytes, no time left — and when
/// the fetch fails its message is a bare error number. This small floating window, owned by
/// the app that is actually moving the bytes, says how far along the copy is and, if it
/// fails, why.
private final class TransferPanel: NSObject, NSWindowDelegate {
    /// Nothing else holds a panel once its transfer is over, and a failure stays on screen
    /// until the user closes it — so the open ones are kept here.
    private static var live = Set<TransferPanel>()

    private let name: String
    private let cancelURL: URL
    private var total: Int64
    private var done: Int64 = 0
    private var finished = false
    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let bytes = ByteCountFormatter()
    private let eta: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = [.hour, .minute, .second]
        return f
    }()
    /// Recent (time, bytes) samples: the speed is read over the last few seconds, so a link
    /// that changes pace shows its current one.
    private var samples: [(Date, Int64)] = []

    init(name: String, total: Int64, cancel: URL) {
        self.name = name
        self.total = total
        self.cancelURL = cancel
        super.init()
        Self.live.insert(self)
        bytes.countStyle = .file
        // A file that arrives at once never gets a window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, !self.finished else { return }
            self.show()
        }
    }

    func update(done: Int64, total: Int64) {
        self.done = done
        self.total = total
        let now = Date()
        samples.append((now, done))
        samples.removeAll { now.timeIntervalSince($0.0) > 5 }
        refresh()
    }

    func finish(_ failure: RemoteClipboard.Failure?) {
        finished = true
        guard let failure, failure != .cancelled else { close(); return }
        // Say why, in the same window — the Finder only reports an error number.
        if panel == nil { show() }
        label.stringValue = String(format: t("RemoteFiles.Failed"), name)
        detail.stringValue = Self.message(for: failure)
        detail.textColor = .labelColor
        bar.isHidden = true
        cancelButton?.title = t("RemoteFiles.Close")
        cancelButton?.action = #selector(closeTapped)
        NSApp.requestUserAttention(.informationalRequest)
    }

    private static func message(for failure: RemoteClipboard.Failure) -> String {
        switch failure {
        case .refused:     return t("RemoteFiles.Error.Refused")
        case .sessionGone: return t("RemoteFiles.Error.SessionGone")
        case .timeout:     return t("RemoteFiles.Error.Timeout")
        case .io:          return t("RemoteFiles.Error.IO")
        case .cancelled:   return ""
        }
    }

    private var cancelButton: NSButton?

    private func show() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "mRemoteNXT"
        // The paste was made in the Finder, which stays in front; this app does not.
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self

        label.stringValue = String(format: t("RemoteFiles.Copying"), name)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 4
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let cancel = NSButton(title: t("RemoteFiles.Cancel"), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancelButton = cancel

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
            bar.widthAnchor.constraint(equalToConstant: 404),
            label.widthAnchor.constraint(equalTo: bar.widthAnchor),
            detail.widthAnchor.constraint(equalTo: bar.widthAnchor),
        ])
        p.contentView = content
        panel = p
        refresh()
        p.center()
        p.orderFrontRegardless()
    }

    private func refresh() {
        guard panel != nil, !finished else { return }
        bar.doubleValue = total > 0 ? Double(done) / Double(total) : 0
        let doneText = bytes.string(fromByteCount: done)
        let totalText = bytes.string(fromByteCount: total)
        if let first = samples.first, let last = samples.last, last.0.timeIntervalSince(first.0) >= 1,
           last.1 > first.1 {
            let rate = Double(last.1 - first.1) / last.0.timeIntervalSince(first.0)
            let left = rate > 0 ? Double(total - done) / rate : 0
            detail.stringValue = String(format: t("RemoteFiles.Progress"), doneText, totalText,
                                        bytes.string(fromByteCount: Int64(rate)),
                                        eta.string(from: max(left, 1)) ?? "—")
        } else {
            detail.stringValue = String(format: t("RemoteFiles.ProgressShort"), doneText, totalText)
        }
    }

    @objc private func cancelTapped() {
        // The transfer sees this between two chunks; the extension then fails the Finder's copy.
        FileManager.default.createFile(atPath: cancelURL.path, contents: nil)
        cancelButton?.isEnabled = false
    }

    @objc private func closeTapped() { close() }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        Self.live.remove(self)
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        Self.live.remove(self)
    }
}
