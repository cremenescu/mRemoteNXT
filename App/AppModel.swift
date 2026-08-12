// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit
import Combine
import MRNGCore

/// An open session backed by a tab.
struct Session: Identifiable {
    enum Kind { case ssh, telnet, http, externalApp, rdp, sftp, externalTool, unsupported }
    let id = UUID()
    var title: String
    let kind: Kind
    let node: MRNGNode
    let password: String
    let panel: String
    var command: String? = nil // for .externalTool: the resolved command line
}

/// External tool: a command line with macros (%Host%, %Username%, %Port%, %Password%, %Domain%, %Name%).
struct ExternalTool: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var commandLine: String
}

/// A visible row in the flattened tree (carrying its depth for indentation).
struct FlatRow: Identifiable {
    let node: MRNGNode
    let depth: Int
    var id: String { node.id }
}

enum DropPos { case above, below, into }
struct DropIndicator: Equatable { let id: String; let pos: DropPos }

/// On-disk record of the open sessions for a given file, so they can be
/// reopened on next launch. Stores only node IDs + panel — never passwords
/// (those are re-derived from the confCons file on restore).
private struct SavedSessionState: Codable {
    struct Item: Codable { let nodeID: String; let sftp: Bool; let panel: String }
    let file: String
    let items: [Item]
    let selectedNodeID: String?
    let selectedSftp: Bool
    let selectedPanel: String?
}

/// Everything about one open configuration file: the tree, the sessions on its tabs, and
/// the passphrase they are stored under. There is one per window — the AppKit-side pieces
/// that need a model without an @EnvironmentObject find it through WindowRegistry.
@MainActor
final class AppModel: ObservableObject {
    @Published var doc: ConfCons?
    @Published var loadError: String?
    @Published var fileURL: URL?
    @Published var selectedNodeID: String?
    @Published var searchText: String = ""
    @Published var sessions: [Session] = [] {
        didSet { persistSessionState() }
    }
    @Published var selectedSessionID: UUID? {
        didSet { persistSessionState() }
    }
    @Published var selectedPanel: String? {
        didSet { persistSessionState() }
    }
    @Published var expandedIDs: Set<String> = [] {
        didSet { saveExpanded() }
    }
    @Published var dirty = false
    @Published var treeVersion = 0
    /// Node id the sidebar should scroll to; consumed (reset to nil) by the list.
    @Published var scrollTarget: String?
    @Published var pendingDelete: MRNGNode?
    /// Tab being dragged in the session bar, the tab it is over, and which side of it.
    /// Driven by a DragGesture rather than the system drag-and-drop: mRemoteNG does the
    /// same on Windows (DockPanelSuite captures the mouse and filters WM_MOUSEMOVE /
    /// WM_LBUTTONUP; it never calls DoDragDrop). Tracking the mouse directly avoids the
    /// overlapping drop targets and the missing cancel callback that come with the OS
    /// drag machinery.
    @Published var draggingSessionID: UUID?
    @Published var tabDropTargetID: UUID?
    @Published var tabDropBefore: Bool = true
    @Published var dropIndicator: DropIndicator?
    private var dropClearWork: DispatchWorkItem?

    /// Sets the indicator and schedules auto-clear (~0.35s after the drag stops).
    func setDropIndicator(_ ind: DropIndicator) {
        if dropIndicator != ind { dropIndicator = ind }
        dropClearWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.dropIndicator = nil }
        dropClearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    func clearDropIndicator() {
        dropClearWork?.cancel()
        dropIndicator = nil
    }

    /// Work out which tab the pointer is over and which side of it, from the measured tab
    /// frames. Only publishes when the answer actually changes, so a drag produces a few
    /// updates rather than one per mouse move.
    func updateTabDrop(pointerX: CGFloat, frames: [UUID: CGRect], dragged: UUID) {
        var target: UUID?
        var before = true
        for (id, frame) in frames where id != dragged {
            if pointerX >= frame.minX, pointerX <= frame.maxX {
                target = id
                before = pointerX < frame.midX
                break
            }
        }
        if tabDropTargetID != target { tabDropTargetID = target }
        if tabDropBefore != before { tabDropBefore = before }
    }

    /// Apply the pending reorder. Not animated: animating a ForEach reorder of
    /// different-width items makes SwiftUI cross-fade the removal against the insertion at
    /// one position, drawing both tabs on top of each other instead of sliding them.
    func commitTabDrop() {
        defer {
            draggingSessionID = nil
            tabDropTargetID = nil
        }
        guard let dragged = draggingSessionID, let target = tabDropTargetID, dragged != target,
              let from = sessions.firstIndex(where: { $0.id == dragged }),
              let targetIdx = sessions.firstIndex(where: { $0.id == target }),
              sessions[from].panel == sessions[targetIdx].panel else { return }
        let moved = sessions.remove(at: from)
        guard var insert = sessions.firstIndex(where: { $0.id == target }) else {
            sessions.insert(moved, at: min(from, sessions.count))
            return
        }
        if !tabDropBefore { insert += 1 }
        sessions.insert(moved, at: insert)
    }
    /// Deliberately NOT persisted: it is the visibility of a modal, not a preference.
    /// It used to be saved and restored, but selectedNodeID isn't, so quitting with the
    /// editor open reopened it on an empty selection — a blank sheet with no buttons and
    /// no way out.
    @Published var editorVisible: Bool = false

