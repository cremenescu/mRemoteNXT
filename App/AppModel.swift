// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit
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
    @Published var pendingDelete: MRNGNode?
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
    @Published var uiFontSize: Double = 13 {
        didSet { UserDefaults.standard.set(uiFontSize, forKey: "uiFontSize") }
    }
    @Published var terminalFontSize: Double = 13 {
        didSet { UserDefaults.standard.set(terminalFontSize, forKey: "terminalFontSize") }
    }
    @Published var terminalTheme: String = "Implicit" {
        didSet { UserDefaults.standard.set(terminalTheme, forKey: "terminalTheme") }
    }
    @Published var rowHeight: Double = 22 {
        didSet { UserDefaults.standard.set(rowHeight, forKey: "rowHeight") }
    }
    @Published var showProtocol: Bool = false {
        didSet { UserDefaults.standard.set(showProtocol, forKey: "showProtocol") }
    }
    @Published var showPasswordPlain: Bool = false {
        didSet { UserDefaults.standard.set(showPasswordPlain, forKey: "showPasswordPlain") }
    }
    @Published var cursorBlinkSpeed: CursorBlinkSpeed = .medium {
        didSet { UserDefaults.standard.set(cursorBlinkSpeed.rawValue, forKey: "cursorBlinkSpeed") }
    }
    @Published var updateTabTitleFromTerminal: Bool = true {
        didSet { UserDefaults.standard.set(updateTabTitleFromTerminal, forKey: "updateTabTitleFromTerminal") }
    }
    @Published var editorVisible: Bool = false {
        didSet { UserDefaults.standard.set(editorVisible, forKey: "editorVisible") }
    }
    @Published var closeTabOnDisconnect: Bool = false {
        didSet { UserDefaults.standard.set(closeTabOnDisconnect, forKey: "closeTabOnDisconnect") }
    }
    /// Reopen (and reconnect) the connections that were open when the app last
    /// quit. Default on. Restored on launch after the file auto-loads.
    @Published var restoreSessions: Bool = true {
        didSet { UserDefaults.standard.set(restoreSessions, forKey: "restoreSessions") }
    }
    /// When on, FreeRDP writes a DEBUG log to ~/Library/Logs/mRemoteNXT/mRemoteNXT.log
    /// so RDP connection failures can be diagnosed. Off by default (verbose).
    @Published var diagnosticLogging: Bool = false {
        didSet {
            UserDefaults.standard.set(diagnosticLogging, forKey: "diagnosticLogging")
            AppModel.applyDiagnosticLogging(diagnosticLogging)
        }
    }
    @Published var externalTools: [ExternalTool] = [] {
        didSet { saveTools() }
    }

    /// Directory where diagnostic logs are written.
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/mRemoteNXT", isDirectory: true)
    }

    static func applyDiagnosticLogging(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        }
        RDPClient.setDiagnosticLogging(on, directory: logDirectory.path)
    }

    /// v1: assume the default passphrase. Phase 2: prompt the user when Protected fails to validate.
    private(set) var masterPassword = MRNGCrypto.defaultPassword

    init() {
        if let v = UserDefaults.standard.object(forKey: "uiFontSize") as? Double { uiFontSize = v }
        if let v = UserDefaults.standard.object(forKey: "terminalFontSize") as? Double { terminalFontSize = v }
        if let v = UserDefaults.standard.string(forKey: "terminalTheme") { terminalTheme = v }
        if let v = UserDefaults.standard.object(forKey: "rowHeight") as? Double { rowHeight = v }
        if let v = UserDefaults.standard.object(forKey: "showProtocol") as? Bool { showProtocol = v }
        if let v = UserDefaults.standard.object(forKey: "showPasswordPlain") as? Bool { showPasswordPlain = v }
        if let v = UserDefaults.standard.string(forKey: "cursorBlinkSpeed"),
           let s = CursorBlinkSpeed(rawValue: v) { cursorBlinkSpeed = s }
        if let v = UserDefaults.standard.object(forKey: "updateTabTitleFromTerminal") as? Bool { updateTabTitleFromTerminal = v }
        if let v = UserDefaults.standard.object(forKey: "editorVisible") as? Bool { editorVisible = v }
        if let v = UserDefaults.standard.object(forKey: "closeTabOnDisconnect") as? Bool { closeTabOnDisconnect = v }
        if let v = UserDefaults.standard.object(forKey: "restoreSessions") as? Bool { restoreSessions = v }
        if let v = UserDefaults.standard.object(forKey: "diagnosticLogging") as? Bool { diagnosticLogging = v }
        AppModel.applyDiagnosticLogging(diagnosticLogging)
        loadTools()
        // Auto-reopen the last file used (if it still exists on disk).
        if let saved = UserDefaults.standard.string(forKey: "lastOpenedFile"),
           FileManager.default.fileExists(atPath: saved) {
            load(url: URL(fileURLWithPath: saved))
            restoreOpenSessions()
        }
    }

    func zoomTerminal(_ delta: Double) {
        terminalFontSize = min(28, max(8, terminalFontSize + delta))
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    /// Create a new, empty confCons.xml at a user-chosen location and open it.
    func newDocumentPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "confCons.xml"
        panel.message = t("NewDoc.Prompt")
        if panel.runModal() == .OK, let url = panel.url {
            createNewDocument(at: url)
        }
    }

    /// Build an empty ConfCons (mRemoteNG 2.6, default passphrase) and save it.
    func createNewDocument(at url: URL) {
        let iterations = 1000
        let protectedEnc = MRNGCrypto.encrypt(
            plaintext: "ThisIsNotProtected",
            password: MRNGCrypto.defaultPassword,
            iterations: iterations)
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
            load(url: url)
        } catch {
            loadError = String(format: t("Error.SaveFailed"), error.localizedDescription)
        }
    }

    /// Close the current document and return to the empty state.
    /// Disconnects all sessions; the next launch will not auto-reopen anything.
    func closeDocument() {
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
        UserDefaults.standard.removeObject(forKey: "lastOpenedFile")
    }

    func load(url: URL) {
        do {
            let parsed = try ConfConsParser.parse(fileURL: url)
            self.fileURL = url
            self.doc = parsed
            self.loadError = nil
            UserDefaults.standard.set(url.path, forKey: "lastOpenedFile")
            loadExpanded(for: parsed)
            // Determine the master password: default, or (phase 2) prompted from the user.
            if !parsed.protected.isEmpty,
               !MRNGCrypto.passwordIsCorrect(protectedBase64: parsed.protected,
                                             password: MRNGCrypto.defaultPassword,
                                             iterations: parsed.kdfIterations) {
                self.loadError = t("Error.CustomMaster")
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

    func encrypt(_ plaintext: String) -> String {
        guard let doc, !plaintext.isEmpty else { return "" }
        return MRNGCrypto.encrypt(plaintext: plaintext, password: masterPassword, iterations: doc.kdfIterations)
    }

    // MARK: - Editing / saving

    func markDirty() { dirty = true; treeVersion &+= 1 }

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
        let dir = url.deletingLastPathComponent()
        let backups = dir.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        // Back up the current file before overwriting it.
        if FileManager.default.fileExists(atPath: url.path) {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd_HHmmss"
            let bak = backups.appendingPathComponent("confCons-\(fmt.string(from: Date())).xml")
            try? FileManager.default.copyItem(at: url, to: bak)
        }
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            dirty = false
        } catch {
            loadError = String(format: t("Error.SaveFailed"), error.localizedDescription)
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
        let fresh = Session(title: session.title, kind: session.kind, node: session.node,
                            password: session.password, panel: session.panel)
        sessions[idx] = fresh
        selectedSessionID = fresh.id
        selectedPanel = fresh.panel
    }

    func duplicate(_ session: Session) {
        connect(session.node)
    }

    // MARK: - Session restore (remember open connections across launches)

    /// Persist the currently open connections for the loaded file. Only node IDs
    /// + panel are written (never passwords); external-tool tabs are excluded.
    private func persistSessionState() {
        guard restoreSessions, let file = fileURL?.path else {
            UserDefaults.standard.removeObject(forKey: "openSessions")
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
            UserDefaults.standard.set(data, forKey: "openSessions")
        }
    }

    /// Reopen the connections saved from the previous launch, if the setting is
    /// on and the saved state belongs to the file that just loaded. Nodes that
    /// no longer exist in the file are skipped.
    private func restoreOpenSessions() {
        guard restoreSessions,
              let file = fileURL?.path,
              let data = UserDefaults.standard.data(forKey: "openSessions"),
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

    private func loadTools() {
        if let data = UserDefaults.standard.data(forKey: "externalTools"),
           let tools = try? JSONDecoder().decode([ExternalTool].self, from: data) {
            externalTools = tools
        } else {
            externalTools = [
                ExternalTool(name: "Ping", commandLine: "ping -c 5 %Host%"),
                ExternalTool(name: "Traceroute", commandLine: "traceroute %Host%"),
                ExternalTool(name: "Open in browser", commandLine: "open http://%Host%"),
            ]
        }
    }

    private func saveTools() {
        if let data = try? JSONEncoder().encode(externalTools) {
            UserDefaults.standard.set(data, forKey: "externalTools")
        }
    }

    func substituteMacros(_ template: String, node: MRNGNode) -> String {
        var s = template
        let map: [String: String] = [
            "%Host%": node.hostname, "%Hostname%": node.hostname,
            "%Username%": node.username, "%User%": node.username,
            "%Port%": "\(node.port)", "%Domain%": node.domain,
            "%Name%": node.name, "%Description%": node.descr,
            "%Password%": decryptedPassword(for: node),
        ]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }

    /// Run an external tool in a terminal tab (via /bin/sh -lc).
    func runTool(_ tool: ExternalTool, on node: MRNGNode) {
        let cmd = substituteMacros(tool.commandLine, node: node)
        let session = Session(
            title: "\(tool.name): \(node.name)",
            kind: .externalTool,
            node: node,
            password: "",
            panel: node.panel.isEmpty ? "General" : node.panel,
            command: cmd
        )
        sessions.append(session)
        selectedSessionID = session.id
        selectedPanel = session.panel
    }

    func addTool() { externalTools.append(ExternalTool(name: "New tool", commandLine: "")) }
    func deleteTool(_ tool: ExternalTool) { externalTools.removeAll { $0.id == tool.id } }

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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.password, forType: .string)
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
