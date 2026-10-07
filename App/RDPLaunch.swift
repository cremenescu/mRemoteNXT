// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit
import MRNGCore

/// A .rdp file opened from the Finder, or an rdp:// link: connects straight away in the
/// front window, as Windows App does, without adding anything to the configuration.
/// Keeping it is what File › Import RDP Files is for.
///
/// The credentials sheet comes first every time. A link can come from any web page, so
/// it doubles as the confirmation that this computer is really where to connect — and an
/// .rdp file never carries a usable password anyway (mstsc encrypts it for one Windows
/// account).
@MainActor
enum RDPLaunch {
    /// Opens seen in the last few seconds. AppKit hands an open to the app delegate and
    /// SwiftUI to onOpenURL, and which of the two fires differs between files and links,
    /// so both are wired and the second delivery of the same one is dropped.
    private static var recent: [(key: String, at: Date)] = []

    static func canHandle(_ url: URL) -> Bool {
        url.isFileURL ? url.pathExtension.lowercased() == "rdp" : url.scheme?.lowercased() == "rdp"
    }

    static func open(_ urls: [URL], preferring model: AppModel? = nil) {
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0.at) > 3 }
        for url in urls where canHandle(url) {
            let key = url.absoluteString
            guard !recent.contains(where: { $0.key == key }) else { continue }
            recent.append((key, now))
            handle(url, preferring: model, attempt: 0)
        }
    }

    private static func handle(_ url: URL, preferring model: AppModel?, attempt: Int) {
        // Launched by the open itself: the windows are still being restored. Wait for one,
        // and make one if none turns up.
        guard let target = model ?? frontModel() else {
            guard attempt < 40 else { return }
            if attempt == 10 { WindowRouter.shared.newWindow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                handle(url, preferring: nil, attempt: attempt + 1)
            }
            return
        }

        let settings: RDPFile.Settings
        let name: String
        let source: String
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url) else {
                fail(String(format: t("RDPOpen.Unreadable"), url.lastPathComponent))
                return
            }
            settings = RDPFile.parse(data: data)
            name = url.deletingPathExtension().lastPathComponent
            source = String(format: t("RDPOpen.FromFile"), url.lastPathComponent)
        } else {
            settings = RDPFile.parse(uri: url.absoluteString) ?? [:]
            name = ""
            source = t("RDPOpen.FromLink")
        }
        guard let node = RDPFile.makeConnection(name: name, settings: settings) else {
            fail(String(format: t("RDPOpen.NoAddress"), url.isFileURL ? url.lastPathComponent : url.absoluteString))
            return
        }
        WindowRegistry.shared.focus(target)
        guard let password = askCredentials(for: node, source: source) else { return }
        target.connectTemporary(node, password: password)
    }

    /// The document window last in front, if it is still open.
    private static func frontModel() -> AppModel? {
        let registry = WindowRegistry.shared
        if let m = registry.frontModel, registry.window(for: m) != nil { return m }
        return registry.models.first { registry.window(for: $0) != nil }
    }

    /// Username (prefilled from the file) and password. nil = cancelled. The username is
    /// written back to the node, split into domain and user the way the editor keeps them.
    private static func askCredentials(for node: MRNGNode, source: String) -> String? {
        let alert = NSAlert()
        let port = node.port == 3389 ? "" : ":\(node.port)"
        alert.messageText = String(format: t("RDPOpen.Title"), node.hostname + port)
        alert.informativeText = source + "\n\n" + t("RDPOpen.NotSaved")

        let user = NSTextField(string: node.domain.isEmpty ? node.username : node.domain + "\\" + node.username)
        user.placeholderString = t("Editor.Field.Username")
        let pass = NSSecureTextField(string: "")
        pass.placeholderString = t("Editor.Field.Password")
        let stack = NSStackView(views: [user, pass])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 52)
        for f in [user, pass] { f.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: t("RDPOpen.Connect"))
        alert.addButton(withTitle: t("Delete.Cancel"))
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : pass

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var name = user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var domain = ""
        if let r = name.range(of: "\\") {
            domain = String(name[..<r.lowerBound])
            name = String(name[r.upperBound...])
        }
        node.attributes["Username"] = name
        node.attributes["Domain"] = domain
        return pass.stringValue
    }

    private static func fail(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("RDPOpen.FailedTitle")
        alert.informativeText = message
        alert.runModal()
    }
}