    // MARK: - Application preferences

    /// These belong to the app, not to the file, so they live in a single shared object
    /// (see Preferences). They are forwarded here because every view already reaches them
    /// through the model, and because a per-window copy would have let two windows disagree
    /// about the font size. The relay below republishes the shared object's changes as our
    /// own, so all windows redraw together.
    private let prefs = Preferences.shared
    private var prefsRelay: AnyCancellable?

    var uiFontSize: Double {
        get { prefs.uiFontSize } set { prefs.uiFontSize = newValue }
    }
    var terminalFontSize: Double {
        get { prefs.terminalFontSize } set { prefs.terminalFontSize = newValue }
    }
    var terminalTheme: String {
        get { prefs.terminalTheme } set { prefs.terminalTheme = newValue }
    }
    var scrollbackLines: Int {
        get { prefs.scrollbackLines } set { prefs.scrollbackLines = newValue }
    }
    var rowHeight: Double {
        get { prefs.rowHeight } set { prefs.rowHeight = newValue }
    }
    var showProtocol: Bool {
        get { prefs.showProtocol } set { prefs.showProtocol = newValue }
    }
    var showPasswordPlain: Bool {
        get { prefs.showPasswordPlain } set { prefs.showPasswordPlain = newValue }
    }
    var cursorBlinkSpeed: CursorBlinkSpeed {
        get { prefs.cursorBlinkSpeed } set { prefs.cursorBlinkSpeed = newValue }
    }
    var optionAsMetaKey: Bool {
        get { prefs.optionAsMetaKey } set { prefs.optionAsMetaKey = newValue }
    }
    var updateTabTitleFromTerminal: Bool {
        get { prefs.updateTabTitleFromTerminal } set { prefs.updateTabTitleFromTerminal = newValue }
    }
    var closeTabOnDisconnect: Bool {
        get { prefs.closeTabOnDisconnect } set { prefs.closeTabOnDisconnect = newValue }
    }
    var restoreSessions: Bool {
        get { prefs.restoreSessions } set { prefs.restoreSessions = newValue }
    }
    var autosaveMinutes: Int {
        get { prefs.autosaveMinutes } set { prefs.autosaveMinutes = newValue }
    }
    var backupKeepCount: Int {
        get { prefs.backupKeepCount } set { prefs.backupKeepCount = newValue }
    }
    var sharedFolderPath: String {
        get { prefs.sharedFolderPath } set { prefs.sharedFolderPath = newValue }
    }
    var diagnosticLogging: Bool {
        get { prefs.diagnosticLogging } set { prefs.diagnosticLogging = newValue }
    }
    var externalTools: [ExternalTool] {
        get { prefs.externalTools } set { prefs.externalTools = newValue }
    }

    /// Passphrase the file's stored passwords are encrypted with. Starts as mRemoteNG's
    /// default and is replaced once the user unlocks a file that uses a custom one.
    private(set) var masterPassword = MRNGCrypto.defaultPassword
    /// True when the open file uses a passphrase other than mRemoteNG's public default.
    var hasCustomMasterPassword: Bool { masterPassword != MRNGCrypto.defaultPassword }
    /// Set while a file is open but still locked, so the UI can ask for the passphrase.
    @Published var needsMasterPassword: URL?

