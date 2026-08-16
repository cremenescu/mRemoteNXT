// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit

/// Where a window first meets its model: the only place in the SwiftUI tree that can see
/// the NSWindow, so it registers the pair with WindowRegistry.
///
/// The title bar itself is set with navigationTitle/Subtitle/Document in ContentView.
/// Writing it onto the NSWindow from here as well raced with SwiftUI and lost.
struct WindowChrome: NSViewRepresentable {
    let fileURL: URL?
    let model: AppModel

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
        WindowRegistry.shared.attach(model: model, to: window)
    }
}

/// Confirms Cmd+Q while connections are open or edits are unsaved, anywhere in the app.
///
/// Quitting used to be instant, which is unforgiving next to Cmd+W on a keyboard where the
/// two keys are neighbours: one slip and every session is gone. (Cmd+W now closes a tab;
/// the per-window equivalent of this guard is WindowCloseGuard.)
final class QuitGuardDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI builds the main menu after launch, so the Cmd+W fixup has to wait for it.
        // (Reopening last session's windows is driven from the first window's onAppear,
        // where the open-window action is available.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainMenuFixup.apply()
        }
        // After the windows have had their moment: a panel that lands on top of a tree
        // still drawing itself reads as something gone wrong rather than as news.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            WhatsNewWindow.showAfterUpdateIfNeeded()
        }
    }

    /// Keep the app alive with no windows open, like Finder or Mail: the menu bar stays,
    /// and Cmd+N or the Dock icon brings a window back. Closing the last window is not a
    /// decision to quit — especially now that closing one is a routine thing to do.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { confirmQuit() }
    }

    @MainActor
    private func confirmQuit() -> NSApplication.TerminateReply {
        let registry = WindowRegistry.shared
        let (sessions, dirty) = registry.totals
        guard sessions > 0 || dirty else {
            registry.beginTermination()
            return .terminateNow
        }

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
            registry.beginTermination()
            return .terminateNow
        case .alertThirdButtonReturn where dirty:
            registry.saveAllDirty()
            registry.beginTermination()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
