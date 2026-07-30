// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit

/// Puts the open configuration file in the window's title bar the way macOS documents do:
/// `representedURL` gives the proxy icon, so Cmd- or right-clicking the title shows the
/// full folder path — the quick way to tell apart several confCons.xml files living in
/// different directories. The subtitle spells the folder out without any clicking.
struct WindowChrome: NSViewRepresentable {
    let fileURL: URL?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { apply(from: v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: nsView) }
    }

    private func apply(from view: NSView) {
        guard let window = view.window else { return }
        window.representedURL = fileURL
        if let url = fileURL {
            window.title = url.lastPathComponent
            window.subtitle = (url.deletingLastPathComponent().path as NSString)
                .abbreviatingWithTildeInPath
        } else {
            window.title = "mRemoteNXT"
            window.subtitle = ""
        }
    }
}

/// Confirms Cmd+Q while connections are open or edits are unsaved.
///
/// Quitting used to be instant, which is unforgiving next to Cmd+W on a keyboard where the
/// two keys are neighbours: one slip and every session is gone.
final class QuitGuardDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.current else { return .terminateNow }
        let sessions = model.sessions.count
        let dirty = model.dirty
        guard sessions > 0 || dirty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Quit.Title")
        alert.informativeText = {
            if sessions > 0 && dirty {
                return String(format: t("Quit.BodyBoth"), sessions)
            } else if sessions > 0 {
                return String(format: t("Quit.BodySessions"), sessions)
            }
            return t("Quit.BodyUnsaved")
        }()
        alert.addButton(withTitle: t("Quit.Confirm"))   // first = default
        alert.addButton(withTitle: t("Delete.Cancel"))
        if dirty { alert.addButton(withTitle: t("Quit.SaveAndQuit")) }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .terminateNow
        case .alertThirdButtonReturn where dirty:
            model.save()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