    init() {
        // Take the snapshot of what was open at quit before any window rewrites the list.
        _ = LaunchState.openDocuments
        prefsRelay = prefs.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            // The interval may be what just changed; rescheduling is a no-op if it isn't.
            DispatchQueue.main.async { self?.rescheduleAutosave() }
        }
        WindowRegistry.shared.register(self)
        rescheduleAutosave()
    }

    deinit { autosaveTimer?.invalidate() }

    // MARK: - Autosave

    private var autosaveTimer: Timer?
    private var autosaveTimerMinutes = 0
    private func rescheduleAutosave() {
        let minutes = prefs.autosaveMinutes
        guard minutes != autosaveTimerMinutes else { return }
        autosaveTimerMinutes = minutes
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        guard minutes > 0 else { return }
        let t = Timer(timeInterval: TimeInterval(minutes) * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
        // .common so it keeps firing while a menu is open or a window is being dragged.
        RunLoop.main.add(t, forMode: .common)
        autosaveTimer = t
    }

    private func autosave() {
        guard prefs.autosaveMinutes > 0, dirty, doc != nil, fileURL != nil else { return }
        // Never write out a file that is still locked: its passwords are encrypted with a
        // passphrase we haven't been given, and nothing here should touch it unattended.
        guard needsMasterPassword == nil else { return }
        save()
    }

    private var started = false

    /// Load whatever this window is meant to show. `request` is a specific file, a
    /// deliberately blank window, or — when nil, which is the window macOS opens at launch —
    /// whatever was open last time. Called from the window's onAppear, which can fire more
    /// than once, so it only ever runs its first time.
    func start(request: WindowRequest?) {
        guard !started else { return }
        started = true

        let path: String?
        if let request {
            path = request.path.isEmpty ? nil : request.path
        } else {
            path = LaunchState.openDocuments.first ?? UserDefaults.standard.string(forKey: "lastOpenedFile")
        }
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        // Another window may already have it: two windows on one file would be two
        // independent copies of the tree, and the last save would win. This is the restore
        // path racing with whatever macOS reopened by itself, so the spare window goes away
        // rather than sitting there empty.
        if let existing = WindowRegistry.shared.model(withFile: url), existing !== self {
            DispatchQueue.main.async { WindowRegistry.shared.window(for: self)?.close() }
            return
        }
        load(url: url)
        restoreOpenSessions()
    }

    func zoomTerminal(_ delta: Double) {
        terminalFontSize = min(28, max(8, terminalFontSize + delta))
    }

    /// Import a Royal TS / Royal TSX document into the open configuration. The imported
    /// tree is appended at the root; nothing is written to disk until the file is saved,
    /// so a bad import can be abandoned by closing without saving.
    func importRoyalTSPanel() {
        guard doc != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = t("Import.RoyalPrompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try RoyalTSImporter.load(fileURL: url) { [weak self] plain in
                self?.encrypt(plain) ?? nil
            }
            guard var d = doc else { return }
            for root in result.roots {
                root.parent = nil
                d.roots.append(root)
                expandedIDs.insert(root.id)
            }
            doc = d
            markDirty()

            let alert = NSAlert()
            alert.messageText = t("Import.DoneTitle")
            var body = String(format: t("Import.DoneBody"),
                              result.connections, result.withPassword, result.documentName)
            if result.connections > result.withPassword {
                body += "\n\n" + t("Import.NoPasswordNote")
            }
            if !result.skipped.isEmpty {
                let list = result.skipped.sorted { $0.key < $1.key }
                    .map { "\($0.key) × \($0.value)" }.joined(separator: ", ")
                body += "\n\n" + String(format: t("Import.SkippedNote"), list)
            }
            alert.informativeText = body
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = t("Import.FailedTitle")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func openFilePanel() {
        WindowRouter.shared.openFilePanel(preferring: self)
    }

    /// Create a new, empty confCons.xml at a user-chosen location and open it.
    func newDocumentPanel() {
        WindowRouter.shared.newDocumentPanel(preferring: self)
    }

    /// Build an empty ConfCons (mRemoteNG 2.6, default passphrase) and write it to disk.
    /// Returns nil on success, or a message describing why it failed.
    static func writeEmptyDocument(to url: URL) -> String? {
        let iterations = 1000
        guard let protectedEnc = MRNGCrypto.encrypt(
            plaintext: "ThisIsNotProtected",
            password: MRNGCrypto.defaultPassword,
            iterations: iterations) else {
            return String(format: t("Error.SaveFailed"), t("Error.EncryptionFailed"))
        }
        let blank = ConfCons(
            encryptionEngine: "AES",
            blockCipherMode: "GCM",
            kdfIterations: iterations,
            fullFileEncryption: false,
            protected: protectedEnc,
            confVersion: "2.6",
            roots: []
        )
        do {
            let xml = ConfConsSerializer.serialize(blank)
            try xml.write(to: url, atomically: true, encoding: String.Encoding.utf8)
            return nil
        } catch {
            return String(format: t("Error.SaveFailed"), error.localizedDescription)
        }
    }

    /// Close the current document and return to the empty state.
    /// Disconnects all sessions; the next launch will not auto-reopen anything.
    func closeDocument() {
        let closing = fileURL
        // Stop all open sessions (RDP threads, terminal subprocesses, etc.).
        for s in sessions { closeSession(s.id) }
        sessions.removeAll()
        selectedSessionID = nil
        selectedPanel = nil
        doc = nil
        fileURL = nil
        loadError = nil
        selectedNodeID = nil
        searchText = ""
        expandedIDs.removeAll()
        editorVisible = false
        pendingDelete = nil
        dirty = false
        if UserDefaults.standard.string(forKey: "lastOpenedFile") == closing?.path {
            UserDefaults.standard.removeObject(forKey: "lastOpenedFile")
        }
        WindowRegistry.shared.syncOpenDocuments()
    }

    func load(url: URL) {
        do {
            let parsed = try ConfConsParser.parse(fileURL: url)
            self.fileURL = url
            self.doc = parsed
            self.loadError = nil
            UserDefaults.standard.set(url.path, forKey: "lastOpenedFile")
            WindowRegistry.shared.syncOpenDocuments()
            loadExpanded(for: parsed)
            // Work out the passphrase: the public default, one already in the keychain for
            // this file, or ask. An empty Protected attribute means nothing to check against.
            self.masterPassword = MRNGCrypto.defaultPassword
            self.needsMasterPassword = nil
            if !parsed.protected.isEmpty,
               !MRNGCrypto.passwordIsCorrect(protectedBase64: parsed.protected,
                                             password: MRNGCrypto.defaultPassword,
                                             iterations: parsed.kdfIterations) {
                if let saved = MasterPasswordStore.password(for: url),
                   MRNGCrypto.passwordIsCorrect(protectedBase64: parsed.protected,
                                                password: saved,
                                                iterations: parsed.kdfIterations) {
                    self.masterPassword = saved
                } else {
                    self.needsMasterPassword = url
                }
            }
        } catch {
            self.doc = nil
            self.loadError = String(format: t("Error.ParseFailed"), "\(error)")
        }
    }

    func node(byID id: String?) -> MRNGNode? {
        guard let id, let doc else { return nil }
        return doc.allNodes().first { $0.id == id }
    }

    func decryptedPassword(for node: MRNGNode) -> String {
        let enc = node.encryptedPassword
        guard !enc.isEmpty, let doc else { return "" }
        return MRNGCrypto.decrypt(base64: enc, password: masterPassword, iterations: doc.kdfIterations) ?? ""
    }

    /// Try to unlock the open file with `candidate`. Returns false if it doesn't decrypt
    /// the Protected blob, leaving the file locked.
    @discardableResult
    func unlock(with candidate: String, remember: Bool) -> Bool {
        guard let doc, !doc.protected.isEmpty else { return false }
        guard MRNGCrypto.passwordIsCorrect(protectedBase64: doc.protected,
                                           password: candidate,
                                           iterations: doc.kdfIterations) else { return false }
        masterPassword = candidate
        needsMasterPassword = nil
        if remember, let url = fileURL { MasterPasswordStore.save(candidate, for: url) }
        treeVersion &+= 1
        return true
    }

    /// Change the file's master password: every stored password is decrypted with the old
    /// passphrase and re-encrypted with the new one, and the root Protected blob is rebuilt
    /// with the marker mRemoteNG expects. Nothing is written to disk until the file is
    /// saved, so a mistake can still be abandoned by closing without saving.
    ///
    /// Passing mRemoteNG's default passphrase removes the protection.
    ///
    /// All or nothing. It used to skip nodes that would not decrypt with the old passphrase
    /// and carry on, which left those passwords sealed under a key the file no longer
    /// admitted to using — unrecoverable after the next save, and silent about it. Now the
    /// whole document is converted in memory first, and a single failure abandons the change
    /// with the file untouched.
    ///
    /// Returns true when the passphrase was changed.
    @discardableResult
    func changeMasterPassword(to newPassword: String) -> Bool {
        guard var doc else { return false }
        let old = masterPassword
        guard old != newPassword else { return false }

        var converted: [(node: MRNGNode, sealed: String)] = []
        var unreadable = 0
        for node in doc.allNodes() {
            let enc = node.attributes["Password"] ?? ""
            guard !enc.isEmpty else { continue }
            guard let plain = MRNGCrypto.decrypt(base64: enc, password: old,
                                                 iterations: doc.kdfIterations) else {
                unreadable += 1
                continue
            }
            guard let sealed = MRNGCrypto.encrypt(plaintext: plain, password: newPassword,
                                                  iterations: doc.kdfIterations) else {
                reportMasterPasswordFailure(t("Master.FailedEncrypt"))
                return false
            }
            converted.append((node, sealed))
        }
        guard unreadable == 0 else {
            reportMasterPasswordFailure(String(format: t("Master.FailedUnreadable"), unreadable))
            return false
        }
        guard let protectedBlob = MRNGCrypto.makeProtected(password: newPassword,
                                                           iterations: doc.kdfIterations) else {
            reportMasterPasswordFailure(t("Master.FailedEncrypt"))
            return false
        }

        for item in converted { item.node.attributes["Password"] = item.sealed }
        doc.protected = protectedBlob
        self.doc = doc
        masterPassword = newPassword
        if let url = fileURL {
            if newPassword == MRNGCrypto.defaultPassword {
                MasterPasswordStore.clear(for: url)
            } else {
                MasterPasswordStore.save(newPassword, for: url)
            }
        }
        markDirty()
        return true
    }

    private func reportMasterPasswordFailure(_ body: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Master.FailedTitle")
        alert.informativeText = body
        alert.runModal()
    }

    /// Nil when there is nothing to encrypt or the encryption failed — never an empty
    /// string, which a caller would happily write over a perfectly good password.
    func encrypt(_ plaintext: String) -> String? {
        guard let doc, !plaintext.isEmpty else { return nil }
        return MRNGCrypto.encrypt(plaintext: plaintext, password: masterPassword, iterations: doc.kdfIterations)
    }

    // MARK: - Editing / saving

    func markDirty() { dirty = true; treeVersion &+= 1 }

    /// Reveal a node in the sidebar: expand every ancestor so the row exists, select it,
    /// and ask the list to scroll to it. The search filter is cleared first — an active
    /// filter can exclude the target from visibleRows(), and then the jump would silently
    /// do nothing.
    func revealInSidebar(_ node: MRNGNode) {
        if !searchText.isEmpty { searchText = "" }
        var ancestor = node.parent
        while let cur = ancestor {
            expandedIDs.insert(cur.id)
            ancestor = cur.parent
        }
        selectedNodeID = node.id
        scrollTarget = node.id
    }

    /// Container into which new nodes are inserted, derived from the current selection.
    private func targetContainer() -> MRNGNode? {
        if let sel = node(byID: selectedNodeID) {
            return sel.isContainer ? sel : sel.parent
        }
        return nil
    }

    func addConnection() {
        let node = MRNGNode.makeConnection(name: t("Connection.NewConnectionName"))
        insertNew(node)
    }

    func addFolder() {
        let node = MRNGNode.makeContainer(name: t("Connection.NewFolderName"))
        insertNew(node)
    }

    func duplicateNode(_ node: MRNGNode) {
        let copied = node.deepCopy(name: duplicateName(for: node))
        if let parent = node.parent {
            let idx = parent.children.firstIndex { $0 === node } ?? parent.children.count - 1
            parent.addChild(copied, at: idx + 1)
            expandedIDs.insert(parent.id)
        } else {
            let idx = doc?.roots.firstIndex { $0 === node } ?? ((doc?.roots.count ?? 1) - 1)
            doc?.roots.insert(copied, at: min(idx + 1, doc?.roots.count ?? 0))
            copied.parent = nil
        }
        if copied.isContainer {
            expandedIDs.insert(copied.id)
        }
        selectedNodeID = copied.id
        markDirty()
    }

    // MARK: - Move to / Copy to a folder

    /// Folders a node may be sent to: every container in the tree except the node itself
    /// and anything beneath it, since a folder cannot become its own ancestor.
    func destinationFolders(excluding node: MRNGNode) -> [MRNGNode] {
        (doc?.roots ?? []).filter { $0.isContainer && $0 !== node && !$0.isDescendant(of: node) }
    }

    /// Child folders of a folder, filtered the same way.
    func destinationFolders(under parent: MRNGNode, excluding node: MRNGNode) -> [MRNGNode] {
        parent.children.filter { $0.isContainer && $0 !== node && !$0.isDescendant(of: node) }
    }

    /// Move a node to the end of a folder, or to the end of the root when folder is nil.
    func move(_ node: MRNGNode, toFolder folder: MRNGNode?) {
        guard folder !== node.parent else { return }
        _ = moveNode(node, into: folder, at: nil)
        selectedNodeID = node.id
    }

    /// Copy a node into a folder. The copy keeps its name — a different folder has no
    /// clash to resolve — and only takes a suffix when the destination already holds one
    /// by that name, which is what copying into the node's own folder amounts to.
    func copy(_ node: MRNGNode, toFolder folder: MRNGNode?) {
        let siblings = folder.map { $0.children } ?? (doc?.roots ?? [])
        let taken = Set(siblings.map(\.name))
        var name = node.name
        if taken.contains(name) {
            name = String(format: t("Connection.CopyNameFormat"), node.name)
            var n = 2
            while taken.contains(name) {
                name = String(format: t("Connection.CopyNameNumberedFormat"), node.name, n)
                n += 1
            }
        }
        let copied = node.deepCopy(name: name)
        if let folder {
            folder.addChild(copied)
            expandedIDs.insert(folder.id)
        } else {
            copied.parent = nil
            doc?.roots.append(copied)
        }
        if copied.isContainer { expandedIDs.insert(copied.id) }
        selectedNodeID = copied.id
        markDirty()
    }

    private func duplicateName(for node: MRNGNode) -> String {
        let base = String(format: t("Connection.CopyNameFormat"), node.name)
        let siblingNames: Set<String>
        if let parent = node.parent {
            siblingNames = Set(parent.children.map(\.name))
        } else {
            siblingNames = Set(doc?.roots.map(\.name) ?? [])
        }
        guard siblingNames.contains(base) else { return base }
        var index = 2
        while true {
            let candidate = String(format: t("Connection.CopyNameNumberedFormat"), node.name, index)
            if !siblingNames.contains(candidate) { return candidate }
            index += 1
        }
    }

    private func insertNew(_ node: MRNGNode) {
        if let parent = targetContainer() {
            parent.addChild(node)
            expandedIDs.insert(parent.id)
        } else {
            doc?.roots.append(node) // new root node
        }
        selectedNodeID = node.id
        markDirty()
    }

    func deleteNode(_ node: MRNGNode) {
        // Close any open sessions on this node or any of its descendants.
        let ids = Set([node] + descendants(of: node))
        sessions.filter { ids.contains($0.node) }.forEach { closeSession($0.id) }
        if node.parent != nil {
            node.removeFromParent()
        } else {
            doc?.roots.removeAll { $0 === node }
        }
        if selectedNodeID == node.id { selectedNodeID = nil }
        markDirty()
    }

    private func descendants(of node: MRNGNode) -> [MRNGNode] {
        var out: [MRNGNode] = []
        func walk(_ n: MRNGNode) { n.children.forEach { out.append($0); walk($0) } }
        walk(node)
        return out
    }

    /// Move `node` to `newParent` (or root, if nil) at the given index.
    /// Rejects moving into one of its own descendants.
    @discardableResult
    func moveNode(_ node: MRNGNode, into newParent: MRNGNode?, at index: Int?) -> Bool {
        if let newParent {
            guard newParent !== node, !newParent.isDescendant(of: node), newParent.isContainer else { return false }
            // A node sitting at the top level is in doc.roots and has no parent, so
            // addChild's own detach step finds nothing to detach and the node ends up in
            // both places at once — listed at the root and inside the folder.
            if node.parent == nil { doc?.roots.removeAll { $0 === node } }
            newParent.addChild(node, at: index)
            expandedIDs.insert(newParent.id)
        } else {
            node.removeFromParent()
            if let index, index >= 0, index <= (doc?.roots.count ?? 0) { doc?.roots.insert(node, at: index) }
            else { doc?.roots.append(node) }
        }
        markDirty()
        return true
    }

    /// Apply a move based on the drop indicator position.
    func performMove(draggedID: String, target: MRNGNode, pos: DropPos) {
        dropIndicator = nil
        guard let dragged = node(byID: draggedID), dragged !== target else { return }
        guard !target.isDescendant(of: dragged) else { return } // don't move a folder into itself
        switch pos {
        case .into:
            guard target.isContainer else { return }
            moveNode(dragged, into: target, at: nil)
        case .above, .below:
            moveNode(dragged, relativeTo: target, after: pos == .below)
        }
    }

    /// Insert `node` next to `ref` (above/below), inside ref's parent (or roots).
    func moveNode(_ node: MRNGNode, relativeTo ref: MRNGNode, after: Bool) {
        guard node !== ref else { return }
        let newParent = ref.parent
        if let newParent, newParent === node || newParent.isDescendant(of: node) { return }
        // Detach the node from its current location (parent or roots).
        node.removeFromParent()
        doc?.roots.removeAll { $0 === node }
        // Recompute ref's index after removal.
        if let newParent {
            let idx = newParent.children.firstIndex { $0 === ref } ?? newParent.children.count
            let insertAt = after ? idx + 1 : idx
            newParent.children.insert(node, at: min(insertAt, newParent.children.count))
            node.parent = newParent
        } else {
            let roots = doc?.roots ?? []
            let idx = roots.firstIndex { $0 === ref } ?? roots.count
            let insertAt = after ? idx + 1 : idx
            doc?.roots.insert(node, at: min(insertAt, doc?.roots.count ?? 0))
            node.parent = nil
        }
        markDirty()
    }

    /// Recursive alphabetical sort (flat): at every level everything sorts A-Z by name,
    /// folders and connections mixed together.
    func sortAlphabetical() {
        guard var d = doc else { return }
        func cmp(_ a: MRNGNode, _ b: MRNGNode) -> Bool {
            // caseInsensitiveCompare = ordinal (no locale) -> matches Windows sort order.
            a.name.caseInsensitiveCompare(b.name) == .orderedAscending
        }
        func sortNode(_ n: MRNGNode) {
            for c in n.children where c.isContainer { sortNode(c) }
            n.children.sort(by: cmp)
        }
        d.roots.forEach(sortNode)
        d.roots.sort(by: cmp)
        doc = d
        markDirty()
    }

    func save() {
        guard let doc, let url = fileURL else { return }
        let xml = ConfConsSerializer.serialize(doc)
        backUp(url)
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            dirty = false
        } catch {
            loadError = String(format: t("Error.SaveFailed"), error.localizedDescription)
        }
    }

    /// Copy the file aside before overwriting it, then drop the oldest copies beyond the
    /// configured count. Same shape as mRemoteNG (FileBackupCreator + FileBackupPruner):
    /// one copy per save, newest N kept, count 0 turns the feature off.
    ///
    /// One deliberate difference: a count of 0 only stops NEW copies, it does not delete
    /// the ones already there. mRemoteNG's pruner would remove all of them, and quietly
    /// throwing away every backup because a setting was toggled is not a trade worth making.
    private func backUp(_ url: URL) {
        let keep = prefs.backupKeepCount
        guard keep > 0, FileManager.default.fileExists(atPath: url.path) else { return }
        let backups = url.deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)

        // Named after the file being saved, not a fixed "confCons": several documents can
        // live in one folder and share this backups directory, and a shared name would let
        // one document's rotation delete another's copies.
        let base = url.deletingPathExtension().lastPathComponent
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let stamp = fmt.string(from: Date())
        try? FileManager.default.copyItem(
            at: url, to: backups.appendingPathComponent("\(base)-\(stamp).xml"))

        prune(backups, base: base, keep: keep)
    }

    private func prune(_ dir: URL, base: String, keep: Int) {
        guard let all = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
        // Strict match on our own naming, so nothing else the user keeps in that folder is
        // ever a candidate for deletion.
        let escaped = NSRegularExpression.escapedPattern(for: base)
        guard let re = try? NSRegularExpression(
                pattern: "^\(escaped)-\\d{4}-\\d{2}-\\d{2}_\\d{6}\\.xml$") else { return }
        let mine = all.map(\.lastPathComponent).filter { name in
            re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        // The stamp sorts lexicographically, so descending by name is newest first.
        for name in mine.sorted(by: >).dropFirst(keep) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    func kind(for node: MRNGNode) -> Session.Kind {
        switch node.protocolType {
        case "SSH1", "SSH2": return .ssh
        case "Telnet": return .telnet
        case "HTTP", "HTTPS": return .http
        case "RDP": return .rdp
        case "IntApp": return .externalApp
        default: return .unsupported
        }
    }

    func connect(_ node: MRNGNode) {
        guard !node.isContainer else { return }
        let session = Session(
            title: node.name,
            kind: kind(for: node),
            node: node,
            password: decryptedPassword(for: node),
            panel: node.panel.isEmpty ? "General" : node.panel
        )
        sessions.append(session)
        selectedSessionID = session.id
        selectedPanel = session.panel
    }

    /// Distinct panels (in first-seen order) among the currently open sessions.
    func panels() -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for s in sessions where !seen.contains(s.panel) { seen.insert(s.panel); out.append(s.panel) }
        return out
    }

    func sessions(inPanel panel: String?) -> [Session] {
        sessions.filter { $0.panel == panel }
    }

    func selectPanel(_ panel: String) {
        selectedPanel = panel
        if let first = sessions.first(where: { $0.panel == panel }) {
            selectedSessionID = first.id
        }
    }

    func closeSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id {
            // Prefer a session in the current panel; otherwise the last session.
            let inPanel = sessions.last { $0.panel == selectedPanel }
            let next = inPanel ?? sessions.last
            selectedSessionID = next?.id
            selectedPanel = next?.panel
        }
    }

    /// Reconnect: replace the session with a new one (fresh id) -> the view is
    /// recreated and the underlying process restarts.
    func reconnect(_ session: Session) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        // Re-read the password from the node instead of reusing the one captured when the
        // tab was first opened. Editing the credentials of a failed session and hitting
        // Reconnect otherwise retried with the stale password — the only way to pick up the
        // change was closing the tab and opening it again from the sidebar. Everything else
        // (host, user, domain) is already read live from the node at connect time.
        let fresh = Session(title: session.title, kind: session.kind, node: session.node,
                            password: decryptedPassword(for: session.node), panel: session.panel)
        sessions[idx] = fresh
        selectedSessionID = fresh.id
        selectedPanel = fresh.panel
    }

    func duplicate(_ session: Session) {
        connect(session.node)
    }

    // MARK: - Session restore (remember open connections across launches)

    /// Key under which one file's open connections are remembered. Keyed by path because
    /// several files can be open at once, one window each — a single shared key meant the
    /// last window to touch a tab overwrote every other window's list.
    private static func sessionsKey(for path: String) -> String { "openSessions:" + path }

    /// Persist the currently open connections for the loaded file. Only node IDs
    /// + panel are written (never passwords); external-tool tabs are excluded.
    private func persistSessionState() {
        guard restoreSessions, let file = fileURL?.path else {
            if let file = fileURL?.path {
                UserDefaults.standard.removeObject(forKey: AppModel.sessionsKey(for: file))
            }
            return
        }
        let restorable: Set<Session.Kind> = [.ssh, .telnet, .http, .rdp, .sftp]
        let open = sessions.filter { restorable.contains($0.kind) }
        let items = open.map {
            SavedSessionState.Item(nodeID: $0.node.id, sftp: $0.kind == .sftp, panel: $0.panel)
        }
        let sel = sessions.first { $0.id == selectedSessionID }
        let state = SavedSessionState(
            file: file,
            items: items,
            selectedNodeID: sel.map { $0.node.id },
            selectedSftp: sel?.kind == .sftp,
            selectedPanel: selectedPanel
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: AppModel.sessionsKey(for: file))
        }
    }

    /// Reopen the connections saved from the previous launch, if the setting is
    /// on and the saved state belongs to the file that just loaded. Nodes that
    /// no longer exist in the file are skipped.
    private func restoreOpenSessions() {
        guard restoreSessions, let file = fileURL?.path else { return }
        var blob = UserDefaults.standard.data(forKey: AppModel.sessionsKey(for: file))
        if blob == nil {
            // Written by versions before the key was split per file; consume it once.
            if let legacy = UserDefaults.standard.data(forKey: "openSessions"),
               let state = try? JSONDecoder().decode(SavedSessionState.self, from: legacy),
               state.file == file {
                blob = legacy
                UserDefaults.standard.removeObject(forKey: "openSessions")
            }
        }
        guard let data = blob,
              let state = try? JSONDecoder().decode(SavedSessionState.self, from: data),
              state.file == file else { return }
        for item in state.items {
            guard let node = node(byID: item.nodeID), !node.isContainer else { continue }
            if item.sftp { openSFTP(node) } else { connect(node) }
        }
        if let sn = state.selectedNodeID,
           let match = sessions.first(where: { $0.node.id == sn && ($0.kind == .sftp) == state.selectedSftp }) {
            selectedSessionID = match.id
        }
        if let p = state.selectedPanel { selectedPanel = p }
    }

    // MARK: - External Tools

    /// Wrap a value in single quotes so the shell reads it as one literal word, with the
    /// only character that can end such a quote spliced out. Without this, a connection
    /// named `x; rm -rf ~` ran as two commands — and names come from confCons.xml files
    /// that are routinely handed around between people.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Values are substituted already quoted, so a template writes `ping %Host%`, not
    /// `ping "%Host%"` — quoting a macro yourself now nests quotes instead of protecting it.
    func substituteMacros(_ template: String, node: MRNGNode) -> String {
        var s = template
        let map: [String: String] = [
            "%Host%": node.hostname, "%Hostname%": node.hostname,
            "%Username%": node.username, "%User%": node.username,
            "%Port%": "\(node.port)", "%Domain%": node.domain,
            "%Name%": node.name, "%Description%": node.descr,
        ]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: Self.shellQuoted(v)) }
        // The password is the one value that never becomes text: it is passed to the shell
        // in the environment, and the macro expands to a reference to it. Command lines are
        // world-readable to this user's processes; environments are not on public display.
        s = s.replacingOccurrences(of: "%Password%", with: "\"$MRNG_PASSWORD\"")
        return s
    }

    /// Run an external tool in a terminal tab (via /bin/sh -lc).
    func runTool(_ tool: ExternalTool, on node: MRNGNode) {
        let cmd = substituteMacros(tool.commandLine, node: node)
        let session = Session(
            title: "\(tool.name): \(node.name)",
            kind: .externalTool,
            node: node,
            password: tool.commandLine.contains("%Password%") ? decryptedPassword(for: node) : "",
            panel: node.panel.isEmpty ? "General" : node.panel,
            command: cmd
        )
        sessions.append(session)
        selectedSessionID = session.id
        selectedPanel = session.panel
    }

    /// Open an SFTP tab (a terminal running sftp) for an SSH connection.
    func openSFTP(_ node: MRNGNode) {
        guard !node.isContainer else { return }
        let session = Session(
            title: node.name + " (SFTP)",
            kind: .sftp,
            node: node,
            password: decryptedPassword(for: node),
            panel: node.panel.isEmpty ? "General" : node.panel
        )
        sessions.append(session)
        selectedSessionID = session.id
        selectedPanel = session.panel
    }

    func renameSession(_ id: UUID, to title: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        sessions[idx].title = title
    }

    /// Called by the terminal coordinator when the remote shell emits an OSC
    /// 0/1/2 title (typical zsh precmd: "user@host:cwd"). Gated by a setting.
    func updateTitleFromTerminal(_ id: UUID, _ title: String) {
        guard updateTabTitleFromTerminal else { return }
        renameSession(id, to: title)
    }

    func copyPassword(_ session: Session) {
        // From the node, not the session's snapshot: after editing the credentials of an
        // open tab, the snapshot still holds what was used at connect time.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(decryptedPassword(for: session.node), forType: .string)
    }

    /// Send Ctrl+Alt+Del to the given RDP session.
    func sendCtrlAltDel(_ session: Session) {
        NotificationCenter.default.post(name: .mrngSendCAD, object: session.id)
    }

    func promptAndRename(_ session: Session) {
        let alert = NSAlert()
        alert.messageText = t("Rename.Title")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = session.title
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: t("Delete.Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            renameSession(session.id, to: field.stringValue)
        }
    }

    // MARK: - Tree (expansion / visibility)

    /// Visible rows (DFS). When search is active -> filter (matching connections + their parent folders).
    func visibleRows() -> [FlatRow] {
        guard let doc else { return [] }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()

        if q.isEmpty {
            var out: [FlatRow] = []
            func walk(_ node: MRNGNode, depth: Int) {
                out.append(FlatRow(node: node, depth: depth))
                if node.isContainer && expandedIDs.contains(node.id) {
                    for child in node.children { walk(child, depth: depth + 1) }
                }
            }
            for root in doc.roots { walk(root, depth: 0) }
            return out
        }

        // Filtering: include matching nodes + their ancestors (context).
        // Search also matches Panel. If a FOLDER matches, include its whole subtree.
        func matches(_ n: MRNGNode) -> Bool {
            n.name.lowercased().contains(q)
                || n.hostname.lowercased().contains(q)
                || n.protocolType.lowercased().contains(q)
                || n.descr.lowercased().contains(q)
                || n.panel.lowercased().contains(q)
        }
        var keep = Set<String>()
        @discardableResult
        func mark(_ n: MRNGNode, ancestorMatched: Bool) -> Bool {
            let effectiveMatch = matches(n) || ancestorMatched
            var childMatch = false
            for c in n.children where mark(c, ancestorMatched: effectiveMatch) { childMatch = true }
            if effectiveMatch || childMatch {
                keep.insert(n.id)
                return true
            }
            return false
        }
        doc.roots.forEach { mark($0, ancestorMatched: false) }

        var out: [FlatRow] = []
        func emit(_ n: MRNGNode, depth: Int) {
            guard keep.contains(n.id) else { return }
            out.append(FlatRow(node: n, depth: depth))
            for c in n.children { emit(c, depth: depth + 1) }
        }
        doc.roots.forEach { emit($0, depth: 0) }
        return out
    }

    func toggleExpanded(_ id: String) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }

    func expandAll() {
        guard let doc else { return }
        expandedIDs = Set(doc.allNodes().filter { $0.isContainer }.map { $0.id })
    }

    func collapseAll() {
        expandedIDs = []
    }

    private func expandedKey() -> String? {
        fileURL.map { "expanded:" + $0.path }
    }

    private func saveExpanded() {
        guard let key = expandedKey() else { return }
        UserDefaults.standard.set(Array(expandedIDs), forKey: key)
    }

    /// Load saved state; if none, fall back to the Expanded attribute from the XML.
    private func loadExpanded(for doc: ConfCons) {
        if let key = expandedKey(), let saved = UserDefaults.standard.array(forKey: key) as? [String] {
            expandedIDs = Set(saved)
        } else {
            expandedIDs = Set(doc.allNodes()
                .filter { $0.isContainer && $0.attributes["Expanded"] == "true" }
                .map { $0.id })
        }
    }
}
